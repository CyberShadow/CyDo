module cydo.agent.drivers.codex.process;

import std.exception : enforce;
import std.logger : warningf;

import ae.net.jsonrpc.binding : JsonRpcDispatcher, jsonRpcDispatcher;
import ae.utils.json : JSONFragment, jsonParse, toJson;
import ae.utils.jsonrpc : JsonRpcErrorCode, JsonRpcException, JsonRpcRequest, JsonRpcResponse;
import ae.utils.promise : Promise, reject, resolve;

import ae.net.asockets : DisconnectType, socketManager;
version (unittest) import ae.net.asockets : IConnection;

import cydo.agent.drivers.codex.app_server;
import cydo.agent.drivers.codex.rpc;
import cydo.agent.process : AgentProcess, AgentRpcCodec, ReadinessQueue, RpcRetirement, scheduleOwnerExit;
import cydo.protocol : TranslatedEvent;

// ---------------------------------------------------------------------------
// AppServerProcess — manages a `codex app-server` process via JSON-RPC 2.0.
// One instance per workspace, shared across multiple CodexSessions (threads).
// ---------------------------------------------------------------------------

/// Startup opens readiness. Retirement stops new RPCs and evicts the owner.
/// The first retirement cause fixes the exit status. Only confirmed exit,
/// deferred behind codec continuations, closes readiness and notifies routes.
class AppServerProcess
{
	private string[] args;
	private AgentProcess process;
	private AgentRpcCodec codec;
	private JsonRpcDispatcher!ICodexServer serverDispatcher;
	private enum Retirement { transport, startupFailure, shutdown, terminate }
	private Retirement retirement_;
	private bool exitQueued_;
	private void delegate() releaseStartupGate_;

	enum State { starting, initializing, authenticating, ready, retiring, dead }
	private State state_ = State.starting;

	// Thread routing: threadId → session (populated after thread/start response)
	private CodexSessionRouteTarget[string] sessions;
	// Task ID → session (populated at session creation, before thread/start)
	private CodexSessionRouteTarget[int] sessionsByTid;
	// A stopped-source fork owns a real private CodexSession while it resumes
	// the source thread. Its route identity must never overlap a logical task.
	// A reservation keeps the process alive without a route.
	private bool[int] operationRouteReservations_;
	private enum firstNonOperationRouteTid = -1;
	private int nextOperationRouteTid_ = int.min;

	private ReadinessQueue readiness_;
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

		codec = process.attachJsonRpcCodec(&onTransportDisconnect);

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

		process.onExit = &confirmedExit;
		sendInitialize();
	}

	package void confirmedExit(int status)
	{
		retire(Retirement.transport);
		if (exitQueued_)
			return;
		exitQueued_ = true;
		scheduleOwnerExit({ fanout(status); });
	}

	@property State state() { return state_; }

	void registerSession(string threadId, CodexSessionRouteTarget session)
	{
		enforce(state_ != State.dead, "Cannot register a route on an exited Codex app-server");
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
		releaseThreadSubscription(threadId);
		sessions.remove(threadId);
		shutdownIfUnrouted();
	}

	void registerSessionByTid(int tid, CodexSessionRouteTarget session)
	{
		enforce(state_ != State.dead, "Cannot register a route on an exited Codex app-server");
		enforce(tid >= firstNonOperationRouteTid,
			"Codex task route cannot use an operation route ID");
		enforce(tid !in sessionsByTid,
			"Codex task route is already registered");
		sessionsByTid[tid] = session;
	}

	package int reserveOperationRouteTid()
	{
		for (;;)
		{
			enforce(nextOperationRouteTid_ < firstNonOperationRouteTid,
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
		enforce(state_ != State.dead, "Cannot register a route on an exited Codex app-server");
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

	void onReady(void delegate() ready, void delegate(Exception) failed)
	{
		readiness_.wait(ready, failed);
	}

	@property bool dead() const { return state_ >= State.retiring; }

	/// Evict the retiring server and cancel its startup if it was queued.
	package void delegate() onShutdown_;

	void shutdown() { retire(Retirement.shutdown); }
	void terminate() { retire(Retirement.terminate); }

	private void retire(Retirement cause)
	{
		if (dead)
			return;
		state_ = State.retiring;
		retirement_ = cause;
		if (onShutdown_)
			onShutdown_();
		if (process !is null)
			process.retire(RpcRetirement.codex);
		else if (codec is null)
			confirmedExit(1);
	}

	/// Send a JSON-RPC request to the Codex server.
	package Promise!JsonRpcResponse sendRequest(string method, string params)
	{
		if (dead)
			return reject!JsonRpcResponse(new Exception("Codex app-server is not running"));
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
			releaseThreadSubscription(threadId);
	}

	private void releaseThreadSubscription(string threadId)
	{
		unsubscribeThread(threadId).then((JsonRpcResponse) {}, (Exception e) {
			warningf("thread/unsubscribe failed: %s", e.msg);
		}).ignoreResult();
	}

	// ---- Initialization handshake ----

	private void sendInitialize()
	{
		state_ = State.initializing;
		sendRequest("initialize", toJson(makeInitializeParams())).then((JsonRpcResponse result) {
			if (result.isError)
				return recordStartupReplyFailure(new JsonRpcException(result.error.get));
			if (state_ != State.initializing)
				return;
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
				return recordStartupReplyFailure(new JsonRpcException(result.error.get));
			if (state_ != State.authenticating)
				return;
			// API-key auth may complete synchronously.
			auto resultJson = result.result.toJson();
			if (resultJson.canFind(`"success"`) || resultJson.canFind(`"loggedIn"`))
				onLoginCompleted();
		}, &failStartup).ignoreResult();
	}

	private void onTransportDisconnect(string reason, DisconnectType)
	{
		if (!readiness_.isOpen && readinessError_ is null)
			readinessError_ = new Exception("JSON-RPC connection closed: " ~ reason);
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
		if (readiness_.isOpen)
		{
			warningf("Codex startup reply failed after readiness: %s", error.msg);
			return;
		}
		readinessError_ = error;
		retire(Retirement.startupFailure);
	}

	private void onLoginCompleted()
	{
		if (state_ != State.initializing && state_ != State.authenticating)
			return;
		state_ = State.ready;
		readiness_.open();
	}

	private void fanout(int status)
	{
		final switch (retirement_)
		{
		case Retirement.transport:
			if (!readiness_.isOpen)
				status = 1;
			break;
		case Retirement.startupFailure:
		case Retirement.shutdown:
			status = 1;
			break;
		case Retirement.terminate:
			status = 143;
			break;
		}
		state_ = State.dead;
		releaseStartupGateOnce();
		readiness_.close(readinessError_ is null ? new Exception("Codex app-server exited") : readinessError_);
		auto routes = sessionsByTid;
		sessionsByTid = null;
		sessions = null;
		foreach (tid; routes.keys)
			if (tid < firstNonOperationRouteTid)
				enforce(operationRouteReservations_.remove(tid),
					"Exiting Codex operation route lost its reservation");
		foreach (session; routes)
			if (session.onServerExit !is null)
				session.onServerExit(status);
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
	server.codec = new AgentRpcCodec(connection, &server.onTransportDisconnect);
	if (startHandshake)
		server.sendInitialize();
	else
	{
		server.state_ = AppServerProcess.State.ready;
		server.readiness_.open();
	}
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

unittest
{
	import core.stdc.errno : errno, ESRCH;
	import core.sys.posix.signal : kill;
	import cydo.agent.process : rpcChildSurvivalProbe;
	import std.conv : to;
	import std.file : exists, remove, tempDir;
	import std.path : buildPath;
	import std.process : thisProcessID;
	import std.string : startsWith;

	auto marker = buildPath(tempDir, "cydo-codex-startup-eof-" ~ thisProcessID.to!string);
	scope (exit) if (exists(marker)) remove(marker);
	auto server = new AppServerProcess(["sh", "-c",
		`trap 'exit 42' TERM; read -r request; exec 1>&-;` ~ rpcChildSurvivalProbe,
		"test", marker]);
	string[] order;
	string[] errors;
	auto pid = 0;
	server.onShutdown_ = {
		pid = server.process.processId.processID;
		order ~= "evicted";
		assert(kill(pid, 0) == 0, "the child should still exist at eviction");
	};
	server.onReady({ assert(false, "startup reached readiness"); }, (Exception e) {
		order ~= "readiness failed";
		errors ~= e.msg;
	});
	server.startProcess({
		assert(kill(pid, 0) == -1 && errno == ESRCH, "released gate before child exit");
		order ~= "gate released";
	});
	socketManager.loop();

	assert(order == ["evicted", "gate released", "readiness failed"]);
	assert(errors.length == 1 && errors[0].startsWith("JSON-RPC connection closed: "));
	assert(!exists(marker));
}

unittest
{
	import cydo.agent.process : rpcChildSurvivalProbe;
	import std.conv : to;
	import std.file : exists, remove, tempDir;
	import std.path : buildPath;
	import std.process : environment, thisProcessID;

	auto codexKey = environment.get("CODEX_API_KEY", null);
	auto openAIKey = environment.get("OPENAI_API_KEY", null);
	environment.remove("CODEX_API_KEY");
	environment.remove("OPENAI_API_KEY");
	scope (exit)
	{
		if (codexKey !is null) environment["CODEX_API_KEY"] = codexKey;
		if (openAIKey !is null) environment["OPENAI_API_KEY"] = openAIKey;
	}

	auto marker = buildPath(tempDir, "cydo-codex-ready-eof-" ~ thisProcessID.to!string);
	scope (exit) if (exists(marker)) remove(marker);
	auto server = new AppServerProcess(["sh", "-c", q"SH
		trap 'exit 42' TERM
		read -r initialize
		printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
		read -r ready
		exec 1>&-
SH" ~ rpcChildSurvivalProbe, "test", marker]);
	int ready;
	int[] statuses;
	CodexSessionRouteTarget route;
	route.onServerExit = (int status) { statuses ~= status; };
	server.registerSessionByTid(1, route);
	server.onReady({
		++ready;
		server.sendRequest("test/ready", "{}").ignoreResult();
	}, (Exception e) { assert(false, e.msg); });
	server.startProcess({});
	socketManager.loop();

	assert(ready == 1 && statuses == [42]);
	assert(!exists(marker));
}
