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
	private AgentSession session;
	private WebSocketAdapter[] clients;
	private string[] messageHistory;

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

		// Replay message history to new client
		foreach (msg; messageHistory)
			ws.send(Data(msg.representation));

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

		// Parse incoming WebSocket message
		auto json = jsonParse!WsMessage(text);

		if (json.type == "message")
		{
			ensureSession();
			session.sendMessage(json.content);
		}
		else if (json.type == "interrupt")
		{
			if (session)
				session.interrupt();
		}
	}

	private void ensureSession()
	{
		if (session && session.alive)
			return;

		session = new ClaudeCodeSession();

		session.onOutput = (string line) {
			broadcast(line);
		};

		session.onStderr = (string line) {
			import ae.utils.json : toJson;
			broadcast(toJson(StderrMessage("stderr", line)));
		};

		session.onExit = (int status) {
			import ae.utils.json : toJson;
			broadcast(toJson(ExitMessage("exit", status)));
			session = null;
		};
	}

	private void broadcast(string message)
	{
		messageHistory ~= message;
		auto data = Data(message.representation);
		foreach (ws; clients)
			ws.send(data);
	}

	private void removeClient(WebSocketAdapter ws)
	{
		import std.algorithm : remove;
		clients = clients.remove!(c => c is ws);
	}
}

private:

struct WsMessage
{
	string type;
	string content;
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
