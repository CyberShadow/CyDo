module cydo.agent.drivers.codex.process;

import core.time : seconds;

import std.exception : enforce;

import ae.net.jsonrpc.binding : JsonRpcDispatcher, jsonRpcDispatcher;
import ae.net.jsonrpc.codec : JsonRpcCodec;
import ae.utils.json : JSONFragment, jsonParse, toJson;
import ae.utils.jsonrpc : JsonRpcErrorCode, JsonRpcException, JsonRpcRequest, JsonRpcResponse;
import ae.utils.promise : Promise, reject, resolve;

version (unittest) import ae.net.asockets : DisconnectType, IConnection;

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

	enum State { starting, initializing, authenticating, ready, dead }
	private State state_ = State.starting;

	// Thread routing: threadId → session (populated after thread/start response)
	private CodexSessionRouteTarget[string] sessions;
	// Task ID → session (populated at session creation, before thread/start)
	private CodexSessionRouteTarget[int] sessionsByTid;
	// A stopped-source fork owns a real private CodexSession while it resumes
	// the source thread. Its route identity must never overlap a logical task.
	// A reservation keeps the process alive without a route. One that never
	// gets a session (a history read) names what to run if the process ends.
	private void delegate()[int] operationRouteReservations_;
	private int nextOperationRouteTid_ = int.min;

	// Actions queued until server reaches ready state.
	private struct ReadyWaiter
	{
		void delegate() ready;
		void delegate(Exception) failed;
	}
	private ReadyWaiter[] readyQueue;
	private Exception readinessError_;

	this(string[] args)
	{
		this.args = args;
	}

	version (unittest) package static IConnection delegate(string[]) spawnForTest;

	void startProcess(void delegate() releaseStartupGate)
	{
		releaseStartupGate_ = releaseStartupGate;
		try
			spawnAndInitialize();
		catch (Exception e)
			failStartup(e);
	}

	package @property Exception startupError() { return readinessError_; }

	private void spawnAndInitialize()
	{
		version (unittest)
			if (spawnForTest !is null)
			{
				auto connection = spawnForTest(args);
				makeTestAppServerProcess(connection, true, this);
				return;
			}

		// Environment and current directory are handled by bwrap (included in args).
		process = new AgentProcess(args, logName: "codex");

		codec = process.createJsonRpcCodec();

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
			if (!terminating_ && state_ != State.ready)
				return failStartup(new Exception("Codex app-server exited"));
			releaseStartupGateOnce();
			state_ = State.dead;
			auto effectiveStatus = status;
			if (terminating_)
				effectiveStatus = 143;
			notifyExit(effectiveStatus);
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

	void unregisterSession(string threadId, void delegate(int) ownerExit)
	{
		auto route = threadId in sessions;
		if (route is null || route.onServerExit != ownerExit)
			return;
		// Send before removing the last route, which can stop the server.
		unsubscribeThread(threadId).ignoreResult();
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

	package int reserveOperationRouteTid(void delegate() onServerExit = null)
	{
		for (;;)
		{
			enforce(nextOperationRouteTid_ < -1,
				"Codex operation route ID space is exhausted");
			auto routeTid = nextOperationRouteTid_++;
			if (routeTid in sessionsByTid || routeTid in operationRouteReservations_)
				continue;
			operationRouteReservations_[routeTid] = onServerExit;
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

	void unregisterSessionByTid(int tid, void delegate(int) ownerExit)
	{
		auto route = tid in sessionsByTid;
		if (route is null || route.onServerExit != ownerExit)
			return;
		sessionsByTid.remove(tid);
		operationRouteReservations_.remove(tid);
		shutdownIfUnrouted();
	}

	/// Run the action once startup succeeds or report why it failed.
	void onReady(void delegate() ready, void delegate(Exception) failed)
	{
		if (state_ == State.ready)
			ready();
		else if (state_ == State.dead)
			failed(readinessError_);
		else
			readyQueue ~= ReadyWaiter(ready, failed);
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
			notifyExit(143);
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
		if (state_ == State.dead)
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
		state_ = State.dead;
		scope (exit) releaseStartupGateOnce();
		if (process is null)
		{
			if (onCancelStartup_)
				onCancelStartup_();
		}
		else
		{
			process.onExit = null;
			if (!process.dead)
			{
				process.closeStdin();
				process.terminate();
				process.killAfterTimeout(0.seconds);
			}
		}
		if (onShutdown_)
			onShutdown_();
		notifyExit(1);
	}

	/// Send a JSON-RPC request to the Codex server.
	/// Returns a promise for the response. For fire-and-forget, ignore the promise.
	package Promise!JsonRpcResponse sendRequest(string method, string params)
	{
		if (dead)
			return reject!JsonRpcResponse(new Exception("Codex app-server is no longer running"));
		JsonRpcRequest req;
		req.method = method;
		req.params = params.jsonParse!SO;
		return codec.sendRequest(req);
	}

	package Promise!JsonRpcResponse unsubscribeThread(string threadId)
	{
		return sendRequest("thread/unsubscribe", toJson(ThreadUnsubscribeParams(threadId)));
	}

	package void releaseUnroutedThread(string threadId)
	{
		if (threadId !in sessions)
			unsubscribeThread(threadId).ignoreResult();
	}

	// ---- Initialization handshake ----

	private void sendInitialize()
	{
		state_ = State.initializing;
		sendRequest("initialize", toJson(makeInitializeParams())).then((JsonRpcResponse result) {
			if (result.isError)
				return failStartup(new JsonRpcException(result.error.get));
			releaseStartupGateOnce();
			sendLogin();
		}, &failStartup).ignoreResult();
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
			if (result.isError)
				return failStartup(new JsonRpcException(result.error.get));
			// API-key auth may complete synchronously.
			auto resultJson = result.result.toJson();
			if (resultJson.canFind(`"success"`) || resultJson.canFind(`"loggedIn"`))
				onLoginCompleted();
		}, &failStartup).ignoreResult();
	}

	private void failStartup(Exception error)
	{
		if (state_ == State.dead)
			return;
		readinessError_ = error;
		shutdown();
	}

	private void onLoginCompleted()
	{
		if (state_ != State.initializing && state_ != State.authenticating)
			return;
		state_ = State.ready;
		auto queue = readyQueue;
		readyQueue = null;
		foreach (waiter; queue)
			waiter.ready();
	}

	private void notifyExit(int status)
	{
		if (readinessError_ is null)
			readinessError_ = new Exception("Codex app-server exited");
		auto queue = readyQueue;
		readyQueue = null;
		foreach (waiter; queue)
			waiter.failed(readinessError_);
		foreach (session; sessionsByTid.values)
			if (session.onServerExit !is null)
				session.onServerExit(status);
		foreach (onServerExit; operationRouteReservations_.values)
			if (onServerExit !is null)
				onServerExit();
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
	IConnection connection, bool startHandshake = false, AppServerProcess server = null)
{
	if (server is null)
		server = new AppServerProcess(null);
	server.codec = new JsonRpcCodec(connection);
	server.codec.handleDisconnect = (string reason, DisconnectType) {
		server.readinessError_ = new Exception(reason);
		server.state_ = AppServerProcess.State.dead;
	};
	if (startHandshake)
		server.sendInitialize();
	else
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
