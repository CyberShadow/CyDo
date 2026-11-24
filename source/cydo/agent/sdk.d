module cydo.agent.sdk;

import ae.net.asockets : IConnection;
import ae.net.jsonrpc.binding : JsonRpcDispatcher, jsonRpcDispatcher,
	RPCFlatten, RPCName, RPCNamedParams;
import ae.net.jsonrpc.codec : JsonRpcCodec;
import ae.utils.json : JSONFragment, JSONName, JSONOptional, JSONPartial, jsonParse;
import ae.utils.jsonrpc : JsonRpcException, JsonRpcRequest, JsonRpcResponse;
import ae.utils.serialization.store : SerializedObject;

private alias SO = SerializedObject!(immutable char);
import ae.utils.promise : Promise, reject, resolve;

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
	SO arguments;
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
	SO data;
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

@JSONPartial
struct AuthStatusResult
{
	bool isAuthenticated;
	@JSONOptional string statusMessage;
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
	void handleStartupFailure(Exception error);
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

		codec = process.createJsonRpcCodec();
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

	version (unittest) private this(IConnection connection,
		bool sendInitializationPing)
	{
		initializeTestSdkProcess(this, connection, sendInitializationPing);
	}

	@property State state() { return state_; }
	@property bool dead() { return state_ == State.failed || state_ == State.dead || process.dead; }

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
	/// firing.  We use killAfterTimeout to force-close all pipes after 3 s via
	/// daemon timers, which guarantees the event loop drains even if orphaned
	/// children hold write-ends of the stdout/stderr pipes open.
	///
	/// NOTE: we deliberately do NOT call asyncWait here.  If the AgentProcess
	/// asyncWait (installed in the constructor) fires first it reaps the pid
	/// via waitpid(2), making any subsequent asyncWait for the same pid return
	/// ECHILD indefinitely — leaving a non-daemon ThreadAnchor that never
	/// closes and hangs the event loop forever.
	void shutdown()
	{
		if (dead)
			return;
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

		// Route the existing pipe-drain exit notification through fireExit.
		// AgentProcess.tryFireExit calls onExit once stdout+stderr reach EOF
		// and the process has exited — this is the correct place to fire.
		process.onExit = (int) { fireExit(); };
		process.closeStdin();
		process.terminate();

		// Daemon timers: SIGKILL at +3 s, forceClosePipes at +3.5 s.
		// These are daemon so they do not prevent the event loop from exiting,
		// but the non-daemon stdout/stderr FileConnections keep it alive until
		// the pipes actually close (either naturally or via forceClosePipes).
		import core.time : seconds;
		process.killAfterTimeout(3.seconds);
	}

	/// Queue an action for when the server is ready. Runs immediately if ready.
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
		if (dead)
			return reject!JsonRpcResponse(new Exception("Copilot SDK process is no longer running"));
		JsonRpcRequest req;
		req.method = method;
		req.params = jsonParse!SO(params);
		return codec.sendRequest(req);
	}

	Promise!void requireAuthentication()
	{
		return sendRequest("auth.getStatus", `{}`).then((JsonRpcResponse response) {
			if (response.isError)
				throw new JsonRpcException(response.error.get);
			auto status = response.result.deserializeTo!AuthStatusResult();
			if (!status.isAuthenticated)
				throw new Exception("Copilot CLI is not authenticated: " ~ status.statusMessage);
		});
	}

	/// Send a JSON-RPC notification (no id, no response expected).
	void sendNotification(string method, string params)
	{
		JsonRpcRequest req;
		req.method = method;
		req.params = jsonParse!SO(params);
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
				failStartup(new Exception(resp.error.get.message));
				return;
			}
			int protocolVersion = 0;
			try
			{
				auto pr = resp.result.deserializeTo!PingResult();
				protocolVersion = pr.protocolVersion;
			}
			catch (Exception) {}

			if (protocolVersion < 2)
			{
				failStartup(new Exception("Copilot SDK protocol version is unsupported"));
				return;
			}
			state_ = State.ready;
			auto queue = readyQueue;
			readyQueue = null;
			foreach (dg; queue)
				dg();
		})
		.except((Exception e) {
			failStartup(e);
		});
	}

	private void failStartup(Exception error)
	{
		if (state_ == State.failed || state_ == State.dead)
			return;
		state_ = State.failed;
		readyQueue = null;
		auto handlers = sessions.values;
		foreach (handler; handlers)
			handler.handleStartupFailure(error);
	}
}

version (unittest) private final class TestSdkProcess : SdkProcess
{
	this(IConnection connection, bool sendInitializationPing)
	{
		super(connection, sendInitializationPing);
	}

	override @property bool dead()
	{
		return state_ == State.failed || state_ == State.dead;
	}

	override void shutdown()
	{
		if (dead)
			return;
		state_ = State.dead;
		auto sessionsCopy = sessions.values;
		foreach (session; sessionsCopy)
			session.handleExit(1);
	}
}

version (unittest) private void initializeTestSdkProcess(SdkProcess server,
	IConnection connection, bool sendInitializationPing)
{
	server.codec = new JsonRpcCodec(connection);
	auto router = new SdkServerRouter(server);
	server.serverDispatcher = jsonRpcDispatcher!ISdkServer(router);
	server.codec.handleRequest = &server.serverDispatcher.dispatch;
	if (sendInitializationPing)
		server.sendPing();
	else
		server.state_ = SdkProcess.State.ready;
}

version (unittest) package(cydo.agent) SdkProcess makeTestSdkProcess(
	IConnection connection, bool sendInitializationPing = false)
{
	return new TestSdkProcess(connection, sendInitializationPing);
}
