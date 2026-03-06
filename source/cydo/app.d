module cydo.app;

import core.lifetime : move;

import std.datetime : Clock;
import std.file : exists, isFile;
import std.format : format;
import std.stdio : writefln;
import std.string : representation;

import ae.net.asockets : socketManager, DisconnectType;
import ae.net.http.common : HttpRequest, HttpStatusCode;
import ae.net.http.responseex : HttpResponseEx;
import ae.net.http.server : HttpServer, HttpServerConnection;
import ae.net.http.websocket : WebSocketAdapter, accept;
import ae.sys.data : Data;
import ae.sys.dataset : DataVec;

import cydo.agent.claude : ClaudeCodeSession;
import cydo.agent.process : AgentProcess;
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

		// Load persisted sessions (metadata only — history loaded on demand)
		foreach (row; persistence.loadSessions())
		{
			auto sd = SessionData(row.sid);
			sd.claudeSessionId = row.claudeSessionId;
			sd.title = row.title;
			sd.titleGenDone = row.title.length > 0;
			sessions[row.sid] = move(sd);
		}

		server = new HttpServer();
		server.handleRequest = &handleRequest;
		auto port = server.listen(3456);
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
		response.serveFile(path, "web/dist/");
		response.headers["Content-Security-Policy"] =
			"default-src 'self'; " ~
			"script-src 'self' 'wasm-unsafe-eval'; " ~
			"style-src 'self' 'unsafe-inline'; " ~
			"worker-src blob:; " ~
			"connect-src 'self' ws: wss:; " ~
			"img-src 'self' data:; " ~
			"object-src 'none'; " ~
			"base-uri 'self'; " ~
			"frame-ancestors 'none'";
		conn.sendResponse(response);
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

		// Send sessions list to new client (history loaded on demand)
		ws.send(Data(buildSessionsList().representation));

		ws.handleReadData = (Data data) {
			auto text = cast(string) data.toGC();
			handleWsMessage(ws, text);
		};

		ws.handleDisconnect = (string reason, DisconnectType type) {
			removeClient(ws);
		};
	}

	private void handleWsMessage(WebSocketAdapter ws, string text)
	{
		import ae.utils.json : jsonParse, toJson;

		auto json = jsonParse!WsMessage(text);

		if (json.type == "create_session")
		{
			auto sid = createSession();
			broadcast(toJson(SessionCreatedMessage("session_created", sid)));
		}
		else if (json.type == "request_history")
		{
			auto sid = json.sid;
			if (sid < 0 || sid !in sessions)
				return;
			auto sd = &sessions[sid];

			// Load JSONL from disk if not already loaded
			if (!sd.historyLoaded && sd.claudeSessionId.length > 0)
			{
				sd.history = loadSessionHistory(sid, sd.claudeSessionId);
				sd.historyLoaded = true;
			}

			// Send unified history to requesting client
			foreach (msg; sd.history)
				ws.send(msg);

			// Send end marker
			ws.send(Data(toJson(SessionHistoryEndMessage("session_history_end", sid)).representation));
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

			// Set initial title from first user message (truncated)
			if (sd.title.length == 0)
			{
				sd.title = truncateTitle(json.content, 80);
				persistence.setTitle(sid, sd.title);
				broadcastTitleUpdate(sid, sd.title);
				generateTitle(sid, json.content);
			}
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
			if (sid !in sessions)
				return;
			sessions[sid].alive = false;
			// Discard all history and reload from JSONL (canonical source).
			// Frontends are notified to discard their state and re-request.
			if (sessions[sid].claudeSessionId.length > 0)
			{
				sessions[sid].history = loadSessionHistory(sid, sessions[sid].claudeSessionId);
				sessions[sid].historyLoaded = true;
				broadcast(toJson(SessionReloadMessage("session_reload", sid)));
			}
			broadcast(buildSessionsList());
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

	private void broadcastTitleUpdate(int sid, string title)
	{
		import ae.utils.json : toJson;
		broadcast(toJson(TitleUpdateMessage("title_update", sid, title)));
	}

	/// Spawn a lightweight claude process to generate a concise title
	/// from the user's initial message.
	private void generateTitle(int sid, string userMessage)
	{
		auto sd = &sessions[sid];

		if (sd.titleGenDone || sd.titleGenProcess !is null)
			return;

		auto msg = userMessage.length > 500 ? userMessage[0 .. 500] : userMessage;

		sd.titleGenProcess = new AgentProcess([
			"claude",
			"-p",
			"Generate a concise title (max 8 words) for a coding session. " ~
			"Reply with ONLY the title, nothing else. No quotes, no period at the end. " ~
			"User's request: " ~ msg,
			"--output-format", "stream-json",
			"--model", "haiku",
			"--max-turns", "1",
			"--tools", "",
			"--no-session-persistence",
		], null, null, true); // noStdin

		string titleText;

		sd.titleGenProcess.onStdoutLine = (string line) {
			titleText ~= extractAssistantText(line);
		};

		sd.titleGenProcess.onExit = (int status) {
			if (sid !in sessions)
				return;
			sessions[sid].titleGenProcess = null;
			sessions[sid].titleGenDone = true;

			if (status != 0)
				return;

			import std.string : strip;
			auto title = titleText.strip();

			if (title.length > 0 && title.length < 200)
			{
				sessions[sid].title = title;
				persistence.setTitle(sid, title);
				broadcastTitleUpdate(sid, title);
			}
		};
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
			entries ~= SessionListEntry(sd.sid, sd.alive, sd.claudeSessionId.length > 0 && !sd.alive, sd.lastActivity, sd.title);
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
	DataVec history;          // unified: JSONL file events + live stdout events
	bool historyLoaded;       // whether JSONL has been loaded into history
	string claudeSessionId;
	bool alive = false;
	string lastActivity;
	string title;
	bool titleGenDone; // true after LLM title generation completed
	AgentProcess titleGenProcess; // prevent GC while running
}

struct SessionHistoryEndMessage
{
	string type = "session_history_end";
	int sid;
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
	string title;
}

struct SessionReloadMessage
{
	string type = "session_reload";
	int sid;
}

struct TitleUpdateMessage
{
	string type = "title_update";
	int sid;
	string title;
}

/// Truncate text to maxLen chars, collapsing whitespace and appending "…" if needed.
string truncateTitle(string text, size_t maxLen)
{
	import std.regex : ctRegex, replaceAll;

	auto cleaned = text.replaceAll(ctRegex!`\s+`, " ");
	if (cleaned.length <= maxLen)
		return cleaned;
	return cleaned[0 .. maxLen] ~ "…";
}

/// Extract text content from a stream-json assistant message line.
/// Returns the concatenated text blocks, or empty string if not an assistant message.
string extractAssistantText(string line)
{
	import ae.utils.json : jsonParse, JSONPartial;
	import std.algorithm : canFind;

	if (!line.canFind(`"type":"assistant"`))
		return "";

	// Parse just enough to get the text content
	@JSONPartial
	static struct ContentBlock
	{
		string type;
		string text;
	}

	@JSONPartial
	static struct Message
	{
		ContentBlock[] content;
	}

	@JSONPartial
	static struct AssistantProbe
	{
		string type;
		Message message;
	}

	try
	{
		auto probe = jsonParse!AssistantProbe(line);
		if (probe.type != "assistant")
			return "";

		string result;
		foreach (ref block; probe.message.content)
			if (block.type == "text")
				result ~= block.text;
		return result;
	}
	catch (Exception)
	{
		return "";
	}
}
