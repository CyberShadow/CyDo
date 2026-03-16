module cydo.app;

import core.lifetime : move;

import std.datetime : Clock;
import std.file : exists, isFile;
import std.format : format;
import std.stdio : File, stderr;
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
	renderPrompt, renderContinuationPrompt, substituteVars, formatCreatableTaskTypes, formatSwitchModes, formatHandoffs, disallowedTools;
import cydo.task;

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
	import cydo.jsonl : JsonlTracker;

	private HttpServer server;
	private HttpServer mcpServer; // UNIX socket for MCP proxy calls (no auth)
	private string mcpSocketPath;
	private WebSocketAdapter[] clients;
	/// Per-client subscription set: which tasks each client receives live events for.
	/// INVARIANT: subscription ≡ request_history. A client is subscribed only
	/// after receiving the full history buffer. Resetting history (agent exit,
	/// undo) unsubscribes all clients, forcing re-subscription via request_history.
	private bool[int][WebSocketAdapter] clientSubscriptions;
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
	// JSONL file tracking state
	private JsonlTracker jsonlTracker;
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
				stderr.writefln("  WARN: task type: %s", e);
			taskTypesCache = types;
			return taskTypesCache;
		}
		catch (Exception e)
		{
			stderr.writefln("Warning: task types file changed but failed to parse, keeping previous version: %s", e.msg);
			return taskTypesCache;
		}
	}

	void start()
	{
		persistence = Persistence("data/cydo.db");
		config = loadConfig();
		agent = createAgent(config.default_agent_type);
		agentsByType[config.default_agent_type] = agent;

		jsonlTracker.getAgent = &agentForTask;
		jsonlTracker.getTask = (int tid) => tid in tasks ? &tasks[tid] : null;
		jsonlTracker.broadcast = &broadcast;

		// Load task type definitions
		auto types = getTaskTypes();
		if (types.length == 0)
			stderr.writefln("Warning: no task types loaded");
		else
			stderr.writefln("Loaded %d task types", types.length);

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
		stderr.writefln("CyDo server listening on %s://localhost:%d", proto, port);

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
		stderr.writefln("MCP socket listening on %s", mcpSocketPath);
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
		import std.conv : to;

		// Reject tool calls after SwitchMode/Handoff — the agent must yield.
		if (auto tdp = to!int(tid) in tasks)
		{
			if (tdp.pendingContinuation.length > 0)
				return resolve(McpResult(
					"Tool call rejected: you already called SwitchMode/Handoff. "
					~ "Yield your turn immediately — do not make any more tool calls.",
					true));
		}

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
		import std.algorithm : canFind, map;
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

		// Validate task_type against parent's creatable_tasks and resolve alias
		auto parentTypeDef = getTaskTypes().byName(parentTd.taskType);
		string resolvedTaskType = taskType;
		if (parentTypeDef !is null &&
			parentTypeDef.creatable_tasks.length > 0)
		{
			auto edge = parentTypeDef.creatable_tasks.byName(taskType);
			if (edge is null)
			{
				return resolve(McpResult(
					"Task type '" ~ taskType ~ "' is not in creatable_tasks for '" ~
					parentTd.taskType ~ "'. Allowed: " ~
					parentTypeDef.creatable_tasks.map!(c => c.name).join(", "), true));
			}
			resolvedTaskType = edge.resolvedType;
		}

		// Validate child task type exists
		auto childTypeDef = getTaskTypes().byName(resolvedTaskType);
		if (childTypeDef is null)
			return resolve(McpResult("Unknown task type: " ~ resolvedTaskType, true));

		// Create child task
		auto childTid = createTask(parentTd.workspace, parentTd.projectPath);
		auto childTd = &tasks[childTid];
		childTd.taskType = resolvedTaskType;
		childTd.description = prompt;
		childTd.parentTid = parentTid;
		childTd.relationType = "subtask";
		childTd.title = description.length > 0
			? description
			: truncateTitle(prompt, 80);

		// Persist metadata
		persistence.setTaskType(childTid, resolvedTaskType);
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

		// Set up worktree from edge config: create new or inherit from parent
		string edgeTemplate;
		if (parentTypeDef !is null)
		{
			if (auto edge = parentTypeDef.creatable_tasks.byName(taskType))
			{
				edgeTemplate = edge.prompt_template;
				childTd.resultNote = substituteVars(edge.result_note,
					["output_dir": parentTd.taskDir]);
				if (edge.worktree)
					setupWorktree(childTid, true);
				else if (parentTd.hasWorktree)
					setupWorktree(childTid, false, parentTd.worktreePath);
			}
		}

		// Configure and spawn child agent
		auto sessionConfig = SessionConfig(
			agentForTask(childTid).resolveModelAlias(childTypeDef.model_class),
		);
		sessionConfig.disallowedTools = disallowedTools();
		ensureTaskAgent(childTid, sessionConfig);

		// Send rendered prompt template as first user message
		if (childTd.session !is null)
		{
			auto renderedPrompt = renderPrompt(*childTypeDef, prompt, taskTypesDir, childTd.outputPath, edgeTemplate);
			broadcastUnconfirmedUserMessage(childTid, renderedPrompt);
			sendTaskMessage(childTid, renderedPrompt);
		}

		if (description.length == 0)
			generateTitle(childTid, prompt);
		stderr.writefln("Task: tid=%d type=%s parent=%d", childTid, resolvedTaskType, parentTid);

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
		stderr.writefln("SwitchMode: tid=%d continuation=%s (type %s → %s)",
			tid, continuation, td.taskType, contDef.task_type);

		return McpResult(
			"Mode switch to '" ~ contDef.task_type ~ "' accepted. "
			~ "Yield your turn IMMEDIATELY — do not call any more tools or generate output. "
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
		stderr.writefln("Handoff: tid=%d continuation=%s (type %s → %s)",
			tid, continuation, td.taskType, contDef.task_type);

		return McpResult(
			"Handoff to '" ~ contDef.task_type ~ "' accepted. "
			~ "Yield your turn IMMEDIATELY — do not call any more tools or generate output. "
			~ "A new task will be created with your prompt. Your session is ending.");
	}

	private void handleWsMessage(WebSocketAdapter ws, string text)
	{
		import ae.utils.json : jsonParse;
		auto json = jsonParse!WsMessage(text);

		switch (json.type)
		{
			case "create_task":       handleCreateTaskMsg(ws, json); break;
			case "request_history":   handleRequestHistory(ws, json); break;
			case "message":           handleUserMessage(json); break;
			case "resume":            handleResumeMsg(json); break;
			case "interrupt":         handleInterruptMsg(json); break;
			case "sigint":            handleSigintMsg(json); break;
			case "close_stdin":       handleCloseStdinMsg(json); break;
			case "stop":              handleStopMsg(json); break;
			case "dismiss_attention": handleDismissAttention(json); break;
			case "fork_task":         handleForkTaskMsg(ws, json); break;
			case "undo_task":         handleUndoTaskMsg(ws, json); break;
			default: break;
		}
	}

	private void handleCreateTaskMsg(WebSocketAdapter ws, WsMessage json)
	{
		import ae.utils.json : toJson;

		auto at = json.agent_type.length > 0 ? json.agent_type : config.default_agent_type;
		auto tid = createTask(json.workspace, json.project_path, at);
		if (json.task_type.length > 0 && getTaskTypes().byName(json.task_type) !is null)
		{
			tasks[tid].taskType = json.task_type;
			persistence.setTaskType(tid, json.task_type);
		}
		// Send task_created only to the requesting client (unicast) so that
		// parallel test workers don't steal each other's task IDs.
		ws.send(Data(toJson(TaskCreatedMessage("task_created", tid, json.workspace, json.project_path, 0, "")).representation));
		// Broadcast updated task list so all other clients see the new task.
		broadcast(buildTasksList());

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

	private void handleRequestHistory(WebSocketAdapter ws, WsMessage json)
	{
		import ae.utils.json : toJson;

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
			string lastDequeuedText;
			td.history = loadTaskHistory(tid, jsonlPath, delegate string[](string line, int lineNum) {
				if (isQueueOperation(line))
				{
					import ae.utils.json : jsonParse;
					auto op = jsonParse!QueueOperationProbe(line);
					if (op.operation == "enqueue")
					{
						steeringStash ~= op.content;
						return [buildSyntheticUserEvent(op.content, false, true)];
					}
					else if (op.operation == "dequeue")
					{
						string[] result;
						// Flush any deferred synthetic from a prior dequeue
						// (handles compacted back-to-back dequeues)
						if (lastDequeuedText.length > 0)
						{
							result ~= buildSyntheticUserEvent(lastDequeuedText);
							lastDequeuedText = null;
						}
						if (steeringStash.length > 0)
						{
							lastDequeuedText = steeringStash[0];
							steeringStash = steeringStash[1 .. $];
							// Defer: wait to see if type:"user" echo follows
						}
						return result;
					}
					else if (op.operation == "remove")
					{
						if (steeringStash.length > 0)
						{
							auto text = steeringStash[0];
							steeringStash = steeringStash[1 .. $];
							return [buildSyntheticUserEvent(text, true)];
						}
						return [];
					}
					return []; // unknown queue operation
				}
				// Deferred compaction check: if a type:"user" echo follows the
				// dequeue, pass it through with its UUID intact (non-compacted).
				// Neutral lines (file-history-snapshot, progress, etc.) pass through
				// without leaving deferred mode — they can appear between dequeue and
				// the user echo. Only type:"assistant" confirms compaction and triggers
				// synthetic emission.
				if (lastDequeuedText.length > 0)
				{
					if (isUserMessageLine(line))
					{
						// Non-compacted: type:"user" echo present — pass through with UUID
						lastDequeuedText = null;
						auto t = ta.translateHistoryLine(line, lineNum);
						return t !is null ? [t] : [];
					}
					if (isAssistantMessageLine(line))
					{
						// Compacted: assistant response appeared without preceding user echo —
						// emit synthetic before the assistant line.
						auto synthetic = buildSyntheticUserEvent(lastDequeuedText);
						lastDequeuedText = null;
						auto t = ta.translateHistoryLine(line, lineNum);
						return t !is null ? [synthetic, t] : [synthetic];
					}
					// Neutral line (file-history-snapshot, progress, etc.) — pass through,
					// stay in deferred mode waiting for type:"user" or type:"assistant".
					auto t = ta.translateHistoryLine(line, lineNum);
					return t !is null ? [t] : [];
				}
				auto t = ta.translateHistoryLine(line, lineNum);
				return t !is null ? [t] : [];
			});
			td.historyLoaded = true;
		}

		// Send unified history to requesting client
		foreach (msg; td.history)
			ws.send(msg);

		// Send forkable UUIDs extracted from JSONL
		if (td.agentSessionId.length > 0)
			jsonlTracker.sendForkableUuidsFromFile(ws, tid, td.agentSessionId, td.effectiveCwd);

		// Send end marker
		ws.send(Data(toJson(TaskHistoryEndMessage("task_history_end", tid)).representation));

		// Subscribe client to live events for this task
		clientSubscriptions.require(ws)[tid] = true;
	}

	private void handleUserMessage(WsMessage json)
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

	private void handleResumeMsg(WsMessage json)
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
		// Resumed session is immediately idle — generate suggestions.
		try
			generateSuggestions(tid);
		catch (Exception e)
			stderr.writeln("Error generating suggestions: ", e);
	}

	private void handleInterruptMsg(WsMessage json)
	{
		auto tid = json.tid;
		if (tid < 0 || tid !in tasks)
			return;
		auto td = &tasks[tid];
		if (td.session)
			td.session.interrupt();
	}

	private void handleSigintMsg(WsMessage json)
	{
		auto tid = json.tid;
		if (tid < 0 || tid !in tasks)
			return;
		auto td = &tasks[tid];
		if (td.session)
			td.session.sigint();
	}

	private void handleCloseStdinMsg(WsMessage json)
	{
		auto tid = json.tid;
		if (tid < 0 || tid !in tasks)
			return;
		auto td = &tasks[tid];
		if (td.session)
			td.session.closeStdin();
	}

	private void handleStopMsg(WsMessage json)
	{
		auto tid = json.tid;
		if (tid < 0 || tid !in tasks)
			return;
		auto td = &tasks[tid];
		if (td.session)
			td.session.stop();
	}

	private void handleDismissAttention(WsMessage json)
	{
		auto tid = json.tid;
		if (tid >= 0 && tid in tasks)
		{
			tasks[tid].needsAttention = false;
			tasks[tid].notificationBody = "";
			broadcast(buildTasksList());
		}
	}

	private void handleForkTaskMsg(WebSocketAdapter ws, WsMessage json)
	{
		import ae.utils.json : toJson;

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

	private void handleUndoTaskMsg(WebSocketAdapter ws, WsMessage json)
	{
		import ae.utils.json : toJson;

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
				unsubscribeAll(tid);
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
				try
					generateSuggestions(tid);
				catch (Exception e)
					stderr.writeln("Error generating suggestions: ", e);
			}

			broadcast(buildTasksList());
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
		td.suggestGenHandle = null; // cancel any in-flight suggestion generation
		td.suggestGeneration++;
		broadcast(buildTasksList());
	}

	private int createTask(string workspace = "", string projectPath = "", string agentType = "claude")
	{
		auto tid = persistence.createTask(workspace, projectPath, agentType);
		auto td = TaskData(tid);
		td.workspace = workspace;
		td.projectPath = projectPath;
		td.agentType = agentType;
		td.historyLoaded = true; // New tasks have no JSONL to load
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

	/// Set up a worktree for a task: either create a new git worktree or
	/// inherit an existing one from a predecessor/parent via symlink.
	private void setupWorktree(int tid, bool createNew, string inheritFrom = "")
	{
		auto td = &tasks[tid];
		if (td.hasWorktree || td.taskDir.length == 0)
			return;

		import std.file : mkdirRecurse;
		import std.path : buildPath;

		mkdirRecurse(td.taskDir);

		if (createNew)
		{
			import std.process : execute;
			auto wtPath = buildPath(td.taskDir, "worktree");
			auto workDir = td.projectPath.length > 0 ? td.projectPath : null;
			auto gitResult = execute(["git", "-C", workDir, "worktree", "add", "--detach", wtPath]);
			if (gitResult.status == 0)
			{
				td.hasWorktree = true;
				persistence.setHasWorktree(td.tid, true);
				stderr.writefln("Created worktree for task %d: %s", td.tid, wtPath);
			}
			else
				stderr.writefln("Failed to create worktree for task %d: %s", td.tid, gitResult.output);
		}
		else if (inheritFrom.length > 0)
		{
			import std.file : symlink;
			auto wtPath = buildPath(td.taskDir, "worktree");
			symlink(inheritFrom, wtPath);
			td.hasWorktree = true;
			persistence.setHasWorktree(td.tid, true);
			stderr.writefln("Inherited worktree for task %d: %s → %s", td.tid, wtPath, inheritFrom);
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
			jsonlTracker.startJsonlWatch(tid);

		td.session.onOutput = (string line) {
			broadcastTask(tid, line);

			import std.algorithm : canFind;
			if (line.canFind(`"type":"result"`) || line.canFind(`"type":"turn/result"`))
			{
				// Turn completed — no longer processing, but still alive.
				td.isProcessing = false;

				// Re-try JSONL watch if not yet established (Codex may
				// not have the file at session-start time).
				jsonlTracker.startJsonlWatch(tid);

				// Broadcast forkable UUIDs now that JSONL should exist.
				jsonlTracker.broadcastForkableUuidsFromFile(tid);

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
					try
						generateSuggestions(tid);
					catch (Exception e)
						stderr.writeln("Error generating suggestions: ", e);
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
			jsonlTracker.stopJsonlWatch(tid);

			// Force JSONL reload on next request_history so that
			// fork IDs from the file replace live-stream UUIDs.
			tasks[tid].history = DataVec();
			tasks[tid].historyLoaded = false;
			unsubscribeAll(tid);

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
				auto taskResult = TaskResult(
					tasks[tid].resultText,
					tasks[tid].outputPath.length > 0 ? tasks[tid].outputPath : null,
					tasks[tid].hasWorktree ? tasks[tid].worktreePath : null,
					tasks[tid].resultNote,
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
			stderr.writefln("spawnContinuation: unknown task type '%s' for tid=%d", td.taskType, tid);
			td.status = "failed";
			persistence.setStatus(tid, "failed");
			broadcast(buildTasksList());
			return;
		}

		auto contDefP = contKey in typeDef.continuations;
		if (contDefP is null)
		{
			stderr.writefln("spawnContinuation: unknown continuation '%s' for type '%s' tid=%d",
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
			stderr.writefln("spawnContinuation: unknown successor type '%s' for tid=%d", contDef.task_type, tid);
			td.status = "failed";
			persistence.setStatus(tid, "failed");
			broadcast(buildTasksList());
			return;
		}

		stderr.writefln("Continuation: tid=%d %s → %s (keep_context=%s)",
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

			// Set up worktree from edge config: create new or inherit from predecessor
			if (contDef.worktree)
				setupWorktree(childTid, true);
			else if (td.hasWorktree)
				setupWorktree(childTid, false, td.worktreePath);

			// Spawn the successor agent
			auto sessionConfig = SessionConfig(agentForTask(childTid).resolveModelAlias(newTypeDef.model_class));
			sessionConfig.disallowedTools = disallowedTools();
			ensureTaskAgent(childTid, sessionConfig);

			if (childTd.session !is null)
			{
				auto renderedPrompt = renderPrompt(*newTypeDef, successorPrompt,
					taskTypesDir, childTd.outputPath, contDef.prompt_template);
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

	/// Send data to all clients subscribed to the given task.
	private void sendToSubscribed(int tid, Data data)
	{
		foreach (ws; clients)
			if (auto subs = ws in clientSubscriptions)
				if (tid in *subs)
					ws.send(data);
	}

	/// Unsubscribe all clients from a task's live events.
	/// Used when resetting history — forces clients to re-subscribe
	/// via request_history.
	private void unsubscribeAll(int tid)
	{
		foreach (ws; clients)
			if (auto subs = ws in clientSubscriptions)
				(*subs).remove(tid);
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

		sendToSubscribed(tid, data);
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
						sendToSubscribed(tid, data);
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

		sendToSubscribed(tid, data);
	}

	/// Try to extract agent session ID from an output line using the Agent interface.
	private void tryExtractAgentSessionId(int tid, string rawLine)
	{
		auto sessionId = agentForTask(tid).parseSessionId(rawLine);
		if (sessionId.length > 0)
		{
			tasks[tid].agentSessionId = sessionId;
			persistence.setAgentSessionId(tid, sessionId);
			jsonlTracker.startJsonlWatch(tid);
		}
	}

	private void broadcastTitleUpdate(int tid, string title)
	{
		import ae.utils.json : toJson;
		broadcast(toJson(TitleUpdateMessage("title_update", tid, title)));
	}

	private void broadcastSuggestionsUpdate(int tid, string[] suggestions, uint generation)
	{
		import ae.utils.json : toJson;
		broadcast(toJson(SuggestionsUpdateMessage("suggestions_update", tid, suggestions, generation)));
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

			stderr.writefln("Workspace '%s' (%s): %d project(s)", ws.name, ws.root, projects.length);
			foreach (ref p; projects)
				stderr.writefln("  - %s (%s)", p.name, p.path);
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
			stderr.writefln("Config directory %s does not exist, skipping config watch", cfgDir);
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
		stderr.writefln("Config file changed, reloading...");
		auto result = reloadConfig();
		if (result.isNull())
		{
			stderr.writefln("  Config reload failed (parse error), keeping current config");
			return;
		}
		config = result.get();
		discoverAllWorkspaces();
		broadcast(buildWorkspacesList());
		stderr.writefln("  Config reloaded successfully");
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
				entries ~= TaskTypeListEntry(def.name, def.display_name, def.description, def.model_class, def.read_only);
		return toJson(TaskTypesListMessage("task_types_list", entries));
	}

	private void removeClient(WebSocketAdapter ws)
	{
		import std.algorithm : remove;
		clients = clients.remove!(c => c is ws);
		clientSubscriptions.remove(ws);
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

	private bool hasSubscribers(int tid)
	{
		foreach (ws; clients)
			if (auto subs = ws in clientSubscriptions)
				if (tid in *subs)
					return true;
		return false;
	}

	private void generateSuggestions(int tid)
	{
		if (tid !in tasks)
			return;
		auto td = &tasks[tid];

		// Only generate for interactive (non-sub-task) sessions
		if (td.parentTid != 0)
			return;

		// Only generate when someone is actually viewing this task
		if (!hasSubscribers(tid))
			return;

		auto history = buildAbbreviatedHistory(tid);
		if (history.length == 0)
			return;

		td.suggestGeneration++;
		auto capturedGen = td.suggestGeneration;

		td.suggestGenHandle = agentForTask(tid).generateSuggestions(history,
			(string[] suggestions) {
				if (tid !in tasks)
					return;
				if (tasks[tid].suggestGeneration != capturedGen)
					return; // stale result from a prior subprocess
				tasks[tid].suggestGenHandle = null;
				broadcastSuggestionsUpdate(tid, suggestions, capturedGen);
			});
	}

	/// Build an abbreviated conversation history string for suggestion generation.
	private string buildAbbreviatedHistory(int tid)
	{
		if (tid !in tasks)
			return "";

		auto taskAgent = agentForTask(tid);

		string[] entries;
		size_t totalLen = 0;
		enum maxLen = 10_000;
		enum truncThreshold = 256;

		foreach_reverse (ref d; tasks[tid].history)
		{
			auto envelope = cast(string) d.toGC();
			auto event = extractEventFromEnvelope(envelope);
			if (event.length == 0)
				event = extractFileEventFromEnvelope(envelope);
			if (event.length == 0)
				continue;

			string entry;

			auto userText = taskAgent.extractUserText(event);
			if (userText.length > 0)
			{
				entry = "USER: " ~ abbreviateText(userText, truncThreshold);
			}
			else
			{
				auto assistantText = taskAgent.extractAssistantText(event);
				if (assistantText.length > 0)
				{
					entry = "A: " ~ abbreviateText(assistantText, truncThreshold);
				}
				else
				{
					auto resultText = taskAgent.extractResultText(event);
					if (resultText.length > 0)
					{
						entry = "A: " ~ abbreviateText(resultText, truncThreshold);
					}
					else
					{
						import std.algorithm : canFind;
						if (event.canFind(`"tool_use"`) || event.canFind(`"tool_result"`))
						{
							if (entries.length > 0 && entries[$ - 1].length > 1
								&& entries[$ - 1][0] == '[')
							{
								import std.conv : to;
								import std.string : indexOf;
								auto bracket = entries[$ - 1].indexOf(' ');
								if (bracket > 1)
								{
									try
									{
										auto count = entries[$ - 1][1 .. bracket].to!int + 1;
										entries[$ - 1] = "[" ~ count.to!string ~ " tool calls]";
									}
									catch (Exception) {}
								}
								continue;
							}
							entry = "[1 tool calls]";
						}
						else
							continue;
					}
				}
			}

			totalLen += entry.length;
			if (totalLen > maxLen)
				break;

			entries ~= entry;
		}

		import std.algorithm : reverse;
		entries.reverse();

		foreach (ref e; entries)
			if (e == "[1 tool calls]")
				e = "[1 tool call]";

		import std.array : join;
		return entries.join("\n\n");
	}

	private static string abbreviateText(string text, size_t threshold)
	{
		import std.regex : replaceAll;
		import ae.utils.regex : re;

		text = text.replaceAll(re!`\s+`, " ");
		if (text.length <= threshold)
			return text;
		auto keepEach = threshold / 2 - 3;
		return text[0 .. keepEach] ~ " [...] " ~ text[$ - keepEach .. $];
	}
}

