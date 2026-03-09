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
import cydo.config : CydoConfig, PathMode, SandboxConfig, WorkspaceConfig, loadConfig, reloadConfig;
import cydo.discover : DiscoveredProject, discoverProjects;
import cydo.persist : ForkResult, Persistence, claudeJsonlPath, extractForkableUuids,
	forkTask, loadTaskHistory;
import cydo.sandbox : ResolvedSandbox, buildBwrapArgs, cleanup, resolveSandbox;
import cydo.tasktype : TaskTypeDef, byName, loadTaskTypes, validateTaskTypes, modelClassToAlias,
	renderPrompt, formatCreatableTaskTypes, disallowedTools;

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
	if (args.canFind("--dot"))
	{
		import cydo.tasktype : runDot;
		runDot(args);
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
	private TaskTypeDef[] taskTypes;
	private string taskTypesDir;
	// Pending sub-task promises (childTid → promise fulfilled on task exit)
	private Promise!(McpResult)[int] pendingSubTasks;
	// inotify watches for JSONL file tracking (tid → watch descriptor)
	private INotify.WatchDescriptor[int] jsonlFileWatches;
	private INotify.WatchDescriptor[int] jsonlDirWatches;
	private size_t[int] jsonlReadPos;
	// inotify watches for config file hot-reload
	private INotify.WatchDescriptor configFileWatch;
	private INotify.WatchDescriptor configDirWatch;
	private bool configFileWatchActive;
	private bool configDirWatchActive;

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
		discoverAllWorkspaces();

		// Watch config file for hot-reload
		startConfigWatch();

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
			td.hasWorktree = row.hasWorktree;
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

		// Send workspaces list, task types, and tasks list to new client
		ws.send(Data(buildWorkspacesList().representation));
		ws.send(Data(buildTaskTypesList().representation));
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
	/// tool completes — immediately for sync tools, later for async tools
	/// (e.g. Task, which awaits the child task's completion in a fiber).
	private Promise!McpResult dispatchTool(string tool, string tid, JSONFragment args)
	{
		import ae.utils.promise.await : async;
		import cydo.mcp.binding : mcpToolDispatcher;
		import cydo.mcp.tools : CydoTools, CydoToolsImpl;

		return async({
			auto impl = new CydoToolsImpl(this, tid);
			auto dispatcher = mcpToolDispatcher!CydoTools(impl);
			return dispatcher.dispatch(tool, args);
		});
	}

	/// Handle Task — returns a promise that resolves when the child task completes.
	package Promise!McpResult handleCreateTask(string callerTid,
		string description, string taskType, string prompt)
	{
		import ae.utils.json : toJson;
		import std.algorithm : canFind;
		import std.array : join;
		import std.conv : to;

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
		auto parentTypeDef = taskTypes.byName(parentTd.taskType);
		if (parentTypeDef !is null &&
			parentTypeDef.creatable_tasks.length > 0 &&
			!parentTypeDef.creatable_tasks.canFind(taskType))
		{
			return resolve(McpResult(
				"Task type '" ~ taskType ~ "' is not in creatable_tasks for '" ~
				parentTd.taskType ~ "'. Allowed: " ~
				parentTypeDef.creatable_tasks.join(", "), true));
		}

		// Validate child task type exists
		auto childTypeDef = taskTypes.byName(taskType);
		if (childTypeDef is null)
			return resolve(McpResult("Unknown task type: " ~ taskType, true));

		// Create child task
		auto childTid = createTask(parentTd.workspace, parentTd.projectPath);
		auto childTd = &tasks[childTid];
		childTd.taskType = taskType;
		childTd.description = prompt;
		childTd.parentTid = parentTid;
		childTd.relationType = "subtask";
		childTd.title = description.length > 0
			? description
			: truncateTitle(prompt, 80);

		// Persist metadata
		persistence.setTaskType(childTid, taskType);
		persistence.setDescription(childTid, prompt);
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
		sessionConfig.disallowedTools = disallowedTools();
		ensureTaskAgent(childTid, sessionConfig);

		// Send rendered prompt template as first user message
		if (childTd.session !is null)
		{
			auto renderedPrompt = renderPrompt(*childTypeDef, prompt, taskTypesDir);
			childTd.session.sendMessage(renderedPrompt);
			broadcastUnconfirmedUserMessage(childTid, renderedPrompt);
		}

		if (description.length == 0)
			generateTitle(childTid, prompt);
		writefln("Task: tid=%d type=%s parent=%d", childTid, taskType, parentTid);

		return promise;
	}

	private void handleWsMessage(WebSocketAdapter ws, string text)
	{
		import ae.utils.json : jsonParse, toJson;

		auto json = jsonParse!WsMessage(text);

		if (json.type == "create_task")
		{
			auto tid = createTask(json.workspace, json.project_path);
			if (json.task_type.length > 0 && taskTypes.byName(json.task_type) !is null)
			{
				tasks[tid].taskType = json.task_type;
				persistence.setTaskType(tid, json.task_type);
			}
			broadcast(toJson(TaskCreatedMessage("task_created", tid, json.workspace, json.project_path, 0, "")));

			// If content is provided, send it as the first message atomically
			if (json.content.length > 0)
			{
				auto td = &tasks[tid];
				auto typeDef = taskTypes.byName(td.taskType);
				if (typeDef !is null)
				{
					auto sc = SessionConfig(
						modelClassToAlias(typeDef.model_class),
					);
					sc.disallowedTools = disallowedTools();
					ensureTaskAgent(tid, sc);
				}
				else
					ensureTaskAgent(tid);

				auto messageToSend = json.content;
				if (typeDef !is null)
					messageToSend = renderPrompt(*typeDef, json.content, taskTypesDir);
				td.session.sendMessage(messageToSend);
				td.isProcessing = true;
				broadcastUnconfirmedUserMessage(tid, json.content);

				td.description = json.content;
				persistence.setDescription(tid, json.content);

				td.title = truncateTitle(json.content, 80);
				persistence.setTitle(tid, td.title);
				broadcastTitleUpdate(tid, td.title);
				generateTitle(tid, json.content);

				broadcast(buildTasksList());
			}
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
				td.history = loadTaskHistory(tid, td.claudeSessionId, td.effectiveCwd);
				td.historyLoaded = true;
			}

			// Send unified history to requesting client
			foreach (msg; td.history)
				ws.send(msg);

			// Send forkable UUIDs extracted from JSONL
			if (td.claudeSessionId.length > 0)
				sendForkableUuidsFromFile(ws, tid, td.claudeSessionId, td.effectiveCwd);

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
				// Build session config from task type if available
				auto typeDef = taskTypes.byName(td.taskType);
				if (typeDef !is null)
				{
					auto sc = SessionConfig(
						modelClassToAlias(typeDef.model_class),
					);
					sc.disallowedTools = disallowedTools();
					ensureTaskAgent(tid, sc);
				}
				else
					ensureTaskAgent(tid);
			}
			// Wrap first message in prompt template (e.g. conversation.md)
			auto messageToSend = json.content;
			if (td.description.length == 0)
			{
				auto typeDef = taskTypes.byName(td.taskType);
				if (typeDef !is null)
					messageToSend = renderPrompt(*typeDef, json.content, taskTypesDir);
			}
			td.session.sendMessage(messageToSend);
			td.needsAttention = false;
			td.notificationBody = "";
			td.isProcessing = true;
			broadcast(buildTasksList());
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
			td.needsAttention = false;
			td.notificationBody = "";
			td.status = "active";
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
		else if (json.type == "sigint")
		{
			auto tid = json.tid;
			if (tid < 0 || tid !in tasks)
				return;
			auto td = &tasks[tid];
			if (td.session)
				td.session.sigint();
		}
		else if (json.type == "close_stdin")
		{
			auto tid = json.tid;
			if (tid < 0 || tid !in tasks)
				return;
			auto td = &tasks[tid];
			if (td.session)
				td.session.closeStdin();
		}
		else if (json.type == "stop")
		{
			auto tid = json.tid;
			if (tid < 0 || tid !in tasks)
				return;
			auto td = &tasks[tid];
			if (td.session)
				td.session.stop();
		}
		else if (json.type == "dismiss_attention")
		{
			auto tid = json.tid;
			if (tid >= 0 && tid in tasks)
			{
				tasks[tid].needsAttention = false;
				tasks[tid].notificationBody = "";
				broadcast(buildTasksList());
			}
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
				td.effectiveCwd, td.workspace, td.title);
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

		// Disable built-in Task tool — our MCP Task tool replaces it
		if (sessionConfig.disallowedTools.length == 0)
			sessionConfig.disallowedTools = "Task";

		auto workDir = td.projectPath.length > 0 ? td.projectPath : null;
		auto typeDef = taskTypes.byName(td.taskType);

		// Ensure per-task directory exists
		import std.path : buildPath;
		if (td.taskDir.length > 0)
		{
			import std.file : mkdirRecurse;
			mkdirRecurse(td.taskDir);
		}

		// Create git worktree for task types that require isolation
		if (!td.hasWorktree && td.taskDir.length > 0)
		{
			import std.process : execute;

			if (typeDef !is null && typeDef.worktree)
			{
				auto wtPath = buildPath(td.taskDir, "worktree");
				auto gitResult = execute(["git", "-C", workDir, "worktree", "add", "--detach", wtPath]);
				if (gitResult.status == 0)
				{
					td.hasWorktree = true;
					persistence.setHasWorktree(td.tid, true);
					writefln("Created worktree for task %d: %s", td.tid, wtPath);
				}
				else
					writefln("Failed to create worktree for task %d: %s", td.tid, gitResult.output);
			}
		}

		// Use worktree path as chdir if available; sandbox covers project dir (rw)
		auto chdir = td.hasWorktree ? td.worktreePath : workDir;

		// Resolve sandbox config: agent defaults + global + per-workspace
		auto wsSandbox = findWorkspaceSandbox(td.workspace);
		bool readOnly = typeDef !is null && typeDef.read_only;
		td.sandbox = resolveSandbox(config.sandbox, wsSandbox, agent, workDir, readOnly);

		// Task directory is always writable (even for read-only tasks)
		if (td.taskDir.length > 0)
			td.sandbox.paths[td.taskDir] = PathMode.rw;

		auto bwrapPrefix = buildBwrapArgs(td.sandbox, chdir);

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

			import std.algorithm : canFind;
			if (line.canFind(`"type":"result"`))
			{
				// Turn completed — no longer processing, but still alive.
				td.isProcessing = false;
				td.needsAttention = true;
				td.notificationBody = extractLastAssistantText(tid);
				broadcast(buildTasksList());

				// Capture the canonical result text for sub-task output.
				td.resultText = extractResultText(line);

				// For sub-tasks: close stdin so the process exits cleanly.
				if (tid in pendingSubTasks)
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
			tasks[tid].isProcessing = false;
			tasks[tid].status = exitCode == 0 ? "completed" : "failed";
			persistence.setStatus(tid, tasks[tid].status);
			cleanup(tasks[tid].sandbox);
			stopJsonlWatch(tid);

			// Fulfill pending sub-task promise (if this is a child task)
			if (auto pending = tid in pendingSubTasks)
			{
				auto output = tasks[tid].resultText;
				auto success = tasks[tid].status == "completed";
				pending.fulfill(McpResult(output.length > 0 ? output : "(no output)", !success));
				pendingSubTasks.remove(tid);
			}

			// Discard all history and reload from JSONL (canonical source).
			// Frontends are notified to discard their state and re-request.
			if (tasks[tid].claudeSessionId.length > 0)
			{
				tasks[tid].history = loadTaskHistory(tid, tasks[tid].claudeSessionId, tasks[tid].effectiveCwd);
				tasks[tid].historyLoaded = true;
				broadcast(toJson(TaskReloadMessage("task_reload", tid)));
			}
			tasks[tid].needsAttention = true;
			tasks[tid].notificationBody = extractLastAssistantText(tid);
			broadcast(buildTasksList());
		};

		td.alive = true;
		td.status = "active";
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
			~ `","unconfirmedUserEvent":` ~ userEvent ~ `}`;

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

	/// Discover projects in all configured workspaces and populate workspacesInfo.
	private void discoverAllWorkspaces()
	{
		workspacesInfo = null;
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
	}

	/// Watch the config file for changes and reload on modification.
	/// Handles both direct saves (closeWrite) and editor write-and-rename (vim, etc.)
	/// by also watching the config directory for create events.
	private void startConfigWatch()
	{
		import std.file : exists;
		import std.path : baseName, dirName;
		import cydo.config : configPath;

		auto cfgPath = configPath;
		auto cfgDir = dirName(cfgPath);
		auto cfgFileName = baseName(cfgPath);

		if (!exists(cfgDir))
		{
			writefln("Config directory %s does not exist, skipping config watch", cfgDir);
			return;
		}

		// Watch the file itself for direct writes
		if (exists(cfgPath))
			watchConfigFile(cfgPath);

		// Watch the directory for create events (editor write-and-rename)
		configDirWatch = iNotify.add(cfgDir, INotify.Mask.create | INotify.Mask.movedTo,
			(in char[] name, INotify.Mask mask, uint cookie)
			{
				if (name == cfgFileName)
				{
					// File was replaced — re-watch the new file
					if (configFileWatchActive)
					{
						iNotify.remove(configFileWatch);
						configFileWatchActive = false;
					}
					watchConfigFile(cfgPath);
					onConfigChanged();
				}
			}
		);
		configDirWatchActive = true;
	}

	private void watchConfigFile(string cfgPath)
	{
		configFileWatch = iNotify.add(cfgPath, INotify.Mask.closeWrite,
			(in char[] name, INotify.Mask mask, uint cookie)
			{
				onConfigChanged();
			}
		);
		configFileWatchActive = true;
	}

	private void onConfigChanged()
	{
		writefln("Config file changed, reloading...");
		auto result = reloadConfig();
		if (result.isNull())
		{
			writefln("  Config reload failed (parse error), keeping current config");
			return;
		}
		config = result.get();
		discoverAllWorkspaces();
		broadcast(buildWorkspacesList());
		writefln("  Config reloaded successfully");
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

		auto jsonlPath = claudeJsonlPath(td.claudeSessionId, td.effectiveCwd);

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
				td.isProcessing, td.needsAttention, td.notificationBody,
				td.lastActivity, td.title, td.workspace, td.projectPath, td.parentTid, td.relationType, td.status);
		return toJson(TasksListMessage("tasks_list", entries));
	}

	private string buildWorkspacesList()
	{
		import ae.utils.json : toJson;
		return toJson(WorkspacesListMessage("workspaces_list", workspacesInfo));
	}

	private string buildTaskTypesList()
	{
		import ae.utils.json : toJson;

		TaskTypeListEntry[] entries;
		foreach (ref def; taskTypes)
			if (def.user_visible)
				entries ~= TaskTypeListEntry(def.name, def.description, def.model_class, def.read_only);
		return toJson(TaskTypesListMessage("task_types_list", entries));
	}

	private void removeClient(WebSocketAdapter ws)
	{
		import std.algorithm : remove;
		clients = clients.remove!(c => c is ws);
	}

	/// Extract the last assistant text from a task's history, truncated.
	/// Used for notification body when a task needs attention.
	private string extractLastAssistantText(int tid)
	{
		if (tid !in tasks)
			return "";
		foreach_reverse (ref d; tasks[tid].history)
		{
			auto envelope = cast(string) d.toGC();
			auto event = extractEventFromEnvelope(envelope);
			if (event.length > 0)
			{
				auto text = extractAssistantText(event);
				if (text.length > 0)
					return truncateTitle(text, 200);
			}
		}
		return "";
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
	bool hasWorktree;
	string title;
	string status = "pending";  // pending, active, completed, failed

	/// Per-task directory: .cydo/tasks/<tid>/
	@property string taskDir() const
	{
		if (projectPath.length == 0)
			return "";
		import std.path : buildPath;
		return buildPath(projectPath, ".cydo", "tasks", format!"%d"(tid));
	}

	/// Worktree path (if this task has one).
	@property string worktreePath() const
	{
		if (!hasWorktree)
			return "";
		import std.path : buildPath;
		return buildPath(taskDir, "worktree");
	}

	/// Effective working directory: worktree path if set, otherwise project path.
	@property string effectiveCwd() const
	{
		return hasWorktree ? worktreePath : projectPath;
	}

	// Runtime state (not persisted)
	AgentSession session;
	ResolvedSandbox sandbox;
	DataVec history;          // unified: JSONL file events + live stdout events
	bool historyLoaded;       // whether JSONL has been loaded into history
	bool alive = false;
	bool isProcessing = false;
	bool needsAttention = false;
	string notificationBody;
	string lastActivity;
	string resultText;    // result from the "result" event (canonical sub-task output)
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
	string task_type;
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
	bool isProcessing;
	bool needsAttention;
	string notificationBody;
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

struct TaskTypeListEntry
{
	string name;
	string description;
	string model_class;
	bool read_only;
}

struct TaskTypesListMessage
{
	string type = "task_types_list";
	TaskTypeListEntry[] task_types;
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

/// Extract the "result" field from a stream-json result event.
/// The result event has: {"type":"result","subtype":"success","result":"..."}
string extractResultText(string line)
{
	import ae.utils.json : jsonParse, JSONPartial;

	@JSONPartial
	static struct ResultProbe
	{
		string type;
		string result;
	}

	try
	{
		auto probe = jsonParse!ResultProbe(line);
		if (probe.type == "result")
			return probe.result;
		return "";
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
