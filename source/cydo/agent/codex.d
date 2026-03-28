module cydo.agent.codex;

import std.conv : to;
import std.logger : errorf, tracef, warningf;
import std.path : buildPath, dirName;

import ae.net.asockets : IConnection;
import ae.net.jsonrpc.binding : JsonRpcDispatcher,
	jsonRpcDispatcher, RPCFlatten, RPCName, RPCNamedParams;
import ae.net.jsonrpc.codec : JsonRpcCodec;
import ae.sys.data : Data;
import ae.utils.json : JSONExtras, JSONFragment, JSONName, JSONOptional, JSONPartial,
	jsonParse, toJson;
import ae.utils.jsonrpc : JsonRpcErrorCode, JsonRpcRequest, JsonRpcResponse;
import ae.utils.promise : Promise, resolve;

import cydo.agent.agent : Agent, OneShotHandle, SessionConfig;
import cydo.agent.process : AgentProcess, FramingMode, LoggingAdapter;
import cydo.agent.protocol : ContentBlock;
import cydo.agent.session : AgentSession;
import cydo.config : PathMode;

// ---------------------------------------------------------------------------
// JSON-RPC param/result structs for the Codex app-server protocol.
// ---------------------------------------------------------------------------

// ---- Outgoing request params (CyDo → Codex) ----

@RPCFlatten @JSONPartial
struct InitializeParams
{
	static struct ClientInfo
	{
		string name;
		@JSONName("version") string version_;
	}
	ClientInfo clientInfo;
	JSONFragment capabilities;
}

@RPCFlatten @JSONPartial
struct LoginStartParams
{
	string type;
	string apiKey;
}

@RPCFlatten @JSONPartial
struct ThreadStartParams
{
	string cwd;
	string model;
	string approvalPolicy;
	string sandbox;
	@JSONOptional string developerInstructions;
	@JSONOptional JSONFragment config;
}

@RPCFlatten @JSONPartial
struct ThreadResumeParams
{
	string threadId;
	@JSONOptional string model;
	@JSONOptional string cwd;
	@JSONOptional string approvalPolicy;
	@JSONOptional string sandbox;
	@JSONOptional string developerInstructions;
	@JSONOptional JSONFragment config;
}

@RPCFlatten @JSONPartial
struct TurnStartInput
{
	string type;
	string text;
}

@RPCFlatten @JSONPartial
struct SandboxPolicy
{
	string type;
	string networkAccess;
}

@RPCFlatten @JSONPartial
struct TurnStartParams
{
	string threadId;
	TurnStartInput[] input;
	SandboxPolicy sandboxPolicy;
}

@RPCFlatten @JSONPartial
struct TurnSteerParams
{
	string threadId;
	string instructions;
}

@RPCFlatten @JSONPartial
struct TurnInterruptParams
{
	string threadId;
	string turnId;
}

// ---- Incoming notification params (Codex → CyDo) ----

@RPCFlatten @JSONPartial
struct ItemStartedParams
{
	string threadId;
	@JSONOptional string turnId;
	static struct Item
	{
		string type;
		@JSONOptional string id;
		@JSONOptional string name;
		@JSONOptional string text;
		@JSONOptional string command;
		@JSONOptional JSONFragment action;
		@JSONOptional JSONFragment content; // userMessage items: Array<UserInput>
		@JSONOptional string tool;          // mcpToolCall: tool name (e.g. "AskUserQuestion")
		@JSONOptional string server;        // mcpToolCall: server name (e.g. "cydo")
		JSONExtras extras;
	}
	Item item;
}

@RPCFlatten @JSONPartial
struct DeltaParams
{
	string threadId;
	string delta;
}

@RPCFlatten @JSONPartial
struct TerminalInteractionParams
{
	string threadId;
	string itemId;
	string processId;
	string stdin;
	string turnId;
}

@RPCFlatten @JSONPartial
struct ThreadIdParams
{
	string threadId;
}

@RPCFlatten @JSONPartial
struct TurnDiffUpdatedParams
{
	string threadId;
	string turnId;
	JSONFragment diff;
}

/// Catch-all params struct for no-op handlers that receive notifications
/// we don't process (may or may not have a threadId).
@RPCFlatten @JSONPartial
struct IgnoredParams
{
	@JSONOptional string threadId;
}

@RPCFlatten @JSONPartial
struct ItemCompletedParams
{
	string threadId;
	static struct Item
	{
		@JSONOptional string id;
		@JSONOptional bool is_error;
		@JSONOptional string aggregatedOutput; // commandExecution: stdout+stderr
		JSONExtras extras;
	}
	@JSONOptional Item item;
}

// ---- Response result types ----

@JSONPartial
struct ThreadStartResult
{
	@JSONPartial
	static struct Thread { string id; }
	Thread thread;
}

@JSONPartial
struct ApprovalDecision
{
	string decision;
}

// ---- Config struct for MCP override ----

struct McpServerConfig
{
	string command;
	string[] args;
	string[string] env;
	uint tool_timeout_sec;
}

// ---------------------------------------------------------------------------
// ICodexServer — methods Codex app-server calls on CyDo.
// ---------------------------------------------------------------------------

@RPCNamedParams
private interface ICodexServer
{
	@RPCName("item/started")
	Promise!void itemStarted(ItemStartedParams params);

	@RPCName("item/agentMessage/delta")
	Promise!void itemAgentMessageDelta(DeltaParams params);

	@RPCName("item/reasoning/textDelta")
	Promise!void itemReasoningTextDelta(DeltaParams params);

	@RPCName("item/reasoning/summaryTextDelta")
	Promise!void itemReasoningSummaryTextDelta(DeltaParams params);

	@RPCName("item/commandExecution/outputDelta")
	Promise!void itemCommandExecutionOutputDelta(DeltaParams params);

	@RPCName("item/commandExecution/terminalInteraction")
	Promise!void itemCommandExecutionTerminalInteraction(TerminalInteractionParams params);

	@RPCName("item/completed")
	Promise!void itemCompleted(ItemCompletedParams params);

	@RPCName("turn/completed")
	Promise!void turnCompleted(ThreadIdParams params);

	@RPCName("thread/compacted")
	Promise!void threadCompacted(ThreadIdParams params);

	@RPCName("thread/started")
	Promise!void threadStarted(IgnoredParams params);

	@RPCName("thread/status/changed")
	Promise!void threadStatusChanged(IgnoredParams params);

	@RPCName("turn/started")
	Promise!void turnStarted(IgnoredParams params);

	@RPCName("turn/diff/updated")
	Promise!void turnDiffUpdated(TurnDiffUpdatedParams params);

	@RPCName("thread/tokenUsage/updated")
	Promise!void threadTokenUsageUpdated(IgnoredParams params);

	@RPCName("account/rateLimits/updated")
	Promise!void accountRateLimitsUpdated(IgnoredParams params);

	@RPCName("account/updated")
	Promise!void accountUpdated(IgnoredParams params);

	@RPCName("account/login/completed")
	Promise!void accountLoginCompleted();

	@RPCName("item/commandExecution/requestApproval")
	Promise!ApprovalDecision commandExecutionApproval(ItemStartedParams params);

	@RPCName("item/fileChange/requestApproval")
	Promise!ApprovalDecision fileChangeApproval(ItemStartedParams params);

	@RPCName("item/fileChange/outputDelta")
	Promise!void itemFileChangeOutputDelta(DeltaParams params);
}

// ---------------------------------------------------------------------------
// CodexServerRouter — routes incoming Codex notifications to sessions.
// ---------------------------------------------------------------------------

private class CodexServerRouter : ICodexServer
{
	private AppServerProcess server;

	this(AppServerProcess s) { server = s; }

	private void routeToSession(string threadId,
		scope void delegate(CodexSession) handler)
	{
		if (auto session = threadId in server.sessions)
			handler(*session);
	}

	/// Build a JSON-RPC notification string for use as _raw provenance.
	/// Reconstructs the notification from the method name and serialized params.
	private static string buildRawNotification(string method, string paramsJson)
	{
		return `{"jsonrpc":"2.0","method":"` ~ method ~ `","params":` ~ paramsJson ~ `}`;
	}

	Promise!void itemStarted(ItemStartedParams params)
	{
		auto raw = buildRawNotification("item/started", toJson(params));
		routeToSession(params.threadId, (s) => s.handleItemStarted(params, raw));
		return resolve();
	}

	Promise!void itemAgentMessageDelta(DeltaParams params)
	{
		auto raw = buildRawNotification("item/agentMessage/delta", toJson(params));
		routeToSession(params.threadId,
			(s) => s.handleDelta(params, "text_delta", raw));
		return resolve();
	}

	Promise!void itemReasoningTextDelta(DeltaParams params)
	{
		auto raw = buildRawNotification("item/reasoning/textDelta", toJson(params));
		routeToSession(params.threadId,
			(s) => s.handleDelta(params, "thinking_delta", raw));
		return resolve();
	}

	Promise!void itemReasoningSummaryTextDelta(DeltaParams params)
	{
		auto raw = buildRawNotification("item/reasoning/summaryTextDelta", toJson(params));
		routeToSession(params.threadId,
			(s) => s.handleDelta(params, "thinking_delta", raw));
		return resolve();
	}

	Promise!void itemCommandExecutionOutputDelta(DeltaParams params)
	{
		auto raw = buildRawNotification("item/commandExecution/outputDelta", toJson(params));
		routeToSession(params.threadId,
			(s) => s.handleDelta(params, "output_delta", raw));
		return resolve();
	}

	Promise!void itemFileChangeOutputDelta(DeltaParams params)
	{
		auto raw = buildRawNotification("item/fileChange/outputDelta", toJson(params));
		routeToSession(params.threadId,
			(s) => s.handleDelta(params, "output_delta", raw));
		return resolve();
	}

	Promise!void itemCommandExecutionTerminalInteraction(TerminalInteractionParams params)
	{
		auto raw = buildRawNotification("item/commandExecution/terminalInteraction", toJson(params));
		routeToSession(params.threadId,
			(s) => s.handleTerminalInteraction(params, raw));
		return resolve();
	}

	Promise!void itemCompleted(ItemCompletedParams params)
	{
		auto raw = buildRawNotification("item/completed", toJson(params));
		routeToSession(params.threadId,
			(s) => s.handleItemCompleted(params, raw));
		return resolve();
	}

	Promise!void turnCompleted(ThreadIdParams params)
	{
		auto raw = buildRawNotification("turn/completed", toJson(params));
		routeToSession(params.threadId,
			(s) => s.handleTurnCompleted(raw));
		return resolve();
	}

	Promise!void threadStarted(IgnoredParams params) { return resolve(); }
	Promise!void threadStatusChanged(IgnoredParams params) { return resolve(); }
	Promise!void turnStarted(IgnoredParams params) { return resolve(); }
	Promise!void turnDiffUpdated(TurnDiffUpdatedParams params) { return resolve(); }
	Promise!void threadTokenUsageUpdated(IgnoredParams params) { return resolve(); }
	Promise!void accountRateLimitsUpdated(IgnoredParams params) { return resolve(); }
	Promise!void accountUpdated(IgnoredParams params) { return resolve(); }

	Promise!void threadCompacted(ThreadIdParams params)
	{
		auto raw = buildRawNotification("thread/compacted", toJson(params));
		routeToSession(params.threadId, (s) {
			import cydo.agent.protocol : injectRawField;
			if (s.outputHandler_)
				s.outputHandler_(injectRawField(`{"type":"session/compacted"}`, raw));
		});
		return resolve();
	}

	Promise!void accountLoginCompleted()
	{
		server.onLoginCompleted();
		return resolve();
	}

	Promise!ApprovalDecision commandExecutionApproval(ItemStartedParams params)
	{
		return resolve(ApprovalDecision("acceptForSession"));
	}

	Promise!ApprovalDecision fileChangeApproval(ItemStartedParams params)
	{
		return resolve(ApprovalDecision("acceptForSession"));
	}
}

// ---------------------------------------------------------------------------
// AppServerProcess — manages a `codex app-server` process via JSON-RPC 2.0.
// One instance per workspace, shared across multiple CodexSessions (threads).
// ---------------------------------------------------------------------------

class AppServerProcess
{
	private AgentProcess process;
	private JsonRpcCodec codec;
	private JsonRpcDispatcher!ICodexServer serverDispatcher;
	private bool terminating_;

	enum State { starting, initializing, authenticating, ready, failed, dead }
	private State state_ = State.starting;

	// Thread routing: threadId → session (populated after thread/start response)
	private CodexSession[string] sessions;
	// Task ID → session (populated at session creation, before thread/start)
	private CodexSession[int] sessionsByTid;

	// Actions queued until server reaches ready state.
	private void delegate()[] readyQueue;

	this(string[] args)
	{
		// Environment and current directory are handled by bwrap (included in args).
		process = new AgentProcess(args, null, null, false,
			FramingMode.ndjson, null, false);

		// Set up bidirectional JSON-RPC codec on the process connection.
		// The codec takes over handleReadData from stdoutLines; onStdoutLine
		// is no longer called.
		IConnection connection = process.connection;
		connection = new LoggingAdapter(connection, "codex");
		codec = new JsonRpcCodec(connection);

		// Dispatcher for incoming notifications/requests from Codex.
		auto router = new CodexServerRouter(this);
		serverDispatcher = jsonRpcDispatcher!ICodexServer(router);
		codec.handleRequest = (JsonRpcRequest request) {
			// Silently ignore v1 legacy notifications — they are always
			// duplicates of v2 item/* / turn/* methods.
			if (request.method.length >= 12 && request.method[0 .. 12] == "codex/event/")
				return resolve(JsonRpcResponse.init);
			return serverDispatcher.dispatch(request).then((JsonRpcResponse resp) {
				if (resp.isError && resp.error.get.code == JsonRpcErrorCode.methodNotFound)
				{
					import cydo.agent.protocol : makeUnrecognizedEvent;
					auto rawJsonRpc = `{"jsonrpc":"2.0","method":"` ~ request.method ~ `","params":`
						~ (request.params.json !is null ? request.params.json : "null") ~ `}`;
					auto event = makeUnrecognizedEvent("unknown method: " ~ request.method, rawJsonRpc);
					// Try to route to a specific session by threadId/conversationId.
					string routedId;
					if (request.params.json !is null)
					{
						import std.string : indexOf;
						foreach (key; ["threadId", "conversationId"])
						{
							auto needle = `"` ~ key ~ `":"`;
							auto idx = request.params.json.indexOf(needle);
							if (idx >= 0)
							{
								idx += needle.length;
								auto end = request.params.json.indexOf(`"`, idx);
								if (end > idx)
								{
									routedId = request.params.json[idx .. end];
									break;
								}
							}
						}
					}
					if (routedId.length > 0)
					{
						if (auto session = routedId in sessions)
							if (session.outputHandler_)
								session.outputHandler_(event);
					}
					else
					{
						foreach (session; sessionsByTid)
							if (session.outputHandler_)
								session.outputHandler_(event);
					}
				}
				return resp;
			});
		};

		process.onStderrLine = (string line) {
			foreach (session; sessionsByTid)
				if (session.stderrHandler_)
					session.stderrHandler_(line);
		};

		process.onExit = (int status) {
			state_ = State.dead;
			auto effectiveStatus = status;
			if (terminating_)
				effectiveStatus = 143;
			foreach (session; sessionsByTid)
				session.onServerExit(effectiveStatus);
		};

		// Begin initialization handshake.
		sendInitialize();
	}

	@property State state() { return state_; }

	void registerSession(string threadId, CodexSession session)
	{
		sessions[threadId] = session;
	}

	void unregisterSession(string threadId)
	{
		sessions.remove(threadId);
		if (sessions.length == 0 && sessionsByTid.length == 0)
			shutdown();
	}

	void registerSessionByTid(int tid, CodexSession session)
	{
		sessionsByTid[tid] = session;
	}

	void unregisterSessionByTid(int tid)
	{
		sessionsByTid.remove(tid);
		if (sessions.length == 0 && sessionsByTid.length == 0)
			shutdown();
	}

	/// Queue an action for when the server is ready. Runs immediately if
	/// already ready; silently dropped if failed/dead.
	void onReady(void delegate() dg)
	{
		if (state_ == State.ready)
			dg();
		else if (state_ != State.failed && state_ != State.dead)
			readyQueue ~= dg;
	}

	void terminate()
	{
		if (process.dead || terminating_)
			return;
		terminating_ = true;
		// codex app-server runs over stdio; closing stdin reliably triggers
		// shutdown even when SIGTERM is not handled promptly.
		process.closeStdin();
		process.terminate();
		import core.time : msecs;
		import core.sys.posix.signal : SIGKILL;
		import ae.sys.timing : setTimeout;
		setTimeout({
			if (!process.dead)
				process.sendSignal(SIGKILL);
		}, 1500.msecs);
	}

	@property bool dead() { return process.dead; }

	/// Callback invoked when this server shuts down, for pool cleanup.
	private void delegate() onShutdown_;

	/// Terminate the server immediately and notify remaining sessions.
	/// Nulls onExit to prevent double-firing from the async process exit.
	void shutdown()
	{
		if (state_ == State.dead) return;
		process.onExit = null;
		process.closeStdin();
		process.terminate();
		state_ = State.dead;
		foreach (session; sessionsByTid)
			session.onServerExit(1);
		if (onShutdown_)
			onShutdown_();
	}

	/// Send a JSON-RPC request to the Codex server.
	/// Returns a promise for the response. For fire-and-forget, ignore the promise.
	package Promise!JsonRpcResponse sendRequest(string method, JSONFragment params)
	{
		JsonRpcRequest req;
		req.method = method;
		req.params = params;
		return codec.sendRequest(req);
	}

	// ---- Initialization handshake ----

	private void sendInitialize()
	{
		state_ = State.initializing;
		sendRequest("initialize", JSONFragment(toJson(InitializeParams(
			InitializeParams.ClientInfo("cydo", "0.1.0"),
			JSONFragment("{}")
		)))).then((JsonRpcResponse result) {
			sendLogin();
		});
	}

	private void sendLogin()
	{
		import std.process : environment;
		auto apiKey = environment.get("CODEX_API_KEY",
			environment.get("OPENAI_API_KEY", ""));
		if (apiKey.length == 0)
		{
			onLoginCompleted();
			return;
		}

		state_ = State.authenticating;
		sendRequest("account/login/start",
			JSONFragment(toJson(LoginStartParams("apiKey", apiKey)))
		).then((JsonRpcResponse result) {
			import std.algorithm : canFind;
			// API-key auth may complete synchronously.
			if (result.result.json.canFind(`"success"`) || result.result.json.canFind(`"loggedIn"`))
				onLoginCompleted();
		});
	}

	private void onLoginCompleted()
	{
		if (state_ == State.ready)
			return;
		state_ = State.ready;
		auto queue = readyQueue;
		readyQueue = null;
		foreach (dg; queue)
			dg();
	}
}

// ---------------------------------------------------------------------------
// CodexAgent — Agent descriptor for OpenAI Codex CLI.
// ---------------------------------------------------------------------------

class CodexAgent : Agent
{
	private AppServerProcess[string] serverPool; // keyed by workspace+sandbox signature
	private string[string] modelAliasOverrides;
	private string lastMcpConfigPath_;

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

		// Codex home directory (config, sessions)
		auto home = environment.get("HOME", "/tmp");
		auto codexHome = environment.get("CODEX_HOME", buildPath(home, ".codex"));
		paths[codexHome] = PathMode.rw;

		auto codexBinary = resolveCodexBinary();
		if (codexBinary == home ~ "/.npm-packages/bin")
			addIfNotRw(home ~ "/.npm-packages", PathMode.ro);
		else
			addIfNotRw(resolveCodexBinary(), PathMode.ro);

		addIfNotRw(cydoBinaryDir(), PathMode.ro);

		// Pass through Codex-required env vars so they survive --clearenv
		void passthrough(string key)
		{
			auto val = environment.get(key, "");
			if (val.length > 0)
				env[key] = val;
		}

		passthrough("PATH");
		passthrough("OPENAI_API_KEY");
		passthrough("OPENAI_BASE_URL");
		passthrough("CODEX_API_KEY");
		passthrough("CODEX_HOME");
	}

	@property string gitName() { return "Codex CLI"; }
	@property string gitEmail() { return "noreply@openai.com"; }
	@property string lastMcpConfigPath() { return lastMcpConfigPath_; }

	private string serverPoolKey(string workspace, string[] cmdPrefix)
	{
		import std.regex : regex, replaceAll;
		auto prefixSig = cmdPrefix is null ? "[]" : toJson(cmdPrefix);
		// Task-local scratch paths differ by tid but are safe to share across
		// Codex threads in the same workspace; ignore only that variance.
		prefixSig = replaceAll(prefixSig, regex(`/\.cydo\/tasks\/\d+/`), "/.cydo/tasks/*");
		return workspace ~ "\n" ~ prefixSig;
	}

	AgentSession createSession(int tid, string resumeSessionId, string[] cmdPrefix,
		SessionConfig config = SessionConfig.init)
	{
		auto workspace = config.workspace.length > 0 ? config.workspace : "default";
		auto server = getOrCreateServer(serverPoolKey(workspace, cmdPrefix), cmdPrefix);
		auto session = new CodexSession(server, tid, config);
		server.registerSessionByTid(tid, session);

		auto model = config.model.length > 0 ? config.model : "codex-mini-latest";
		auto workDir = config.workDir.length > 0 ? config.workDir : ".";

		// Build developerInstructions: system prompt + disallowedTools restriction.
		string devInstructions = config.appendSystemPrompt;
		if (devInstructions.length > 0)
			devInstructions ~= "\n\n";
		devInstructions ~= "IMPORTANT: Do NOT use the following tools: "
			~ "spawn_agent,update_plan,request_user_input"
			~ ". If you attempt to use them, they will fail.";

		// Build MCP config override for CyDo tools.
		auto mcpConfig = buildMcpConfigOverride(tid,
			config.creatableTaskTypes, config.switchModes, config.handoffs,
			config.includeTools, config.mcpSocketPath);

		server.onReady(() {
			void startFreshThread()
			{
				ThreadStartParams tsp;
				tsp.cwd = workDir;
				tsp.model = model;
				tsp.approvalPolicy = "never";
				tsp.sandbox = "danger-full-access";
				if (devInstructions.length > 0)
					tsp.developerInstructions = devInstructions;
				if (mcpConfig.length > 0)
					tsp.config = JSONFragment(mcpConfig);

				server.sendRequest("thread/start",
					JSONFragment(toJson(tsp))
				).then((JsonRpcResponse resp) {
					ThreadStartResult result;
					try
						result = resp.getResult!ThreadStartResult();
					catch (Exception e)
						warningf("thread/start error: %s", e.msg);
					session.onThreadStarted(result, null, model, workDir,
						resp.result.json);
				});
			}

			if (resumeSessionId.length > 0)
			{
				ThreadResumeParams trp;
				trp.threadId = resumeSessionId;
				trp.model = model;
				trp.cwd = workDir;
				trp.approvalPolicy = "never";
				trp.sandbox = "danger-full-access";
				if (devInstructions.length > 0)
					trp.developerInstructions = devInstructions;
				if (mcpConfig.length > 0)
					trp.config = JSONFragment(mcpConfig);

				server.sendRequest("thread/resume",
					JSONFragment(toJson(trp))
				).then((JsonRpcResponse resp) {
					ThreadStartResult result;
					try
						result = resp.getResult!ThreadStartResult();
					catch (Exception e)
					{
						// Resume can fail when sandbox/workspace changes require a new
						// app-server process that does not know the old thread ID.
						// Fall back to a fresh thread so tools (MCP) are still available.
						warningf("thread/resume error: %s; falling back to thread/start", e.msg);
						startFreshThread();
						return;
					}
					if (result.thread.id.length == 0)
					{
						warningf("thread/resume returned empty thread id; falling back to thread/start");
						startFreshThread();
						return;
					}
					session.onThreadStarted(result, resumeSessionId, model, workDir,
						resp.result.json);
				});
			}
			else
				startFreshThread();
		});

		return session;
	}

	private AppServerProcess getOrCreateServer(string poolKey, string[] cmdPrefix)
	{
		if (auto existing = poolKey in serverPool)
			if (!existing.dead)
				return *existing;

		string[] codexArgs = [getCodexBinName(), "app-server", "--listen", "stdio://"];
		string[] args;
		if (cmdPrefix !is null)
			args = cmdPrefix ~ codexArgs;
		else
			args = codexArgs;

		auto server = new AppServerProcess(args);
		serverPool[poolKey] = server;
		server.onShutdown_ = { serverPool.remove(poolKey); };
		return server;
	}

	/// Shut down all pooled server processes (safety net for app shutdown).
	void shutdownAllServers()
	{
		auto servers = serverPool.values;
		serverPool = null;
		foreach (server; servers)
			server.shutdown();
	}

	string parseSessionId(string line)
	{
		import std.algorithm : canFind;
		// CodexSession emits agnostic events; look for session/init.
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

			warningf("Unexpected session/init event: %s", line);
			return null;
		}
		catch (Exception e)
		{
			warningf("Error parsing session id: %s", e.msg);
			return null;
		}
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

			warningf("Unexpected turn/result event: %s", line);
			return "";
		}
		catch (Exception e)
		{
			warningf("Error parsing result: %s", e.msg);
			return "";
		}
	}

	string extractAssistantText(string line)
	{
		import std.algorithm : canFind;

		// New format: item/started with item_type=text
		if (line.canFind(`"item/started"`))
		{
			@JSONPartial static struct ItemStartedProbe { string type; string item_type; string text; }
			try
			{
				auto probe = jsonParse!ItemStartedProbe(line);
				if (probe.type == "item/started" && probe.item_type == "text" && probe.text.length > 0)
					return probe.text;
			}
			catch (Exception) {}
		}

		return "";
	}

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
			case "small":  return "gpt-5-nano";
			case "medium": return "gpt-5.3-codex";
			case "large":  return "gpt-5.4";
			default:       return "gpt-5-nano";
		}
	}

	string historyPath(string sessionId, string projectPath)
	{
		import std.file : dirEntries, SpanMode;
		import std.process : environment;

		auto home = environment.get("HOME", "/tmp");
		auto codexHome = environment.get("CODEX_HOME", buildPath(home, ".codex"));
		auto sessionsDir = buildPath(codexHome, "sessions");

		// Codex stores sessions at ~/.codex/sessions/YYYY/MM/DD/rollout-*-<threadId>.jsonl
		// Glob for the file since the timestamp prefix is unknown.
		try
		{
			foreach (entry; dirEntries(sessionsDir, "*-" ~ sessionId ~ ".jsonl", SpanMode.depth))
				return entry.name;
			return null;
		}
		catch (Exception e)
		{
			warningf("Error reading Codex session history: %s", e.msg);
			return null;
		}
	}

	string[] translateHistoryLine(string line, int lineNum)
	{
		import std.algorithm : canFind;
		import std.conv : to;

		// Codex JSONL lines: { timestamp, type, payload }
		// type is one of: session_meta, response_item, event_msg, turn_context, compacted
		if (line.canFind(`"type":"session_meta"`))
		{
			auto t = translateRolloutSessionMeta(line);
			return t !is null ? [t] : [];
		}
		else if (line.canFind(`"type":"response_item"`))
		{
			// Pass line-number fork ID for user/assistant messages
			string forkId = null;
			if (line.canFind(`"role":"user"`) || line.canFind(`"role":"assistant"`))
				forkId = "line:" ~ to!string(lineNum);
			return translateRolloutResponseItem(line, forkId);
		}
		else if (line.canFind(`"type":"event_msg"`))
		{
			auto t = translateRolloutEventMsg(line);
			return t !is null ? [t] : [];
		}
		// Skip turn_context, compacted, unknown
		return [];
	}

	string[] translateLiveEvent(string rawLine)
	{
		// CodexSession emits new-format events natively; pass through unchanged.
		return [rawLine];
	}

	bool isTurnResult(string rawLine)
	{
		import std.algorithm : canFind;
		return rawLine.canFind(`"type":"turn/result"`);
	}

	bool isUserMessageLine(string rawLine)
	{
		import std.algorithm : canFind;
		// Codex JSONL: response_item with role=user
		return rawLine.canFind(`"type":"response_item"`) && rawLine.canFind(`"role":"user"`);
	}

	bool isAssistantMessageLine(string rawLine)
	{
		import std.algorithm : canFind;
		// Codex JSONL: response_item with role=assistant
		return rawLine.canFind(`"type":"response_item"`) && rawLine.canFind(`"role":"assistant"`);
	}

	string rewriteSessionId(string line, string oldId, string newId)
	{
		import std.array : replace;
		return line
			.replace(`"threadId":"` ~ oldId ~ `"`, `"threadId":"` ~ newId ~ `"`)
			.replace(`"session_id":"` ~ oldId ~ `"`, `"session_id":"` ~ newId ~ `"`);
	}

	string[] extractForkableIds(string content, int lineOffset = 0)
	{
		import std.algorithm : canFind;
		import std.conv : to;
		import std.string : lineSplitter;

		string[] ids;
		int lineNum = lineOffset;
		foreach (line; content.lineSplitter)
		{
			lineNum++;
			if (line.length == 0)
				continue;
			// Forkable: response_item with role user or assistant
			if (!line.canFind(`"type":"response_item"`))
				continue;
			if (!line.canFind(`"role":"user"`) && !line.canFind(`"role":"assistant"`))
				continue;
			ids ~= "line:" ~ to!string(lineNum);
		}
		return ids;
	}

	bool forkIdMatchesLine(string line, int lineNum, string forkId)
	{
		import std.conv : to;
		// Fork IDs are "line:<N>" — match on line number
		if (forkId.length > 5 && forkId[0 .. 5] == "line:")
		{
			try
				return lineNum == to!int(forkId[5 .. $]);
			catch (Exception)
				return false;
		}
		return false;
	}

	bool isForkableLine(string line)
	{
		import std.algorithm : canFind;
		return line.canFind(`"type":"response_item"`)
			&& (line.canFind(`"role":"user"`) || line.canFind(`"role":"assistant"`));
	}

	@property bool needsBash() { return false; }
	@property bool supportsFileRevert() { return false; }

	string rewindFiles(string sessionId, string afterUuid, string cwd)
	{
		return "File revert is not supported for Codex sessions";
	}

	/// Currently unused — no callers in the codebase. Implement if a caller is added.
	string extractUserText(string line) { return ""; }

	OneShotHandle completeOneShot(string prompt, string modelClass)
	{
		import std.string : strip;

		auto promise = new Promise!string;

		AgentProcess proc;
		try
			// Pass null env to inherit the full parent environment, matching
			// how AppServerProcess spawns the main codex session.
			// --skip-git-repo-check avoids the "not inside a trusted directory"
			// error when the process CWD is not a git repo root.
			proc = new AgentProcess([
				getCodexBinName(), "exec",
				"--ephemeral",
				"--skip-git-repo-check",
				"-m", resolveModelAlias(modelClass),
				prompt,
			], null, null, true); // noStdin
		catch (Exception e)
		{
			errorf("completeOneShot: failed to spawn codex: %s", e.msg);
			promise.reject(new Exception("failed to spawn codex: " ~ e.msg));
			return OneShotHandle(promise, null);
		}

		// When stdout is a pipe (not a TTY), codex exec writes only the final
		// response text to stdout; all headers and diagnostics go to stderr.
		string responseText;
		string stderrText;

		proc.onStdoutLine = (string line) {
			responseText ~= line;
		};

		proc.onStderrLine = (string line) {
			stderrText ~= line ~ "\n";
		};

		proc.onExit = (int status) {
			if (status != 0)
			{
				auto msg = "codex exited with status " ~ status.to!string;
				if (stderrText.length > 0)
					errorf("completeOneShot: %s\n%s", msg, stderrText);
				promise.reject(new Exception(msg));
			}
			else
				promise.fulfill(responseText.strip());
		};

		void cancel() { proc.sendSignal(15); } // SIGTERM; no-op if already exited

		return OneShotHandle(promise, &cancel);
	}
}

// ---------------------------------------------------------------------------
// CodexSession — one Codex thread, implementing AgentSession.
// ---------------------------------------------------------------------------

class CodexSession : AgentSession
{
	private AppServerProcess server;
	private int tid;
	private string threadId;
	private string activeTurnId_;
	private string model;
	private string workDir;
	private bool alive_;
	private bool turnInProgress;

	// Active item tracking for item/delta routing.
	private string activeItemId_;              // most recently started item (for delta routing)
	private string[string] activeItemTypes_;   // itemId → itemType for all active items
	private int itemCounter_;                  // monotonic counter for generating item IDs
	private string lastResultText_;             // last completed text content, for turn/result

	private string sessionId;

	// Queued messages waiting for thread to be ready.
	private ContentBlock[][] pendingMessages;

	// Callbacks
	package void delegate(string line) outputHandler_;
	package void delegate(string line) stderrHandler_;
	private void delegate(int status) exitHandler_;

	this(AppServerProcess server, int tid, SessionConfig config)
	{
		this.server = server;
		this.tid = tid;
		this.alive_ = true;
	}

	/// Called when thread/start or thread/resume response arrives.
	package void onThreadStarted(ThreadStartResult result, string resumeId,
		string model, string workDir, string rawResultJson)
	{
		this.model = model;
		this.workDir = workDir;

		if (result.thread.id.length > 0)
			threadId = result.thread.id;

		if (threadId.length == 0 && resumeId.length > 0)
			threadId = resumeId;

		if (threadId.length == 0)
		{
			if (outputHandler_)
				outputHandler_(`{"type":"process/stderr","text":"Failed to start Codex thread"}`);
			return;
		}

		sessionId = threadId;
		server.registerSession(threadId, this);

		// Emit synthetic session/init with raw RPC response as _raw.
		import cydo.agent.protocol : SessionInitEvent, injectRawField;
		SessionInitEvent initEv;
		initEv.session_id      = threadId;
		initEv.model           = model;
		initEv.cwd             = workDir;
		initEv.tools           = [];
		initEv.agent_version   = "";
		initEv.permission_mode = "dangerously-skip-permissions";
		initEv.agent           = "codex";
		auto initEvent = toJson(initEv);
		if (rawResultJson.length > 0)
			initEvent = injectRawField(initEvent, rawResultJson);

		if (outputHandler_)
			outputHandler_(initEvent);

		// Drain queued messages now that the thread is ready.
		auto queued = pendingMessages;
		pendingMessages = null;
		foreach (msg; queued)
			sendMessage(msg);
	}

	/// Called when the app-server process dies.
	package void onServerExit(int status)
	{
		if (!alive_)
			return; // Already stopped; avoid double-invocation of exitHandler_.
		alive_ = false;
		auto cb = exitHandler_;
		exitHandler_ = null;
		if (cb)
			cb(status);
	}

	// ----- AgentSession interface -----

	void sendMessage(const(ContentBlock)[] content)
	{
		// Extract text (only text blocks supported; throw on others).
		string text;
		foreach (ref b; content)
		{
			if (b.type == "text") text ~= b.text;
			else throw new Exception("Unsupported content block type for Codex: " ~ b.type);
		}

		if (!alive_)
			return;

		// Queue message if thread hasn't been created yet.
		if (threadId.length == 0)
		{
			pendingMessages ~= content.dup;
			return;
		}

		if (turnInProgress)
		{
			server.sendRequest("turn/steer",
				JSONFragment(toJson(TurnSteerParams(threadId, text))));
		}
		else
		{
			turnInProgress = true;
			activeTurnId_ = null;
			activeItemId_ = null;
			activeItemTypes_ = null;

			server.sendRequest("turn/start",
				JSONFragment(toJson(TurnStartParams(
					threadId,
					[TurnStartInput("text", text)],
					SandboxPolicy("externalSandbox", "enabled")))));
		}
	}

	@property bool supportsImages() const { return false; }

	void interrupt()
	{
		if (!alive_ || threadId.length == 0 || !turnInProgress || activeTurnId_.length == 0)
			return;
		server.sendRequest("turn/interrupt",
			JSONFragment(toJson(TurnInterruptParams(threadId, activeTurnId_))));
	}

	void sigint()
	{
		interrupt();
	}

	void stop()
	{
		if (!alive_)
			return;
		// Codex sessions share a pooled app-server process. Kill is an
		// emergency stop that terminates that process and lets onServerExit
		// propagate the real exit to all attached sessions.
		server.terminate();
	}

	void closeStdin()
	{
		if (!alive_)
			return;
		if (threadId.length > 0)
			server.unregisterSession(threadId);
		server.unregisterSessionByTid(tid);
		activeTurnId_ = null;
		alive_ = false;
		auto cb = exitHandler_;
		exitHandler_ = null;
		if (cb)
			cb(0); // zero = clean close
	}

	@property void onOutput(void delegate(string line) dg) { outputHandler_ = dg; }
	@property void onStderr(void delegate(string line) dg) { stderrHandler_ = dg; }
	@property void onExit(void delegate(int status) dg) { exitHandler_ = dg; }
	@property bool alive() { return alive_ && !server.dead; }

	// ----- Notification handling (routed by CodexServerRouter) -----

	package void handleItemStarted(ItemStartedParams params, string rawNotification)
	{
		import cydo.agent.protocol : ItemStartedEvent, injectRawField;
		if (params.turnId.length > 0)
			activeTurnId_ = params.turnId;

		auto item = params.item;

		ItemStartedEvent ev;

		if (item.type == "userMessage")
		{
			// Echo user message as item/started type=user_message.
			if (item.content.json !is null && outputHandler_)
			{
				ev.item_type = "user_message";
				// Extract text from content array: [{type:"input_text",text:"..."}]
				@JSONPartial
				static struct InputTextItem { @JSONOptional string text; }
				string userText;
				try
				{
					auto items = jsonParse!(InputTextItem[])(item.content.json);
					foreach (ref i; items)
						userText ~= i.text;
				}
				catch (Exception) {}
				if (userText.length == 0)
					userText = item.text;
				ev.item_id = "codex-user-" ~ to!string(itemCounter_++);
				ev.text = userText;
				outputHandler_(injectRawField(toJson(ev), rawNotification));
			}
			return;
		}

		// Assign item ID: use native id if available, else generate one.
		auto itemId = item.id.length > 0 ? item.id : "codex-item-" ~ to!string(itemCounter_++);
		activeItemId_ = itemId;

		switch (item.type)
		{
			case "agentMessage":
				activeItemTypes_[itemId] = "text";
				ev.item_type = "text";
				// Reset + capture text for result extraction. Text may arrive
				// fully formed here (no deltas) or be empty with deltas following.
				lastResultText_ = item.text;
				break;
			case "reasoning":
				activeItemTypes_[itemId] = "thinking";
				ev.item_type = "thinking";
				break;
			case "commandExecution":
				activeItemTypes_[itemId] = "tool_use";
				ev.item_type = "tool_use";
				ev.name = "commandExecution";
				// Build input JSON from the command string field.
				string cmdInput;
				if (item.command.length > 0)
				{
					import cydo.agent.protocol : CommandInput;
					cmdInput = toJson(CommandInput(item.command, ""));
				}
				else
					cmdInput = extractCommandInput(item.action);
				if (cmdInput.length > 0 && cmdInput != `{}`)
					ev.input = JSONFragment(cmdInput);
				break;
			case "fileChange":
				activeItemTypes_[itemId] = "tool_use";
				ev.item_type = "tool_use";
				ev.name = "fileChange";
				// Include changes directly so the frontend can show the File Viewer button
				// without relying on _raw (which is stripped before broadcast).
				if (auto pChanges = "changes" in item.extras)
					ev.input = JSONFragment(`{"changes":` ~ pChanges.json ~ `}`);
				break;
			case "mcpToolCall":
				activeItemTypes_[itemId] = "tool_use";
				ev.item_type = "tool_use";
				if (item.tool.length > 0)
					ev.name = item.server.length > 0 ? "mcp__" ~ item.server ~ "__" ~ item.tool : item.tool;
				else
					ev.name = item.name.length > 0 ? item.name : "unknown";
				if (auto pArguments = "arguments" in item.extras)
					ev.input = *pArguments;
				break;
			case "webSearch":
				activeItemTypes_[itemId] = "tool_use";
				ev.item_type = "tool_use";
				ev.name = "WebSearch";
				if (auto pQuery = "query" in item.extras)
					ev.input = JSONFragment(`{"query":` ~ pQuery.json ~ `}`);
				break;
			default:
				activeItemTypes_[itemId] = "text";
				ev.item_type = "text";
				break;
		}

		ev.item_id = itemId;

		// If item/started already contains text (e.g. during history replay),
		// include it directly in the event.
		if (item.text.length > 0)
			ev.text = item.text;

		if (outputHandler_)
			outputHandler_(injectRawField(toJson(ev), rawNotification));
	}

	/// Handle any delta notification (text, thinking, or command output).
	package void handleDelta(DeltaParams params, string deltaType, string rawNotification)
	{
		if (activeItemId_.length == 0 || outputHandler_ is null)
			return;

		// Accumulate text deltas for result extraction.
		if (deltaType == "text_delta")
		{
			auto pType = activeItemId_ in activeItemTypes_;
			if (pType !is null && *pType == "text")
				lastResultText_ ~= params.delta;
		}

		import cydo.agent.protocol : ItemDeltaEvent, injectRawField;
		ItemDeltaEvent ev;
		ev.item_id = activeItemId_;
		ev.delta_type = deltaType;
		ev.content = params.delta;
		outputHandler_(injectRawField(toJson(ev), rawNotification));
	}

	/// Handle terminal interaction notification (stdin written to a running process).
	package void handleTerminalInteraction(TerminalInteractionParams params, string rawNotification)
	{
		if (outputHandler_ is null)
			return;

		import cydo.agent.protocol : ItemDeltaEvent, injectRawField;
		ItemDeltaEvent ev;
		ev.item_id = params.itemId.length > 0 ? params.itemId : activeItemId_;
		ev.delta_type = "stdin_delta";
		ev.content = params.stdin;
		outputHandler_(injectRawField(toJson(ev), rawNotification));
	}

	package void handleItemCompleted(ItemCompletedParams params, string rawNotification)
	{
		// Determine which item completed: prefer explicit ID from params.
		string itemId = (params.item.id.length > 0) ? params.item.id : activeItemId_;
		if (itemId.length == 0)
			return;

		// Look up item type from map.
		auto pType = itemId in activeItemTypes_;
		if (pType is null)
			return; // unknown item, skip
		string itemType = *pType;

		import cydo.agent.protocol : ItemCompletedEvent, ItemResultEvent, injectRawField;
		ItemCompletedEvent ev;
		ev.item_id = itemId;
		ev.is_error = params.item.is_error;

		if (itemType == "tool_use" && params.item.aggregatedOutput.length > 0)
			ev.output = params.item.aggregatedOutput;

		if (outputHandler_)
			outputHandler_(injectRawField(toJson(ev), rawNotification));

		// Emit item/result for tool_use items so the frontend can display the output.
		// item/result must come AFTER item/completed so the tool_use block is
		// already in content[] when reduceItemResult searches for it.
		if (itemType == "tool_use" && outputHandler_)
		{
			ItemResultEvent resEv;
			resEv.item_id = itemId;
			if (params.item.aggregatedOutput.length > 0)
				resEv.content = JSONFragment(`[{"type":"text","text":` ~ toJson(params.item.aggregatedOutput) ~ `}]`);
			else
			{
				@JSONPartial
				static struct ResultPayload
				{
					@JSONOptional JSONFragment content;
				}

				bool hasResultContent = false;
				if (auto pResult = "result" in params.item.extras)
				{
					try
					{
						auto payload = jsonParse!ResultPayload(pResult.json);
						if (payload.content.json !is null)
						{
							resEv.content = payload.content;
							hasResultContent = true;
						}
					}
					catch (Exception) {}
				}

				// For webSearch items, serialize the full item as result content.
				// For all other tool_use items (commandExecution, mcpToolCall, etc.),
				// use an empty string — the frontend expects a string or array, not an object.
				if (!hasResultContent)
				{
					auto pItemType = "type" in params.item.extras;
					bool isWebSearch = pItemType !is null && pItemType.json == `"webSearch"`;
					if (isWebSearch)
					{
						auto itemJson = toJson(params.item);
						resEv.content = JSONFragment(`[{"type":"text","text":` ~ (itemJson.length > 2 ? toJson(itemJson) : `""`) ~ `}]`);
					}
					else
						resEv.content = JSONFragment(`[{"type":"text","text":""}]`);
				}
			}
			outputHandler_(injectRawField(toJson(resEv), rawNotification));
		}

		// Remove from tracking.
		activeItemTypes_.remove(itemId);
		if (activeItemId_ == itemId)
			activeItemId_ = null;
	}

	package void handleTurnCompleted(string rawNotification)
	{
		turnInProgress = false;
		activeTurnId_ = null;

		// Do NOT clear activeItemId_ or activeItemTypes_ here — background items
		// may still complete after the turn ends.

		// 1. turn/stop
		if (outputHandler_)
		{
			import cydo.agent.protocol : TurnStopEvent, UsageInfo, injectRawField;
			TurnStopEvent tsev;
			tsev.model = model;
			tsev.usage = UsageInfo(0, 0);
			outputHandler_(injectRawField(toJson(tsev), rawNotification));
		}

		// 2. turn/result
		if (outputHandler_)
		{
			import cydo.agent.protocol : TurnResultEvent, UsageInfo, injectRawField;
			TurnResultEvent tre;
			tre.subtype = "success";
			tre.num_turns = 1;
			tre.usage = UsageInfo(0, 0);
			tre.result = lastResultText_;
			outputHandler_(injectRawField(toJson(tre), rawNotification));
		}
		lastResultText_ = null;
	}
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

private:

/// Build a JSON config override object with MCP server config for CyDo tools.
/// Returns empty string if CyDo binary is not available.
/// The JSON value is passed as the "config" field in thread/start params.
string buildMcpConfigOverride(int tid, string creatableTaskTypes,
	string switchModes, string handoffs, string[] includeTools, string mcpSocketPath)
{
	import std.array : join;

	auto cydoBin = cydoBinaryPath;
	if (cydoBin.length == 0)
		return "";

	string[string] env;
	env["CYDO_TID"] = to!string(tid);
	env["CYDO_SOCKET"] = mcpSocketPath;
	env["CYDO_CREATABLE_TYPES"] = creatableTaskTypes;
	env["CYDO_SWITCHMODES"] = switchModes;
	env["CYDO_HANDOFFS"] = handoffs;
	env["CYDO_INCLUDE_TOOLS"] = includeTools is null ? "" : includeTools.join(",");

	auto serverConfig = McpServerConfig(
		cydoBin,
		["mcp-server"],
		env,
		100000000,
	);

	// Build {"mcp_servers.cydo": {...}} — dotted key is a normal string key.
	JSONFragment[string] config;
	config["mcp_servers.cydo"] = JSONFragment(toJson(serverConfig));
	return toJson(config);
}

// ---------------------------------------------------------------------------
// Rollout JSONL translation: Codex rollout format → agnostic events.
// Codex rollout line: { timestamp, type: "session_meta"|"response_item"|
//   "event_msg"|"turn_context"|"compacted", payload: {...} }
// ---------------------------------------------------------------------------

/// Translate a session_meta rollout line → session/init agnostic event.
string translateRolloutSessionMeta(string line)
{
	@JSONPartial
	static struct Probe
	{
		@JSONPartial
		static struct Payload
		{
			string id;
			string cwd;
			string cli_version;
		}
		Payload payload;
	}

	Probe probe;
	try
		probe = jsonParse!Probe(line);
	catch (Exception e)
	{ tracef("translateHistoryEvent: probe parse error: %s", e.msg); return null; }

	if (probe.payload.id.length == 0)
		return null;

	import cydo.agent.protocol : SessionInitEvent, injectRawField;
	SessionInitEvent ev;
	ev.session_id      = probe.payload.id;
	ev.model           = "";
	ev.cwd             = probe.payload.cwd;
	ev.tools           = [];
	ev.agent_version   = probe.payload.cli_version;
	ev.permission_mode = "dangerously-skip-permissions";
	ev.agent           = "codex";
	return injectRawField(toJson(ev), line);
}

/// Translate a response_item rollout line → item-based protocol events.
string[] translateRolloutResponseItem(string line, string forkId = null)
{
	@JSONPartial
	static struct Probe
	{
		@JSONPartial
		static struct Payload
		{
			string type;   // "message", "local_shell_call", "function_call",
			               // "custom_tool_call", "function_call_output", "reasoning"
			string role;   // for message type
			JSONFragment content;  // message content array or reasoning content

			// local_shell_call fields
			string call_id;
			JSONFragment action; // { type: "exec", command: [...] }

			// function_call fields
			string name;
			string arguments;
			string input;

			// function_call_output fields
			JSONFragment output;

			// reasoning fields
			JSONFragment summary;
		}
		Payload payload;
	}

	Probe probe;
	try
		probe = jsonParse!Probe(line);
	catch (Exception e)
	{ tracef("translateHistoryStreamEvent: probe parse error: %s", e.msg); return []; }

	auto ptype = probe.payload.type;

	string[] results;
	if (ptype == "message")
		results = translateRolloutMessage(probe.payload.role,
			probe.payload.content.json !is null ? probe.payload.content.json : "[]",
			forkId);
	else if (ptype == "local_shell_call")
		results = translateRolloutToolUse(probe.payload.call_id, "local_shell_call",
			extractCommandInput(probe.payload.action));
	else if (ptype == "function_call")
	{
		// Pass parsed arguments object directly (not wrapped as {"arguments":"..."}).
		string argsJson = probe.payload.arguments;
		string inputJson;
		if (argsJson.length > 0 && argsJson[0] == '{')
			inputJson = argsJson;  // already a JSON object
		else
			inputJson = `{}`;
		results = translateRolloutToolUse(probe.payload.call_id, probe.payload.name,
			inputJson);
	}
	else if (ptype == "custom_tool_call")
	{
		// custom_tool_call.input is string payload. Wrap plain string into {"input": "..."}
		// so frontend parser can recover apply_patch text consistently.
		string inputJson = `{}`;
		auto rawInput = probe.payload.input;
		if (rawInput.length > 0)
		{
			if (rawInput[0] == '{')
				inputJson = rawInput;
			else
				inputJson = `{"input":` ~ toJson(rawInput) ~ `}`;
		}
		results = translateRolloutToolUse(probe.payload.call_id, probe.payload.name,
			inputJson);
	}
	else if (ptype == "function_call_output" || ptype == "custom_tool_call_output"
		|| ptype == "mcp_tool_call_output")
	{
		auto r = translateRolloutToolResult(probe.payload.call_id,
			probe.payload.output.json !is null ? probe.payload.output.json : `""`);
		if (r !is null) results = [r];
	}
	else if (ptype == "reasoning")
		results = translateRolloutReasoning(
			probe.payload.summary.json !is null ? probe.payload.summary.json : "[]",
			probe.payload.content.json);
	else
		return [];

	if (results.length == 0)
		return [];

	import cydo.agent.protocol : injectRawField;
	string[] injected;
	foreach (r; results)
		injected ~= injectRawField(r, line);
	return injected;
}

/// Translate a message response_item payload → item/started [+ item/completed].
string[] translateRolloutMessage(string role, string contentJson, string forkId = null)
{
	import std.array : replace;

	// Remap Codex content types (input_text/output_text) → agnostic "text"
	auto content = contentJson
		.replace(`"type":"input_text"`, `"type":"text"`)
		.replace(`"type":"output_text"`, `"type":"text"`);

	if (role == "assistant")
	{
		import cydo.agent.protocol : ItemStartedEvent, ItemCompletedEvent, TurnStopEvent, UsageInfo;

		// Parse content blocks from the JSON array string
		@JSONPartial
		static struct RawBlock
		{
			string type;
			@JSONOptional string text;
		}

		string[] events;
		try
		{
			auto rawBlocks = jsonParse!(RawBlock[])(content);
			foreach (i, ref rb; rawBlocks)
			{
				auto itemId = "codex-hist-" ~ to!string(i);
				ItemStartedEvent startEv;
				startEv.item_id = itemId;
				startEv.item_type = rb.type == "thinking" ? "thinking" : "text";
				if (rb.text.length > 0)
					startEv.text = rb.text;
				events ~= toJson(startEv);

				ItemCompletedEvent compEv;
				compEv.item_id = itemId;
				if (rb.text.length > 0)
					compEv.text = rb.text;
				events ~= toJson(compEv);
			}
		}
		catch (Exception e)
		{ tracef("translateRolloutMessage: content parse error: %s", e.msg); }

		TurnStopEvent tsev;
		tsev.model = "";
		tsev.usage = UsageInfo(0, 0);
		if (forkId !is null)
			tsev.uuid = forkId;
		events ~= toJson(tsev);
		return events;
	}
	else // user, developer, system
	{
		import cydo.agent.protocol : ItemStartedEvent;

		// Extract text from the content array
		@JSONPartial
		static struct TextBlock { string type; @JSONOptional string text; }
		string userText;
		try
		{
			auto blocks = jsonParse!(TextBlock[])(content);
			foreach (ref b; blocks)
				if (b.type == "text")
					userText ~= b.text;
		}
		catch (Exception) {}

		ItemStartedEvent ev;
		ev.item_id = "codex-user-hist";
		ev.item_type = "user_message";
		ev.text = userText;
		if (forkId !is null)
			ev.uuid = forkId;
		return [toJson(ev)];
	}
}

/// Translate a tool_use response_item → item/started + item/completed.
string[] translateRolloutToolUse(string callId, string toolName, string inputJson)
{
	import std.uuid : randomUUID;
	import cydo.agent.protocol : ItemStartedEvent, ItemCompletedEvent;

	if (callId.length == 0)
		callId = randomUUID().toString();

	ItemStartedEvent startEv;
	startEv.item_id = callId;
	startEv.item_type = "tool_use";
	startEv.name = toolName;
	if (inputJson.length > 0 && inputJson != `{}`)
		startEv.input = JSONFragment(inputJson);

	ItemCompletedEvent compEv;
	compEv.item_id = callId;
	if (inputJson.length > 0 && inputJson != `{}`)
		compEv.input = JSONFragment(inputJson);

	return [toJson(startEv), toJson(compEv)];
}

/// Translate a tool_result response_item → item/result.
string translateRolloutToolResult(string callId, string outputJson)
{
	import cydo.agent.protocol : ItemResultEvent;

	ItemResultEvent ev;
	ev.item_id = callId;
	if (outputJson.length > 0 && outputJson[0] == '"')
		ev.content = JSONFragment(`[{"type":"text","text":` ~ outputJson ~ `}]`);
	else
		ev.content = JSONFragment(outputJson);
	return toJson(ev);
}

/// Translate a reasoning response_item → item/started (thinking) + item/completed.
string[] translateRolloutReasoning(string summaryJson, string contentJson)
{
	// Extract text from summary array: [{ text: "..." }, ...]
	string thinkingText;
	if (contentJson !is null && contentJson.length > 2)
	{
		@JSONPartial static struct ReasoningContent { string text; }
		try
		{
			auto items = jsonParse!(ReasoningContent[])(contentJson);
			foreach (ref item; items)
				if (item.text.length > 0)
					thinkingText ~= item.text;
		}
		catch (Exception) {}
	}

	if (thinkingText.length == 0 && summaryJson.length > 2)
	{
		@JSONPartial static struct SummaryItem { string text; }
		try
		{
			auto items = jsonParse!(SummaryItem[])(summaryJson);
			foreach (ref item; items)
				if (item.text.length > 0)
					thinkingText ~= item.text;
		}
		catch (Exception e) { tracef("translateRolloutReasoning: parse error: %s", e.msg); }
	}

	if (thinkingText.length == 0)
		return [];

	import cydo.agent.protocol : ItemStartedEvent, ItemCompletedEvent;

	ItemStartedEvent startEv;
	startEv.item_id = "codex-reasoning";
	startEv.item_type = "thinking";
	startEv.text = thinkingText;

	ItemCompletedEvent compEv;
	compEv.item_id = "codex-reasoning";
	compEv.text = thinkingText;

	return [toJson(startEv), toJson(compEv)];
}

/// Translate an event_msg rollout line → turn/result (for task_complete).
string translateRolloutEventMsg(string line)
{
	@JSONPartial
	static struct Probe
	{
		@JSONPartial
		static struct Payload
		{
			string type;
		}
		Payload payload;
	}

	Probe probe;
	try
		probe = jsonParse!Probe(line);
	catch (Exception e)
	{ tracef("translateStreamEvent: probe parse error: %s", e.msg); return null; }

	if (probe.payload.type == "task_complete")
	{
		import cydo.agent.protocol : TurnResultEvent, UsageInfo, injectRawField;
		TurnResultEvent ev;
		ev.subtype = "success";
		ev.num_turns = 1;
		ev.usage = UsageInfo(0, 0);
		return injectRawField(toJson(ev), line);
	}

	// Skip user_message, task_started, error, etc.
	return null;
}

/// Extract command string from a Codex commandExecution action fragment.
string extractCommandInput(JSONFragment action)
{
	if (action.json is null || action.json.length == 0)
		return `{}`;

	@JSONPartial
	static struct ActionData
	{
		string[] command;
	}

	try
	{
		auto act = jsonParse!ActionData(action.json);
		string cmd;
		if (act.command.length >= 3 && act.command[0] == "sh" && act.command[1] == "-c")
			cmd = act.command[2];
		else if (act.command.length > 0)
		{
			import std.array : join;
			cmd = act.command.join(" ");
		}
		import cydo.agent.protocol : CommandInput;
		return toJson(CommandInput(cmd, ""));
	}
	catch (Exception e)
	{ tracef("extractBashInput: parse error: %s", e.msg); return `{}`; }
}

/// Get the codex binary name/path.
/// If CYDO_CODEX_BIN is set, use it (can be absolute path); else "codex".
private string getCodexBinName()
{
	import std.process : environment;
	return environment.get("CYDO_CODEX_BIN", "codex");
}

unittest
{
	@JSONPartial
	struct StartedNotification
	{
		ItemStartedParams params;
	}

	@JSONPartial
	struct CompletedNotification
	{
		ItemCompletedParams params;
	}

	@JSONPartial
	struct EmittedStartedEvent
	{
		string type;
		@JSONOptional JSONFragment input;
	}

	@JSONPartial
	struct AskQuestionOption
	{
		string label;
		string description;
	}

	@JSONPartial
	struct AskQuestion
	{
		string header;
		string question;
		AskQuestionOption[] options;
		@JSONOptional bool multiSelect;
	}

	@JSONPartial
	struct AskUserQuestionInput
	{
		AskQuestion[] questions;
	}

	@JSONPartial
	struct EmittedResultEvent
	{
		string type;
		JSONFragment content;
	}

	@JSONPartial
	struct TextContentBlock
	{
		string type;
		@JSONOptional string text;
	}

	enum startedPayload =
		`{"jsonrpc":"2.0","method":"item/started","params":{"threadId":"thread-ask","turnId":"turn-ask","item":{"id":"mcp-call-ask","type":"mcpToolCall","server":"cydo","tool":"AskUserQuestion","arguments":{"questions":[{"header":"Test","question":"Do you agree?","options":[{"label":"Yes","description":"Confirm"},{"label":"No","description":"Deny"}],"multiSelect":false}]}}}}`;

	enum completedPayload =
		`{"jsonrpc":"2.0","method":"item/completed","params":{"threadId":"thread-ask","item":{"id":"mcp-call-ask","result":{"content":[{"type":"text","text":"User has answered your questions: \"Do you agree?\"=\"Yes\"."}]}}}}`;

	auto session = new CodexSession(cast(AppServerProcess) null, 1, SessionConfig.init);
	string[] emitted;
	void sink(string line) { emitted ~= line; }
	session.onOutput(&sink);

	auto started = jsonParse!StartedNotification(startedPayload);
	session.handleItemStarted(started.params, startedPayload);

	auto completed = jsonParse!CompletedNotification(completedPayload);
	session.handleItemCompleted(completed.params, completedPayload);

	auto startedEvent = jsonParse!EmittedStartedEvent(emitted[0]);
	auto resultEvent = jsonParse!EmittedResultEvent(emitted[$ - 1]);

	bool inputOk = false;
	string actualInput = "<missing>";
	if (startedEvent.input.json !is null)
	{
		actualInput = startedEvent.input.json;
		const parsedInput = jsonParse!AskUserQuestionInput(startedEvent.input.json);
		inputOk =
			parsedInput.questions.length == 1
			&& parsedInput.questions[0].header == "Test"
			&& parsedInput.questions[0].question == "Do you agree?"
			&& parsedInput.questions[0].options.length == 2
			&& parsedInput.questions[0].options[0].label == "Yes";
	}

	auto blocks = jsonParse!(TextContentBlock[])(resultEvent.content.json);
	const actualResult =
		blocks.length > 0 && blocks[0].text.length > 0 ? blocks[0].text : "<empty>";
	const resultOk =
		blocks.length == 1
		&& blocks[0].type == "text"
		&& actualResult == `User has answered your questions: "Do you agree?"="Yes".`;

	assert(
		inputOk && resultOk,
		"expected Codex mcpToolCall AskUserQuestion payload to survive translation; "
			~ "actual input=" ~ actualInput ~ " actual result=" ~ actualResult,
	);
}

/// Resolve the codex binary path by searching PATH.
package string resolveCodexBinary()
{
	import std.algorithm : splitter, startsWith;
	import std.file : exists, isFile;
	import std.process : environment;

	auto binName = getCodexBinName();
	if (binName.startsWith("/"))
		return dirName(binName);

	auto pathVar = environment.get("PATH", "");
	foreach (dir; pathVar.splitter(':'))
	{
		auto candidate = buildPath(dir, binName);
		if (exists(candidate) && isFile(candidate))
			return dir; // return the directory, not the binary itself
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
