module cydo.app;

import core.lifetime : move;

import std.datetime : Clock;
import std.file : exists, isFile;
import std.format : format;
import std.stdio : File, writefln;
import std.string : representation;

import ae.net.asockets : socketManager, DisconnectType;
import ae.net.http.common : HttpRequest, HttpStatusCode;
import ae.net.http.responseex : HttpResponseEx;
import ae.net.http.server : HttpServer, HttpServerConnection;
import ae.net.http.websocket : WebSocketAdapter, accept;
import ae.sys.data : Data;
import ae.sys.dataset : DataVec;

import cydo.agent.agent : Agent;
import cydo.agent.claude : ClaudeCodeAgent;
import cydo.agent.process : AgentProcess;
import cydo.agent.session : AgentSession;
import cydo.config : CydoConfig, SandboxConfig, WorkspaceConfig, loadConfig;
import cydo.discover : DiscoveredProject, discoverProjects;
import cydo.persist : ForkResult, Persistence, claudeJsonlPath, extractForkableUuids,
	forkSession, loadSessionHistory;
import cydo.sandbox : ResolvedSandbox, buildBwrapArgs, cleanup, resolveSandbox;

void main()
{
	auto app = new App();
	app.start();
	socketManager.loop();
}

class App
{
	import ae.sys.inotify : INotify, iNotify;

	private HttpServer server;
	private WebSocketAdapter[] clients;
	private SessionData[int] sessions;
	private Persistence persistence;
	private CydoConfig config;
	private WorkspaceInfo[] workspacesInfo;
	private Agent agent;
	// inotify watches for JSONL file tracking (sid → watch descriptor)
	private INotify.WatchDescriptor[int] jsonlFileWatches;
	private INotify.WatchDescriptor[int] jsonlDirWatches;
	private size_t[int] jsonlReadPos;

	void start()
	{
		persistence = Persistence("data/cydo.db");
		config = loadConfig();
		agent = new ClaudeCodeAgent();

		// Discover projects in all workspaces
		foreach (ref ws; config.workspaces)
		{
			auto projects = discoverProjects(ws);
			ProjectInfo[] projInfos;
			foreach (ref p; projects)
				projInfos ~= ProjectInfo(p.name, p.path);
			workspacesInfo ~= WorkspaceInfo(ws.name, projInfos);

			writefln("Workspace '%s' (%s): %d project(s)", ws.name, ws.root, projects.length);
			foreach (ref p; projects)
				writefln("  - %s (%s)", p.name, p.path);
		}

		// Load persisted sessions (metadata only — history loaded on demand)
		foreach (row; persistence.loadSessions())
		{
			auto sd = SessionData(row.sid);
			sd.claudeSessionId = row.claudeSessionId;
			sd.title = row.title;
			sd.titleGenDone = row.title.length > 0;
			sd.workspace = row.workspace;
			sd.projectPath = row.projectPath;
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

		// Send workspaces list and sessions list to new client
		ws.send(Data(buildWorkspacesList().representation));
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
			auto sid = createSession(json.workspace, json.project_path);
			broadcast(toJson(SessionCreatedMessage("session_created", sid, json.workspace, json.project_path)));
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
				sd.history = loadSessionHistory(sid, sd.claudeSessionId, sd.projectPath);
				sd.historyLoaded = true;
			}

			// Send unified history to requesting client
			foreach (msg; sd.history)
				ws.send(msg);

			// Send forkable UUIDs extracted from JSONL
			if (sd.claudeSessionId.length > 0)
				sendForkableUuidsFromFile(ws, sid, sd.claudeSessionId, sd.projectPath);

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
			if (sd.session is null || !sd.session.alive)
			{
				if (sd.claudeSessionId.length > 0)
					return; // resumable but not resumed — ignore
				ensureSessionAgent(sid);
			}
			sd.session.sendMessage(json.content);

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
			if (sd.session !is null && sd.session.alive)
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
			if (sd.session)
				sd.session.interrupt();
		}
		else if (json.type == "fork_session")
		{
			auto sid = json.sid;
			if (sid < 0 || sid !in sessions)
				return;
			auto sd = &sessions[sid];
			if (sd.claudeSessionId.length == 0)
			{
				ws.send(Data(toJson(ErrorMessage("error", "Session has no Claude session ID", sid)).representation));
				return;
			}

			auto result = forkSession(persistence, sd.claudeSessionId, json.after_uuid,
				sd.projectPath, sd.workspace, sd.title);
			if (result.sid < 0)
			{
				ws.send(Data(toJson(ErrorMessage("error",
					"Fork failed: message UUID not found in session history", sid)).representation));
				return;
			}

			auto newSd = SessionData(result.sid);
			newSd.workspace = sd.workspace;
			newSd.projectPath = sd.projectPath;
			newSd.title = sd.title.length > 0 ? sd.title ~ " (fork)" : "";
			newSd.claudeSessionId = result.claudeSessionId;
			sessions[result.sid] = move(newSd);

			import ae.utils.json : toJson;
			broadcast(toJson(SessionCreatedMessage("session_created", result.sid, sd.workspace, sd.projectPath)));
			broadcast(buildSessionsList());
		}
	}

	private int createSession(string workspace = "", string projectPath = "")
	{
		auto sid = persistence.createSession(workspace, projectPath);
		auto sd = SessionData(sid);
		sd.workspace = workspace;
		sd.projectPath = projectPath;
		sessions[sid] = move(sd);
		return sid;
	}

	private void ensureSessionAgent(int sid)
	{
		auto sd = &sessions[sid];
		if (sd.session && sd.session.alive)
			return;

		auto workDir = sd.projectPath.length > 0 ? sd.projectPath : null;

		// Resolve sandbox config: agent defaults + global + per-workspace
		auto wsSandbox = findWorkspaceSandbox(sd.workspace);
		sd.sandbox = resolveSandbox(config.sandbox, wsSandbox, agent, workDir);
		auto bwrapPrefix = buildBwrapArgs(sd.sandbox, workDir);

		sd.session = agent.createSession(sd.claudeSessionId, bwrapPrefix);

		// Start watching the JSONL file for forkable UUIDs.
		// For resumed sessions claudeSessionId is already set; for new sessions
		// it will be set later in tryExtractClaudeSessionId which also calls this.
		if (sd.claudeSessionId.length > 0)
			startJsonlWatch(sid);

		sd.session.onOutput = (string line) {
			broadcastSession(sid, line);
		};

		sd.session.onStderr = (string line) {
			import ae.utils.json : toJson;
			broadcastSession(sid, toJson(StderrMessage("stderr", line)));
		};

		sd.session.onExit = (int status) {
			import ae.utils.json : toJson;
			broadcastSession(sid, toJson(ExitMessage("exit", status)));
			if (sid !in sessions)
				return;
			sessions[sid].alive = false;
			cleanup(sessions[sid].sandbox);
			stopJsonlWatch(sid);
			// Discard all history and reload from JSONL (canonical source).
			// Frontends are notified to discard their state and re-request.
			if (sessions[sid].claudeSessionId.length > 0)
			{
				sessions[sid].history = loadSessionHistory(sid, sessions[sid].claudeSessionId, sessions[sid].projectPath);
				sessions[sid].historyLoaded = true;
				broadcast(toJson(SessionReloadMessage("session_reload", sid)));
			}
			broadcast(buildSessionsList());
		};

		sd.alive = true;
	}

	private SandboxConfig findWorkspaceSandbox(string workspaceName)
	{
		foreach (ref ws; config.workspaces)
			if (ws.name == workspaceName)
				return ws.sandbox;
		return SandboxConfig.init;
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
				startJsonlWatch(sid);
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

	/// Start watching the JSONL file (or directory if file doesn't exist yet).
	private void startJsonlWatch(int sid)
	{
		import std.file : exists;
		import std.path : baseName, dirName;

		if (sid !in sessions)
			return;
		if (sid in jsonlFileWatches || sid in jsonlDirWatches)
			return; // already watching
		auto sd = &sessions[sid];
		if (sd.claudeSessionId.length == 0)
			return;

		auto jsonlPath = claudeJsonlPath(sd.claudeSessionId, sd.projectPath);

		if (exists(jsonlPath))
		{
			watchJsonlFile(sid, jsonlPath);
		}
		else
		{
			// File doesn't exist yet — watch directory for its creation
			auto dirPath = dirName(jsonlPath);
			auto fileName = baseName(jsonlPath);
			jsonlDirWatches[sid] = iNotify.add(dirPath, INotify.Mask.create,
				(in char[] name, INotify.Mask mask, uint cookie)
				{
					if (name == fileName)
					{
						// File appeared — switch to file watch
						if (auto p = sid in jsonlDirWatches)
						{
							iNotify.remove(*p);
							jsonlDirWatches.remove(sid);
						}
						watchJsonlFile(sid, jsonlPath);
					}
				}
			);
		}
	}

	/// Start watching a JSONL file for modifications.
	private void watchJsonlFile(int sid, string jsonlPath)
	{
		// Read any existing content
		processNewJsonlContent(sid, jsonlPath);

		jsonlFileWatches[sid] = iNotify.add(jsonlPath, INotify.Mask.modify,
			(in char[] name, INotify.Mask mask, uint cookie)
			{
				processNewJsonlContent(sid, jsonlPath);
			}
		);
	}

	/// Read new content from the JSONL file and broadcast forkable UUIDs.
	private void processNewJsonlContent(int sid, string jsonlPath)
	{
		import std.file : getSize;

		auto fileSize = getSize(jsonlPath);
		auto lastPos = jsonlReadPos.get(sid, 0);
		if (fileSize <= lastPos)
			return;

		// Read only the new portion
		auto f = File(jsonlPath, "r");
		f.seek(lastPos);
		char[] buf;
		buf.length = cast(size_t)(fileSize - lastPos);
		auto got = f.rawRead(buf);
		jsonlReadPos[sid] = cast(size_t) fileSize;

		auto newContent = cast(string) got;
		auto uuids = extractForkableUuids(newContent);
		if (uuids.length > 0)
			broadcastForkableUuids(sid, uuids);
	}

	/// Send forkable UUIDs from the full JSONL file (used during history load).
	private void sendForkableUuidsFromFile(WebSocketAdapter ws, int sid,
		string claudeSessionId, string projectPath)
	{
		import std.file : exists, readText;

		auto jsonlPath = claudeJsonlPath(claudeSessionId, projectPath);
		if (!exists(jsonlPath))
			return;

		auto content = readText(jsonlPath);
		auto uuids = extractForkableUuids(content);
		if (uuids.length > 0)
		{
			import ae.utils.json : toJson;
			ws.send(Data(toJson(ForkableUuidsMessage("forkable_uuids", sid, uuids)).representation));
		}
	}

	/// Broadcast forkable UUIDs to all clients.
	private void broadcastForkableUuids(int sid, string[] uuids)
	{
		import ae.utils.json : toJson;
		broadcast(toJson(ForkableUuidsMessage("forkable_uuids", sid, uuids)));
	}

	/// Stop watching the JSONL file for a session.
	private void stopJsonlWatch(int sid)
	{
		if (auto p = sid in jsonlFileWatches)
		{
			iNotify.remove(*p);
			jsonlFileWatches.remove(sid);
		}
		if (auto p = sid in jsonlDirWatches)
		{
			iNotify.remove(*p);
			jsonlDirWatches.remove(sid);
		}
		jsonlReadPos.remove(sid);
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
			entries ~= SessionListEntry(sd.sid, sd.alive, sd.claudeSessionId.length > 0 && !sd.alive,
				sd.lastActivity, sd.title, sd.workspace, sd.projectPath);
		return toJson(SessionsListMessage("sessions_list", entries));
	}

	private string buildWorkspacesList()
	{
		import ae.utils.json : toJson;
		return toJson(WorkspacesListMessage("workspaces_list", workspacesInfo));
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
	AgentSession session;
	ResolvedSandbox sandbox;
	DataVec history;          // unified: JSONL file events + live stdout events
	bool historyLoaded;       // whether JSONL has been loaded into history
	string claudeSessionId;
	bool alive = false;
	string lastActivity;
	string title;
	bool titleGenDone; // true after LLM title generation completed
	AgentProcess titleGenProcess; // prevent GC while running
	string workspace;
	string projectPath;
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
	string workspace;
	string project_path;
	string after_uuid;
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
	string workspace;
	string project_path;
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
	string workspace;
	string project_path;
}

struct ProjectInfo
{
	string name;      // relative path within workspace
	string path;      // absolute path
}

struct WorkspaceInfo
{
	string name;
	ProjectInfo[] projects;
}

struct WorkspacesListMessage
{
	string type = "workspaces_list";
	WorkspaceInfo[] workspaces;
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

struct ForkableUuidsMessage
{
	string type = "forkable_uuids";
	int sid;
	string[] uuids;
}

struct ErrorMessage
{
	string type = "error";
	string message;
	int sid = -1;
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
