module cydo.agent.drivers.codex.process;

import core.time : seconds;

import ae.net.jsonrpc.binding : JsonRpcDispatcher, jsonRpcDispatcher;
import ae.net.jsonrpc.codec : JsonRpcCodec;
import ae.utils.json : JSONFragment, jsonParse, toJson;
import ae.utils.jsonrpc : JsonRpcErrorCode, JsonRpcRequest, JsonRpcResponse;
import ae.utils.promise : Promise, resolve;

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
	private AgentProcess process;
	private JsonRpcCodec codec;
	private JsonRpcDispatcher!ICodexServer serverDispatcher;
	private bool terminating_;

	enum State { starting, initializing, authenticating, ready, failed, dead }
	private State state_ = State.starting;

	// Thread routing: threadId → session (populated after thread/start response)
	private CodexSessionRouteTarget[string] sessions;
	// Task ID → session (populated at session creation, before thread/start)
	private CodexSessionRouteTarget[int] sessionsByTid;

	// Actions queued until server reaches ready state.
	private void delegate()[] readyQueue;

	this(string[] args)
	{
		// Environment and current directory are handled by bwrap (included in args).
		process = new AgentProcess(args, logName: "codex");

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
		sessions[threadId] = session;
	}

	void unregisterSession(string threadId)
	{
		sessions.remove(threadId);
		if (sessions.length == 0 && sessionsByTid.length == 0)
			shutdown();
	}

	void registerSessionByTid(int tid, CodexSessionRouteTarget session)
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
		// Use killAfterTimeout(0) — SIGTERM already sent above, so the
		// first timer fires immediately (re-sends SIGTERM, harmless), then
		// SIGKILL + force-close pipes after 2s.
		process.killAfterTimeout(0.seconds);
	}

	@property bool dead() { return process.dead; }

	/// Callback invoked when this server shuts down, for pool cleanup.
	package void delegate() onShutdown_;

	/// Terminate the server immediately and notify remaining sessions.
	/// Nulls onExit to prevent double-firing from the async process exit.
	void shutdown()
	{
		if (state_ == State.dead) return;
		process.onExit = null;
		process.closeStdin();
		process.terminate();
		process.killAfterTimeout(0.seconds);
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
		sendRequest("initialize", toJson(InitializeParams(
			InitializeParams.ClientInfo("cydo", "0.1.0"),
			JSONFragment(`{"experimentalApi":true}`)
		))).then((JsonRpcResponse result) {
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
}
