module cydo.app;

import core.lifetime : move;

import std.datetime : Clock;
import std.file : exists, isFile;
import std.format : format;
import std.string : startsWith, representation;

import ae.net.asockets : socketManager, DisconnectType;
import ae.net.http.common : HttpRequest, HttpStatusCode;
import ae.net.http.responseex : HttpResponseEx;
import ae.net.http.server : HttpServer, HttpServerConnection;
import ae.net.http.websocket : WebSocketAdapter, accept;
import ae.sys.data : Data;
import ae.sys.dataset : DataVec;

import cydo.agent.claude : ClaudeCodeSession;
import cydo.agent.session : AgentSession;
import cydo.persist : Persistence, loadSessionHistory;

void main()
{
	auto app = new App();
	app.start();
	socketManager.loop();
}

class App
{
	private HttpServer server;
	private WebSocketAdapter[] clients;
	private SessionData[int] sessions;
	private Persistence persistence;

	void start()
	{
		persistence = Persistence("data/cydo.db");

		// Load persisted sessions
		foreach (row; persistence.loadSessions())
		{
			auto sd = SessionData(row.sid);
			sd.claudeSessionId = row.claudeSessionId;
			if (row.claudeSessionId.length > 0)
				sd.history = loadSessionHistory(row.sid, row.claudeSessionId);
			sessions[row.sid] = move(sd);
		}

		server = new HttpServer();
		server.handleRequest = &handleRequest;
		auto port = server.listen(3456);
		import std.stdio : writefln;
		writefln("CyDo server listening on http://localhost:%d", port);
	}

	private void handleRequest(HttpRequest request, HttpServerConnection conn)
	{
		if (request.resource == "/ws")
		{
			handleWebSocket(request, conn);
			return;
		}

		// Serve static files from web/dist/, with SPA fallback
		auto response = new HttpResponseEx();
		auto path = request.resource[1 .. $]; // strip leading /
		if (path == "" || !exists("web/dist/" ~ path) || !isFile("web/dist/" ~ path))
			path = "index.html";
		conn.sendResponse(response.serveFile(path, "web/dist/"));
	}

	private void handleWebSocket(HttpRequest request, HttpServerConnection conn)
	{
		WebSocketAdapter ws;
		try
			ws = accept(request, conn);
		catch (Exception e)
		{
			auto response = new HttpResponseEx();
			response.setStatus(HttpStatusCode.BadRequest);
			conn.sendResponse(response.serveData("Bad WebSocket request"));
			return;
		}

		ws.sendBinary = false; // text frames for JSON
		clients ~= ws;

		// Send sessions list to new client
		ws.send(Data(buildSessionsList().representation));

		// Replay each session's history (already wrapped with sid envelope)
		foreach (ref sd; sessions)
			foreach (msg; sd.history)
				ws.send(msg);

		ws.handleReadData = (Data data) {
			auto text = cast(string) data.toGC();
			handleWsMessage(text);
		};

		ws.handleDisconnect = (string reason, DisconnectType type) {
			removeClient(ws);
		};
	}

	private void handleWsMessage(string text)
	{
		import ae.utils.json : jsonParse, toJson;

		auto json = jsonParse!WsMessage(text);

		if (json.type == "create_session")
		{
			auto sid = createSession();
			broadcast(toJson(SessionCreatedMessage("session_created", sid)));
		}
		else if (json.type == "message")
		{
			auto sid = json.sid;
			if (sid < 0 || sid !in sessions)
				return;
			auto sd = &sessions[sid];
			// Only auto-spawn for new sessions (no claudeSessionId yet).
			// Resumable sessions require an explicit "resume" first.
			if (sd.agent is null || !sd.agent.alive)
			{
				if (sd.claudeSessionId.length > 0)
					return; // resumable but not resumed — ignore
				ensureSessionAgent(sid);
			}
			sd.agent.sendMessage(json.content);
		}
		else if (json.type == "resume")
		{
			auto sid = json.sid;
			if (sid < 0 || sid !in sessions)
				return;
			auto sd = &sessions[sid];
			// Only resume if we have a Claude session ID and no running process
			if (sd.claudeSessionId.length == 0)
				return;
			if (sd.agent !is null && sd.agent.alive)
				return;
			ensureSessionAgent(sid);
			broadcast(buildSessionsList());
		}
		else if (json.type == "interrupt")
		{
			auto sid = json.sid;
			if (sid < 0 || sid !in sessions)
				return;
			auto sd = &sessions[sid];
			if (sd.agent)
				sd.agent.interrupt();
		}
	}

	private int createSession()
	{
		auto sid = persistence.createSession();
		sessions[sid] = SessionData(sid);
		return sid;
	}

	private void ensureSessionAgent(int sid)
	{
		auto sd = &sessions[sid];
		if (sd.agent && sd.agent.alive)
			return;

		sd.agent = new ClaudeCodeSession(sd.claudeSessionId);

		sd.agent.onOutput = (string line) {
			broadcastSession(sid, line);
		};

		sd.agent.onStderr = (string line) {
			import ae.utils.json : toJson;
			broadcastSession(sid, toJson(StderrMessage("stderr", line)));
		};

		sd.agent.onExit = (int status) {
			import ae.utils.json : toJson;
			broadcastSession(sid, toJson(ExitMessage("exit", status)));
			if (sid in sessions)
				sessions[sid].alive = false;
		};

		sd.alive = true;
	}

	private void broadcastSession(int sid, string rawLine)
	{
		// Wrap the event with a session envelope including timestamp
		auto now = Clock.currTime.toISOExtString();
		string injected = `{"sid":` ~ format!"%d"(sid) ~ `,"timestamp":"` ~ now ~ `","event":` ~ rawLine ~ `}`;

		auto data = Data(injected.representation);

		if (sid in sessions)
		{
			sessions[sid].lastActivity = now;
			sessions[sid].history ~= data;

			// Extract Claude session ID from system.init messages
			if (sessions[sid].claudeSessionId.length == 0)
				tryExtractClaudeSessionId(sid, rawLine);
		}

		foreach (ws; clients)
			ws.send(data);
	}

	/// Parse system.init messages to extract the Claude session UUID.
	private void tryExtractClaudeSessionId(int sid, string rawLine)
	{
		import ae.utils.json : jsonParse, JSONPartial;
		import std.algorithm : canFind;

		// Quick string check before parsing
		if (!rawLine.canFind(`"subtype":"init"`))
			return;

		@JSONPartial
		static struct InitProbe
		{
			string type;
			string subtype;
			string session_id;
		}

		try
		{
			auto probe = jsonParse!InitProbe(rawLine);
			if (probe.type == "system" && probe.subtype == "init" && probe.session_id.length > 0)
			{
				sessions[sid].claudeSessionId = probe.session_id;
				persistence.setClaudeSessionId(sid, probe.session_id);
			}
		}
		catch (Exception)
		{
			// Not a valid init message, ignore
		}
	}

	private void broadcast(string message)
	{
		auto data = Data(message.representation);
		foreach (ws; clients)
			ws.send(data);
	}

	private string buildSessionsList()
	{
		import ae.utils.json : toJson;

		SessionListEntry[] entries;
		foreach (ref sd; sessions)
			entries ~= SessionListEntry(sd.sid, sd.alive, sd.claudeSessionId.length > 0 && !sd.alive, sd.lastActivity);
		return toJson(SessionsListMessage("sessions_list", entries));
	}

	private void removeClient(WebSocketAdapter ws)
	{
		import std.algorithm : remove;
		clients = clients.remove!(c => c is ws);
	}
}

private:

struct SessionData
{
	int sid;
	AgentSession agent;
	DataVec history;
	string claudeSessionId;
	bool alive = false;
	string lastActivity;
}

struct WsMessage
{
	string type;
	string content;
	int sid = -1;
}

struct ExitMessage
{
	string type;
	int code;
}

struct StderrMessage
{
	string type;
	string text;
}

struct SessionCreatedMessage
{
	string type;
	int sid;
}

struct SessionsListMessage
{
	string type;
	SessionListEntry[] sessions;
}

struct SessionListEntry
{
	int sid;
	bool alive;
	bool resumable;
	string lastActivity;
}
