module cydo.agent.copilot;

import core.time : Duration;

import std.conv : to;
import std.format : format;
import std.path : buildPath, dirName, expandTilde;
import ae.utils.json : JSONFragment, JSONPartial, jsonParse, toJson;
import ae.utils.jsonrpc : JsonRpcResponse;
import ae.utils.promise : Promise, resolve;

import cydo.agent.sdk : SdkProcess, SdkSessionHandler,
	SdkPermissionRequest, SdkPermissionResult,
	SdkToolCallRequest, SdkToolCallResult, SdkToolResult,
	SdkEvent, EmptyResult;
import cydo.agent.agent : Agent, DiscoveredSession, OneShotHandle, RewindResult, SessionConfig, SessionMeta;
import cydo.agent.protocol : ContentBlock;
import cydo.agent.session : AgentSession;
import cydo.config : PathMode;
import cydo.sandbox : ProcessLaunch, cydoBinaryDir, cydoBinaryPath, effectiveEnvValue,
	executableMountPaths, resolveExecutablePath;
import cydo.mcp : McpResult;

// Callback type for dispatching custom tool calls.
alias ToolDispatchFn = Promise!McpResult delegate(string tool, string tid, JSONFragment args);

// ---------------------------------------------------------------------------
// CopilotAgent — Agent descriptor for GitHub Copilot CLI via SDK protocol.
// ---------------------------------------------------------------------------

class CopilotAgent : Agent
{
	private string[string] modelAliasOverrides;
	// Shared SDK process for one-shot requests.
	package SdkProcess sharedSdkServer_;
	package string sharedWorkDir_;
	private string lastMcpConfigPath_;
	// Tool dispatch callback — set externally (e.g., by App) before creating sessions.
	package(cydo) ToolDispatchFn toolDispatch_;
	// Background thread: sessionId → session directory path (populated by enumerateAllSessions)
	private string[string] sessionIdToDirPath_;

	void configureSandbox(ref PathMode[string] paths, ref string[string] env)
	{
		import std.algorithm : startsWith;
		import std.process : environment;

		void addIfNotRw(string path, PathMode mode)
		{
			if (path.length == 0)
				return;
			if (mode == PathMode.ro)
			{
				if (auto existing = path in paths)
					if (*existing == PathMode.rw)
						return;
				foreach (existing, existingMode; paths)
					if (existingMode == PathMode.rw && path.startsWith(existing ~ "/"))
						return;
			}
			paths[path] = mode;
		}

		// Copilot home directory (config, sessions, cache)
		auto home = environment.get("HOME", "/tmp");
		auto copilotHome = environment.get("COPILOT_HOME", buildPath(home, ".copilot"));
		paths[copilotHome] = PathMode.rw;

		foreach (path; executableMountPaths(resolveExecutablePath(executableName(env), env)))
			addIfNotRw(path, PathMode.ro);
		addIfNotRw(cydoBinaryDir(), PathMode.ro);

		// Pass through Copilot-required env vars so they survive --clearenv
		void passthrough(string key)
		{
			if (key in env)
				return;
			auto val = environment.get(key, "");
			if (val.length > 0)
				env[key] = val;
		}

		passthrough("COPILOT_GITHUB_TOKEN");
		passthrough("GH_TOKEN");
		passthrough("GITHUB_TOKEN");
		passthrough("PATH");
		passthrough("COPILOT_HOME");
		passthrough("COPILOT_MODEL");
		passthrough("HTTPS_PROXY");
		passthrough("NODE_TLS_REJECT_UNAUTHORIZED");
	}

	@property string gitName() { return "GitHub Copilot"; }
	@property string gitEmail() { return "noreply@github.com"; }
	@property string lastMcpConfigPath() { return lastMcpConfigPath_; }
	string executableName(string[string] env)
	{
		return effectiveEnvValue(env, "CYDO_COPILOT_BIN", "copilot");
	}

	AgentSession createSession(int tid, string resumeSessionId, ProcessLaunch launch,
		SessionConfig config = SessionConfig.init)
	{
		auto model = config.model.length > 0 ? resolveModelAlias(config.model) : "";
		auto workDir = launch.workDir.length > 0
			? launch.workDir
			: (config.workDir.length > 0 ? config.workDir : ".");

		// Generate MCP config file if a socket path was provided.
		string mcpConfigPath = null;
		if (config.mcpSocketPath.length > 0)
		{
			mcpConfigPath = generateCopilotMcpConfig(tid, config.creatableTaskTypes,
				config.switchModes, config.handoffs, config.includeTools, config.mcpSocketPath);
			lastMcpConfigPath_ = mcpConfigPath;
		}

		// Build CLI args: copilot --headless --no-auto-update --stdio [--additional-mcp-config @<path>]
		auto copilotBin = launch.executablePath.length > 0
			? launch.executablePath
			: executableName(launch.sandbox.env);
		string[] copilotArgs = [copilotBin, "--headless", "--no-auto-update", "--stdio"];
		if (mcpConfigPath !is null)
			copilotArgs ~= ["--additional-mcp-config", "@" ~ mcpConfigPath];

		string[] args;
		if (launch.cmdPrefix !is null)
			args = launch.cmdPrefix ~ copilotArgs;
		else
			args = copilotArgs;

		// Session ID is client-generated for new sessions; for resume use the resume ID.
		import std.uuid : randomUUID;
		auto sessionId = resumeSessionId.length > 0 ? resumeSessionId : randomUUID().toString();

		auto server = new SdkProcess(args, null, null, "copilot");
		sharedSdkServer_ = server;
		sharedWorkDir_ = workDir;
		auto session = new CopilotSession(server, tid, sessionId, model, workDir, launch.cmdPrefix, toolDispatch_);

		// Register before sending create/resume so events can be routed immediately.
		server.registerSession(sessionId, session);

		server.onReady(() {
			if (resumeSessionId.length > 0)
			{
				// session.resume replays history; set replayMode to suppress events.
				session.startReplay();
				server.sendRequest("session.resume",
					buildSessionResumeParams(sessionId, model, config))
				.then((JsonRpcResponse resp) {
					session.onSessionStarted(model, workDir);
				});
			}
			else
			{
				server.sendRequest("session.create",
					buildSessionCreateParams(sessionId, model, workDir, config))
				.then((JsonRpcResponse resp) {
					session.onSessionStarted(model, workDir);
				});
			}
		});

		return session;
	}

	string parseSessionId(string line)
	{
		import std.algorithm : canFind;
		if (!line.canFind(`"session/init"`))
			return null;

		@JSONPartial
		static struct InitProbe
		{
			string type;
			string session_id;
		}

		try
		{
			auto probe = jsonParse!InitProbe(line);
			if (probe.type == "session/init" && probe.session_id.length > 0)
				return probe.session_id;
		}
		catch (Exception) {}
		return null;
	}

	string extractResultText(string line)
	{
		import std.algorithm : canFind;
		if (!line.canFind(`"turn/result"`))
			return "";

		@JSONPartial
		static struct ResultProbe
		{
			string type;
			string result;
		}

		try
		{
			auto probe = jsonParse!ResultProbe(line);
			if (probe.type == "turn/result")
				return probe.result;
		}
		catch (Exception) {}
		return "";
	}

	string extractAssistantText(string line)
	{
		import std.algorithm : canFind;
		if (!line.canFind(`"item/started"`))
			return "";

		@JSONPartial
		static struct ItemStartedProbe { string type; string item_type; string text; }

		try
		{
			auto probe = jsonParse!ItemStartedProbe(line);
			if (probe.type == "item/started" && probe.item_type == "text" && probe.text.length > 0)
				return probe.text;
		}
		catch (Exception) {}
		return "";
	}

	string extractUserText(string line) { return ""; }

	DiscoveredSession[] enumerateAllSessions()
	{
		import std.file : DirEntry, dirEntries, exists, SpanMode;
		import std.path : baseName, buildPath;
		import std.process : environment;

		auto home = environment.get("HOME", "/tmp");
		auto copilotHome = environment.get("COPILOT_HOME", buildPath(home, ".copilot"));
		auto sessionStateDir = buildPath(copilotHome, "session-state");
		if (!exists(sessionStateDir))
			return [];

		sessionIdToDirPath_ = null;
		DiscoveredSession[] result;
		try
		{
			foreach (DirEntry dirEntry; dirEntries(sessionStateDir, SpanMode.shallow))
			{
				if (!dirEntry.isDir)
					continue;
				auto eventsFile = buildPath(dirEntry.name, "events.jsonl");
				if (!exists(eventsFile))
					continue;
				auto sessionId = baseName(dirEntry.name);
				sessionIdToDirPath_[sessionId] = dirEntry.name;
				DiscoveredSession ds;
				ds.sessionId = sessionId;
				import std.file : timeLastModified;
				ds.mtime = timeLastModified(eventsFile).stdTime;
				ds.projectPath = ""; // not derivable
				result ~= ds;
			}
		}
		catch (Exception e)
		{
			import std.logger : tracef;
			tracef("enumerateAllSessions(copilot): error scanning %s: %s", sessionStateDir, e.msg);
		}
		return result;
	}

	SessionMeta readSessionMeta(string sessionId)
	{
		import std.algorithm : canFind;
		import std.path : buildPath;
		import std.stdio : File;
		import cydo.task : truncateTitle;

		auto pathp = sessionId in sessionIdToDirPath_;
		if (pathp is null)
			return SessionMeta.init;

		auto eventsFile = buildPath(*pathp, "events.jsonl");
		SessionMeta meta;
		try
		{
			int lineCount = 0;
			auto f = File(eventsFile, "r");
			foreach (line; f.byLine)
			{
				if (lineCount++ > 50)
					break;
				string lineStr = cast(string) line.idup;
				// Look for working directory in early events
				if (meta.projectPath.length == 0 && lineStr.canFind(`"cwd"`))
				{
					@JSONPartial
					static struct CwdProbe { string cwd; }
					try
					{
						auto probe = jsonParse!CwdProbe(lineStr);
						if (probe.cwd.length > 0)
							meta.projectPath = probe.cwd;
					}
					catch (Exception) {}
				}
				// Look for first user message
				if (meta.title.length == 0 && lineStr.canFind(`"role":"user"`)
					&& lineStr.canFind(`"content"`))
				{
					@JSONPartial
					static struct UserMsgProbe
					{
						string role;
						string content;
					}
					try
					{
						auto probe = jsonParse!UserMsgProbe(lineStr);
						if (probe.role == "user" && probe.content.length > 0)
							meta.title = truncateTitle(probe.content, 80);
					}
					catch (Exception) {}
				}
				if (meta.title.length > 0 && meta.projectPath.length > 0)
					break;
			}
		}
		catch (Exception e)
		{
			import std.logger : tracef;
			tracef("readSessionMeta(copilot, %s): error: %s", sessionId, e.msg);
		}
		return meta;
	}

	string matchProject(string sessionId, const string[] knownProjectPaths) { return ""; }

	void setModelAliases(string[string] aliases)
	{
		modelAliasOverrides = aliases;
	}

	string resolveModelAlias(string modelClass)
	{
		if (auto p = modelClass in modelAliasOverrides)
			return *p;
		switch (modelClass)
		{
			case "small":  return "claude-haiku-4.5";
			case "medium": return "claude-sonnet-4.6";
			case "large":  return "claude-opus-4.6";
			default:       return modelClass; // pass through unknown aliases
		}
	}

	// ---- History / fork ----

	string historyPath(string sessionId, string projectPath)
	{
		import std.process : environment;
		if (sessionId.length == 0)
			return "";
		auto home = environment.get("HOME", "/tmp");
		auto copilotHome = environment.get("COPILOT_HOME", buildPath(home, ".copilot"));
		return buildPath(copilotHome, "session-state", sessionId, "events.jsonl");
	}

	string[] translateHistoryLine(string line, int lineNum)
	{
		import std.algorithm : canFind;
		import std.uuid : randomUUID;
		import cydo.agent.protocol : ItemStartedEvent, ItemCompletedEvent, ItemResultEvent,
			TurnStopEvent, SessionInitEvent, injectRawField;

		if (!line.canFind(`"type":"`))
			return null;

		@JSONPartial
		static struct CpEventBase { string type; string id; }

		CpEventBase base;
		try base = jsonParse!CpEventBase(line);
		catch (Exception)
			return null;

		string[] events;
		switch (base.type)
		{
			case "session.start":
			{
				@JSONPartial static struct CpSessionStartData { string sessionId; string model; string cwd; }
				@JSONPartial static struct CpSessionStartEvent { CpSessionStartData data; }
				CpSessionStartEvent ev;
				try ev = jsonParse!CpSessionStartEvent(line);
				catch (Exception) {}
				SessionInitEvent initEv;
				initEv.session_id      = ev.data.sessionId.length > 0 ? ev.data.sessionId : base.id;
				initEv.model           = ev.data.model;
				initEv.cwd             = ev.data.cwd;
				initEv.tools           = [];
				initEv.agent_version   = "";
				initEv.permission_mode = "dangerously-skip-permissions";
				initEv.agent           = "copilot";
				initEv.supports_file_revert = false;
				events = [toJson(initEv)];
				break;
			}
			case "user.message":
			{
				@JSONPartial static struct CpUserMsgData { string content; }
				@JSONPartial static struct CpUserMsgEvent { CpUserMsgData data; }
				CpUserMsgEvent ev;
				try ev = jsonParse!CpUserMsgEvent(line);
				catch (Exception) {}
				ItemStartedEvent startEv;
				startEv.item_id   = "cp-user-" ~ (base.id.length > 0 ? base.id : randomUUID().toString());
				startEv.item_type = "user_message";
				startEv.text      = ev.data.content;
				startEv.uuid      = base.id;
				events = [toJson(startEv)];
				break;
			}
			case "assistant.message":
			{
				@JSONPartial static struct CpAsstData { string content; }
				@JSONPartial static struct CpAsstEvent { CpAsstData data; }
				CpAsstEvent ev;
				try ev = jsonParse!CpAsstEvent(line);
				catch (Exception) {}
				if (ev.data.content.length == 0)
					return null;
				auto itemId = "cp-text-" ~ randomUUID().toString();
				ItemStartedEvent startEv;
				startEv.item_id   = itemId;
				startEv.item_type = "text";
				startEv.text      = ev.data.content;

				ItemCompletedEvent compEv;
				compEv.item_id = itemId;
				compEv.text    = ev.data.content;

				TurnStopEvent tsEv;
				tsEv.uuid = base.id;
				events = [toJson(startEv), toJson(compEv), toJson(tsEv)];
				break;
			}
			case "tool.execution_start":
			{
				@JSONPartial static struct CpToolStart
				{
					string toolCallId;
					string toolName;
					string mcpToolName;
					string parentToolCallId;
					JSONFragment arguments;
				}
				@JSONPartial static struct CpToolStartEvent { CpToolStart data; }
				CpToolStartEvent ev;
				try ev = jsonParse!CpToolStartEvent(line);
				catch (Exception) {}
				import std.algorithm : startsWith;
				auto toolId = ev.data.toolCallId.length > 0 ? ev.data.toolCallId : base.id;
				auto toolName = ev.data.mcpToolName.length > 0 ? ev.data.mcpToolName
					: ev.data.toolName.length > 0 ? ev.data.toolName : "unknown";
				auto inputFrag = ev.data.arguments;
				string inputJson = inputFrag.json !is null && inputFrag.json.length > 0
					? inputFrag.json : `{}`;

				ItemStartedEvent startEv;
				startEv.item_id   = toolId;
				startEv.item_type = "tool_use";
				if (toolName.startsWith("cydo-"))
				{
					startEv.name        = toolName[5 .. $];
					startEv.tool_server = "cydo";
					startEv.tool_source = "mcp";
				}
				else
					startEv.name = toolName;
				startEv.input     = JSONFragment(inputJson);
				startEv.parent_tool_use_id = ev.data.parentToolCallId;

				events = [toJson(startEv)];
				break;
			}
			case "tool.execution_complete":
			{
				@JSONPartial static struct CpToolComplete { string toolCallId; JSONFragment result; }
				@JSONPartial static struct CpToolCompleteEvent { CpToolComplete data; }
				CpToolCompleteEvent ev;
				try ev = jsonParse!CpToolCompleteEvent(line);
				catch (Exception) {}
				auto toolId = ev.data.toolCallId.length > 0 ? ev.data.toolCallId : base.id;
				string outputText = .extractResultText(ev.data.result);

				ItemCompletedEvent compEv;
				compEv.item_id = toolId;

				ItemResultEvent resEv;
				resEv.item_id = toolId;
				resEv.content = JSONFragment(`[{"type":"text","text":"` ~ cpEscape(outputText) ~ `"}]`);
				events = [toJson(compEv), toJson(resEv)];
				break;
			}
			case "assistant.turn_end":
				events = [`{"type":"turn/result","subtype":"success","is_error":false`
					~ `,"num_turns":1,"duration_ms":0,"total_cost_usd":0`
					~ `,"usage":{"input_tokens":0,"output_tokens":0}}`];
				break;
			case "subagent.started":
			case "permission.completed":
				return null;
			default:
				return null;
		}

		// Attach original JSONL line as _raw on all translated events.
		foreach (ref e; events)
			e = injectRawField(e, line);
		return events;
	}

	string[] translateLiveEvent(string rawLine)
	{
		// Copilot emits agnostic-format events natively (via CopilotSession);
		// only stderr/exit need renaming.  Everything else passes through.
		import std.algorithm : canFind;
		if (rawLine.canFind(`"type":"stderr"`))
			return [replaceTypeField(rawLine, "process/stderr")];
		if (rawLine.canFind(`"type":"exit"`))
			return [replaceTypeField(rawLine, "process/exit")];
		return [rawLine];
	}

	/// Replace the "type" field value in a JSON line.
	private static string replaceTypeField(string rawLine, string newType)
	{
		import std.string : indexOf;
		auto idx = rawLine.indexOf(`"type":"`);
		if (idx < 0) return rawLine;
		auto valStart = idx + `"type":"`.length;
		auto valEnd = rawLine.indexOf(`"`, valStart);
		if (valEnd < 0) return rawLine;
		return rawLine[0 .. valStart] ~ newType ~ rawLine[valEnd .. $];
	}

	bool isTurnResult(string rawLine)
	{
		import std.algorithm : canFind;
		return rawLine.canFind(`"type":"turn/result"`);
	}

	bool isUserMessageLine(string rawLine)
	{
		import std.algorithm : canFind;
		return rawLine.canFind(`"type":"user.message"`);
	}

	bool isAssistantMessageLine(string rawLine)
	{
		import std.algorithm : canFind;
		return rawLine.canFind(`"type":"assistant.message"`);
	}

	string rewriteSessionId(string line, string oldId, string newId)
	{
		// events.jsonl session ID is the directory name, not embedded per-line.
		return line;
	}

	string[] extractForkableIds(string content, int lineOffset = 0)
	{
		import std.algorithm : canFind;
		import std.string : lineSplitter;

		string[] ids;
		foreach (line; content.lineSplitter)
		{
			if (line.length == 0)
				continue;
			if (!line.canFind(`"type":"user.message"`) && !line.canFind(`"type":"assistant.message"`))
				continue;

			@JSONPartial
			static struct IdProbe
			{
				string id;
			}

			try
			{
				auto probe = jsonParse!IdProbe(line);
				if (probe.id.length > 0)
					ids ~= probe.id;
			}
			catch (Exception) {}
		}
		return ids;
	}

	bool forkIdMatchesLine(string line, int lineNum, string forkId)
	{
		@JSONPartial
		static struct IdProbe
		{
			string id;
		}

		try
		{
			auto probe = jsonParse!IdProbe(line);
			return probe.id == forkId;
		}
		catch (Exception)
			return false;
	}

	bool isForkableLine(string line)
	{
		import std.algorithm : canFind;
		return line.canFind(`"type":"user.message"`) || line.canFind(`"type":"assistant.message"`);
	}

	@property bool needsBash() { return true; }
	@property bool supportsFileRevert() { return false; }

	RewindResult rewindFiles(string sessionId, string afterUuid, string cwd,
		ProcessLaunch launch = ProcessLaunch.init)
	{
		return RewindResult(false, "File revert is not supported for Copilot sessions");
	}

	OneShotHandle completeOneShot(string prompt, string modelClass,
		ProcessLaunch launch = ProcessLaunch.init)
	{
		auto p = new Promise!string;
		auto session = new OneShotCopilotSession(p);

		auto model = modelClass.length > 0 ? resolveModelAlias(modelClass) : "";
		auto cwd = launch.workDir.length > 0 ? launch.workDir
			: (sharedWorkDir_.length > 0 ? sharedWorkDir_ : ".");

		import std.uuid : randomUUID;
		auto sessionId = randomUUID().toString();

		// Spawn and wire up our own one-shot SdkProcess.
		void startOwnProcess()
		{
			auto copilotBin = launch.executablePath.length > 0
				? launch.executablePath
				: executableName(launch.sandbox.env);
			string[] copilotArgs = [copilotBin, "--headless", "--no-auto-update", "--stdio"];
			string[] args = launch.cmdPrefix !is null ? launch.cmdPrefix ~ copilotArgs : copilotArgs;
			auto srv = new SdkProcess(args, null, null, "copilot");

			// Set cleanup callback before registering
			session.onFulfill_ = () {
				srv.unregisterSession(sessionId);
				srv.sendRequest("session.destroy",
					`{"sessionId":"` ~ cpEscape(sessionId) ~ `"}`)
				.then((JsonRpcResponse r) { srv.shutdown(); });
			};

			srv.registerSession(sessionId, session);

			srv.onReady(() {
				srv.sendRequest("session.create",
					buildSessionCreateParams(sessionId, model, cwd, SessionConfig.init))
				.then((JsonRpcResponse createResp) {
					srv.sendRequest("session.send",
						`{"sessionId":"` ~ cpEscape(sessionId) ~ `","prompt":"` ~ cpEscape(prompt) ~ `"}`)
					.then((JsonRpcResponse sendResp) {
						// Turn completion via session.idle event → handleEvent → promise fulfilled
					});
				});
			});
		}

		// If the shared server exists and is still initializing, wait for it to
		// reach ready state (extraction complete) before spawning our own process.
		// This avoids the race condition where two copilot processes try to
		// self-extract to the same ~/.cache/copilot/pkg/ directory simultaneously.
		// If the shared server is already ready or doesn't exist, start immediately.
		if (sharedSdkServer_ !is null && !sharedSdkServer_.dead
			&& sharedSdkServer_.state == SdkProcess.State.initializing)
		{
			sharedSdkServer_.onReady(&startOwnProcess);
		}
		else
		{
			startOwnProcess();
		}

		return OneShotHandle(p, null);
	}
}

// ---------------------------------------------------------------------------
// CopilotSession — one Copilot session, implementing AgentSession + SdkSessionHandler.
// ---------------------------------------------------------------------------

class CopilotSession : AgentSession, SdkSessionHandler
{
	private SdkProcess server;
	private int tid;
	private string sessionId;
	private string model;
	private string workDir;
	private string[] cmdPrefix_;
	private bool alive_;
	private bool turnInProgress;
	private bool replayMode; // true during session.resume replay
	private bool gracefulShutdown_; // true after closeStdin() — handleExit reports 0
	private bool forcedStop_;       // true after stop() — handleExit always reports 1
	private ToolDispatchFn toolDispatch_;

	// Streaming state: item tracking for item-based protocol.
	private int nextItemIndex;

	// Active streaming item for text/thinking (sequential — at most one at a time).
	private struct ActiveTextItem
	{
		string id;    // item_id
		string type;  // "text" or "thinking"
		string text;  // accumulated content
		string parentToolCallId; // parent tool_use id for sub-agent nesting
	}
	private ActiveTextItem activeTextItem;

	// In-flight tool calls (parallel — multiple may be active simultaneously).
	private struct ToolItem
	{
		string id;    // item_id (= toolCallId)
		string name;  // tool name
		string input; // tool input JSON
		string text;  // accumulated output (currently unused for streaming)
		string parentToolCallId; // parent tool_use id for sub-agent nesting
		bool externallyHandled;  // completed by handleExternalToolRequested
	}
	private ToolItem[string] activeTools; // keyed by toolCallId

	private string lastResultText;  // last completed text content, for turn/result
	private string currentRawJson_; // raw event data.json from handleEvent, for _raw injection
	private string currentSubagentParent_;  // toolCallId of current sub-agent parent (task tool)

	private bool sessionReady_; // true after session.create/resume response

	// Queued messages waiting for the current turn to finish.
	private ContentBlock[][] pendingMessages;

	// Callbacks
	package void delegate(string line) outputHandler_;
	package void delegate(string line) stderrHandler_;
	private void delegate(int status) exitHandler_;

	this(SdkProcess server, int tid, string sessionId, string model, string workDir,
		string[] cmdPrefix = null, ToolDispatchFn toolDispatch = null)
	{
		this.server = server;
		this.tid = tid;
		this.sessionId = sessionId;
		this.model = model;
		this.workDir = workDir;
		this.cmdPrefix_ = cmdPrefix;
		this.toolDispatch_ = toolDispatch;
		this.alive_ = true;
	}

	/// Called to suppress events during session.resume history replay.
	package void startReplay()
	{
		replayMode = true;
	}

	/// Called when session.create or session.resume response arrives.
	package void onSessionStarted(string m, string wd)
	{
		this.model = m;
		this.workDir = wd;
		replayMode = false; // Done with replay (or was never in it)
		turnInProgress = false;
		sessionReady_ = true;

		// Emit synthetic session/init.
		import cydo.agent.protocol : SessionInitEvent;
		SessionInitEvent initEv;
		initEv.session_id      = sessionId;
		initEv.model           = model;
		initEv.cwd             = workDir;
		initEv.tools           = [];
		initEv.agent_version   = "";
		initEv.permission_mode = "dangerously-skip-permissions";
		initEv.agent           = "copilot";

		emitEvent(toJson(initEv));

		// Drain queued messages now that the session is ready.
		auto queued = pendingMessages;
		pendingMessages = null;
		foreach (msg; queued)
			sendMessage(msg);
	}

	// ----- AgentSession interface -----

	void sendMessage(const(ContentBlock)[] content)
	{
		// Extract text (only text blocks supported; throw on others).
		string text;
		foreach (ref b; content)
		{
			if (b.type == "text") text ~= b.text;
			else throw new Exception("Unsupported content block type for Copilot: " ~ b.type);
		}

		if (!alive_)
			return;

		// Queue message if session hasn't been created yet.
		if (!sessionReady_)
		{
			pendingMessages ~= content.dup;
			return;
		}

		auto escaped = cpEscape(text);

		if (turnInProgress)
		{
			// Steering: buffer message; send after current turn completes.
			pendingMessages ~= content.dup;
		}
		else
		{
			turnInProgress = true;
			nextItemIndex = 0;
			activeTextItem = ActiveTextItem.init;
			activeTools = null;

			// Emit user message item so the frontend confirms the pending placeholder.
			emitEvent(
				`{"type":"item/started","item_id":"cp-user-msg","item_type":"user_message","text":"` ~ escaped ~ `"}`);

			// SDK session.send returns immediately with messageId.
			// Turn completion comes via session.idle event.
			server.sendRequest("session.send",
				`{"sessionId":"` ~ cpEscape(sessionId)
				~ `","prompt":"` ~ escaped ~ `"}`)
			.then((JsonRpcResponse resp) {
				// ACK received — turn is in progress
			});
		}
	}

	@property bool supportsImages() const { return false; }

	void interrupt()
	{
		if (!alive_ || sessionId.length == 0)
			return;
		server.sendRequest("session.abort",
			`{"sessionId":"` ~ cpEscape(sessionId) ~ `"}`)
		.then((JsonRpcResponse resp) {});
	}

	void sigint()
	{
		interrupt();
	}

	void stop()
	{
		if (!alive_)
			return;
		if (sessionId.length > 0)
		{
			server.sendRequest("session.abort",
				`{"sessionId":"` ~ cpEscape(sessionId) ~ `"}`)
			.then((JsonRpcResponse resp) {});
		}
		alive_ = false;
		forcedStop_ = true;
		server.shutdown();
	}

	void closeStdin()
	{
		if (!alive_)
			return;
		if (sessionId.length > 0)
		{
			server.sendRequest("session.abort",
				`{"sessionId":"` ~ cpEscape(sessionId) ~ `"}`)
			.then((JsonRpcResponse resp) {});
		}
		alive_ = false;
		gracefulShutdown_ = true;
		server.shutdown();
	}

	void killAfterTimeout(Duration timeout) {} // no-op: server.shutdown handles graceful exit

	@property void onOutput(void delegate(string line) dg) { outputHandler_ = dg; }
	@property void onStderr(void delegate(string line) dg) { stderrHandler_ = dg; }
	@property void onExit(void delegate(int status) dg) { exitHandler_ = dg; }
	@property bool alive() { return alive_ && !server.dead; }

	// ----- SdkSessionHandler interface -----

	void handleEvent(SdkEvent event)
	{
		if (!alive_)
			return;
		if (replayMode)
			return;

		currentRawJson_ = event.data.json;
		switch (event.type)
		{
			case "assistant.turn_start":
				handleTurnStart(event.data);
				break;
			case "assistant.message_delta":
				handleMessageDelta(event.data);
				break;
			case "assistant.message":
				handleAssistantMessage(event.data);
				break;
			case "assistant.reasoning_delta":
				handleReasoningDelta(event.data);
				break;
			case "tool.execution_start":
				handleToolExecutionStart(event.data);
				break;
			case "tool.execution_complete":
				handleToolExecutionComplete(event.data);
				break;
			case "user.message":
				handleUserMessage(event.data);
				break;
			case "session.idle":
				handleTurnCompleted("end_turn");
				break;
			case "session.start":
				handleSessionStart(event.data);
				break;
			case "session.resume":
				handleSessionResume(event.data);
				break;
			case "session.error":
				handleSessionError(event.data);
				break;
			case "external_tool.requested":
				handleExternalToolRequested(event.data);
				break;
			case "permission.requested":
				handlePermissionRequested(event.data);
				break;
			case "subagent.started":
				handleSubagentStarted(event.data);
				break;
			case "plan":
			case "available_commands_update":
			case "config_option_update":
			case "current_mode_update":
			case "session_info_update":
			case "usage_update":
			case "pending_messages.modified":
			case "session.title_changed":
			case "session.tools_updated":
			case "session.usage_info":
			case "assistant.turn_end":
			case "assistant.streaming_delta":
			case "assistant.usage":
			case "external_tool.completed":
			case "permission.completed":
				break;
			default:
				import cydo.agent.protocol : makeUnrecognizedEvent;
				emitEvent(makeUnrecognizedEvent(
					"unknown copilot event: " ~ event.type,
					event.data.json), currentRawJson_);
				break;
		}
	}

	Promise!SdkPermissionResult handlePermissionRequest(SdkPermissionRequest params)
	{
		// Auto-approve all permissions (same policy as prior ACP implementation).
		return resolve(SdkPermissionResult("approved"));
	}

	Promise!SdkToolCallResult handleToolCall(SdkToolCallRequest params)
	{
		if (toolDispatch_ is null)
			return resolve(SdkToolCallResult(SdkToolResult(
				"Tool dispatch not configured", "failure")));

		import std.algorithm : startsWith;

		// Strip cydo- prefix so the backend dispatcher sees canonical names
		// (e.g., "cydo-Task" → "Task", "cydo-Bash" → "Bash").
		auto toolName = params.toolName;
		if (toolName.startsWith("cydo-"))
			toolName = toolName[5 .. $];

		auto result = new Promise!SdkToolCallResult;
		toolDispatch_(toolName, to!string(tid), params.arguments)
		.then((McpResult mcpResult) {
			result.fulfill(SdkToolCallResult(SdkToolResult(
				mcpResult.text,
				mcpResult.isError ? "failure" : "success")));
		}, (Exception e) {
			result.fulfill(SdkToolCallResult(SdkToolResult(e.msg, "failure")));
		});
		return result;
	}

	/// Handle external_tool.requested session event (protocol v3).
	/// The copilot binary dispatches custom tool calls as broadcast events
	/// instead of tool.call JSON-RPC requests.  We execute the tool via the
	/// same dispatch path as handleToolCall and send the result back via
	/// session.tools.handlePendingToolCall.
	///
	/// We also emit item/started here so the UI shows the tool call immediately.
	/// After the tool resolves we emit item/completed + item/result and mark
	/// the tool as externallyHandled so that any subsequent tool.execution_start
	/// event (which Copilot fires for MCP tools after receiving the result) is
	/// silently ignored instead of creating a duplicate UI entry.
	private void handleExternalToolRequested(JSONFragment data)
	{
		import std.algorithm : startsWith;

		if (toolDispatch_ is null)
			return;

		@JSONPartial static struct ExtToolReq
		{
			string requestId;
			string toolName;
			JSONFragment arguments;
		}

		ExtToolReq req;
		try req = jsonParse!ExtToolReq(data.json);
		catch (Exception) return;

		if (req.requestId.length == 0 || req.toolName.length == 0)
			return;

		// Strip cydo- prefix for backend dispatch (same as handleToolCall).
		auto dispatchName = req.toolName;
		if (dispatchName.startsWith("cydo-"))
			dispatchName = dispatchName[5 .. $];
		auto displayName = req.toolName;
		bool isCydo = displayName.startsWith("cydo-");
		if (isCydo)
			displayName = displayName[5 .. $];

		// Set up a tool item for UI rendering before the async dispatch.
		// If handleToolExecutionStart already created an entry for the
		// same tool (race: events arrive via different I/O channels), reuse
		// it instead of creating a duplicate.
		string inputJson = req.arguments.json !is null && req.arguments.json.length > 0
			? req.arguments.json : "{}";

		// Look for an existing tool entry that matches (by name, not yet externally handled).
		string itemId;
		bool found;
		foreach (ref tool; activeTools)
		{
			if (tool.name == displayName && !tool.externallyHandled)
			{
				tool.externallyHandled = true;
				itemId = tool.id;
				found = true;
				break;
			}
		}
		if (!found)
		{
			finalizeActiveTextItem();
			itemId = "cp-ext-" ~ req.requestId;
			activeTools[itemId] = ToolItem(itemId, displayName, inputJson, "", "", true);
			emitEvent(
				`{"type":"item/started","item_id":"` ~ cpEscape(itemId)
				~ `","item_type":"tool_use","name":"` ~ cpEscape(displayName)
				~ (isCydo ? `","tool_server":"cydo","tool_source":"mcp` : "")
				~ `","input":` ~ inputJson ~ `}`, currentRawJson_);
		}
		auto rawJson = currentRawJson_; // capture before async dispatch

		toolDispatch_(dispatchName, to!string(tid), req.arguments)
		.then((McpResult mcpResult) {
			// Emit completion events for the UI.
			emitEvent(
				`{"type":"item/completed","item_id":"` ~ cpEscape(itemId)
				~ `","input":` ~ inputJson ~ `}`, rawJson);
			emitEvent(
				`{"type":"item/result","item_id":"` ~ cpEscape(itemId)
				~ `","content":"` ~ cpEscape(mcpResult.text) ~ `"}`, rawJson);

			auto resultType = mcpResult.isError ? "failure" : "success";
			auto escaped = cpEscape(mcpResult.text);
			auto params = `{"sessionId":"` ~ cpEscape(sessionId)
				~ `","requestId":"` ~ cpEscape(req.requestId)
				~ `","result":{"textResultForLlm":"` ~ escaped
				~ `","resultType":"` ~ resultType ~ `"}}`;
			server.sendRequest("session.tools.handlePendingToolCall", params);
		}, (Exception e) {
			auto escaped = cpEscape(e.msg);
			auto params = `{"sessionId":"` ~ cpEscape(sessionId)
				~ `","requestId":"` ~ cpEscape(req.requestId)
				~ `","error":"` ~ escaped ~ `"}`;
			server.sendRequest("session.tools.handlePendingToolCall", params);
		});
	}

	/// Handle permission.requested session event (protocol v3).
	/// Copilot broadcasts permission requests as events instead of the older
	/// permission.request JSON-RPC method.  Auto-approve all requests.
	private void handlePermissionRequested(JSONFragment data)
	{
		@JSONPartial static struct PermReq
		{
			string requestId;
			bool resolvedByHook;
		}

		PermReq req;
		try req = jsonParse!PermReq(data.json);
		catch (Exception) return;

		if (req.requestId.length == 0)
			return;

		// Already resolved by a hook — no response needed.
		if (req.resolvedByHook)
			return;

		auto params = `{"sessionId":"` ~ cpEscape(sessionId)
			~ `","requestId":"` ~ cpEscape(req.requestId)
			~ `","result":{"kind":"approved"}}`;
		server.sendRequest("session.permissions.handlePendingPermissionRequest", params);
	}

	/// Handle subagent.started — set the current sub-agent parent context
	/// so subsequent text/thinking/tool events are nested under the parent
	/// task tool call.
	private void handleSubagentStarted(JSONFragment data)
	{
		@JSONPartial static struct SubagentStarted
		{
			string toolCallId;
			string agentName;
		}
		SubagentStarted sa;
		try sa = jsonParse!SubagentStarted(data.json);
		catch (Exception) return;

		currentSubagentParent_ = sa.toolCallId;
	}

	void handleStderr(string line)
	{
		if (stderrHandler_)
			stderrHandler_(line);
	}

	void handleExit(int status)
	{
		if (exitHandler_ is null)
			return;
		auto cb = exitHandler_;
		exitHandler_ = null;
		alive_ = false;
		int code = gracefulShutdown_ ? 0 : (forcedStop_ ? 1 : status);
		cb(code);
	}

	// ----- Event handlers -----

	private void emitEvent(string translated, string rawJson = null)
	{
		if (outputHandler_)
		{
			if (rawJson.length > 0)
			{
				import cydo.agent.protocol : injectRawField;
				outputHandler_(injectRawField(translated, rawJson));
			}
			else
				outputHandler_(translated);
		}
	}

	private void handleTurnStart(JSONFragment data)
	{
		turnInProgress = true;
		nextItemIndex = 0;
		activeTextItem = ActiveTextItem.init;
		activeTools = null;
		lastResultText = null;
		currentSubagentParent_ = null;
	}

	private void handleMessageDelta(JSONFragment data)
	{
		@JSONPartial static struct MsgDelta { string deltaContent; }
		MsgDelta d;
		try d = jsonParse!MsgDelta(data.json);
		catch (Exception) return;

		auto text = d.deltaContent;

		// Start a new text item if we don't have an active one.
		if (activeTextItem.type != "text")
		{
			finalizeActiveTextItem();
			auto id = "cp-text-" ~ to!string(nextItemIndex++);
			activeTextItem = ActiveTextItem(id, "text", "", currentSubagentParent_);
			string parentField = currentSubagentParent_.length > 0
				? `","parent_tool_use_id":"` ~ cpEscape(currentSubagentParent_) : "";
			emitEvent(
				`{"type":"item/started","item_id":"` ~ cpEscape(id)
				~ `","item_type":"text` ~ parentField ~ `"}`, currentRawJson_);
		}

		activeTextItem.text ~= text;

		if (text.length > 0)
			emitEvent(
				`{"type":"item/delta","item_id":"` ~ cpEscape(activeTextItem.id)
				~ `","delta_type":"text_delta","content":"` ~ cpEscape(text) ~ `"}`, currentRawJson_);
	}

	private void handleReasoningDelta(JSONFragment data)
	{
		@JSONPartial static struct ReasoningDelta { string deltaContent; }
		ReasoningDelta d;
		try d = jsonParse!ReasoningDelta(data.json);
		catch (Exception) return;

		auto text = d.deltaContent;

		// Start a new thinking item if we don't have an active one.
		if (activeTextItem.type != "thinking")
		{
			finalizeActiveTextItem();
			auto id = "cp-think-" ~ to!string(nextItemIndex++);
			activeTextItem = ActiveTextItem(id, "thinking", "", currentSubagentParent_);
			string parentField = currentSubagentParent_.length > 0
				? `","parent_tool_use_id":"` ~ cpEscape(currentSubagentParent_) : "";
			emitEvent(
				`{"type":"item/started","item_id":"` ~ cpEscape(id)
				~ `","item_type":"thinking` ~ parentField ~ `"}`, currentRawJson_);
		}

		activeTextItem.text ~= text;

		if (text.length > 0)
			emitEvent(
				`{"type":"item/delta","item_id":"` ~ cpEscape(activeTextItem.id)
				~ `","delta_type":"thinking_delta","content":"` ~ cpEscape(text) ~ `"}`, currentRawJson_);
	}

	private void handleToolExecutionStart(JSONFragment data)
	{
		@JSONPartial static struct ToolStart
		{
			string toolCallId;
			string toolName;
			string parentToolCallId;
			JSONFragment arguments;
		}
		ToolStart ts;
		try ts = jsonParse!ToolStart(data.json);
		catch (Exception) return;

		// Skip if this tool was already handled by handleExternalToolRequested.
		if (auto p = ts.toolCallId in activeTools)
		{
			if (p.externallyHandled)
			{
				activeTools.remove(ts.toolCallId);
				return;
			}
		}

		// Finalize any active text/thinking item (tools don't interrupt each other).
		finalizeActiveTextItem();

		import std.algorithm : startsWith;

		auto id = ts.toolCallId;
		auto name = ts.toolName;
		string toolServer;
		string toolSource;
		if (name.startsWith("cydo-"))
		{
			toolServer = "cydo";
			toolSource = "mcp";
			name = name[5 .. $];
		}
		string inputJson = ts.arguments.json !is null && ts.arguments.json.length > 0
			? ts.arguments.json : "{}";

		activeTools[id] = ToolItem(id, name, inputJson, "", ts.parentToolCallId);

		string parentField = ts.parentToolCallId.length > 0
			? `","parent_tool_use_id":"` ~ cpEscape(ts.parentToolCallId) : "";
		emitEvent(
			`{"type":"item/started","item_id":"` ~ cpEscape(id)
			~ `","item_type":"tool_use","name":"` ~ cpEscape(name)
			~ (toolServer.length > 0 ? `","tool_server":"cydo","tool_source":"mcp` : "")
			~ parentField
			~ `","input":` ~ inputJson ~ `}`, currentRawJson_);

		// Emit the full input as a single input_json_delta so the UI can
		// display it during streaming.
		if (inputJson.length > 0 && inputJson != "{}")
			emitEvent(
				`{"type":"item/delta","item_id":"` ~ cpEscape(id)
				~ `","delta_type":"input_json_delta","content":"` ~ cpEscape(inputJson) ~ `"}`, currentRawJson_);
	}

	private void handleToolExecutionComplete(JSONFragment data)
	{
		@JSONPartial static struct ToolComplete { string toolCallId; bool success; JSONFragment result; }
		ToolComplete tc;
		try tc = jsonParse!ToolComplete(data.json);
		catch (Exception) return;

		auto p = tc.toolCallId in activeTools;
		if (p is null || p.externallyHandled)
			return;

		// Extract result text: may be a plain string or an object with a
		// "content" / "detailedContent" field (e.g. bash tool results).
		string resultText = extractResultText(tc.result);
		if (resultText.length > 0)
			p.text = resultText;

		// Emit item/completed with final input.
		emitEvent(
			`{"type":"item/completed","item_id":"` ~ cpEscape(p.id)
			~ `","input":` ~ (p.input.length > 0 ? p.input : `{}`) ~ `}`, currentRawJson_);
		// Emit item/result with tool output.
		emitEvent(
			`{"type":"item/result","item_id":"` ~ cpEscape(p.id)
			~ `","content":"` ~ cpEscape(p.text) ~ `"}`, currentRawJson_);
		activeTools.remove(tc.toolCallId);
	}

	private void handleAssistantMessage(JSONFragment data)
	{
		// Option B: synthesize message/assistant from completedItems in handleTurnCompleted.
		// The SDK assistant.message event is not used directly.
	}

	private void handleUserMessage(JSONFragment data)
	{
		// Suppress: sendMessage() already emits the user echo.  Copilot's
		// user.message event is a redundant echo that would create a
		// duplicate user message in the frontend.
	}

	private void handleSessionStart(JSONFragment data)
	{
		// session/init already emitted by onSessionStarted; nothing to do here.
	}

	private void handleSessionResume(JSONFragment data)
	{
		// Replay complete — re-enable live event processing.
		replayMode = false;
	}

	private void handleSessionError(JSONFragment data)
	{
		@JSONPartial static struct SessErr { string message; }
		SessErr se;
		try se = jsonParse!SessErr(data.json);
		catch (Exception) {}
		emitEvent(
			`{"type":"process/stderr","text":"Copilot error: ` ~ cpEscape(se.message) ~ `"}`, currentRawJson_);
	}

	// ----- Turn completion -----

	private void handleTurnCompleted(string stopReason)
	{
		// Finalize any still-active text/thinking item.
		finalizeActiveTextItem();
		// Finalize any remaining in-flight tools (shouldn't happen normally,
		// but cleans up if turn ends before tool.execution_complete arrives).
		finalizeAllTools();

		turnInProgress = false;

		// 1. turn/stop
		emitEvent(`{"type":"turn/stop","model":"` ~ cpEscape(model) ~ `"}`, currentRawJson_);

		// 2. turn/result
		string subtype;
		switch (stopReason)
		{
			case "end_turn":  subtype = "success";  break;
			case "cancelled": subtype = "cancelled"; break;
			default:          subtype = "unknown";   break;
		}
		// Include the last text item as "result" so extractResultText can retrieve it.
		emitEvent(
			`{"type":"turn/result","subtype":"` ~ subtype ~ `"`
			~ `,"is_error":false,"num_turns":1,"duration_ms":0,"total_cost_usd":0`
			~ (lastResultText.length > 0 ? `,"result":"` ~ cpEscape(lastResultText) ~ `"` : "")
			~ `,"usage":{"input_tokens":0,"output_tokens":0}}`, currentRawJson_);
		lastResultText = null;

		// Drain pending messages (steering).
		if (pendingMessages.length > 0)
		{
			auto next = pendingMessages[0];
			pendingMessages = pendingMessages[1 .. $];
			sendMessage(next);
		}
	}

	/// Finalize the active text/thinking item: emit item/completed.
	/// No-op if there is no active text item.
	private void finalizeActiveTextItem()
	{
		if (activeTextItem.type.length == 0)
			return;

		if (activeTextItem.type == "text")
			lastResultText = activeTextItem.text;
		emitEvent(
			`{"type":"item/completed","item_id":"` ~ cpEscape(activeTextItem.id)
			~ `","text":"` ~ cpEscape(activeTextItem.text) ~ `"}`, currentRawJson_);

		activeTextItem = ActiveTextItem.init;
	}

	/// Finalize all remaining in-flight tools (at turn end).
	private void finalizeAllTools()
	{
		foreach (ref tool; activeTools)
		{
			if (tool.externallyHandled)
				continue;
			emitEvent(
				`{"type":"item/completed","item_id":"` ~ cpEscape(tool.id)
				~ `","input":` ~ (tool.input.length > 0 ? tool.input : `{}`) ~ `}`, currentRawJson_);
			emitEvent(
				`{"type":"item/result","item_id":"` ~ cpEscape(tool.id)
				~ `","content":"` ~ cpEscape(tool.text) ~ `"}`, currentRawJson_);
		}
		activeTools = null;
	}
}

// ---------------------------------------------------------------------------
// OneShotCopilotSession — minimal SdkSessionHandler for completeOneShot.
// ---------------------------------------------------------------------------

private final class OneShotCopilotSession : SdkSessionHandler
{
	private string text_;
	private bool fulfilled_;
	private Promise!string promise_;
	package void delegate() onFulfill_;

	this(Promise!string p) { promise_ = p; }

	void handleEvent(SdkEvent event)
	{
		switch (event.type)
		{
			case "assistant.message_delta":
			{
				@JSONPartial static struct OneShotDelta { string deltaContent; }
				OneShotDelta d;
				try d = jsonParse!OneShotDelta(event.data.json);
				catch (Exception) return;
				text_ ~= d.deltaContent;
				break;
			}
			case "session.idle":
				if (!fulfilled_)
				{
					fulfilled_ = true;
					if (onFulfill_) onFulfill_();
					promise_.fulfill(text_);
				}
				break;
			case "permission.requested":
				break; // One-shot sessions can't respond; tools are not used.
			default:
				break;
		}
	}

	Promise!SdkPermissionResult handlePermissionRequest(SdkPermissionRequest params)
	{
		return resolve(SdkPermissionResult("approved"));
	}

	Promise!SdkToolCallResult handleToolCall(SdkToolCallRequest params)
	{
		return resolve(SdkToolCallResult(SdkToolResult(
			"Tool calls not supported in one-shot mode", "failure")));
	}

	void handleStderr(string line)
	{
		import std.stdio : stderr;
		stderr.writeln("[one-shot-sdk/stderr] " ~ line);
	}

	void handleExit(int status)
	{
		if (!fulfilled_)
		{
			import std.stdio : stderr;
			stderr.writeln("[one-shot-sdk] process exited status=" ~ to!string(status) ~ " before session.idle");
			fulfilled_ = true;
			promise_.reject(new Exception(
				"completeOneShot: process exited with status " ~ to!string(status)));
		}
	}
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

private:

/// Build tool definitions JSON array for session.create params.
/// Only includes tools if an MCP socket is configured (tools backend is available).
/// Tool names use `cydo-` prefix to avoid collisions with built-in or third-party tools.
/// The prefix is stripped to canonical names for dispatch (handleToolCall), and structured
/// tool_server/tool_source fields are set for UI events.
string buildToolDefinitions(SessionConfig config)
{
	if (config.mcpSocketPath.length == 0)
		return "[]";

	// Names use cydo- prefix to match what the LLM sends in tool_calls.
	return `[`
		~ `{"name":"cydo-Task","description":"Create sub-tasks that run autonomously","parameters":`
		~ `{"type":"object","properties":{"tasks":{"type":"array","items":{"type":"object"}}}`
		~ `,"required":["tasks"]},"skipPermission":true}`
		~ `,{"name":"cydo-Bash","description":"Execute a shell command and return its output","parameters":`
		~ `{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}`
		~ `,"skipPermission":true}`
		~ `,{"name":"cydo-SwitchMode","description":"Switch this task to a different mode","parameters":`
		~ `{"type":"object","properties":{"continuation":{"type":"string"}},"required":["continuation"]}`
		~ `,"skipPermission":true}`
		~ `,{"name":"cydo-Handoff","description":"Hand off this task to a successor","parameters":`
		~ `{"type":"object","properties":{"continuation":{"type":"string"},"prompt":{"type":"string"}}`
		~ `,"required":["continuation","prompt"]},"skipPermission":true}`
		~ `,{"name":"cydo-AskUserQuestion","description":"Ask the user one or more questions","parameters":`
		~ `{"type":"object","properties":{"questions":{"type":"array","items":{"type":"object"}}}`
		~ `,"required":["questions"]},"skipPermission":true}`
		~ `,{"name":"cydo-Ask","description":"Ask a question to a related task and wait for the answer","parameters":`
		~ `{"type":"object","properties":{"message":{"type":"string"},"tid":{"type":"integer"}}`
		~ `,"required":["message"]},"skipPermission":true}`
		~ `,{"name":"cydo-Answer","description":"Answer a question from a related task","parameters":`
		~ `{"type":"object","properties":{"qid":{"type":"integer"},"message":{"type":"string"}}`
		~ `,"required":["qid","message"]},"skipPermission":true}`
		~ `]`;
}

/// Build JSON params string for session.create.
string buildSessionCreateParams(string sessionId, string model, string workDir, SessionConfig config)
{
	auto tools = buildToolDefinitions(config);
	auto modelPart = model.length > 0 ? `,"model":"` ~ cpEscape(model) ~ `"` : "";
	auto systemMsg = config.appendSystemPrompt.length > 0
		? `,"systemMessage":{"mode":"append","content":"` ~ cpEscape(config.appendSystemPrompt) ~ `"}`
		: "";
	return `{"sessionId":"` ~ cpEscape(sessionId) ~ `"`
		~ modelPart
		~ `,"clientName":"cydo"`
		~ `,"workingDirectory":"` ~ cpEscape(workDir) ~ `"`
		~ `,"streaming":true`
		~ `,"requestPermission":true`
		~ `,"tools":` ~ tools
		~ systemMsg
		~ `}`;
}

/// Build JSON params string for session.resume.
string buildSessionResumeParams(string sessionId, string model, SessionConfig config)
{
	auto tools = buildToolDefinitions(config);
	auto modelPart = model.length > 0 ? `,"model":"` ~ cpEscape(model) ~ `"` : "";
	auto systemMsg = config.appendSystemPrompt.length > 0
		? `,"systemMessage":{"mode":"append","content":"` ~ cpEscape(config.appendSystemPrompt) ~ `"}`
		: "";
	return `{"sessionId":"` ~ cpEscape(sessionId) ~ `"`
		~ modelPart
		~ `,"streaming":true`
		~ `,"requestPermission":true`
		~ `,"tools":` ~ tools
		~ systemMsg
		~ `}`;
}

/// Generate a temporary MCP config file for Copilot's --additional-mcp-config flag.
string generateCopilotMcpConfig(int tid, string creatableTaskTypes,
	string switchModes, string handoffs, string[] includeTools, string mcpSocketPath)
{
	import std.array : join;
	import std.file : exists, mkdirRecurse, write;

	auto cydoBin = cydoBinaryPath;
	if (cydoBin.length == 0)
		return null;

	import std.process : environment;
	auto home = environment.get("HOME", "/tmp");
	auto copilotHome = environment.get("COPILOT_HOME", buildPath(home, ".copilot"));
	auto configDir = buildPath(copilotHome, "mcp-configs");
	if (!exists(configDir))
		mkdirRecurse(configDir);

	auto configPath = buildPath(configDir, "cydo-" ~ to!string(tid) ~ ".json");

	auto config = `{"mcpServers":{"cydo":{"command":"`
		~ cpEscape(cydoBin) ~ `","args":["mcp-server"],"env":{"CYDO_TID":"`
		~ to!string(tid) ~ `","CYDO_SOCKET":"`
		~ cpEscape(mcpSocketPath) ~ `","CYDO_CREATABLE_TYPES":"`
		~ cpEscape(creatableTaskTypes) ~ `","CYDO_SWITCHMODES":"`
		~ cpEscape(switchModes) ~ `","CYDO_HANDOFFS":"`
		~ cpEscape(handoffs) ~ `","CYDO_INCLUDE_TOOLS":"`
		~ cpEscape(includeTools is null ? "" : includeTools.join(",")) ~ `"}}}}`;

	write(configPath, config);
	return configPath;
}

/// Extract plain text from a tool result JSONFragment.
/// Handles both plain JSON strings and objects with a "content" or
/// "detailedContent" field (e.g. bash tool results from Copilot SDK).
string extractResultText(JSONFragment frag)
{
	if (frag.json.length == 0)
		return "";
	// Try as plain string first.
	try return jsonParse!string(frag.json);
	catch (Exception) {}
	// Try as object with content/detailedContent fields.
	@JSONPartial static struct ResultObj { string content; string detailedContent; }
	try
	{
		auto obj = jsonParse!ResultObj(frag.json);
		if (obj.content.length > 0)
			return obj.content;
		if (obj.detailedContent.length > 0)
			return obj.detailedContent;
	}
	catch (Exception) {}
	return "";
}

/// Escape a string for embedding in JSON.
string cpEscape(string s)
{
	import std.array : replace;
	return s
		.replace(`\`, `\\`)
		.replace(`"`, `\"`)
		.replace("\n", `\n`)
		.replace("\r", `\r`)
		.replace("\t", `\t`);
}
