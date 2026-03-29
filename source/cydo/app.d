module cydo.app;

import core.lifetime : move;

import std.file : exists, isFile, thisExePath;
import std.format : format;
import std.logger : tracef, infof, warningf, errorf, fatalf;
import std.stdio : File, stderr;
import std.string : representation;

import ae.utils.funopt : funopt, funoptDispatch, funoptDispatchUsage, FunOptConfig, Parameter;
import ae.utils.main : main;

import ae.net.asockets : socketManager, DisconnectType;
import ae.net.http.common : HttpRequest, HttpStatusCode;
import ae.net.http.responseex : HttpResponseEx;
import ae.net.http.server : HttpServer, HttpServerConnection, HttpsServer;
import ae.net.http.websocket : WebSocketAdapter, accept;
import ae.net.ssl.openssl;
import ae.sys.data : Data;
import ae.sys.dataset : DataVec;
import ae.sys.pidfile : createPidFile;
import ae.utils.json : JSONFragment, JSONPartial, jsonParse, toJson;
import ae.utils.promise : Promise, resolve, reject;
import ae.utils.promise.concurrency : threadAsync;
import ae.utils.statequeue : StateQueue;

mixin SSLUseLib;

import cydo.mcp : McpResult;
import cydo.mcp.tools : AskQuestion, ToolsBackend;

import cydo.agent.agent : Agent, DiscoveredSession, SessionConfig, SessionMeta;
import cydo.agent.protocol : ContentBlock, extractContentText;
import cydo.agent.session : AgentSession;
import cydo.config : AgentConfig, CydoConfig, PathMode, SandboxConfig, WorkspaceConfig, loadConfig, reloadConfig;
import cydo.persist : ForkResult, Persistence, countLinesAfterForkId,
	editJsonlMessage, forkTask, lastForkIdInJsonl, loadTaskHistory, truncateJsonl;
import cydo.sandbox : ResolvedSandbox, buildCommandPrefix, cleanup, cydoBinaryDir, cydoBinaryPath,
	resolveSandbox, resolveSandboxForDiscovery, runtimeDir;
import cydo.tasktype : TaskTypeDef, ContinuationDef, OutputType, byName, isInteractive, loadTaskTypes, validateTaskTypes,
	renderPrompt, renderContinuationPrompt, substituteVars, formatCreatableTaskTypes, formatSwitchModes, formatHandoffs,
	loadSystemPrompt;
import cydo.task;
import cydo.worktree;

@(`CyDo backend and tooling.`)
struct Program
{
static:
	@(`Start the CyDo backend.`)
	void server()
	{
		auto app = new App();
		app.start();

		// On SIGTERM, terminate all agent sessions so child processes flush their
		// persistent state before the backend exits.  ae.net.shutdown delivers the
		// callback inside the event loop thread, so we can use normal async stop().
		// Once children exit, their pipe FileConnections close and the event loop
		// drains naturally.  alarm() is a safety net in case a child hangs.
		import ae.net.shutdown : addShutdownHandler;
		addShutdownHandler((scope const(char)[]) {
			app.shutdown();
			import core.sys.posix.unistd : alarm;
			alarm(2);
		});

		socketManager.loop();
	}

	@(`Run the MCP server.`)
	void mcpServer()
	{
		import cydo.mcp.server : runMcpServer;
		runMcpServer();
	}

	@(`Simulate task type workflow.`)
	void simulate(Parameter!(string, "Path to task-types YAML file.") typesYaml)
	{
		import cydo.tasktype : runSimulator;
		runSimulator(typesYaml);
	}

	@(`Generate Graphviz dot output for task types.`)
	void dot(Parameter!(string, "Path to task-types YAML file.") typesYaml)
	{
		import cydo.tasktype : runDot;
		runDot(typesYaml);
	}

	@(`Dump agent context for a task type.`)
	void dumpContext(
		Parameter!(string, "Path to task-types YAML file.") typesYaml,
		Parameter!(string, "Task type name.") typeName,
	)
	{
		import cydo.tasktype : runDumpContext;
		runDumpContext(typesYaml, typeName);
	}

	@(`Discover projects in a workspace.`)
	void discover(
		Parameter!(string, "Workspace root path.") root,
		Parameter!(string, "Workspace name.") name,
		Parameter!(string, "is_project expression (JSON).") isProjectJson,
		Parameter!(string, "recurse_when expression (JSON).") recurseWhenJson,
		Parameter!(immutable(string)[], "Patterns to exclude.") exclude = null,
	)
	{
		import cydo.discover : runDiscover;
		runDiscover(root, name, isProjectJson, recurseWhenJson, cast(string[]) exclude);
	}
}

void usageFun(string usage)
{
	stderr.writeln(usage, funoptDispatchUsage!Program);
}

void dispatch(
	Parameter!(string, "Action to perform (see list below)") action = "server",
	immutable(string)[] actionArguments = null,
)
{
	funoptDispatch!Program([thisExePath, action] ~ actionArguments);
}

void run(string[] args)
{
	funopt!(dispatch, FunOptConfig.init, usageFun)(args);
}

mixin main!run;

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
	private enum taskTypesDir = "defs";
	private enum taskTypesPath = "defs/task-types.yaml";
	// Pending sub-task promises (childTid → promise fulfilled on task exit)
	private Promise!(McpResult)[int] pendingSubTasks;
	// In-memory mirror of task_deps table (childTid → parentTid)
	private int[int] taskDeps;
	// Pending AskUserQuestion promises (tid -> promise fulfilled when user responds)
	private Promise!(McpResult)[int] pendingAskUserQuestions;
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
	// Set during SIGTERM shutdown — suppress onExit status updates so tasks
	// stay "alive" in the DB and can be resumed after restart.
	private bool shuttingDown;

	/// Result from background discovery thread for a single session.
	private struct DiscoveryResult
	{
		string agentType;
		string sessionId;
		long mtime;
		string enumProjectPath; // from enumerateAllSessions (best-effort, may be empty)
		// Metadata — either from cache hit or from readSessionMeta call
		string title;
		string projectPath;
		bool fromCache;
	}

	private TaskTypeDef[] getTaskTypes()
	{
		import std.path : buildPath, expandTilde;
		try
		{
			auto userTypesPath = buildPath(expandTilde("~/.config/cydo"), "task-types.yaml");
			auto types = loadTaskTypes(taskTypesPath, userTypesPath);
			auto errors = validateTaskTypes(types, taskTypesDir);
			foreach (e; errors)
				warningf("task type: %s", e);
			taskTypesCache = types;
			return taskTypesCache;
		}
		catch (Exception e)
		{
			warningf("task types file changed but failed to parse, keeping previous version: %s", e.msg);
			return taskTypesCache;
		}
	}

	void start()
	{
		initLogLevel();
		persistence = Persistence("data/cydo.db");
		createPidFile("cydo.pid", "data/");
		config = loadConfig();
		agent = createAgent(config.default_agent_type);
		if (auto ac = config.default_agent_type in config.agents)
			agent.setModelAliases(ac.model_aliases);
		{
			import cydo.agent.copilot : CopilotAgent;
			if (auto ca = cast(CopilotAgent) agent)
				ca.toolDispatch_ = (string tool, string callerTid, JSONFragment args) =>
					dispatchTool(tool, callerTid, args);
		}
		agentsByType[config.default_agent_type] = agent;

		jsonlTracker.getAgent = &agentForTask;
		jsonlTracker.getTask = (int tid) => tid in tasks ? &tasks[tid] : null;
		jsonlTracker.broadcast = &broadcast;

		// Load task type definitions
		auto types = getTaskTypes();
		if (types.length == 0)
			warningf("no task types loaded");
		else
			infof("Loaded %d task types", types.length);

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
			td.archived = row.archived;
			td.draft = row.draft;
			td.resultText = row.resultText;
			td.createdAt = row.createdAt;
			td.lastActive = row.lastActive;
			td.titleGenDone = row.title.length > 0;
			auto rowTid = row.tid;
			tasks[rowTid] = move(td);
			tasks[rowTid].processQueue = new StateQueue!ProcessState(
				makeProcessQueueSF(rowTid),
				ProcessState.Dead,
			);
		}

		// Internal UNIX socket for MCP proxy calls (no auth required).
		// Must run before resumeInFlightTasks so mcpSocketPath is set
		// when generating MCP configs for auto-resumed sessions.
		startMcpSocket();

		resumeInFlightTasks();

		// Recover last_active from .jsonl mtime for tasks that were alive
		// when the backend crashed (last_active was cleared on session start).
		foreach (ref td; tasks)
		{
			if (td.lastActive == 0 && td.agentSessionId.length > 0)
			{
				try
				{
					auto ta = agentForTask(td.tid);
					auto jp = ta.historyPath(td.agentSessionId, td.effectiveCwd);
					if (jp.length > 0)
					{
						import std.file : exists, timeLastModified;
						if (exists(jp))
						{
							td.lastActive = timeLastModified(jp).stdTime;
							persistence.setLastActive(td.tid, td.lastActive);
						}
					}
				}
				catch (Exception) {} // best-effort
			}
			// Final fallback: if still no lastActive but has createdAt, use that
			if (td.lastActive == 0 && td.createdAt != 0)
				td.lastActive = td.createdAt;
		}

		enumerateSessions();

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

		import core.sys.posix.unistd : isatty, STDERR_FILENO;

		auto userEnv = environment.get("CYDO_AUTH_USER", null);
		auto passEnv = environment.get("CYDO_AUTH_PASS", null);
		bool generatedCredentials;

		if (passEnv is null)
		{
			if (!isatty(STDERR_FILENO))
			{
				fatalf("CYDO_AUTH_PASS not set and stderr is not a TTY — cannot safely communicate generated password. " ~
					"Set CYDO_AUTH_PASS explicitly, or set CYDO_AUTH_PASS='' to disable authentication.");
			}
			import std.random : Random, unpredictableSeed, uniform;
			auto rng = Random(unpredictableSeed);
			enum chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
			char[16] buf;
			foreach (ref c; buf)
				c = chars[uniform(0, chars.length, rng)];
			authPass = buf[].idup;
			generatedCredentials = true;
		}
		else
			authPass = passEnv;

		authUser = userEnv is null ? (authPass.length > 0 ? "user" : "") : userEnv;
		if (userEnv is null && generatedCredentials)
			warningf("CYDO_AUTH_USER not set — defaulting to 'user'.");

		server.handleRequest = &handleRequest;

		auto listenSocket = environment.get("CYDO_LISTEN_SOCKET", null);
		if (listenSocket)
		{
			import std.file : remove;
			import std.path : absolutePath;
			import std.socket : AddressFamily, AddressInfo, ProtocolType, SocketType, UnixAddress;

			listenSocket = absolutePath(listenSocket);

			if (exists(listenSocket))
				remove(listenSocket);

			auto addr = new UnixAddress(listenSocket);
			server.listen([AddressInfo(AddressFamily.UNIX, SocketType.STREAM, cast(ProtocolType) 0, addr, listenSocket)]);
			infof("CyDo server listening on unix:%s", listenSocket);
		}
		else
		{
			import std.conv : to;
			auto listenAddrEnv = environment.get("CYDO_LISTEN_ADDRESS", "localhost");
			auto listenPort = to!ushort(environment.get("CYDO_LISTEN_PORT", "3940"));
			auto listenAddr = listenAddrEnv == "*" ? null : listenAddrEnv;

			auto port = server.listen(listenPort, listenAddr);
			auto proto = sslCert ? "https" : "http";
			auto addrStr = listenAddr ? listenAddr : "*";
			if (generatedCredentials)
			{
				warningf("Generated random credentials for this session. Set CYDO_AUTH_PASS='' to disable authentication.");
				infof("CyDo server listening on %s://%s:%s@%s:%d", proto, authUser, authPass, addrStr, port);
			}
			else
				infof("CyDo server listening on %s://%s:%d", proto, addrStr, port);
		}
	}

	/// Graceful shutdown: stop all agent sessions and close servers.
	/// Called from the ae.net.shutdown handler (runs in the event loop thread).
	void shutdown()
	{
		shuttingDown = true;
		foreach (ref td; tasks)
		{
			if (td.session && td.session.alive)
				td.session.stop();
			if (td.titleGenKill !is null)
			{
				td.titleGenKill();
				td.titleGenKill = null;
			}
			if (td.suggestGenKill !is null)
			{
				td.suggestGenKill();
				td.suggestGenKill = null;
			}
		}
		{
			import cydo.agent.codex : CodexAgent;
			foreach (a; agentsByType)
				if (auto ca = cast(CodexAgent) a)
					ca.shutdownAllServers();
		}
		{
			import ae.net.asockets : disconnectable;
			auto clientsSnapshot = clients;
			clients = null;
			foreach (ws; clientsSnapshot)
			{
				if (ws is null)
					continue;
				if (ws.state.disconnectable)
					ws.disconnect("shutting down");
			}
		}
		server.close();
		if (mcpServer)
			mcpServer.close();
		// Remove inotify watches so the event loop can exit.
		if (configFileWatchActive)
		{
			iNotify.remove(configFileWatch);
			configFileWatchActive = false;
		}
		if (configDirWatchActive)
		{
			iNotify.remove(configDirWatch);
			configDirWatchActive = false;
		}
	}

	private bool checkAuth(HttpRequest request, HttpServerConnection conn)
	{
		if (authUser.length == 0 && authPass.length == 0)
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

		if (request.path == "/api/raw-source")
		{
			handleRawSourceRequest(request, conn);
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

	private void handleRawSourceRequest(HttpRequest request, HttpServerConnection conn)
	{
		import cydo.agent.protocol : extractRawField;
		import cydo.task : extractEventFromEnvelope;
		import std.conv : to, ConvException;

		auto response = new HttpResponseEx();
		auto params = request.urlParameters;
		auto tidStr = params.get("tid", "");
		auto seqStr = params.get("seq", "");
		if (tidStr.length == 0 || seqStr.length == 0)
		{
			response.setStatus(HttpStatusCode.BadRequest);
			conn.sendResponse(response.serveData("Missing tid or seq"));
			return;
		}

		int tid;
		size_t seq;
		try
		{
			tid = tidStr.to!int;
			seq = seqStr.to!size_t;
		}
		catch (ConvException)
		{
			response.setStatus(HttpStatusCode.BadRequest);
			conn.sendResponse(response.serveData("Invalid tid or seq"));
			return;
		}

		if (tid !in tasks)
		{
			response.setStatus(HttpStatusCode.NotFound);
			conn.sendResponse(response.serveData("Task not found"));
			return;
		}

		auto td = &tasks[tid];
		ensureHistoryLoaded(tid);
		if (seq >= td.history.length)
		{
			response.setStatus(HttpStatusCode.NotFound);
			conn.sendResponse(response.serveData("Seq out of range"));
			return;
		}

		auto envelope = cast(string) td.history[seq].toGC();
		auto event = extractEventFromEnvelope(envelope);
		auto raw = event.length > 0 ? extractRawField(event) : null;

		response.headers["Content-Type"] = "application/json";
		conn.sendResponse(response.serveData(raw !is null ? raw : "null"));
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
			conn.sendResponse(response.serveData("Bad WebSocket request: " ~ e.msg));
			return;
		}

		ws.sendBinary = true; // binary frames — no UTF-8 encoding requirement
		clients ~= ws;

		// Send workspaces list, task types, tasks list, and server status to new client
		ws.send(Data(buildWorkspacesList().representation));
		ws.send(Data(buildTaskTypesList().representation));
		ws.send(Data(buildAgentTypesList().representation));
		ws.send(Data(buildTasksList().representation));
		ws.send(Data(buildServerStatus().representation));

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
		infof("MCP socket listening on %s", mcpSocketPath);
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
			{
				// MCP delivery failed — trigger fallback delivery for Task tool calls.
				onMcpDeliveryFailed(call.tid);
				return;
			}
			auto resultJson = toJson(McpContentResult(
				[McpContentItem("text", result.text)],
				result.isError,
				result.structuredContent,
			));
			conn.sendResponse(response.serveData(resultJson));
			onToolCallDelivered(call.tid);
		}).except((Exception e) {
			warningf("dispatchTool: unhandled error: %s", e.msg);
		}).ignoreResult();
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
		int parsedTid;
		bool hasParsedTid = true;
		try
			parsedTid = to!int(tid);
		catch (Exception)
			hasParsedTid = false;

		if (hasParsedTid)
		{
			if (auto tdp = parsedTid in tasks)
			{
				if (tdp.pendingContinuation.length > 0)
					return resolve(McpResult(
						"Tool call rejected: you already called SwitchMode/Handoff. "
						~ "Yield your turn immediately — do not make any more tool calls.",
						true));
			}
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

		McpResult structuredTaskError(string message)
		{
			auto taskResultJson = toJson(TaskResult(message, null, null, null, message));
			return McpResult(message, true, JSONFragment(taskResultJson));
		}

		// Look up calling task
		int parentTid;
		try
			parentTid = to!int(callerTid);
		catch (Exception)
			return resolve(structuredTaskError("Invalid calling task ID"));

		auto parentTd = parentTid in tasks;
		if (parentTd is null)
			return resolve(structuredTaskError("Calling task not found"));

		// Validate task_type against parent's creatable_tasks and resolve alias
		auto parentTypeDef = getTaskTypes().byName(parentTd.taskType);
		string resolvedTaskType = taskType;
		if (parentTypeDef !is null &&
			parentTypeDef.creatable_tasks.length > 0)
		{
			auto edge = parentTypeDef.creatable_tasks.byName(taskType);
			if (edge is null)
			{
				return resolve(structuredTaskError(
					"Task type '" ~ taskType ~ "' is not in creatable_tasks for '" ~
					parentTd.taskType ~ "'. Allowed: " ~
					parentTypeDef.creatable_tasks.map!(c => c.name).join(", ")));
			}
			resolvedTaskType = edge.resolvedType;
		}

		// Validate child task type exists
		auto childTypeDef = getTaskTypes().byName(resolvedTaskType);
		if (childTypeDef is null)
			return resolve(structuredTaskError("Unknown task type: " ~ resolvedTaskType));

		// Create child task
		auto childTid = createTask(parentTd.workspace, parentTd.projectPath, parentTd.agentType);
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
		persistence.addTaskDep(parentTid, childTid);
		taskDeps[childTid] = parentTid;
		parentTd.status = "waiting";
		persistence.setStatus(parentTid, "waiting");
		broadcastTaskUpdate(parentTid);

		// Broadcast to UI
		broadcast(toJson(TaskCreatedMessage("task_created", childTid,
			parentTd.workspace, parentTd.projectPath, parentTid, "subtask")));
		broadcastTaskUpdate(childTid);

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
					setupWorktree(childTid, true, "", parentTd.hasWorktree ? parentTd.worktreePath : "");
				else if (parentTd.hasWorktree)
					setupWorktree(childTid, false, parentTd.worktreePath);
			}
		}

		// Configure and spawn child agent
		auto renderedPrompt = renderPrompt(*childTypeDef, prompt, taskTypesDir, childTd.outputPath, edgeTemplate);
		tasks[childTid].processQueue.setGoal(ProcessState.Alive).then(() {
			broadcastUnconfirmedUserMessage(childTid, [ContentBlock("text", renderedPrompt)]);
			sendTaskMessage(childTid, [ContentBlock("text", renderedPrompt)]);
		}).ignoreResult();

		if (description.length == 0)
		{
			auto promptForTitle = prompt;
			tasks[childTid].processQueue.setGoal(ProcessState.Alive).then(() {
				generateTitle(childTid, promptForTitle);
			}).ignoreResult();
		}
		infof("Task: tid=%d type=%s parent=%d", childTid, resolvedTaskType, parentTid);

		return promise;
	}

	/// Handle SwitchMode tool — validate and store continuation choice (keep_context).
	/// The actual transition happens in onExit after the session ends.
	McpResult handleSwitchMode(string callerTid, string continuation)
	{
		import std.algorithm : filter, map;
		import std.array : array, join;
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
			auto validModes = typeDef.continuations.byKeyValue
				.filter!(kv => kv.value.keep_context)
				.map!(kv => "'" ~ kv.key ~ "'")
				.array.join(", ");
			return McpResult(
				"Unknown SwitchMode continuation '" ~ continuation ~ "' for task type '" ~
				td.taskType ~ "'. Available modes: " ~ (validModes.length > 0 ? validModes : "(none)") ~ ".", true);
		}

		td.pendingContinuation = continuation;
		infof("SwitchMode: tid=%d continuation=%s (type %s → %s)",
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
		infof("Handoff: tid=%d continuation=%s (type %s → %s)",
			tid, continuation, td.taskType, contDef.task_type);

		return McpResult(
			"Handoff to '" ~ contDef.task_type ~ "' accepted. "
			~ "Yield your turn IMMEDIATELY — do not call any more tools or generate output. "
			~ "A new task will be created with your prompt. Your session is ending.");
	}

	/// Handle AskUserQuestion — broadcast questions to frontend, return promise
	/// that resolves when the user responds.
	Promise!McpResult handleAskUserQuestion(string callerTid, AskQuestion[] questions)
	{
		import ae.utils.json : toJson;
		import std.conv : to;

		int tid;
		try
			tid = to!int(callerTid);
		catch (Exception)
			return resolve(McpResult("Invalid calling task ID", true));

		auto tdp = tid in tasks;
		if (tdp is null)
			return resolve(McpResult("Task not found", true));

		// Gate: only types in the interactive cluster (user_visible or reachable
		// from user_visible via keep_context continuations).
		auto taskTypes = getTaskTypes();
		auto typeDef = taskTypes.byName(tdp.taskType);
		if (typeDef is null || !taskTypes.isInteractive(tdp.taskType))
			return resolve(McpResult(
				"AskUserQuestion is only available for interactive tasks. "
				~ "This task type (" ~ tdp.taskType ~ ") is not interactive.", true));

		// Only one pending AskUserQuestion per task
		if (tid in pendingAskUserQuestions)
			return resolve(McpResult("Another AskUserQuestion is already pending for this task", true));

		auto promise = new Promise!McpResult;
		pendingAskUserQuestions[tid] = promise;

		// Correlation ID (tid is unique since only one pending per task)
		auto toolUseId = format!"ask_%d"(tid);
		auto questionsJson = toJson(questions);
		tdp.pendingAskToolUseId = toolUseId;
		tdp.pendingAskQuestions = JSONFragment(questionsJson);

		// Broadcast to subscribed clients
		auto msg = toJson(AskUserQuestionMessage("ask_user_question", tid, toolUseId, JSONFragment(questionsJson)));
		sendToSubscribed(tid, Data(msg.representation));

		// Update task state for sidebar
		tdp.needsAttention = true;
		tdp.hasPendingQuestion = true;
		tdp.notificationBody = "Waiting for your answer";
		tdp.isProcessing = false;
		touchTask(tid);
		persistence.setLastActive(tid, tasks[tid].lastActive);
		broadcastTaskUpdate(tid);

		return promise;
	}

	Promise!McpResult handleBash(string callerTid, string command)
	{
		import cydo.agent.terminal : TerminalProcess;

		auto terminal = new TerminalProcess(
			["/bin/sh", "-c", command],
			null,   // inherit env
			null,   // inherit working directory
			1024 * 1024
		);

		auto promise = new Promise!McpResult;
		terminal.onExit = () {
			auto output = terminal.output();
			promise.fulfill(McpResult(output, terminal.exitCode() != 0));
		};
		return promise;
	}

	/// Called after an MCP tool call result is successfully sent back to the
	/// agent's MCP proxy. Cleans up sub-task deps (if any) and transitions
	/// the parent from "waiting" to "active".
	private void onToolCallDelivered(string callerTidStr)
	{
		import std.conv : to;
		int tid;
		try tid = to!int(callerTidStr);
		catch (Exception) return;

		if (tid !in tasks)
			return;

		// Clean up deps for completed children (no-op for non-Task tools)
		auto children = childrenOf(tid);
		if (children.length == 0)
			return;

		foreach (childTid; children)
		{
			persistence.removeTaskDep(tid, childTid);
			taskDeps.remove(childTid);
		}

		// Transition parent from waiting to active
		if (tasks[tid].status == "waiting")
		{
			tasks[tid].status = "active";
			persistence.setStatus(tid, "active");
			broadcastTaskUpdate(tid);
		}
	}

	/// Called when MCP delivery fails (connection dead). If this was a Task tool
	/// call and all children are done, triggers fallback delivery via
	/// deliverBatchResults so the parent receives results as a user message
	/// without requiring manual resume.
	private void onMcpDeliveryFailed(string callerTidStr)
	{
		import std.conv : to;
		int tid;
		try tid = to!int(callerTidStr);
		catch (Exception) return;

		if (tid !in tasks)
			return;

		// No-op for non-Task tools (no children to deliver)
		if (childrenOf(tid).length == 0)
			return;

		// Only deliver when ALL children are done — partial delivery
		// would lose the remaining results.
		foreach (childTid, depParent; taskDeps)
		{
			if (depParent == tid && childTid in tasks
				&& tasks[childTid].status != "completed"
				&& tasks[childTid].status != "failed")
				return; // Remaining children will trigger this check on their exit
		}

		deliverBatchResults(tid);
	}

	private void handleAskUserResponse(WsMessage json)
	{
		auto tid = json.tid;
		if (tid < 0 || tid !in tasks)
			return;

		auto pending = tid in pendingAskUserQuestions;
		if (pending is null)
			return;

		auto td = &tasks[tid];
		td.pendingAskToolUseId = null;
		td.pendingAskQuestions = JSONFragment.init;
		td.needsAttention = false;
		td.hasPendingQuestion = false;
		td.notificationBody = "";
		td.isProcessing = true;

		// json.content is the JSON from the frontend:
		//   {"answers": {"q": "a", ...}} — normal response
		//   {"error": "..."} — user aborted
		string rawContent = json.content.json !is null ? jsonParse!string(json.content.json) : "{}";
		string resultText = rawContent; // fallback: raw JSON
		bool isError = false;
		try
		{
			import std.json : parseJSON;
			auto parsed = parseJSON(rawContent);
			if (auto errorMsg = "error" in parsed)
			{
				resultText = errorMsg.str;
				isError = true;
			}
			else if (auto answersObj = "answers" in parsed)
			{
				string[] parts;
				foreach (key, val; answersObj.object)
					parts ~= `"` ~ key ~ `"="` ~ val.str ~ `"`;
				import std.array : join;
				resultText = "User has answered your questions: " ~ parts.join(". ") ~ ".";
			}
		}
		catch (Exception e) { warningf("AskUserQuestion response parse error: %s", e.msg); } // use raw JSON as fallback

		pending.fulfill(McpResult(resultText, isError));
		pendingAskUserQuestions.remove(tid);

		// Broadcast clear to all subscribed clients (so other tabs/windows dismiss the form)
		import ae.utils.json : toJson;
		sendToSubscribed(tid, Data(toJson(AskUserQuestionMessage("ask_user_question", tid, "", JSONFragment("[]"))).representation));

		broadcastTaskUpdate(tid);
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
			case "edit_message":      handleEditMessage(ws, json); break;
			case "set_archived":      handleSetArchivedMsg(ws, json); break;
			case "set_draft":         handleSetDraftMsg(ws, json); break;
			case "delete_task":       handleDeleteTaskMsg(json); break;
			case "ask_user_response": handleAskUserResponse(json); break;
			case "refresh_workspaces": handleRefreshWorkspacesMsg(); break;
			case "promote_task":     handlePromoteTaskMsg(json); break;
			case "set_task_type":    handleSetTaskTypeMsg(json); break;
			default: break;
		}
	}

	private void handleSetTaskTypeMsg(WsMessage json)
	{
		auto tid = json.tid;
		if (tid < 0 || tid !in tasks) return;
		if (tasks[tid].alive) return; // can't change type of a running task
		if (json.task_type.length == 0) return;
		if (getTaskTypes().byName(json.task_type) is null) return;
		tasks[tid].taskType = json.task_type;
		persistence.setTaskType(tid, json.task_type);
		broadcastTaskUpdate(tid);
	}

	private void handleCreateTaskMsg(WebSocketAdapter ws, WsMessage json)
	{
		auto at = json.agent_type.length > 0 ? json.agent_type : defaultAgentType(json.workspace);
		auto tid = createTask(json.workspace, json.project_path, at);
		if (json.task_type.length > 0 && getTaskTypes().byName(json.task_type) !is null)
		{
			tasks[tid].taskType = json.task_type;
			persistence.setTaskType(tid, json.task_type);
		}
		// Send task_created only to the requesting client (unicast) so that
		// parallel test workers don't steal each other's task IDs.
		ws.send(Data(toJson(TaskCreatedMessage("task_created", tid, json.workspace, json.project_path, 0, "", json.correlation_id)).representation));
		// Broadcast updated task state so all other clients see the new task.
		broadcastTaskUpdate(tid);

		// If content is provided, send it as the first message atomically
		ContentBlock[] blocks;
		if (json.content.json !is null)
			blocks = jsonParse!(ContentBlock[])(json.content.json);
		if (blocks.length > 0)
		{
			auto td = &tasks[tid];
			auto typeDef = getTaskTypes().byName(td.taskType);
			auto textContent = extractContentText(blocks);
			auto messageToSend = blocks;
			if (typeDef !is null)
			{
				import std.algorithm : filter;
				import std.array : array;
				auto rendered = renderPrompt(*typeDef, textContent, taskTypesDir, td.outputPath);
				// Preserve image blocks alongside the rendered text prompt.
				messageToSend = ContentBlock("text", rendered)
					~ blocks.filter!(b => b.type == "image").array;
			}
			// Record text so ensureHistoryLoaded can produce correct synthetics
			// for queue-operation:remove lines (same as handleUserMessage does).
			td.pendingSteeringTexts ~= textContent;
			auto msgContent = blocks;
			tasks[tid].processQueue.setGoal(ProcessState.Alive).then(() {
				broadcastUnconfirmedUserMessage(tid, msgContent);
				sendTaskMessage(tid, messageToSend);
			}).ignoreResult();

			td.description = textContent;
			persistence.setDescription(tid, textContent);

			td.title = truncateTitle(textContent, 80);
			persistence.setTitle(tid, td.title);
			broadcastTitleUpdate(tid, td.title);
			tasks[tid].processQueue.setGoal(ProcessState.Alive).then(() {
				generateTitle(tid, textContent);
			}).ignoreResult();
		}
	}

	/// Load JSONL history from disk if not already loaded.
	/// Must be called before appending to td.history to avoid a later
	/// reload silently replacing events that were appended while
	/// historyLoaded was false (e.g. continuation prompts).
	private void ensureHistoryLoaded(int tid)
	{
		if (tid !in tasks)
			return;
		auto td = &tasks[tid];
		if (td.historyLoaded || td.agentSessionId.length == 0)
			return;

		auto ta = agentForTask(tid);
		auto jsonlPath = ta.historyPath(td.agentSessionId, td.effectiveCwd);
		// steeringStash holds (text, enqueueLineNum, rawLine) for queued steering messages.
		// Using parallel arrays to avoid struct allocation in a delegate closure.
		bool hasQueueOps = false;     // set when any queue-operation line is seen
		int userMsgFromJsonl = 0;     // count of user message lines seen in JSONL
		string[] steeringStash;
		int[] steeringEnqueueLineNums;
		string[] steeringEnqueueRawLines;
		string lastDequeuedText;
		int lastDequeuedEnqueueLineNum;
		string lastDequeuedRawLine;
		td.history = loadTaskHistory(tid, jsonlPath, delegate string[](string line, int lineNum) {
			if (isQueueOperation(line))
			{
				import ae.utils.json : jsonParse;
				import std.format : format;
				auto op = jsonParse!QueueOperationProbe(line);
				if (op.operation == "enqueue")
				{
					hasQueueOps = true;
					// Claude's JSONL enqueue lines have no content field.
					// Use the text recorded at send time (pendingSteeringTexts),
					// falling back to op.content (null) if unavailable.
					string text = op.content;
					if (td.pendingSteeringTexts.length > 0)
					{
						text = td.pendingSteeringTexts[0];
						td.pendingSteeringTexts = td.pendingSteeringTexts[1 .. $];
					}
					steeringStash ~= text;
					steeringEnqueueLineNums ~= lineNum;
					steeringEnqueueRawLines ~= line;
					return []; // Dequeue+echo/compaction will emit the confirmed version
				}
				else if (op.operation == "dequeue" || op.operation == "remove")
				{
					import cydo.agent.protocol : injectRawField;
					string[] result;
					// Flush any deferred synthetic from a prior dequeue/remove
					// (handles compacted back-to-back dequeues)
					if (lastDequeuedText.length > 0)
					{
						auto synthetic = buildSyntheticUserEvent(lastDequeuedText);
						if (lastDequeuedRawLine.length > 0)
							synthetic = injectRawField(synthetic, lastDequeuedRawLine);
						result ~= synthetic;
						lastDequeuedText = null;
						lastDequeuedRawLine = null;
					}
					if (steeringStash.length > 0)
					{
						auto text = steeringStash[0];
						auto enqLineNum = steeringEnqueueLineNums[0];
						auto enqRaw = steeringEnqueueRawLines[0];
						steeringStash = steeringStash[1 .. $];
						steeringEnqueueLineNums = steeringEnqueueLineNums[1 .. $];
						steeringEnqueueRawLines = steeringEnqueueRawLines[1 .. $];
						if (op.operation == "remove")
						{
							// "remove" means the message was removed from the queue
							// without a type:"user" echo following in the JSONL.
							// Emit the synthetic confirmed event immediately (with
							// enqueue UUID for undo support), matching live-stream
							// behaviour where remove → synthetic broadcast.
							auto enqueueUuid = format!"enqueue-%d"(enqLineNum);
							auto synthetic = buildSyntheticUserEvent(text, true);
							synthetic = synthetic[0 .. $ - 1]
								~ `,"uuid":"` ~ enqueueUuid ~ `"}`;
							if (enqRaw.length > 0)
								synthetic = injectRawField(synthetic, enqRaw);
							result ~= synthetic;
						}
						else
						{
							// "dequeue" means a type:"user" echo should follow.
							lastDequeuedText = text;
							lastDequeuedEnqueueLineNum = enqLineNum;
							lastDequeuedRawLine = enqRaw;
							// Defer: wait to see if type:"user" echo follows
						}
					}
					return result;
				}
				return []; // unknown queue operation
			}
			// Deferred compaction check: if a type:"user" echo follows the
			// dequeue/remove, pass it through with the enqueue UUID injected so the
			// undo button appears on the confirmed message after reload.
			// Other lines (file-history-snapshot, progress, etc.) are translated/dropped
			// without leaving deferred mode — they can appear between dequeue and
			// the user echo. Only type:"assistant" confirms compaction and triggers
			// synthetic emission.
			if (lastDequeuedText.length > 0)
			{
				if (ta.isUserMessageLine(line))
				{
					// Non-compacted: type:"user" echo present — pass through with
					// the enqueue UUID injected (always override any existing uuid so
					// that undo truncates at the enqueue line, not the echo line).
					auto savedEnqueueLineNum = lastDequeuedEnqueueLineNum;
					lastDequeuedText = null;
					lastDequeuedEnqueueLineNum = 0;
					auto ts = ta.translateHistoryLine(line, lineNum);
					if (ts.length > 0)
					{
						import std.string : indexOf;
						import std.format : format;
						auto enqueueUuid = format!"enqueue-%d"(savedEnqueueLineNum);
						enum uuidPrefix = `"uuid":"`;
						// Inject UUID into the first event (item/started type=user_message).
						auto t = ts[0];
						auto uIdx = t.indexOf(uuidPrefix);
						if (uIdx >= 0)
						{
							auto vStart = uIdx + uuidPrefix.length;
							auto vEnd = t.indexOf('"', vStart);
							t = t[0 .. vStart] ~ enqueueUuid ~ t[vEnd .. $];
						}
						else
							t = t[0 .. $ - 1] ~ `,"uuid":"` ~ enqueueUuid ~ `"}`;
						return [t] ~ ts[1 .. $];
					}
					return [];
				}
				if (ta.isAssistantMessageLine(line))
				{
					// Compacted: assistant response appeared without preceding user echo —
					// emit synthetic with enqueue UUID before the assistant line.
					import std.format : format;
					import cydo.agent.protocol : injectRawField;
					auto enqueueUuid = format!"enqueue-%d"(lastDequeuedEnqueueLineNum);
					auto synthetic = buildSyntheticUserEvent(lastDequeuedText, true);
					synthetic = synthetic[0 .. $ - 1] ~ `,"uuid":"` ~ enqueueUuid ~ `"}`;
					if (lastDequeuedRawLine.length > 0)
						synthetic = injectRawField(synthetic, lastDequeuedRawLine);
					lastDequeuedText = null;
					lastDequeuedEnqueueLineNum = 0;
					lastDequeuedRawLine = null;
					auto ts = ta.translateHistoryLine(line, lineNum);
					return [synthetic] ~ ts;
				}
				// Other lines (file-history-snapshot, progress, etc.) are translated/dropped;
				// stay in deferred mode waiting for type:"user" or type:"assistant".
				return ta.translateHistoryLine(line, lineNum);
			}
			if (ta.isUserMessageLine(line))
				userMsgFromJsonl++;
			return ta.translateHistoryLine(line, lineNum);
		});
		td.historyLoaded = true;
		// For agents without queue-operations (e.g. Copilot), emit synthetics for
		// user messages that were sent but not yet flushed to JSONL at kill time.
		if (!hasQueueOps && td.pendingSteeringTexts.length > userMsgFromJsonl)
		{
			import std.file : append, mkdirRecurse;
			import std.path : dirName;
			import ae.utils.json : toJson;
			import std.uuid : randomUUID;
			import std.format : format;
			foreach (text; td.pendingSteeringTexts[cast(size_t)userMsgFromJsonl .. $])
			{
				auto uuid = randomUUID().toString();
				// Append to events.jsonl so undo can truncate at this UUID.
				if (jsonlPath.length > 0)
				{
					mkdirRecurse(dirName(jsonlPath));
					append(jsonlPath,
						`{"type":"user.message","id":"` ~ uuid
						~ `","data":{"content":` ~ toJson(text) ~ `}}` ~ "\n");
				}
				// Emit synthetic into history with uuid for undo support.
				auto synthetic = buildSyntheticUserEvent(text);
				synthetic = synthetic[0 .. $ - 1] ~ `,"uuid":"` ~ uuid ~ `"}`;
				td.history ~= Data(
					(format!`{"tid":%d,"event":%s}`(tid, synthetic)).representation);
			}
			// Broadcast updated forkable UUIDs now that events.jsonl has new entries.
			jsonlTracker.broadcastForkableUuidsFromFile(tid);
		}
	}

	private void handleRequestHistory(WebSocketAdapter ws, WsMessage json)
	{
		import ae.utils.json : toJson;

		auto tid = json.tid;
		if (tid < 0 || tid !in tasks)
			return;
		auto td = &tasks[tid];

		ensureHistoryLoaded(tid);

		// Send unified history to requesting client (strip _raw, add _seq)
		import cydo.agent.protocol : stripRawField;
		import cydo.task : extractEventFromEnvelope;
		foreach (i, ref msg; td.history)
		{
			auto envelope = cast(string) msg.unsafeContents;
			auto event = extractEventFromEnvelope(envelope);
			if (event.length == 0)
			{
				// Non-event envelope (unconfirmedUserEvent, etc.) — pass through
				ws.send(msg);
				continue;
			}
			auto stripped = stripRawField(event);
			string clientEnvelope = `{"tid":` ~ format!"%d"(tid)
				~ `,"seq":` ~ format!"%d"(i)
				~ `,"event":` ~ stripped ~ `}`;
			ws.send(Data(clientEnvelope.representation));
		}

		// Send forkable UUIDs extracted from JSONL
		if (td.agentSessionId.length > 0)
			jsonlTracker.sendForkableUuidsFromFile(ws, tid, td.agentSessionId, td.effectiveCwd);

		// Send end marker
		ws.send(Data(toJson(TaskHistoryEndMessage("task_history_end", tid)).representation));

		// Send cached suggestions if available
		if (td.lastSuggestions.length > 0)
			ws.send(Data(toJson(SuggestionsUpdateMessage("suggestions_update", tid, td.lastSuggestions)).representation));

		// Re-broadcast pending AskUserQuestion (client reconnect / tab switch)
		if (tid in pendingAskUserQuestions && tasks[tid].pendingAskToolUseId.length > 0)
		{
			auto tdask = &tasks[tid];
			ws.send(Data(toJson(AskUserQuestionMessage("ask_user_question", tid, tdask.pendingAskToolUseId, tdask.pendingAskQuestions)).representation));
		}

		// Subscribe client to live events for this task
		clientSubscriptions.require(ws)[tid] = true;

		// If a turn already completed but suggestions were skipped because no client was
		// subscribed at the time (race: turn completed before request_history processed),
		// trigger suggestion generation now that a subscriber is present.
		if (td.suggestGenHandle is null && td.lastSuggestions.length == 0 && td.status == "alive")
		{
			try
				generateSuggestions(tid);
			catch (Exception e)
				warningf("Error generating suggestions on subscribe: %s", e.msg);
		}
	}

	private void handleUserMessage(WsMessage json)
	{
		auto tid = json.tid;
		if (tid < 0 || tid !in tasks)
			return;
		auto td = &tasks[tid];
		assert(td.taskType.length > 0, "Task must have a task_type when receiving a message");
		// Resumable tasks (completed with agentSessionId) require explicit "resume".
		if (td.agentSessionId.length > 0 && (td.session is null || !td.session.alive))
			return; // resumable but not resumed — ignore

		ContentBlock[] blocks;
		if (json.content.json !is null)
			blocks = jsonParse!(ContentBlock[])(json.content.json);
		auto textContent = extractContentText(blocks);

		// Record text for ensureHistoryLoaded, which needs it to produce correct
		// synthetic confirmed events for queue-operation:remove lines (Claude's JSONL
		// does not include message text in enqueue/remove entries).
		td.pendingSteeringTexts ~= textContent;

		// Wrap first message in prompt template (e.g. conversation.md)
		auto messageToSend = blocks;
		if (td.description.length == 0)
		{
			auto typeDef = getTaskTypes().byName(td.taskType);
			if (typeDef !is null)
			{
				import std.algorithm : filter;
				import std.array : array;
				auto rendered = renderPrompt(*typeDef, textContent, taskTypesDir, td.outputPath);
				// Preserve image blocks alongside the rendered text prompt.
				messageToSend = ContentBlock("text", rendered)
					~ blocks.filter!(b => b.type == "image").array;
			}
		}
		td.lastSuggestions = null;
		broadcastUnconfirmedUserMessage(tid, blocks);
		td.processQueue.setGoal(ProcessState.Alive).then(() {
			auto td = &tasks[tid];
			if (td.status == "alive")
			{
				td.status = "active";
				persistence.setStatus(tid, "active");
			}
			sendTaskMessage(tid, messageToSend);
		}).ignoreResult();

		// Store first message as task description
		if (td.description.length == 0)
		{
			td.description = textContent;
			persistence.setDescription(tid, textContent);
		}

		// Set initial title from first user message (truncated)
		if (td.title.length == 0)
		{
			td.title = truncateTitle(textContent, 80);
			persistence.setTitle(tid, td.title);
			broadcastTitleUpdate(tid, td.title);
			td.processQueue.setGoal(ProcessState.Alive).then(() {
				generateTitle(tid, textContent);
			}).ignoreResult();
		}

		// Clear draft when message is sent
		if (td.draft.length > 0)
		{
			td.draft = "";
			persistence.setDraft(tid, "");
			auto draftData = Data(toJson(DraftUpdatedMessage("draft_updated", tid, "")).representation);
			sendToSubscribed(tid, draftData);
		}
	}

	private void handleResumeMsg(WsMessage json)
	{
		auto tid = json.tid;
		if (tid < 0 || tid !in tasks)
			return;
		auto td = &tasks[tid];
		if (td.archived)
			return;
		// Only resume if we have an agent session ID and no running process
		if (td.agentSessionId.length == 0)
			return;
		if (td.session !is null && td.session.alive)
			return;
		td.needsAttention = false;
		td.notificationBody = "";
		td.processQueue.setGoal(ProcessState.Alive).then(() {
			auto td = &tasks[tid];
			td.status = "alive";
			persistence.setStatus(tid, "alive");
			try
				generateSuggestions(tid);
			catch (Exception e)
				warningf("Error generating suggestions: %s", e.msg);

			// Deliver pending batch results if all children are done
			auto children = childrenOf(tid);
			if (children.length > 0)
			{
				bool allDone = true;
				foreach (childTid; children)
					if (childTid in tasks
						&& tasks[childTid].status != "completed"
						&& tasks[childTid].status != "failed")
					{ allDone = false; break; }
				if (allDone)
					deliverBatchResults(tid);
			}

			broadcastTaskUpdate(tid);
		}).ignoreResult();
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
		{
			td.processQueue.setGoal(ProcessState.Dead).ignoreResult();
			td.session.closeStdin();
		}
	}

	private void handleStopMsg(WsMessage json)
	{
		auto tid = json.tid;
		if (tid < 0 || tid !in tasks)
			return;
		auto td = &tasks[tid];
		if (td.session)
		{
			td.wasKilledByUser = true;
			td.processQueue.setGoal(ProcessState.Dead).ignoreResult();
			td.session.stop();
		}
	}

	private void handleDismissAttention(WsMessage json)
	{
		auto tid = json.tid;
		if (tid >= 0 && tid in tasks)
		{
			tasks[tid].needsAttention = false;
			tasks[tid].notificationBody = "";
			broadcastTaskUpdate(tid);
		}
	}

	private void handleSetArchivedMsg(WebSocketAdapter ws, WsMessage json)
	{
		auto tid = json.tid;
		if (tid < 0 || tid !in tasks)
			return;
		auto td = &tasks[tid];
		bool archived = json.content.json == `"true"`;
		if (td.archived == archived)
			return; // no change

		// Block archiving if any task in the subtree is alive
		if (archived)
		{
			int aliveTid = findAliveInSubtree(tid);
			if (aliveTid >= 0)
			{
				ws.send(Data(toJson(ErrorMessage("error",
					format!"Cannot archive: task %d is still running"(aliveTid), tid)).representation));
				return;
			}
		}

		td.archived = archived;
		persistence.setArchived(tid, archived);
		broadcastTaskUpdate(tid);

		if (archived)
		{
			archiveWorktreesForTask(tid);
			cleanupSharedTmp(tid);
		}
		else
			unarchiveWorktreesForTask(tid);
	}

	private void handleSetDraftMsg(WebSocketAdapter senderWs, WsMessage json)
	{
		auto tid = json.tid;
		if (tid < 0 || tid !in tasks)
			return;
		auto td = &tasks[tid];
		string draft = json.content.json !is null ? jsonParse!string(json.content.json) : "";
		td.draft = draft;
		persistence.setDraft(tid, draft);
		// Broadcast to other subscribed clients (not the sender)
		auto data = Data(toJson(DraftUpdatedMessage("draft_updated", tid, draft)).representation);
		foreach (ws; clients)
			if (ws !is senderWs)
				if (auto subs = ws in clientSubscriptions)
					if (tid in *subs)
						ws.send(data);
	}

	private void handleDeleteTaskMsg(WsMessage json)
	{
		import ae.utils.json : toJson;
		auto tid = json.tid;
		if (tid < 0 || tid !in tasks)
			return;
		auto td = &tasks[tid];
		// Only allow deletion of empty pending tasks (no agent has run)
		if (td.agentSessionId.length > 0 || td.alive || td.status != "pending")
			return;
		// Clean up subscriptions
		foreach (ref subs; clientSubscriptions)
			subs.remove(tid);
		// Remove from in-memory state
		tasks.remove(tid);
		// Remove from database
		persistence.deleteTask(tid);
		// Broadcast deletion to all clients
		broadcast(toJson(TaskDeletedMessage("task_deleted", tid)));
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
			td.projectPath, td.workspace, td.title,
			// Source JSONL lives under the worktree path (effectiveCwd);
			// destination should live under the real project path so the
			// fork task (which has projectPath, not a worktree) can find it.
			(string sid) => ta.historyPath(sid,
				sid == td.agentSessionId ? td.effectiveCwd : td.projectPath),
			&ta.rewriteSessionId, &ta.forkIdMatchesLine,
			td.description, td.taskType, td.agentType);
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
		newTd.agentType = td.agentType;
		newTd.description = td.description;
		newTd.taskType = td.taskType;
		import std.datetime : Clock;
		newTd.createdAt = Clock.currStdTime;
		newTd.lastActive = newTd.createdAt;
		tasks[result.tid] = move(newTd);
		tasks[result.tid].processQueue = new StateQueue!ProcessState(
			(ProcessState goal) => processTransition(result.tid, goal),
			ProcessState.Dead,
		);

		broadcast(toJson(TaskCreatedMessage("task_created", result.tid, td.workspace, td.projectPath, tid, "fork")));
		broadcastTaskUpdate(result.tid);
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
			// Skip for synthetic enqueue UUIDs: they have no file checkpoints.
			import std.algorithm : startsWith;
			if (json.revert_files && ta.supportsFileRevert()
				&& !json.after_uuid.startsWith("enqueue-"))
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
						td.projectPath, td.workspace, td.title,
						(string sid) => ta.historyPath(sid,
							sid == td.agentSessionId ? td.effectiveCwd : td.projectPath),
						&ta.rewriteSessionId, &ta.forkIdMatchesLine,
						td.description, td.taskType, td.agentType);
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
						bTd.agentType = td.agentType;
						bTd.description = td.description;
						bTd.taskType = td.taskType;
						import std.datetime : Clock;
						bTd.createdAt = Clock.currStdTime;
						bTd.lastActive = bTd.createdAt;
						persistence.setRelationType(backup.tid, "undo-backup");
						persistence.setTitle(backup.tid, bTd.title);
						tasks[backup.tid] = move(bTd);
						tasks[backup.tid].processQueue = new StateQueue!ProcessState(
							(ProcessState goal) => processTransition(backup.tid, goal),
							ProcessState.Dead,
						);
						broadcast(toJson(TaskCreatedMessage("task_created", backup.tid, td.workspace, td.projectPath, tid, "undo-backup")));
						broadcastTaskUpdate(backup.tid);
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
				// Clip pendingSteeringTexts to match remaining user messages in the
				// truncated JSONL. Without this, ensureHistoryLoaded would re-emit
				// synthetics for messages that were intentionally undone.
				if (td.pendingSteeringTexts.length > 0)
				{
					import std.file : readText, exists;
					import std.string : splitLines;
					auto histPath = ta.historyPath(td.agentSessionId, td.effectiveCwd);
					if (histPath.length > 0 && histPath.exists)
					{
						int remaining = 0;
						foreach (line; readText(histPath).splitLines())
							if (ta.isUserMessageLine(line))
								remaining++;
						if (remaining < cast(int)td.pendingSteeringTexts.length)
							td.pendingSteeringTexts = td.pendingSteeringTexts[0 .. remaining].dup;
					}
				}
			}

			broadcast(toJson(TaskReloadMessage("task_reload", tid)));

			// 4. Auto-resume so the input box shows immediately
			// (the user's undone message text is recovered via preReloadDrafts)
			if (json.revert_conversation && td.agentSessionId.length > 0)
			{
				td.processQueue.setGoal(ProcessState.Alive).then(() {
					auto td = &tasks[tid];
					td.status = "active";
					persistence.setStatus(tid, "active");
					try
						generateSuggestions(tid);
					catch (Exception e)
						warningf("Error generating suggestions: %s", e.msg);
					broadcastTaskUpdate(tid);
				}).ignoreResult();
			}

			broadcastTaskUpdate(tid);
		}
	}

	private void handleEditMessage(WebSocketAdapter ws, WsMessage json)
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

		if (td.session && td.session.alive)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Stop the session before editing messages", tid)).representation));
			return;
		}

		auto ta = agentForTask(tid);
		auto jsonlPath = ta.historyPath(td.agentSessionId, td.effectiveCwd);
		auto newContent = json.content.json !is null ? jsonParse!string(json.content.json) : "";
		auto targetUuid = json.after_uuid;

		auto edited = editJsonlMessage(jsonlPath, targetUuid,
			&ta.forkIdMatchesLine,
			(string line) => replaceUserMessageContent(line, newContent));

		if (!edited)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Message UUID not found in history", tid)).representation));
			return;
		}

		td.history = DataVec();
		td.historyLoaded = false;
		unsubscribeAll(tid);

		broadcast(toJson(TaskReloadMessage("task_reload", tid, "edit")));
		broadcastTaskUpdate(tid);
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
	private void sendTaskMessage(int tid, const(ContentBlock)[] content)
	{
		import std.algorithm : min, filter;
		import std.array : array;
		auto td = &tasks[tid];
		assert(td.taskType.length > 0, "Task must have a task_type when sending a message");
		// Strip image blocks for agents that don't support them.
		const(ContentBlock)[] toSend = td.session.supportsImages
			? content
			: content.filter!(b => b.type != "image").array;
		td.session.sendMessage(toSend);
		td.isProcessing = true;
		touchTask(tid);
		td.needsAttention = false;
		td.notificationBody = "";
		td.suggestGenHandle = null; // cancel any in-flight suggestion generation
		td.suggestGeneration++;
		broadcastTaskUpdate(tid);
	}

	private int createTask(string workspace = "", string projectPath = "", string agentType = "claude")
	{
		auto tid = persistence.createTask(workspace, projectPath, agentType);
		auto td = TaskData(tid);
		td.workspace = workspace;
		td.projectPath = projectPath;
		td.agentType = agentType;
		td.historyLoaded = true; // New tasks have no JSONL to load
		import std.datetime : Clock;
		td.createdAt = Clock.currStdTime;
		td.lastActive = td.createdAt;
		tasks[tid] = move(td);
		tasks[tid].processQueue = new StateQueue!ProcessState(
			(ProcessState goal) => processTransition(tid, goal),
			ProcessState.Dead,
		);
		return tid;
	}

	/// Return the Agent instance for a task's agent type, creating it on demand.
	private Agent agentForTask(int tid)
	{
		auto td = &tasks[tid];
		if (auto p = td.agentType in agentsByType)
			return *p;
		auto a = createAgent(td.agentType);
		if (auto ac = td.agentType in config.agents)
			a.setModelAliases(ac.model_aliases);
		{
			import cydo.agent.copilot : CopilotAgent;
			if (auto ca = cast(CopilotAgent) a)
				ca.toolDispatch_ = (string tool, string callerTid, JSONFragment args) =>
					dispatchTool(tool, callerTid, args);
		}
		agentsByType[td.agentType] = a;
		return a;
	}

	/// Create an Agent instance by type name.
	private static Agent createAgent(string agentType)
	{
		import cydo.agent.registry : agentRegistry;
		foreach (ref entry; agentRegistry)
			if (entry.name == agentType)
				return entry.create();
		throw new Exception("Unknown agent type: " ~ agentType);
	}

	/// Set up a worktree for a task: either create a new git worktree or
	/// inherit an existing one from a predecessor/parent via symlink.
	private void setupWorktree(int tid, bool createNew, string inheritFrom = "", string baseFrom = "")
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
			auto workDir = baseFrom.length > 0 ? baseFrom : (td.projectPath.length > 0 ? td.projectPath : null);
			auto gitResult = execute(["git", "-C", workDir, "worktree", "add", "--detach", wtPath]);
			if (gitResult.status == 0)
			{
				td.hasWorktree = true;
				persistence.setHasWorktree(td.tid, true);
				infof("Created worktree for task %d: %s", td.tid, wtPath);
			}
			else
				errorf("Failed to create worktree for task %d: %s", td.tid, gitResult.output);
		}
		else if (inheritFrom.length > 0)
		{
			import std.file : symlink;
			auto wtPath = buildPath(td.taskDir, "worktree");
			symlink(inheritFrom, wtPath);
			td.hasWorktree = true;
			persistence.setHasWorktree(td.tid, true);
			infof("Inherited worktree for task %d: %s → %s", td.tid, wtPath, inheritFrom);
		}
	}

	private void spawnTaskSession(int tid)
	{
		auto td = &tasks[tid];
		assert(td.taskType.length > 0, "Task must have a task_type before spawning session");
		td.wasKilledByUser = false;

		// Look up the correct agent for this task's agent type
		auto taskAgent = agentForTask(tid);

		auto typeDef = getTaskTypes().byName(td.taskType);

		// Derive session config from task type definition
		SessionConfig sessionConfig;
		if (typeDef !is null)
		{
			sessionConfig.model = taskAgent.resolveModelAlias(typeDef.model_class);
			sessionConfig.appendSystemPrompt = loadSystemPrompt(*typeDef, taskTypesDir, td.outputPath);
		}
		sessionConfig.creatableTaskTypes = formatCreatableTaskTypes(getTaskTypes(), td.taskType);
		sessionConfig.switchModes = formatSwitchModes(getTaskTypes(), td.taskType);
		sessionConfig.handoffs = formatHandoffs(getTaskTypes(), td.taskType);
		sessionConfig.mcpSocketPath = mcpSocketPath;

		auto workDir = td.projectPath.length > 0 ? td.projectPath : null;

		// Ensure per-task directory exists
		import std.path : buildPath;
		if (td.taskDir.length > 0)
		{
			import std.file : mkdirRecurse;
			mkdirRecurse(td.taskDir);
		}

		// Use worktree path as chdir if available; sandbox covers project dir (rw)
		auto chdir = td.hasWorktree ? td.worktreePath : workDir;

		// Resolve sandbox config: agent defaults + global + per-agent + per-workspace
		auto wsSandbox = findWorkspaceSandbox(td.workspace);
		auto agentTypeSandbox = findAgentTypeSandbox(td.agentType);
		bool readOnly = typeDef !is null && typeDef.read_only;
		td.sandbox = resolveSandbox(config.sandbox, agentTypeSandbox, wsSandbox, taskAgent, workDir, readOnly);

		// Task directory is always writable (even for read-only tasks)
		if (td.taskDir.length > 0)
			td.sandbox.paths[td.taskDir] = PathMode.rw;

		// MCP socket must be accessible inside the sandbox
		if (mcpSocketPath.length > 0)
			td.sandbox.paths[mcpSocketPath] = PathMode.ro;

		// Set up shared /tmp: all tasks in a tree share the same host-backed directory
		td.sandbox.sharedTmpPath = resolveSharedTmpPath(tid);

		auto cmdPrefix = buildCommandPrefix(td.sandbox, chdir);

		// Pass workspace and working directory for agents that need them (Codex).
		sessionConfig.workspace = td.workspace;
		sessionConfig.workDir = chdir !is null ? chdir : "";
		if (taskAgent.needsBash())
			sessionConfig.includeTools ~= "Bash";
		if (sessionConfig.creatableTaskTypes.length > 0)
			sessionConfig.includeTools ~= "Task";
		if (sessionConfig.switchModes.length > 0)
			sessionConfig.includeTools ~= "SwitchMode";
		if (sessionConfig.handoffs.length > 0)
			sessionConfig.includeTools ~= "Handoff";
		if (getTaskTypes().isInteractive(td.taskType))
			sessionConfig.includeTools ~= "AskUserQuestion";

		if (typeDef !is null && typeDef.allow_native_subagents)
			sessionConfig.allowNativeSubagents = true;

		td.session = taskAgent.createSession(tid, td.agentSessionId, cmdPrefix, sessionConfig);
		persistence.clearLastActive(tid);

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

			if (taskAgent.isTurnResult(line))
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
				// Also check taskDeps for post-restart sub-tasks (no promise in pendingSubTasks).
				// Also close stdin for tasks with on_yield (they auto-continue on exit).
				auto onYieldTypeDef = getTaskTypes().byName(td.taskType);
				bool hasOnYield = onYieldTypeDef !is null && onYieldTypeDef.on_yield.task_type.length > 0;
				if (tid in pendingSubTasks || td.pendingContinuation.length > 0
					|| tid in taskDeps || hasOnYield)
				{
					td.processQueue.setGoal(ProcessState.Dead).ignoreResult();
					td.session.closeStdin();
				}
				else
				{
					td.status = "alive";
					persistence.setStatus(tid, "alive");
					td.needsAttention = true;
					td.notificationBody = td.resultText.length > 0 ? truncateTitle(td.resultText, 200) : extractLastAssistantText(tid);
					touchTask(tid);
					persistence.setLastActive(tid, tasks[tid].lastActive);
					try
						generateSuggestions(tid);
					catch (Exception e)
						warningf("Error generating suggestions: %s", e.msg);
				}
				broadcastTaskUpdate(tid);
			}
		};

		string lastStderr;

		td.session.onStderr = (string line) {
			import ae.utils.json : toJson;
			import cydo.agent.protocol : ProcessStderrEvent;
			ProcessStderrEvent ev;
			ev.text = line;
			broadcastTask(tid, toJson(ev));
			lastStderr = line;
		};

		td.session.onExit = (int exitCode) {
			// During shutdown, skip all exit handling so task status stays
			// "alive" in the DB and can be resumed after restart.
			if (shuttingDown)
				return;
			touchTask(tid);
			persistence.setLastActive(tid, tasks[tid].lastActive);
			import ae.utils.json : toJson;
			import cydo.agent.protocol : ProcessExitEvent;
			tracef("onExit: tid=%d exitCode=%d status=%s",
				tid, exitCode, tid in tasks ? tasks[tid].status : "(gone)");
			ProcessExitEvent ev;
			ev.code = exitCode;
			// Treat explicit user kill as non-clean exit for on_yield purposes.
			// Claude Code may exit with code 0 on SIGTERM, but killing should never trigger on_yield.
			auto cleanExit = exitCode == 0 && !tasks[tid].wasKilledByUser;
			auto onYieldDef = (cleanExit && tasks[tid].pendingContinuation.length == 0)
				? getTaskTypes().byName(tasks[tid].taskType) : null;
			bool hasOnYield = onYieldDef !is null && onYieldDef.on_yield.task_type.length > 0;
			if (cleanExit && (tasks[tid].pendingContinuation.length > 0 || hasOnYield))
				ev.is_continuation = true;
			broadcastTask(tid, toJson(ev));
			if (tid !in tasks)
				return;
			tasks[tid].isProcessing = false;
			if (exitCode != 0)
				tasks[tid].error = lastStderr;
			cleanup(tasks[tid].sandbox);
			jsonlTracker.stopJsonlWatch(tid);

			// Fulfill pending AskUserQuestion promise with error if session dies
			if (auto askPending = tid in pendingAskUserQuestions)
			{
				askPending.fulfill(McpResult("Session ended while waiting for user response", true));
				pendingAskUserQuestions.remove(tid);
				tasks[tid].pendingAskToolUseId = null;
				tasks[tid].pendingAskQuestions = JSONFragment.init;
				tasks[tid].needsAttention = false;
				tasks[tid].hasPendingQuestion = false;
				tasks[tid].notificationBody = "";
			}

			// Kill any in-flight one-shot subprocesses (title/suggestion generation).
			if (tasks[tid].titleGenKill !is null)
			{
				tasks[tid].titleGenKill();
				tasks[tid].titleGenKill = null;
			}
			if (tasks[tid].suggestGenKill !is null)
			{
				tasks[tid].suggestGenKill();
				tasks[tid].suggestGenKill = null;
			}

			// Force JSONL reload on next request_history so that
			// fork IDs from the file replace live-stream UUIDs.
			tasks[tid].history = DataVec();
			tasks[tid].historyLoaded = false;
			unsubscribeAll(tid);

			// --- StateQueue notification ---
			bool intentionalExit = tasks[tid].processQueue.goalState != ProcessState.Alive
				|| (tasks[tid].agentType == "codex" && exitCode == 143);

			if (tasks[tid].killPromise !is null)
			{
				// Active Dead transition in progress — fulfill its promise
				auto p = tasks[tid].killPromise;
				tasks[tid].killPromise = null;
				p.fulfill(ProcessState.Dead);
			}
			else
			{
				// No active Dead transition — unexpected external state change.
				tasks[tid].processQueue.setCurrentState(ProcessState.Dead);
				if (!intentionalExit)
					tasks[tid].processQueue.setGoal(ProcessState.Dead).ignoreResult();
			}

			if (!intentionalExit)
			{
				// Crash — fail the task immediately, no retry
				tasks[tid].status = "failed";
				if (tasks[tid].error.length == 0)
					tasks[tid].error = "Process exited unexpectedly";
				persistence.setStatus(tid, "failed");
				broadcastTaskUpdate(tid);
				return;
			}

			// Continuation: transition to successor instead of completing
			if (cleanExit && tasks[tid].pendingContinuation.length > 0)
			{
				spawnContinuation(tid);
				return;
			}

			// on_yield: auto-continuation on clean exit without explicit SwitchMode/Handoff
			if (hasOnYield)
			{
				infof("on_yield: tid=%d type=%s → %s",
					tid, tasks[tid].taskType, onYieldDef.on_yield.task_type);
				executeContinuation(tid, onYieldDef.on_yield, tasks[tid].resultText);
				return;
			}

			// Output enforcement: check declared outputs before completing.
			// Skip when user stopped the task — they may resume or abandon it.
			if (cleanExit)
			{
				auto missing = checkDeclaredOutputs(tid);
				if (missing !is null && !tasks[tid].outputEnforcementAttempted)
				{
					tasks[tid].outputEnforcementAttempted = true;
					infof("Output enforcement: tid=%d missing outputs, resuming: %s", tid, missing);
					auto enfMissing = missing;
					tasks[tid].processQueue.setGoal(ProcessState.Alive).then(() {
						auto msg = "[SYSTEM: Missing required outputs]\n\n"
							~ "Your task type declares outputs that were not produced:\n"
							~ enfMissing ~ "\n\n"
							~ "Please produce the missing output(s) before finishing. "
							~ "Write your report to your output file if you haven't already.";
						sendTaskMessage(tid, [ContentBlock("text", msg)]);
					}).ignoreResult();
					return; // Don't complete yet — wait for the agent to try again
				}
				if (missing !is null)
					warningf("Output enforcement: tid=%d still missing outputs after retry: %s", tid, missing);
			}

			tasks[tid].status = exitCode == 0 ? "completed" : "failed";
			persistence.setStatus(tid, tasks[tid].status);
			persistence.setResultText(tid, tasks[tid].resultText);

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
				auto taskResult = buildTaskResult(tid);
				auto resultJson = toJson(taskResult);
				pending.fulfill(McpResult(resultJson, !success, JSONFragment(resultJson)));
				pendingSubTasks.remove(tid);
				// Deps left intact — cleaned by onToolCallDelivered() on success,
				// or used by deliverBatchResults() as fallback if MCP delivery fails.
			}
			else if (auto parentTidPtr = tid in taskDeps)
			{
				// Post-restart path: no promise — batch deliver when all children done
				auto parentTid = *parentTidPtr;
				tracef("onExit Branch B: child tid=%d (status=%s) finished, parent tid=%d",
					tid, tasks[tid].status, parentTid);
				if (parentTid in tasks)
				{
					// Check if ALL children of this parent are completed/failed
					bool allDone = true;
					foreach (childTid, depParent; taskDeps)
					{
						if (depParent == parentTid && childTid in tasks
							&& tasks[childTid].status != "completed"
							&& tasks[childTid].status != "failed")
						{
							tracef("onExit Branch B: sibling tid=%d still %s, deferring batch delivery",
								childTid, tasks[childTid].status);
							allDone = false;
							break;
						}
					}

					if (allDone)
						deliverBatchResults(parentTid);
					// else: wait — remaining children will trigger this check
				}
				else
					tracef("onExit Branch B: parent tid=%d not in tasks", parentTid);
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
			broadcastTaskUpdate(tid);
		};

		td.status = "active";
		persistence.setStatus(tid, "active");
		td.error = null;
	}

	/// Returns a stateFunc delegate bound to a specific tid.
	/// Using a helper function (rather than an inline lambda in a foreach) avoids
	/// the D closure-capture bug where all loop iterations share the same `rowTid`.
	private Promise!ProcessState delegate(ProcessState) makeProcessQueueSF(int tid)
	{
		return (ProcessState goal) => processTransition(tid, goal);
	}

	private Promise!ProcessState processTransition(int tid, ProcessState goal)
	{
		if (tid !in tasks)
			return reject!ProcessState(new Exception("Task not found"));

		auto td = &tasks[tid];

		if (goal == ProcessState.Alive)
		{
			try
				spawnTaskSession(tid);
			catch (Exception e)
			{
				td.status = "failed";
				td.error = e.msg;
				persistence.setStatus(tid, "failed");
				broadcastTaskUpdate(tid);
				return reject!ProcessState(e);
			}
			broadcastTaskUpdate(tid);
			return resolve(ProcessState.Alive);
		}
		else  // Dead
		{
			// If session is already gone, resolve immediately.
			if (td.session is null || !td.session.alive)
				return resolve(ProcessState.Dead);
			// Don't actively kill — caller must initiate (closeStdin/stop).
			// Just wait for onExit to fulfill this promise.
			td.killPromise = new Promise!ProcessState;
			return td.killPromise;
		}
	}

	/// Execute a continuation transition — shared by explicit (SwitchMode/Handoff)
	/// and implicit (on_yield) paths.
	private void executeContinuation(int tid, ContinuationDef contDef, string handoffPrompt)
	{
		import ae.utils.json : toJson;

		auto td = &tasks[tid];

		auto newTypeDef = getTaskTypes().byName(contDef.task_type);
		if (newTypeDef is null)
		{
			errorf("executeContinuation: unknown successor type '%s' for tid=%d", contDef.task_type, tid);
			td.status = "failed";
			persistence.setStatus(tid, "failed");
			broadcastTaskUpdate(tid);
			return;
		}

		infof("Continuation: tid=%d %s → %s (keep_context=%s)",
			tid, td.taskType, contDef.task_type, contDef.keep_context);

		auto resultText = td.resultText;

		if (contDef.keep_context)
		{
			// Mutate task type in-place, resume the same session
			td.taskType = contDef.task_type;
			persistence.setTaskType(tid, contDef.task_type);

			// Notify frontends to re-request history
			broadcast(toJson(TaskReloadMessage("task_reload", tid, "continuation")));

			td.status = "active";
			persistence.setStatus(tid, "active");

			// Send the continuation's prompt template as first message to successor.
			auto renderedContinuationPrompt = renderContinuationPrompt(contDef,
				"Continue from where you left off.", taskTypesDir,
				["result_text": resultText, "output_dir": td.taskDir]);
			td.processQueue.setGoal(ProcessState.Alive).then(() {
				broadcastUnconfirmedUserMessage(tid, [ContentBlock("text", renderedContinuationPrompt)]);
				sendTaskMessage(tid, [ContentBlock("text", renderedContinuationPrompt)]);
				broadcastTaskUpdate(tid);
			}).ignoreResult();
		}
		else
		{
			// Complete the current task normally (preserving its history),
			// then create a new child task for the successor.
			td.status = "completed";
			persistence.setStatus(tid, "completed");

			// Notify frontends to re-request history
			broadcast(toJson(TaskReloadMessage("task_reload", tid, "continuation")));

			// Create child task for the successor with the handoff prompt
			auto successorPrompt = handoffPrompt.length > 0 ? handoffPrompt : td.description;
			auto childTid = createTask(td.workspace, td.projectPath, td.agentType);
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
			broadcastTaskUpdate(childTid);

			// If this task was itself a pending sub-task, move the promise
			// to the new child so the parent awaits the full chain
			if (auto pending = tid in pendingSubTasks)
			{
				pendingSubTasks[childTid] = *pending;
				pendingSubTasks.remove(tid);
				// Transfer dependency: the parent that was waiting on tid now waits on childTid
				persistence.removeAllChildDeps(tid);
				persistence.addTaskDep(td.parentTid, childTid);
				taskDeps.remove(tid);
				taskDeps[childTid] = td.parentTid;
			}

			// Set up worktree from edge config: create new or inherit from predecessor
			if (contDef.worktree)
				setupWorktree(childTid, true, "", td.hasWorktree ? td.worktreePath : "");
			else if (td.hasWorktree)
				setupWorktree(childTid, false, td.worktreePath);

			// Spawn the successor agent
			auto renderedSuccessorPrompt = renderPrompt(*newTypeDef, successorPrompt,
				taskTypesDir, childTd.outputPath, contDef.prompt_template,
				["result_text": resultText]);
			tasks[childTid].processQueue.setGoal(ProcessState.Alive).then(() {
				broadcastUnconfirmedUserMessage(childTid, [ContentBlock("text", renderedSuccessorPrompt)]);
				sendTaskMessage(childTid, [ContentBlock("text", renderedSuccessorPrompt)]);
			}).ignoreResult();

			broadcastTaskUpdate(tid);
		}
	}

	/// Transition a task to its successor via continuation.
	/// Called from onExit when pendingContinuation is set.
	private void spawnContinuation(int tid)
	{
		auto td = &tasks[tid];
		auto typeDef = getTaskTypes().byName(td.taskType);
		auto contKey = td.pendingContinuation;
		auto hPrompt = td.handoffPrompt;
		td.pendingContinuation = null;
		td.handoffPrompt = null;

		if (typeDef is null)
		{
			errorf("spawnContinuation: unknown task type '%s' for tid=%d", td.taskType, tid);
			td.status = "failed";
			persistence.setStatus(tid, "failed");
			broadcastTaskUpdate(tid);
			return;
		}

		auto contDefP = contKey in typeDef.continuations;
		if (contDefP is null)
		{
			errorf("spawnContinuation: unknown continuation '%s' for type '%s' tid=%d",
				contKey, td.taskType, tid);
			td.status = "failed";
			persistence.setStatus(tid, "failed");
			broadcastTaskUpdate(tid);
			return;
		}

		executeContinuation(tid, *contDefP, hPrompt);
	}

	private string defaultAgentType(string workspaceName)
	{
		foreach (ref ws; config.workspaces)
			if (ws.name == workspaceName && ws.default_agent_type.length > 0)
				return ws.default_agent_type;
		return config.default_agent_type;
	}

	private SandboxConfig findWorkspaceSandbox(string workspaceName)
	{
		foreach (ref ws; config.workspaces)
			if (ws.name == workspaceName)
				return ws.sandbox;
		return SandboxConfig.init;
	}

	private SandboxConfig findAgentTypeSandbox(string agentType)
	{
		if (config.agents !is null)
			if (auto ac = agentType in config.agents)
				return ac.sandbox;
		return SandboxConfig.init;
	}

	/// Check whether a completing task has produced all declared outputs.
	/// Returns null if all outputs are present, or a message describing what's missing.
	private string checkDeclaredOutputs(int tid)
	{
		import std.file : exists;

		auto td = &tasks[tid];
		auto typeDef = getTaskTypes().byName(td.taskType);
		if (typeDef is null || typeDef.output_type.length == 0)
			return null;

		string[] missing;

		foreach (ot; typeDef.output_type)
		{
			final switch (ot)
			{
			case OutputType.report:
				if (td.outputPath.length == 0 || !exists(td.outputPath))
					missing ~= "report (expected at " ~ td.outputPath ~ ")";
				break;

			case OutputType.worktree:
				// TODO: implement worktree/commit checks
				break;

			case OutputType.commit:
				// TODO: implement worktree/commit checks
				break;
			}
		}

		if (missing.length == 0)
			return null;

		import std.array : join;
		return "Missing declared outputs: " ~ missing.join(", ");
	}

	private TaskResult buildTaskResult(int tid)
	{
		import std.file : exists;
		auto td = &tasks[tid];
		bool hasOutput = td.outputPath.length > 0 && exists(td.outputPath);
		bool hasWorktree = td.hasWorktree;
		bool isFailed = td.status == "failed";
		string note;
		if (hasOutput && hasWorktree)
			note = "Read the output file for full findings. The worktree path is included for adopting changes.";
		else if (hasOutput)
			note = "Read the output file for full findings.";
		else if (hasWorktree)
			note = "The worktree contains the implementation.";
		return TaskResult(
			td.resultText,
			hasOutput ? td.outputPath : null,
			hasWorktree ? td.worktreePath : null,
			note.length > 0 ? note : td.resultNote,
			isFailed ? td.resultText : null,
		);
	}

	private void deliverBatchResults(int parentTid)
	{
		if (parentTid !in tasks)
			return;
		tasks[parentTid].processQueue.setGoal(ProcessState.Alive).then(() {
			actuallyDeliverBatchResults(parentTid);
		}).except((Exception e) {
			errorf("deliverBatchResults: failed for parent %d: %s", parentTid, e.msg);
		});
	}

	private void actuallyDeliverBatchResults(int parentTid)
	{
		import ae.utils.json : toJson;
		import std.array : join;

		if (parentTid !in tasks)
		{
			tracef("deliverBatchResults: parent tid=%d not in tasks, skipping", parentTid);
			return;
		}

		auto td = &tasks[parentTid];
		if (td.session is null || !td.session.alive)
		{
			warningf("actuallyDeliverBatchResults: parent tid=%d session %s, retrying via deliverBatchResults",
				parentTid, td.session is null ? "is null" : "not alive");
			deliverBatchResults(parentTid);
			return;
		}

		auto children = childrenOf(parentTid);
		if (children.length == 0)
		{
			tracef("deliverBatchResults: parent tid=%d has no children in taskDeps", parentTid);
			return;
		}

		string[] resultJsons;
		foreach (childTid; children)
		{
			if (childTid !in tasks)
				continue;
			resultJsons ~= toJson(buildTaskResult(childTid));
		}

		if (resultJsons.length == 0)
			return;

		infof("deliverBatchResults: delivering %d result(s) to parent tid=%d",
			resultJsons.length, parentTid);

		// Deliver single batch message
		auto resultsArray = "[" ~ resultJsons.join(",") ~ "]";
		auto msg =
			"[SYSTEM: Sub-task results]\n\n"
			~ "The following sub-task(s) completed while your session was interrupted. "
			~ "Their results are provided below exactly as they would have been "
			~ "returned by the Task tool.\n\n"
			~ "<task_results>\n" ~ resultsArray ~ "\n</task_results>\n\n"
			~ "Continue from where you left off. Process these results as if they "
			~ "were returned normally by the Task tool.";
		sendTaskMessage(parentTid, [ContentBlock("text", msg)]);

		// Clean up all deps
		foreach (childTid; children)
		{
			persistence.removeTaskDep(parentTid, childTid);
			taskDeps.remove(childTid);
		}

		// Transition parent
		if (td.status == "waiting")
		{
			td.status = "alive";
			persistence.setStatus(parentTid, "alive");
			broadcastTaskUpdate(parentTid);
		}
	}

	private void resumeInFlightTasks()
	{
		// Load persisted dependencies into memory.
		foreach (parentTid, children; persistence.loadTaskDeps())
			foreach (childTid; children)
				taskDeps[childTid] = parentTid;

		// Collect tasks that need resuming
		int[] toResume;
		foreach (ref td; tasks)
		{
			if (td.status == "alive" || td.status == "active" || td.status == "waiting")
				toResume ~= td.tid;
		}

		if (toResume.length == 0)
			return;

		infof("Resuming %d in-flight task(s) after restart", toResume.length);

		// Resume order doesn't matter: children that already completed have
		// their results in the DB; children still in-flight will deliver
		// results via the fallback onExit path when they eventually finish.
		foreach (tid; toResume)
		{
			if (tid !in tasks)
				continue;
			auto status = tasks[tid].status;

			if (status == "waiting")
			{
				// Check if all children already completed
				bool allChildrenDone = true;
				foreach (childTid, parentTid; taskDeps)
					if (parentTid == tid && childTid in tasks
						&& tasks[childTid].status != "completed" && tasks[childTid].status != "failed"
					&& tasks[childTid].status != "importable")
					{
						tracef("resumeInFlightTasks: tid=%d waiting, child tid=%d still %s",
							tid, childTid, tasks[childTid].status);
						allChildrenDone = false;
						break;
					}

				if (allChildrenDone)
				{
					tracef("resumeInFlightTasks: tid=%d waiting, all children done — resuming with batch delivery", tid);
					resumeAndDeliverResults(tid);
				}
				else
				{
					tracef("resumeInFlightTasks: tid=%d waiting, children still running — resuming without message", tid);
					resumeWaitingTask(tid);
				}
			}
			else if (status == "active")
			{
				resumeActiveTask(tid);
			}
			else if (status == "alive")
			{
				resumeTask(tid).ignoreResult();
			}
		}
	}

	private Promise!void resumeTask(int tid)
	{
		if (tid !in tasks)
			return resolve();
		auto td = &tasks[tid];
		auto savedStatus = td.status;
		return td.processQueue.setGoal(ProcessState.Alive).then(() {
			auto td = &tasks[tid];
			// spawnTaskSession sets status to "active"; restore the original status
			// for "alive" (idle) or "waiting" tasks so a subsequent restart handles
			// them properly.
			if (savedStatus != "active")
			{
				td.status = savedStatus;
				persistence.setStatus(tid, savedStatus);
			}
			broadcastTaskUpdate(tid);
		});
	}

	private void sendSystemNudge(int tid)
	{
		if (tid !in tasks)
			return;
		// Defer to event loop — resumeInFlightTasks runs before
		// socketManager.loop() so stdin writes would stall otherwise.
		import ae.net.asockets : onNextTick;
		socketManager.onNextTick(() {
			if (tid !in tasks)
				return;
			auto td = &tasks[tid];
			if (td.session is null || !td.session.alive)
				return;
			sendTaskMessage(tid, [ContentBlock("text",
				"[SYSTEM: Your session was interrupted by a backend restart. "
				~ "Continue from where you left off. If you had a tool call in progress "
				~ "(Task, Handoff, SwitchMode, or any other tool), retry it.]")]);
		});
	}

	/// Collect child tids for a given parent from the in-memory taskDeps map.
	private int[] childrenOf(int parentTid)
	{
		int[] children;
		foreach (childTid, depParent; taskDeps)
			if (depParent == parentTid)
				children ~= childTid;
		return children;
	}

	/// Returns true if any ancestor of `tid` (via parent_tid chain) is archived.
	private bool isEffectivelyArchivedByAncestor(int tid)
	{
		int current = tid;
		for (;;)
		{
			auto tdp = current in tasks;
			if (!tdp)
				return false;
			int parent = tdp.parentTid;
			if (parent <= 0 || parent == current)
				return false;
			auto parentTdp = parent in tasks;
			if (!parentTdp)
				return false;
			if (parentTdp.archived)
				return true;
			current = parent;
		}
	}

	/// Returns the tid of the first alive task in the subtree rooted at `tid`,
	/// or -1 if none are alive.
	private int findAliveInSubtree(int tid)
	{
		auto tdp = tid in tasks;
		if (tdp is null)
			return -1;
		if (tdp.alive)
			return tid;
		foreach (childTid, ref child; tasks)
			if (child.parentTid == tid)
			{
				int found = findAliveInSubtree(childTid);
				if (found >= 0)
					return found;
			}
		return -1;
	}

	/// Archive worktrees for task `tid` and all descendants via DFS.
	/// Skips if `tid` is already effectively archived by an ancestor.
	private void archiveWorktreesForTask(int tid)
	{
		if (isEffectivelyArchivedByAncestor(tid))
			return;
		archiveWorktreesDFS(tid, false);
	}

	/// Unarchive worktrees for task `tid` and all descendants via DFS.
	/// Skips if `tid` is still effectively archived by an ancestor.
	private void unarchiveWorktreesForTask(int tid)
	{
		if (isEffectivelyArchivedByAncestor(tid))
			return;
		unarchiveWorktreesDFS(tid, false);
	}

	/// DFS archive: process this task's worktree, then recurse to children.
	/// `parentEffectivelyArchived` is true if an ancestor in this walk was
	/// already directly archived (meaning its subtree was handled earlier).
	private void archiveWorktreesDFS(int tid, bool parentEffectivelyArchived)
	{
		import std.path : buildPath;

		auto tdp = tid in tasks;
		if (tdp is null)
			return;

		// If this descendant is directly archived, its worktrees were already
		// handled when it was archived individually — prune this subtree.
		if (parentEffectivelyArchived && tdp.archived)
			return;

		if (tdp.hasWorktree && tdp.taskDir.length > 0)
		{
			if (tdp.ownsWorktree())
				archiveWorktree(tdp.worktreePath, tdp.projectPath, tid);
			else
			{
				// Inherited worktree via symlink: remove to avoid dangling
				import std.file : exists, remove;
				auto wtPath = buildPath(tdp.taskDir, "worktree");
				if (exists(wtPath))
					remove(wtPath);
			}
		}

		// Recurse to structural children
		foreach (childTid, ref child; tasks)
			if (child.parentTid == tid)
				archiveWorktreesDFS(childTid, true);
	}

	/// DFS unarchive: process this task's worktree, then recurse to children.
	private void unarchiveWorktreesDFS(int tid, bool parentEffectivelyArchived)
	{
		import std.file : exists, symlink;
		import std.path : buildPath;

		auto tdp = tid in tasks;
		if (tdp is null)
			return;

		// If this descendant is directly archived, it remains effectively
		// archived — don't restore its subtree.
		if (parentEffectivelyArchived && tdp.archived)
			return;

		if (tdp.hasWorktree && tdp.taskDir.length > 0)
		{
			auto wtPath = buildPath(tdp.taskDir, "worktree");
			if (hasArchiveRef(tdp.projectPath, tid))
				unarchiveWorktree(tdp.projectPath, tid, wtPath);
			else if (!exists(wtPath))
			{
				// Inherited worktree via symlink: recreate it
				string ownerPath = findOwnerWorktreePath(tid);
				if (ownerPath.length > 0)
					symlink(ownerPath, wtPath);
				else
					warningf("unarchiveWorktreesDFS: could not find worktree owner for tid=%d", tid);
			}
		}

		// Recurse to structural children
		foreach (childTid, ref child; tasks)
			if (child.parentTid == tid)
				unarchiveWorktreesDFS(childTid, true);
	}

	/// Find the root task ID by walking parentTid to the top of the tree.
	private int findRootTid(int tid)
	{
		int current = tid;
		for (;;)
		{
			auto tdp = current in tasks;
			if (tdp is null)
				return current;
			if (tdp.parentTid <= 0 || tdp.parentTid == current)
				return current;
			current = tdp.parentTid;
		}
	}

	/// Resolve the shared /tmp host path for a task.
	/// All tasks in a tree share the same directory, keyed by root task ID.
	/// Creates the directory on first access.
	private string resolveSharedTmpPath(int tid)
	{
		import std.conv : to;
		import std.file : mkdirRecurse, exists;
		import std.path : buildPath;

		int rootTid = findRootTid(tid);
		auto path = buildPath(runtimeDir(), "tmp-" ~ rootTid.to!string);
		if (!exists(path))
			mkdirRecurse(path);
		return path;
	}

	/// Remove the shared /tmp directory for this task's tree if this task is the root.
	private void cleanupSharedTmp(int tid)
	{
		import std.conv : to;
		import std.file : exists, rmdirRecurse;
		import std.path : buildPath;

		int rootTid = findRootTid(tid);
		auto rootTd = rootTid in tasks;
		if (rootTd is null)
			return;
		if (rootTid != tid && !rootTd.archived)
			return; // root is still active, don't clean up

		auto path = buildPath(runtimeDir(), "tmp-" ~ rootTid.to!string);
		if (exists(path))
		{
			try
				rmdirRecurse(path);
			catch (Exception e)
				warningf("cleanupSharedTmp: failed to remove %s: %s", path, e.msg);
		}
	}

	/// Walk the parent_tid chain from `tid` to find the owning task's worktree path.
	private string findOwnerWorktreePath(int tid)
	{
		import std.path : buildPath;
		int current = tasks[tid].parentTid;
		while (current > 0 && current in tasks)
		{
			auto td = &tasks[current];
			if (td.hasWorktree && td.ownsWorktree())
				return buildPath(td.taskDir, "worktree");
			current = td.parentTid;
		}
		return "";
	}

	private void resumeAndDeliverResults(int tid)
	{
		resumeTask(tid).then(() {
			deliverBatchResults(tid);
		}).ignoreResult();
	}

	private void resumeWaitingTask(int tid)
	{
		resumeTask(tid).ignoreResult();
	}

	/// Resume an "active" task and send it a system nudge once alive.
	/// Using a helper function (rather than an inline lambda in a foreach) avoids
	/// the D closure-capture bug where all loop iterations share the same `tid`.
	private void resumeActiveTask(int tid)
	{
		resumeTask(tid).then(() {
			sendSystemNudge(tid);
		}).ignoreResult();
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
	/// This is shown as pending until Claude echoes it back with is_replay.
	private void broadcastUnconfirmedUserMessage(int tid, const(ContentBlock)[] content)
	{
		import ae.utils.json : toJson;
		import cydo.agent.protocol : ItemStartedEvent;

		ItemStartedEvent ev;
		ev.item_id   = "cc-user-msg";
		ev.item_type = "user_message";
		ev.text      = extractContentText(content);
		ev.content   = content.dup;
		ev.pending   = true;
		auto userEvent = toJson(ev);
		string injected = `{"tid":` ~ format!"%d"(tid)
			~ `,"unconfirmedUserEvent":` ~ userEvent ~ `}`;

		auto data = Data(injected.representation);

		if (tid in tasks)
		{
			ensureHistoryLoaded(tid);
			tasks[tid].history ~= data;
		}

		sendToSubscribed(tid, data);
	}

	private void broadcastTask(int tid, string rawLine)
	{
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
					td.enqueuedSteeringRawLines ~= rawLine;
					return; // already displayed via unconfirmedUserEvent
				}
				else if (op.operation == "dequeue")
				{
					if (td.enqueuedSteeringTexts.length > 0)
					{
						td.enqueuedSteeringTexts = td.enqueuedSteeringTexts[1 .. $];
						td.enqueuedSteeringRawLines = td.enqueuedSteeringRawLines[1 .. $];
					}
					return; // the real message/user follows
				}
				else if (op.operation == "remove")
				{
					if (td.enqueuedSteeringTexts.length > 0)
					{
						auto text = td.enqueuedSteeringTexts[0];
						auto enqueueRaw = td.enqueuedSteeringRawLines[0];
						td.enqueuedSteeringTexts = td.enqueuedSteeringTexts[1 .. $];
						td.enqueuedSteeringRawLines = td.enqueuedSteeringRawLines[1 .. $];
						// Broadcast synthetic steering confirmation
						import cydo.agent.protocol : injectRawField;
						auto steeringEvent = buildSyntheticUserEvent(text, true);
						if (enqueueRaw.length > 0)
							steeringEvent = injectRawField(steeringEvent, enqueueRaw);
						string injected = `{"tid":` ~ format!"%d"(tid)
							~ `,"event":` ~ steeringEvent ~ `}`;
						auto data = Data(injected.representation);
						ensureHistoryLoaded(tid);
						td.history ~= data;
						sendToSubscribed(tid, data);
					}
					return;
				}
			}
			return; // unknown queue operation — consume silently
		}

		// Translate to agent-agnostic protocol (returns zero or more events).
		auto translatedEvents = agentForTask(tid).translateLiveEvent(rawLine);

		import cydo.agent.protocol : stripRawField;

		foreach (translated; translatedEvents)
		{
			if (tid in tasks)
			{
				ensureHistoryLoaded(tid);
				// Store full event (with _raw) in history.
				string historyEnvelope = `{"tid":` ~ format!"%d"(tid) ~ `,"event":` ~ translated ~ `}`;
				auto historyData = Data(historyEnvelope.representation);
				// Merge adjacent item/delta events with matching item_id to keep
				// history compact without reordering events.
				if (!mergeStreamingDelta(tid, translated, historyData))
					tasks[tid].history ~= historyData;
			}

			// Send to clients: strip _raw, add _seq.
			auto stripped = stripRawField(translated);
			auto seq = (tid in tasks) ? tasks[tid].history.length - 1 : 0;
			string clientEnvelope = `{"tid":` ~ format!"%d"(tid)
				~ `,"seq":` ~ format!"%d"(seq)
				~ `,"event":` ~ stripped ~ `}`;
			sendToSubscribed(tid, Data(clientEnvelope.representation));
		}
	}

	/// Try to merge an item/delta into the last history entry.
	/// Returns true if merged (caller should NOT append), false otherwise.
	private bool mergeStreamingDelta(int tid, string translated, Data data)
	{
		import std.algorithm : canFind;

		// Only merge item/delta events.
		if (!translated.canFind(`"type":"item/delta"`))
			return false;

		auto history = &tasks[tid].history;
		if (history.length == 0)
			return false;

		auto lastEntry = cast(const(char)[])(*history)[$ - 1].unsafeContents;
		if (lastEntry.length > 64 * 1024)
			return false;
		if (!lastEntry.canFind(`"type":"item/delta"`) &&
		    !lastEntry.canFind(`"type":"item\/delta"`))
			return false;

		// Both are item/delta — check that item_id matches.
		auto lastId = extractItemId(lastEntry);
		auto newId = extractItemId(translated);
		if (lastId is null || newId is null || lastId != newId)
			return false;

		// Merge: concatenate the `content` fields.
		auto merged = mergeItemDeltas(lastEntry, translated);
		if (merged is null)
			return false;

		// Reconstruct canonical envelope (_raw stripped).
		import std.json : parseJSON;
		auto mergedObj = parseJSON(merged);
		if ("_raw" in mergedObj["event"].objectNoRef)
			mergedObj["event"].objectNoRef.remove("_raw");
		string canonical = `{"tid":` ~ format!"%d"(tid) ~ `,"event":` ~ mergedObj["event"].toString() ~ `}`;
		(*history)[$ - 1] = Data(canonical.representation);
		return true;
	}

	/// Extract the "item_id" string value from an item/delta event string.
	/// Returns null if not found.
	private static string extractItemId(const(char)[] s)
	{
		import std.string : indexOf;
		enum key = `"item_id":"`;
		auto idx = s.indexOf(key);
		if (idx < 0)
			return null;
		auto start = idx + key.length;
		auto end = s.indexOf('"', start);
		if (end < 0 || end <= start)
			return null;
		return cast(string) s[start .. end];
	}

	/// Merge two item/delta envelope strings by concatenating content.
	/// Returns the merged envelope string, or null if merging failed.
	private string mergeItemDeltas(const(char)[] lastEnvelope, string newTranslated)
	{
		import std.json : parseJSON, JSONValue, JSONType;

		JSONValue lastJson, newEventJson;
		try
		{
			lastJson = parseJSON(lastEnvelope);
			newEventJson = parseJSON(newTranslated);
		}
		catch (Exception e)
		{ tracef("mergeItemDeltas: JSON parse error: %s", e.msg); return null; }

		auto lastEvent = lastJson["event"];
		// Concatenate the `content` field.
		if (auto lastContent = "content" in lastEvent.objectNoRef)
		{
			if (auto newContent = "content" in newEventJson.objectNoRef)
			{
				(*lastContent).str = (*lastContent).str ~ (*newContent).str;
				return lastJson.toString();
			}
		}

		return null;
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

	private void broadcastSuggestionsUpdate(int tid, string[] suggestions)
	{
		import ae.utils.json : toJson;
		broadcast(toJson(SuggestionsUpdateMessage("suggestions_update", tid, suggestions)));
	}

	private void handlePromoteTaskMsg(WsMessage json)
	{
		auto tid = json.tid;
		if (tid < 0 || tid !in tasks)
			return;
		auto td = &tasks[tid];
		if (td.status != "importable")
			return;
		td.status = "completed";
		persistence.setStatus(tid, "completed");
		broadcastTaskUpdate(tid);
	}

	/// Enumerate external sessions and create importable tasks for new ones.
	private void enumerateSessions()
	{
		// Collect all known agent session IDs (agentType ~ "\0" ~ sessionId for uniqueness)
		bool[string] knownSessionIds;
		foreach (ref td; tasks)
			if (td.agentSessionId.length > 0)
				knownSessionIds[td.agentType ~ "\0" ~ td.agentSessionId] = true;

		// Load cache into memory map keyed by agentType ~ "\0" ~ sessionId
		Persistence.CacheRow[string] cacheMap;
		foreach (row; persistence.loadSessionMetaCache())
			cacheMap[row.agentType ~ "\0" ~ row.sessionId] = row;

		// Snapshot agent references for background thread
		Agent[] agentList;
		string[] agentTypeNames;
		foreach (name, a; agentsByType)
		{
			agentList ~= a;
			agentTypeNames ~= name;
		}

		// Orphan cleanup: remove importable tasks whose files no longer exist
		{
			int[] toDelete;
			foreach (ref td; tasks)
			{
				if (td.status != "importable")
					continue;
				try
				{
					auto ta = agentForTask(td.tid);
					auto jp = ta.historyPath(td.agentSessionId, td.effectiveCwd);
					import std.file : exists;
					if (jp.length == 0 || !exists(jp))
						toDelete ~= td.tid;
				}
				catch (Exception)
					toDelete ~= td.tid;
			}
			foreach (delTid; toDelete)
			{
				tasks.remove(delTid);
				persistence.deleteTask(delTid);
				broadcast(toJson(TaskDeletedMessage("task_deleted", delTid)));
			}
		}

		// Capture cache keys for orphan cache cleanup after scan
		string[] cacheKeys = cacheMap.keys;

		// Snapshot known project paths for background thread project matching
		string[] knownProjectPaths;
		foreach (ref wi; workspacesInfo)
			foreach (ref pi; wi.projects)
				knownProjectPaths ~= pi.path;

		// Launch background discovery scan (captures agentList, agentTypeNames,
		// knownSessionIds, cacheMap, knownProjectPaths by value — safe for background thread)
		threadAsync({
			DiscoveryResult[] results;
			foreach (idx, agent; agentList)
			{
				auto agentType = agentTypeNames[idx];
				DiscoveredSession[] discovered;
				try
					discovered = agent.enumerateAllSessions();
				catch (Exception e)
				{
					warningf("enumerateSessions: error enumerating %s sessions: %s",
						agentType, e.msg);
					continue;
				}

				foreach (ref ds; discovered)
				{
					auto compositeKey = agentType ~ "\0" ~ ds.sessionId;
					if (compositeKey in knownSessionIds)
						continue;

					auto cachedp = compositeKey in cacheMap;

					DiscoveryResult dr;
					dr.agentType = agentType;
					dr.sessionId = ds.sessionId;
					dr.mtime = ds.mtime;
					dr.enumProjectPath = ds.projectPath.length > 0
						? ds.projectPath
						: agent.matchProject(ds.sessionId, knownProjectPaths);

					if (cachedp !is null && cachedp.mtime == ds.mtime)
					{
						dr.title = cachedp.title;
						dr.projectPath = cachedp.projectPath;
						dr.fromCache = true;
					}
					else
					{
						try
						{
							auto meta = agent.readSessionMeta(ds.sessionId);
							dr.title = meta.title;
							dr.projectPath = meta.projectPath;
						}
						catch (Exception e)
							warningf("enumerateSessions: error reading meta for %s/%s: %s",
								agentType, ds.sessionId, e.msg);
						dr.fromCache = false;
					}
					results ~= dr;
				}
			}
			return results;
		}).then((DiscoveryResult[] results) {
			// Track discovered (agentType, sessionId) for cache orphan cleanup
			bool[string] discoveredKeys;
			foreach (ref r; results)
				discoveredKeys[r.agentType ~ "\0" ~ r.sessionId] = true;

			persistence.db.db.exec("BEGIN TRANSACTION;");
			scope(success) persistence.db.db.exec("COMMIT TRANSACTION;");
			scope(failure) persistence.db.db.exec("ROLLBACK TRANSACTION;");

			// Delete orphaned cache entries (sessions that disappeared)
			foreach (key; cacheKeys)
				if (key !in discoveredKeys)
				{
					import std.string : indexOf;
					auto sep = key.indexOf('\0');
					if (sep >= 0)
						persistence.deleteSessionMetaCacheEntry(key[0 .. sep], key[sep + 1 .. $]);
				}

			foreach (ref r; results)
			{
				// Re-check: a new task might have been created during the scan
				bool alreadyKnown = false;
				foreach (ref td; tasks)
					if (td.agentSessionId == r.sessionId && td.agentType == r.agentType)
					{ alreadyKnown = true; break; }
				if (alreadyKnown)
					continue;

				string finalProjectPath = r.projectPath.length > 0 ? r.projectPath : r.enumProjectPath;
				string finalTitle;
				if (r.title.length > 0)
					finalTitle = r.title;
				else
				{
					import std.algorithm : min;
					finalTitle = r.sessionId[0 .. min(8, $)] ~ "…";
				}

				if (!r.fromCache)
					persistence.upsertSessionMetaCache(r.agentType, r.sessionId, r.mtime,
						finalProjectPath, finalTitle);

				// Match workspace by project path
				string workspace = "";
				foreach (ref wi; workspacesInfo)
					if (wi.projects !is null)
						foreach (ref pi; wi.projects)
							if (pi.path == finalProjectPath)
							{ workspace = wi.name; break; }

				// Create importable task row
				auto tid = createTask(workspace, finalProjectPath, r.agentType);
				auto td = &tasks[tid];
				td.status = "importable";
				td.agentSessionId = r.sessionId;
				td.title = finalTitle;
				td.lastActive = r.mtime;
				td.historyLoaded = false;
				persistence.setStatus(tid, "importable");
				persistence.setAgentSessionId(tid, r.sessionId);
				persistence.setTitle(tid, finalTitle);
				persistence.setLastActive(tid, r.mtime);

				broadcast(toJson(TaskCreatedMessage("task_created", tid, workspace, finalProjectPath, 0, "")));
				broadcastTaskUpdate(tid);
			}
		}).ignoreResult();
	}

	/// Discover projects in all configured workspaces and populate workspacesInfo.
	private void discoverAllWorkspaces()
	{
		import std.json : parseJSON;
		import std.process : execute;

		workspacesInfo = null;
		foreach (ref ws; config.workspaces)
		{
			auto sandbox = resolveSandboxForDiscovery(
				config.sandbox, ws.sandbox, ws.root, cydoBinaryDir());
			auto cmdPrefix = buildCommandPrefix(sandbox, "/");
			auto isProjectJson = ws.project_discovery.is_project.isConfigured
				? ws.project_discovery.is_project.toJson().toString()
				: "";
			auto recurseWhenJson = ws.project_discovery.recurse_when.isConfigured
				? ws.project_discovery.recurse_when.toJson().toString()
				: "";
			auto cmd = (cmdPrefix !is null ? cmdPrefix : []) ~ cydoBinaryPath
				~ ["discover", ws.root, ws.name, isProjectJson, recurseWhenJson]
				~ ws.exclude;

			auto result = execute(cmd);
			sandbox.cleanup();

			if (result.status != 0)
			{
				warningf("Discovery failed for workspace '%s': exit %d", ws.name, result.status);
				workspacesInfo ~= WorkspaceInfo(ws.name, null, ws.default_agent_type);
				continue;
			}

			ProjectInfo[] projInfos;
			try
			{
				auto json = parseJSON(result.output);
				foreach (entry; json.array)
					projInfos ~= ProjectInfo(entry["name"].str, entry["path"].str);
			}
			catch (Exception e)
				warningf("Discovery JSON parse failed for workspace '%s': %s", ws.name, e.msg);

			workspacesInfo ~= WorkspaceInfo(ws.name, projInfos, ws.default_agent_type);

			infof("Workspace '%s' (%s): %d project(s)", ws.name, ws.root, projInfos.length);
			foreach (ref p; projInfos)
				infof("  - %s (%s)", p.name, p.path);
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
			warningf("Config directory %s does not exist, skipping config watch", cfgDir);
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
		infof("Config file changed, reloading...");
		auto result = reloadConfig();
		if (result.isNull())
		{
			warningf("Config reload failed (parse error), keeping current config");
			return;
		}
		config = result.get();
		foreach (agentType, a; agentsByType)
		{
			if (auto ac = agentType in config.agents)
				a.setModelAliases(ac.model_aliases);
			else
				a.setModelAliases(null);
		}
		discoverAllWorkspaces();
		broadcast(buildWorkspacesList());
		infof("Config reloaded successfully");
	}

	private void handleRefreshWorkspacesMsg()
	{
		discoverAllWorkspaces();
		broadcast(buildWorkspacesList());
		enumerateSessions();
	}

	/// Read a prompt template file from the task types directory and substitute variables.
	private string readPromptFile(string relativePath, string[string] vars)
	{
		import std.file : exists, readText;
		import std.path : buildPath;

		auto path = buildPath(taskTypesDir, relativePath);
		if (!exists(path))
		{
			warningf("Prompt file not found: %s", path);
			return "";
		}
		return substituteVars(readText(path), vars);
	}

	/// Spawn a lightweight claude process to generate a concise title
	/// from the user's initial message.
	private void generateTitle(int tid, string userMessage)
	{
		auto td = &tasks[tid];

		if (td.titleGenDone || td.titleGenHandle !is null)
			return;

		auto msg = userMessage.length > 500 ? userMessage[0 .. 500] : userMessage;
		auto prompt = readPromptFile("prompts/generate-title.md", ["user_message": msg]);
		if (prompt.length == 0)
			return;

		auto titleHandle = agentForTask(tid).completeOneShot(prompt, "small");
		td.titleGenHandle = titleHandle.promise;
		td.titleGenKill = titleHandle.cancel;
		td.titleGenHandle.then((string title) {
			if (tid !in tasks)
				return;
			tasks[tid].titleGenHandle = null;
			tasks[tid].titleGenKill = null;
			tasks[tid].titleGenDone = true;
			if (title.length > 0 && title.length < 200)
			{
				tasks[tid].title = title;
				persistence.setTitle(tid, title);
				broadcastTitleUpdate(tid, title);
			}
		}).except((Exception e) {
			if (tid !in tasks)
				return;
			tasks[tid].titleGenHandle = null;
			tasks[tid].titleGenKill = null;
			import ae.utils.json : toJson;
			import cydo.agent.protocol : ProcessStderrEvent;
			ProcessStderrEvent ev;
			ev.text = "failed to generate title: " ~ e.msg;
			broadcastTask(tid, toJson(ev));
		}).ignoreResult();

	}

	private void broadcast(string message)
	{
		auto data = Data(message.representation);
		foreach (ws; clients)
			ws.send(data);
	}

	private void touchTask(int tid)
	{
		import std.datetime : Clock;
		tasks[tid].lastActive = Clock.currStdTime;
	}

	private TaskListEntry buildTaskEntry(ref TaskData td)
	{
		import cydo.task : stdTimeToUnixMillis;
		return TaskListEntry(td.tid, td.alive,
			td.agentSessionId.length > 0 && !td.alive && td.status != "importable",
			td.isProcessing, td.needsAttention, td.hasPendingQuestion, td.notificationBody,
			td.title, td.workspace, td.projectPath, td.parentTid, td.relationType, td.status,
			td.taskType, td.archived, td.draft, td.error,
			stdTimeToUnixMillis(td.createdAt), stdTimeToUnixMillis(td.lastActive));
	}

	private string buildTasksList()
	{
		import ae.utils.json : toJson;

		TaskListEntry[] entries;
		foreach (ref td; tasks)
			entries ~= buildTaskEntry(td);
		return toJson(TasksListMessage("tasks_list", entries));
	}

	private void broadcastTaskUpdate(int tid)
	{
		import ae.utils.json : toJson;

		broadcast(toJson(TaskUpdatedMessage("task_updated", buildTaskEntry(tasks[tid]))));
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
			entries ~= TaskTypeListEntry(def.name, def.display_name, def.description, def.model_class, def.read_only, def.icon, def.user_visible);
		return toJson(TaskTypesListMessage("task_types_list", entries));
	}

	private string buildAgentTypesList()
	{
		import ae.utils.json : toJson;
		import cydo.agent.registry : agentRegistry;

		AgentTypeListEntry[] entries;
		foreach (ref entry; agentRegistry)
			entries ~= AgentTypeListEntry(entry.name, entry.displayName, entry.resolveBinary().length > 0);
		return toJson(AgentTypesListMessage("agent_types_list", entries, config.default_agent_type));
	}

	private string buildServerStatus()
	{
		import ae.utils.json : toJson;
		return toJson(ServerStatusMessage("server_status", authUser.length > 0 || authPass.length > 0));
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
		if (td.wasKilledByUser)
			return;

		// Don't spawn if a suggestion generation is already in-flight
		if (td.suggestGenHandle !is null)
			return;

		// Only generate when someone is actually viewing this task
		if (!hasSubscribers(tid))
		{
			tracef("generateSuggestions[%d]: no subscribers, skipping", tid);
			return;
		}

		auto history = buildAbbreviatedHistory(tid);
		if (history.length == 0)
		{
			tracef("generateSuggestions[%d]: empty history, skipping", tid);
			return;
		}

		auto prompt = readPromptFile("prompts/generate-suggestions.md", ["conversation": history]);
		if (prompt.length == 0)
		{
			warningf("generateSuggestions[%d]: prompt file not found or empty", tid);
			return;
		}
		tracef("generateSuggestions[%d]: spawning one-shot (history.length=%d)", tid, history.length);

		td.suggestGeneration++;
		auto capturedGen = td.suggestGeneration;

		auto suggestHandle = agentForTask(tid).completeOneShot(prompt, "small");
		td.suggestGenHandle = suggestHandle.promise;
		td.suggestGenKill = suggestHandle.cancel;
		td.suggestGenHandle.then((string result) {
			if (tid !in tasks)
				return;
			if (tasks[tid].suggestGeneration != capturedGen)
				return;
			tasks[tid].suggestGenHandle = null;
			tasks[tid].suggestGenKill = null;


				import ae.utils.json : jsonParse;
				string[] suggestionList;
				try
					suggestionList = jsonParse!(string[])(result);
				catch (Exception e)
				{ warningf("generateSuggestions: failed to parse result: %s", e.msg); return; }

			if (suggestionList.length > 0)
			{
				tasks[tid].lastSuggestions = suggestionList;
				broadcastSuggestionsUpdate(tid, suggestionList);
			}
		}).except((Exception e) {
			warningf("generateSuggestions[%d]: one-shot failed: %s", tid, e.msg);
			if (tid !in tasks)
				return;
			tasks[tid].suggestGenHandle = null;
			tasks[tid].suggestGenKill = null;
		}).ignoreResult();

	}

	/// Build an abbreviated conversation history string for suggestion generation.
	private string buildAbbreviatedHistory(int tid)
	{
		if (tid !in tasks)
			return "";

		// First pass: count stats for structured header
		int userMsgCount = 0;
		int toolUseCount = 0;
		foreach (ref d; tasks[tid].history)
		{
			auto envelope = cast(string) d.toGC();
			auto event = extractEventFromEnvelope(envelope);
			if (event.length == 0)
				continue;
			import std.algorithm : canFind;
			if (event.canFind(`"message/user"`))
				userMsgCount++;
			if (event.canFind(`"tool_use"`))
				toolUseCount++;
		}

		// Second pass: build entries (same logic as before)
		string[] entries;
		size_t totalLen = 0;
		enum maxLen = 2_500;
		enum truncThreshold = 256;

		bool seenAssistantText = false;
		bool turnCollapsed = false;

		foreach_reverse (ref d; tasks[tid].history)
		{
			auto envelope = cast(string) d.toGC();
			auto event = extractEventFromEnvelope(envelope);
			if (event.length == 0)
				continue;

			import std.algorithm : canFind;

			string entry;

			if (event.canFind(`"message/user"`))
			{
				auto text = extractMessageText(event);
				if (text.length > 0)
				{
					seenAssistantText = false;
					turnCollapsed = false;
					entry = "USER: " ~ abbreviateText(text, truncThreshold);
				}
				else
					continue;
			}
			else if (event.canFind(`"message/assistant"`) || event.canFind(`"turn/result"`))
			{
				auto text = extractMessageText(event);
				if (text.length == 0)
					continue;

				if (!seenAssistantText)
				{
					seenAssistantText = true;
					entry = "A: " ~ abbreviateText(text, truncThreshold);
				}
				else
				{
					if (!turnCollapsed)
					{
						turnCollapsed = true;
						entry = "[...]";
					}
					else
						continue;
				}
			}
			else if (event.canFind(`"tool_use"`) || event.canFind(`"tool_result"`))
			{
				if (seenAssistantText)
				{
					if (!turnCollapsed)
					{
						turnCollapsed = true;
						entry = "[...]";
					}
					else
						continue;
				}
				else
					continue;
			}
			else
				continue;

			totalLen += entry.length;
			if (totalLen > maxLen)
				break;

			entries ~= entry;
		}

		import std.algorithm : reverse;
		entries.reverse();

		// Structured context: header + last 4 entries only
		if (entries.length > 4)
			entries = entries[$ - 4 .. $];

		import std.conv : to;
		import std.array : join;
		string header = "[Session: " ~ userMsgCount.to!string ~ " user messages, "
			~ toolUseCount.to!string ~ " tool uses]\n\n";

		return header ~ entries.join("\n\n");
	}

	/// Extract text content from a translated protocol event (message/user,
	/// message/assistant, turn/result). Handles both string and array content.
	private static string extractMessageText(string event)
	{
		import ae.utils.json : jsonParse, JSONPartial;

		// Try string content first (user messages)
		@JSONPartial
		static struct StringMsg { string content; }
		@JSONPartial
		static struct StringProbe { StringMsg message; bool pending; }

		try
		{
			auto probe = jsonParse!StringProbe(event);
			if (probe.message.content.length > 0 && !probe.pending)
				return probe.message.content;
		}
		catch (Exception) {}

		// Try flat array content (agnostic assistant messages: content at top level)
		@JSONPartial
		static struct Block { string type; string text; }
		@JSONPartial
		static struct FlatProbe { Block[] content; }

		try
		{
			auto probe = jsonParse!FlatProbe(event);
			string result;
			foreach (ref block; probe.content)
				if (block.type == "text")
					result ~= block.text;
			if (result.length > 0)
				return result;
		}
		catch (Exception) {}

		// Try wrapped array content (legacy format with message wrapper)
		@JSONPartial
		static struct ArrayMsg { Block[] content; }
		@JSONPartial
		static struct ArrayProbe { ArrayMsg message; }

		try
		{
			auto probe = jsonParse!ArrayProbe(event);
			string result;
			foreach (ref block; probe.message.content)
				if (block.type == "text")
					result ~= block.text;
			return result;
		}
		catch (Exception e)
		{ tracef("extractAssistantText: all parse attempts failed: %s", e.msg); return ""; }
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

/// Set globalLogLevel from CYDO_LOG_LEVEL env var (trace/info/warning/error).
/// Defaults to info.
private void initLogLevel()
{
	import std.logger : sharedLog, LogLevel;
	import std.process : environment;

	auto level = environment.get("CYDO_LOG_LEVEL", "info");
	switch (level)
	{
		case "trace":    (cast()sharedLog).logLevel = LogLevel.trace; break;
		case "info":     (cast()sharedLog).logLevel = LogLevel.info; break;
		case "warning":  (cast()sharedLog).logLevel = LogLevel.warning; break;
		case "error":    (cast()sharedLog).logLevel = LogLevel.error; break;
		default:         (cast()sharedLog).logLevel = LogLevel.info; break;
	}
}

/// Replace the text content in a user message JSONL line.
/// Handles both string content and array-of-blocks content.
private string replaceUserMessageContent(string line, string newContent)
{
	import std.json : parseJSON, JSONValue;

	auto json = parseJSON(line);
	if ("message" in json)
		json["message"]["content"] = JSONValue(newContent);
	return json.toString();
}
