module cydo.agent.drivers.copilot;

import core.time : Duration;

import std.conv : to;
import std.exception : enforce;
import std.format : format;
import std.path : buildPath, dirName, expandTilde;
import ae.utils.json : JSONFragment, JSONOptional, JSONPartial, jsonParse, toJson;
import ae.utils.time.types : AbsTime;
import ae.utils.jsonrpc : JsonRpcResponse;
import ae.utils.promise : Promise, resolve;
import ae.net.asockets : onNextTick, socketManager;

version (unittest) import ae.net.asockets : ConnectionState, DisconnectType,
	IConnection;
version (unittest) import ae.sys.data : Data;
version (unittest) import ae.utils.jsonrpc : JsonRpcError, JsonRpcErrorCode,
	JsonRpcRequest;

import cydo.agent.sdk : SdkProcess, SdkSessionHandler,
	SdkPermissionRequest, SdkPermissionResult,
	SdkToolCallRequest, SdkToolCallResult, SdkToolResult,
	SdkEvent, EmptyResult;
version (unittest) import cydo.agent.sdk : makeTestSdkProcess;
import cydo.agent.contract : Agent, DiscoveredSession, InterruptedToolCallRepair,
	PersistedHistoryBoundary, PersistedHistoryBoundaryKind, OneShotHandle,
	RewindResult, SessionConfig, SessionMeta;
import cydo.protocol : ContentBlock, ItemCompletedEvent, ItemDeltaEvent,
	ItemResultEvent, ItemStartedEvent, makeUnrecognizedEvent, ProcessExitEvent,
	ProcessStderrEvent, SessionInitEvent, TranslatedEvent, TurnResultEvent,
	TurnStopEvent, UsageInfo;
import cydo.agent.session : AgentSession, AgentSubmissionReceipt;
import cydo.runtime.config : AgentDriver, ModelSpec, ModelSpecFields;
import cydo.runtime.launch.sandbox_paths : PathAccess, SandboxPathOrigin,
	SandboxPathOriginKind, SandboxPaths;
import cydo.runtime.launch.types : NativeHistoryProfile, NativeHistoryRule,
	ProcessLaunch;
import cydo.runtime.launch.sandbox : cydoBinaryDir, cydoBinaryPath, effectiveEnvValue,
	executableMountPaths, resolveExecutablePath;
import cydo.mcp : McpResult;
import cydo.mcp.tools : handoffToolDescription, taskToolDescription;
import cydo.foundation.text.title : truncateTitle;

// Callback type for dispatching custom tool calls.
alias ToolDispatchFn = Promise!McpResult delegate(string tool, string tid, JSONFragment args);

// ---------------------------------------------------------------------------
// CopilotAgent — Agent descriptor for GitHub Copilot CLI via SDK protocol.
// ---------------------------------------------------------------------------

class CopilotAgent : Agent
{
	private ModelSpec[string] modelAliasOverrides;
	// Shared SDK process for one-shot requests.
	package SdkProcess sharedSdkServer_;
	package string sharedWorkDir_;
	private string lastMcpConfigPath_;
	// Tool dispatch callback — set externally (e.g., by App) before creating sessions.
	package(cydo) ToolDispatchFn toolDispatch_;
	void configureSandbox(ref SandboxPaths paths, ref string[string] env)
	{
		import std.process : environment;

		foreach (path; executableMountPaths(resolveExecutablePath(executableName(env), env)))
			paths.requireReadVisible(path,
				SandboxPathOrigin(SandboxPathOriginKind.agentRequirement, "copilot",
					"Copilot executable"));
		paths.requireReadVisible(cydoBinaryDir(),
			SandboxPathOrigin(SandboxPathOriginKind.agentRequirement, "copilot",
				"CyDo binary"));

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
		passthrough("COPILOT_MODEL");
		passthrough("HTTPS_PROXY");
		passthrough("NODE_TLS_REJECT_UNAUTHORIZED");
	}

	@property string gitName() { return "GitHub Copilot"; }
	@property string gitEmail() { return "noreply@github.com"; }
	override @property AgentDriver driver() { return AgentDriver.copilot; }
	override @property NativeHistoryRule nativeHistoryRule()
	{
		return NativeHistoryRule(AgentDriver.copilot, "COPILOT_HOME", ".copilot", null);
	}
	@property string lastMcpConfigPath() { return lastMcpConfigPath_; }
	string executableName(string[string] env)
	{
		return effectiveEnvValue(env, "CYDO_COPILOT_BIN", "copilot");
	}

	AgentSession createSession(int tid, string resumeSessionId, ProcessLaunch launch,
		SessionConfig config = SessionConfig.init)
	{
		auto model = config.model;
		auto workDir = launch.workDir.length > 0
			? launch.workDir
			: (config.workDir.length > 0 ? config.workDir : ".");

		// Generate MCP config file if a socket path was provided.
		string mcpConfigPath = null;
		if (config.mcpSocketPath.length > 0)
		{
			mcpConfigPath = generateCopilotMcpConfig(tid, launch.nativeHistoryProfile,
				config.creatableTaskTypes,
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
		return attachSession(server, tid, sessionId, resumeSessionId, model,
			workDir, launch.cmdPrefix, toolDispatch_, config);
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

	DiscoveredSession[] enumerateAllSessions(const ref NativeHistoryProfile profile)
	{
		import std.file : DirEntry, dirEntries, exists, SpanMode;
		import std.path : baseName, buildPath;

		enforce(profile.driver == driver,
			"Copilot history profile driver does not match Copilot");
		auto sessionStateDir = buildPath(profile.root, "session-state");
		if (!exists(sessionStateDir))
			return [];

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
				DiscoveredSession ds;
				ds.sessionId = sessionId;
				import std.file : timeLastModified;
				ds.mtime = timeLastModified(eventsFile).stdTime;
				ds.projectPath = ""; // not derivable
				ds.exactHistoryPath = eventsFile;
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

	SessionMeta readSessionMeta(const ref DiscoveredSession session)
	{
		import std.algorithm : canFind;
		import std.stdio : File;
		if (session.exactHistoryPath.length == 0)
			return SessionMeta.init;

		SessionMeta meta;
		try
		{
			int lineCount = 0;
			auto f = File(session.exactHistoryPath, "r");
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
			tracef("readSessionMeta(copilot, %s): error: %s", session.sessionId, e.msg);
		}
		return meta;
	}

	string matchProject(const ref DiscoveredSession session,
		const string[] knownProjectPaths) { return ""; }

	void setModelAliases(ModelSpec[string] aliases)
	{
		modelAliasOverrides = aliases;
	}

	private static string defaultModelForClass(string modelClass)
	{
		switch (modelClass)
		{
			case "small":  return "claude-haiku-4.5";
			case "medium": return "claude-sonnet-4.6";
			case "large":  return "claude-opus-4.6";
			default:       return modelClass; // pass through unknown aliases
		}
	}

	ModelSpec resolveModelSpec(string modelClass)
	{
		ModelSpec spec;
		if (auto p = modelClass in modelAliasOverrides)
			spec = *p;
		if (spec.model.length == 0)
			spec.model = defaultModelForClass(modelClass);
		return spec;
	}

	unittest
	{
		auto agent = new CopilotAgent();

		// 14. with no overrides, hardcoded defaults and empty effort
		assert(agent.resolveModelSpec("small") == ModelSpec(ModelSpecFields("claude-haiku-4.5")));
		assert(agent.resolveModelSpec("medium") == ModelSpec(ModelSpecFields("claude-sonnet-4.6")));
		assert(agent.resolveModelSpec("large") == ModelSpec(ModelSpecFields("claude-opus-4.6")));

		// 15. an override replaces the default model
		agent.setModelAliases(["large": ModelSpec(ModelSpecFields("custom-model"))]);
		assert(agent.resolveModelSpec("large").model == "custom-model");

		// 16. an effort-only override keeps the driver's default model
		agent.setModelAliases(["large": ModelSpec(ModelSpecFields("", "high"))]);
		auto effortOnly = agent.resolveModelSpec("large");
		assert(effortOnly.model == "claude-opus-4.6");
		assert(effortOnly.effort == "high");

		// 17. an unknown class passes through, and can still be overridden
		agent.setModelAliases(null);
		auto passthrough = agent.resolveModelSpec("best");
		assert(passthrough.model == "best");
		assert(passthrough.effort == "");
		agent.setModelAliases(["best": ModelSpec(ModelSpecFields("opus", "max"))]);
		auto customClass = agent.resolveModelSpec("best");
		assert(customClass.model == "opus");
		assert(customClass.effort == "max");

		// 18. the empty-class edge stays inert
		agent.setModelAliases(null);
		assert(agent.resolveModelSpec("").model == "");
	}

	// ---- History / fork ----

	string historyPath(string sessionId, const ref NativeHistoryProfile profile)
	{
		enforce(profile.driver == driver,
			"Copilot history profile driver does not match Copilot");
		enforce(sessionId.length > 0,
			"Copilot history path requires a session ID");
		return buildPath(profile.root, "session-state", sessionId, "events.jsonl");
	}

	void registerHistoryPath(string sessionId, string path,
		const ref NativeHistoryProfile profile)
	{
		// Copilot session paths are fully derivable, so a locator learned
		// elsewhere must agree with the derivation.
		enforce(path == historyPath(sessionId, profile),
			"Copilot history registration does not match its derived path");
	}

	string createHistoryForkDestination(string sessionId, string sourceHistoryPath,
		const ref NativeHistoryProfile profile)
	{
		return historyPath(sessionId, profile);
	}

	void resetHistoryReplay() {} // no state to reset for Copilot

	TranslatedEvent[] translateHistoryLine(string line, int lineNum)
	{
		import std.algorithm : canFind;
		import std.uuid : randomUUID;
		if (!line.canFind(`"type":"`))
			return null;

		@JSONPartial
		static struct CpEventBase { string type; string id; @JSONOptional string timestamp; }

		CpEventBase base;
		try base = jsonParse!CpEventBase(line);
		catch (Exception)
			return null;

		import cydo.protocol : parseIso8601Timestamp;
		auto ts = parseIso8601Timestamp(base.timestamp);

		string[] evStrings;
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
				evStrings = [toJson(initEv)];
				break;
			}
			case "user.message":
			{
				@JSONPartial static struct CpUserMsgData { string content; }
				@JSONPartial static struct CpUserMsgEvent { CpUserMsgData data; }
				CpUserMsgEvent ev;
				try ev = jsonParse!CpUserMsgEvent(line);
				catch (Exception) {}
				ContentBlock cb;
				cb.type = "text";
				cb.text = ev.data.content;
				ItemStartedEvent startEv;
				startEv.item_id   = "cp-user-" ~ (base.id.length > 0 ? base.id : randomUUID().toString());
				startEv.item_type = "user_message";
				startEv.content   = [cb];
				startEv.uuid      = base.id;
				evStrings = [toJson(startEv)];
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
				evStrings = [toJson(startEv), toJson(compEv), toJson(tsEv)];
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

				evStrings = [toJson(startEv)];
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
				ContentBlock resCb;
				resCb.type = "text";
				resCb.text = outputText;
				resEv.content = JSONFragment(toJson([resCb]));
				TurnStopEvent tsEv;
				evStrings = [toJson(compEv), toJson(resEv), toJson(tsEv)];
				break;
			}
			case "assistant.turn_end":
			{
				TurnResultEvent histTrEv;
				histTrEv.subtype        = "success";
				histTrEv.is_error       = false;
				histTrEv.num_turns      = 1;
				histTrEv.duration_ms    = 0;
				histTrEv.total_cost_usd = 0.0;
				histTrEv.usage          = UsageInfo(0, 0);
				evStrings = [toJson(histTrEv)];
				break;
			}
			case "subagent.started":
			case "permission.completed":
				return null;
			default:
				return null;
		}

		// Wrap each translated string with the original JSONL line as raw source.
		TranslatedEvent[] events;
		foreach (e; evStrings)
			events ~= TranslatedEvent(e, line, ts);
		return events;
	}

	TranslatedEvent[] translateLiveEvent(string rawLine)
	{
		// Copilot emits agnostic-format events natively (via CopilotSession);
		// only stderr/exit need renaming.  Everything else passes through.
		@JSONPartial static struct TypeProbe { string type; }
		try
		{
			auto probe = jsonParse!TypeProbe(rawLine);
			if (probe.type == "stderr")
			{
				@JSONPartial static struct RawStderr { string text; }
				auto raw = jsonParse!RawStderr(rawLine);
				ProcessStderrEvent ev;
				ev.text = raw.text;
				return [TranslatedEvent(toJson(ev), null)];
			}
			if (probe.type == "exit")
			{
				@JSONPartial static struct RawExit { int code; @JSONOptional bool is_continuation; }
				auto raw = jsonParse!RawExit(rawLine);
				ProcessExitEvent ev;
				ev.code = raw.code;
				ev.is_continuation = raw.is_continuation;
				return [TranslatedEvent(toJson(ev), null)];
			}
		}
		catch (Exception) {}
		return [TranslatedEvent(rawLine, null)];
	}

	bool isTurnResult(string rawLine)
	{
		@JSONPartial static struct TypeProbe { string type; }
		try { return jsonParse!TypeProbe(rawLine).type == "turn/result"; }
		catch (Exception) { return false; }
	}

	bool isUserMessageLine(string rawLine)
	{
		@JSONPartial static struct TypeProbe { string type; }
		try { return jsonParse!TypeProbe(rawLine).type == "user.message"; }
		catch (Exception) { return false; }
	}

	bool isAssistantMessageLine(string rawLine)
	{
		@JSONPartial static struct TypeProbe { string type; }
		try { return jsonParse!TypeProbe(rawLine).type == "assistant.message"; }
		catch (Exception) { return false; }
	}

	string rewriteSessionId(string line, string oldId, string newId)
	{
		// events.jsonl session ID is the directory name, not embedded per-line.
		return line;
	}

	PersistedHistoryBoundary[] extractPersistedHistoryBoundaries(string content, int lineOffset = 0)
	{
		import std.algorithm : startsWith;
		import std.string : lineSplitter;

		@JSONPartial static struct TypeIdProbe { string type; string id;
			@JSONPartial static struct Data { string content; }
			Data data; }

		PersistedHistoryBoundary[] ids;
		foreach (line; content.lineSplitter)
		{
			if (line.length == 0)
				continue;
			try
			{
				auto probe = jsonParse!TypeIdProbe(line);
				if (probe.type != "user.message" && probe.type != "assistant.message")
					continue;
				if (probe.type == "user.message" && probe.data.content.startsWith("[SYSTEM:"))
					continue;
				if (probe.id.length > 0)
					ids ~= PersistedHistoryBoundary(probe.id,
						probe.type == "user.message" ? PersistedHistoryBoundaryKind.user : PersistedHistoryBoundaryKind.agent_turn, null);
			}
			catch (Exception) {}
		}
		return ids;
	}

	InterruptedToolCallRepair repairInterruptedToolCall(string[] lines, string toolName,
		string resultText)
	{
		// Native SDK tool dispatch (at handleToolCall/toolDispatch_) never reaches
		// transport.d's interrupted MCP path; continuation e2e coverage pins its
		// already-successful tool.execution_complete record instead.
		return null;
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
	@property bool supportsDeveloperPrompt() { return true; }

	RewindResult rewindFiles(string sessionId, string afterUuid, ProcessLaunch launch)
	{
		return RewindResult(false, "File revert is not supported for Copilot sessions");
	}

	OneShotHandle completeOneShot(string prompt, string modelClass,
		ProcessLaunch launch)
	{
		auto p = new Promise!string;
		auto session = new OneShotCopilotSession(p);

		auto model = resolveModelSpec(modelClass).model;
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
				SessionIdParams destP;
				destP.sessionId = sessionId;
				srv.sendRequest("session.destroy", toJson(destP))
				.then((JsonRpcResponse r) { srv.shutdown(); });
			};

			srv.registerSession(sessionId, session);

			srv.onReady(() {
				srv.sendRequest("session.create",
					buildSessionCreateParams(sessionId, model, cwd, SessionConfig.init))
				.then((JsonRpcResponse createResp) {
					SessionSendParams oneShotSendP;
					oneShotSendP.sessionId = sessionId;
					oneShotSendP.prompt    = prompt;
					srv.sendRequest("session.send", toJson(oneShotSendP))
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

unittest
{
	auto agent = new CopilotAgent;
	assert(agent.repairInterruptedToolCall([`{"type":"tool.execution_complete"}`],
		"mcp__cydo__SwitchMode", "RESULT") is null);
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
	import std.path : buildPath;
	import std.process : environment, execute;
	import cydo.runtime.config : PathMode, SandboxConfig;
	import cydo.runtime.launch.sandbox_resolver : resolveSandbox;
	import cydo.runtime.launch.types : AgentSandboxConfig;

	auto root = buildPath(tempDir(), "cydo-copilot-configure-sandbox");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);

	auto environmentKeys = ["HOME", "PATH", "COPILOT_HOME",
		"COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN", "COPILOT_MODEL",
		"HTTPS_PROXY", "NODE_TLS_REJECT_UNAUTHORIZED"];
	string[string] previousEnvironment;
	bool[string] hadEnvironment;
	foreach (key; environmentKeys)
	{
		hadEnvironment[key] = key in environment;
		previousEnvironment[key] = environment.get(key, "");
	}
	scope (exit)
	{
		foreach (key; environmentKeys)
		{
			if (hadEnvironment[key])
				environment[key] = previousEnvironment[key];
			else
				environment.remove(key);
		}
	}

	auto home = buildPath(root, "home");
	auto copilotHome = buildPath(home, "configured-copilot-home");
	auto executableDir = buildPath(root, "bin");
	auto executable = buildPath(executableDir, "copilot");
	mkdirRecurse(copilotHome);
	mkdirRecurse(executableDir);
	write(executable, "#!/bin/sh\nexit 0\n");
	execute(["chmod", "+x", executable]);
	environment["HOME"] = home;
	environment["COPILOT_HOME"] = copilotHome;
	environment["COPILOT_GITHUB_TOKEN"] = "test-copilot-token";
	environment["GH_TOKEN"] = "test-gh-token";
	environment["GITHUB_TOKEN"] = "test-github-token";
	environment["COPILOT_MODEL"] = "test-copilot-model";
	environment["HTTPS_PROXY"] = "http://copilot.test.invalid:8080";
	environment["NODE_TLS_REJECT_UNAUTHORIZED"] = "0";
	environment["PATH"] = executableDir;

	auto agent = new CopilotAgent;
	auto cydoDir = cydoBinaryDir();
	assert(cydoDir.length > 0);

	SandboxConfig global;
	global.paths = [
		executableDir: PathMode.rw,
		cydoDir: PathMode.always_rw,
	];
	global.env = [
		"CYDO_COPILOT_BIN": executable,
		"PATH": executableDir,
	];
	auto executableMounts = executableMountPaths(resolveExecutablePath(executable, global.env));
	assert(executableMounts.length == 1);
	assert(executableMounts[0] == executableDir);
	AgentSandboxConfig agentSandbox;
	agentSandbox.configureSandbox = (ref SandboxPaths paths, ref string[string] env) {
		agent.configureSandbox(paths, env);
	};
	agentSandbox.agentName = "copilot";
	agentSandbox.workspaceName = "test";
	auto resolved = resolveSandbox(global, SandboxConfig.init, SandboxConfig.init,
		agentSandbox, "");

	auto executableView = resolved.paths.exact(executableDir).get;
	assert(executableView.declaration.get.mode == PathMode.rw);
	assert(executableView.effectiveMode == PathMode.rw);
	auto cydoView = resolved.paths.exact(cydoDir).get;
	assert(cydoView.declaration.get.mode == PathMode.always_rw);
	assert(cydoView.effectiveMode == PathMode.always_rw);

	// Native history is materialized by prepareProcessLaunch, not while the
	// driver configures executable visibility and credential passthrough.
	assert(resolved.paths.exact(copilotHome).isNull);
	auto nativeRule = agent.nativeHistoryRule;
	assert(nativeRule.driver == AgentDriver.copilot);
	assert(nativeRule.profileEnvName == "COPILOT_HOME");
	assert(nativeRule.homeRelativeDefault == ".copilot");
	assert(nativeRule.homeSupportRequirements.length == 0);
	assert(resolved.env["PATH"] == executableDir);
	assert(("COPILOT_HOME" in resolved.env) is null);
	assert(resolved.env["COPILOT_GITHUB_TOKEN"] == "test-copilot-token");
	assert(resolved.env["GH_TOKEN"] == "test-gh-token");
	assert(resolved.env["GITHUB_TOKEN"] == "test-github-token");
	assert(resolved.env["COPILOT_MODEL"] == "test-copilot-model");
	assert(resolved.env["HTTPS_PROXY"] == "http://copilot.test.invalid:8080");
	assert(resolved.env["NODE_TLS_REJECT_UNAUTHORIZED"] == "0");

	// A configured profile selector remains in the resolved child environment,
	// but configureSandbox must not turn it into a native-history mount.
	auto configuredCopilotHome = buildPath(home, "sandbox-copilot-home");
	SandboxConfig configuredGlobal;
	configuredGlobal.env = [
		"CYDO_COPILOT_BIN": executable,
		"PATH": executableDir,
		"COPILOT_HOME": configuredCopilotHome,
	];
	auto configuredResolved = resolveSandbox(configuredGlobal, SandboxConfig.init,
		SandboxConfig.init, agentSandbox, "");
	assert(configuredResolved.paths.exact(configuredCopilotHome).isNull);
	assert(configuredResolved.paths.exact(copilotHome).isNull);
	assert(configuredResolved.env["COPILOT_HOME"] == configuredCopilotHome);

	// Missing launch values do not inherit host COPILOT_HOME during driver setup.
	SandboxPaths defaultPaths;
	string[string] defaultEnv = ["CYDO_COPILOT_BIN": executable];
	agent.configureSandbox(defaultPaths, defaultEnv);
	assert(defaultEnv["PATH"] == executableDir);
	assert(("COPILOT_HOME" in defaultEnv) is null);
	assert(defaultPaths.exact(copilotHome).isNull);
	assert(defaultEnv["COPILOT_GITHUB_TOKEN"] == "test-copilot-token");
	assert(defaultEnv["GH_TOKEN"] == "test-gh-token");
	assert(defaultEnv["GITHUB_TOKEN"] == "test-github-token");
	assert(defaultEnv["COPILOT_MODEL"] == "test-copilot-model");
	assert(defaultEnv["HTTPS_PROXY"] == "http://copilot.test.invalid:8080");
	assert(defaultEnv["NODE_TLS_REJECT_UNAUTHORIZED"] == "0");
	foreach (path; executableMounts)
		assert(defaultPaths.exact(path).get.effectiveMode == PathMode.ro);

	// Writable ancestors satisfy read visibility without producing a child mount.
	auto origin = SandboxPathOrigin(SandboxPathOriginKind.launchRequirement,
		"copilot test", "pre-existing host access");
	SandboxPaths ancestorPaths;
	auto executableParent = dirName(executableDir);
	auto cydoParent = dirName(cydoDir);
	ancestorPaths.require(executableParent, PathAccess.rw, origin);
	ancestorPaths.require(cydoParent, PathAccess.alwaysRw, origin);
	string[string] ancestorEnv = [
		"CYDO_COPILOT_BIN": executable,
		"PATH": executableDir,
	];
	agent.configureSandbox(ancestorPaths, ancestorEnv);
	assert(ancestorPaths.exact(executableParent).get.effectiveMode == PathMode.rw);
	assert(ancestorPaths.exact(executableDir).isNull);
	assert(ancestorPaths.exact(cydoParent).get.effectiveMode == PathMode.always_rw);
	assert(ancestorPaths.exact(cydoDir).isNull);
}

private CopilotSession attachSession(SdkProcess server, int tid,
	string sessionId, string resumeSessionId, string model, string workDir,
	string[] cmdPrefix, ToolDispatchFn toolDispatch, SessionConfig config)
{
	auto session = new CopilotSession(server, tid, sessionId, model, workDir,
		cmdPrefix, toolDispatch, config.agentName);

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
				if (resp.isError)
				{
					import std.logger : warningf;
					warningf("session.resume error: %s", resp.error.get.message);
					session.replayMode = false;
					ProcessStderrEvent resumeErrEv;
					resumeErrEv.text = "session.resume error: " ~ resp.error.get.message;
					session.emitEvent(toJson(resumeErrEv));
					server.unregisterSession(sessionId);
					session.handleStartupFailure(new Exception(
						"session.resume error: " ~ resp.error.get.message));
					return;
				}
				session.onSessionStarted(model, workDir);
			}, (Exception e) {
				server.unregisterSession(sessionId);
				session.handleStartupFailure(e);
			});
		}
		else
		{
			server.sendRequest("session.create",
				buildSessionCreateParams(sessionId, model, workDir, config))
			.then((JsonRpcResponse resp) {
				if (resp.isError)
				{
					server.unregisterSession(sessionId);
					session.handleStartupFailure(new Exception(
						"session.create error: " ~ resp.error.get.message));
					return;
				}
				session.onSessionStarted(model, workDir);
			}, (Exception e) {
				server.unregisterSession(sessionId);
				session.handleStartupFailure(e);
			});
		}
	});

	return session;
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
	private bool hadItemsSinceLastStop_;
	private string currentRawJson_; // raw event data.json from handleEvent, for _raw injection
	private AbsTime currentEventTs_; // timestamp of the current live event
	private string currentSubagentParent_;  // toolCallId of current sub-agent parent (task tool)
	private string currentAssistantMessageId_;
	private string activeTurnNamespace_;

	private bool sessionReady_; // true after session.create/resume response
	private string agentName_;
	private string copilotVersion_;
	private void delegate(string sessionId) nativeSessionStartedHandler_;
	private bool nativeSessionStartedNotified_;

	// Each message owns its settlement while it waits for readiness, a turn,
	// or the correlated session.send response.
	private static final class PendingMessage
	{
		ContentBlock[] content;
		string text;
		string correlationId;
		bool isContextBootstrap;
		Promise!AgentSubmissionReceipt promise;
		bool settled;
		bool accepted;
		TranslatedEvent gatedUserEcho;
		bool hasGatedUserEcho;

		this(const(ContentBlock)[] content, string text, string correlationId,
			bool isContextBootstrap)
		{
			this.content = content.dup;
			this.text = text;
			this.correlationId = correlationId;
			this.isContextBootstrap = isContextBootstrap;
			this.promise = new Promise!AgentSubmissionReceipt;
		}
	}
	private PendingMessage[] pendingMessages;
	private static final class ExpectedUserMessage
	{
		string content;
		PendingMessage submission;
		bool nativeEchoSeen;

		this(PendingMessage submission)
		{
			this.content = submission.text;
			this.submission = submission;
		}
	}
	private ExpectedUserMessage[] expectedUserMessages;

	// Callbacks
	package void delegate(TranslatedEvent) outputHandler_;
	package void delegate(string line) stderrHandler_;
	private void delegate(int status) exitHandler_;

	this(SdkProcess server, int tid, string sessionId, string model, string workDir,
		string[] cmdPrefix = null, ToolDispatchFn toolDispatch = null, string agentName = null)
	{
		this.server = server;
		this.tid = tid;
		this.sessionId = sessionId;
		this.model = model;
		this.workDir = workDir;
		this.cmdPrefix_ = cmdPrefix;
		this.toolDispatch_ = toolDispatch;
		this.alive_ = true;
		this.agentName_ = agentName;
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
		hadItemsSinceLastStop_ = false;

		// Emit synthetic session/init.
		notifyNativeSessionStarted();
		SessionInitEvent initEv;
		initEv.session_id      = sessionId;
		initEv.model           = model;
		initEv.cwd             = workDir;
		initEv.tools           = [];
		initEv.agent_version   = "";
		initEv.permission_mode = "dangerously-skip-permissions";
		initEv.agent           = "copilot";
		initEv.agent_name      = agentName_;

		emitEvent(toJson(initEv));

		// Drain queued messages now that the session is ready.
		drainPendingMessages();
	}

	private void rejectSubmission(PendingMessage submission, Exception error)
	{
		if (submission.settled)
			return;
		submission.settled = true;
		submission.promise.reject(error);
	}

	private void removeExpectedUserMessage(PendingMessage submission)
	{
		foreach (i, expected; expectedUserMessages)
			if (expected.submission is submission)
			{
				expectedUserMessages = expectedUserMessages[0 .. i]
					~ expectedUserMessages[i + 1 .. $];
				return;
			}
		assert(false, "Copilot submission response has no expected user echo");
	}

	private void emitAcceptedUserEcho(PendingMessage submission,
		TranslatedEvent event)
	{
		assert(submission.accepted,
			"Copilot user.message emitted before session.send acceptance");
		auto output = outputHandler_;
		// Queue after fulfillment so App commits acceptance before translating it.
		onNextTick(socketManager, {
			if (output)
				output(event);
		});
	}

	private void releaseGatedUserEcho(PendingMessage submission)
	{
		if (!submission.hasGatedUserEcho)
			return;
		auto event = submission.gatedUserEcho;
		submission.gatedUserEcho = TranslatedEvent.init;
		submission.hasGatedUserEcho = false;
		removeExpectedUserMessage(submission);
		emitAcceptedUserEcho(submission, event);
	}

	private void rejectUnsettledMessages(Exception error)
	{
		auto queued = pendingMessages;
		pendingMessages = null;
		foreach (submission; queued)
			rejectSubmission(submission, error);

		auto expected = expectedUserMessages;
		expectedUserMessages = null;
		foreach (message; expected)
			rejectSubmission(message.submission, error);
	}

	private void resetRejectedSubmission()
	{
		turnInProgress = false;
		nextItemIndex = 0;
		activeTextItem = ActiveTextItem.init;
		activeTools = null;
		hadItemsSinceLastStop_ = false;
		lastResultText = null;
		currentAssistantMessageId_ = null;
		currentSubagentParent_ = null;
		activeTurnNamespace_ = null;
	}

	private void drainPendingMessages()
	{
		if (!alive_ || !sessionReady_ || turnInProgress
			|| pendingMessages.length == 0)
			return;
		auto submission = pendingMessages[0];
		pendingMessages = pendingMessages[1 .. $];
		submitMessage(submission);
	}

	private void submitMessage(PendingMessage submission)
	{
		assert(sessionReady_ && !turnInProgress,
			"Copilot submission requires a ready idle session");
		turnInProgress = true;
		nextItemIndex = 0;
		activeTextItem = ActiveTextItem.init;
		activeTools = null;
		hadItemsSinceLastStop_ = false;
		expectedUserMessages ~= new ExpectedUserMessage(submission);

		SessionSendParams params;
		params.sessionId = sessionId;
		params.prompt = submission.text;
		try
		{
			server.sendRequest("session.send", toJson(params))
				.then((JsonRpcResponse response) {
					if (submission.settled)
						return;
					if (response.isError)
					{
						removeExpectedUserMessage(submission);
						resetRejectedSubmission();
						rejectSubmission(submission,
							new Exception(response.error.get.message));
						drainPendingMessages();
						return;
					}
					submission.accepted = true;
					submission.settled = true;
					submission.promise.fulfill(
						AgentSubmissionReceipt.appServerAccepted);
					releaseGatedUserEcho(submission);
				}, (Exception e) {
					if (submission.settled)
						return;
					removeExpectedUserMessage(submission);
					resetRejectedSubmission();
					rejectSubmission(submission, e);
					drainPendingMessages();
				}).ignoreResult();
		}
		catch (Exception e)
		{
			removeExpectedUserMessage(submission);
			resetRejectedSubmission();
			rejectSubmission(submission, e);
			drainPendingMessages();
		}
	}

	// ----- AgentSession interface -----

	Promise!AgentSubmissionReceipt sendMessage(const(ContentBlock)[] content, string correlationId = null,
		bool isContextBootstrap = false, string nativeSubmissionUuid = null)
	{
		// Extract text (only text blocks supported; throw on others).
		string text;
		foreach (ref b; content)
		{
			if (b.type == "text") text ~= b.text;
			else throw new Exception("Unsupported content block type for Copilot: " ~ b.type);
		}

		auto submission = new PendingMessage(content, text, correlationId,
			isContextBootstrap);
		if (!alive_)
		{
			submission.promise.reject(new Exception(
				"Copilot session is no longer alive"));
			return submission.promise;
		}

		if (!sessionReady_ || turnInProgress)
			pendingMessages ~= submission;
		else
			submitMessage(submission);
		return submission.promise;
	}

	void invalidatePendingSubmittedMessages()
	{
		rejectUnsettledMessages(new Exception(
			"Copilot message submission was invalidated"));
	}

	@property bool supportsImages() const { return false; }

	void interrupt()
	{
		if (!alive_ || sessionId.length == 0)
			return;
		SessionIdParams abortP;
		abortP.sessionId = sessionId;
		server.sendRequest("session.abort", toJson(abortP))
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
		rejectUnsettledMessages(new Exception(
			"Copilot session closed before accepting message submission"));
		if (sessionId.length > 0)
		{
			SessionIdParams stopP;
			stopP.sessionId = sessionId;
			server.sendRequest("session.abort", toJson(stopP))
			.then((JsonRpcResponse resp) {});
		}
		alive_ = false;
		forcedStop_ = true;
		server.shutdown();
	}

	void closeStdin()
	{
		rejectUnsettledMessages(new Exception(
			"Copilot session closed before accepting message submission"));
		if (!alive_)
			return;
		if (sessionId.length > 0)
		{
			SessionIdParams closeP;
			closeP.sessionId = sessionId;
			server.sendRequest("session.abort", toJson(closeP))
			.then((JsonRpcResponse resp) {});
		}
		alive_ = false;
		gracefulShutdown_ = true;
		server.shutdown();
	}

	void killAfterTimeout(Duration timeout) {} // no-op: server.shutdown handles graceful exit

	@property bool canStopAfterCloseStdin() const
	{
		return false;
	}

	@property void onNativeSessionStarted(void delegate(string sessionId) callback)
	{
		nativeSessionStartedHandler_ = callback;
		if (nativeSessionStartedHandler_ && sessionId.length > 0)
		{
			nativeSessionStartedNotified_ = true;
			nativeSessionStartedHandler_(sessionId);
		}
	}

	private void notifyNativeSessionStarted()
	{
		if (nativeSessionStartedNotified_)
			return;
		nativeSessionStartedNotified_ = true;
		if (nativeSessionStartedHandler_)
			nativeSessionStartedHandler_(sessionId);
	}

	@property void onOutput(void delegate(TranslatedEvent) dg) { outputHandler_ = dg; }
	@property void onStderr(void delegate(string line) dg) { stderrHandler_ = dg; }
	@property void onExit(void delegate(int status) dg) { exitHandler_ = dg; }
	@property bool alive() { return alive_ && (server is null || !server.dead); }

	// ----- SdkSessionHandler interface -----

	void handleEvent(SdkEvent event)
	{
		if (!alive_)
			return;
		if (replayMode)
		{
			if (event.type == "session.start")
				handleSessionStart(JSONFragment(event.data.toJson()));
			return;
		}

		import cydo.protocol : parseIso8601Timestamp;
		currentEventTs_ = parseIso8601Timestamp(event.timestamp);
		auto data = JSONFragment(event.data.toJson());
		currentRawJson_ = data.json;
		switch (event.type)
		{
			case "assistant.turn_start":
				handleTurnStart(event.id, data);
				break;
			case "assistant.message_delta":
				handleMessageDelta(data);
				break;
			case "assistant.message":
				handleAssistantMessage(event.id, data);
				break;
			case "assistant.reasoning_delta":
				handleReasoningDelta(data);
				break;
			case "tool.execution_start":
				handleToolExecutionStart(data);
				break;
			case "tool.execution_complete":
				handleToolExecutionComplete(data);
				break;
			case "user.message":
				handleUserMessage(event.id, data);
				break;
			case "assistant.turn_end":
				handleAssistantTurnEnd();
				break;
			case "session.idle":
				handleSessionIdle();
				break;
			case "session.start":
				handleSessionStart(data);
				break;
			case "session.resume":
				handleSessionResume(data);
				break;
			case "session.error":
				handleSessionError(data);
				break;
			case "external_tool.requested":
				handleExternalToolRequested(data);
				break;
			case "permission.requested":
				handlePermissionRequested(data);
				break;
			case "subagent.started":
				handleSubagentStarted(data);
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
			case "assistant.streaming_delta":
			case "assistant.usage":
			case "external_tool.completed":
			case "permission.completed":
				break;
			default:
				emitEvent(makeUnrecognizedEvent(
					"unknown copilot event: " ~ event.type), currentRawJson_);
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
		toolDispatch_(toolName, to!string(tid), JSONFragment(params.arguments.toJson()))
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
			ItemStartedEvent extStartEv;
			extStartEv.item_id   = itemId;
			extStartEv.item_type = "tool_use";
			extStartEv.name      = displayName;
			if (isCydo) { extStartEv.tool_server = "cydo"; extStartEv.tool_source = "mcp"; }
			extStartEv.input     = JSONFragment(inputJson);
			emitEvent(toJson(extStartEv), currentRawJson_);
			hadItemsSinceLastStop_ = true;
		}
		auto rawJson = currentRawJson_; // capture before async dispatch

		toolDispatch_(dispatchName, to!string(tid), req.arguments)
		.then((McpResult mcpResult) {
			// Emit completion events for the UI.
			ItemCompletedEvent extCompEv;
			extCompEv.item_id = itemId;
			extCompEv.input   = JSONFragment(inputJson);
			emitEvent(toJson(extCompEv), rawJson);

			ItemResultEvent extResEv;
			extResEv.item_id = itemId;
			extResEv.content = JSONFragment(toJson(mcpResult.text));
			emitEvent(toJson(extResEv), rawJson);

			if (!alive_ || server.dead) return;
			HandlePendingToolCallParams tcp;
			tcp.sessionId = sessionId;
			tcp.requestId = req.requestId;
			tcp.result    = ToolCallResultInner(mcpResult.text, mcpResult.isError ? "failure" : "success");
			server.sendRequest("session.tools.handlePendingToolCall", toJson(tcp))
				.ignoreResult();
		}, (Exception e) {
			if (!alive_ || server.dead) return;
			HandlePendingToolCallError tcpe;
			tcpe.sessionId = sessionId;
			tcpe.requestId = req.requestId;
			tcpe.error     = e.msg;
			server.sendRequest("session.tools.handlePendingToolCall", toJson(tcpe))
				.ignoreResult();
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

		if (!alive_ || server.dead) return;
		HandlePermissionRequestParams prp;
		prp.sessionId = sessionId;
		prp.requestId = req.requestId;
		prp.result    = permissionDecisionForCopilotVersion(copilotVersion_);
		server.sendRequest("session.permissions.handlePendingPermissionRequest", toJson(prp))
			.ignoreResult();
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

	void handleStartupFailure(Exception error)
	{
		rejectUnsettledMessages(error);
		handleExit(1);
	}

	void handleExit(int status)
	{
		rejectUnsettledMessages(new Exception(
			"Copilot session exited before accepting message submission"));
		alive_ = false;
		if (exitHandler_ is null)
			return;
		auto cb = exitHandler_;
		exitHandler_ = null;
		int code = gracefulShutdown_ ? 0 : (forcedStop_ ? 1 : status);
		cb(code);
	}

	// ----- Event handlers -----

	private void emitEvent(string translated, string rawJson = null)
	{
		if (outputHandler_)
			outputHandler_(TranslatedEvent(translated, rawJson.length > 0 ? rawJson : null, currentEventTs_));
	}

	private void handleTurnStart(string eventId, JSONFragment data)
	{
		assert(eventId.length > 0, "Copilot assistant.turn_start has no native ID");
		assert(currentAssistantMessageId_.length == 0,
			"Copilot assistant message ID leaked into the next sub-turn");
		turnInProgress = true;
		nextItemIndex = 0;
		activeTextItem = ActiveTextItem.init;
		activeTools = null;
		hadItemsSinceLastStop_ = false;
		currentSubagentParent_ = null;
		activeTurnNamespace_ = sessionId ~ "-" ~ eventId;
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
			assert(activeTurnNamespace_.length > 0, "Copilot text delta has no active turn namespace");
			auto id = "cp-text-" ~ activeTurnNamespace_ ~ "-" ~ to!string(nextItemIndex++);
			activeTextItem = ActiveTextItem(id, "text", "", currentSubagentParent_);
			ItemStartedEvent textStartEv;
			textStartEv.item_id            = id;
			textStartEv.item_type          = "text";
			textStartEv.parent_tool_use_id = currentSubagentParent_;
			emitEvent(toJson(textStartEv), currentRawJson_);
			hadItemsSinceLastStop_ = true;
		}

		activeTextItem.text ~= text;

		if (text.length > 0)
		{
			ItemDeltaEvent textDeltaEv;
			textDeltaEv.item_id    = activeTextItem.id;
			textDeltaEv.delta_type = "text_delta";
			textDeltaEv.content    = text;
			emitEvent(toJson(textDeltaEv), currentRawJson_);
		}
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
			assert(activeTurnNamespace_.length > 0, "Copilot thinking delta has no active turn namespace");
			auto id = "cp-think-" ~ activeTurnNamespace_ ~ "-" ~ to!string(nextItemIndex++);
			activeTextItem = ActiveTextItem(id, "thinking", "", currentSubagentParent_);
			ItemStartedEvent thinkStartEv;
			thinkStartEv.item_id            = id;
			thinkStartEv.item_type          = "thinking";
			thinkStartEv.parent_tool_use_id = currentSubagentParent_;
			emitEvent(toJson(thinkStartEv), currentRawJson_);
			hadItemsSinceLastStop_ = true;
		}

		activeTextItem.text ~= text;

		if (text.length > 0)
		{
			ItemDeltaEvent thinkDeltaEv;
			thinkDeltaEv.item_id    = activeTextItem.id;
			thinkDeltaEv.delta_type = "thinking_delta";
			thinkDeltaEv.content    = text;
			emitEvent(toJson(thinkDeltaEv), currentRawJson_);
		}
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

		ItemStartedEvent toolStartEv;
		toolStartEv.item_id            = id;
		toolStartEv.item_type          = "tool_use";
		toolStartEv.name               = name;
		if (toolServer.length > 0) { toolStartEv.tool_server = toolServer; toolStartEv.tool_source = toolSource; }
		toolStartEv.parent_tool_use_id = ts.parentToolCallId;
		toolStartEv.input              = JSONFragment(inputJson);
		emitEvent(toJson(toolStartEv), currentRawJson_);
		hadItemsSinceLastStop_ = true;

		// Emit the full input as a single input_json_delta so the UI can
		// display it during streaming.
		if (inputJson.length > 0 && inputJson != "{}")
		{
			ItemDeltaEvent inputDeltaEv;
			inputDeltaEv.item_id    = id;
			inputDeltaEv.delta_type = "input_json_delta";
			inputDeltaEv.content    = inputJson;
			emitEvent(toJson(inputDeltaEv), currentRawJson_);
		}
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
		ItemCompletedEvent tcCompEv;
		tcCompEv.item_id = p.id;
		tcCompEv.input   = JSONFragment(p.input.length > 0 ? p.input : `{}`);
		emitEvent(toJson(tcCompEv), currentRawJson_);
		// Emit item/result with tool output.
		ItemResultEvent tcResEv;
		tcResEv.item_id = p.id;
		tcResEv.content = JSONFragment(toJson(p.text));
		emitEvent(toJson(tcResEv), currentRawJson_);
		activeTools.remove(tc.toolCallId);
	}

	private void handleAssistantMessage(string eventId, JSONFragment data)
	{
		assert(eventId.length > 0, "Copilot assistant.message has no native ID");
		assert(currentAssistantMessageId_.length == 0,
			"Copilot sub-turn produced multiple assistant.message events");
		currentAssistantMessageId_ = eventId;
	}

	private void handleUserMessage(string eventId, JSONFragment data)
	{
		@JSONPartial static struct UserMessage { string content; }
		assert(eventId.length > 0, "Copilot user.message has no native ID");
		assert(expectedUserMessages.length > 0,
			"Copilot user.message has no queued originating send");
		auto message = jsonParse!UserMessage(data.json);
		auto expected = expectedUserMessages[0];
		assert(message.content == expected.content,
			"Copilot user.message content differs from its originating send");
		assert(!expected.nativeEchoSeen,
			"Copilot submission received multiple native user echoes");
		ContentBlock content;
		content.type = "text";
		content.text = message.content;
		ItemStartedEvent userEv;
		userEv.item_id = "cp-user-" ~ eventId;
		userEv.item_type = "user_message";
		userEv.content = [content];
		userEv.uuid = eventId;
		userEv.correlation_id = expected.submission.correlationId;
		auto translated = TranslatedEvent(toJson(userEv), currentRawJson_,
			currentEventTs_, 0, expected.submission.isContextBootstrap);
		if (expected.submission.accepted)
		{
			expectedUserMessages = expectedUserMessages[1 .. $];
			emitAcceptedUserEcho(expected.submission, translated);
		}
		else
		{
			expected.nativeEchoSeen = true;
			expected.submission.gatedUserEcho = translated;
			expected.submission.hasGatedUserEcho = true;
		}
	}

	private void handleSessionStart(JSONFragment data)
	{
		@JSONPartial
		static struct SessionStartData
		{
			@JSONOptional string copilotVersion;
		}

		try
		{
			auto start = jsonParse!SessionStartData(data.json);
			copilotVersion_ = start.copilotVersion;
		}
		catch (Exception) {}
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
		ProcessStderrEvent sessErrEv;
		sessErrEv.text = "Copilot error: " ~ se.message;
		emitEvent(toJson(sessErrEv), currentRawJson_);
	}

	// ----- Turn completion -----

	private void finalizeTurnItemsAndEmitStop(string uuid)
	{
		// Finalize any still-active text/thinking item.
		finalizeActiveTextItem();
		// Finalize any remaining in-flight tools (shouldn't happen normally,
		// but cleans up if turn ends before tool.execution_complete arrives).
		finalizeAllTools();

		TurnStopEvent tsEv;
		tsEv.model = model;
		tsEv.uuid = uuid;
		emitEvent(toJson(tsEv), currentRawJson_);
		hadItemsSinceLastStop_ = false;
	}

	private void handleAssistantTurnEnd()
	{
		assert(currentAssistantMessageId_.length > 0,
			"Copilot assistant.turn_end has no assistant.message identity");
		finalizeTurnItemsAndEmitStop(currentAssistantMessageId_);
		currentAssistantMessageId_ = null;
	}

	private void handleSessionIdle()
	{
		if (currentAssistantMessageId_.length > 0)
		{
			finalizeTurnItemsAndEmitStop(currentAssistantMessageId_);
			currentAssistantMessageId_ = null;
		}
		else
		{
			finalizeActiveTextItem();
			finalizeAllTools();
			hadItemsSinceLastStop_ = false;
		}
		turnInProgress = false;

		// Include the last text item as "result" so extractResultText can retrieve it.
		TurnResultEvent trEv;
		trEv.subtype        = "success";
		trEv.is_error       = false;
		trEv.num_turns      = 1;
		trEv.duration_ms    = 0;
		trEv.total_cost_usd = 0.0;
		trEv.result         = lastResultText;
		trEv.usage          = UsageInfo(0, 0);
		emitEvent(toJson(trEv), currentRawJson_);
		lastResultText = null;

		// Drain one pending message after the preceding turn has completed.
		drainPendingMessages();
	}

	/// Finalize the active text/thinking item: emit item/completed.
	/// No-op if there is no active text item.
	private void finalizeActiveTextItem()
	{
		if (activeTextItem.type.length == 0)
			return;

		if (activeTextItem.type == "text")
			lastResultText = activeTextItem.text;
		ItemCompletedEvent finTextEv;
		finTextEv.item_id = activeTextItem.id;
		finTextEv.text    = activeTextItem.text;
		emitEvent(toJson(finTextEv), currentRawJson_);

		activeTextItem = ActiveTextItem.init;
	}

	/// Finalize all remaining in-flight tools (at turn end).
	private void finalizeAllTools()
	{
		foreach (ref tool; activeTools)
		{
			if (tool.externallyHandled)
				continue;
			ItemCompletedEvent finToolEv;
			finToolEv.item_id = tool.id;
			finToolEv.input   = JSONFragment(tool.input.length > 0 ? tool.input : `{}`);
			emitEvent(toJson(finToolEv), currentRawJson_);
			ItemResultEvent finResEv;
			finResEv.item_id = tool.id;
			finResEv.content = JSONFragment(toJson(tool.text));
			emitEvent(toJson(finResEv), currentRawJson_);
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
				try d = jsonParse!OneShotDelta(event.data.toJson());
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

	void handleStartupFailure(Exception error)
	{
		if (!fulfilled_)
		{
			fulfilled_ = true;
			promise_.reject(error);
		}
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

version (unittest) private final class TestCopilotConnection : IConnection
{
	string[] sentMessages;
	private ReadDataHandler readDataHandler;

	@property ConnectionState state()
	{
		return ConnectionState.connected;
	}

	void send(scope Data[] data, int priority = DEFAULT_PRIORITY)
	{
		ubyte[] message;
		foreach (ref datum; data)
			datum.enter((contents) { message ~= cast(ubyte[]) contents; });
		sentMessages ~= cast(string) message;
	}
	alias send = IConnection.send;

	JsonRpcRequest takeRequest(string expectedMethod)
	{
		assert(sentMessages.length > 0,
			"Copilot test connection has no pending request");
		auto request = jsonParse!JsonRpcRequest(sentMessages[0]);
		sentMessages = sentMessages[1 .. $];
		assert(request.method == expectedMethod,
			"Unexpected Copilot request method: " ~ request.method);
		assert(request.id, "Copilot request has no JSON-RPC id");
		return request;
	}

	void respond(JsonRpcRequest request, JsonRpcResponse response)
	{
		import ae.utils.array : asBytes;

		assert(readDataHandler !is null,
			"Copilot test connection has no response handler");
		response.id = request.id;
		readDataHandler(Data(toJson(response).asBytes));
	}

	void receive(string message)
	{
		import ae.utils.array : asBytes;

		assert(readDataHandler !is null,
			"Copilot test connection has no response handler");
		readDataHandler(Data(message.asBytes));
	}

	void disconnect(string reason = defaultDisconnectReason,
		DisconnectType type = DisconnectType.requested)
	{
		assert(false, reason);
	}
	@property void handleConnect(ConnectHandler value) {}
	@property void handleReadData(ReadDataHandler value) { readDataHandler = value; }
	@property void handleDisconnect(DisconnectHandler value) {}
	@property void handleBufferFlushed(BufferFlushedHandler value) {}
}

version (unittest) private final class TestCopilotSubmissionOutcome
{
	int acceptedCount;
	int rejectedCount;
	string rejectionMessage;

	this(Promise!AgentSubmissionReceipt promise)
	{
		promise.then((AgentSubmissionReceipt receipt) {
			assert(receipt == AgentSubmissionReceipt.appServerAccepted);
			acceptedCount++;
		}, (Exception error) {
			rejectedCount++;
			rejectionMessage = error.msg;
		}).ignoreResult();
	}
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

private:

// ---- JSON-RPC param structs ----

private struct SessionIdParams { string sessionId; }
private struct SessionSendParams { string sessionId; string prompt; }

private struct ToolCallResultInner { string textResultForLlm; string resultType; }
private struct HandlePendingToolCallParams
{
	string sessionId;
	string requestId;
	ToolCallResultInner result;
}
private struct HandlePendingToolCallError
{
	string sessionId;
	string requestId;
	string error;
}

private struct PermissionDecision { string kind; }
private enum PermissionDecision PermissionDecisionApproved = PermissionDecision("approved");
private enum PermissionDecision PermissionDecisionApproveOnce = PermissionDecision("approve-once");
private struct HandlePermissionRequestParams
{
	string sessionId;
	string requestId;
	PermissionDecision result;
}

private struct CopilotCliVersion
{
	uint[3] components;
	bool valid;
}

private CopilotCliVersion parseCopilotCliVersion(string versionText)
{
	CopilotCliVersion parsed;
	uint componentIndex;
	bool sawDigit;

	foreach (ch; versionText)
	{
		if (ch >= '0' && ch <= '9')
		{
			auto digit = cast(uint)(ch - '0');
			auto current = parsed.components[componentIndex];
			if (current > (uint.max - digit) / 10)
				return CopilotCliVersion.init;
			parsed.components[componentIndex] = current * 10 + digit;
			sawDigit = true;
			continue;
		}

		if (ch == '.')
		{
			if (!sawDigit || componentIndex >= parsed.components.length - 1)
				return CopilotCliVersion.init;
			componentIndex++;
			sawDigit = false;
			continue;
		}

		return CopilotCliVersion.init;
	}

	if (!sawDigit || componentIndex != parsed.components.length - 1)
		return CopilotCliVersion.init;

	parsed.valid = true;
	return parsed;
}

private bool copilotVersionUsesApproveOnce(string versionText)
{
	auto parsed = parseCopilotCliVersion(versionText);
	if (!parsed.valid)
		return false;

	immutable uint[3] threshold = [1u, 0u, 39u];
	foreach (i; 0 .. parsed.components.length)
	{
		if (parsed.components[i] > threshold[i])
			return true;
		if (parsed.components[i] < threshold[i])
			return false;
	}
	return true;
}

private PermissionDecision permissionDecisionForCopilotVersion(string versionText)
{
	return copilotVersionUsesApproveOnce(versionText)
		? PermissionDecisionApproveOnce
		: PermissionDecisionApproved;
}

unittest
{
	import ae.net.asockets : socketManager;
	import std.algorithm.searching : canFind;

	void drainPromiseNextTicks()
	{
		for (;;)
		{
			auto handlers = __traits(getMember, socketManager,
				"nextTickHandlers");
			if (handlers.length == 0)
				return;
			mixin(`__traits(getMember, socketManager, "nextTickHandlers") = null;`);
			foreach (handler; handlers)
				handler();
		}
	}

	JsonRpcResponse acceptedResponse(string resultJson = `{}`)
	{
		JsonRpcResponse response;
		response.result = jsonParse!(typeof(response.result))(resultJson);
		return response;
	}

	JsonRpcResponse rejectedResponse(string message)
	{
		JsonRpcResponse response;
		response.error = JsonRpcError.fromCode(
			JsonRpcErrorCode.invalidRequest, message);
		return response;
	}

	void assertPending(TestCopilotSubmissionOutcome outcome)
	{
		assert(outcome.acceptedCount == 0 && outcome.rejectedCount == 0);
	}

	void assertAcceptedOnce(TestCopilotSubmissionOutcome outcome)
	{
		assert(outcome.acceptedCount == 1 && outcome.rejectedCount == 0);
	}

	void assertRejectedOnce(TestCopilotSubmissionOutcome outcome,
		string expectedMessage = null)
	{
		assert(outcome.acceptedCount == 0 && outcome.rejectedCount == 1);
		assert(outcome.rejectionMessage.length > 0);
		if (expectedMessage.length > 0)
			assert(outcome.rejectionMessage == expectedMessage);
	}

	// The create owner leaves a production sendMessage promise pending until
	// session readiness, then the matching codec response accepts it once.
	{
		auto connection = new TestCopilotConnection;
		auto server = makeTestSdkProcess(connection);
		SessionConfig config;
		config.model = "test-model";
		auto session = attachSession(server, 1, "create-success", null,
			"test-model", "/test/workdir", null, null, config);
		auto createRequest = connection.takeRequest("session.create");
		auto createParams = jsonParse!SessionCreateParams(
			toJson(createRequest.params));
		assert(createParams.sessionId == session.sessionId
			&& createParams.model == "test-model"
			&& createParams.workingDirectory == "/test/workdir");

		string[] emitted;
		session.onOutput = (TranslatedEvent event) {
			emitted ~= event.translated;
		};
		auto submission = new TestCopilotSubmissionOutcome(
			session.sendMessage([ContentBlock("text", "pre-ready")],
				"pre-ready-nonce", true));
		assertPending(submission);
		assert(session.pendingMessages.length == 1);
		assert(connection.sentMessages.length == 0);

		connection.respond(createRequest, acceptedResponse());
		drainPromiseNextTicks();
		assertPending(submission);
		assert(session.sessionReady_ && session.pendingMessages.length == 0
			&& session.expectedUserMessages.length == 1);
		assert(emitted.length == 1
			&& emitted[0].canFind(`"type":"session/init"`));
		emitted = null;

		auto sendRequest = connection.takeRequest("session.send");
		auto sendParams = jsonParse!SessionSendParams(toJson(sendRequest.params));
		assert(sendParams.sessionId == session.sessionId
			&& sendParams.prompt == "pre-ready");
		connection.respond(sendRequest,
			acceptedResponse(`{"messageId":"accepted-pre-ready"}`));
		drainPromiseNextTicks();
		assertAcceptedOnce(submission);
		assert(session.turnInProgress);
		assert(emitted.length == 0,
			"session.send acceptance fabricated a translated event");

		session.invalidatePendingSubmittedMessages();
		drainPromiseNextTicks();
		assertAcceptedOnce(submission);
	}

	// A successful response and its native user echo can be read back-to-back.
	// The App acceptance continuation must run before either echo is emitted.
	{
		auto connection = new TestCopilotConnection;
		auto server = makeTestSdkProcess(connection);
		auto session = new CopilotSession(server, 7, "echo-order",
			"test-model", "/test/workdir");
		server.registerSession("echo-order", session);
		session.onSessionStarted("test-model", "/test/workdir");

		bool firstAccepted;
		bool secondAccepted;
		string[] correlations;
		session.onOutput = (TranslatedEvent event) {
			if (!event.translated.canFind(`"item_type":"user_message"`))
				return;
			auto user = jsonParse!ItemStartedEvent(event.translated);
			if (user.correlation_id == "first-nonce")
				assert(firstAccepted);
			else
			{
				assert(user.correlation_id == "second-nonce");
				assert(secondAccepted);
			}
			correlations ~= user.correlation_id;
		};

		session.sendMessage([ContentBlock("text", "first prompt")],
			"first-nonce").then((AgentSubmissionReceipt receipt) {
			assert(receipt == AgentSubmissionReceipt.appServerAccepted);
			firstAccepted = true;
		}).ignoreResult();
		auto firstRequest = connection.takeRequest("session.send");
		connection.respond(firstRequest, acceptedResponse());
		connection.receive(`{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"echo-order","event":{"id":"first-native","timestamp":"2026-07-24T00:00:00Z","type":"user.message","data":{"content":"first prompt"}}}}`);
		assert(!firstAccepted && correlations.length == 0);
		drainPromiseNextTicks();
		assert(firstAccepted && correlations == ["first-nonce"]);

		session.handleSessionIdle();
		session.sendMessage([ContentBlock("text", "second prompt")],
			"second-nonce").then((AgentSubmissionReceipt receipt) {
			assert(receipt == AgentSubmissionReceipt.appServerAccepted);
			secondAccepted = true;
		}).ignoreResult();
		auto secondRequest = connection.takeRequest("session.send");
		connection.respond(secondRequest, acceptedResponse());
		connection.receive(`{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"echo-order","event":{"id":"second-native","timestamp":"2026-07-24T00:00:01Z","type":"user.message","data":{"content":"second prompt"}}}}`);
		assert(!secondAccepted && correlations == ["first-nonce"]);
		drainPromiseNextTicks();
		assert(secondAccepted && correlations == ["first-nonce", "second-nonce"]);
	}

	// A rejected session.send restores the idle state, rejects only its own
	// record, and immediately submits the queued successor with a distinct ID.
	{
		auto connection = new TestCopilotConnection;
		auto server = makeTestSdkProcess(connection);
		auto session = new CopilotSession(server, 2, "send-rejection",
			"test-model", "/test/workdir");
		string[] emitted;
		session.onOutput = (TranslatedEvent event) {
			emitted ~= event.translated;
		};
		session.onSessionStarted("test-model", "/test/workdir");
		emitted = null;

		auto rejected = new TestCopilotSubmissionOutcome(
			session.sendMessage([ContentBlock("text", "reject me")], "reject"));
		auto rejectedRequest = connection.takeRequest("session.send");
		auto successor = new TestCopilotSubmissionOutcome(
			session.sendMessage([ContentBlock("text", "accept me")], "successor"));
		assertPending(rejected);
		assertPending(successor);
		assert(session.pendingMessages.length == 1);

		connection.respond(rejectedRequest,
			rejectedResponse("session.send rejected"));
		drainPromiseNextTicks();
		assertRejectedOnce(rejected, "session.send rejected");
		assertPending(successor);
		assert(session.pendingMessages.length == 0
			&& session.expectedUserMessages.length == 1
			&& session.turnInProgress);
		assert(emitted.length == 0,
			"session.send rejection fabricated a turn result or acknowledgment");

		auto successorRequest = connection.takeRequest("session.send");
		auto successorParams = jsonParse!SessionSendParams(
			toJson(successorRequest.params));
		assert(successorParams.prompt == "accept me");
		assert(rejectedRequest.id.toJson() != successorRequest.id.toJson());
		connection.respond(successorRequest,
			acceptedResponse(`{"messageId":"accepted-successor"}`));
		drainPromiseNextTicks();
		assertRejectedOnce(rejected, "session.send rejected");
		assertAcceptedOnce(successor);
		assert(emitted.length == 0);
	}

	void exerciseLifecycleLoss(string label,
		void delegate(CopilotSession) loseLifecycle, bool remainsAlive)
	{
		auto connection = new TestCopilotConnection;
		auto server = makeTestSdkProcess(connection);
		auto session = new CopilotSession(server, 3, "lifecycle-" ~ label,
			"test-model", "/test/workdir");
		session.onSessionStarted("test-model", "/test/workdir");

		auto inFlight = new TestCopilotSubmissionOutcome(
			session.sendMessage([ContentBlock("text", label ~ " in flight")],
				label ~ "-flight"));
		auto captured = connection.takeRequest("session.send");
		auto queued = new TestCopilotSubmissionOutcome(
			session.sendMessage([ContentBlock("text", label ~ " queued")],
				label ~ "-queued"));
		assert(session.expectedUserMessages.length == 1
			&& session.pendingMessages.length == 1);

		loseLifecycle(session);
		loseLifecycle(session);
		drainPromiseNextTicks();
		assertRejectedOnce(inFlight);
		assertRejectedOnce(queued);
		assert(session.alive_ == remainsAlive);
		assert(session.expectedUserMessages.length == 0
			&& session.pendingMessages.length == 0);

		connection.respond(captured,
			acceptedResponse(`{"messageId":"late-` ~ label ~ `"}`));
		drainPromiseNextTicks();
		assertRejectedOnce(inFlight);
		assertRejectedOnce(queued);
		assert(session.expectedUserMessages.length == 0
			&& session.pendingMessages.length == 0);
		assert(connection.sentMessages.length == 0,
			"late response drained or resurrected a submission");
	}

	exerciseLifecycleLoss("invalidation",
		(CopilotSession session) {
			session.invalidatePendingSubmittedMessages();
		}, true);
	exerciseLifecycleLoss("exit",
		(CopilotSession session) {
			session.handleExit(17);
		}, false);

	void exerciseCloseOwner(string label,
		void delegate(CopilotSession) closeOwner, int expectedExitStatus)
	{
		auto connection = new TestCopilotConnection;
		auto server = makeTestSdkProcess(connection);
		auto sessionId = "close-" ~ label;
		auto session = new CopilotSession(server, 4, sessionId,
			"test-model", "/test/workdir");
		server.registerSession(sessionId, session);
		session.onSessionStarted("test-model", "/test/workdir");

		int[] exitStatuses;
		session.onExit = (int status) { exitStatuses ~= status; };
		auto inFlight = new TestCopilotSubmissionOutcome(
			session.sendMessage([ContentBlock("text", label ~ " in flight")],
				label ~ "-flight"));
		auto captured = connection.takeRequest("session.send");
		auto queued = new TestCopilotSubmissionOutcome(
			session.sendMessage([ContentBlock("text", label ~ " queued")],
				label ~ "-queued"));

		closeOwner(session);
		closeOwner(session);
		auto abortRequest = connection.takeRequest("session.abort");
		auto abortParams = jsonParse!SessionIdParams(toJson(abortRequest.params));
		assert(abortParams.sessionId == sessionId);
		assert(connection.sentMessages.length == 0);
		drainPromiseNextTicks();
		assertRejectedOnce(inFlight);
		assertRejectedOnce(queued);
		assert(exitStatuses == [expectedExitStatus]);
		assert(server.dead && !session.alive);

		connection.respond(captured,
			acceptedResponse(`{"messageId":"late-close"}`));
		drainPromiseNextTicks();
		assertRejectedOnce(inFlight);
		assertRejectedOnce(queued);
		assert(connection.sentMessages.length == 0);
	}

	exerciseCloseOwner("stdin",
		(CopilotSession session) { session.closeStdin(); }, 0);
	exerciseCloseOwner("stop",
		(CopilotSession session) { session.stop(); }, 1);

	// Ping rejection exercises SdkProcess.failStartup and the registered
	// session callback, including a message queued before SDK readiness.
	{
		auto connection = new TestCopilotConnection;
		auto server = makeTestSdkProcess(connection, true);
		auto pingRequest = connection.takeRequest("ping");
		auto session = new CopilotSession(server, 5, "ping-failure",
			"test-model", "/test/workdir");
		server.registerSession("ping-failure", session);
		auto queued = new TestCopilotSubmissionOutcome(
			session.sendMessage([ContentBlock("text", "wait for ping")],
				"ping-queued"));
		assertPending(queued);

		connection.respond(pingRequest, rejectedResponse("ping rejected"));
		drainPromiseNextTicks();
		assertRejectedOnce(queued, "ping rejected");
		assert(server.state == SdkProcess.State.failed && server.dead);
		assert(!session.alive_);

		session.handleStartupFailure(new Exception("duplicate ping failure"));
		drainPromiseNextTicks();
		assertRejectedOnce(queued, "ping rejected");
	}

	void exerciseSessionSetupFailure(string resumeSessionId,
		string expectedMethod)
	{
		auto connection = new TestCopilotConnection;
		auto server = makeTestSdkProcess(connection);
		SessionConfig config;
		config.model = "test-model";
		auto sessionId = resumeSessionId.length > 0
			? resumeSessionId : "create-failure";
		auto session = attachSession(server, 6, sessionId, resumeSessionId,
			"test-model", "/test/workdir", null, null, config);
		auto setupRequest = connection.takeRequest(expectedMethod);
		if (resumeSessionId.length > 0)
		{
			auto params = jsonParse!SessionResumeParams(
				toJson(setupRequest.params));
			assert(params.sessionId == sessionId
				&& params.model == "test-model");
			assert(session.replayMode);
		}
		else
		{
			auto params = jsonParse!SessionCreateParams(
				toJson(setupRequest.params));
			assert(params.sessionId == sessionId
				&& params.model == "test-model"
				&& params.workingDirectory == "/test/workdir");
		}

		string[] emitted;
		session.onOutput = (TranslatedEvent event) {
			emitted ~= event.translated;
		};
		auto queued = new TestCopilotSubmissionOutcome(
			session.sendMessage([ContentBlock("text", "queued setup")],
				"setup-queued"));
		assertPending(queued);
		assert(connection.sentMessages.length == 0);

		connection.respond(setupRequest,
			rejectedResponse("setup rejected"));
		drainPromiseNextTicks();
		auto expectedError = expectedMethod ~ " error: setup rejected";
		assertRejectedOnce(queued, expectedError);
		assert(!session.alive_ && !session.sessionReady_);
		assert(session.pendingMessages.length == 0
			&& session.expectedUserMessages.length == 0);
		assert(connection.sentMessages.length == 0);
		if (resumeSessionId.length > 0)
		{
			assert(!session.replayMode);
			assert(emitted.length == 1
				&& emitted[0].canFind(expectedError));
		}
		else
			assert(emitted.length == 0);

		session.handleStartupFailure(new Exception("duplicate setup failure"));
		drainPromiseNextTicks();
		assertRejectedOnce(queued, expectedError);
	}

	exerciseSessionSetupFailure(null, "session.create");
	exerciseSessionSetupFailure("resume-failure", "session.resume");
}

unittest
{
	import ae.net.asockets : socketManager;
	import std.algorithm.searching : canFind;

	void drainPromiseNextTicks()
	{
		for (;;)
		{
			auto handlers = __traits(getMember, socketManager,
				"nextTickHandlers");
			if (handlers.length == 0)
				return;
			mixin(`__traits(getMember, socketManager, "nextTickHandlers") = null;`);
			foreach (handler; handlers)
				handler();
		}
	}

	JsonRpcResponse acceptedResponse()
	{
		JsonRpcResponse response;
		response.result = jsonParse!(typeof(response.result))(`{}`);
		return response;
	}

	auto connection = new TestCopilotConnection;
	auto server = makeTestSdkProcess(connection);
	auto session = new CopilotSession(server, 7, "pre-echo-order",
		"test-model", "/test/workdir");
	server.registerSession("pre-echo-order", session);
	session.onSessionStarted("test-model", "/test/workdir");

	TranslatedEvent[] userEchoes;
	session.onOutput = (TranslatedEvent event) {
		if (event.translated.canFind(`"item_type":"user_message"`))
			userEchoes ~= event;
	};
	bool systemAccepted;
	bool userAccepted;
	session.sendMessage([ContentBlock("text", "[SYSTEM: internal reminder]")])
		.then((AgentSubmissionReceipt receipt) {
			assert(receipt == AgentSubmissionReceipt.appServerAccepted);
			systemAccepted = true;
		}).ignoreResult();
	auto systemRequest = connection.takeRequest("session.send");
	connection.respond(systemRequest, acceptedResponse());
	drainPromiseNextTicks();
	assert(systemAccepted && session.expectedUserMessages.length == 1);

	// Copilot can declare the preceding turn idle before it emits that turn's
	// native user echo. A following user submission must remain independently
	// accepted and retain its place behind the system message's echo.
	session.handleSessionIdle();
	session.sendMessage([ContentBlock("text", "ordinary prompt")], "user-nonce")
		.then((AgentSubmissionReceipt receipt) {
			assert(receipt == AgentSubmissionReceipt.appServerAccepted);
			userAccepted = true;
		}).ignoreResult();
	auto userRequest = connection.takeRequest("session.send");
	connection.respond(userRequest, acceptedResponse());
	drainPromiseNextTicks();
	assert(systemAccepted && userAccepted);
	assert(session.expectedUserMessages.length == 2);
	assert(userEchoes.length == 0);

	connection.receive(`{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"pre-echo-order","event":{"id":"native-system","timestamp":"2026-07-24T00:00:00Z","type":"user.message","data":{"content":"[SYSTEM: internal reminder]"}}}}`);
	drainPromiseNextTicks();
	assert(userEchoes.length == 1);
	auto systemEcho = jsonParse!ItemStartedEvent(userEchoes[0].translated);
	assert(systemEcho.correlation_id.length == 0);
	assert(systemEcho.content.length == 1
		&& systemEcho.content[0].text == "[SYSTEM: internal reminder]");

	connection.receive(`{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"pre-echo-order","event":{"id":"native-user","timestamp":"2026-07-24T00:00:01Z","type":"user.message","data":{"content":"ordinary prompt"}}}}`);
	drainPromiseNextTicks();
	assert(userEchoes.length == 2);
	auto userEcho = jsonParse!ItemStartedEvent(userEchoes[1].translated);
	assert(userEcho.correlation_id == "user-nonce");
	assert(userEcho.content.length == 1
		&& userEcho.content[0].text == "ordinary prompt");
	assert(session.expectedUserMessages.length == 0);
}

unittest
{
	import ae.net.asockets : socketManager;
	import std.algorithm.searching : canFind;

	void drainPromiseNextTicks()
	{
		for (;;)
		{
			auto handlers = __traits(getMember, socketManager,
				"nextTickHandlers");
			if (handlers.length == 0)
				return;
			mixin(`__traits(getMember, socketManager, "nextTickHandlers") = null;`);
			foreach (handler; handlers)
				handler();
		}
	}

	JsonRpcResponse acceptedResponse()
	{
		JsonRpcResponse response;
		response.result = jsonParse!(typeof(response.result))(`{}`);
		return response;
	}

	auto connection = new TestCopilotConnection;
	auto server = makeTestSdkProcess(connection);
	auto session = new CopilotSession(server, 8, "two-nonce-pre-echo",
		"test-model", "/test/workdir");
	server.registerSession("two-nonce-pre-echo", session);
	session.onSessionStarted("test-model", "/test/workdir");

	TranslatedEvent[] userEchoes;
	session.onOutput = (TranslatedEvent event) {
		if (event.translated.canFind(`"item_type":"user_message"`))
			userEchoes ~= event;
	};
	bool firstAccepted;
	bool secondAccepted;
	session.sendMessage([ContentBlock("text", "first prompt")], "first-nonce")
		.then((AgentSubmissionReceipt receipt) {
			assert(receipt == AgentSubmissionReceipt.appServerAccepted);
			firstAccepted = true;
		}).ignoreResult();
	auto firstRequest = connection.takeRequest("session.send");
	auto firstParams = jsonParse!SessionSendParams(toJson(firstRequest.params));
	assert(firstParams.prompt == "first prompt");
	connection.respond(firstRequest, acceptedResponse());
	drainPromiseNextTicks();
	assert(firstAccepted && session.expectedUserMessages.length == 1);

	// Copilot can become idle before its first user.message event reaches us.
	// Submit and accept a second nonce-bearing prompt before either native echo.
	session.handleSessionIdle();
	session.sendMessage([ContentBlock("text", "second prompt")], "second-nonce")
		.then((AgentSubmissionReceipt receipt) {
			assert(receipt == AgentSubmissionReceipt.appServerAccepted);
			secondAccepted = true;
		}).ignoreResult();
	auto secondRequest = connection.takeRequest("session.send");
	auto secondParams = jsonParse!SessionSendParams(toJson(secondRequest.params));
	assert(secondParams.prompt == "second prompt");
	connection.respond(secondRequest, acceptedResponse());
	drainPromiseNextTicks();
	assert(firstAccepted && secondAccepted
		&& session.expectedUserMessages.length == 2 && userEchoes.length == 0);

	connection.receive(`{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"two-nonce-pre-echo","event":{"id":"native-first","timestamp":"2026-07-24T00:00:00Z","type":"user.message","data":{"content":"first prompt"}}}}`);
	drainPromiseNextTicks();
	assert(userEchoes.length == 1);
	auto firstEcho = jsonParse!ItemStartedEvent(userEchoes[0].translated);
	assert(firstEcho.correlation_id == "first-nonce"
		&& firstEcho.content.length == 1
		&& firstEcho.content[0].text == "first prompt");

	connection.receive(`{"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"two-nonce-pre-echo","event":{"id":"native-second","timestamp":"2026-07-24T00:00:01Z","type":"user.message","data":{"content":"second prompt"}}}}`);
	drainPromiseNextTicks();
	assert(userEchoes.length == 2);
	auto secondEcho = jsonParse!ItemStartedEvent(userEchoes[1].translated);
	assert(secondEcho.correlation_id == "second-nonce"
		&& secondEcho.content.length == 1
		&& secondEcho.content[0].text == "second prompt"
		&& session.expectedUserMessages.length == 0);
}

unittest
{
	assert(!copilotVersionUsesApproveOnce("1.0.9"));
	assert(!copilotVersionUsesApproveOnce("1.0.38"));
	assert(copilotVersionUsesApproveOnce("1.0.39"));
	assert(copilotVersionUsesApproveOnce("1.0.40"));
}

unittest
{
	import std.algorithm : canFind;

	auto session = new CopilotSession(null, 1, "session-123", "", ".");
	session.startReplay();

	SdkEvent event;
	event.type = "session.start";
	event.data = jsonParse!(typeof(event.data))(`{"copilotVersion":"1.0.39"}`);
	session.handleEvent(event);

	assert(session.copilotVersion_ == "1.0.39");
}

unittest
{
	import ae.net.asockets : socketManager;
	import std.algorithm : canFind;

	void drainPromiseNextTicks()
	{
		for (;;)
		{
			auto handlers = __traits(getMember, socketManager,
				"nextTickHandlers");
			if (handlers.length == 0)
				return;
			mixin(`__traits(getMember, socketManager, "nextTickHandlers") = null;`);
			foreach (handler; handlers)
				handler();
		}
	}

	auto session = new CopilotSession(null, 1, "session-123", "", ".");
	string[] output;
	session.outputHandler_ = (event) { output ~= event.translated; };
	auto internalSubmission = new CopilotSession.PendingMessage(
		[ContentBlock("text", "[SYSTEM: internal]")], "[SYSTEM: internal]", null, false);
	auto ordinarySubmission = new CopilotSession.PendingMessage(
		[ContentBlock("text", "ordinary")], "ordinary", "nonce-1", false);
	internalSubmission.accepted = true;
	ordinarySubmission.accepted = true;
	session.expectedUserMessages = [
		new CopilotSession.ExpectedUserMessage(internalSubmission),
		new CopilotSession.ExpectedUserMessage(ordinarySubmission),
	];

	SdkEvent internal;
	internal.id = "native-system-1";
	internal.type = "user.message";
	internal.data = jsonParse!(typeof(internal.data))(`{"content":"[SYSTEM: internal]"}`);
	session.handleEvent(internal);
	drainPromiseNextTicks();
	assert(output.length == 1);
	assert(output[0].canFind(`"uuid":"native-system-1"`));
	assert(!output[0].canFind(`"correlation_id"`));

	SdkEvent user;
	user.id = "native-user-1";
	user.type = "user.message";
	user.data = jsonParse!(typeof(user.data))(`{"content":"ordinary"}`);
	session.handleEvent(user);
	drainPromiseNextTicks();
	assert(output.length == 2);
	assert(output[1].canFind(`"uuid":"native-user-1"`));
	assert(output[1].canFind(`"correlation_id":"nonce-1"`));

	SdkEvent start;
	start.id = "native-turn-start-1";
	start.type = "assistant.turn_start";
	start.data = jsonParse!(typeof(start.data))(`{}`);
	session.handleEvent(start);
	SdkEvent message;
	message.id = "native-assistant-1";
	message.type = "assistant.message";
	message.data = jsonParse!(typeof(message.data))(`{"content":""}`);
	session.handleEvent(message);
	SdkEvent end;
	end.type = "assistant.turn_end";
	end.data = jsonParse!(typeof(end.data))(`{}`);
	session.handleEvent(end);
	assert(output.length == 3);
	assert(output[2].canFind(`"type":"turn/stop"`));
	assert(output[2].canFind(`"uuid":"native-assistant-1"`));
}

unittest
{
	auto agent = new CopilotAgent;
	auto content = `{"type":"user.message","id":"system-id","data":{"content":"[SYSTEM: bootstrap"}}`
		~ "\n"
		~ `{"type":"user.message","id":"native-user-id","data":{"content":"ordinary"}}`
		~ "\n";
	auto boundaries = agent.extractPersistedHistoryBoundaries(content);
	assert(boundaries.length == 1);
	assert(boundaries[0].anchor == "native-user-id");
	assert(boundaries[0].kind == PersistedHistoryBoundaryKind.user);
}

unittest
{
	@JSONPartial
	struct SerializedPermissionRequest
	{
		string sessionId;
		string requestId;
		@JSONPartial struct ResultPayload { string kind; }
		ResultPayload result;
	}

	void assertPayloadKind(string versionText, string expectedKind)
	{
		HandlePermissionRequestParams params;
		params.sessionId = "session-123";
		params.requestId = "request-456";
		params.result    = permissionDecisionForCopilotVersion(versionText);

		auto json = toJson(params);
		auto expected = format(
			`{"sessionId":"session-123","requestId":"request-456","result":{"kind":"%s"}}`,
			expectedKind,
		);
		assert(
			json == expected,
			format(
				"session.permissions.handlePendingPermissionRequest payload mismatch for version '%s': %s",
				versionText,
				json,
			),
		);

		auto payload = jsonParse!SerializedPermissionRequest(json);
		assert(payload.sessionId == "session-123");
		assert(payload.requestId == "request-456");
		assert(payload.result.kind == expectedKind);
	}

	assertPayloadKind("1.0.9", "approved");
	assertPayloadKind("1.0.39", "approve-once");
	assertPayloadKind("1.0.40", "approve-once");
	assertPayloadKind("", "approved");
	assertPayloadKind("1.0.x", "approved");
}

// ---- Session create/resume param structs ----

private struct ToolDefinition
{
	string name;
	string description;
	JSONFragment parameters;
	bool skipPermission;
}

private struct SystemMessageParam
{
	string mode;
	string content;
}

private struct SessionCreateParams
{
	string sessionId;
	@JSONOptional string model;
	string clientName;
	string workingDirectory;
	bool streaming;
	bool requestPermission;
	JSONFragment tools;
	@JSONOptional JSONFragment systemMessage;
}

private struct SessionResumeParams
{
	string sessionId;
	@JSONOptional string model;
	bool streaming;
	bool requestPermission;
	JSONFragment tools;
	@JSONOptional JSONFragment systemMessage;
}

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
	ToolDefinition[] tools;
	tools ~= ToolDefinition("cydo-Task",
		taskToolDescription,
		JSONFragment(`{"type":"object","properties":{"tasks":{"type":"array","items":{"type":"object"}}},"required":["tasks"]}`),
		true);
	tools ~= ToolDefinition("cydo-Bash",
		"Execute a shell command and return its output",
		JSONFragment(`{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}`),
		true);
	tools ~= ToolDefinition("cydo-SwitchMode",
		"Switch this task to a different mode",
		JSONFragment(`{"type":"object","properties":{"continuation":{"type":"string"}},"required":["continuation"]}`),
		true);
	tools ~= ToolDefinition("cydo-Handoff",
		handoffToolDescription,
		JSONFragment(`{"type":"object","properties":{"continuation":{"type":"string"},"prompt":{"type":"string"}},"required":["continuation","prompt"]}`),
		true);
	tools ~= ToolDefinition("cydo-AskUserQuestion",
		"Ask the user one or more questions",
		JSONFragment(`{"type":"object","properties":{"questions":{"type":"array","items":{"type":"object"}}},"required":["questions"]}`),
		true);
	tools ~= ToolDefinition("cydo-Ask",
		"Ask a blocking question to a related task and wait for the answer",
		JSONFragment(`{"type":"object","properties":{"message":{"type":"string"},"tid":{"type":"integer"}},"required":["message"]}`),
		true);
	tools ~= ToolDefinition("cydo-Answer",
		"Answer a question from a related task",
		JSONFragment(`{"type":"object","properties":{"qid":{"type":"integer"},"message":{"type":"string"}},"required":["qid","message"]}`),
		true);
	return toJson(tools);
}

unittest
{
	SessionConfig config;
	config.mcpSocketPath = "/tmp/cydo-mcp.sock";
	auto tools = jsonParse!(ToolDefinition[])(buildToolDefinitions(config));

	string[] expectedNames = [
		"cydo-Task",
		"cydo-Bash",
		"cydo-SwitchMode",
		"cydo-Handoff",
		"cydo-AskUserQuestion",
		"cydo-Ask",
		"cydo-Answer",
	];
	string[] expectedSchemas = [
		`{"type":"object","properties":{"tasks":{"type":"array","items":{"type":"object"}}},"required":["tasks"]}`,
		`{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}`,
		`{"type":"object","properties":{"continuation":{"type":"string"}},"required":["continuation"]}`,
		`{"type":"object","properties":{"continuation":{"type":"string"},"prompt":{"type":"string"}},"required":["continuation","prompt"]}`,
		`{"type":"object","properties":{"questions":{"type":"array","items":{"type":"object"}}},"required":["questions"]}`,
		`{"type":"object","properties":{"message":{"type":"string"},"tid":{"type":"integer"}},"required":["message"]}`,
		`{"type":"object","properties":{"qid":{"type":"integer"},"message":{"type":"string"}},"required":["qid","message"]}`,
	];

	assert(tools.length == expectedNames.length);
	foreach (i, ref tool; tools)
	{
		assert(tool.name == expectedNames[i]);
		assert(tool.skipPermission);
		assert(tool.parameters.json == expectedSchemas[i]);
	}
	assert(tools[0].description == taskToolDescription);
	assert(tools[3].description == handoffToolDescription);
}

/// Build JSON params string for session.create.
string buildSessionCreateParams(string sessionId, string model, string workDir, SessionConfig config)
{
	SessionCreateParams p;
	p.sessionId         = sessionId;
	p.model             = model;
	p.clientName        = "cydo";
	p.workingDirectory  = workDir;
	p.streaming         = true;
	p.requestPermission = true;
	p.tools             = JSONFragment(buildToolDefinitions(config));
	if (config.appendSystemPrompt.length > 0)
	{
		SystemMessageParam sm;
		sm.mode    = "append";
		sm.content = config.appendSystemPrompt;
		p.systemMessage = JSONFragment(toJson(sm));
	}
	return toJson(p);
}

/// Build JSON params string for session.resume.
string buildSessionResumeParams(string sessionId, string model, SessionConfig config)
{
	SessionResumeParams p;
	p.sessionId         = sessionId;
	p.model             = model;
	p.streaming         = true;
	p.requestPermission = true;
	p.tools             = JSONFragment(buildToolDefinitions(config));
	if (config.appendSystemPrompt.length > 0)
	{
		SystemMessageParam sm;
		sm.mode    = "append";
		sm.content = config.appendSystemPrompt;
		p.systemMessage = JSONFragment(toJson(sm));
	}
	return toJson(p);
}

private struct CopilotMcpConfigEnv
{
	string CYDO_TID;
	string CYDO_SOCKET;
	string CYDO_CREATABLE_TYPES;
	string CYDO_SWITCHMODES;
	string CYDO_HANDOFFS;
	string CYDO_INCLUDE_TOOLS;
}

private struct CopilotMcpConfigServer
{
	string command;
	string[] args;
	CopilotMcpConfigEnv env;
	int timeout = 2_147_483_647;
}

private struct CopilotMcpConfigServers { CopilotMcpConfigServer cydo; }
private struct CopilotMcpConfig { CopilotMcpConfigServers mcpServers; }

unittest
{
	auto session = new CopilotSession(null, 1, "client-generated-id",
		"test-model", "/test/workdir");
	string[] order;
	session.onOutput = (TranslatedEvent event) { order ~= "output"; };
	session.onNativeSessionStarted = (string sessionId) {
		order ~= "native:" ~ sessionId;
	};
	assert(order == ["native:client-generated-id"]);

	session.onSessionStarted("test-model", "/test/workdir");
	assert(order == ["native:client-generated-id", "output"],
		"Copilot must publish its native ID once before synthetic session/init");

	auto lateSession = new CopilotSession(null, 2, "late-id", "test-model",
		"/test/workdir");
	lateSession.onSessionStarted("test-model", "/test/workdir");
	string delivered;
	lateSession.onNativeSessionStarted = (string sessionId) { delivered = sessionId; };
	assert(delivered == "late-id");
}

/// Generate a temporary MCP config file for Copilot's --additional-mcp-config flag.
string generateCopilotMcpConfig(int tid, const ref NativeHistoryProfile profile,
	string creatableTaskTypes,
	string switchModes, string handoffs, string[] includeTools, string mcpSocketPath)
{
	import std.array : join;
	import std.exception : enforce;
	import std.file : exists, mkdirRecurse, write;

	auto cydoBin = cydoBinaryPath;
	if (cydoBin.length == 0)
		return null;

	enforce(profile.driver == AgentDriver.copilot,
		"Copilot MCP config requires a Copilot native history profile");
	auto configDir = buildPath(profile.root, "mcp-configs");
	if (!exists(configDir))
		mkdirRecurse(configDir);

	auto configPath = buildPath(configDir, "cydo-" ~ to!string(tid) ~ ".json");

	import ae.utils.array : nonNull;

	auto cfg = CopilotMcpConfig(CopilotMcpConfigServers(CopilotMcpConfigServer(
		cydoBin,
		["mcp-server"],
		CopilotMcpConfigEnv(
			to!string(tid),
			mcpSocketPath.nonNull,
			creatableTaskTypes.nonNull,
			switchModes.nonNull,
			handoffs.nonNull,
			includeTools is null ? "" : includeTools.join(","),
		),
	)));
	write(configPath, toJson(cfg));
	return configPath;
}

unittest
{
	import std.exception : assertThrown;
	import std.file : exists, rmdirRecurse;
	import std.path : buildPath;

	auto root = buildPath("/tmp", "cydo-copilot-mcp-native-profile");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	auto profile = NativeHistoryProfile(AgentDriver.copilot,
		buildPath(root, "supplied-profile"));
	auto configPath = generateCopilotMcpConfig(43, profile, "", "", "", null, "");
	assert(configPath == buildPath(profile.root, "mcp-configs", "cydo-43.json"));
	assert(exists(configPath));
	auto wrongDriverProfile = NativeHistoryProfile(AgentDriver.codex,
		buildPath(root, "wrong-driver"));
	assertThrown!Exception(generateCopilotMcpConfig(43, wrongDriverProfile,
		"", "", "", null, ""));
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
