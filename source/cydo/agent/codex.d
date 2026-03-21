module cydo.agent.codex;

import std.conv : to;
import std.logger : errorf, tracef, warningf;
import std.path : buildPath, dirName;

import ae.net.asockets : ConnectionAdapter, IConnection;
import ae.net.jsonrpc.binding : JsonRpcDispatcher,
	jsonRpcDispatcher, RPCFlatten, RPCName, RPCNamedParams;
import ae.net.jsonrpc.codec : JsonRpcCodec;
import ae.sys.data : Data;
import ae.utils.json : JSONExtras, JSONFragment, JSONName, JSONOptional, JSONPartial,
	jsonParse, toJson;
import ae.utils.jsonrpc : JsonRpcRequest, JsonRpcResponse;
import ae.utils.promise : Promise, resolve;

import cydo.agent.agent : Agent, SessionConfig;
import cydo.agent.process : AgentProcess;
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
}

// ---- Incoming notification params (Codex → CyDo) ----

@RPCFlatten @JSONPartial
struct ItemStartedParams
{
	string threadId;
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
struct ThreadIdParams
{
	string threadId;
}

@RPCFlatten @JSONPartial
struct ItemCompletedParams
{
	string threadId;
	static struct Item
	{
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

	@RPCName("item/commandExecution/outputDelta")
	Promise!void itemCommandExecutionOutputDelta(DeltaParams params);

	@RPCName("item/completed")
	Promise!void itemCompleted(ItemCompletedParams params);

	@RPCName("turn/completed")
	Promise!void turnCompleted(ThreadIdParams params);

	@RPCName("thread/compacted")
	Promise!void threadCompacted(ThreadIdParams params);

	@RPCName("account/login/completed")
	Promise!void accountLoginCompleted();

	@RPCName("item/commandExecution/requestApproval")
	Promise!ApprovalDecision commandExecutionApproval(ItemStartedParams params);

	@RPCName("item/fileChange/requestApproval")
	Promise!ApprovalDecision fileChangeApproval(ItemStartedParams params);
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

	Promise!void itemStarted(ItemStartedParams params)
	{
		routeToSession(params.threadId, (s) => s.handleItemStarted(params));
		return resolve();
	}

	Promise!void itemAgentMessageDelta(DeltaParams params)
	{
		routeToSession(params.threadId,
			(s) => s.handleDelta(params, "text_delta"));
		return resolve();
	}

	Promise!void itemReasoningTextDelta(DeltaParams params)
	{
		routeToSession(params.threadId,
			(s) => s.handleDelta(params, "thinking_delta"));
		return resolve();
	}

	Promise!void itemCommandExecutionOutputDelta(DeltaParams params)
	{
		routeToSession(params.threadId,
			(s) => s.handleDelta(params, "text_delta"));
		return resolve();
	}

	Promise!void itemCompleted(ItemCompletedParams params)
	{
		routeToSession(params.threadId,
			(s) => s.handleItemCompleted(params));
		return resolve();
	}

	Promise!void turnCompleted(ThreadIdParams params)
	{
		routeToSession(params.threadId,
			(s) => s.handleTurnCompleted());
		return resolve();
	}

	Promise!void threadCompacted(ThreadIdParams params)
	{
		routeToSession(params.threadId, (s) {
			if (s.outputHandler_)
				s.outputHandler_(`{"type":"session/compacted"}`);
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

class LoggingAdapter : ConnectionAdapter
{
	string name;

	this(IConnection next, string name)
	{
		super(next);
		this.name = name;
	}

	override void onReadData(Data data)
	{
		data.enter((scope contents) {
			tracef("[%s] < %s", name, cast(string)contents);
		});
		super.onReadData(data);
	}

	override void send(scope Data[] data, int priority)
	{
		foreach (ref datum; data)
			datum.enter((scope contents) {
				tracef("[%s] > %s", name, cast(string)contents);
			});
		super.send(data, priority);
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
		process = new AgentProcess(args, null, null);

		// Set up bidirectional JSON-RPC codec on the process connection.
		// The codec takes over handleReadData from stdoutLines; onStdoutLine
		// is no longer called.
		IConnection connection = process.connection;
		debug (codex) connection = new LoggingAdapter(connection, "codex");
		codec = new JsonRpcCodec(connection);

		// Dispatcher for incoming notifications/requests from Codex.
		auto router = new CodexServerRouter(this);
		serverDispatcher = jsonRpcDispatcher!ICodexServer(router);
		codec.handleRequest = &serverDispatcher.dispatch;

		process.onStderrLine = (string line) {
			foreach (session; sessionsByTid)
				if (session.stderrHandler_)
					session.stderrHandler_(line);
		};

		process.onExit = (int status) {
			state_ = State.dead;
			foreach (session; sessionsByTid)
				session.onServerExit(status);
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
	}

	void registerSessionByTid(int tid, CodexSession session)
	{
		sessionsByTid[tid] = session;
	}

	void unregisterSessionByTid(int tid)
	{
		sessionsByTid.remove(tid);
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
		process.terminate();
	}

	@property bool dead() { return process.dead; }

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
	private AppServerProcess[string] serverPool; // keyed by workspace
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

	AgentSession createSession(int tid, string resumeSessionId, string[] bwrapPrefix,
		SessionConfig config = SessionConfig.init)
	{
		auto workspace = config.workspace.length > 0 ? config.workspace : "default";
		auto server = getOrCreateServer(workspace, bwrapPrefix);
		auto session = new CodexSession(server, tid, config);
		server.registerSessionByTid(tid, session);

		auto model = config.model.length > 0 ? config.model : "codex-mini-latest";
		auto workDir = config.workDir.length > 0 ? config.workDir : ".";

		server.onReady(() {
			if (resumeSessionId.length > 0)
			{
				server.sendRequest("thread/resume",
					JSONFragment(toJson(ThreadResumeParams(resumeSessionId)))
				).then((JsonRpcResponse resp) {
					ThreadStartResult result;
					try
						result = resp.getResult!ThreadStartResult();
					catch (Exception e)
					{ warningf("thread/resume error: %s", e.msg); }
					session.onThreadStarted(result, resumeSessionId, model, workDir);
				});
			}
			else
			{
				// Build developerInstructions: system prompt + disallowedTools restriction
				string devInstructions = config.appendSystemPrompt;
				if (devInstructions.length > 0)
					devInstructions ~= "\n\n";
				devInstructions ~= "IMPORTANT: Do NOT use the following tools: "
					~ "spawn_agent,update_plan,request_user_input"
					~ ". If you attempt to use them, they will fail.";

				// Build MCP config override for CyDo tools
				auto mcpConfig = buildMcpConfigOverride(tid,
					config.creatableTaskTypes, config.switchModes, config.handoffs, config.mcpSocketPath);

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
					{ warningf("thread/start error: %s", e.msg); }
					session.onThreadStarted(result, null, model, workDir);
				});
			}
		});

		return session;
	}

	private AppServerProcess getOrCreateServer(string workspace, string[] bwrapPrefix)
	{
		if (auto existing = workspace in serverPool)
			if (!existing.dead)
				return *existing;

		string[] codexArgs = [getCodexBinName(), "app-server", "--listen", "stdio://"];
		string[] args;
		if (bwrapPrefix !is null)
			args = bwrapPrefix ~ codexArgs;
		else
			args = codexArgs;

		auto server = new AppServerProcess(args);
		serverPool[workspace] = server;
		return server;
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
		if (!line.canFind(`"message/assistant"`))
			return "";

		@JSONPartial
		static struct ContentBlock
		{
			string type;
			string text;
		}

		@JSONPartial
		static struct AssistantProbe
		{
			string type;
			ContentBlock[] content;
		}

		try
		{
			auto probe = jsonParse!AssistantProbe(line);
			if (probe.type != "message/assistant")
				return "";
			string result;
			foreach (ref block; probe.content)
				if (block.type == "text")
					result ~= block.text;
			return result;
		}
		catch (Exception e)
		{
			tracef("Error parsing assistant message: %s", e.msg);
			return "";
		}
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

	string translateHistoryLine(string line, int lineNum)
	{
		import std.algorithm : canFind;
		import std.conv : to;

		// Codex JSONL lines: { timestamp, type, payload }
		// type is one of: session_meta, response_item, event_msg, turn_context, compacted
		if (line.canFind(`"type":"session_meta"`))
			return translateRolloutSessionMeta(line);
		else if (line.canFind(`"type":"response_item"`))
		{
			// Pass line-number fork ID for user/assistant messages
			string forkId = null;
			if (line.canFind(`"role":"user"`) || line.canFind(`"role":"assistant"`))
				forkId = "line:" ~ to!string(lineNum);
			return translateRolloutResponseItem(line, forkId);
		}
		else if (line.canFind(`"type":"event_msg"`))
			return translateRolloutEventMsg(line);
		// Skip turn_context, compacted, unknown
		return null;
	}

	string translateLiveEvent(string rawLine)
	{
		// Codex emits agnostic-format events natively; no translation needed.
		return rawLine;
	}

	bool isTurnResult(string rawLine)
	{
		import std.algorithm : canFind;
		return rawLine.canFind(`"type":"turn/result"`);
	}

	bool isUserMessageLine(string rawLine)
	{
		import std.algorithm : canFind;
		return rawLine.canFind(`"type":"message/user"`);
	}

	bool isAssistantMessageLine(string rawLine)
	{
		import std.algorithm : canFind;
		return rawLine.canFind(`"type":"message/assistant"`);
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

	@property bool supportsFileRevert() { return false; }

	string rewindFiles(string sessionId, string afterUuid, string cwd)
	{
		return "File revert is not supported for Codex sessions";
	}

	/// Currently unused — no callers in the codebase. Implement if a caller is added.
	string extractUserText(string line) { return ""; }

	Promise!string completeOneShot(string prompt, string modelClass)
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
			return promise;
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

		return promise;
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
	private string model;
	private string workDir;
	private bool alive_;
	private bool turnInProgress;

	// Streaming state: block index counter (reset per turn).
	private int blockIndex;
	private string sessionId;

	// Turn accumulation for synthetic message/assistant at turn completion.
	private struct CompletedItem
	{
		string type; // "text", "thinking", "tool_use"
		string id;   // tool_use id
		string name; // tool_use name
		string text; // accumulated delta text (content for text/thinking, output for tools)
		string input; // tool_use input JSON
		bool isError; // whether tool execution reported an error
	}
	private CompletedItem activeItem;
	private CompletedItem[] completedItems;

	// Queued messages waiting for thread to be ready.
	private string[] pendingMessages;

	// Whether the active streaming item is a command execution.
	// Used to suppress text_delta (command output goes to tool result, not streaming).
	private bool activeItemIsCommand;

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
		string model, string workDir)
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

		// Emit synthetic session/init.
		import cydo.agent.protocol : SessionInitEvent;
		SessionInitEvent initEv;
		initEv.session_id      = threadId;
		initEv.model           = model;
		initEv.cwd             = workDir;
		initEv.tools           = [];
		initEv.agent_version   = "";
		initEv.permission_mode = "dangerously-skip-permissions";
		initEv.agent           = "codex";
		auto initEvent = toJson(initEv);

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

	void sendMessage(string content)
	{
		if (!alive_)
			return;

		// Queue message if thread hasn't been created yet.
		if (threadId.length == 0)
		{
			pendingMessages ~= content;
			return;
		}

		if (turnInProgress)
		{
			server.sendRequest("turn/steer",
				JSONFragment(toJson(TurnSteerParams(threadId, content))));
		}
		else
		{
			turnInProgress = true;
			blockIndex = 0;
			completedItems = null;
			activeItem = CompletedItem.init;

			server.sendRequest("turn/start",
				JSONFragment(toJson(TurnStartParams(
					threadId,
					[TurnStartInput("text", content)],
					SandboxPolicy("externalSandbox", "enabled")))));
		}
	}

	void interrupt()
	{
		if (!alive_ || threadId.length == 0)
			return;
		server.sendRequest("turn/interrupt",
			JSONFragment(toJson(TurnInterruptParams(threadId))));
	}

	void sigint()
	{
		interrupt();
	}

	void stop()
	{
		if (!alive_)
			return;
		// Send a thread-level interrupt (not server-level terminate) so that
		// only this session stops and other concurrent sessions are unaffected.
		if (threadId.length > 0)
		{
			server.sendRequest("turn/interrupt",
				JSONFragment(toJson(TurnInterruptParams(threadId))));
			server.unregisterSession(threadId);
		}
		server.unregisterSessionByTid(tid);
		alive_ = false;
		auto cb = exitHandler_;
		exitHandler_ = null;
		if (cb)
			cb(1); // non-zero = killed by user
	}

	void closeStdin()
	{
		if (!alive_)
			return;
		if (threadId.length > 0)
		{
			server.sendRequest("turn/interrupt",
				JSONFragment(toJson(TurnInterruptParams(threadId))));
			server.unregisterSession(threadId);
		}
		server.unregisterSessionByTid(tid);
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

	package void handleItemStarted(ItemStartedParams params)
	{
		auto item = params.item;

		// Emit a message/user echo so the frontend confirms the pending placeholder.
		if (item.type == "userMessage")
		{
			if (item.content.json !is null && outputHandler_)
			{
				import cydo.agent.protocol : UserMessageEvent, injectRawField;
				UserMessageEvent uev;
				uev.content = item.content;
				outputHandler_(injectRawField(toJson(uev), toJson(item)));
			}
			return;
		}

		auto idx = blockIndex++;
		activeItem = CompletedItem.init;

		import cydo.agent.protocol : BlockDescriptor, StreamBlockStartEvent,
			StreamBlockDeltaEvent, StreamDelta;

		BlockDescriptor blockDesc;

		switch (item.type)
		{
			case "agentMessage":
				blockDesc.type = "text";
				activeItem.type = "text";
				break;
			case "reasoning":
				blockDesc.type = "thinking";
				activeItem.type = "thinking";
				break;
			case "commandExecution":
				blockDesc.type = "tool_use";
				blockDesc.id = item.id;
				blockDesc.name = "commandExecution";
				activeItem.type = "tool_use";
				activeItem.id = item.id;
				activeItem.name = "commandExecution";
				activeItemIsCommand = true;
				// Build input JSON from the command string field.
				string cmdInput;
				if (item.command.length > 0)
				{
					import cydo.agent.protocol : CommandInput;
					cmdInput = toJson(CommandInput(item.command, ""));
				}
				else
				{
					// Fall back to action fragment if present.
					cmdInput = extractCommandInput(item.action);
				}
				activeItem.input = cmdInput;
				break;
			case "fileChange":
				blockDesc.type = "tool_use";
				blockDesc.id = item.id;
				blockDesc.name = "fileChange";
				activeItem.type = "tool_use";
				activeItem.id = item.id;
				activeItem.name = "fileChange";
				break;
			case "mcpToolCall":
				// v2 protocol uses "tool" and "server" fields.
				string toolDisplayName;
				if (item.tool.length > 0)
				{
					if (item.server.length > 0)
						toolDisplayName = item.server ~ "__" ~ item.tool;
					else
						toolDisplayName = item.tool;
				}
				else
					toolDisplayName = item.name.length > 0 ? item.name : "unknown";
				blockDesc.type = "tool_use";
				blockDesc.id = item.id;
				blockDesc.name = toolDisplayName;
				activeItem.type = "tool_use";
				activeItem.id = item.id;
				activeItem.name = toolDisplayName;
				break;
			default:
				blockDesc.type = "text";
				activeItem.type = "text";
				break;
		}

		if (outputHandler_)
		{
			import cydo.agent.protocol : injectRawField;
			StreamBlockStartEvent ev;
			ev.index = idx;
			ev.content_block = blockDesc;
			outputHandler_(injectRawField(toJson(ev), toJson(item)));
		}

		// Emit the command input as input_json_delta so the frontend renders
		// the command during streaming (tool_use blocks need input to display).
		if (activeItemIsCommand && activeItem.input.length > 0
			&& activeItem.input != `{}` && outputHandler_)
		{
			StreamBlockDeltaEvent dev;
			dev.index = idx;
			dev.delta.type = "input_json_delta";
			dev.delta.partial_json = activeItem.input;
			outputHandler_(toJson(dev));
		}

		// If item/started already contains text (agentMessage with pre-populated
		// content), emit a synthetic delta so the frontend has content to display.
		if (item.text.length > 0 && outputHandler_)
		{
			import cydo.agent.protocol : injectRawField;
			activeItem.text = item.text;
			StreamBlockDeltaEvent dev;
			dev.index = idx;
			dev.delta.type = "text_delta";
			dev.delta.text = item.text;
			outputHandler_(injectRawField(toJson(dev), toJson(item)));
		}
	}

	/// Handle any delta notification (text, thinking, or tool output).
	package void handleDelta(DeltaParams params, string deltaType)
	{
		activeItem.text ~= params.delta;

		// Don't stream command output as text deltas — the output will be
		// included in the tool result synthesized from item/completed.
		if (activeItemIsCommand)
			return;

		auto idx = blockIndex > 0 ? blockIndex - 1 : 0;
		if (outputHandler_)
		{
			import cydo.agent.protocol : StreamBlockDeltaEvent, StreamDelta;
			StreamBlockDeltaEvent ev;
			ev.index = idx;
			ev.delta.type = deltaType;
			ev.delta.text = params.delta;
			outputHandler_(toJson(ev));
		}
	}

	package void handleItemCompleted(ItemCompletedParams params)
	{
		// Skip if no active item (e.g., userMessage items are not tracked).
		if (activeItem.type.length == 0)
			return;

		auto idx = blockIndex > 0 ? blockIndex - 1 : 0;

		if (outputHandler_)
		{
			import cydo.agent.protocol : StreamBlockStopEvent, injectRawField;
			StreamBlockStopEvent ev;
			ev.index = idx;
			outputHandler_(injectRawField(toJson(ev), toJson(params.item)));
		}

		activeItem.isError = params.item.is_error;

		// For commands, use aggregatedOutput from item/completed as the tool
		// result text (deltas were suppressed during streaming).
		if (activeItemIsCommand && params.item.aggregatedOutput.length > 0)
			activeItem.text = params.item.aggregatedOutput;

		activeItemIsCommand = false;
		completedItems ~= activeItem;
		activeItem = CompletedItem.init;
	}

	package void handleTurnCompleted()
	{
		import std.uuid : randomUUID;

		turnInProgress = false;

		// 1. stream/turn_stop
		if (outputHandler_)
			outputHandler_(`{"type":"stream/turn_stop"}`);

		// 2. Synthetic message/assistant
		if (completedItems.length > 0)
		{
			import cydo.agent.protocol : AssistantMessageEvent, ContentBlock,
				UsageInfo, UserMessageEvent, ToolResultBlock;

			auto msgId = "msg_" ~ randomUUID().toString();

			ContentBlock[] contentBlocks;
			foreach (ref ci; completedItems)
			{
				ContentBlock cb;
				cb.type = ci.type;
				if (ci.type == "text" || ci.type == "thinking")
					cb.text = ci.text;
				else if (ci.type == "tool_use")
				{
					cb.id   = ci.id;
					cb.name = ci.name;
					cb.input = JSONFragment(ci.input.length > 0 ? ci.input : `{}`);
				}
				contentBlocks ~= cb;
			}

			AssistantMessageEvent aev;
			aev.id          = msgId;
			aev.content     = contentBlocks;
			aev.model       = model;
			aev.stop_reason = "end_turn";
			aev.usage       = UsageInfo(0, 0);

			if (outputHandler_)
				outputHandler_(toJson(aev));

			// 3. Synthetic message/user with tool_result blocks
			ToolResultBlock[] toolResults;
			foreach (ref ci; completedItems)
				if (ci.type == "tool_use")
				{
					ToolResultBlock tr;
					tr.tool_use_id = ci.id;
					tr.content = JSONFragment(toJson(ci.text));
					tr.is_error = ci.isError;
					toolResults ~= tr;
				}

			if (toolResults.length > 0 && outputHandler_)
			{
				UserMessageEvent uev;
				uev.content = JSONFragment(toJson(toolResults));
				outputHandler_(toJson(uev));
			}
		}

		// 4. turn/result
		if (outputHandler_)
		{
			import cydo.agent.protocol : TurnResultEvent, UsageInfo;
			TurnResultEvent tre;
			tre.subtype = "success";
			tre.num_turns = 1;
			tre.usage = UsageInfo(0, 0);
			outputHandler_(toJson(tre));
		}

		completedItems = null;
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
	string switchModes, string handoffs, string mcpSocketPath)
{
	auto cydoBin = cydoBinaryPath;
	if (cydoBin.length == 0)
		return "";

	string[string] env;
	env["CYDO_TID"] = to!string(tid);
	env["CYDO_SOCKET"] = mcpSocketPath;
	env["CYDO_CREATABLE_TYPES"] = creatableTaskTypes;
	env["CYDO_SWITCHMODES"] = switchModes;
	env["CYDO_HANDOFFS"] = handoffs;

	auto serverConfig = McpServerConfig(cydoBin, ["--mcp-server"], env);

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

/// Translate a response_item rollout line → message/assistant or message/user.
string translateRolloutResponseItem(string line, string forkId = null)
{
	@JSONPartial
	static struct Probe
	{
		@JSONPartial
		static struct Payload
		{
			string type;   // "message", "local_shell_call", "function_call",
			               // "function_call_output", "reasoning"
			string role;   // for message type
			JSONFragment content;  // message content array or reasoning content

			// local_shell_call fields
			string call_id;
			JSONFragment action; // { type: "exec", command: [...] }

			// function_call fields
			string name;
			string arguments;

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
	{ tracef("translateHistoryStreamEvent: probe parse error: %s", e.msg); return null; }

	auto ptype = probe.payload.type;

	string result;
	if (ptype == "message")
		result = translateRolloutMessage(probe.payload.role,
			probe.payload.content.json !is null ? probe.payload.content.json : "[]",
			forkId);
	else if (ptype == "local_shell_call")
		result = translateRolloutToolUse(probe.payload.call_id, "local_shell_call",
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
		result = translateRolloutToolUse(probe.payload.call_id, probe.payload.name,
			inputJson);
	}
	else if (ptype == "function_call_output" || ptype == "custom_tool_call_output"
		|| ptype == "mcp_tool_call_output")
		result = translateRolloutToolResult(probe.payload.call_id,
			probe.payload.output.json !is null ? probe.payload.output.json : `""`);
	else if (ptype == "reasoning")
		result = translateRolloutReasoning(
			probe.payload.summary.json !is null ? probe.payload.summary.json : "[]",
			probe.payload.content.json);
	else
		return null;

	import cydo.agent.protocol : injectRawField;
	return result !is null ? injectRawField(result, line) : null;
}

/// Translate a message response_item payload.
string translateRolloutMessage(string role, string contentJson, string forkId = null)
{
	import std.array : replace;
	import std.uuid : randomUUID;

	// Remap Codex content types (input_text/output_text) → agnostic "text"
	auto content = contentJson
		.replace(`"type":"input_text"`, `"type":"text"`)
		.replace(`"type":"output_text"`, `"type":"text"`);

	if (role == "assistant")
	{
		import cydo.agent.protocol : AssistantMessageEvent, ContentBlock, UsageInfo;

		// Parse content blocks from the JSON array string
		@JSONPartial
		static struct RawBlock
		{
			string type;
			@JSONOptional string text;
			@JSONOptional string id;
			@JSONOptional string name;
			@JSONOptional JSONFragment input;
		}

		ContentBlock[] blocks;
		try
		{
			auto rawBlocks = jsonParse!(RawBlock[])(content);
			foreach (ref rb; rawBlocks)
			{
				ContentBlock cb;
				cb.type = rb.type;
				cb.text = rb.text;
				cb.id   = rb.id;
				cb.name = rb.name;
				cb.input = rb.input;
				blocks ~= cb;
			}
		}
		catch (Exception e)
		{ tracef("translateHistoryEvent: content parse error: %s", e.msg); }

		auto msgId = "msg_" ~ randomUUID().toString();
		AssistantMessageEvent aev;
		aev.id          = msgId;
		aev.content     = blocks;
		aev.model       = "";
		aev.stop_reason = "end_turn";
		aev.usage       = UsageInfo(0, 0);
		if (forkId !is null)
			aev.uuid = forkId;
		return toJson(aev);
	}
	else // user, developer, system
	{
		import cydo.agent.protocol : UserMessageEvent;
		UserMessageEvent ev;
		ev.content = JSONFragment(content);
		if (forkId !is null)
			ev.uuid = forkId;
		return toJson(ev);
	}
}

/// Construct a message/assistant with a single tool_use content block.
string translateRolloutToolUse(string callId, string toolName, string inputJson)
{
	import std.uuid : randomUUID;
	import cydo.agent.protocol : AssistantMessageEvent, ContentBlock, UsageInfo;

	if (callId.length == 0)
		callId = randomUUID().toString();

	ContentBlock cb;
	cb.type  = "tool_use";
	cb.id    = callId;
	cb.name  = toolName;
	cb.input = JSONFragment(inputJson);

	auto msgId = "msg_" ~ randomUUID().toString();
	AssistantMessageEvent aev;
	aev.id          = msgId;
	aev.content     = [cb];
	aev.model       = "";
	aev.stop_reason = "end_turn";
	aev.usage       = UsageInfo(0, 0);
	return toJson(aev);
}

/// Construct a message/user with a tool_result content block.
string translateRolloutToolResult(string callId, string outputJson)
{
	import cydo.agent.protocol : ToolResultBlock, UserMessageEvent;

	// outputJson might be a plain string or an object — extract text
	string text;
	if (outputJson.length > 0 && outputJson[0] == '"')
	{
		// Plain string value — use as-is (already JSON-encoded)
		text = outputJson;
	}
	else
	{
		// Object or other — just stringify
		text = `"(output)"`;
	}

	ToolResultBlock tr;
	tr.tool_use_id = callId;
	tr.content = JSONFragment(text);

	UserMessageEvent ev;
	ev.content = JSONFragment(toJson([tr]));
	return toJson(ev);
}

/// Construct a message/assistant with a thinking content block from reasoning.
string translateRolloutReasoning(string summaryJson, string contentJson)
{
	import std.uuid : randomUUID;

	// Extract text from summary array: [{ text: "..." }, ...]
	string thinkingText;
	if (contentJson !is null && contentJson.length > 2)
	{
		// Try to extract reasoning text from content array
		@JSONPartial
		static struct ReasoningContent
		{
			string text;
		}

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
		// Fallback to summary
		@JSONPartial
		static struct SummaryItem
		{
			string text;
		}

		try
		{
			auto items = jsonParse!(SummaryItem[])(summaryJson);
			foreach (ref item; items)
				if (item.text.length > 0)
					thinkingText ~= item.text;
		}
		catch (Exception e) { tracef("extractThinkingBlock: parse error: %s", e.msg); }
	}

	if (thinkingText.length == 0)
		return null;

	import cydo.agent.protocol : AssistantMessageEvent, ContentBlock, UsageInfo;
	ContentBlock cb;
	cb.type = "thinking";
	cb.text = thinkingText; // normalized: text field, no signature

	auto msgId = "msg_" ~ randomUUID().toString();
	AssistantMessageEvent aev;
	aev.id          = msgId;
	aev.content     = [cb];
	aev.model       = "";
	aev.stop_reason = "end_turn";
	aev.usage       = UsageInfo(0, 0);
	return toJson(aev);
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

/// Resolve the codex binary path by searching PATH.
string resolveCodexBinary()
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
