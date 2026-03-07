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
import ae.utils.json : JSONFragment;
import ae.utils.promise : Promise, resolve;

import cydo.mcp : McpResult;

import cydo.agent.agent : Agent, SessionConfig;
import cydo.agent.claude : ClaudeCodeAgent;
import cydo.agent.process : AgentProcess;
import cydo.agent.session : AgentSession;
import cydo.config : CydoConfig, SandboxConfig, WorkspaceConfig, loadConfig;
import cydo.discover : DiscoveredProject, discoverProjects;
import cydo.persist : ForkResult, Persistence, claudeJsonlPath, extractForkableUuids,
	forkTask, loadTaskHistory;
import cydo.sandbox : ResolvedSandbox, buildBwrapArgs, cleanup, resolveSandbox;
import cydo.tasktype : TaskTypeDef, loadTaskTypes, validateTaskTypes, modelClassToAlias, renderPrompt,
	formatCreatableTaskTypes;

void main(string[] args)
{
	import std.algorithm : canFind;
	if (args.canFind("--mcp-server"))
	{
		import cydo.mcp.server : runMcpServer;
		runMcpServer();
		return;
	}
	if (args.canFind("--simulate"))
	{
		import cydo.tasktype : runSimulator;
		runSimulator(args);
		return;
	}

	auto app = new App();
	app.start();
	socketManager.loop();
}

class App
{
	import ae.sys.inotify : INotify, iNotify;

	private HttpServer server;
	private WebSocketAdapter[] clients;
	private TaskData[int] tasks;
	private Persistence persistence;
	private CydoConfig config;
	private WorkspaceInfo[] workspacesInfo;
	private Agent agent;
	// Task type definitions loaded from YAML
	private TaskTypeDef[string] taskTypes;
	private string taskTypesDir;
	// Pending sub-task promises (childTid → promise fulfilled on task exit)
	private Promise!(McpResult)[int] pendingSubTasks;
	// inotify watches for JSONL file tracking (tid → watch descriptor)
	private INotify.WatchDescriptor[int] jsonlFileWatches;
	private INotify.WatchDescriptor[int] jsonlDirWatches;
	private size_t[int] jsonlReadPos;

	void start()
	{
		persistence = Persistence("data/cydo.db");
		config = loadConfig();
		agent = new ClaudeCodeAgent();

		// Load task type definitions
		try
		{
			import std.path : dirName;
			enum typesPath = "docs/task-types/types.yaml";
			taskTypes = loadTaskTypes(typesPath);
			taskTypesDir = dirName(typesPath);
			auto errors = validateTaskTypes(taskTypes);
			foreach (e; errors)
				writefln("  WARN: task type: %s", e);
			writefln("Loaded %d task types", taskTypes.length);
		}
		catch (Exception e)
			writefln("Warning: could not load task types: %s", e.msg);

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

		// Load persisted tasks (metadata only — history loaded on demand)
		foreach (row; persistence.loadTasks())
		{
			auto td = TaskData(row.tid);
			td.claudeSessionId = row.claudeSessionId;
			td.description = row.description;
			td.taskType = row.taskType;
			td.parentTid = row.parentTid;
			td.relationType = row.relationType;
			td.workspace = row.workspace;
			td.projectPath = row.projectPath;
			td.title = row.title;
			td.status = row.status;
			td.titleGenDone = row.title.length > 0;
			tasks[row.tid] = move(td);
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

		if (request.resource == "/mcp/call" && request.method == "POST")
		{
			handleMcpCall(request, conn);
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

		// Send workspaces list and tasks list to new client
		ws.send(Data(buildWorkspacesList().representation));
		ws.send(Data(buildTasksList().representation));

		ws.handleReadData = (Data data) {
			auto text = cast(string) data.toGC();
			handleWsMessage(ws, text);
		};

		ws.handleDisconnect = (string reason, DisconnectType type) {
			removeClient(ws);
		};
	}

	private void handleMcpCall(HttpRequest request, HttpServerConnection conn)
	{
		import ae.sys.dataset : joinData;
		import ae.utils.json : jsonParse, toJson, JSONPartial;

		auto response = new HttpResponseEx();
		response.headers["Content-Type"] = "application/json";

		@JSONPartial
		static struct McpCallRequest
		{
			string tid;
			string tool;
			JSONFragment args;
		}

		McpCallRequest call;
		try
		{
			auto bodyText = cast(string) request.data[].joinData().toGC();
			call = jsonParse!McpCallRequest(bodyText);
		}
		catch (Exception e)
		{
			conn.sendResponse(response.serveData(
				`{"content":[{"type":"text","text":"Invalid request"}],"isError":true}`));
			return;
		}

		// Unified async dispatch — all tools return Promise!McpResult
		dispatchTool(call.tool, call.tid, call.args).then((McpResult result) {
			auto resultJson = toJson(McpContentResult(
				[McpContentItem("text", result.text)],
				result.isError,
			));
			conn.sendResponse(response.serveData(resultJson));
		});
	}

	/// Dispatch an MCP tool call. Returns a promise that resolves when the
	/// tool completes — immediately for sync tools, later for async tools.
	private Promise!McpResult dispatchTool(string tool, string tid, JSONFragment args)
	{
		if (tool == "CreateTask")
			return handleCreateTask(tid, args);

		// Sync dispatch for other tools
		import cydo.mcp.binding : mcpToolDispatcher;
		import cydo.mcp.tools : CydoTools, CydoToolsImpl;

		auto impl = new CydoToolsImpl();
		auto dispatcher = mcpToolDispatcher!CydoTools(impl);
		return resolve(dispatcher.dispatch(tool, args));
	}

	/// Handle CreateTask — returns a promise that resolves when the child task completes.
	private Promise!McpResult handleCreateTask(string callerTid, JSONFragment rawArgs)
	{
		import ae.utils.json : jsonParse, toJson, JSONPartial;
		import std.algorithm : canFind;
		import std.array : join;
		import std.conv : to;

		@JSONPartial
		static struct CreateTaskArgs
		{
			string task_type;
			string description;
		}

		CreateTaskArgs args;
		try
			args = jsonParse!CreateTaskArgs(rawArgs.json);
		catch (Exception e)
			return resolve(McpResult("Invalid CreateTask arguments: " ~ e.msg, true));

		// Look up calling task
		int parentTid;
		try
			parentTid = to!int(callerTid);
		catch (Exception)
			return resolve(McpResult("Invalid calling task ID", true));

		auto parentTd = parentTid in tasks;
		if (parentTd is null)
			return resolve(McpResult("Calling task not found", true));

		// Validate task_type against parent's creatable_tasks
		auto parentTypeDef = parentTd.taskType in taskTypes;
		if (parentTypeDef !is null &&
			parentTypeDef.creatable_tasks.length > 0 &&
			!parentTypeDef.creatable_tasks.canFind(args.task_type))
		{
			return resolve(McpResult(
				"Task type '" ~ args.task_type ~ "' is not in creatable_tasks for '" ~
				parentTd.taskType ~ "'. Allowed: " ~
				parentTypeDef.creatable_tasks.join(", "), true));
		}

		// Validate child task type exists
		auto childTypeDef = args.task_type in taskTypes;
		if (childTypeDef is null)
			return resolve(McpResult("Unknown task type: " ~ args.task_type, true));

		// Create child task
		auto childTid = createTask(parentTd.workspace, parentTd.projectPath);
		auto childTd = &tasks[childTid];
		childTd.taskType = args.task_type;
		childTd.description = args.description;
		childTd.parentTid = parentTid;
		childTd.relationType = "subtask";
		childTd.title = truncateTitle(args.description, 80);

		// Persist metadata
		persistence.setTaskType(childTid, args.task_type);
		persistence.setDescription(childTid, args.description);
		persistence.setParentTid(childTid, parentTid);
		persistence.setRelationType(childTid, "subtask");
		persistence.setTitle(childTid, childTd.title);

		// Create promise — fulfilled when child task exits
		auto promise = new Promise!McpResult;
		pendingSubTasks[childTid] = promise;

		// Broadcast to UI
		broadcast(toJson(TaskCreatedMessage("task_created", childTid,
			parentTd.workspace, parentTd.projectPath, parentTid, "subtask")));
		broadcast(buildTasksList());

		// Configure and spawn child agent
		auto sessionConfig = SessionConfig(
			modelClassToAlias(childTypeDef.model_class),
		);
		ensureTaskAgent(childTid, sessionConfig);

		// Send rendered prompt template as first user message
		if (childTd.session !is null)
		{
			auto prompt = renderPrompt(*childTypeDef, args.description, taskTypesDir);
			childTd.session.sendMessage(prompt);
			broadcastUnconfirmedUserMessage(childTid, prompt);
		}

		generateTitle(childTid, args.description);
		writefln("CreateTask: tid=%d type=%s parent=%d", childTid, args.task_type, parentTid);

		return promise;
	}

	private void handleWsMessage(WebSocketAdapter ws, string text)
	{
		import ae.utils.json : jsonParse, toJson;

		auto json = jsonParse!WsMessage(text);

		if (json.type == "create_task")
		{
			auto tid = createTask(json.workspace, json.project_path);
			broadcast(toJson(TaskCreatedMessage("task_created", tid, json.workspace, json.project_path, 0, "")));
		}
		else if (json.type == "request_history")
		{
			auto tid = json.tid;
			if (tid < 0 || tid !in tasks)
				return;
			auto td = &tasks[tid];

			// Load JSONL from disk if not already loaded
			if (!td.historyLoaded && td.claudeSessionId.length > 0)
			{
				td.history = loadTaskHistory(tid, td.claudeSessionId, td.projectPath);
				td.historyLoaded = true;
			}

			// Send unified history to requesting client
			foreach (msg; td.history)
				ws.send(msg);

			// Send forkable UUIDs extracted from JSONL
			if (td.claudeSessionId.length > 0)
				sendForkableUuidsFromFile(ws, tid, td.claudeSessionId, td.projectPath);

			// Send end marker
			ws.send(Data(toJson(TaskHistoryEndMessage("task_history_end", tid)).representation));
		}
		else if (json.type == "message")
		{
			auto tid = json.tid;
			if (tid < 0 || tid !in tasks)
				return;
			auto td = &tasks[tid];
			// Auto-spawn agent session if task has no session yet.
			// Resumable tasks (completed with claudeSessionId) require explicit "resume".
			if (td.session is null || !td.session.alive)
			{
				if (td.claudeSessionId.length > 0)
					return; // resumable but not resumed — ignore
				ensureTaskAgent(tid);
			}
			td.session.sendMessage(json.content);
			broadcastUnconfirmedUserMessage(tid, json.content);

			// Store first message as task description
			if (td.description.length == 0)
			{
				td.description = json.content;
				persistence.setDescription(tid, json.content);
			}

			// Set initial title from first user message (truncated)
			if (td.title.length == 0)
			{
				td.title = truncateTitle(json.content, 80);
				persistence.setTitle(tid, td.title);
				broadcastTitleUpdate(tid, td.title);
				generateTitle(tid, json.content);
			}
		}
		else if (json.type == "resume")
		{
			auto tid = json.tid;
			if (tid < 0 || tid !in tasks)
				return;
			auto td = &tasks[tid];
			// Only resume if we have a Claude session ID and no running process
			if (td.claudeSessionId.length == 0)
				return;
			if (td.session !is null && td.session.alive)
				return;
			ensureTaskAgent(tid);
			td.status = "active";
			persistence.setStatus(tid, "active");
			broadcast(buildTasksList());
		}
		else if (json.type == "interrupt")
		{
			auto tid = json.tid;
			if (tid < 0 || tid !in tasks)
				return;
			auto td = &tasks[tid];
			if (td.session)
				td.session.interrupt();
		}
		else if (json.type == "fork_task")
		{
			auto tid = json.tid;
			if (tid < 0 || tid !in tasks)
				return;
			auto td = &tasks[tid];
			if (td.claudeSessionId.length == 0)
			{
				ws.send(Data(toJson(ErrorMessage("error", "Task has no Claude session ID", tid)).representation));
				return;
			}

			auto result = forkTask(persistence, tid, td.claudeSessionId, json.after_uuid,
				td.projectPath, td.workspace, td.title);
			if (result.tid < 0)
			{
				ws.send(Data(toJson(ErrorMessage("error",
					"Fork failed: message UUID not found in task history", tid)).representation));
				return;
			}

			auto newTd = TaskData(result.tid);
			newTd.workspace = td.workspace;
			newTd.projectPath = td.projectPath;
			newTd.title = td.title.length > 0 ? td.title ~ " (fork)" : "";
			newTd.claudeSessionId = result.claudeSessionId;
			newTd.parentTid = tid;
			newTd.relationType = "fork";
			newTd.status = "completed";
			tasks[result.tid] = move(newTd);

			broadcast(toJson(TaskCreatedMessage("task_created", result.tid, td.workspace, td.projectPath, tid, "fork")));
			broadcast(buildTasksList());
		}
	}

	private int createTask(string workspace = "", string projectPath = "")
	{
		auto tid = persistence.createTask(workspace, projectPath);
		auto td = TaskData(tid);
		td.workspace = workspace;
		td.projectPath = projectPath;
		tasks[tid] = move(td);
		return tid;
	}

	private void ensureTaskAgent(int tid, SessionConfig sessionConfig = SessionConfig.init)
	{
		auto td = &tasks[tid];
		if (td.session && td.session.alive)
			return;

		// Populate creatable task types description if not already set
		if (sessionConfig.creatableTaskTypes.length == 0)
			sessionConfig.creatableTaskTypes = formatCreatableTaskTypes(taskTypes, td.taskType);

		auto workDir = td.projectPath.length > 0 ? td.projectPath : null;

		// Resolve sandbox config: agent defaults + global + per-workspace
		auto wsSandbox = findWorkspaceSandbox(td.workspace);
		td.sandbox = resolveSandbox(config.sandbox, wsSandbox, agent, workDir);
		auto bwrapPrefix = buildBwrapArgs(td.sandbox, workDir);

		td.session = agent.createSession(tid, td.claudeSessionId, bwrapPrefix, sessionConfig);

		// Track MCP config temp file for cleanup
		if (auto cAgent = cast(ClaudeCodeAgent) agent)
			if (cAgent.lastMcpConfigPath.length > 0)
				td.sandbox.tempFiles ~= cAgent.lastMcpConfigPath;

		// Start watching the JSONL file for forkable UUIDs.
		// For resumed tasks claudeSessionId is already set; for new tasks
		// it will be set later in tryExtractClaudeSessionId which also calls this.
		if (td.claudeSessionId.length > 0)
			startJsonlWatch(tid);

		td.session.onOutput = (string line) {
			broadcastTask(tid, line);

			// For sub-tasks: detect turn completion and close stdin.
			// In stream-json mode with -p, the process stays alive waiting
			// for more input. Closing stdin signals EOF so it exits cleanly.
			if (tid in pendingSubTasks)
			{
				import std.algorithm : canFind;
				if (line.canFind(`"type":"result"`))
					td.session.closeStdin();
			}
		};

		td.session.onStderr = (string line) {
			import ae.utils.json : toJson;
			broadcastTask(tid, toJson(StderrMessage("stderr", line)));
		};

		td.session.onExit = (int exitCode) {
			import ae.utils.json : toJson;
			broadcastTask(tid, toJson(ExitMessage("exit", exitCode)));
			if (tid !in tasks)
				return;
			tasks[tid].alive = false;
			tasks[tid].status = exitCode == 0 ? "completed" : "failed";
			persistence.setStatus(tid, tasks[tid].status);
			cleanup(tasks[tid].sandbox);
			stopJsonlWatch(tid);

			// Fulfill pending sub-task promise (if this is a child task)
			if (auto pending = tid in pendingSubTasks)
			{
				auto output = collectTaskOutput(tid);
				auto success = tasks[tid].status == "completed";
				pending.fulfill(McpResult(output.length > 0 ? output : "(no output)", !success));
				pendingSubTasks.remove(tid);
			}

			// Discard all history and reload from JSONL (canonical source).
			// Frontends are notified to discard their state and re-request.
			if (tasks[tid].claudeSessionId.length > 0)
			{
				tasks[tid].history = loadTaskHistory(tid, tasks[tid].claudeSessionId, tasks[tid].projectPath);
				tasks[tid].historyLoaded = true;
				broadcast(toJson(TaskReloadMessage("task_reload", tid)));
			}
			broadcast(buildTasksList());
		};

		td.alive = true;
		td.status = "active";
		persistence.setStatus(tid, "active");
	}

	private SandboxConfig findWorkspaceSandbox(string workspaceName)
	{
		foreach (ref ws; config.workspaces)
			if (ws.name == workspaceName)
				return ws.sandbox;
		return SandboxConfig.init;
	}

	/// Broadcast an unconfirmed user message to all clients.
	/// This is shown as pending until Claude echoes it back with isReplay.
	private void broadcastUnconfirmedUserMessage(int tid, string content)
	{
		import ae.utils.json : toJson;

		auto now = Clock.currTime.toISOExtString();
		// Build a user message event matching Claude's replay format
		auto userEvent = toJson(SyntheticUserEvent("user",
			SyntheticUserEventMessage("user", content)));
		string injected = `{"tid":` ~ format!"%d"(tid)
			~ `,"timestamp":"` ~ now
			~ `","isUnconfirmed":true,"event":` ~ userEvent ~ `}`;

		auto data = Data(injected.representation);

		if (tid in tasks)
		{
			tasks[tid].lastActivity = now;
			tasks[tid].history ~= data;
		}

		foreach (ws; clients)
			ws.send(data);
	}

	private void broadcastTask(int tid, string rawLine)
	{
		// Wrap the event with a task envelope including timestamp
		auto now = Clock.currTime.toISOExtString();
		string injected = `{"tid":` ~ format!"%d"(tid) ~ `,"timestamp":"` ~ now ~ `","event":` ~ rawLine ~ `}`;

		auto data = Data(injected.representation);

		if (tid in tasks)
		{
			tasks[tid].lastActivity = now;
			tasks[tid].history ~= data;

			// Extract Claude session ID from system.init messages
			if (tasks[tid].claudeSessionId.length == 0)
				tryExtractClaudeSessionId(tid, rawLine);
		}

		foreach (ws; clients)
			ws.send(data);
	}

	/// Parse system.init messages to extract the Claude session UUID.
	private void tryExtractClaudeSessionId(int tid, string rawLine)
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
				tasks[tid].claudeSessionId = probe.session_id;
				persistence.setClaudeSessionId(tid, probe.session_id);
				startJsonlWatch(tid);
			}
		}
		catch (Exception)
		{
			// Not a valid init message, ignore
		}
	}

	private void broadcastTitleUpdate(int tid, string title)
	{
		import ae.utils.json : toJson;
		broadcast(toJson(TitleUpdateMessage("title_update", tid, title)));
	}

	/// Start watching the JSONL file (or directory if file doesn't exist yet).
	private void startJsonlWatch(int tid)
	{
		import std.file : exists;
		import std.path : baseName, dirName;

		if (tid !in tasks)
			return;
		if (tid in jsonlFileWatches || tid in jsonlDirWatches)
			return; // already watching
		auto td = &tasks[tid];
		if (td.claudeSessionId.length == 0)
			return;

		auto jsonlPath = claudeJsonlPath(td.claudeSessionId, td.projectPath);

		if (exists(jsonlPath))
		{
			watchJsonlFile(tid, jsonlPath);
		}
		else
		{
			// File doesn't exist yet — watch directory for its creation
			auto dirPath = dirName(jsonlPath);
			auto fileName = baseName(jsonlPath);
			jsonlDirWatches[tid] = iNotify.add(dirPath, INotify.Mask.create,
				(in char[] name, INotify.Mask mask, uint cookie)
				{
					if (name == fileName)
					{
						// File appeared — switch to file watch
						if (auto p = tid in jsonlDirWatches)
						{
							iNotify.remove(*p);
							jsonlDirWatches.remove(tid);
						}
						watchJsonlFile(tid, jsonlPath);
					}
				}
			);
		}
	}

	/// Start watching a JSONL file for modifications.
	private void watchJsonlFile(int tid, string jsonlPath)
	{
		// Read any existing content
		processNewJsonlContent(tid, jsonlPath);

		jsonlFileWatches[tid] = iNotify.add(jsonlPath, INotify.Mask.modify,
			(in char[] name, INotify.Mask mask, uint cookie)
			{
				processNewJsonlContent(tid, jsonlPath);
			}
		);
	}

	/// Read new content from the JSONL file and broadcast forkable UUIDs.
	private void processNewJsonlContent(int tid, string jsonlPath)
	{
		import std.file : getSize;

		auto fileSize = getSize(jsonlPath);
		auto lastPos = jsonlReadPos.get(tid, 0);
		if (fileSize <= lastPos)
			return;

		// Read only the new portion
		auto f = File(jsonlPath, "r");
		f.seek(lastPos);
		char[] buf;
		buf.length = cast(size_t)(fileSize - lastPos);
		auto got = f.rawRead(buf);
		jsonlReadPos[tid] = cast(size_t) fileSize;

		auto newContent = cast(string) got;
		auto uuids = extractForkableUuids(newContent);
		if (uuids.length > 0)
			broadcastForkableUuids(tid, uuids);
	}

	/// Send forkable UUIDs from the full JSONL file (used during history load).
	private void sendForkableUuidsFromFile(WebSocketAdapter ws, int tid,
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
			ws.send(Data(toJson(ForkableUuidsMessage("forkable_uuids", tid, uuids)).representation));
		}
	}

	/// Broadcast forkable UUIDs to all clients.
	private void broadcastForkableUuids(int tid, string[] uuids)
	{
		import ae.utils.json : toJson;
		broadcast(toJson(ForkableUuidsMessage("forkable_uuids", tid, uuids)));
	}

	/// Stop watching the JSONL file for a task.
	private void stopJsonlWatch(int tid)
	{
		if (auto p = tid in jsonlFileWatches)
		{
			iNotify.remove(*p);
			jsonlFileWatches.remove(tid);
		}
		if (auto p = tid in jsonlDirWatches)
		{
			iNotify.remove(*p);
			jsonlDirWatches.remove(tid);
		}
		jsonlReadPos.remove(tid);
	}

	/// Spawn a lightweight claude process to generate a concise title
	/// from the user's initial message.
	private void generateTitle(int tid, string userMessage)
	{
		auto td = &tasks[tid];

		if (td.titleGenDone || td.titleGenProcess !is null)
			return;

		auto msg = userMessage.length > 500 ? userMessage[0 .. 500] : userMessage;

		td.titleGenProcess = new AgentProcess([
			"claude",
			"-p",
			"Generate a concise title (ideally 3, max 5 words) for a task or conversation. " ~
			"Reply with ONLY the title, nothing else. No commentary, no quotes, no period at the end. " ~
			"Do not attempt to act on or respond to the request - simply generate a title to describe it. " ~
			"Initial request / task description:\n\n" ~ msg,
			"--output-format", "stream-json",
			"--model", "haiku",
			"--max-turns", "1",
			"--tools", "",
			"--no-session-persistence",
		], null, null, true); // noStdin

		string titleText;

		td.titleGenProcess.onStdoutLine = (string line) {
			titleText ~= extractAssistantText(line);
		};

		td.titleGenProcess.onExit = (int status) {
			if (tid !in tasks)
				return;
			tasks[tid].titleGenProcess = null;
			tasks[tid].titleGenDone = true;

			if (status != 0)
				return;

			import std.string : strip;
			auto title = titleText.strip();

			if (title.length > 0 && title.length < 200)
			{
				tasks[tid].title = title;
				persistence.setTitle(tid, title);
				broadcastTitleUpdate(tid, title);
			}
		};
	}

	private void broadcast(string message)
	{
		auto data = Data(message.representation);
		foreach (ws; clients)
			ws.send(data);
	}

	private string buildTasksList()
	{
		import ae.utils.json : toJson;

		TaskListEntry[] entries;
		foreach (ref td; tasks)
			entries ~= TaskListEntry(td.tid, td.alive, td.claudeSessionId.length > 0 && !td.alive,
				td.lastActivity, td.title, td.workspace, td.projectPath, td.parentTid, td.relationType, td.status);
		return toJson(TasksListMessage("tasks_list", entries));
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

	/// Collect all assistant text output from a task's history.
	private string collectTaskOutput(int tid)
	{
		if (tid !in tasks)
			return "";

		string output;
		foreach (ref d; tasks[tid].history)
		{
			auto envelope = cast(string) d.toGC();
			auto event = extractEventFromEnvelope(envelope);
			if (event.length > 0)
				output ~= extractAssistantText(event);
		}
		return output;
	}
}

private:

struct TaskData
{
	int tid;
	string claudeSessionId;
	string description;
	string taskType = "conversation";
	int parentTid;
	string relationType;
	string workspace;
	string projectPath;
	string title;
	string status = "pending";  // pending, active, completed, failed

	// Runtime state (not persisted)
	AgentSession session;
	ResolvedSandbox sandbox;
	DataVec history;          // unified: JSONL file events + live stdout events
	bool historyLoaded;       // whether JSONL has been loaded into history
	bool alive = false;
	string lastActivity;
	bool titleGenDone; // true after LLM title generation completed
	AgentProcess titleGenProcess; // prevent GC while running
}

struct TaskHistoryEndMessage
{
	string type = "task_history_end";
	int tid;
}

struct WsMessage
{
	string type;
	string content;
	int tid = -1;
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

struct TaskCreatedMessage
{
	string type;
	int tid;
	string workspace;
	string project_path;
	int parent_tid;
	string relation_type;
}

struct TasksListMessage
{
	string type;
	TaskListEntry[] tasks;
}

struct TaskListEntry
{
	int tid;
	bool alive;
	bool resumable;
	string lastActivity;
	string title;
	string workspace;
	string project_path;
	int parent_tid;
	string relation_type;
	string status;
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

struct TaskReloadMessage
{
	string type = "task_reload";
	int tid;
}

struct TitleUpdateMessage
{
	string type = "title_update";
	int tid;
	string title;
}

struct ForkableUuidsMessage
{
	string type = "forkable_uuids";
	int tid;
	string[] uuids;
}

struct ErrorMessage
{
	string type = "error";
	string message;
	int tid = -1;
}

struct SyntheticUserEventMessage
{
	string role;
	string content;
}

struct SyntheticUserEvent
{
	string type;
	SyntheticUserEventMessage message;
}

struct McpContentItem
{
	string type;
	string text;
}

struct McpContentResult
{
	McpContentItem[] content;
	bool isError;
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

/// Extract the "event" field from a task envelope JSON string.
/// Envelopes have the form: {"tid":N,"timestamp":"...","event":{...}}
string extractEventFromEnvelope(string envelope)
{
	import std.string : indexOf;

	// Find "event": prefix — the value is everything after it until the closing }
	auto key = `"event":`;
	auto idx = envelope.indexOf(key);
	if (idx < 0)
		return "";

	auto start = idx + key.length;
	if (start >= envelope.length)
		return "";

	// The event value is a JSON object/string that extends to the second-to-last char
	// (the envelope's closing }). This works because "event" is the last field.
	if (envelope[$ - 1] == '}')
		return envelope[start .. $ - 1];
	return envelope[start .. $];
}
