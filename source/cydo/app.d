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
import ae.net.http.server : HttpServer, HttpServerConnection, HttpsServer;
import ae.net.http.websocket : WebSocketAdapter, accept;
import ae.net.ssl.openssl;
import ae.sys.data : Data;
import ae.sys.dataset : DataVec;
import ae.utils.json : JSONFragment, JSONPartial;
import ae.utils.promise : Promise, resolve;

mixin SSLUseLib;

import cydo.mcp : McpResult;
import cydo.mcp.tools : ToolsBackend;

import cydo.agent.agent : Agent, SessionConfig;
import cydo.agent.session : AgentSession;
import cydo.config : CydoConfig, PathMode, SandboxConfig, WorkspaceConfig, loadConfig, reloadConfig;
import cydo.discover : DiscoveredProject, discoverProjects;
import cydo.persist : ForkResult, Persistence, countLinesAfterForkId,
	forkTask, lastForkIdInJsonl, loadTaskHistory, truncateJsonl;
import cydo.sandbox : ResolvedSandbox, buildBwrapArgs, cleanup, resolveSandbox;
import cydo.tasktype : TaskTypeDef, byName, loadTaskTypes, validateTaskTypes,
	renderPrompt, renderContinuationPrompt, formatCreatableTaskTypes, formatSwitchModes, formatHandoffs, disallowedTools;

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
	if (args.canFind("--dump-context"))
	{
		import cydo.tasktype : runDumpContext;
		runDumpContext(args);
		return;
	}

	auto app = new App();
	app.start();
	socketManager.loop();
}

class App : ToolsBackend
{
	import ae.sys.inotify : INotify, iNotify;
	import cydo.inotify : RefCountedINotify;

	private HttpServer server;
	private HttpServer mcpServer; // UNIX socket for MCP proxy calls (no auth)
	private string mcpSocketPath;
	private WebSocketAdapter[] clients;
	private TaskData[int] tasks;
	private Persistence persistence;
	private CydoConfig config;
	private WorkspaceInfo[] workspacesInfo;
	private Agent agent; // default agent
	private Agent[string] agentsByType;
	// Task type definitions loaded from YAML
	private TaskTypeDef[] taskTypesCache;
	private enum taskTypesDir = "defs/task-types";
	private enum taskTypesPath = "defs/task-types/types.yaml";
	// Pending sub-task promises (childTid → promise fulfilled on task exit)
	private Promise!(McpResult)[int] pendingSubTasks;
	// inotify watches for JSONL file tracking (tid → handle)
	private RefCountedINotify rcINotify;
	private RefCountedINotify.Handle[int] jsonlWatches;
	private size_t[int] jsonlReadPos;
	private int[int] jsonlLineCount;  // cumulative line count for partial reads
	// inotify watches for config file hot-reload
	private INotify.WatchDescriptor configFileWatch;
	private INotify.WatchDescriptor configDirWatch;
	private bool configFileWatchActive;
	private bool configDirWatchActive;
	// HTTP basic auth credentials (from environment)
	private string authUser;
	private string authPass;

	private TaskTypeDef[] getTaskTypes()
	{
		try
		{
			auto types = loadTaskTypes(taskTypesPath);
			auto errors = validateTaskTypes(types, taskTypesDir);
			foreach (e; errors)
				writefln("  WARN: task type: %s", e);
			taskTypesCache = types;
			return taskTypesCache;
		}
		catch (Exception e)
		{
			writefln("Warning: task types file changed but failed to parse, keeping previous version: %s", e.msg);
			return taskTypesCache;
		}
	}

	void start()
	{
		persistence = Persistence("data/cydo.db");
		config = loadConfig();
		agent = createAgent(config.default_agent_type);
		agentsByType[config.default_agent_type] = agent;

		// Load task type definitions
		auto types = getTaskTypes();
		if (types.length == 0)
			writefln("Warning: no task types loaded");
		else
			writefln("Loaded %d task types", types.length);

		// Discover projects in all workspaces
		discoverAllWorkspaces();

		// Watch config file for hot-reload
		startConfigWatch();

		// Load persisted tasks (metadata only — history loaded on demand)
		foreach (row; persistence.loadTasks())
		{
			auto td = TaskData(row.tid);
			td.agentSessionId = row.agentSessionId;
			td.description = row.description;
			td.taskType = row.taskType;
			td.agentType = row.agentType;
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

		import std.process : environment;

		auto sslCert = environment.get("CYDO_TLS_CERT", null);
		auto sslKey = environment.get("CYDO_TLS_KEY", null);
		if (sslCert || sslKey)
		{
			auto https = new HttpsServer();
			https.ctx.setCertificate(sslCert);
			https.ctx.setPrivateKey(sslKey);
			server = https;
		}
		else
			server = new HttpServer();

		authUser = environment.get("CYDO_AUTH_USER", null);
		authPass = environment.get("CYDO_AUTH_PASS", null);

		server.handleRequest = &handleRequest;
		auto port = server.listen(3456);
		auto proto = sslCert ? "https" : "http";
		writefln("CyDo server listening on %s://localhost:%d", proto, port);

		// Internal UNIX socket for MCP proxy calls (no auth required)
		startMcpSocket();
	}

	private bool checkAuth(HttpRequest request, HttpServerConnection conn)
	{
		if (!authUser && !authPass)
			return true;
		auto response = new HttpResponseEx();
		if (!response.authorize(request, (reqUser, reqPass) => reqUser == authUser && reqPass == authPass))
		{
			conn.sendResponse(response);
			return false;
		}
		return true;
	}

	private void handleRequest(HttpRequest request, HttpServerConnection conn)
	{
		if (!checkAuth(request, conn))
			return;

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

		ws.sendBinary = true; // binary frames — no UTF-8 encoding requirement
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

	private void startMcpSocket()
	{
		import std.file : mkdirRecurse, remove;
		import std.path : absolutePath, buildPath;
		import std.socket : AddressFamily, AddressInfo, ProtocolType, SocketType, UnixAddress;

		mcpSocketPath = absolutePath(buildPath("data", "mcp.sock"));

		// Remove stale socket file from previous run
		if (exists(mcpSocketPath))
			remove(mcpSocketPath);

		mkdirRecurse("data");

		mcpServer = new HttpServer();
		mcpServer.handleRequest = (HttpRequest request, HttpServerConnection conn) {
			if (request.resource == "/mcp/call" && request.method == "POST")
				handleMcpCall(request, conn);
			else
			{
				auto response = new HttpResponseEx();
				response.setStatus(HttpStatusCode.NotFound);
				conn.sendResponse(response);
			}
		};
		auto addr = new UnixAddress(mcpSocketPath);
		mcpServer.listen([AddressInfo(AddressFamily.UNIX, SocketType.STREAM, cast(ProtocolType) 0, addr, mcpSocketPath)]);
		writefln("MCP socket listening on %s", mcpSocketPath);
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
			if (!conn.connected)
				return;
			auto resultJson = toJson(McpContentResult(
				[McpContentItem("text", result.text)],
				result.isError,
				result.structuredContent,
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
	Promise!McpResult handleCreateTask(string callerTid,
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
		auto parentTypeDef = getTaskTypes().byName(parentTd.taskType);
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
		auto childTypeDef = getTaskTypes().byName(taskType);
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
			agentForTask(childTid).resolveModelAlias(childTypeDef.model_class),
		);
		sessionConfig.disallowedTools = disallowedTools();
		ensureTaskAgent(childTid, sessionConfig);

		// Send rendered prompt template as first user message
		if (childTd.session !is null)
		{
			auto renderedPrompt = renderPrompt(*childTypeDef, prompt, taskTypesDir, childTd.outputPath);
			broadcastUnconfirmedUserMessage(childTid, renderedPrompt);
			sendTaskMessage(childTid, renderedPrompt);
		}

		if (description.length == 0)
			generateTitle(childTid, prompt);
		writefln("Task: tid=%d type=%s parent=%d", childTid, taskType, parentTid);

		return promise;
	}

	/// Handle SwitchMode tool — validate and store continuation choice (keep_context).
	/// The actual transition happens in onExit after the session ends.
	McpResult handleSwitchMode(string callerTid, string continuation)
	{
		import std.conv : to;

		int tid;
		try
			tid = to!int(callerTid);
		catch (Exception)
			return McpResult("Invalid calling task ID", true);

		auto td = tid in tasks;
		if (td is null)
			return McpResult("Calling task not found", true);

		auto typeDef = getTaskTypes().byName(td.taskType);
		if (typeDef is null)
			return McpResult("Unknown task type: " ~ td.taskType, true);

		auto contDef = continuation in typeDef.continuations;
		if (contDef is null || !contDef.keep_context)
		{
			return McpResult(
				"Unknown SwitchMode continuation '" ~ continuation ~ "' for task type '" ~
				td.taskType ~ "'. Check the available modes in the tool description.", true);
		}

		td.pendingContinuation = continuation;
		writefln("SwitchMode: tid=%d continuation=%s (type %s → %s)",
			tid, continuation, td.taskType, contDef.task_type);

		return McpResult(
			"Mode switch to '" ~ contDef.task_type ~ "' accepted. "
			~ "Yield your turn now — do not call any more tools or generate output. "
			~ "You will receive new instructions when your session resumes.");
	}

	/// Handle Handoff tool — validate continuation, store choice + prompt.
	/// Creates a new child task on exit with the provided prompt.
	McpResult handleHandoff(string callerTid, string continuation, string prompt)
	{
		import std.conv : to;

		int tid;
		try
			tid = to!int(callerTid);
		catch (Exception)
			return McpResult("Invalid calling task ID", true);

		auto td = tid in tasks;
		if (td is null)
			return McpResult("Calling task not found", true);

		auto typeDef = getTaskTypes().byName(td.taskType);
		if (typeDef is null)
			return McpResult("Unknown task type: " ~ td.taskType, true);

		auto contDef = continuation in typeDef.continuations;
		if (contDef is null || contDef.keep_context)
		{
			return McpResult(
				"Unknown Handoff continuation '" ~ continuation ~ "' for task type '" ~
				td.taskType ~ "'. Check the available handoffs in the tool description.", true);
		}

		if (prompt.length == 0)
			return McpResult("Handoff requires a non-empty prompt for the successor task.", true);

		td.pendingContinuation = continuation;
		td.handoffPrompt = prompt;
		writefln("Handoff: tid=%d continuation=%s (type %s → %s)",
			tid, continuation, td.taskType, contDef.task_type);

		return McpResult(
			"Handoff to '" ~ contDef.task_type ~ "' accepted. "
			~ "Yield your turn now — do not call any more tools or generate output. "
			~ "A new task will be created with your prompt. Your session is ending.");
	}

	private void handleWsMessage(WebSocketAdapter ws, string text)
	{
		import ae.utils.json : jsonParse, toJson;

		auto json = jsonParse!WsMessage(text);

		if (json.type == "create_task")
		{
			auto at = json.agent_type.length > 0 ? json.agent_type : config.default_agent_type;
			auto tid = createTask(json.workspace, json.project_path, at);
			if (json.task_type.length > 0 && getTaskTypes().byName(json.task_type) !is null)
			{
				tasks[tid].taskType = json.task_type;
				persistence.setTaskType(tid, json.task_type);
			}
			broadcast(toJson(TaskCreatedMessage("task_created", tid, json.workspace, json.project_path, 0, "")));

			// If content is provided, send it as the first message atomically
			if (json.content.length > 0)
			{
				auto td = &tasks[tid];
				auto typeDef = getTaskTypes().byName(td.taskType);
				if (typeDef !is null)
				{
					auto sc = SessionConfig(
						agentForTask(tid).resolveModelAlias(typeDef.model_class),
					);
					sc.disallowedTools = disallowedTools();
					ensureTaskAgent(tid, sc);
				}
				else
					ensureTaskAgent(tid);

				auto messageToSend = json.content;
				if (typeDef !is null)
					messageToSend = renderPrompt(*typeDef, json.content, taskTypesDir, td.outputPath);
				broadcastUnconfirmedUserMessage(tid, json.content);
				sendTaskMessage(tid, messageToSend);

				td.description = json.content;
				persistence.setDescription(tid, json.content);

				td.title = truncateTitle(json.content, 80);
				persistence.setTitle(tid, td.title);
				broadcastTitleUpdate(tid, td.title);
				generateTitle(tid, json.content);
			}
		}
		else if (json.type == "request_history")
		{
			auto tid = json.tid;
			if (tid < 0 || tid !in tasks)
				return;
			auto td = &tasks[tid];

			// Load JSONL from disk if not already loaded
			if (!td.historyLoaded && td.agentSessionId.length > 0)
			{
				auto ta = agentForTask(tid);
				auto jsonlPath = ta.historyPath(td.agentSessionId, td.effectiveCwd);
				string[] steeringStash;
				td.history = loadTaskHistory(tid, jsonlPath, (string line, int lineNum) {
					if (isQueueOperation(line))
					{
						import ae.utils.json : jsonParse;
						auto op = jsonParse!QueueOperationProbe(line);
						if (op.operation == "enqueue")
						{
							steeringStash ~= op.content;
							return buildSyntheticUserEvent(op.content, false, true);
						}
						else if (op.operation == "dequeue")
						{
							if (steeringStash.length > 0)
								steeringStash = steeringStash[1 .. $];
							return null; // skip — the real message/user follows
						}
						else if (op.operation == "remove")
						{
							if (steeringStash.length > 0)
							{
								auto text = steeringStash[0];
								steeringStash = steeringStash[1 .. $];
								// Emit steering confirmation at the remove position
								return buildSyntheticUserEvent(text, true);
							}
							return null;
						}
						return null; // unknown queue operation
					}
					return ta.translateHistoryLine(line, lineNum);
				});
				td.historyLoaded = true;
			}

			// Send unified history to requesting client
			foreach (msg; td.history)
				ws.send(msg);

			// Send forkable UUIDs extracted from JSONL
			if (td.agentSessionId.length > 0)
				sendForkableUuidsFromFile(ws, tid, td.agentSessionId, td.effectiveCwd);

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
			// Resumable tasks (completed with agentSessionId) require explicit "resume".
			if (td.session is null || !td.session.alive)
			{
				if (td.agentSessionId.length > 0)
					return; // resumable but not resumed — ignore
				// Build session config from task type if available
				auto typeDef = getTaskTypes().byName(td.taskType);
				if (typeDef !is null)
				{
					auto sc = SessionConfig(
						agentForTask(tid).resolveModelAlias(typeDef.model_class),
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
				auto typeDef = getTaskTypes().byName(td.taskType);
				if (typeDef !is null)
					messageToSend = renderPrompt(*typeDef, json.content, taskTypesDir, td.outputPath);
			}
			broadcastUnconfirmedUserMessage(tid, json.content);
			sendTaskMessage(tid, messageToSend);

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
			// Only resume if we have an agent session ID and no running process
			if (td.agentSessionId.length == 0)
				return;
			if (td.session !is null && td.session.alive)
				return;
			auto typeDef = getTaskTypes().byName(td.taskType);
			if (typeDef !is null)
			{
				auto sc = SessionConfig(agentForTask(tid).resolveModelAlias(typeDef.model_class));
				sc.disallowedTools = disallowedTools();
				ensureTaskAgent(tid, sc);
			}
			else
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
			if (td.agentSessionId.length == 0)
			{
				ws.send(Data(toJson(ErrorMessage("error", "Task has no agent session ID", tid)).representation));
				return;
			}

			auto ta = agentForTask(tid);
			auto result = forkTask(persistence, tid, td.agentSessionId, json.after_uuid,
				td.effectiveCwd, td.workspace, td.title,
				(string sid) => ta.historyPath(sid, td.effectiveCwd),
				&ta.rewriteSessionId, &ta.forkIdMatchesLine,
				td.description, td.taskType);
			if (result.tid < 0)
			{
				ws.send(Data(toJson(ErrorMessage("error",
					"Fork failed: message UUID not found in task history", tid)).representation));
				return;
			}

			auto newTd = TaskData(result.tid);
			newTd.workspace = td.workspace;
			newTd.projectPath = td.projectPath;
			newTd.title = td.title.length > 0 ? td.title ~ " (fork)" : "(fork)";
			newTd.agentSessionId = result.agentSessionId;
			newTd.parentTid = tid;
			newTd.relationType = "fork";
			newTd.status = "completed";
			newTd.description = td.description;
			newTd.taskType = td.taskType;
			tasks[result.tid] = move(newTd);

			broadcast(toJson(TaskCreatedMessage("task_created", result.tid, td.workspace, td.projectPath, tid, "fork")));
			broadcast(buildTasksList());
		}
		else if (json.type == "undo_task")
		{
			auto tid = json.tid;
			if (tid < 0 || tid !in tasks)
				return;
			auto td = &tasks[tid];
			if (td.agentSessionId.length == 0)
			{
				ws.send(Data(toJson(ErrorMessage("error", "Task has no agent session ID", tid)).representation));
				return;
			}

			auto ta = agentForTask(tid);

			if (json.dry_run)
			{
					auto count = countLinesAfterForkId(
					ta.historyPath(td.agentSessionId, td.effectiveCwd), json.after_uuid,
					&ta.forkIdMatchesLine,
					&ta.isForkableLine);
				if (count < 0)
				{
					ws.send(Data(toJson(ErrorMessage("error", "UUID not found in task history", tid)).representation));
					return;
				}
				// +1 to include the target user message itself
				ws.send(Data(toJson(UndoPreviewMessage("undo_preview", tid, count + 1)).representation));
			}
			else
			{
				// Require session to be stopped
				if (td.session && td.session.alive)
				{
					ws.send(Data(toJson(ErrorMessage("error", "Stop the session before undoing", tid)).representation));
					return;
				}

				// 1. Revert file changes via one-shot --rewind-files invocation
				// (done first so that on failure we haven't modified anything yet)
				if (json.revert_files)
				{
					auto err = ta.rewindFiles(td.agentSessionId, json.after_uuid, td.effectiveCwd);
					if (err !is null)
					{
						ws.send(Data(toJson(ErrorMessage("error", "File revert failed: " ~ err, tid)).representation));
						return;
					}
				}

				// 2. Back up pre-undo state as a child task
				if (json.revert_conversation)
				{
					auto lastForkId = lastForkIdInJsonl(ta.historyPath(td.agentSessionId, td.effectiveCwd),
						&ta.extractForkableIds);
					if (lastForkId.length > 0)
					{
						auto backup = forkTask(persistence, tid, td.agentSessionId, lastForkId,
							td.effectiveCwd, td.workspace, td.title,
							(string sid) => ta.historyPath(sid, td.effectiveCwd),
							&ta.rewriteSessionId, &ta.forkIdMatchesLine,
							td.description, td.taskType);
						if (backup.tid >= 0)
						{
							auto bTd = TaskData(backup.tid);
							bTd.workspace = td.workspace;
							bTd.projectPath = td.projectPath;
							bTd.title = td.title.length > 0 ? td.title ~ " (pre-undo)" : "(pre-undo)";
							bTd.agentSessionId = backup.agentSessionId;
							bTd.parentTid = tid;
							bTd.relationType = "undo-backup";
							bTd.status = "completed";
							bTd.description = td.description;
							bTd.taskType = td.taskType;
							persistence.setRelationType(backup.tid, "undo-backup");
							persistence.setTitle(backup.tid, bTd.title);
							tasks[backup.tid] = move(bTd);
							broadcast(toJson(TaskCreatedMessage("task_created", backup.tid, td.workspace, td.projectPath, tid, "undo-backup")));
						}
					}
				}

				// 3. Truncate conversation history
				if (json.revert_conversation)
				{
					auto removed = truncateJsonl(ta.historyPath(td.agentSessionId, td.effectiveCwd), json.after_uuid, &ta.forkIdMatchesLine, true);
					if (removed < 0)
					{
						ws.send(Data(toJson(ErrorMessage("error", "UUID not found for truncation", tid)).representation));
						return;
					}
					td.history = DataVec();
					td.historyLoaded = false;
				}

				broadcast(toJson(TaskReloadMessage("task_reload", tid)));

				// 4. Auto-resume so the input box shows immediately
				// (the user's undone message text is recovered via preReloadDrafts)
				if (json.revert_conversation && td.agentSessionId.length > 0)
				{
					auto typeDef = getTaskTypes().byName(td.taskType);
					if (typeDef !is null)
					{
						auto sc = SessionConfig(agentForTask(tid).resolveModelAlias(typeDef.model_class));
						sc.disallowedTools = disallowedTools();
						ensureTaskAgent(tid, sc);
					}
					else
						ensureTaskAgent(tid);
					td.status = "active";
				}

				broadcast(buildTasksList());
			}
		}
	}

	/// Send a user message to a task's agent session.
	///
	/// This is the sole entry point for delivering messages to an agent. It
	/// writes the message to the agent's stdin and flips the task into the
	/// "processing" state (yellow dot in the UI), which is later cleared when
	/// the agent emits a `result` event or the process exits.
	///
	/// All code paths that deliver a message — WebSocket `create_task`,
	/// WebSocket `message`, and MCP sub-task creation — must use this method
	/// instead of calling `session.sendMessage` directly, so that processing
	/// state stays consistent.
	private void sendTaskMessage(int tid, string text)
	{
		auto td = &tasks[tid];
		td.session.sendMessage(text);
		td.isProcessing = true;
		td.needsAttention = false;
		td.notificationBody = "";
		broadcast(buildTasksList());
	}

	private int createTask(string workspace = "", string projectPath = "", string agentType = "claude")
	{
		auto tid = persistence.createTask(workspace, projectPath, agentType);
		auto td = TaskData(tid);
		td.workspace = workspace;
		td.projectPath = projectPath;
		td.agentType = agentType;
		tasks[tid] = move(td);
		return tid;
	}

	/// Return the Agent instance for a task's agent type, creating it on demand.
	private Agent agentForTask(int tid)
	{
		auto td = &tasks[tid];
		if (auto p = td.agentType in agentsByType)
			return *p;
		auto a = createAgent(td.agentType);
		agentsByType[td.agentType] = a;
		return a;
	}

	/// Create an Agent instance by type name.
	private static Agent createAgent(string agentType)
	{
		switch (agentType)
		{
			case "claude":
				import cydo.agent.claude : ClaudeCodeAgent;
				return new ClaudeCodeAgent();
			case "codex":
				import cydo.agent.codex : CodexAgent;
				return new CodexAgent();
			default:
				throw new Exception("Unknown agent type: " ~ agentType);
		}
	}

	private void ensureTaskAgent(int tid, SessionConfig sessionConfig = SessionConfig.init)
	{
		auto td = &tasks[tid];
		if (td.session && td.session.alive)
			return;

		// Look up the correct agent for this task's agent type
		auto taskAgent = agentForTask(tid);

		// Populate creatable task types description if not already set
		if (sessionConfig.creatableTaskTypes.length == 0)
			sessionConfig.creatableTaskTypes = formatCreatableTaskTypes(getTaskTypes(), td.taskType);

		// Populate SwitchMode and Handoff descriptions if not already set
		if (sessionConfig.switchModes.length == 0)
			sessionConfig.switchModes = formatSwitchModes(getTaskTypes(), td.taskType);
		if (sessionConfig.handoffs.length == 0)
			sessionConfig.handoffs = formatHandoffs(getTaskTypes(), td.taskType);

		// Disable built-in tools that are replaced by our MCP equivalents
		if (sessionConfig.disallowedTools.length == 0)
			sessionConfig.disallowedTools = disallowedTools();

		// Pass UNIX socket path for MCP proxy communication
		if (sessionConfig.mcpSocketPath.length == 0)
			sessionConfig.mcpSocketPath = mcpSocketPath;

		auto workDir = td.projectPath.length > 0 ? td.projectPath : null;
		auto typeDef = getTaskTypes().byName(td.taskType);

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
		td.sandbox = resolveSandbox(config.sandbox, wsSandbox, taskAgent, workDir, readOnly);

		// Task directory is always writable (even for read-only tasks)
		if (td.taskDir.length > 0)
			td.sandbox.paths[td.taskDir] = PathMode.rw;

		// MCP socket must be accessible inside the sandbox
		if (mcpSocketPath.length > 0)
			td.sandbox.paths[mcpSocketPath] = PathMode.ro;

		auto bwrapPrefix = buildBwrapArgs(td.sandbox, chdir);

		// Pass workspace and working directory for agents that need them (Codex).
		sessionConfig.workspace = td.workspace;
		sessionConfig.workDir = chdir !is null ? chdir : "";

		td.session = taskAgent.createSession(tid, td.agentSessionId, bwrapPrefix, sessionConfig);

		// Track MCP config temp file for cleanup
		if (taskAgent.lastMcpConfigPath.length > 0)
			td.sandbox.tempFiles ~= taskAgent.lastMcpConfigPath;

		// Start watching the JSONL file for forkable UUIDs.
		// For resumed tasks agentSessionId is already set; for new tasks
		// it will be set later in tryExtractAgentSessionId which also calls this.
		if (td.agentSessionId.length > 0)
			startJsonlWatch(tid);

		td.session.onOutput = (string line) {
			broadcastTask(tid, line);

			import std.algorithm : canFind;
			if (line.canFind(`"type":"result"`) || line.canFind(`"type":"turn/result"`))
			{
				// Turn completed — no longer processing, but still alive.
				td.isProcessing = false;

				// Re-try JSONL watch if not yet established (Codex may
				// not have the file at session-start time).
				if (tid !in jsonlWatches && td.agentSessionId.length > 0)
					startJsonlWatch(tid);

				// Broadcast forkable UUIDs now that JSONL should exist.
				broadcastForkableUuidsFromFile(tid);

				// Capture the canonical result text for sub-task output.
				td.resultText = taskAgent.extractResultText(line);

				// For sub-tasks and continuations: close stdin so the process exits cleanly.
				// Interactive tasks stay open for user input — flag for attention.
				if (tid in pendingSubTasks || td.pendingContinuation.length > 0)
					td.session.closeStdin();
				else
				{
					td.needsAttention = true;
					td.notificationBody = td.resultText.length > 0 ? truncateTitle(td.resultText, 200) : extractLastAssistantText(tid);
				}
				broadcast(buildTasksList());
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
			cleanup(tasks[tid].sandbox);
			stopJsonlWatch(tid);

			// Force JSONL reload on next request_history so that
			// fork IDs from the file replace live-stream UUIDs.
			tasks[tid].history = DataVec();
			tasks[tid].historyLoaded = false;

			// Continuation: transition to successor instead of completing
			if (exitCode == 0 && tasks[tid].pendingContinuation.length > 0)
			{
				spawnContinuation(tid);
				return;
			}

			tasks[tid].status = exitCode == 0 ? "completed" : "failed";
			persistence.setStatus(tid, tasks[tid].status);

			// Read output file content (if any) — prefer it over stream result text.
			// The stream result text (agent's final message) is kept as the summary.
			string outputContent;
			if (tasks[tid].outputPath.length > 0)
			{
				import std.file : exists, readText;
				if (exists(tasks[tid].outputPath))
					outputContent = readText(tasks[tid].outputPath);
			}

			// Fulfill pending sub-task promise (if this is a child task)
			if (auto pending = tid in pendingSubTasks)
			{
				auto success = tasks[tid].status == "completed";
				auto mainResult = outputContent.length > 0
					? outputContent
					: (tasks[tid].resultText.length > 0 ? tasks[tid].resultText : "(no output)");
				auto taskResult = TaskResult(
					mainResult,
					tasks[tid].resultText,  // agent's final message (summary)
					tasks[tid].outputPath.length > 0 ? tasks[tid].outputPath : null,
					tasks[tid].hasWorktree ? tasks[tid].worktreePath : null,
				);
				auto resultJson = toJson(taskResult);
				pending.fulfill(McpResult(resultJson, !success, JSONFragment(resultJson)));
				pendingSubTasks.remove(tid);
			}

			// Store the best result text for UI display
			if (outputContent.length > 0)
				tasks[tid].resultText = outputContent;

			// Notify frontends to re-request history (in-memory history
			// already contains both JSONL and stdout-only messages like result).
			broadcast(toJson(TaskReloadMessage("task_reload", tid)));
			// No attention on exit — the session is over and there's
			// nothing for the user to act on.  Turn-complete attention
			// (in onOutput) is sufficient for interactive tasks.
			broadcast(buildTasksList());
		};

		td.alive = true;
		td.status = "active";
	}

	/// Transition a task to its successor via continuation.
	/// Called from onExit when pendingContinuation is set.
	///
	/// Two modes:
	///   keep_context: mutate task type in-place, resume the same session
	///   !keep_context: complete the current task normally, create a new child task
	private void spawnContinuation(int tid)
	{
		import ae.utils.json : toJson;

		auto td = &tasks[tid];
		auto typeDef = getTaskTypes().byName(td.taskType);
		auto contKey = td.pendingContinuation;
		auto hPrompt = td.handoffPrompt;
		td.pendingContinuation = null;
		td.handoffPrompt = null;

		if (typeDef is null)
		{
			writefln("spawnContinuation: unknown task type '%s' for tid=%d", td.taskType, tid);
			td.status = "failed";
			persistence.setStatus(tid, "failed");
			broadcast(buildTasksList());
			return;
		}

		auto contDefP = contKey in typeDef.continuations;
		if (contDefP is null)
		{
			writefln("spawnContinuation: unknown continuation '%s' for type '%s' tid=%d",
				contKey, td.taskType, tid);
			td.status = "failed";
			persistence.setStatus(tid, "failed");
			broadcast(buildTasksList());
			return;
		}
		auto contDef = *contDefP;

		auto newTypeDef = getTaskTypes().byName(contDef.task_type);
		if (newTypeDef is null)
		{
			writefln("spawnContinuation: unknown successor type '%s' for tid=%d", contDef.task_type, tid);
			td.status = "failed";
			persistence.setStatus(tid, "failed");
			broadcast(buildTasksList());
			return;
		}

		writefln("Continuation: tid=%d %s → %s (keep_context=%s)",
			tid, td.taskType, contDef.task_type, contDef.keep_context);

		if (contDef.keep_context)
		{
			// Mutate task type in-place, resume the same session
			td.taskType = contDef.task_type;
			persistence.setTaskType(tid, contDef.task_type);

			// Notify frontends to re-request history
			broadcast(toJson(TaskReloadMessage("task_reload", tid)));

			td.status = "active";
			persistence.setStatus(tid, "active");

			// Spawn successor session — will --resume the existing agentSessionId
			auto sessionConfig = SessionConfig(agentForTask(tid).resolveModelAlias(newTypeDef.model_class));
			sessionConfig.disallowedTools = disallowedTools();
			ensureTaskAgent(tid, sessionConfig);

			// Send the continuation's prompt template as first message to successor.
			if (td.session !is null)
			{
				auto renderedPrompt = renderContinuationPrompt(contDef,
					"Continue from where you left off.", taskTypesDir);
				broadcastUnconfirmedUserMessage(tid, renderedPrompt);
				sendTaskMessage(tid, renderedPrompt);
			}

			broadcast(buildTasksList());
		}
		else
		{
			// Complete the current task normally (preserving its history),
			// then create a new child task for the successor.
			td.status = "completed";
			persistence.setStatus(tid, "completed");

			// Notify frontends to re-request history
			broadcast(toJson(TaskReloadMessage("task_reload", tid)));

			// Create child task for the successor with the handoff prompt
			auto successorPrompt = hPrompt.length > 0 ? hPrompt : td.description;
			auto childTid = createTask(td.workspace, td.projectPath);
			auto childTd = &tasks[childTid];
			childTd.taskType = contDef.task_type;
			childTd.description = successorPrompt;
			childTd.parentTid = tid;
			childTd.relationType = "continuation";
			childTd.title = td.title;

			persistence.setTaskType(childTid, contDef.task_type);
			persistence.setDescription(childTid, successorPrompt);
			persistence.setParentTid(childTid, tid);
			persistence.setRelationType(childTid, "continuation");
			persistence.setTitle(childTid, childTd.title);

			broadcast(toJson(TaskCreatedMessage("task_created", childTid,
				td.workspace, td.projectPath, tid, "continuation")));

			// If this task was itself a pending sub-task, move the promise
			// to the new child so the parent awaits the full chain
			if (auto pending = tid in pendingSubTasks)
			{
				pendingSubTasks[childTid] = *pending;
				pendingSubTasks.remove(tid);
			}

			// Spawn the successor agent
			auto sessionConfig = SessionConfig(agentForTask(childTid).resolveModelAlias(newTypeDef.model_class));
			sessionConfig.disallowedTools = disallowedTools();
			ensureTaskAgent(childTid, sessionConfig);

			if (childTd.session !is null)
			{
				auto renderedPrompt = renderPrompt(*newTypeDef, successorPrompt,
					taskTypesDir, childTd.outputPath);
				broadcastUnconfirmedUserMessage(childTid, renderedPrompt);
				sendTaskMessage(childTid, renderedPrompt);
			}

			broadcast(buildTasksList());
		}
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
		import cydo.agent.protocol : translateClaudeEvent;

		// Extract agent session ID before translation (uses raw Claude format)
		if (tid in tasks && tasks[tid].agentSessionId.length == 0)
			tryExtractAgentSessionId(tid, rawLine);

		// Intercept queue-operation events for steering message handling
		if (isQueueOperation(rawLine))
		{
			if (auto td = tid in tasks)
			{
				import ae.utils.json : jsonParse;
				auto op = jsonParse!QueueOperationProbe(rawLine);
				if (op.operation == "enqueue")
				{
					td.enqueuedSteeringTexts ~= op.content;
					return; // already displayed via unconfirmedUserEvent
				}
				else if (op.operation == "dequeue")
				{
					if (td.enqueuedSteeringTexts.length > 0)
						td.enqueuedSteeringTexts = td.enqueuedSteeringTexts[1 .. $];
					return; // the real message/user follows
				}
				else if (op.operation == "remove")
				{
					if (td.enqueuedSteeringTexts.length > 0)
					{
						auto text = td.enqueuedSteeringTexts[0];
						td.enqueuedSteeringTexts = td.enqueuedSteeringTexts[1 .. $];
						// Broadcast synthetic steering confirmation
						auto now = Clock.currTime.toISOExtString();
						auto steeringEvent = buildSyntheticUserEvent(text, true);
						string injected = `{"tid":` ~ format!"%d"(tid)
							~ `,"timestamp":"` ~ now
							~ `","event":` ~ steeringEvent ~ `}`;
						auto data = Data(injected.representation);
						td.lastActivity = now;
						td.history ~= data;
						foreach (ws; clients)
							ws.send(data);
					}
					return;
				}
			}
			return; // unknown queue operation — consume silently
		}

		// Translate to agent-agnostic protocol
		auto translated = translateClaudeEvent(rawLine);
		if (translated is null)
			return; // consumed event, don't forward

		// Wrap the event with a task envelope including timestamp
		auto now = Clock.currTime.toISOExtString();
		string injected = `{"tid":` ~ format!"%d"(tid) ~ `,"timestamp":"` ~ now ~ `","event":` ~ translated ~ `}`;

		auto data = Data(injected.representation);

		if (tid in tasks)
		{
			tasks[tid].lastActivity = now;
			tasks[tid].history ~= data;
		}

		foreach (ws; clients)
			ws.send(data);
	}

	/// Try to extract agent session ID from an output line using the Agent interface.
	private void tryExtractAgentSessionId(int tid, string rawLine)
	{
		auto sessionId = agentForTask(tid).parseSessionId(rawLine);
		if (sessionId.length > 0)
		{
			tasks[tid].agentSessionId = sessionId;
			persistence.setAgentSessionId(tid, sessionId);
			startJsonlWatch(tid);
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
		if (tid in jsonlWatches)
			return; // already watching
		auto td = &tasks[tid];
		if (td.agentSessionId.length == 0)
			return;

		auto jsonlPath = agentForTask(tid).historyPath(td.agentSessionId, td.effectiveCwd);
		if (jsonlPath.length == 0)
			return; // path not yet known (e.g. Codex before file is created)

		if (exists(jsonlPath))
		{
			watchJsonlFile(tid, jsonlPath);
		}
		else
		{
			// File doesn't exist yet — watch directory for its creation.
			// The directory may not exist either (e.g. worktree paths that
			// Claude Code hasn't seen yet), so ensure it exists first.
			auto dirPath = dirName(jsonlPath);
			auto fileName = baseName(jsonlPath);
			import std.file : mkdirRecurse;
			mkdirRecurse(dirPath);
			jsonlWatches[tid] = rcINotify.add(dirPath, INotify.Mask.create,
				(in char[] name, INotify.Mask mask, uint cookie)
				{
					if (name == fileName)
					{
						// File appeared — switch to file watch
						if (auto h = tid in jsonlWatches)
						{
							rcINotify.remove(*h);
							jsonlWatches.remove(tid);
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

		jsonlWatches[tid] = rcINotify.add(jsonlPath, INotify.Mask.modify,
			(in char[] name, INotify.Mask mask, uint cookie)
			{
				processNewJsonlContent(tid, jsonlPath);
			}
		);
	}

	/// Read new content from the JSONL file and broadcast forkable UUIDs.
	private void processNewJsonlContent(int tid, string jsonlPath)
	{
		import std.file : exists, getSize;

		if (jsonlPath.length == 0 || !exists(jsonlPath))
			return;
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
		auto lineOffset = jsonlLineCount.get(tid, 0);
		auto uuids = agentForTask(tid).extractForkableIds(newContent, lineOffset);

		// Count lines in the new content to update cumulative offset
		import std.string : lineSplitter;
		int newLines = 0;
		foreach (_; newContent.lineSplitter)
			newLines++;
		jsonlLineCount[tid] = lineOffset + newLines;

		if (uuids.length > 0)
			broadcastForkableUuids(tid, uuids);
	}

	/// Send forkable UUIDs from the full JSONL file (used during history load).
	private void sendForkableUuidsFromFile(WebSocketAdapter ws, int tid,
		string agentSessionId, string projectPath)
	{
		import std.file : exists, readText;

		auto jsonlPath = agentForTask(tid).historyPath(agentSessionId, projectPath);
		if (jsonlPath.length == 0 || !exists(jsonlPath))
			return;

		auto content = readText(jsonlPath);
		auto uuids = agentForTask(tid).extractForkableIds(content);
		if (uuids.length > 0)
		{
			import ae.utils.json : toJson;
			ws.send(Data(toJson(ForkableUuidsMessage("forkable_uuids", tid, uuids)).representation));
		}
	}

	/// Broadcast forkable UUIDs from the full JSONL file to all clients.
	/// Broadcast forkable IDs from the JSONL file.
	/// For agents where the JSONL format differs from the protocol messages
	/// (e.g. Codex), this also reloads the in-memory history from the JSONL
	/// so that message UUIDs match the fork IDs.
	private void broadcastForkableUuidsFromFile(int tid)
	{
		import std.file : exists, readText;

		if (tid !in tasks)
			return;
		auto td = &tasks[tid];
		if (td.agentSessionId.length == 0)
			return;

		auto ta = agentForTask(tid);
		auto jsonlPath = ta.historyPath(td.agentSessionId, td.effectiveCwd);
		if (jsonlPath.length == 0 || !exists(jsonlPath))
			return;

		auto uuids = ta.extractForkableIds(readText(jsonlPath));
		if (uuids.length > 0)
			broadcastForkableUuids(tid, uuids);
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
		if (auto h = tid in jsonlWatches)
		{
			rcINotify.remove(*h);
			jsonlWatches.remove(tid);
		}
		jsonlReadPos.remove(tid);
		jsonlLineCount.remove(tid);
	}

	/// Spawn a lightweight claude process to generate a concise title
	/// from the user's initial message.
	private void generateTitle(int tid, string userMessage)
	{
		auto td = &tasks[tid];

		if (td.titleGenDone || td.titleGenHandle !is null)
			return;

		td.titleGenHandle = agentForTask(tid).generateTitle(userMessage, (string title) {
			if (tid !in tasks)
				return;
			tasks[tid].titleGenHandle = null;
			tasks[tid].titleGenDone = true;
			tasks[tid].title = title;
			persistence.setTitle(tid, title);
			broadcastTitleUpdate(tid, title);
		});
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
			entries ~= TaskListEntry(td.tid, td.alive, td.agentSessionId.length > 0 && !td.alive,
				td.isProcessing, td.needsAttention, td.notificationBody,
				td.lastActivity, td.title, td.workspace, td.projectPath, td.parentTid, td.relationType, td.status,
				td.taskType, td.agentType);
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
		foreach (ref def; getTaskTypes())
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
				auto text = agentForTask(tid).extractAssistantText(event);
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
	string agentSessionId;
	string description;
	string taskType = "conversation";
	string agentType = "claude";
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

	/// Output file path: .cydo/tasks/<tid>/output.md
	@property string outputPath() const
	{
		if (taskDir.length == 0)
			return "";
		import std.path : buildPath;
		return buildPath(taskDir, "output.md");
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
	string pendingContinuation; // continuation key set by SwitchMode/Handoff, consumed by onExit
	string handoffPrompt;      // prompt for the successor task (Handoff only)
	bool titleGenDone; // true after LLM title generation completed
	Object titleGenHandle; // prevent GC while running
	string[] enqueuedSteeringTexts; // stash of enqueued steering message texts
}

struct TaskHistoryEndMessage
{
	string type = "task_history_end";
	int tid;
}

/// Check if a raw line is a queue-operation event (fast string search).
private bool isQueueOperation(string line)
{
	import std.algorithm : canFind;
	return line.canFind(`"queue-operation"`);
}

/// Parsed queue-operation fields.
@JSONPartial
private struct QueueOperationProbe
{
	string type;
	string operation;
	string content;
}

/// Build a synthetic message/user JSON string with optional flags.
private string buildSyntheticUserEvent(string text,
	bool isSteering = false, bool pending = false)
{
	import ae.utils.json : toJson;
	auto contentJson = toJson(text);
	string extra;
	if (isSteering) extra ~= `,"isSteering":true`;
	if (pending) extra ~= `,"pending":true`;
	return `{"type":"message/user","message":{"role":"user","content":`
		~ contentJson ~ `}` ~ extra ~ `}`;
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
	string agent_type;
	bool dry_run;
	bool revert_conversation;
	bool revert_files;
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
	string task_type;
	string agent_type;
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

struct UndoPreviewMessage
{
	string type = "undo_preview";
	int tid;
	int messages_removed;
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

/// Structured result returned to the parent agent as JSON via MCP.
struct TaskResult
{
	string result;          // main output text (output file content, or final message if no file)
	string summary;         // agent's final message (one-sentence summary)
	string output_file;     // path to output artifact, if any
	string worktree;        // path to worktree, if any
}

struct McpContentItem
{
	string type;
	string text;
}

struct McpContentResult
{
	import ae.utils.json : JSONOptional;

	McpContentItem[] content;
	bool isError;
	@JSONOptional JSONFragment structuredContent;
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
