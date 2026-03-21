module cydo.agent.acp;

import std.conv : to;

import ae.utils.json : JSONFragment, JSONPartial, jsonParse;

import cydo.agent.process : AgentProcess;

// ---------------------------------------------------------------------------
// AcpSessionHandler — per-session event sink wired up by CopilotSession.
// ---------------------------------------------------------------------------

package interface AcpSessionHandler
{
	void handleNotification(string method, string rawLine);
	void handleServerRequest(string rawId, string method, string rawLine);
	void handleStderr(string line);
	void handleExit(int status);
}

// ---------------------------------------------------------------------------
// AcpProcess — manages a JSON-RPC 2.0 ACP subprocess.
// One instance per CopilotSession (model and MCP config are per-process).
// Structural mirror of AppServerProcess in codex.d.
// ---------------------------------------------------------------------------

class AcpProcess
{
	private AgentProcess process;
	private int nextRequestId = 1;

	enum State { starting, initializing, ready, failed, dead }
	private State state_ = State.starting;

	// Pending JSON-RPC response callbacks, keyed by request id.
	private void delegate(string result)[int] pendingCallbacks;

	// Session routing: sessionId → handler
	private AcpSessionHandler[string] sessions;

	// Actions queued until server reaches ready state.
	private void delegate()[] readyQueue;

	this(string[] args, string[string] env, string workDir)
	{
		process = new AgentProcess(args, env, workDir);

		process.onStdoutLine = (string line) {
			handleLine(line);
		};

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

	/// Send a JSON-RPC notification (no id, no response expected).
	void sendNotification(string method, string params)
	{
		process.writeLine(
			`{"jsonrpc":"2.0","method":"` ~ method ~ `","params":` ~ params ~ `}`);
	}

	/// Respond to a server-initiated request. rawId is the raw JSON value of
	/// the id field (may be int or string).
	void respondToRequest(string rawId, string result)
	{
		process.writeLine(
			`{"jsonrpc":"2.0","id":` ~ rawId ~ `,"result":` ~ result ~ `}`);
	}

	// ---- Initialization handshake ----

	private void sendInitialize()
	{
		state_ = State.initializing;
		sendRequest("initialize",
			`{"protocolVersion":1,"clientCapabilities":{},"clientInfo":{"name":"cydo","version":"0.1.0"}}`,
			(string result) {
				state_ = State.ready;
				auto queue = readyQueue;
				readyQueue = null;
				foreach (dg; queue)
					dg();
			});
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

		// Check for JSON-RPC error response
		@JSONPartial
		static struct ErrorCheck { JSONFragment error; }
		ErrorCheck ec;
		try ec = jsonParse!ErrorCheck(line);
		catch (Exception) {}
		if (ec.error.json !is null && ec.error.json.length > 0)
		{
			import std.stdio : stderr;
			stderr.writeln("[acp/error-response] id=" ~ to!string(id) ~ " error=" ~ ec.error.json);
		}

		auto callback = *cb;
		pendingCallbacks.remove(id);
		callback(data.result.json !is null ? data.result.json : "{}");
	}

	private void handleNotification(string method, string line)
	{
		// Route to session by sessionId in params.
		@JSONPartial
		static struct SessionProbe
		{
			@JSONPartial
			static struct Params
			{
				string sessionId;
			}
			Params params;
		}

		SessionProbe sp;
		try
			sp = jsonParse!SessionProbe(line);
		catch (Exception)
			return;

		if (auto session = sp.params.sessionId in sessions)
			(*session).handleNotification(method, line);
	}

	private void handleServerRequest(string rawId, string method, string line)
	{
		if (method == "session/request_permission")
		{
			// Auto-approve by selecting the first allow_once option.
			@JSONPartial
			static struct PermOption
			{
				string optionId;
				string kind;
			}

			@JSONPartial
			static struct PermProbe
			{
				@JSONPartial
				static struct Params
				{
					PermOption[] options;
				}
				Params params;
			}

			PermProbe pp;
			try
				pp = jsonParse!PermProbe(line);
			catch (Exception) {}

			string optionId = "";
			foreach (ref opt; pp.params.options)
			{
				if (opt.kind == "allow_once")
				{
					optionId = opt.optionId;
					break;
				}
			}

			if (optionId.length > 0)
				respondToRequest(rawId,
					`{"outcome":{"outcome":"selected","optionId":"` ~ acpEscape(optionId) ~ `"}}`);
			else
				respondToRequest(rawId, `{"outcome":{"outcome":"allow"}}`);
			return;
		}

		// Route terminal/* methods to the session handler.
		if (method.length > 9 && method[0 .. 9] == "terminal/")
		{
			@JSONPartial
			static struct SessionProbe
			{
				@JSONPartial
				static struct Params { string sessionId; }
				Params params;
			}

			SessionProbe sp;
			try
				sp = jsonParse!SessionProbe(line);
			catch (Exception) {}

			if (auto session = sp.params.sessionId in sessions)
			{
				(*session).handleServerRequest(rawId, method, line);
				return;
			}
		}

		// Unknown / unroutable — method-not-found.
		process.writeLine(
			`{"jsonrpc":"2.0","id":` ~ rawId
			~ `,"error":{"code":-32601,"message":"Method not supported"}}`);
	}
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

private:

string acpEscape(string s)
{
	import std.array : replace;
	return s
		.replace(`\`, `\\`)
		.replace(`"`, `\"`)
		.replace("\n", `\n`)
		.replace("\r", `\r`)
		.replace("\t", `\t`);
}
