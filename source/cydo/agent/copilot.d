module cydo.agent.copilot;

import std.conv : to;
import std.format : format;
import std.path : buildPath, dirName, expandTilde;
import ae.utils.json : JSONFragment, JSONPartial, jsonParse, toJson;
import ae.utils.jsonrpc : JsonRpcResponse;
import ae.utils.promise : Promise, resolve;

import cydo.agent.acp : AcpProcess, AcpSessionHandler,
	EmptyResult, TerminalCreateParams, TerminalCreateResult,
	TerminalIdParams, TerminalOutputResult, TerminalExitResult;
import cydo.agent.agent : Agent, SessionConfig;
import cydo.agent.session : AgentSession;
import cydo.agent.terminal : TerminalProcess;
import cydo.config : PathMode;

// ---------------------------------------------------------------------------
// CopilotAgent — Agent descriptor for GitHub Copilot CLI via ACP.
// ---------------------------------------------------------------------------

class CopilotAgent : Agent
{
	private string lastMcpConfigPath_;
	private string[string] modelAliasOverrides;
	// Shared ACP process for one-shot requests (reuses the main session's process).
	package AcpProcess sharedAcpServer_;
	package string sharedWorkDir_;

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

		addIfNotRw(resolveCopilotBinary(), PathMode.ro);
		addIfNotRw(cydoBinaryDir(), PathMode.ro);

		// Pass through Copilot-required env vars so they survive --clearenv
		void passthrough(string key)
		{
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

	AgentSession createSession(int tid, string resumeSessionId, string[] bwrapPrefix,
		SessionConfig config = SessionConfig.init)
	{
		auto model = config.model.length > 0 ? resolveModelAlias(config.model) : "";
		auto workDir = config.workDir.length > 0 ? config.workDir : ".";

		// Generate MCP config file if a socket path was provided.
		string mcpConfigPath = null;
		if (config.mcpSocketPath.length > 0)
		{
			mcpConfigPath = generateCopilotMcpConfig(tid, config.creatableTaskTypes,
				config.switchModes, config.handoffs, config.includeTools, config.mcpSocketPath);
			lastMcpConfigPath_ = mcpConfigPath;
		}

		// Build CLI args: copilot --acp --yolo [--model <model>] [--additional-mcp-config @<path>]
		string[] copilotArgs = [getCopilotBinName(), "--acp", "--yolo"];
		if (model.length > 0)
			copilotArgs ~= ["--model", model];
		if (mcpConfigPath !is null)
			copilotArgs ~= ["--additional-mcp-config", "@" ~ mcpConfigPath];

		string[] args;
		if (bwrapPrefix !is null)
			args = bwrapPrefix ~ copilotArgs;
		else
			args = copilotArgs;

		auto server = new AcpProcess(args, null, null);
		sharedAcpServer_ = server;
		sharedWorkDir_ = workDir;
		auto session = new CopilotSession(server, tid, model, workDir, bwrapPrefix);

		server.onReady(() {
			if (resumeSessionId.length > 0)
			{
				// session/load replays history; set replayMode to suppress events.
				session.startReplay();
				server.sendRequest("session/load",
					`{"sessionId":"` ~ cpEscape(resumeSessionId) ~ `","cwd":"` ~ cpEscape(workDir) ~ `","mcpServers":[]}`)
				.then((JsonRpcResponse resp) {
					session.onSessionStarted(
						resp.result.json !is null ? resp.result.json : "{}",
						resumeSessionId, model, workDir);
				});
			}
			else
			{
				server.sendRequest("session/new",
					`{"cwd":"` ~ cpEscape(workDir) ~ `","mcpServers":[]}`)
				.then((JsonRpcResponse resp) {
					session.onSessionStarted(
						resp.result.json !is null ? resp.result.json : "{}",
						null, model, workDir);
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
			case "large":  return "claude-sonnet-4.6";
			default:       return modelClass; // pass through unknown aliases
		}
	}

	// ---- History / fork — stubs (implemented in a later sub-task) ----

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
			TurnStopEvent, SessionInitEvent;

		if (!line.canFind(`"type":"`))
			return null;

		@JSONPartial
		static struct CpEventBase { string type; string id; }

		CpEventBase base;
		try base = jsonParse!CpEventBase(line);
		catch (Exception)
			return null;

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
				return [toJson(initEv)];
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
				return [toJson(startEv)];
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
				return [toJson(startEv), toJson(compEv), toJson(tsEv)];
			}
			case "tool.execution_start":
			{
				// JSONL format uses toolName/mcpToolName/arguments,
				// NOT the ACP live fields (title/kind/rawInput).
				@JSONPartial static struct CpToolStart
				{
					string toolCallId;
					string toolName;
					string mcpToolName;
					string kind;
					string title;
					JSONFragment arguments;
					JSONFragment rawInput;
				}
				@JSONPartial static struct CpToolStartEvent { CpToolStart data; }
				CpToolStartEvent ev;
				try ev = jsonParse!CpToolStartEvent(line);
				catch (Exception) {}
				auto toolId = ev.data.toolCallId.length > 0 ? ev.data.toolCallId : base.id;
				// Prefer mcpToolName, then toolName, then ACP fallback.
				auto toolName = ev.data.mcpToolName.length > 0 ? ev.data.mcpToolName
					: ev.data.toolName.length > 0 ? ev.data.toolName
					: mapKindToName(ev.data.kind, ev.data.title);
				// JSONL uses "arguments", ACP uses "rawInput".
				auto inputFrag = ev.data.arguments.json !is null && ev.data.arguments.json.length > 0
					? ev.data.arguments : ev.data.rawInput;
				string inputJson = inputFrag.json !is null && inputFrag.json.length > 0
					? inputFrag.json : `{}`;

				ItemStartedEvent startEv;
				startEv.item_id   = toolId;
				startEv.item_type = "tool_use";
				startEv.name      = toolName;
				startEv.input     = JSONFragment(inputJson);

				ItemCompletedEvent compEv;
				compEv.item_id = toolId;
				compEv.input   = JSONFragment(inputJson);

				events = [toJson(startEv), toJson(compEv)];
				break;
			}
			case "tool.execution_complete":
			{
				@JSONPartial static struct CpResultInner { string text; }
				@JSONPartial static struct CpResultContent { string type; CpResultInner content; }
				@JSONPartial static struct CpToolComplete { string toolCallId; CpResultContent[] content; }
				@JSONPartial static struct CpToolCompleteEvent { CpToolComplete data; }
				CpToolCompleteEvent ev;
				try ev = jsonParse!CpToolCompleteEvent(line);
				catch (Exception) {}
				auto toolId = ev.data.toolCallId.length > 0 ? ev.data.toolCallId : base.id;
				string outputText;
				foreach (ref ci; ev.data.content)
					if (ci.type == "content")
						outputText ~= ci.content.text;

				ItemResultEvent resEv;
				resEv.item_id = toolId;
				resEv.content = JSONFragment(`"` ~ cpEscape(outputText) ~ `"`);
				return [toJson(resEv)];
			}
			case "assistant.turn_end":
				return [`{"type":"turn/result","subtype":"success","is_error":false`
					~ `,"num_turns":1,"duration_ms":0,"total_cost_usd":0`
					~ `,"usage":{"input_tokens":0,"output_tokens":0}}`];
			default:
				return null;
		}
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
		// Fast string-level replacement: find "type":"…" and swap the value.
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

	string rewindFiles(string sessionId, string afterUuid, string cwd)
	{
		return "File revert is not supported for Copilot sessions";
	}

	Promise!string completeOneShot(string prompt, string modelClass)
	{
		auto p = new Promise!string;
		auto session = new OneShotCopilotSession(p);

		import std.process : environment;
		auto model = modelClass.length > 0 ? resolveModelAlias(modelClass) : "";
		string[] copilotArgs = [getCopilotBinName(), "--acp", "--yolo"];
		if (model.length > 0)
			copilotArgs ~= ["--model", model];
		auto srv = new AcpProcess(copilotArgs, null, null);

		// Use the same working directory as the main session so session/new
		// receives a valid git-repository path (copilot requires this).
		auto cwd = sharedWorkDir_.length > 0 ? sharedWorkDir_ : ".";
		srv.onReady(() {
			srv.sendRequest("session/new",
				`{"cwd":"` ~ cpEscape(cwd) ~ `","mcpServers":[]}`)
			.then((JsonRpcResponse newResp) {
				@JSONPartial
				static struct SR { string sessionId; }
				string sid;
				try sid = jsonParse!SR(newResp.result.json).sessionId;
				catch (Exception) {}

				if (sid.length == 0)
				{
					session.fail(new Exception("completeOneShot: session/new failed"));
					srv.shutdown();
					return;
				}

				srv.registerSession(sid, session);
				srv.sendRequest("session/prompt",
					`{"sessionId":"` ~ cpEscape(sid) ~ `","prompt":[{"type":"text","text":"` ~ cpEscape(prompt) ~ `"}]}`)
				.then((JsonRpcResponse r) {
					srv.unregisterSession(sid);
					session.succeed();
					srv.shutdown();
				});
			});
		});

		return p;
	}
}

// ---------------------------------------------------------------------------
// CopilotSession — one Copilot session, implementing AgentSession.
// ---------------------------------------------------------------------------

class CopilotSession : AgentSession, AcpSessionHandler
{
	private AcpProcess server;
	private int tid;
	private string sessionId;
	private string model;
	private string workDir;
	private string[] bwrapPrefix_;
	private bool alive_;
	private bool turnInProgress;
	private bool replayMode; // true during session/load replay
	private bool gracefulShutdown_; // true after closeStdin() — handleExit reports 0
	private bool forcedStop_;       // true after stop() — handleExit always reports 1

	// Terminal registry for ACP terminal capability.
	private TerminalProcess[string] terminals;
	private int nextTerminalId_ = 1;
	private Promise!TerminalExitResult[string] pendingWaitIds_; // terminalId → promise for wait_for_exit

	// Streaming state: item tracking for item-based protocol.
	private int nextItemIndex;

	// Active item being streamed (text, thinking, or tool_use).
	private struct ActiveItem
	{
		string id;    // item_id
		string type;  // "text", "thinking", "tool_use"
		string name;  // tool name (tool_use only)
		string input; // tool input JSON (tool_use only)
		string text;  // accumulated text/output
	}
	private ActiveItem activeItem;

	// Queued messages waiting for the current turn to finish.
	private string[] pendingMessages;

	// Callbacks
	package void delegate(string line) outputHandler_;
	package void delegate(string line) stderrHandler_;
	private void delegate(int status) exitHandler_;

	this(AcpProcess server, int tid, string model, string workDir, string[] bwrapPrefix = null)
	{
		this.server = server;
		this.tid = tid;
		this.model = model;
		this.workDir = workDir;
		this.bwrapPrefix_ = bwrapPrefix;
		this.alive_ = true;
	}

	/// Called to suppress events during session/load history replay.
	package void startReplay()
	{
		replayMode = true;
	}

	/// Called when session/new or session/load response arrives.
	package void onSessionStarted(string result, string resumeId, string m, string wd)
	{
		this.model = m;
		this.workDir = wd;

		// Extract sessionId from result.
		@JSONPartial
		static struct SessionResult
		{
			string sessionId;
		}

		try
		{
			auto parsed = jsonParse!SessionResult(result);
			if (parsed.sessionId.length > 0)
				sessionId = parsed.sessionId;
		}
		catch (Exception) {}

		if (sessionId.length == 0 && resumeId.length > 0)
			sessionId = resumeId;

		if (sessionId.length == 0)
		{
			if (outputHandler_)
				outputHandler_(`{"type":"process/stderr","text":"Failed to start Copilot session"}`);
			return;
		}

		replayMode = false; // Done with replay (or was never in it)
		server.registerSession(sessionId, this);

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

		if (outputHandler_)
			outputHandler_(toJson(initEv));

		// Drain queued messages now that the session is ready.
		auto queued = pendingMessages;
		pendingMessages = null;
		foreach (msg; queued)
			sendMessage(msg);
	}

	// ----- AgentSession interface -----

	void sendMessage(string content)
	{
		if (!alive_)
			return;

		// Queue message if session hasn't been created yet.
		if (sessionId.length == 0)
		{
			pendingMessages ~= content;
			return;
		}

		auto escaped = cpEscape(content);

		if (turnInProgress)
		{
			// Steering: buffer message; send after current turn completes.
			pendingMessages ~= content;
		}
		else
		{
			turnInProgress = true;
			nextItemIndex = 0;
			activeItem = ActiveItem.init;

			// Emit user message item so the frontend confirms the pending placeholder.
			if (outputHandler_)
				outputHandler_(
					`{"type":"item/started","item_id":"cp-user-msg","item_type":"user_message","text":"` ~ escaped ~ `"}`);

			// ACP session/prompt uses "prompt" key for the message content array.
			server.sendRequest("session/prompt",
				`{"sessionId":"` ~ cpEscape(sessionId)
				~ `","prompt":[{"type":"text","text":"` ~ escaped ~ `"}]}`)
			.then((JsonRpcResponse resp) {
				onPromptCompleted(resp.result.json !is null ? resp.result.json : "{}");
			});
		}
	}

	void interrupt()
	{
		if (!alive_ || sessionId.length == 0)
			return;
		server.sendNotification("session/cancel",
			`{"sessionId":"` ~ cpEscape(sessionId) ~ `"}`);
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
			server.sendNotification("session/cancel",
				`{"sessionId":"` ~ cpEscape(sessionId) ~ `"}`);
			// Do NOT unregisterSession here — keep the session registered so
			// handleExit fires once the process actually exits.  This ensures
			// events.jsonl is fully flushed before any subsequent session/load
			// (e.g. undo) reads from it.
		}
		alive_ = false;
		forcedStop_ = true;
		server.shutdown();
		// Don't call exitHandler_ here; handleExit will call it once the
		// process has actually exited (after SIGTERM).
	}

	void closeStdin()
	{
		if (!alive_)
			return;
		if (sessionId.length > 0)
		{
			server.sendNotification("session/cancel",
				`{"sessionId":"` ~ cpEscape(sessionId) ~ `"}`);
			// Do NOT unregisterSession here — keep the session registered so
			// handleExit fires once the process actually exits.  This ensures
			// the old process has fully flushed its session state (events.jsonl)
			// before a continuation or undo-resume calls session/load on the
			// same session ID.
		}
		alive_ = false;
		gracefulShutdown_ = true;
		server.shutdown();
		// Don't call exitHandler_ here; handleExit will call it once the
		// process has actually exited (after SIGTERM).
	}

	@property void onOutput(void delegate(string line) dg) { outputHandler_ = dg; }
	@property void onStderr(void delegate(string line) dg) { stderrHandler_ = dg; }
	@property void onExit(void delegate(int status) dg) { exitHandler_ = dg; }
	@property bool alive() { return alive_ && !server.dead; }

	// ----- AcpSessionHandler interface -----

	Promise!TerminalCreateResult handleTerminalCreate(TerminalCreateParams params)
	{
		string[] cmdArgs = [params.command] ~ params.args;

		string[] finalArgs;
		string procWorkDir = null;

		if (bwrapPrefix_ !is null)
		{
			auto prefix = bwrapPrefix_.dup;
			if (params.cwd.length > 0)
			{
				for (size_t i = 0; i + 1 < prefix.length; i++)
				{
					if (prefix[i] == "--chdir")
					{
						prefix[i + 1] = params.cwd;
						break;
					}
				}
			}
			finalArgs = prefix ~ cmdArgs;
		}
		else
		{
			finalArgs = cmdArgs;
			procWorkDir = params.cwd.length > 0 ? params.cwd : workDir;
		}

		string[string] procEnv = null;
		if (params.env.length > 0)
		{
			import std.process : environment;
			procEnv = environment.toAA();
			foreach (ref ev; params.env)
				procEnv[ev.name] = ev.value;
		}

		size_t byteLimit = params.outputByteLimit > 0
			? cast(size_t) params.outputByteLimit : 1024 * 1024;

		auto terminalId = "term_" ~ to!string(nextTerminalId_++);
		terminals[terminalId] = new TerminalProcess(finalArgs, procEnv, procWorkDir, byteLimit);

		return resolve(TerminalCreateResult(terminalId));
	}

	Promise!TerminalOutputResult handleTerminalOutput(TerminalIdParams params)
	{
		auto tp = params.terminalId in terminals;
		if (!tp)
			return resolve(TerminalOutputResult("", false));

		auto term = *tp;
		JSONFragment exitStatus;
		if (term.done)
		{
			auto sig = term.exitSignal();
			if (sig !is null)
				exitStatus = JSONFragment(`{"signal":"` ~ cpEscape(sig) ~ `"}`);
			else
				exitStatus = JSONFragment(`{"exitCode":` ~ to!string(term.exitCode()) ~ `}`);
		}
		return resolve(TerminalOutputResult(term.output(), term.truncated, exitStatus));
	}

	Promise!TerminalExitResult handleTerminalWaitForExit(TerminalIdParams params)
	{
		auto tid = params.terminalId;
		auto tp = tid in terminals;
		if (!tp)
			return resolve(TerminalExitResult());

		auto term = *tp;
		if (term.done)
		{
			auto sig = term.exitSignal();
			if (sig !is null)
				return resolve(TerminalExitResult(0, sig));
			else
				return resolve(TerminalExitResult(term.exitCode()));
		}

		auto p = new Promise!TerminalExitResult;
		pendingWaitIds_[tid] = p;
		term.onExit = () {
			auto pp = tid in pendingWaitIds_;
			if (pp)
			{
				auto sig = term.exitSignal();
				if (sig !is null)
					(*pp).fulfill(TerminalExitResult(0, sig));
				else
					(*pp).fulfill(TerminalExitResult(term.exitCode()));
				pendingWaitIds_.remove(tid);
			}
		};
		return p;
	}

	Promise!EmptyResult handleTerminalKill(TerminalIdParams params)
	{
		auto tp = params.terminalId in terminals;
		if (tp)
			(*tp).kill();
		return resolve(EmptyResult());
	}

	Promise!EmptyResult handleTerminalRelease(TerminalIdParams params)
	{
		auto tid = params.terminalId;
		auto tp = tid in terminals;
		if (tp)
		{
			(*tp).forceKill();
			terminals.remove(tid);
		}
		return resolve(EmptyResult());
	}

	void handleSessionUpdate(JSONFragment update)
	{
		if (!alive_)
			return;
		if (replayMode)
			return;

		@JSONPartial
		static struct UpdateType { string sessionUpdate; }

		UpdateType ut;
		try
			ut = jsonParse!UpdateType(update.json);
		catch (Exception)
			return;

		switch (ut.sessionUpdate)
		{
			case "agent_message_chunk":
				handleAgentMessageChunk(update);
				break;
			case "agent_thought_chunk":
				handleAgentThoughtChunk(update);
				break;
			case "tool_call":
				handleToolCall(update);
				break;
			case "tool_call_update":
				handleToolCallUpdate(update);
				break;
			case "user_message_chunk":
				handleUserMessageChunk(update);
				break;
			// Drop: plan, available_commands_update, config_option_update,
			//       current_mode_update, session_info_update, usage_update
			default:
				break;
		}
	}

	void handleStderr(string line)
	{
		if (stderrHandler_)
			stderrHandler_(line);
	}

	void handleExit(int status)
	{
		// Kill any still-running terminal processes.
		foreach (term; terminals)
			term.forceKill();
		terminals = null;
		pendingWaitIds_ = null;

		// Fire exitHandler_ if set, regardless of alive_.  Both closeStdin() and
		// stop() defer the callback here so the process has fully exited before
		// continuations or undo/fork sessions start.
		if (exitHandler_ is null)
			return;
		auto cb = exitHandler_;
		exitHandler_ = null;
		alive_ = false;
		// gracefulShutdown_ (closeStdin) → report 0 (task completed normally)
		// forcedStop_ (stop) → always report 1 (task killed by user = failed)
		// otherwise → use the actual exit code
		int code = gracefulShutdown_ ? 0 : (forcedStop_ ? 1 : status);
		cb(code);
	}

	// ----- Notification handlers -----

	private void handleAgentMessageChunk(JSONFragment update)
	{
		// update.content.text
		@JSONPartial
		static struct Content { string text; }
		@JSONPartial
		static struct Update { Content content; }

		Update u;
		try
			u = jsonParse!Update(update.json);
		catch (Exception)
			return;

		auto text = u.content.text;

		// Start a new text item if we don't have an active one.
		if (activeItem.type != "text")
		{
			finalizeActiveItem();
			auto id = "cp-text-" ~ to!string(nextItemIndex++);
			activeItem = ActiveItem(id, "text", "", "", "");
			if (outputHandler_)
				outputHandler_(
					`{"type":"item/started","item_id":"` ~ cpEscape(id)
					~ `","item_type":"text"}`);
		}

		activeItem.text ~= text;

		if (outputHandler_ && text.length > 0)
			outputHandler_(
				`{"type":"item/delta","item_id":"` ~ cpEscape(activeItem.id)
				~ `","delta_type":"text_delta","content":"` ~ cpEscape(text) ~ `"}`);
	}

	private void handleAgentThoughtChunk(JSONFragment update)
	{
		// update.content.text
		@JSONPartial
		static struct Content { string text; }
		@JSONPartial
		static struct Update { Content content; }

		Update u;
		try
			u = jsonParse!Update(update.json);
		catch (Exception)
			return;

		auto text = u.content.text;

		// Start a new thinking item if we don't have an active one.
		if (activeItem.type != "thinking")
		{
			finalizeActiveItem();
			auto id = "cp-think-" ~ to!string(nextItemIndex++);
			activeItem = ActiveItem(id, "thinking", "", "", "");
			if (outputHandler_)
				outputHandler_(
					`{"type":"item/started","item_id":"` ~ cpEscape(id)
					~ `","item_type":"thinking"}`);
		}

		activeItem.text ~= text;

		if (outputHandler_ && text.length > 0)
			outputHandler_(
				`{"type":"item/delta","item_id":"` ~ cpEscape(activeItem.id)
				~ `","delta_type":"thinking_delta","content":"` ~ cpEscape(text) ~ `"}`);
	}

	private void handleUserMessageChunk(JSONFragment update)
	{
		// Emit user message item so the frontend confirms the pending placeholder.
		// update.content.text contains the user's message text.
		@JSONPartial
		static struct Content { string text; }
		@JSONPartial
		static struct Update { Content content; }

		Update u;
		try
			u = jsonParse!Update(update.json);
		catch (Exception)
			return;

		auto text = u.content.text;
		if (text.length > 0 && outputHandler_)
			outputHandler_(
				`{"type":"item/started","item_id":"cp-user-msg","item_type":"user_message","text":"` ~ cpEscape(text) ~ `"}`);
	}

	private void handleToolCall(JSONFragment update)
	{
		// update.{toolCallId, title, kind, rawInput}
		@JSONPartial
		static struct Update
		{
			string toolCallId;
			string title;
			string kind;
			JSONFragment rawInput;
		}

		Update u;
		try
			u = jsonParse!Update(update.json);
		catch (Exception)
			return;

		// Finalize any active text/thinking item.
		finalizeActiveItem();

		auto id = u.toolCallId;
		auto name = mapKindToName(u.kind, u.title);
		string inputJson = u.rawInput.json !is null && u.rawInput.json.length > 0
			? u.rawInput.json : "{}";

		activeItem = ActiveItem(id, "tool_use", name, inputJson, "");

		if (outputHandler_)
			outputHandler_(
				`{"type":"item/started","item_id":"` ~ cpEscape(id)
				~ `","item_type":"tool_use","name":"` ~ cpEscape(name)
				~ `","input":` ~ inputJson ~ `}`);

		// Emit the full input as a single input_json_delta so the UI can
		// display it during streaming (ACP provides the full rawInput upfront).
		if (outputHandler_ && inputJson.length > 0 && inputJson != "{}")
			outputHandler_(
				`{"type":"item/delta","item_id":"` ~ cpEscape(id)
				~ `","delta_type":"input_json_delta","content":"` ~ cpEscape(inputJson) ~ `"}`);
	}

	private void handleToolCallUpdate(JSONFragment update)
	{
		// update.{status, content[]}
		// content items: {type:"content", content:{type:"text", text:"..."}}
		@JSONPartial
		static struct InnerContent { string text; }
		@JSONPartial
		static struct ContentItem
		{
			string type;       // "content", "diff", "terminal"
			InnerContent content; // for type=="content"
			string terminalId; // for type=="terminal"
		}
		@JSONPartial
		static struct Update
		{
			string status;
			ContentItem[] content;
		}

		Update u;
		try
			u = jsonParse!Update(update.json);
		catch (Exception)
			return;

		// Accumulate text from "content" and "terminal" type content items.
		// Bash output arrives as "terminal" type with a terminalId reference.
		string text;
		foreach (ref ci; u.content)
		{
			if (ci.type == "content")
				text ~= ci.content.text;
			else if (ci.type == "terminal")
			{
				if (auto term = ci.terminalId in terminals)
					text ~= (*term).output();
			}
		}

		if (text.length > 0)
		{
			activeItem.text ~= text;
			if (outputHandler_)
				outputHandler_(
					`{"type":"item/delta","item_id":"` ~ cpEscape(activeItem.id)
					~ `","delta_type":"output_delta","content":"` ~ cpEscape(text) ~ `"}`);
		}

		auto status = u.status;
		if (status == "completed" || status == "failed")
		{
			// Emit item/completed with final input.
			if (outputHandler_)
				outputHandler_(
					`{"type":"item/completed","item_id":"` ~ cpEscape(activeItem.id)
					~ `","input":` ~ (activeItem.input.length > 0 ? activeItem.input : `{}`) ~ `}`);
			// Emit item/result with accumulated output.
			if (outputHandler_)
				outputHandler_(
					`{"type":"item/result","item_id":"` ~ cpEscape(activeItem.id)
					~ `","content":"` ~ cpEscape(activeItem.text) ~ `"}`);
			activeItem = ActiveItem.init;
		}
	}

	// ----- Turn completion -----

	private void onPromptCompleted(string result)
	{
		// Extract stopReason from the response.
		@JSONPartial
		static struct PromptResult
		{
			string stopReason;
		}

		string stopReason = "end_turn";
		try
		{
			auto pr = jsonParse!PromptResult(result);
			if (pr.stopReason.length > 0)
				stopReason = pr.stopReason;
		}
		catch (Exception) {}

		handleTurnCompleted(stopReason);
	}

	private void handleTurnCompleted(string stopReason)
	{
		// Finalize any still-active item.
		finalizeActiveItem();

		turnInProgress = false;

		// 1. turn/stop
		if (outputHandler_)
			outputHandler_(`{"type":"turn/stop","model":"` ~ cpEscape(model) ~ `"}`);

		// 2. turn/result
		string subtype;
		switch (stopReason)
		{
			case "end_turn":  subtype = "success";  break;
			case "cancelled": subtype = "cancelled"; break;
			default:          subtype = "unknown";   break;
		}
		if (outputHandler_)
			outputHandler_(
				`{"type":"turn/result","subtype":"` ~ subtype ~ `"`
				~ `,"is_error":false,"num_turns":1,"duration_ms":0,"total_cost_usd":0`
				~ `,"usage":{"input_tokens":0,"output_tokens":0}}`);

		// Drain pending messages (steering).
		if (pendingMessages.length > 0)
		{
			auto next = pendingMessages[0];
			pendingMessages = pendingMessages[1 .. $];
			sendMessage(next);
		}
	}

	/// Finalize activeItem: emit item/completed (and item/result for tools).
	/// No-op if there is no active item.
	private void finalizeActiveItem()
	{
		if (activeItem.type.length == 0)
			return;

		if (outputHandler_)
		{
			if (activeItem.type == "tool_use")
			{
				// Tool: emit completed with input, and result with accumulated output.
				outputHandler_(
					`{"type":"item/completed","item_id":"` ~ cpEscape(activeItem.id)
					~ `","input":` ~ (activeItem.input.length > 0 ? activeItem.input : `{}`) ~ `}`);
				outputHandler_(
					`{"type":"item/result","item_id":"` ~ cpEscape(activeItem.id)
					~ `","content":"` ~ cpEscape(activeItem.text) ~ `"}`);
			}
			else
			{
				// Text/thinking: emit completed with accumulated text.
				outputHandler_(
					`{"type":"item/completed","item_id":"` ~ cpEscape(activeItem.id)
					~ `","text":"` ~ cpEscape(activeItem.text) ~ `"}`);
			}
		}

		activeItem = ActiveItem.init;
	}
}

// ---------------------------------------------------------------------------
// OneShotCopilotSession — minimal AcpSessionHandler for completeOneShot.
// ---------------------------------------------------------------------------

private final class OneShotCopilotSession : AcpSessionHandler
{
	private string text_;
	private bool fulfilled_;
	private Promise!string promise_;

	this(Promise!string p) { promise_ = p; }

	Promise!TerminalCreateResult handleTerminalCreate(TerminalCreateParams params)
		{ return resolve(TerminalCreateResult("")); }
	Promise!TerminalOutputResult handleTerminalOutput(TerminalIdParams params)
		{ return resolve(TerminalOutputResult("", false)); }
	Promise!TerminalExitResult handleTerminalWaitForExit(TerminalIdParams params)
		{ return resolve(TerminalExitResult()); }
	Promise!EmptyResult handleTerminalKill(TerminalIdParams params)
		{ return resolve(EmptyResult()); }
	Promise!EmptyResult handleTerminalRelease(TerminalIdParams params)
		{ return resolve(EmptyResult()); }

	void handleSessionUpdate(JSONFragment update)
	{
		@JSONPartial
		static struct UpProbe { string sessionUpdate; }

		UpProbe up;
		try up = jsonParse!UpProbe(update.json);
		catch (Exception) return;

		if (up.sessionUpdate != "agent_message_chunk")
			return;

		@JSONPartial
		static struct Content { string text; }
		@JSONPartial
		static struct Chunk { Content content; }

		Chunk c;
		try c = jsonParse!Chunk(update.json);
		catch (Exception) return;

		text_ ~= c.content.text;
	}

	void handleStderr(string) {}

	void handleExit(int status)
	{
		if (!fulfilled_)
		{
			fulfilled_ = true;
			promise_.reject(new Exception("completeOneShot: process exited with status " ~ to!string(status)));
		}
	}

	void succeed()
	{
		if (!fulfilled_)
		{
			fulfilled_ = true;
			promise_.fulfill(text_);
		}
	}

	void fail(Exception e)
	{
		if (!fulfilled_)
		{
			fulfilled_ = true;
			promise_.reject(e);
		}
	}
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

private:

/// Map ACP tool kind to agnostic tool name.
string mapKindToName(string kind, string title)
{
	switch (kind)
	{
		case "read":    return "Read";
		case "edit":    return "Edit";
		case "execute": return "Bash";
		case "search":  return "Grep";
		case "other":
			return title.length > 0 ? title : "unknown";
		default:
			return title.length > 0 ? title : "unknown";
	}
}

/// Get the copilot binary name/path.
/// If CYDO_COPILOT_BIN is set, use it (can be absolute path); else "copilot".
string getCopilotBinName()
{
	import std.process : environment;
	return environment.get("CYDO_COPILOT_BIN", "copilot");
}

/// Resolve the copilot binary directory by searching PATH.
string resolveCopilotBinary()
{
	import std.algorithm : startsWith;
	import std.file : exists, isFile;
	import std.process : environment;

	auto binName = getCopilotBinName();
	if (binName.startsWith("/"))
		return dirName(binName);

	auto pathVar = environment.get("PATH", "");
	import std.algorithm : splitter;
	foreach (dir; pathVar.splitter(':'))
	{
		auto candidate = buildPath(dir, binName);
		if (exists(candidate) && isFile(candidate))
			return dir;
	}
	return "";
}

/// Absolute path to the cydo binary, cached at module init.
immutable string cydoBinaryPath;
shared static this()
{
	import std.file : thisExePath;
	cydoBinaryPath = thisExePath();
}

string cydoBinaryDir()
{
	return cydoBinaryPath.length > 0 ? dirName(cydoBinaryPath) : "";
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
		~ cpEscape(cydoBin) ~ `","args":["--mcp-server"],"env":{"CYDO_TID":"`
		~ to!string(tid) ~ `","CYDO_SOCKET":"`
		~ cpEscape(mcpSocketPath) ~ `","CYDO_CREATABLE_TYPES":"`
		~ cpEscape(creatableTaskTypes) ~ `","CYDO_SWITCHMODES":"`
		~ cpEscape(switchModes) ~ `","CYDO_HANDOFFS":"`
		~ cpEscape(handoffs) ~ `","CYDO_INCLUDE_TOOLS":"`
		~ cpEscape(includeTools is null ? "" : includeTools.join(",")) ~ `"}}}}`;

	write(configPath, config);
	return configPath;
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
