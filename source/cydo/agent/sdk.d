module cydo.agent.sdk;

import std.exception : enforce;

import ae.net.asockets : DisconnectType, socketManager;
version (unittest) import ae.net.asockets : IConnection;
import ae.net.jsonrpc.binding : JsonRpcDispatcher, jsonRpcDispatcher,
	RPCFlatten, RPCName, RPCNamedParams;
import ae.utils.json : JSONFragment, JSONName, JSONOptional, JSONPartial, jsonParse;
import ae.utils.jsonrpc : JsonRpcException, JsonRpcRequest, JsonRpcResponse;
import ae.utils.serialization.store : SerializedObject;

private alias SO = SerializedObject!(immutable char);
import ae.utils.promise : Promise, reject, resolve;

import cydo.agent.process : AgentProcess, AgentRpcCodec, FramingMode, ReadinessQueue, RpcRetirement, scheduleOwnerExit;

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

/// Startup opens readiness. Retirement stops new RPCs and fixes the exit
/// cause. Only confirmed exit, deferred behind codec continuations, closes
/// readiness and notifies the registered sessions.
class SdkProcess
{
	private AgentProcess process;
	private AgentRpcCodec codec;
	private JsonRpcDispatcher!ISdkServer serverDispatcher;

	enum State { starting, initializing, ready, retiring, dead }
	private State state_ = State.starting;

	// Session routing: sessionId → handler
	private SdkSessionHandler[string] sessions;

	private enum Retirement { transport, startupFailure, shutdown }
	private Retirement retirement_;
	private bool exitQueued_;
	private ReadinessQueue readiness_;
	private Exception startupError_;

	version (unittest) private bool exitOnRetireForTest;

	this(string[] args, string[string] env, string workDir, string logName)
	{
		process = new AgentProcess(args, env, workDir, false, FramingMode.contentLength, logName: logName);

		codec = process.attachJsonRpcCodec(&onTransportDisconnect);
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

		process.onExit = &confirmedExit;

		sendPing();
	}

	version (unittest) private this(IConnection connection,
		bool sendInitializationPing, bool exitOnRetire)
	{
		exitOnRetireForTest = exitOnRetire;
		codec = new AgentRpcCodec(connection, &onTransportDisconnect);
		auto router = new SdkServerRouter(this);
		serverDispatcher = jsonRpcDispatcher!ISdkServer(router);
		codec.handleRequest = &serverDispatcher.dispatch;
		if (sendInitializationPing)
			sendPing();
		else
		{
			state_ = State.ready;
			readiness_.open();
		}
	}

	@property State state() { return state_; }
	@property bool dead() { return state_ >= State.retiring; }

	void registerSession(string sessionId, SdkSessionHandler handler)
	{
		enforce(state_ != State.dead, "Cannot register a session on an exited Copilot SDK");
		sessions[sessionId] = handler;
	}

	void unregisterSession(string sessionId)
	{
		sessions.remove(sessionId);
	}

	void shutdown() { retire(Retirement.shutdown); }

	private void retire(Retirement cause)
	{
		if (dead)
			return;
		state_ = State.retiring;
		retirement_ = cause;
		if (process !is null)
			process.retire(RpcRetirement.copilot);
		else
		{
			version (unittest)
				if (exitOnRetireForTest)
					confirmedExit(1);
		}
	}

	void onReady(void delegate() ready, void delegate(Exception) failed)
	{
		readiness_.wait(ready, failed);
	}

	package(cydo.agent) void confirmedExit(int status)
	{
		retire(Retirement.transport);
		if (exitQueued_)
			return;
		exitQueued_ = true;
		scheduleOwnerExit({ fanout(status); });
	}

	private void fanout(int status)
	{
		state_ = State.dead;
		readiness_.close(startupError_ is null ? new Exception("Copilot SDK exited") : startupError_);
		foreach (session; sessions.values)
			if (startupError_ !is null)
				session.handleStartupFailure(startupError_);
			else
				session.handleExit(retirement_ == Retirement.shutdown ? 1 : status);
	}

	/// Send a JSON-RPC request, returning a promise for the response.
	Promise!JsonRpcResponse sendRequest(string method, string params)
	{
		if (dead)
			return reject!JsonRpcResponse(new Exception("Copilot SDK is not running"));
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
				recordStartupReplyFailure(new Exception(resp.error.get.message));
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
				recordStartupReplyFailure(new Exception("Copilot SDK protocol version is unsupported"));
				return;
			}
			if (state_ != State.initializing)
				return;
			state_ = State.ready;
			readiness_.open();
		})
		.except((Exception e) {
			failStartup(e);
		}).ignoreResult();
	}

	private void onTransportDisconnect(string reason, DisconnectType)
	{
		if (!dead && !readiness_.isOpen)
			startupError_ = new Exception("JSON-RPC connection closed: " ~ reason);
		retire(Retirement.transport);
	}

	private void failStartup(Exception error)
	{
		if (dead)
			return;
		recordStartupReplyFailure(error);
	}

	private void recordStartupReplyFailure(Exception error)
	{
		startupError_ = error;
		retire(Retirement.startupFailure);
	}
}

version (unittest) package(cydo.agent) SdkProcess makeTestSdkProcess(
	IConnection connection, bool sendInitializationPing = false, bool exitOnRetire = true)
{
	return new SdkProcess(connection, sendInitializationPing, exitOnRetire);
}

version (unittest) private final class TestSdkExitHandler : SdkSessionHandler
{
	string[] startupErrors;
	int[] exits;

	void handleEvent(SdkEvent) { assert(false); }
	Promise!SdkPermissionResult handlePermissionRequest(SdkPermissionRequest) { assert(false); }
	Promise!SdkToolCallResult handleToolCall(SdkToolCallRequest) { assert(false); }
	void handleStderr(string line) { assert(false, line); }
	void handleStartupFailure(Exception error) { startupErrors ~= error.msg; }
	void handleExit(int status) { exits ~= status; }
}

unittest
{
	import cydo.agent.process : rpcChildSurvivalProbe;
	import std.conv : to;
	import std.file : exists, remove, tempDir;
	import std.path : buildPath;
	import std.process : thisProcessID;
	import std.string : startsWith;

	foreach (unsupportedVersion; [false, true])
	{
		auto marker = buildPath(tempDir, "cydo-sdk-startup-" ~ thisProcessID.to!string);
		scope (exit) if (exists(marker)) remove(marker);
		auto action = unsupportedVersion ? q"SH
			payload='{"jsonrpc":"2.0","id":1,"result":{"message":"health check","timestamp":0,"protocolVersion":1}}'
			printf 'Content-Length: %d\r\n\r\n%s' "${#payload}" "$payload"
SH" : "exec 1>&-\n";
		auto server = new SdkProcess(["sh", "-c", "trap 'exit 42' TERM\nread -r header\n"
			~ action ~ rpcChildSurvivalProbe, "test", marker], null, null, "test-sdk");
		auto route = new TestSdkExitHandler;
		server.registerSession("starting", route);
		string[] errors;
		server.onReady({ assert(false, "startup reached readiness"); },
			(Exception e) { errors ~= e.msg; });
		socketManager.loop();

		assert(route.exits.length == 0);
		assert(errors.length == 1 && route.startupErrors == errors);
		if (unsupportedVersion)
			assert(errors[0] == "Copilot SDK protocol version is unsupported");
		else
			assert(errors[0].startsWith("JSON-RPC connection closed: "));
		assert(!exists(marker), "the SDK child survived retirement");
	}
}
