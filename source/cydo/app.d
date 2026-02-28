module cydo.app;

import std.format : format;
import std.string : startsWith, representation;

import ae.net.asockets : socketManager, DisconnectType;
import ae.net.http.common : HttpRequest, HttpStatusCode;
import ae.net.http.responseex : HttpResponseEx;
import ae.net.http.server : HttpServer, HttpServerConnection;
import ae.net.http.websocket : WebSocketAdapter, accept;
import ae.sys.data : Data;

import cydo.agent.claude : ClaudeCodeSession;
import cydo.agent.session : AgentSession;

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
	private int nextSid = 1;

	void start()
	{
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

		// Serve static files from web/dist/
		auto response = new HttpResponseEx();
		auto path = request.resource[1 .. $]; // strip leading /
		if (path == "")
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
		sendTo(ws, buildSessionsList());

		// Replay each session's history (already has sid injected)
		foreach (ref sd; sessions)
			foreach (msg; sd.history)
				sendTo(ws, msg);

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
			ensureSessionAgent(sid);
			sessions[sid].agent.sendMessage(json.content);
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
		auto sid = nextSid++;
		sessions[sid] = SessionData(sid);
		return sid;
	}

	private void ensureSessionAgent(int sid)
	{
		auto sd = &sessions[sid];
		if (sd.agent && sd.agent.alive)
			return;

		sd.agent = new ClaudeCodeSession();

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
		// Inject "sid":N, at the start of the JSON object
		string injected;
		if (rawLine.length > 0 && rawLine[0] == '{')
			injected = `{"sid":` ~ format!"%d"(sid) ~ `,` ~ rawLine[1 .. $];
		else
			injected = rawLine; // non-JSON line, pass through as-is

		if (sid in sessions)
			sessions[sid].history ~= injected;

		auto data = Data(injected.representation);
		foreach (ws; clients)
			ws.send(data);
	}

	private void broadcast(string message)
	{
		auto data = Data(message.representation);
		foreach (ws; clients)
			ws.send(data);
	}

	private void sendTo(WebSocketAdapter ws, string msg)
	{
		ws.send(Data(msg.representation));
	}

	private string buildSessionsList()
	{
		import ae.utils.json : toJson;

		SessionListEntry[] entries;
		foreach (ref sd; sessions)
			entries ~= SessionListEntry(sd.sid, sd.alive);
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
	string[] history;
	bool alive = false;
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
}
