module cydo.agent.drivers.codex.process;

import core.time : seconds;

import std.exception : enforce;

import ae.net.jsonrpc.binding : JsonRpcDispatcher, jsonRpcDispatcher;
import ae.net.jsonrpc.codec : JsonRpcCodec;
import ae.utils.json : JSONFragment, jsonParse, toJson;
import ae.utils.jsonrpc : JsonRpcErrorCode, JsonRpcRequest, JsonRpcResponse;
import ae.utils.promise : Promise, resolve;

version (unittest) import ae.net.asockets : IConnection;

import cydo.agent.drivers.codex.app_server;
import cydo.agent.drivers.codex.rpc;
import cydo.agent.process : AgentProcess;
import cydo.protocol : TranslatedEvent;

// ---------------------------------------------------------------------------
// AppServerProcess — manages a `codex app-server` process via JSON-RPC 2.0.
// One instance per workspace, shared across multiple CodexSessions (threads).
// ---------------------------------------------------------------------------

class AppServerProcess
{
	private string[] args;
	private AgentProcess process;
	private JsonRpcCodec codec;
	private JsonRpcDispatcher!ICodexServer serverDispatcher;
	private bool terminating_;
	private void delegate() releaseStartupGate_;

	enum State { starting, initializing, authenticating, ready, failed, dead }
	private State state_ = State.starting;

	// Thread routing: threadId → session (populated after thread/start response)
	private CodexSessionRouteTarget[string] sessions;
	// Task ID → session (populated at session creation, before thread/start)
	private CodexSessionRouteTarget[int] sessionsByTid;
	// A stopped-source fork owns a real private CodexSession while it resumes
	// the source thread. Its route identity must never overlap a logical task.
	private bool[int] operationRouteReservations_;
	private int nextOperationRouteTid_ = int.min;

	// Actions queued until server reaches ready state.
	private void delegate()[] readyQueue;

	this(string[] args)
	{
		this.args = args;
	}

	void startProcess(void delegate() releaseStartupGate)
	{
		// Environment and current directory are handled by bwrap (included in args).
		process = new AgentProcess(args, logName: "codex");
		releaseStartupGate_ = releaseStartupGate;

		// Set up bidirectional JSON-RPC codec on the process connection.
		// The codec takes over handleReadData from stdoutLines; onStdoutLine
		// is no longer called.
		codec = new JsonRpcCodec(process.connection);

		// Dispatcher for incoming notifications/requests from Codex.
		auto owner = CodexServerOwner(&sessionForThread, &allSessions, &onLoginCompleted);
		auto router = new CodexServerRouter(owner);
		serverDispatcher = jsonRpcDispatcher!ICodexServer(router);
		codec.handleRequest = (JsonRpcRequest request) {
			if (isSilentlyIgnoredCodexNotificationMethod(request.method))
				return resolve(JsonRpcResponse.init);
			return serverDispatcher.dispatch(request).then((JsonRpcResponse resp) {
				if (resp.isError && resp.error.get.code == JsonRpcErrorCode.methodNotFound)
				{
					import cydo.protocol : makeUnrecognizedEvent;
					auto paramsJson = request.params ? request.params.toJson() : "null";
					auto rawJsonRpc = `{"jsonrpc":"2.0","method":"` ~ request.method ~ `","params":`
						~ paramsJson ~ `}`;
					auto tev = TranslatedEvent(makeUnrecognizedEvent("unknown method: " ~ request.method), rawJsonRpc);
					// Try to route to a specific session by threadId/conversationId.
					string routedId;
					if (request.params)
					{
						import std.string : indexOf;
						foreach (key; ["threadId", "conversationId"])
						{
							auto needle = `"` ~ key ~ `":"`;
							auto idx = paramsJson.indexOf(needle);
							if (idx >= 0)
							{
								idx += needle.length;
								auto end = paramsJson.indexOf(`"`, idx);
								if (end > idx)
								{
									routedId = paramsJson[idx .. end];
									break;
								}
							}
						}
					}
					if (routedId.length > 0)
					{
						auto session = sessionForThread(routedId);
						if (session.valid)
							session.emitTranslatedEvent(tev);
					}
					else
					{
						foreach (session; allSessions())
							session.emitTranslatedEvent(tev);
					}
				}
				return resp;
			});
		};

		process.onStderrLine = (string line) {
			foreach (session; sessionsByTid)
				if (session.emitStderr !is null)
					session.emitStderr(line);
		};

		process.onExit = (int status) {
			releaseStartupGateOnce();
			state_ = State.dead;
			auto effectiveStatus = status;
			if (terminating_)
				effectiveStatus = 143;
			foreach (session; sessionsByTid)
				if (session.onServerExit !is null)
					session.onServerExit(effectiveStatus);
		};

		// Begin initialization handshake.
		sendInitialize();
	}

	@property State state() { return state_; }

	void registerSession(string threadId, CodexSessionRouteTarget session)
	{
		enforce(threadId.length > 0, "Codex thread route requires a thread ID");
		enforce(threadId !in sessions,
			"Codex thread route is already registered");
		sessions[threadId] = session;
	}

	void unregisterSession(string threadId)
	{
		sessions.remove(threadId);
		shutdownIfUnrouted();
	}

	void registerSessionByTid(int tid, CodexSessionRouteTarget session)
	{
		enforce(tid !in operationRouteReservations_,
			"Codex task route conflicts with an operation reservation");
		enforce(tid !in sessionsByTid,
			"Codex task route is already registered");
		sessionsByTid[tid] = session;
	}

	package int reserveOperationRouteTid()
	{
		for (;;)
		{
			enforce(nextOperationRouteTid_ < -1,
				"Codex operation route ID space is exhausted");
			auto routeTid = nextOperationRouteTid_++;
			if (routeTid in sessionsByTid || routeTid in operationRouteReservations_)
				continue;
			operationRouteReservations_[routeTid] = true;
			return routeTid;
		}
	}

	package void registerOperationSessionByTid(int routeTid,
		CodexSessionRouteTarget session)
	{
		enforce(routeTid in operationRouteReservations_,
			"Codex operation route was not reserved");
		enforce(routeTid !in sessionsByTid,
			"Codex operation route is already registered");
		sessionsByTid[routeTid] = session;
	}

	package void cancelOperationRouteReservation(int routeTid)
	{
		enforce(routeTid in operationRouteReservations_,
			"Codex operation route was not reserved");
		enforce(routeTid !in sessionsByTid,
			"Codex operation route must unregister before cancellation");
		operationRouteReservations_.remove(routeTid);
		shutdownIfUnrouted();
	}

	void unregisterSessionByTid(int tid)
	{
		sessionsByTid.remove(tid);
		operationRouteReservations_.remove(tid);
		shutdownIfUnrouted();
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
		if (terminating_)
			return;
		terminating_ = true;
		if (process is null)
		{
			if (onCancelStartup_)
				onCancelStartup_();
			state_ = State.dead;
			foreach (session; sessionsByTid)
				if (session.onServerExit !is null)
					session.onServerExit(143);
			return;
		}
		if (process.dead)
			return;
		// codex app-server runs over stdio; closing stdin reliably triggers
		// shutdown even when SIGTERM is not handled promptly.
		process.closeStdin();
		process.terminate();
		// Use killAfterTimeout(0) — SIGTERM already sent above, so the
		// first timer fires immediately (re-sends SIGTERM, harmless), then
		// SIGKILL + force-close pipes after 2s.
		process.killAfterTimeout(0.seconds);
	}

	@property bool dead()
	{
		if (state_ == State.dead || state_ == State.failed)
			return true;
		return process !is null && process.dead;
	}

	/// Callback invoked when this server shuts down, for pool cleanup.
	package void delegate() onShutdown_;
	package void delegate() onCancelStartup_;

	/// Terminate the server immediately and notify remaining sessions.
	/// Nulls onExit to prevent double-firing from the async process exit.
	void shutdown()
	{
		if (state_ == State.dead) return;
		if (process is null)
		{
			if (onCancelStartup_)
				onCancelStartup_();
		}
		else
		{
			releaseStartupGateOnce();
			process.onExit = null;
			if (!process.dead)
			{
				process.closeStdin();
				process.terminate();
				process.killAfterTimeout(0.seconds);
			}
		}
		state_ = State.dead;
		foreach (session; sessionsByTid)
			if (session.onServerExit !is null)
				session.onServerExit(1);
		if (onShutdown_)
			onShutdown_();
	}

	/// Send a JSON-RPC request to the Codex server.
	/// Returns a promise for the response. For fire-and-forget, ignore the promise.
	package Promise!JsonRpcResponse sendRequest(string method, string params)
	{
		JsonRpcRequest req;
		req.method = method;
		req.params = params.jsonParse!SO;
		return codec.sendRequest(req);
	}

	// ---- Initialization handshake ----

	private void sendInitialize()
	{
		state_ = State.initializing;
		sendRequest("initialize", toJson(makeInitializeParams())).then((JsonRpcResponse result) {
			releaseStartupGateOnce();
			sendLogin();
		});
	}

	private void releaseStartupGateOnce()
	{
		if (releaseStartupGate_ is null)
			return;
		auto release = releaseStartupGate_;
		releaseStartupGate_ = null;
		release();
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
			toJson(LoginStartParams("apiKey", apiKey))
		).then((JsonRpcResponse result) {
			import std.algorithm : canFind;
			// API-key auth may complete synchronously.
			auto resultJson = result.result.toJson();
			if (resultJson.canFind(`"success"`) || resultJson.canFind(`"loggedIn"`))
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

	private CodexSessionRouteTarget sessionForThread(string threadId)
	{
		if (auto session = threadId in sessions)
			return *session;
		return CodexSessionRouteTarget.init;
	}

	private CodexSessionRouteTarget[] allSessions()
	{
		return sessionsByTid.values;
	}

	private void shutdownIfUnrouted()
	{
		if (sessions.length == 0 && sessionsByTid.length == 0
			&& operationRouteReservations_.length == 0)
			shutdown();
	}

	version (unittest) package bool hasThreadRouteForTest(string threadId)
	{
		return (threadId in sessions) !is null;
	}
}

private InitializeParams makeInitializeParams()
{
	static struct Capabilities
	{
		bool experimentalApi;
		// Notifications CyDo has no use for: Codex then does not send them.
		string[] optOutNotificationMethods;
	}
	auto capabilities = Capabilities(true, [
		"mcpServer/startupStatus/updated",
		"remoteControl/status/changed",
		// Codex sends this only when a request applies thread settings
		// (thread/settings/update, or turn/start overrides such as the
		// sandbox policy CyDo passes on every turn), to echo the
		// resulting model, effort, cwd, approval and sandbox settings.
		// CyDo chose those settings itself and is the app-server's only
		// client, so the echo carries nothing it doesn't already know.
		"thread/settings/updated",
		"thread/readState/changed",
		"turn/moderationMetadata",
		"thread/reverted",
	]);
	return InitializeParams(
		InitializeParams.ClientInfo("cydo", "0.1.0"),
		JSONFragment(toJson(capabilities))
	);
}

version (unittest) package AppServerProcess makeTestAppServerProcess(
	IConnection connection)
{
	auto server = new AppServerProcess(null);
	server.codec = new JsonRpcCodec(connection);
	server.state_ = AppServerProcess.State.ready;
	return server;
}

unittest
{
	import std.algorithm : canFind;

	auto params = jsonParse!SO(toJson(makeInitializeParams()));
	auto methods = jsonParse!(string[])(
		params["capabilities"]["optOutNotificationMethods"].toJson());
	foreach (method; [
		"mcpServer/startupStatus/updated",
		"remoteControl/status/changed",
		"thread/settings/updated",
		"thread/readState/changed",
		"turn/moderationMetadata",
		"thread/reverted",
	])
		assert(methods.canFind(method), "Missing initialize opt-out: " ~ method);
}
