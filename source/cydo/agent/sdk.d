module cydo.agent.sdk;

import ae.net.asockets : IConnection;
import ae.net.jsonrpc.binding : JsonRpcDispatcher, jsonRpcDispatcher,
	RPCFlatten, RPCName, RPCNamedParams;
import ae.net.jsonrpc.codec : JsonRpcCodec;
import ae.utils.json : JSONFragment, JSONName, JSONOptional, JSONPartial, jsonParse;
import ae.utils.jsonrpc : JsonRpcRequest, JsonRpcResponse;
import ae.utils.promise : Promise, resolve;

import cydo.agent.process : AgentProcess, FramingMode;

// ---------------------------------------------------------------------------
// Param/result structs for SDK server-initiated methods.
// ---------------------------------------------------------------------------

// ---- Permission ----

@RPCFlatten @JSONPartial
struct SdkPermissionRequest
{
	string sessionId;
	string kind;       // "shell", "write", "read", "mcp", "custom-tool", "url"
	string toolCallId;
	@JSONOptional string fullCommandText;
}

struct SdkPermissionResult
{
	string kind;  // "approved" or "denied-interactively-by-user"
	@JSONOptional string feedback;
}

// ---- Tool call ----

@RPCFlatten @JSONPartial
struct SdkToolCallRequest
{
	string sessionId;
	string toolCallId;
	string toolName;
	JSONFragment arguments;
	@JSONOptional string traceparent;
}

struct SdkToolResult
{
	string textResultForLlm;
	string resultType;  // "success" or "failure"
	@JSONOptional string error;
}

struct SdkToolCallResult
{
	SdkToolResult result;
}

// ---- Session event ----

@JSONPartial
struct SdkEvent
{
	string id;
	string timestamp;
	@JSONOptional string parentId;
	string type;
	JSONFragment data;
}

@RPCFlatten @JSONPartial
struct SdkSessionEventParams
{
	string sessionId;
	SdkEvent event;
}

// ---- Ping ----

struct PingParams
{
	string message;
}

@JSONPartial
struct PingResult
{
	string message;
	long timestamp;
	int protocolVersion;
}

// ---- Session results ----

@JSONPartial
struct SessionResult
{
	@JSONOptional string workspacePath;
}

@JSONPartial
struct SessionSendResult
{
	@JSONOptional string messageId;
}

struct EmptyResult {}

// ---------------------------------------------------------------------------
// SdkSessionHandler — per-session event sink wired up by CopilotSession.
// ---------------------------------------------------------------------------

package(cydo.agent) interface SdkSessionHandler
{
	void handleEvent(SdkEvent event);
	Promise!SdkPermissionResult handlePermissionRequest(SdkPermissionRequest params);
	Promise!SdkToolCallResult handleToolCall(SdkToolCallRequest params);
	void handleStderr(string line);
	void handleExit(int status);
}

// ---------------------------------------------------------------------------
// ISdkServer — methods the SDK server calls on us.
// ---------------------------------------------------------------------------

@RPCNamedParams
private interface ISdkServer
{
	// Server → Client notification
	@RPCName("session.event")
	Promise!void sessionEvent(SdkSessionEventParams params);

	// Server → Client synchronous RPC requests
	@RPCName("permission.request")
	Promise!SdkPermissionResult permissionRequest(SdkPermissionRequest params);

	@RPCName("tool.call")
	Promise!SdkToolCallResult toolCall(SdkToolCallRequest params);
}

// ---------------------------------------------------------------------------
// SdkServerRouter — routes incoming requests/notifications to sessions.
// ---------------------------------------------------------------------------

private class SdkServerRouter : ISdkServer
{
	private SdkProcess server;

	this(SdkProcess s) { server = s; }

	Promise!void sessionEvent(SdkSessionEventParams params)
	{
		if (auto session = params.sessionId in server.sessions)
			(*session).handleEvent(params.event);
		return resolve();
	}

	Promise!SdkPermissionResult permissionRequest(SdkPermissionRequest params)
	{
		if (auto session = params.sessionId in server.sessions)
			return (*session).handlePermissionRequest(params);
		return resolve(SdkPermissionResult("approved"));
	}

	Promise!SdkToolCallResult toolCall(SdkToolCallRequest params)
	{
		if (auto session = params.sessionId in server.sessions)
			return (*session).handleToolCall(params);
		return resolve(SdkToolCallResult(SdkToolResult(
			"Unknown session: " ~ params.sessionId, "failure")));
	}
}

// ---------------------------------------------------------------------------
// SdkProcess — manages a JSON-RPC 2.0 SDK subprocess.
// One instance per CopilotAgent (shared across sessions).
// One instance per CopilotAgent (shared across sessions).
// ---------------------------------------------------------------------------

class SdkProcess
{
	private AgentProcess process;
	private JsonRpcCodec codec;
	private JsonRpcDispatcher!ISdkServer serverDispatcher;

	enum State { starting, initializing, ready, failed, dead }
	private State state_ = State.starting;

	// Session routing: sessionId → handler
	private SdkSessionHandler[string] sessions;

	// Actions queued until server reaches ready state.
	private void delegate()[] readyQueue;

	this(string[] args, string[string] env, string workDir, string logName)
	{
		process = new AgentProcess(args, env, workDir, false, FramingMode.contentLength, logName: logName);

		IConnection connection = process.connection;
		codec = new JsonRpcCodec(connection);
		auto router = new SdkServerRouter(this);
		serverDispatcher = jsonRpcDispatcher!ISdkServer(router);
		codec.handleRequest = &serverDispatcher.dispatch;

		process.onStderrLine = (string line) {
			bool routed = false;
			foreach (session; sessions)
			{
				session.handleStderr(line);
				routed = true;
			}
			if (!routed)
			{
				import std.stdio : stderr;
				stderr.writeln("[sdk/pre-session-stderr] " ~ line);
			}
		};

		process.onExit = (int status) {
			state_ = State.dead;
			foreach (session; sessions)
				session.handleExit(status);
		};

		sendPing();
	}

	@property State state() { return state_; }
	@property bool dead() { return state_ == State.dead || process.dead; }

	void registerSession(string sessionId, SdkSessionHandler handler)
	{
		sessions[sessionId] = handler;
	}

	void unregisterSession(string sessionId)
	{
		sessions.remove(sessionId);
	}

	/// Terminate the underlying SDK process and defer exit handlers until the
	/// process has actually exited.  The copilot binary may spawn children that
	/// hold the stdout pipe open, preventing AgentProcess.tryFireExit from ever
	/// firing.  We bypass pipe-based exit detection by using asyncWait (SIGCHLD)
	/// directly, which fires as soon as the process exits — guaranteeing the
	/// binary has flushed its session files (events.jsonl) before onExit runs.
	void shutdown()
	{
		if (dead)
			return;
		// Prevent AgentProcess.tryFireExit from double-firing.
		process.onExit = null;
		process.closeStdin();
		process.terminate();
		state_ = State.dead;

		// Snapshot sessions — the map may be mutated by handleExit.
		auto sessionsCopy = sessions.values;
		bool fired = false;
		void fireExit() {
			if (fired) return;
			fired = true;
			foreach (session; sessionsCopy)
				session.handleExit(1);
		}

		// Wait for actual process exit (SIGCHLD) before firing handlers.
		// This ensures the binary has flushed its files (events.jsonl).
		import ae.sys.process : asyncWait;
		import ae.sys.timing : setTimeout;
		import core.time : msecs;
		asyncWait(process.processId, (int) { fireExit(); });
		// Safety net: if asyncWait never fires (zombie), SIGKILL and timeout after 3s.
		setTimeout({
			if (!process.dead)
			{
				import core.sys.posix.signal : SIGKILL;
				process.sendSignal(SIGKILL);
			}
			fireExit();
		}, 3000.msecs);
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

	/// Send a JSON-RPC request, returning a promise for the response.
	Promise!JsonRpcResponse sendRequest(string method, string params)
	{
		JsonRpcRequest req;
		req.method = method;
		req.params = JSONFragment(params);
		return codec.sendRequest(req);
	}

	/// Send a JSON-RPC notification (no id, no response expected).
	void sendNotification(string method, string params)
	{
		JsonRpcRequest req;
		req.method = method;
		req.params = JSONFragment(params);
		codec.sendNotification(req);
	}

	// ---- Initialization handshake ----

	private void sendPing()
	{
		state_ = State.initializing;
		sendRequest("ping", `{"message":"health check"}`)
		.then((JsonRpcResponse resp) {
			if (resp.isError)
			{
				state_ = State.failed;
				return;
			}
			int protocolVersion = 0;
			try
			{
				auto pr = jsonParse!PingResult(resp.result.json);
				protocolVersion = pr.protocolVersion;
			}
			catch (Exception) {}

			if (protocolVersion < 2)
			{
				state_ = State.failed;
				return;
			}
			state_ = State.ready;
			auto queue = readyQueue;
			readyQueue = null;
			foreach (dg; queue)
				dg();
		})
		.except((Exception e) {
			state_ = State.failed;
		});
	}
}
