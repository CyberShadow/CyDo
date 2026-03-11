module cydo.agent.codex;

import std.conv : to;
import std.format : format;
import std.path : buildPath, dirName, expandTilde;

import ae.utils.json : JSONFragment, JSONPartial, jsonParse;

import cydo.agent.agent : Agent, SessionConfig;
import cydo.agent.process : AgentProcess;
import cydo.agent.session : AgentSession;
import cydo.config : PathMode;

// ---------------------------------------------------------------------------
// AppServerProcess — manages a `codex app-server` process via JSON-RPC 2.0.
// One instance per workspace, shared across multiple CodexSessions (threads).
// ---------------------------------------------------------------------------

class AppServerProcess
{
	private AgentProcess process;
	private int nextRequestId = 1;

	enum State { starting, initializing, authenticating, ready, failed, dead }
	private State state_ = State.starting;

	// Pending JSON-RPC response callbacks, keyed by request id.
	private void delegate(string result)[int] pendingCallbacks;

	// Thread routing: threadId → session
	private CodexSession[string] sessions;

	// Actions queued until server reaches ready state.
	private void delegate()[] readyQueue;

	this(string[] args, string[string] env, string workDir)
	{
		process = new AgentProcess(args, env, workDir);

		process.onStdoutLine = (string line) {
			handleLine(line);
		};

		process.onStderrLine = (string line) {
			foreach (session; sessions)
				if (session.stderrHandler_)
					session.stderrHandler_(line);
		};

		process.onExit = (int status) {
			state_ = State.dead;
			foreach (session; sessions)
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

	/// Queue an action for when the server is ready. Runs immediately if
	/// already ready; silently dropped if failed/dead.
	void onReady(void delegate() dg)
	{
		if (state_ == State.ready)
			dg();
		else if (state_ != State.failed && state_ != State.dead)
			readyQueue ~= dg;
	}

	/// Send a JSON-RPC request with a result callback.
	void sendRequest(string method, string params,
		void delegate(string result) onResult)
	{
		auto id = nextRequestId++;
		pendingCallbacks[id] = onResult;
		process.writeLine(
			`{"jsonrpc":"2.0","id":` ~ to!string(id)
			~ `,"method":"` ~ method ~ `","params":` ~ params ~ `}`);
	}

	/// Respond to a server-initiated request.  rawId is the raw JSON
	/// value of the id field (may be int or string).
	void respondToRequest(string rawId, string result)
	{
		process.writeLine(
			`{"jsonrpc":"2.0","id":` ~ rawId ~ `,"result":` ~ result ~ `}`);
	}

	void terminate()
	{
		process.terminate();
	}

	@property bool dead() { return process.dead; }

	// ---- Initialization handshake ----

	private void sendInitialize()
	{
		state_ = State.initializing;
		sendRequest("initialize",
			`{"clientInfo":{"name":"cydo","version":"0.1.0"},"capabilities":{}}`,
			(string result) { sendLogin(); });
	}

	private void sendLogin()
	{
		import std.process : environment;
		auto apiKey = environment.get("CODEX_API_KEY",
			environment.get("OPENAI_API_KEY", ""));
		if (apiKey.length == 0)
		{
			state_ = State.failed;
			return;
		}

		state_ = State.authenticating;
		sendRequest("account/login/start",
			`{"type":"apiKey","apiKey":"` ~ escapeJsonString(apiKey) ~ `"}`,
			(string result) {
				import std.algorithm : canFind;
				// API-key auth may complete synchronously.
				if (result.canFind(`"success"`) || result.canFind(`"loggedIn"`))
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

	// ---- JSON-RPC message dispatcher ----

	private void handleLine(string line)
	{
		@JSONPartial
		static struct RpcProbe
		{
			JSONFragment id;
			string method;
		}

		RpcProbe probe;
		try
			probe = jsonParse!RpcProbe(line);
		catch (Exception)
			return;

		bool hasId = probe.id.json !is null && probe.id.json.length > 0;
		bool hasMethod = probe.method.length > 0;

		if (hasMethod && hasId)
			handleServerRequest(probe.id.json, probe.method, line);
		else if (hasMethod)
			handleNotification(probe.method, line);
		else if (hasId)
		{
			int numId;
			try
				numId = to!int(probe.id.json);
			catch (Exception)
				return;
			handleResponse(numId, line);
		}
	}

	private void handleResponse(int id, string line)
	{
		auto cb = id in pendingCallbacks;
		if (!cb)
			return;

		@JSONPartial
		static struct ResponseData
		{
			JSONFragment result;
		}

		ResponseData data;
		try
			data = jsonParse!ResponseData(line);
		catch (Exception)
			return;

		auto callback = *cb;
		pendingCallbacks.remove(id);
		callback(data.result.json !is null ? data.result.json : "{}");
	}

	private void handleNotification(string method, string line)
	{
		import std.algorithm : startsWith;

		// Filter legacy v1 duplicates.
		if (method.startsWith("codex/event/"))
			return;

		if (method == "account/login/completed")
		{
			onLoginCompleted();
			return;
		}

		// Route to session by threadId.
		@JSONPartial
		static struct ThreadProbe
		{
			@JSONPartial
			static struct Params
			{
				string threadId;
			}
			Params params;
		}

		ThreadProbe tp;
		try
			tp = jsonParse!ThreadProbe(line);
		catch (Exception)
			return;

		if (auto session = tp.params.threadId in sessions)
			session.handleNotification(method, line);
	}

	private void handleServerRequest(string rawId, string method, string line)
	{
		// Auto-approve all approval gates (sandboxed by bwrap).
		if (method == "item/commandExecution/requestApproval"
			|| method == "item/fileChange/requestApproval")
		{
			respondToRequest(rawId, `{"decision":"acceptForSession"}`);
			return;
		}

		// Unknown server request — respond with method-not-found.
		process.writeLine(
			`{"jsonrpc":"2.0","id":` ~ rawId
			~ `,"error":{"code":-32601,"message":"Method not supported"}}`);
	}
}

// ---------------------------------------------------------------------------
// CodexAgent — Agent descriptor for OpenAI Codex CLI.
// ---------------------------------------------------------------------------

class CodexAgent : Agent
{
	private AppServerProcess[string] serverPool; // keyed by workspace
	private string lastMcpConfigPath_;

	void configureSandbox(ref PathMode[string] paths, ref string[string] env)
	{
		import std.algorithm : startsWith;

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

		auto codexHome = expandTilde("~/.codex");
		paths[codexHome] = PathMode.rw;

		addIfNotRw(resolveCodexBinary(), PathMode.ro);
		addIfNotRw(cydoBinaryDir(), PathMode.ro);
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

		auto model = config.model.length > 0 ? config.model : "codex-mini-latest";
		auto workDir = config.workDir.length > 0 ? config.workDir : ".";

		server.onReady(() {
			if (resumeSessionId.length > 0)
			{
				server.sendRequest("thread/resume",
					`{"threadId":"` ~ escapeJsonString(resumeSessionId) ~ `"}`,
					(string result) {
						session.onThreadStarted(result, resumeSessionId, model, workDir);
					});
			}
			else
			{
				// Build developerInstructions: system prompt + disallowedTools restriction
				string devInstructions = config.appendSystemPrompt;
				if (config.disallowedTools.length > 0)
				{
					if (devInstructions.length > 0)
						devInstructions ~= "\n\n";
					devInstructions ~= "IMPORTANT: Do NOT use the following tools: "
						~ config.disallowedTools
						~ ". If you attempt to use them, they will fail.";
				}

				// Build MCP config override for CyDo tools
				auto mcpConfig = buildMcpConfigOverride(tid,
					config.creatableTaskTypes, config.switchModes, config.handoffs);

				auto params = `{"cwd":"` ~ escapeJsonString(workDir)
					~ `","model":"` ~ escapeJsonString(model)
					~ `","approvalPolicy":"never"`
					~ `,"sandbox":"danger-full-access"`
					~ (devInstructions.length > 0
						? `,"developerInstructions":"` ~ escapeJsonString(devInstructions) ~ `"`
						: ``)
					~ (mcpConfig.length > 0
						? `,"config":` ~ mcpConfig
						: ``)
					~ `}`;
				server.sendRequest("thread/start", params,
					(string result) {
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

		string[] codexArgs = ["codex", "app-server", "--listen", "stdio://"];
		string[] args;
		if (bwrapPrefix !is null)
			args = bwrapPrefix ~ codexArgs;
		else
			args = codexArgs;

		auto server = new AppServerProcess(args, null, null);
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
		if (!line.canFind(`"message/assistant"`))
			return "";

		@JSONPartial
		static struct ContentBlock
		{
			string type;
			string text;
		}

		@JSONPartial
		static struct Message
		{
			ContentBlock[] content;
		}

		@JSONPartial
		static struct AssistantProbe
		{
			string type;
			Message message;
		}

		try
		{
			auto probe = jsonParse!AssistantProbe(line);
			if (probe.type != "message/assistant")
				return "";
			string result;
			foreach (ref block; probe.message.content)
				if (block.type == "text")
					result ~= block.text;
			return result;
		}
		catch (Exception)
			return "";
	}

	string resolveModelAlias(string modelClass)
	{
		switch (modelClass)
		{
			case "small":  return "o4-mini";
			case "medium": return "o3";
			case "large":  return "o3";
			default:       return "o4-mini";
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
		}
		catch (Exception) {}
		return "";
	}

	string translateHistoryLine(string line)
	{
		import std.algorithm : canFind;

		// Codex JSONL lines: { timestamp, type, payload }
		// type is one of: session_meta, response_item, event_msg, turn_context, compacted
		if (line.canFind(`"type":"session_meta"`))
			return translateRolloutSessionMeta(line);
		else if (line.canFind(`"type":"response_item"`))
			return translateRolloutResponseItem(line);
		else if (line.canFind(`"type":"event_msg"`))
			return translateRolloutEventMsg(line);
		// Skip turn_context, compacted, unknown
		return null;
	}

	string rewriteSessionId(string line, string oldId, string newId)
	{
		import std.array : replace;
		return line
			.replace(`"threadId":"` ~ oldId ~ `"`, `"threadId":"` ~ newId ~ `"`)
			.replace(`"session_id":"` ~ oldId ~ `"`, `"session_id":"` ~ newId ~ `"`);
	}

	@property bool supportsFileRevert() { return false; }

	string rewindFiles(string sessionId, string afterUuid, string cwd)
	{
		return "File revert is not supported for Codex sessions";
	}

	Object generateTitle(string userMessage, void delegate(string title) onTitle)
	{
		// TODO: Implement title generation for Codex sessions.
		return null;
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
	}
	private CompletedItem activeItem;
	private CompletedItem[] completedItems;

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
	package void onThreadStarted(string result, string resumeId, string model, string workDir)
	{
		this.model = model;
		this.workDir = workDir;

		// Extract threadId from result.
		@JSONPartial
		static struct ThreadResult
		{
			@JSONPartial
			static struct Thread
			{
				string id;
			}
			Thread thread;
		}

		try
		{
			auto parsed = jsonParse!ThreadResult(result);
			if (parsed.thread.id.length > 0)
				threadId = parsed.thread.id;
		}
		catch (Exception) {}

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
		import std.uuid : randomUUID;
		auto uuid = randomUUID().toString();
		auto initEvent = `{"type":"session/init"`
			~ `,"session_id":"` ~ escapeJsonString(threadId)
			~ `","uuid":"` ~ uuid
			~ `","model":"` ~ escapeJsonString(model)
			~ `","cwd":"` ~ escapeJsonString(workDir)
			~ `","tools":[],"claude_code_version":"","permissionMode":"dangerously-skip-permissions"`
			~ `,"agent":"codex"}`;

		if (outputHandler_)
			outputHandler_(initEvent);
	}

	/// Called when the app-server process dies.
	package void onServerExit(int status)
	{
		alive_ = false;
		if (exitHandler_)
			exitHandler_(status);
	}

	// ----- AgentSession interface -----

	void sendMessage(string content)
	{
		if (!alive_ || threadId.length == 0)
			return;

		auto escaped = escapeJsonString(content);

		if (turnInProgress)
		{
			server.sendRequest("turn/steer",
				`{"threadId":"` ~ escapeJsonString(threadId)
				~ `","instructions":"` ~ escaped ~ `"}`,
				(string result) {});
		}
		else
		{
			turnInProgress = true;
			blockIndex = 0;
			completedItems = null;
			activeItem = CompletedItem.init;

			server.sendRequest("turn/start",
				`{"threadId":"` ~ escapeJsonString(threadId)
				~ `","input":[{"type":"text","text":"` ~ escaped ~ `"}]`
				~ `,"sandboxPolicy":{"type":"externalSandbox","networkAccess":"enabled"}}`,
				(string result) {});
		}
	}

	void interrupt()
	{
		if (!alive_ || threadId.length == 0)
			return;
		server.sendRequest("turn/interrupt",
			`{"threadId":"` ~ escapeJsonString(threadId) ~ `"}`,
			(string result) {});
	}

	void sigint()
	{
		interrupt();
	}

	void stop()
	{
		alive_ = false;
		if (threadId.length > 0)
			server.unregisterSession(threadId);
	}

	void closeStdin()
	{
		alive_ = false;
		if (threadId.length > 0)
			server.unregisterSession(threadId);
		if (exitHandler_)
			exitHandler_(0);
	}

	@property void onOutput(void delegate(string line) dg) { outputHandler_ = dg; }
	@property void onStderr(void delegate(string line) dg) { stderrHandler_ = dg; }
	@property void onExit(void delegate(int status) dg) { exitHandler_ = dg; }
	@property bool alive() { return alive_ && !server.dead; }

	// ----- Notification handling (routed by AppServerProcess) -----

	package void handleNotification(string method, string rawLine)
	{
		switch (method)
		{
			case "item/started":
				handleItemStarted(rawLine);
				break;
			case "item/agentMessage/delta":
				handleDelta(rawLine, "text_delta", "text");
				break;
			case "item/reasoning/textDelta":
				handleDelta(rawLine, "thinking_delta", "thinking");
				break;
			case "item/commandExecution/outputDelta":
				handleDelta(rawLine, "text_delta", "text");
				break;
			case "item/completed":
				handleItemCompleted(rawLine);
				break;
			case "turn/completed":
				handleTurnCompleted(rawLine);
				break;
			case "thread/compacted":
				if (outputHandler_)
					outputHandler_(`{"type":"session/compacted"}`);
				break;
			default:
				break;
		}
	}

	private void handleItemStarted(string rawLine)
	{
		@JSONPartial
		static struct Notification
		{
			@JSONPartial
			static struct Params
			{
				@JSONPartial
				static struct Item
				{
					string type;
					string id;
					string name; // mcpToolCall
					string text; // agentMessage: may contain pre-populated text
					string command; // commandExecution: display command string
					JSONFragment action; // commandExecution: structured action
				}
				Item item;
			}
			Params params;
		}

		Notification n;
		try
			n = jsonParse!Notification(rawLine);
		catch (Exception)
			return;

		auto item = n.params.item;

		// Skip user messages (echoed back by server) — no streaming events needed.
		if (item.type == "userMessage")
			return;

		auto idx = blockIndex++;

		string blockType;
		string extra = "";

		activeItem = CompletedItem.init;

		switch (item.type)
		{
			case "agentMessage":
				blockType = "text";
				activeItem.type = "text";
				break;
			case "reasoning":
				blockType = "thinking";
				activeItem.type = "thinking";
				break;
			case "commandExecution":
				blockType = "tool_use";
				extra = `,"id":"` ~ escapeJsonString(item.id) ~ `","name":"Bash"`;
				activeItem.type = "tool_use";
				activeItem.id = item.id;
				activeItem.name = "Bash";
				// Prefer the structured action; fall back to the display command string.
				auto cmdInput = extractCommandInput(item.action);
				if (cmdInput == `{}` && item.command.length > 0)
					cmdInput = `{"command":"` ~ escapeJsonString(item.command) ~ `","description":""}`;
				activeItem.input = cmdInput;
				break;
			case "fileChange":
				blockType = "tool_use";
				extra = `,"id":"` ~ escapeJsonString(item.id) ~ `","name":"Write"`;
				activeItem.type = "tool_use";
				activeItem.id = item.id;
				activeItem.name = "Write";
				break;
			case "mcpToolCall":
				blockType = "tool_use";
				auto name = item.name.length > 0 ? item.name : "unknown";
				extra = `,"id":"` ~ escapeJsonString(item.id)
					~ `","name":"` ~ escapeJsonString(name) ~ `"`;
				activeItem.type = "tool_use";
				activeItem.id = item.id;
				activeItem.name = name;
				break;
			default:
				blockType = "text";
				activeItem.type = "text";
				break;
		}

		if (outputHandler_)
			outputHandler_(
				`{"type":"stream/block_start","index":` ~ to!string(idx)
				~ `,"content_block":{"type":"` ~ blockType ~ `"` ~ extra ~ `}}`);

		// If item/started already contains text (agentMessage with pre-populated
		// content), emit a synthetic delta so the frontend has content to display.
		if (item.text.length > 0 && outputHandler_)
		{
			activeItem.text = item.text;
			outputHandler_(
				`{"type":"stream/block_delta","index":` ~ to!string(idx)
				~ `,"delta":{"type":"text_delta","text":"` ~ escapeJsonString(item.text) ~ `"}}`);
		}
	}

	/// Handle any delta notification (text, thinking, or tool output).
	private void handleDelta(string rawLine, string deltaType, string deltaKey)
	{
		@JSONPartial
		static struct Notification
		{
			@JSONPartial
			static struct Params
			{
				string delta;
			}
			Params params;
		}

		Notification n;
		try
			n = jsonParse!Notification(rawLine);
		catch (Exception)
			return;

		activeItem.text ~= n.params.delta;

		auto idx = blockIndex > 0 ? blockIndex - 1 : 0;
		if (outputHandler_)
			outputHandler_(
				`{"type":"stream/block_delta","index":` ~ to!string(idx)
				~ `,"delta":{"type":"` ~ deltaType
				~ `","` ~ deltaKey ~ `":"` ~ escapeJsonString(n.params.delta) ~ `"}}`);
	}

	private void handleItemCompleted(string rawLine)
	{
		// Skip if no active item (e.g., userMessage items are not tracked).
		if (activeItem.type.length == 0)
			return;

		auto idx = blockIndex > 0 ? blockIndex - 1 : 0;

		if (outputHandler_)
			outputHandler_(
				`{"type":"stream/block_stop","index":` ~ to!string(idx) ~ `}`);

		completedItems ~= activeItem;
		activeItem = CompletedItem.init;
	}

	private void handleTurnCompleted(string rawLine)
	{
		import std.array : join;
		import std.uuid : randomUUID;

		turnInProgress = false;

		// 1. stream/turn_stop
		if (outputHandler_)
			outputHandler_(`{"type":"stream/turn_stop"}`);

		// 2. Synthetic message/assistant
		if (completedItems.length > 0)
		{
			auto msgId = "msg_" ~ randomUUID().toString();
			auto uuid = randomUUID().toString();

			string[] contentParts;
			foreach (ref ci; completedItems)
			{
				if (ci.type == "text")
					contentParts ~= `{"type":"text","text":"` ~ escapeJsonString(ci.text) ~ `"}`;
				else if (ci.type == "thinking")
					contentParts ~= `{"type":"thinking","thinking":"` ~ escapeJsonString(ci.text) ~ `","signature":""}`;
				else if (ci.type == "tool_use")
					contentParts ~= `{"type":"tool_use","id":"` ~ escapeJsonString(ci.id)
						~ `","name":"` ~ escapeJsonString(ci.name)
						~ `","input":` ~ (ci.input.length > 0 ? ci.input : `{}`) ~ `}`;
			}

			auto assistantEvent = `{"type":"message/assistant"`
				~ `,"uuid":"` ~ uuid
				~ `","session_id":"` ~ escapeJsonString(sessionId)
				~ `","parent_tool_use_id":null`
				~ `,"message":{"id":"` ~ msgId
				~ `","role":"assistant","content":[` ~ contentParts.join(",") ~ `]`
				~ `,"model":"` ~ escapeJsonString(model)
				~ `","stop_reason":"end_turn","stop_sequence":null`
				~ `,"usage":{"input_tokens":0,"output_tokens":0}}}`;

			if (outputHandler_)
				outputHandler_(assistantEvent);

			// 3. Synthetic message/user with tool_result blocks
			string[] toolResultParts;
			foreach (ref ci; completedItems)
				if (ci.type == "tool_use")
					toolResultParts ~= `{"type":"tool_result","tool_use_id":"`
						~ escapeJsonString(ci.id)
						~ `","content":"` ~ escapeJsonString(ci.text) ~ `"}`;

			if (toolResultParts.length > 0 && outputHandler_)
				outputHandler_(
					`{"type":"message/user","message":{"role":"user","content":[`
					~ toolResultParts.join(",") ~ `]}}`);
		}

		// 4. turn/result
		auto resultUuid = randomUUID().toString();
		if (outputHandler_)
			outputHandler_(
				`{"type":"turn/result","subtype":"success"`
				~ `,"uuid":"` ~ resultUuid
				~ `","session_id":"` ~ escapeJsonString(sessionId)
				~ `","is_error":false,"num_turns":1,"duration_ms":0,"total_cost_usd":0`
				~ `,"usage":{"input_tokens":0,"output_tokens":0}}`);

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
	string switchModes, string handoffs)
{
	auto cydoBin = cydoBinaryPath;
	if (cydoBin.length == 0)
		return "";

	return `{"mcp_servers.cydo":{"command":"`
		~ escapeJsonString(cydoBin)
		~ `","args":["--mcp-server"],"env":{"CYDO_TID":"`
		~ to!string(tid) ~ `","CYDO_PORT":"3456","CYDO_CREATABLE_TYPES":"`
		~ escapeJsonString(creatableTaskTypes) ~ `","CYDO_SWITCHMODES":"`
		~ escapeJsonString(switchModes) ~ `","CYDO_HANDOFFS":"`
		~ escapeJsonString(handoffs) ~ `"}}}`;
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
	catch (Exception)
		return null;

	if (probe.payload.id.length == 0)
		return null;

	import std.uuid : randomUUID;
	auto uuid = randomUUID().toString();

	return `{"type":"session/init"`
		~ `,"session_id":"` ~ escapeJsonString(probe.payload.id)
		~ `","uuid":"` ~ uuid
		~ `","model":"","cwd":"` ~ escapeJsonString(probe.payload.cwd)
		~ `","tools":[],"claude_code_version":"` ~ escapeJsonString(probe.payload.cli_version)
		~ `","permissionMode":"dangerously-skip-permissions","agent":"codex"}`;
}

/// Translate a response_item rollout line → message/assistant or message/user.
string translateRolloutResponseItem(string line)
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
	catch (Exception)
		return null;

	auto ptype = probe.payload.type;

	if (ptype == "message")
		return translateRolloutMessage(probe.payload.role,
			probe.payload.content.json !is null ? probe.payload.content.json : "[]");
	else if (ptype == "local_shell_call")
		return translateRolloutToolUse(probe.payload.call_id, "Bash",
			extractCommandInput(probe.payload.action));
	else if (ptype == "function_call")
		return translateRolloutToolUse(probe.payload.call_id, probe.payload.name,
			`{"arguments":"` ~ escapeJsonString(probe.payload.arguments) ~ `"}`);
	else if (ptype == "function_call_output" || ptype == "custom_tool_call_output"
		|| ptype == "mcp_tool_call_output")
		return translateRolloutToolResult(probe.payload.call_id,
			probe.payload.output.json !is null ? probe.payload.output.json : `""`);
	else if (ptype == "reasoning")
		return translateRolloutReasoning(
			probe.payload.summary.json !is null ? probe.payload.summary.json : "[]",
			probe.payload.content.json);

	return null; // Unknown response_item type
}

/// Translate a message response_item payload.
string translateRolloutMessage(string role, string contentJson)
{
	import std.array : replace;
	import std.uuid : randomUUID;

	// Remap Codex content types (input_text/output_text) → agnostic "text"
	auto content = contentJson
		.replace(`"type":"input_text"`, `"type":"text"`)
		.replace(`"type":"output_text"`, `"type":"text"`);

	if (role == "assistant")
	{
		auto uuid = randomUUID().toString();
		auto msgId = "msg_" ~ randomUUID().toString();
		return `{"type":"message/assistant"`
			~ `,"uuid":"` ~ uuid
			~ `","session_id":"","parent_tool_use_id":null`
			~ `,"message":{"id":"` ~ msgId
			~ `","role":"assistant","content":` ~ content
			~ `,"model":"","stop_reason":"end_turn","stop_sequence":null`
			~ `,"usage":{"input_tokens":0,"output_tokens":0}}}`;
	}
	else // user, developer, system
	{
		return `{"type":"message/user","message":{"role":"` ~ escapeJsonString(role)
			~ `","content":` ~ content ~ `}}`;
	}
}

/// Construct a message/assistant with a single tool_use content block.
string translateRolloutToolUse(string callId, string toolName, string inputJson)
{
	import std.uuid : randomUUID;

	if (callId.length == 0)
		callId = randomUUID().toString();

	auto uuid = randomUUID().toString();
	auto msgId = "msg_" ~ randomUUID().toString();
	return `{"type":"message/assistant"`
		~ `,"uuid":"` ~ uuid
		~ `","session_id":"","parent_tool_use_id":null`
		~ `,"message":{"id":"` ~ msgId
		~ `","role":"assistant","content":[{"type":"tool_use","id":"`
		~ escapeJsonString(callId)
		~ `","name":"` ~ escapeJsonString(toolName)
		~ `","input":` ~ inputJson ~ `}]`
		~ `,"model":"","stop_reason":"end_turn","stop_sequence":null`
		~ `,"usage":{"input_tokens":0,"output_tokens":0}}}`;
}

/// Construct a message/user with a tool_result content block.
string translateRolloutToolResult(string callId, string outputJson)
{
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

	return `{"type":"message/user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"`
		~ escapeJsonString(callId)
		~ `","content":` ~ text ~ `}]}}`;
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
		catch (Exception) {}
	}

	if (thinkingText.length == 0)
		return null;

	auto uuid = randomUUID().toString();
	auto msgId = "msg_" ~ randomUUID().toString();
	return `{"type":"message/assistant"`
		~ `,"uuid":"` ~ uuid
		~ `","session_id":"","parent_tool_use_id":null`
		~ `,"message":{"id":"` ~ msgId
		~ `","role":"assistant","content":[{"type":"thinking","thinking":"`
		~ escapeJsonString(thinkingText)
		~ `","signature":""}]`
		~ `,"model":"","stop_reason":"end_turn","stop_sequence":null`
		~ `,"usage":{"input_tokens":0,"output_tokens":0}}}`;
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
	catch (Exception)
		return null;

	if (probe.payload.type == "task_complete")
	{
		import std.uuid : randomUUID;
		auto uuid = randomUUID().toString();
		return `{"type":"turn/result","subtype":"success"`
			~ `,"uuid":"` ~ uuid
			~ `","session_id":"","is_error":false,"num_turns":1,"duration_ms":0,"total_cost_usd":0`
			~ `,"usage":{"input_tokens":0,"output_tokens":0}}`;
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
		return `{"command":"` ~ escapeJsonString(cmd) ~ `","description":""}`;
	}
	catch (Exception)
		return `{}`;
}

/// Escape a string for embedding in JSON.
string escapeJsonString(string s)
{
	import std.array : replace;
	return s
		.replace(`\`, `\\`)
		.replace(`"`, `\"`)
		.replace("\n", `\n`)
		.replace("\r", `\r`)
		.replace("\t", `\t`);
}

/// Resolve the codex binary path by searching PATH.
string resolveCodexBinary()
{
	import std.algorithm : splitter;
	import std.file : exists, isFile;
	import std.process : environment;

	auto pathVar = environment.get("PATH", "");
	foreach (dir; pathVar.splitter(':'))
	{
		auto candidate = buildPath(dir, "codex");
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
