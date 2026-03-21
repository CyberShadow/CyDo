module cydo.agent.acp;

import ae.net.asockets : IConnection;
import ae.net.jsonrpc.binding : JsonRpcDispatcher, jsonRpcDispatcher,
	RPCFlatten, RPCName, RPCNamedParams;
import ae.net.jsonrpc.codec : JsonRpcCodec;
import ae.utils.json : JSONFragment, JSONName, JSONOptional, JSONPartial;
import ae.utils.jsonrpc : JsonRpcRequest, JsonRpcResponse;
import ae.utils.promise : Promise, resolve;

import cydo.agent.process : AgentProcess;

// ---------------------------------------------------------------------------
// Param/result structs for ACP server-initiated methods.
// ---------------------------------------------------------------------------

// ---- Permission ----

@RPCFlatten @JSONPartial
struct PermissionParams
{
	@JSONPartial static struct Option { string optionId; string kind; }
	Option[] options;
}

struct PermissionOutcome { string outcome; @JSONOptional string optionId; }
struct PermissionResult { PermissionOutcome outcome; }

// ---- Terminal requests ----

@RPCFlatten @JSONPartial
struct TerminalCreateParams
{
	string sessionId;
	string command;
	string[] args;
	@JSONOptional string cwd;
	@JSONPartial static struct EnvVar { string name; string value; }
	@JSONOptional EnvVar[] env;
	@JSONOptional long outputByteLimit;
}

struct TerminalCreateResult { string terminalId; }

@RPCFlatten @JSONPartial
struct TerminalIdParams { string sessionId; string terminalId; }

struct TerminalOutputResult
{
	string output;
	bool truncated;
	@JSONOptional JSONFragment exitStatus;
}

struct TerminalExitResult
{
	@JSONOptional @JSONName("exitCode") int exitCode;
	@JSONOptional string signal;
}

struct EmptyResult {}

// ---- Session update ----

@RPCFlatten @JSONPartial
struct SessionUpdateParams
{
	string sessionId;
	JSONFragment update;
}

// ---------------------------------------------------------------------------
// AcpSessionHandler — per-session event sink wired up by CopilotSession.
// ---------------------------------------------------------------------------

package interface AcpSessionHandler
{
	// Terminal server-initiated requests.
	Promise!TerminalCreateResult handleTerminalCreate(TerminalCreateParams params);
	Promise!TerminalOutputResult handleTerminalOutput(TerminalIdParams params);
	Promise!TerminalExitResult handleTerminalWaitForExit(TerminalIdParams params);
	Promise!EmptyResult handleTerminalKill(TerminalIdParams params);
	Promise!EmptyResult handleTerminalRelease(TerminalIdParams params);

	// Session update notification (receives the `update` field, not the full line).
	void handleSessionUpdate(JSONFragment update);

	// Unchanged.
	void handleStderr(string line);
	void handleExit(int status);
}

// ---------------------------------------------------------------------------
// IAcpServer — methods the ACP server calls on us.
// ---------------------------------------------------------------------------

@RPCNamedParams
private interface IAcpServer
{
	@RPCName("session/request_permission")
	Promise!PermissionResult requestPermission(PermissionParams params);

	@RPCName("terminal/create")
	Promise!TerminalCreateResult terminalCreate(TerminalCreateParams params);

	@RPCName("terminal/output")
	Promise!TerminalOutputResult terminalOutput(TerminalIdParams params);

	@RPCName("terminal/wait_for_exit")
	Promise!TerminalExitResult terminalWaitForExit(TerminalIdParams params);

	@RPCName("terminal/kill")
	Promise!EmptyResult terminalKill(TerminalIdParams params);

	@RPCName("terminal/release")
	Promise!EmptyResult terminalRelease(TerminalIdParams params);

	@RPCName("session/update")
	Promise!void sessionUpdate(SessionUpdateParams params);
}

// ---------------------------------------------------------------------------
// AcpServerRouter — routes incoming requests/notifications to sessions.
// ---------------------------------------------------------------------------

private class AcpServerRouter : IAcpServer
{
	private AcpProcess server;

	this(AcpProcess s) { server = s; }

	Promise!PermissionResult requestPermission(PermissionParams params)
	{
		string optionId = "";
		foreach (ref opt; params.options)
		{
			if (opt.kind == "allow_once")
			{
				optionId = opt.optionId;
				break;
			}
		}
		if (optionId.length > 0)
			return resolve(PermissionResult(PermissionOutcome("selected", optionId)));
		else
			return resolve(PermissionResult(PermissionOutcome("allow")));
	}

	Promise!TerminalCreateResult terminalCreate(TerminalCreateParams params)
	{
		if (auto session = params.sessionId in server.sessions)
			return (*session).handleTerminalCreate(params);
		return resolve(TerminalCreateResult(""));
	}

	Promise!TerminalOutputResult terminalOutput(TerminalIdParams params)
	{
		if (auto session = params.sessionId in server.sessions)
			return (*session).handleTerminalOutput(params);
		return resolve(TerminalOutputResult("", false));
	}

	Promise!TerminalExitResult terminalWaitForExit(TerminalIdParams params)
	{
		if (auto session = params.sessionId in server.sessions)
			return (*session).handleTerminalWaitForExit(params);
		return resolve(TerminalExitResult());
	}

	Promise!EmptyResult terminalKill(TerminalIdParams params)
	{
		if (auto session = params.sessionId in server.sessions)
			return (*session).handleTerminalKill(params);
		return resolve(EmptyResult());
	}

	Promise!EmptyResult terminalRelease(TerminalIdParams params)
	{
		if (auto session = params.sessionId in server.sessions)
			return (*session).handleTerminalRelease(params);
		return resolve(EmptyResult());
	}

	Promise!void sessionUpdate(SessionUpdateParams params)
	{
		if (auto session = params.sessionId in server.sessions)
			(*session).handleSessionUpdate(params.update);
		return resolve();
	}
}

// ---------------------------------------------------------------------------
// AcpProcess — manages a JSON-RPC 2.0 ACP subprocess.
// One instance per CopilotSession (model and MCP config are per-process).
// Structural mirror of AppServerProcess in codex.d.
// ---------------------------------------------------------------------------

class AcpProcess
{
	private AgentProcess process;
	private JsonRpcCodec codec;
	private JsonRpcDispatcher!IAcpServer serverDispatcher;

	enum State { starting, initializing, ready, failed, dead }
	private State state_ = State.starting;

	// Session routing: sessionId → handler
	private AcpSessionHandler[string] sessions;

	// Actions queued until server reaches ready state.
	private void delegate()[] readyQueue;

	this(string[] args, string[string] env, string workDir)
	{
		process = new AgentProcess(args, env, workDir);

		IConnection connection = process.connection;
		codec = new JsonRpcCodec(connection);
		auto router = new AcpServerRouter(this);
		serverDispatcher = jsonRpcDispatcher!IAcpServer(router);
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
				stderr.writeln("[acp/pre-session-stderr] " ~ line);
			}
		};

		process.onExit = (int status) {
			state_ = State.dead;
			foreach (session; sessions)
				session.handleExit(status);
		};

		sendInitialize();
	}

	@property State state() { return state_; }
	@property bool dead() { return state_ == State.dead || process.dead; }

	void registerSession(string sessionId, AcpSessionHandler handler)
	{
		sessions[sessionId] = handler;
	}

	void unregisterSession(string sessionId)
	{
		sessions.remove(sessionId);
	}

	/// Terminate the underlying ACP process.
	void shutdown()
	{
		if (!dead)
			process.terminate();
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

	private void sendInitialize()
	{
		state_ = State.initializing;
		sendRequest("initialize",
			`{"protocolVersion":1,"clientCapabilities":{},"clientInfo":{"name":"cydo","version":"0.1.0"}}`)
		.then((JsonRpcResponse resp) {
			if (resp.isError)
			{
				state_ = State.failed;
				return;
			}
			state_ = State.ready;
			auto queue = readyQueue;
			readyQueue = null;
			foreach (dg; queue)
				dg();
		});
	}
}
