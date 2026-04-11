module cydo.app;

import core.lifetime : move;
import core.time : seconds;

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
import ae.utils.promise : Promise, PromiseQueue, resolve, reject;
import std.typecons : Nullable;
import ae.utils.promise.concurrency : threadAsync;
import ae.utils.statequeue : StateQueue;

mixin SSLUseLib;

import cydo.mcp : McpResult;
import cydo.mcp.tools : AskQuestion, ToolsBackend;
import cydo.task : BatchSignal;

import cydo.agent.agent : Agent, DiscoveredSession, SessionConfig, SessionMeta;
import cydo.agent.protocol : ContentBlock, extractContentText;
import cydo.agent.session : AgentSession;
import cydo.config : AgentConfig, CydoConfig, PathMode, SandboxConfig, WorkspaceConfig, loadConfig, reloadConfig;
import cydo.persist : ForkResult, Persistence, countLinesAfterForkId, createForkTask,
	editJsonlMessage, findNextUserUuid, forkTask, lastForkIdInJsonl, loadTaskHistory, truncateJsonl, writeJsonlPrefix;
import cydo.sandbox : ProcessLaunch, buildCommandPrefix, cleanup, cydoBinaryDir, cydoBinaryPath,
	prepareProcessLaunch, resolveExecutablePath,
	resolveSandbox, resolveSandboxForDiscovery, runtimeDir;
import cydo.tasktype : TaskTypeDef, UserEntryPointDef, TaskTypeConfig, ContinuationDef, OutputType, WorktreeMode, byName, isInteractive, loadTaskTypes, validateTaskTypes,
	renderPrompt, renderContinuationPrompt, substituteVars, formatCreatableTaskTypes, formatSwitchModes, formatHandoffs,
	loadSystemPrompt, computeReachesWorktree, computeTreeReadOnly;
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
		// killAfterTimeout (daemon timers) escalates to SIGKILL after ~2s, then
		// forceClosePipes() disconnects any lingering pipe FDs so the event loop
		// drains cleanly without needing alarm().
		import ae.net.shutdown : addShutdownHandler;
		addShutdownHandler((scope const(char)[]) {
			app.shutdown();
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
		Parameter!(string, "is_project expression (djinja).") isProjectExpr,
		Parameter!(string, "recurse_when expression (djinja).") recurseWhenExpr,
		Parameter!(immutable(string)[], "Patterns to exclude.") exclude = null,
	)
	{
		import cydo.discover : runDiscover;
		runDiscover(root, name, isProjectExpr, recurseWhenExpr, cast(string[]) exclude);
	}

	@(`Replay suggestion generation from a debug dump directory.`)
	void replaySuggestions(
		Parameter!(string, "Path to suggestion debug dump directory.") dumpDir,
	)
	{
		import std.file : exists, readText;
		import std.path : buildPath;
		import std.string : strip, splitLines;
		import ae.utils.json : jsonParse, JSONPartial;
		import cydo.agent.agent : Agent;
		import cydo.agent.registry : agentRegistry;
		import cydo.tasktype : substituteVars;

		// Verify required files exist
		auto metaPath = buildPath(dumpDir, "meta.json");
		auto contextPath = buildPath(dumpDir, "context.jsonl");
		if (!exists(metaPath))
		{
			stderr.writeln("Error: meta.json not found in ", dumpDir);
			import core.stdc.stdlib : exit;
			exit(1);
		}
		if (!exists(contextPath))
		{
			stderr.writeln("Error: context.jsonl not found in ", dumpDir);
			import core.stdc.stdlib : exit;
			exit(1);
		}

		// Parse meta.json
		@JSONPartial
		static struct ReplayMeta { string agentType; }
		auto meta = jsonParse!ReplayMeta(readText(metaPath));

		// Parse context.jsonl — one envelope per non-empty line
		string[] envelopes;
		foreach (line; readText(contextPath).splitLines())
		{
			auto s = line.strip();
			if (s.length > 0)
				envelopes ~= s;
		}

		// Build abbreviated history and prompt
		auto history = buildAbbreviatedHistoryFromStrings(envelopes);
		stderr.writeln("=== Abbreviated Context ===");
		stderr.writeln(history);
		stderr.writeln("===========================");

		auto promptPath = buildPath("defs", "prompts/generate-suggestions.md");
		if (!exists(promptPath))
		{
			stderr.writeln("Error: prompt file not found: ", promptPath);
			import core.stdc.stdlib : exit;
			exit(1);
		}
		auto prompt = substituteVars(readText(promptPath), ["conversation": history]);

		// Create agent from meta.json agentType, falling back to "claude"
		Agent agent;
		foreach (ref entry; agentRegistry)
			if (entry.name == meta.agentType) { agent = entry.create(); break; }
		if (agent is null)
			foreach (ref entry; agentRegistry)
				if (entry.name == "claude") { agent = entry.create(); break; }
		if (agent is null)
		{
			stderr.writeln("Error: could not find agent");
			import core.stdc.stdlib : exit;
			exit(1);
		}

		// Run the one-shot and print result to stdout
		bool failed;
		auto handle = agent.completeOneShot(prompt, "small");
		handle.promise.then((string result) {
			import std.stdio : writeln;
			writeln(result);
		}).except((Exception e) {
			stderr.writeln("Error: ", e.msg);
			failed = true;
		}).ignoreResult();

		socketManager.loop();

		if (failed)
		{
			import core.stdc.stdlib : exit;
			exit(1);
		}
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
	private UserEntryPointDef[] entryPointsCache;
	private bool[string] reachesWorktreeCache;
	private bool[string] treeReadOnlyCache;
	private enum taskTypesDir = "defs";
	private enum taskTypesPath = "defs/task-types.yaml";
	// Pending sub-task promises (childTid → promise fulfilled on task exit)
	private Promise!(McpResult)[int] pendingSubTasks;
	// In-memory mirror of task_deps table (childTid → parentTid)
	private int[int] taskDeps;
	// Pending AskUserQuestion promises (tid -> promise fulfilled when user responds)
	private Promise!(McpResult)[int] pendingAskUserQuestions;
	// Per-parent batch state, keyed by parent tid
	private BatchState[int] activeBatches;
	// App-global question ID counter and registry
	private int nextQid = 1;
	private Promise!McpResult[int] pendingQuestions;  // qid → promise waiting for answer
	private int[int] questionToTask;                   // qid → tid of the task that asked

	private struct BatchState
	{
		McpResult[] results;
		bool[] done;
		size_t completed;
		size_t totalChildren;
		int[] childTids;                   // ordered child tids
		PromiseQueue!BatchSignal eventQueue;
	}
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
	// Active notices keyed by notice ID
	private Notice[string] activeNotices;
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
		bool hasMessages = true; // false for ghost sessions (no user messages)
	}

	private TaskTypeDef[] getTaskTypes()
	{
		import std.path : buildPath, expandTilde;
		try
		{
			auto userTypesPath = buildPath(expandTilde("~/.config/cydo"), "task-types.yaml");
			auto config = loadTaskTypes(taskTypesPath, userTypesPath);
			auto errors = validateTaskTypes(config.types, config.entryPoints, taskTypesDir);
			foreach (e; errors)
				warningf("task type: %s", e);
			taskTypesCache = config.types;
			entryPointsCache = config.entryPoints;
			reachesWorktreeCache = computeReachesWorktree(config.types);
			treeReadOnlyCache = computeTreeReadOnly(config.types);
			return taskTypesCache;
		}
		catch (Exception e)
		{
			warningf("task types file changed but failed to parse, keeping previous version: %s", e.msg);
			return taskTypesCache;
		}
	}

	private UserEntryPointDef[] getEntryPoints()
	{
		return entryPointsCache;
	}

	void start()
	{
		initLogLevel();
		{
			import ae.sys.paths : getDataDir;
			import std.path : buildPath;
			auto xdgDataDir = getDataDir("cydo");
			auto xdgDbPath = buildPath(xdgDataDir, "cydo.db");
			string dataDir;
			if (exists("data/cydo.db"))
			{
				warningf("Warning: using legacy database at data/cydo.db — move it to %s to silence this warning", xdgDbPath);
				dataDir = "data";
			}
			else
				dataDir = xdgDataDir;
			persistence = Persistence(buildPath(dataDir, "cydo.db"));
			import cydo.sandbox : runtimeDir;
			createPidFile("cydo.pid", runtimeDir());
		}
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
			td.entryPoint = row.entryPoint;
			td.taskType = row.taskType;
			td.agentType = row.agentType;
			td.parentTid = row.parentTid;
			td.relationType = row.relationType;
			td.workspace = row.workspace;
			td.projectPath = row.projectPath;
			td.worktreeTid = row.worktreeTid;
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
			tasks[rowTid].archiveQueue = new StateQueue!ArchiveState(
				(ArchiveState goal) => archiveTransition(rowTid, goal),
				tasks[rowTid].archived ? ArchiveState.Archived : ArchiveState.Unarchived,
			);
		}

		// Post-migration cleanup: remove stale worktree symlinks from pre-v2 sessions
		foreach (tid, ref td; tasks)
		{
			if (td.taskDir.length == 0) continue;
			import std.file : isSymlink, remove;
			import std.path : buildPath;
			auto wtPath = buildPath(td.taskDir, "worktree");
			try {
				if (isSymlink(wtPath))
				{
					remove(wtPath);
					infof("Removed stale worktree symlink for task %d: %s", tid, wtPath);
				}
			} catch (Exception) {}
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

		if (authUser.length == 0 && authPass.length == 0)
			setNotice("auth_disabled", Nullable!Notice(Notice(NoticeLevel.warning,
				"Authentication is disabled.",
				"Anyone with network access can view and control all sessions.",
				"Set CYDO_AUTH_PASS to enable authentication.")));

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
			{
				td.session.stop();
				import core.time : seconds;
				td.session.killAfterTimeout(0.seconds);
			}
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
		jsonlTracker.stopAllWatches();
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
		// server.close() only disconnects idle connections; force-close any
		// remaining active ones (e.g. in-flight HTTP requests) so the event
		// loop can drain.
		{
			import std.array : array;
			import ae.net.asockets : disconnectable;
			foreach (c; server.connections.iterator.array)
				if (c.conn.state.disconnectable)
					c.conn.disconnect("shutting down");
		}
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

	private static immutable pwaPublicFiles = [
		"manifest.json",
		"icon-192.png",
		"icon-512.png",
		"apple-touch-icon.png",
		"favicon.svg",
	];

	private void handleRequest(HttpRequest request, HttpServerConnection conn)
	{
		// Serve PWA manifest and icons without auth — browsers fetch these
		// without credentials and need them for Add to Home Screen.
		auto resource = request.resource.length > 1 ? request.resource[1 .. $] : "";
		foreach (pub; pwaPublicFiles)
		{
			if (resource == pub)
			{
				auto response = new HttpResponseEx();
				response.serveFile(pub, "web/dist/");
				if (pub == "manifest.json")
					response.headers["Content-Type"] = "application/manifest+json";
				conn.sendResponse(response);
				return;
			}
		}

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
		ws.send(Data(buildNoticesList().representation));

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
		import std.file : remove;
		import std.path : buildPath;
		import std.socket : AddressFamily, AddressInfo, ProtocolType, SocketType, UnixAddress;

		{
			import cydo.sandbox : runtimeDir;
			mcpSocketPath = buildPath(runtimeDir(), "mcp.sock");
		}

		// Remove stale socket file from previous run
		if (exists(mcpSocketPath))
			remove(mcpSocketPath);

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
				setupWorktreeForEdge(childTid, parentTid, edge.worktree);
			}
		}

		// Configure and spawn child agent
		auto renderedPrompt = renderPrompt(*childTypeDef, prompt, taskTypesDir, childTd.outputPath, edgeTemplate);
		auto subtaskMeta = buildCydoMeta(resolvedTaskType, ["task_description": prompt], "task_description", true);
		tasks[childTid].processQueue.setGoal(ProcessState.Alive).then(() {
			broadcastUnconfirmedUserMessage(childTid, [ContentBlock("text", renderedPrompt)], subtaskMeta);
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

	bool wouldBeWriter(string callerTid, string taskType)
	{
		import std.conv : to;
		int parentTid;
		try
			parentTid = to!int(callerTid);
		catch (Exception)
			return false;

		auto parentTd = parentTid in tasks;
		if (parentTd is null)
			return false;

		auto parentTypeDef = getTaskTypes().byName(parentTd.taskType);
		WorktreeMode edgeMode = WorktreeMode.fork;
		string resolvedType = taskType;
		if (parentTypeDef !is null)
			if (auto edge = parentTypeDef.creatable_tasks.byName(taskType))
			{
				edgeMode = edge.worktree;
				resolvedType = edge.resolvedType;
			}

		if (edgeMode == WorktreeMode.fork)
			return false;

		auto childRO = resolvedType in treeReadOnlyCache;
		return childRO is null || !(*childRO);
	}

	/// Set up batch event stream and enter the wait loop.
	/// Called from createTasks — parent fiber blocks here.
	Promise!McpResult registerBatchAndAwait(string callerTidStr,
		Promise!McpResult[] childPromises)
	{
		import std.conv : to;
		int parentTid = to!int(callerTidStr);

		// Map each promise to its child tid by reverse-lookup in pendingSubTasks.
		// (taskDeps iteration order is non-deterministic, but pendingSubTasks allows
		//  matching each promise to the exact child that produced it.)
		int[] childTids = new int[childPromises.length];
		foreach (i, p; childPromises)
		{
			childTids[i] = -1;
			foreach (childTid, subProm; pendingSubTasks)
				if (subProm is p) { childTids[i] = childTid; break; }
		}

		BatchState batch;
		batch.totalChildren = childPromises.length;
		batch.results = new McpResult[childPromises.length];
		batch.done = new bool[childPromises.length];
		batch.childTids = childTids;

		// Set up .then() handlers ONCE — they feed into the event queue.
		foreach (i, p; childPromises)
		{
			int cTid = childTids[i];
			p.then((McpResult r) {
				if (parentTid in activeBatches)
					activeBatches[parentTid].eventQueue.fulfillOne(
						BatchSignal.childDone(cTid, r));
			});
		}

		activeBatches[parentTid] = batch;
		return awaitBatchLoop(parentTid);
	}

	/// Enter (or re-enter) the batch wait loop for a parent.
	/// Blocks until all children complete or a child asks a question.
	private Promise!McpResult awaitBatchLoop(int parentTid)
	{
		import ae.utils.json : JSONFragment, toJson;
		import ae.utils.promise.await : await;

		if ((parentTid in activeBatches) is null)
			return resolve(McpResult("No active batch", true));

		while (activeBatches[parentTid].completed < activeBatches[parentTid].totalChildren)
		{
			// Re-fetch pointer after each await() — AA may rehash during suspension.
			auto sig = activeBatches[parentTid].eventQueue.waitOne().await();

			if (sig.kind == BatchSignal.Kind.childDone)
			{
				foreach (i, cTid; activeBatches[parentTid].childTids)
				{
					if (cTid == sig.childTid)
					{
						activeBatches[parentTid].results[i] = sig.result;
						activeBatches[parentTid].done[i] = true;
						break;
					}
				}
				activeBatches[parentTid].completed++;
			}
			else // question
			{
				// Return question to parent agent — parent answers via Answer,
				// which re-enters this loop.
				return resolve(buildQuestionResult(sig.childTid));
			}
		}

		// All children done — assemble results and clean up
		auto results = activeBatches[parentTid].results.dup;
		activeBatches.remove(parentTid);

		bool anyError;
		JSONFragment[] items;
		foreach (ref result; results)
		{
			if (result.structuredContent)
				items ~= result.structuredContent;
			else
				items ~= JSONFragment(toJson(result.text));
			if (result.isError)
				anyError = true;
		}
		auto arrayJson = toJson(items);
		auto wrappedJson = `{"tasks":` ~ arrayJson ~ `}`;
		return resolve(McpResult(arrayJson, anyError, JSONFragment(wrappedJson)));
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

		// Gate: only types in the interactive cluster (reachable from entry points
		// via keep_context continuations).
		auto taskTypes = getTaskTypes();
		auto typeDef = taskTypes.byName(tdp.taskType);
		if (typeDef is null || !taskTypes.isInteractive(getEntryPoints(), tdp.taskType))
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

	Promise!McpResult handleAsk(string callerTidStr, string message, int targetTid)
	{
		import std.conv : to;
		int callerTidInt;
		try callerTidInt = to!int(callerTidStr);
		catch (Exception) return resolve(McpResult("Invalid calling task ID", true));

		auto callerTd = callerTidInt in tasks;
		if (callerTd is null) return resolve(McpResult("Task not found", true));

		// Resolve tid: -1 means "ask parent"
		if (targetTid == -1)
		{
			if (callerTd.parentTid <= 0)
				return resolve(McpResult("No parent task — tid is required", true));
			targetTid = callerTd.parentTid;
		}

		auto targetTd = targetTid in tasks;
		if (targetTd is null)
			return resolve(McpResult("Target task not found: " ~ to!string(targetTid), true));

		// Direction 1: caller is parent of target (ask completed child for follow-up)
		if (targetTd.parentTid == callerTidInt)
			return handleAskChild(callerTidInt, targetTid, message);

		// Direction 2: target is caller's parent (ask parent)
		if (callerTd.parentTid == targetTid)
			return handleAskParent(callerTidInt, targetTid, message);

		return resolve(McpResult(
			"Ask target must be a sub-task or parent task (tid="
			~ to!string(targetTid) ~ " is neither)", true));
	}

	private Promise!McpResult handleAskChild(int parentTid, int childTid, string message)
	{
		import std.conv : to;
		auto childTd = &tasks[childTid];

		// Child has a pending question — tell parent to use Answer instead
		if (childTd.pendingAskPromise !is null)
		{
			return resolve(McpResult(
				"Sub-task has a pending question (qid=" ~ to!string(childTd.pendingAskQid)
				~ "). Use Answer(qid, message) instead.", true));
		}

		// Child completed/failed → resume for follow-up
		if (childTd.status == "completed" || childTd.status == "failed")
		{
			int qid = nextQid++;
			auto promise = new Promise!McpResult;
			pendingQuestions[qid] = promise;
			questionToTask[qid] = parentTid;

			auto subTaskPromise = new Promise!McpResult;
			pendingSubTasks[childTid] = subTaskPromise;
			taskDeps[childTid] = parentTid;
			persistence.addTaskDep(parentTid, childTid);

			tasks[parentTid].status = "waiting";
			persistence.setStatus(parentTid, "waiting");
			broadcastTaskUpdate(parentTid);

			childTd.status = "active";
			persistence.setStatus(childTid, "active");
			broadcastTaskUpdate(childTid);

			// Register a single-child batch so we can reuse awaitBatchLoop
			BatchState batch;
			batch.totalChildren = 1;
			batch.results = new McpResult[1];
			batch.done = new bool[1];
			batch.childTids = [childTid];
			activeBatches[parentTid] = batch;

			// Hook the promise into the event queue
			subTaskPromise.then((McpResult r) {
				if (parentTid in activeBatches)
					activeBatches[parentTid].eventQueue.fulfillOne(
						BatchSignal.childDone(childTid, r));
			});

			// Resume child process and send follow-up message with qid
			childTd.processQueue.setGoal(ProcessState.Alive).then(() {
				auto msg = "[Follow-up question from parent task (qid=" ~ to!string(qid) ~ ")]\n\n"
					~ message
					~ "\n\nAnswer with Answer(" ~ to!string(qid) ~ ", \"your response\").";
				sendTaskMessage(childTid, [ContentBlock("text", msg)]);
			}).ignoreResult();

			// When child calls Answer(qid, ...), the promise is fulfilled directly.
			// We still need to await the batch in case child exits without answering.
			// The Answer handler will fulfill pendingQuestions[qid] which resolves promise.
			// We return the promise that's fulfilled when child answers.
			// But we must also enter awaitBatchLoop so the parent waits properly.
			// Wire: when promise is fulfilled (child answers), deliver to parent via awaitBatchLoop.
			promise.then((McpResult r) {
				// Child answered the follow-up — deliver as batch result
				if (parentTid in activeBatches)
					activeBatches[parentTid].eventQueue.fulfillOne(
						BatchSignal.childDone(childTid, r));
				pendingQuestions.remove(qid);
				questionToTask.remove(qid);
			});

			return awaitBatchLoop(parentTid);
		}

		// Child is active/busy
		return resolve(McpResult(
			"Cannot Ask active sub-task (tid=" ~ to!string(childTid)
			~ ", status=" ~ childTd.status ~ "). "
			~ "Ask to children is only supported for completed/failed tasks.", true));
	}

	private Promise!McpResult handleAskParent(int childTid, int parentTid, string message)
	{
		import std.conv : to;
		auto childTd = &tasks[childTid];

		// Allocate a qid for this question
		int qid = nextQid++;
		auto promise = new Promise!McpResult;
		childTd.pendingAskPromise = promise;
		childTd.pendingAskQuestion = message;
		childTd.pendingAskQid = qid;
		pendingQuestions[qid] = promise;
		questionToTask[qid] = childTid;

		// Inject question into parent's batch event queue
		if (auto batch = parentTid in activeBatches)
			batch.eventQueue.fulfillOne(BatchSignal.question(childTid, message, qid));

		// Update child status
		childTd.status = "waiting";
		childTd.notificationBody = "Asking parent: " ~ truncateTitle(message, 100);
		persistence.setStatus(childTid, "waiting");
		broadcastTaskUpdate(childTid);

		return promise;
	}

	Promise!McpResult handleAnswer(string callerTidStr, int qid, string message)
	{
		import std.conv : to;
		int callerTidInt;
		try callerTidInt = to!int(callerTidStr);
		catch (Exception) return resolve(McpResult("Invalid calling task ID", true));

		if (callerTidInt !in tasks)
			return resolve(McpResult("Task not found", true));

		auto questionPromise = qid in pendingQuestions;
		if (questionPromise is null)
			return resolve(McpResult("Unknown question ID: " ~ to!string(qid), true));

		auto askingTaskTid = qid in questionToTask;
		if (askingTaskTid is null)
			return resolve(McpResult("Unknown question ID: " ~ to!string(qid), true));

		int askTid = *askingTaskTid;
		auto askTd = askTid in tasks;

		// Determine direction:
		// - Parent answering child's question: askTid is a child of callerTidInt
		// - Child answering parent's follow-up: askTid is the parent of callerTidInt
		bool parentAnsweringChild = askTd !is null && askTd.parentTid == callerTidInt;
		bool childAnsweringParent = askTd !is null && tasks[callerTidInt].parentTid == askTid;

		if (parentAnsweringChild)
		{
			// Fulfill child's blocking Ask call with the answer
			(*questionPromise).fulfill(McpResult(message, false));

			// Clean up child state
			if (askTd.pendingAskPromise !is null)
			{
				askTd.pendingAskPromise = null;
				askTd.pendingAskQuestion = null;
				askTd.pendingAskQid = 0;
			}
			pendingQuestions.remove(qid);
			questionToTask.remove(qid);

			// Update child status
			askTd.status = "active";
			askTd.notificationBody = "";
			persistence.setStatus(askTid, "active");
			broadcastTaskUpdate(askTid);

			// Re-enter the batch wait loop — blocks until next event
			return awaitBatchLoop(callerTidInt);
		}
		else if (childAnsweringParent)
		{
			// Child answering parent's follow-up question
			// Fulfill the promise — handleAskChild's .then() handler delivers to batch
			(*questionPromise).fulfill(McpResult(message, false));
			// Note: pendingQuestions/questionToTask cleanup done in handleAskChild's .then()

			// Return simple success to the child
			return resolve(McpResult("Answer delivered.", false));
		}
		else
		{
			return resolve(McpResult(
				"Unknown question ID: " ~ to!string(qid), true));
		}
	}

	private McpResult buildQuestionResult(int childTid)
	{
		import ae.utils.json : toJson;
		import std.conv : to;
		auto childTd = &tasks[childTid];
		auto questionJson = `{"status":"question","tid":` ~ to!string(childTid)
			~ `,"qid":` ~ to!string(childTd.pendingAskQid)
			~ `,"title":` ~ toJson(childTd.title)
			~ `,"question":` ~ toJson(childTd.pendingAskQuestion) ~ `}`;
		return McpResult(
			"Sub-task \"" ~ childTd.title ~ "\" is asking (qid=" ~ to!string(childTd.pendingAskQid) ~ "): " ~ childTd.pendingAskQuestion,
			false,
			JSONFragment(questionJson)
		);
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

		// Don't clean up deps if there's an active batch (Answer will re-enter)
		if (tid in activeBatches)
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
			case "set_entry_point":  handleSetEntryPointMsg(json); break;
			case "set_agent_type":   handleSetAgentTypeMsg(json); break;
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
		tasks[tid].entryPoint = "";
		persistence.setEntryPoint(tid, "");
		tasks[tid].taskType = json.task_type;
		persistence.setTaskType(tid, json.task_type);
		broadcastTaskUpdate(tid);
	}

	private void handleSetEntryPointMsg(WsMessage json)
	{
		auto tid = json.tid;
		if (tid < 0 || tid !in tasks) return;
		if (tasks[tid].alive) return; // can't change type of a running task
		if (json.entry_point.length == 0) return;
		auto ep = getEntryPoints().byName(json.entry_point);
		if (ep is null) return;
		auto td = &tasks[tid];
		td.entryPoint = json.entry_point;
		persistence.setEntryPoint(tid, td.entryPoint);
		td.taskType = ep.resolvedType;
		persistence.setTaskType(tid, td.taskType);
		broadcastTaskUpdate(tid);
	}

	private void handleSetAgentTypeMsg(WsMessage json)
	{
		import cydo.agent.registry : agentRegistry;
		auto tid = json.tid;
		if (tid < 0 || tid !in tasks) return;
		if (tasks[tid].alive) return; // can't change type of a running task
		if (json.agent_type.length == 0) return;
		bool found = false;
		foreach (ref entry; agentRegistry)
			if (entry.name == json.agent_type) { found = true; break; }
		if (!found) return;
		tasks[tid].agentType = json.agent_type;
		persistence.setAgentType(tid, json.agent_type);
		broadcastTaskUpdate(tid);
	}

	private void handleCreateTaskMsg(WebSocketAdapter ws, WsMessage json)
	{
		auto at = json.agent_type.length > 0 ? json.agent_type : defaultAgentType(json.workspace);
		// Top-level user task creation must always come through a concrete entry point.
		// Internal tasks (subtasks, continuations, imports) are created through other paths.
		auto entryPoints = getEntryPoints();
		if (json.entry_point.length == 0)
		{
			ws.send(Data(toJson(ErrorMessage("error",
				"Top-level task creation requires an entry point")).representation));
			return;
		}
		auto ep = entryPoints.byName(json.entry_point);
		if (ep is null)
		{
			ws.send(Data(toJson(ErrorMessage("error",
				"Unknown entry point: " ~ json.entry_point)).representation));
			return;
		}
		auto epTemplate = ep.prompt_template;
		auto tid = createTask(json.workspace, json.project_path, at, json.entry_point);
		// Call getTaskTypes() after getEntryPoints() so the cache is populated.
		auto taskTypes = getTaskTypes();
		tasks[tid].entryPoint = json.entry_point;
		persistence.setEntryPoint(tid, json.entry_point);
		tasks[tid].taskType = ep.resolvedType;
		if (taskTypes.byName(ep.resolvedType) !is null)
			persistence.setTaskType(tid, ep.resolvedType);
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
			materializePendingTask(tid);
			auto typeDef = taskTypes.byName(td.taskType);
			auto textContent = extractContentText(blocks);
			auto messageToSend = blocks;
			if (typeDef !is null)
			{
				import std.algorithm : filter;
				import std.array : array;
				auto rendered = renderPrompt(*typeDef, textContent, taskTypesDir, td.outputPath, epTemplate);
				// Preserve image blocks alongside the rendered text prompt.
				messageToSend = ContentBlock("text", rendered)
					~ blocks.filter!(b => b.type == "image").array;
			}
			// Record text so ensureHistoryLoaded can produce correct synthetics
			// for queue-operation:remove lines (same as handleUserMessage does).
			td.pendingSteeringTexts ~= textContent;
			auto msgContent = blocks;
			auto msgMeta = typeDef !is null
				? buildCydoMeta(json.entry_point, ["task_description": textContent], "task_description", false)
				: null;
			tasks[tid].processQueue.setGoal(ProcessState.Alive).then(() {
				broadcastUnconfirmedUserMessage(tid, msgContent, msgMeta);
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
		if (isArchiveTransitioning(tid))
			return;
		assert(td.taskType.length > 0, "Task must have a task_type when receiving a message");

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
		string userMsgMeta;
		if (td.description.length == 0)
		{
			materializePendingTask(tid);
			auto typeDef = getTaskTypes().byName(td.taskType);
			if (typeDef !is null)
			{
				import std.algorithm : filter;
				import std.array : array;
				string entryPointTemplate;
				if (td.entryPoint.length > 0)
				{
					auto ep = getEntryPoints().byName(td.entryPoint);
					if (ep !is null)
						entryPointTemplate = ep.prompt_template;
				}
				auto rendered = renderPrompt(*typeDef, textContent, taskTypesDir,
					td.outputPath, entryPointTemplate);
				// Preserve image blocks alongside the rendered text prompt.
				messageToSend = ContentBlock("text", rendered)
					~ blocks.filter!(b => b.type == "image").array;
				// Attach metadata so the frontend can render this as a collapsible system message.
				auto label = "Session start: " ~ (td.entryPoint.length > 0 ? td.entryPoint : td.taskType);
				userMsgMeta = buildCydoMeta(label, ["task_description": textContent], "task_description", false);
			}
		}
		td.lastSuggestions = null;
		broadcastUnconfirmedUserMessage(tid, blocks, userMsgMeta);
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
		if (isArchiveTransitioning(tid))
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

	private bool isArchiveTransitioning(int tid)
	{
		auto tdp = tid in tasks;
		if (tdp is null) return false;
		return tdp.archiving;
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

		// Block if archive transition already in progress
		if (isArchiveTransitioning(tid))
		{
			ws.send(Data(toJson(ErrorMessage("error",
				"Archive operation already in progress", tid)).representation));
			return;
		}

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

		// Update DB and flags immediately so subsequent operations see the new state.
		td.archived = archived;
		td.archiving = true;  // set before broadcast so spinner appears immediately
		persistence.setArchived(tid, archived);

		// Broadcast with archiving=true so frontend shows spinner.
		broadcastTaskUpdate(tid);

		// Start async worktree operation.
		td.archiveQueue.setGoal(archived ? ArchiveState.Archived : ArchiveState.Unarchived)
			.then(() {
				// Transition complete — clear flag and broadcast final state.
				auto tdp = tid in tasks;
				if (tdp !is null)
				{
					tdp.archiving = false;
					broadcastTaskUpdate(tid);
				}
			})
			.except((Exception e) {
				errorf("Archive transition failed for tid=%d: %s", tid, e.msg);
				// Revert the archived flag and clear transitioning state on failure.
				auto tdp = tid in tasks;
				if (tdp !is null)
				{
					tdp.archived = !archived;
					tdp.archiving = false;
					persistence.setArchived(tid, !archived);
					broadcastTaskUpdate(tid);
				}
				ws.send(Data(toJson(ErrorMessage("error",
					format!"Archive operation failed: %s"(e.msg), tid)).representation));
			});
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
		import cydo.agent.codex : CodexAgent, ThreadForkOutcome;

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
		if (auto ca = cast(CodexAgent) ta)
		{
			auto sourcePath = ta.historyPath(td.agentSessionId, td.effectiveCwd);
			if (sourcePath.length == 0)
			{
				ws.send(Data(toJson(ErrorMessage("error",
					"Fork failed: task history file not found", tid)).representation));
				return;
			}

			auto childTid = createForkTask(persistence, tid, "", td.projectPath, td.workspace,
				td.title, td.description, td.taskType, td.agentType);

			auto newTd = TaskData(childTid);
			newTd.workspace = td.workspace;
			newTd.projectPath = td.projectPath;
			newTd.title = td.title.length > 0 ? td.title ~ " (fork)" : "(fork)";
			newTd.parentTid = tid;
			newTd.relationType = "fork";
			newTd.status = "completed";
			newTd.agentType = td.agentType;
			newTd.description = td.description;
			newTd.taskType = td.taskType;
			import std.datetime : Clock;
			newTd.createdAt = Clock.currStdTime;
			newTd.lastActive = newTd.createdAt;
			tasks[childTid] = move(newTd);

			auto childAgent = agentForTask(childTid);
			auto childTypeDef = getTaskTypes().byName(tasks[childTid].taskType);
			auto launch = prepareTaskSessionLaunch(childTid, childAgent, childTypeDef);

			import std.file : exists, remove;
			import std.path : baseName, buildPath, dirName;
			import std.uuid : randomUUID;
			auto forkSourcePath = buildPath(dirName(sourcePath),
				"fork-source-" ~ randomUUID().toString() ~ "-" ~ baseName(sourcePath));
			if (!writeJsonlPrefix(sourcePath, forkSourcePath, json.after_uuid, &ta.forkIdMatchesLine))
			{
				tasks.remove(childTid);
				persistence.deleteTask(childTid);
				ws.send(Data(toJson(ErrorMessage("error",
					"Fork failed: message UUID not found in task history", tid)).representation));
				return;
			}

			ca.forkSession(childTid, td.agentSessionId, launch.processLaunch, launch.sessionConfig,
				forkSourcePath)
				.then((ThreadForkOutcome outcome) {
					try
					{
						if (exists(forkSourcePath))
							remove(forkSourcePath);
					}
					catch (Exception)
					{
					}
					if (!outcome.ok)
					{
						tasks.remove(childTid);
						persistence.deleteTask(childTid);
						ws.send(Data(toJson(ErrorMessage("error",
							"Fork failed: " ~ outcome.error, tid)).representation));
						return;
					}

					tasks[childTid].agentSessionId = outcome.threadId;
					persistence.setAgentSessionId(childTid, outcome.threadId);
					tasks[childTid].processQueue = new StateQueue!ProcessState(
						(ProcessState goal) => processTransition(childTid, goal),
						ProcessState.Dead,
					);
					tasks[childTid].archiveQueue = new StateQueue!ArchiveState(
						(ArchiveState goal) => archiveTransition(childTid, goal),
						ArchiveState.Unarchived,
					);

					broadcast(toJson(TaskCreatedMessage("task_created", childTid, td.workspace,
						td.projectPath, tid, "fork")));
					broadcastTaskUpdate(childTid);
				});
			return;
		}

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
		tasks[result.tid].archiveQueue = new StateQueue!ArchiveState(
			(ArchiveState goal) => archiveTransition(result.tid, goal),
			ArchiveState.Unarchived,
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
			import std.algorithm : canFind, startsWith;
			string rewindOutput;
			if (json.revert_files && ta.supportsFileRevert())
			{
				// Synthetic enqueue-N UUIDs don't have file checkpoints, but the
				// next real type:"user" message in the JSONL does.  Find it.
				string rewindUuid = json.after_uuid;
				if (rewindUuid.startsWith("enqueue-"))
				{
					rewindUuid = findNextUserUuid(
						ta.historyPath(td.agentSessionId, td.effectiveCwd),
						json.after_uuid, &ta.forkIdMatchesLine);
				}

				if (rewindUuid.length > 0 && !rewindUuid.startsWith("enqueue-"))
				{
					auto rewindResult = ta.rewindFiles(td.agentSessionId, rewindUuid, td.effectiveCwd, td.launch);
					if (rewindResult.success)
						rewindOutput = rewindResult.output;
					else if (!rewindResult.output.canFind("No file checkpoint found"))
					{
						ws.send(Data(toJson(ErrorMessage("error", "File revert failed: " ~ rewindResult.output, tid)).representation));
						return;
					}
					// "No file checkpoint found" → no checkpoint for this message, skip silently
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
						tasks[backup.tid].archiveQueue = new StateQueue!ArchiveState(
							(ArchiveState goal) => archiveTransition(backup.tid, goal),
							ArchiveState.Unarchived,
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

			// Send undo result to the requesting client
			ws.send(Data(toJson(UndoResultMessage("undo_result", tid, rewindOutput)).representation));

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

	private int createTask(string workspace = "", string projectPath = "", string agentType = "claude",
		string entryPoint = "")
	{
		auto tid = persistence.createTask(workspace, projectPath, agentType, entryPoint);
		auto td = TaskData(tid);
		td.workspace = workspace;
		td.projectPath = projectPath;
		td.agentType = agentType;
		td.entryPoint = entryPoint;
		td.historyLoaded = true; // New tasks have no JSONL to load
		import std.datetime : Clock;
		td.createdAt = Clock.currStdTime;
		td.lastActive = td.createdAt;
		tasks[tid] = move(td);
		tasks[tid].processQueue = new StateQueue!ProcessState(
			(ProcessState goal) => processTransition(tid, goal),
			ProcessState.Dead,
		);
		tasks[tid].archiveQueue = new StateQueue!ArchiveState(
			(ArchiveState goal) => archiveTransition(tid, goal),
			ArchiveState.Unarchived,
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

	/// Set up a worktree for a task based on the edge's WorktreeMode.
	private void setupWorktreeForEdge(int childTid, int parentTid, WorktreeMode mode)
	{
		final switch (mode)
		{
			case WorktreeMode.inherit:
				setupWorktreeInherit(childTid, parentTid);
				break;
			case WorktreeMode.require:
				setupWorktreeRequire(childTid, parentTid);
				break;
			case WorktreeMode.fork:
				setupWorktreeFork(childTid, parentTid);
				break;
		}
	}

	/// Finalize pending task runtime state right before the first message starts it.
	/// This keeps draft tasks cheap and defers worktree creation until the task
	/// is actually materialized by the first send.
	private void materializePendingTask(int tid)
	{
		auto td = &tasks[tid];
		if (td.alive || td.status != "pending" || td.description.length > 0)
			return;

		if (td.entryPoint.length == 0)
			return;

		auto ep = getEntryPoints().byName(td.entryPoint);
		if (ep is null)
			return;
		if (td.worktreeTid > 0 || ep.worktree == WorktreeMode.inherit)
			return;
		setupWorktreeForEdge(tid, td.parentTid, ep.worktree);
	}

	/// Inherit: if the parent has a worktree, the child shares it.
	private void setupWorktreeInherit(int childTid, int parentTid)
	{
		auto parentTd = parentTid in tasks;
		if (parentTd is null || parentTd.worktreeTid <= 0)
			return;
		auto td = &tasks[childTid];
		td.worktreeTid = parentTd.worktreeTid;
		persistence.setWorktreeTid(childTid, td.worktreeTid);
	}

	/// Require: walk up ancestors to find an existing worktree. If none found,
	/// create one at the root task's directory. The child then shares that worktree.
	/// The root task's own worktree_tid stays 0 (root tasks never chdir).
	private void setupWorktreeRequire(int childTid, int parentTid)
	{
		// Walk up to find nearest ancestor with a worktree
		int current = parentTid;
		while (current > 0)
		{
			auto ancestorTd = current in tasks;
			if (ancestorTd is null)
				break;
			if (ancestorTd.worktreeTid > 0)
			{
				// Found an ancestor with a worktree — share it
				auto td = &tasks[childTid];
				td.worktreeTid = ancestorTd.worktreeTid;
				persistence.setWorktreeTid(childTid, td.worktreeTid);
				return;
			}
			current = ancestorTd.parentTid;
		}
		// No ancestor has a worktree — create one at the root task's directory
		int rootTid = findRootTid(childTid);
		auto rootTd = rootTid in tasks;
		if (rootTd is null || rootTd.taskDir.length == 0)
			return;

		import std.file : exists, mkdirRecurse;
		import std.path : buildPath;
		auto wtPath = buildPath(rootTd.taskDir, "worktree");
		if (!exists(wtPath))
		{
			mkdirRecurse(rootTd.taskDir);
			import std.process : execute;
			auto workDir = rootTd.projectPath.length > 0 ? rootTd.projectPath : null;
			auto gitResult = execute(["git", "-C", workDir, "worktree", "add", "--detach", wtPath]);
			if (gitResult.status != 0)
			{
				errorf("Failed to create worktree for require at root task %d: %s", rootTid, gitResult.output);
				return;
			}
			infof("Created shared worktree at root task %d: %s", rootTid, wtPath);
		}
		// Child points to the root's worktree. Root's worktree_tid stays 0.
		auto td = &tasks[childTid];
		td.worktreeTid = rootTid;
		persistence.setWorktreeTid(childTid, rootTid);
	}

	/// Fork: create a new isolated worktree for this task.
	private void setupWorktreeFork(int childTid, int parentTid)
	{
		auto td = &tasks[childTid];
		if (td.worktreeTid > 0 || td.taskDir.length == 0)
			return;

		import std.file : mkdirRecurse;
		import std.path : buildPath;
		import std.process : execute;

		mkdirRecurse(td.taskDir);
		auto wtPath = buildPath(td.taskDir, "worktree");

		// Determine base: parent's worktree if available, else project dir
		auto parentTd = parentTid in tasks;
		string baseFrom;
		if (parentTd !is null && parentTd.worktreeTid > 0)
			baseFrom = parentTd.worktreePath;
		auto workDir = baseFrom.length > 0 ? baseFrom : (td.projectPath.length > 0 ? td.projectPath : null);

		auto gitResult = execute(["git", "-C", workDir, "worktree", "add", "--detach", wtPath]);
		if (gitResult.status == 0)
		{
			td.worktreeTid = childTid;  // owns its own worktree
			persistence.setWorktreeTid(childTid, childTid);
			infof("Created fork worktree for task %d: %s", childTid, wtPath);
		}
		else
			errorf("Failed to create fork worktree for task %d: %s", childTid, gitResult.output);
	}

	private struct TaskSessionLaunch
	{
		ProcessLaunch processLaunch;
		SessionConfig sessionConfig;
	}

	private TaskSessionLaunch prepareTaskSessionLaunch(int tid, Agent taskAgent,
		TaskTypeDef* typeDef)
	{
		auto td = &tasks[tid];

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

		auto workDir = td.repoPath.length > 0 ? td.repoPath : null;

		// Ensure per-task directory exists
		import std.path : buildPath;
		if (td.taskDir.length > 0)
		{
			import std.file : mkdirRecurse;
			mkdirRecurse(td.taskDir);
		}

		// When a project is a subdirectory inside a git repo, keep that relative
		// path inside the worktree instead of dropping tasks at the repo root.
		auto chdir = td.effectiveCwd.length > 0 ? td.effectiveCwd : workDir;

		// Resolve sandbox config: agent defaults + global + per-agent + per-workspace
		auto wsSandbox = findWorkspaceSandbox(td.workspace);
		auto wsRoot = findWorkspaceRoot(td.workspace);
		auto agentTypeSandbox = findAgentTypeSandbox(td.agentType);
		bool readOnly = typeDef !is null && typeDef.read_only;
		auto sandbox = resolveSandbox(config.sandbox, agentTypeSandbox, wsSandbox,
			taskAgent, workDir, wsRoot, readOnly);

		// Task directory is always writable (even for read-only tasks)
		if (td.taskDir.length > 0)
			sandbox.paths[td.taskDir] = PathMode.rw;

		// Worktree sandbox restriction: when a task has a worktree and is not
		// read-only, downgrade the project directory to ro and add git dirs as rw.
		if (td.worktreeTid > 0 && !readOnly && workDir.length > 0)
		{
			import std.process : execute;
			import std.string : strip;
			import std.path : absolutePath;

			// Downgrade project directory to read-only
			sandbox.paths[workDir] = PathMode.ro;

			// The worktree itself must be writable
			auto wtPath = td.worktreePath;
			if (wtPath.length > 0)
				sandbox.paths[wtPath] = PathMode.rw;

			// Add git dir and git common dir as writable for git operations
			if (wtPath.length > 0)
			{
				auto gitDirResult = execute(["git", "-C", wtPath, "rev-parse", "--git-dir"]);
				if (gitDirResult.status == 0)
				{
					auto gitDir = gitDirResult.output.strip.absolutePath(wtPath);
					sandbox.paths[gitDir] = PathMode.rw;
				}
				auto gitCommonResult = execute(["git", "-C", wtPath, "rev-parse", "--git-common-dir"]);
				if (gitCommonResult.status == 0)
				{
					auto gitCommonDir = gitCommonResult.output.strip.absolutePath(wtPath);
					sandbox.paths[gitCommonDir] = PathMode.rw;
				}
			}
		}

		// Git dirs writable for types that can reach a worktree: they may need
		// to cherry-pick or merge results from child worktrees. Use always_rw
		// so this survives the read_only downgrade.
		if (workDir.length > 0 && td.taskType in reachesWorktreeCache
			&& reachesWorktreeCache[td.taskType])
		{
			import std.process : execute;
			import std.string : strip;
			import std.path : absolutePath;

			auto gitDirResult = execute(["git", "-C", workDir, "rev-parse", "--git-dir"]);
			if (gitDirResult.status == 0)
			{
				auto gitDir = gitDirResult.output.strip.absolutePath(workDir);
				sandbox.paths[gitDir] = PathMode.always_rw;
			}
			auto gitCommonResult = execute(["git", "-C", workDir, "rev-parse", "--git-common-dir"]);
			if (gitCommonResult.status == 0)
			{
				auto gitCommonDir = gitCommonResult.output.strip.absolutePath(workDir);
				sandbox.paths[gitCommonDir] = PathMode.always_rw;
			}
		}

		// MCP socket must be accessible inside the sandbox
		if (mcpSocketPath.length > 0)
			sandbox.paths[mcpSocketPath] = PathMode.ro;

		// Set up shared /tmp: all tasks in a tree share the same host-backed directory
		sandbox.sharedTmpPath = resolveSharedTmpPath(tid);
		td.launch = prepareProcessLaunch(sandbox, chdir,
			taskAgent.executableName(sandbox.env));

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
		if (getTaskTypes().isInteractive(getEntryPoints(), td.taskType))
			sessionConfig.includeTools ~= "AskUserQuestion";
		if (sessionConfig.creatableTaskTypes.length > 0 || td.parentTid > 0)
		{
			sessionConfig.includeTools ~= "Ask";
			sessionConfig.includeTools ~= "Answer";
		}
		if (typeDef !is null && typeDef.allow_native_subagents)
			sessionConfig.allowNativeSubagents = true;

		return TaskSessionLaunch(td.launch, sessionConfig);
	}

	private void spawnTaskSession(int tid)
	{
		auto td = &tasks[tid];
		assert(td.taskType.length > 0, "Task must have a task_type before spawning session");
		td.wasKilledByUser = false;

		// Look up the correct agent for this task's agent type
		auto taskAgent = agentForTask(tid);

		auto typeDef = getTaskTypes().byName(td.taskType);
		auto launch = prepareTaskSessionLaunch(tid, taskAgent, typeDef);
		td.session = taskAgent.createSession(tid, td.agentSessionId,
			launch.processLaunch, launch.sessionConfig);
		persistence.clearLastActive(tid);

		// Track MCP config temp file for cleanup
		if (taskAgent.lastMcpConfigPath.length > 0)
			td.launch.sandbox.tempFiles ~= taskAgent.lastMcpConfigPath;

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
					// For non-continuation subtasks, deliver the result immediately
					// so the parent doesn't wait for process exit.
					if (auto pending = tid in pendingSubTasks)
					{
						if (td.pendingContinuation.length == 0 && !hasOnYield)
						{
							td.status = "completed";
							persistence.setStatus(tid, "completed");
							persistence.setResultText(tid, td.resultText);
							auto taskResult = buildTaskResult(tid);
							auto resultJson = toJson(taskResult);
							pending.fulfill(McpResult(resultJson, false, JSONFragment(resultJson)));
							pendingSubTasks.remove(tid);
							// taskDeps is left intact — onToolCallDelivered() handles
							// the cleanup and the parent "waiting"→"active" transition.
						}
					}

					// Check for unanswered child questions before closing stdin
					auto batch = tid in activeBatches;
					bool hasUnansweredQuestions = false;
					if (batch !is null)
					{
						foreach (cTid; batch.childTids)
						{
							if (cTid in tasks && tasks[cTid].pendingAskPromise !is null)
							{
								hasUnansweredQuestions = true;
								break;
							}
						}
					}

					if (hasUnansweredQuestions)
					{
						import std.conv : to;
						string reminder;
						foreach (cTid; batch.childTids)
						{
							if (cTid in tasks && tasks[cTid].pendingAskPromise !is null)
							{
								auto childTd = &tasks[cTid];
								reminder = "[SYSTEM: Sub-task \"" ~ childTd.title ~ "\" (tid="
									~ to!string(cTid) ~ ") is waiting for your answer (qid="
									~ to!string(childTd.pendingAskQid) ~ ").]\n\n"
									~ "Question: " ~ childTd.pendingAskQuestion ~ "\n\n"
									~ "Use Answer(" ~ to!string(childTd.pendingAskQid)
									~ ", \"your answer\") to respond. You must answer before you can complete your turn.";
								break;
							}
						}
						auto reminderBlocks = [ContentBlock("text", reminder)];
						broadcastUnconfirmedUserMessage(tid, reminderBlocks);
						sendTaskMessage(tid, reminderBlocks);
					}
					else
					{
						td.processQueue.setGoal(ProcessState.Dead).ignoreResult();
						td.session.closeStdin();
						if (td.pendingContinuation.length == 0 && !hasOnYield)
							td.session.killAfterTimeout(5.seconds);
					}
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
			// Suppress auto-navigation when yield enforcement is active:
			// if a child has an unanswered Ask question, the process was
			// restarted by yield enforcement and will restart again.
			if (!ev.is_continuation)
			{
				if (auto batch = tid in activeBatches)
					foreach (cTid; batch.childTids)
						if (cTid in tasks && tasks[cTid].pendingAskPromise !is null)
						{
							ev.is_continuation = true;
							break;
						}
			}
			broadcastTask(tid, toJson(ev));
			if (tid !in tasks)
				return;
			tasks[tid].isProcessing = false;
			if (exitCode != 0)
				tasks[tid].error = lastStderr;
			cleanup(tasks[tid].launch.sandbox);
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

			// Fulfill pending Ask promise with error if child exits while waiting
			if (tasks[tid].pendingAskPromise !is null)
			{
				int qid = tasks[tid].pendingAskQid;
				tasks[tid].pendingAskPromise.fulfill(
					McpResult("Session ended while waiting for Ask response", true));
				tasks[tid].pendingAskPromise = null;
				tasks[tid].pendingAskQuestion = null;
				tasks[tid].pendingAskQid = 0;
				pendingQuestions.remove(qid);
				questionToTask.remove(qid);
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

			if (tasks[tid].status != "completed")
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
			auto contMeta = buildCydoMeta("Mode switch: " ~ contDef.task_type);
			td.processQueue.setGoal(ProcessState.Alive).then(() {
				broadcastUnconfirmedUserMessage(tid, [ContentBlock("text", renderedContinuationPrompt)], contMeta);
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

			// Set up worktree from edge config
			setupWorktreeForEdge(childTid, tid, contDef.worktree);

			// Spawn the successor agent
			auto renderedSuccessorPrompt = renderPrompt(*newTypeDef, successorPrompt,
				taskTypesDir, childTd.outputPath, contDef.prompt_template,
				["result_text": resultText]);
			auto handoffMeta = buildCydoMeta("Handoff: " ~ contDef.task_type,
				["task_description": successorPrompt], "task_description", false);
			tasks[childTid].processQueue.setGoal(ProcessState.Alive).then(() {
				broadcastUnconfirmedUserMessage(childTid, [ContentBlock("text", renderedSuccessorPrompt)], handoffMeta);
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

	private string defaultTaskType(string workspaceName)
	{
		foreach (ref ws; config.workspaces)
			if (ws.name == workspaceName && ws.default_task_type.length > 0)
				return ws.default_task_type;
		return config.default_task_type;
	}

	private SandboxConfig findWorkspaceSandbox(string workspaceName)
	{
		foreach (ref ws; config.workspaces)
			if (ws.name == workspaceName)
				return ws.sandbox;
		return SandboxConfig.init;
	}

	private string findWorkspaceRoot(string workspaceName)
	{
		foreach (ref ws; config.workspaces)
			if (ws.name == workspaceName)
				return ws.root;
		return "";
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
		import std.conv : to;
		import std.file : exists;
		auto td = &tasks[tid];
		bool hasOutput = td.outputPath.length > 0 && exists(td.outputPath);
		bool hasWorktree = td.hasWorktree;
		bool isFailed = td.status == "failed";
		auto talkNote = " Use Ask(question, " ~ to!string(tid) ~ ") to ask follow-up questions.";
		string note;
		if (hasOutput && hasWorktree)
			note = "Read the output file for full findings. The worktree path is included for adopting changes." ~ talkNote;
		else if (hasOutput)
			note = "Read the output file for full findings." ~ talkNote;
		else if (hasWorktree)
			note = "The worktree contains the implementation." ~ talkNote;
		auto result = TaskResult(
			td.resultText,
			hasOutput ? td.outputPath : null,
			hasWorktree ? td.worktreePath : null,
			note.length > 0 ? note : td.resultNote,
			isFailed ? td.resultText : null,
		);
		result.tid = tid;
		return result;
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
			enum nudgeText = "[SYSTEM: Your session was interrupted by a backend restart. "
				~ "Continue from where you left off. If you had a tool call in progress "
				~ "(Task, Handoff, SwitchMode, or any other tool), retry it.]";
			auto nudgeMeta = buildCydoMeta("restart nudge");
			broadcastUnconfirmedUserMessage(tid, [ContentBlock("text", nudgeText)], nudgeMeta);
			sendTaskMessage(tid, [ContentBlock("text", nudgeText)]);
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

	/// Holds the pre-computed data for a single worktree archive/unarchive git operation.
	/// Collected on the main thread and executed in a background thread.
	private struct WorktreeOp
	{
		int tid;
		string worktreePath;
		string projectPath;
	}

	/// Collect archive ops for `tid` and descendants (main thread only).
	/// Skips tasks already effectively archived by an ancestor.
	private WorktreeOp[] collectArchiveOps(int tid)
	{
		WorktreeOp[] ops;
		if (!isEffectivelyArchivedByAncestor(tid))
			collectArchiveOpsDFS(tid, false, ops);
		return ops;
	}

	private void collectArchiveOpsDFS(int tid, bool parentEffectivelyArchived, ref WorktreeOp[] ops)
	{
		import std.file : exists, isDir;
		import std.path : buildPath;

		auto tdp = tid in tasks;
		if (tdp is null)
			return;
		if (parentEffectivelyArchived && tdp.archived)
			return;

		if (tdp.taskDir.length > 0)
		{
			auto wtPath = buildPath(tdp.taskDir, "worktree");
			if (exists(wtPath) && isDir(wtPath))
				ops ~= WorktreeOp(tid, wtPath, tdp.projectPath);
		}

		foreach (childTid, ref child; tasks)
			if (child.parentTid == tid)
				collectArchiveOpsDFS(childTid, true, ops);
	}

	/// Collect unarchive ops for `tid` and descendants (main thread only).
	/// Skips tasks still effectively archived by an ancestor.
	private WorktreeOp[] collectUnarchiveOps(int tid)
	{
		WorktreeOp[] ops;
		if (!isEffectivelyArchivedByAncestor(tid))
			collectUnarchiveOpsDFS(tid, false, ops);
		return ops;
	}

	private void collectUnarchiveOpsDFS(int tid, bool parentEffectivelyArchived, ref WorktreeOp[] ops)
	{
		import std.path : buildPath;

		auto tdp = tid in tasks;
		if (tdp is null)
			return;
		if (parentEffectivelyArchived && tdp.archived)
			return;

		if (tdp.taskDir.length > 0)
			ops ~= WorktreeOp(tid, buildPath(tdp.taskDir, "worktree"), tdp.projectPath);

		foreach (childTid, ref child; tasks)
			if (child.parentTid == tid)
				collectUnarchiveOpsDFS(childTid, true, ops);
	}

	/// Async archive/unarchive transition. Runs git operations in a background thread.
	/// `archiveQueue` field name covers both directions (archive and unarchive).
	private Promise!ArchiveState archiveTransition(int tid, ArchiveState goal)
	{
		import std.conv : to;
		import std.path : buildPath;

		// Pre-collect all data on the main thread (safe: read-only access to tasks).
		WorktreeOp[] ops = goal == ArchiveState.Archived
			? collectArchiveOps(tid) : collectUnarchiveOps(tid);

		// Pre-compute cleanup path for archive (avoids accessing tasks in background thread).
		string cleanupTmpPath;
		if (goal == ArchiveState.Archived)
		{
			int rootTid = findRootTid(tid);
			auto rootTd = rootTid in tasks;
			if (rootTd !is null && (rootTid == tid || rootTd.archived))
				cleanupTmpPath = buildPath(runtimeDir(), "tmp-" ~ rootTid.to!string);
		}

		return threadAsync({
			import std.file : exists, rmdirRecurse;

			if (goal == ArchiveState.Archived)
			{
				foreach (op; ops)
					archiveWorktree(op.worktreePath, op.projectPath, op.tid);
				if (cleanupTmpPath.length > 0 && exists(cleanupTmpPath))
				{
					try
						rmdirRecurse(cleanupTmpPath);
					catch (Exception e)
						warningf("archiveTransition: cleanup failed for tid=%d: %s", tid, e.msg);
				}
			}
			else
			{
				foreach (op; ops)
					if (hasArchiveRef(op.projectPath, op.tid))
						unarchiveWorktree(op.projectPath, op.tid, op.worktreePath);
			}
			return goal;
		});
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

	/// Build metadata JSON for a system-generated user message.
	/// The result is a JSON string (or null) to be injected as "meta" in the
	/// unconfirmed-user-event envelope. NOT sent to the agent.
	private string buildCydoMeta(string label, string[string] vars = null,
		string bodyVar = null, bool bodyMarkdown = false)
	{
		import ae.utils.json : JSONOptional, toJson;
		struct CydoMeta {
			string label;
			@JSONOptional string[string] vars;
			@JSONOptional string bodyVar;
			@JSONOptional bool bodyMarkdown;
		}
		CydoMeta m;
		m.label = label;
		m.vars = vars;
		m.bodyVar = bodyVar;
		m.bodyMarkdown = bodyMarkdown;
		return toJson(m);
	}

	/// Broadcast an unconfirmed user message to all clients.
	/// This is shown as pending until Claude echoes it back with is_replay.
	/// cydoMeta is an optional JSON string injected as "meta" on the event;
	/// it is NOT sent to the agent.
	private void broadcastUnconfirmedUserMessage(int tid, const(ContentBlock)[] content,
		string cydoMeta = null)
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
		// Inject meta directly into the event JSON (before the closing brace).
		if (cydoMeta.length > 0)
			userEvent = userEvent[0 .. $ - 1] ~ `,"meta":` ~ cydoMeta ~ `}`;
		string injected = `{"tid":` ~ format!"%d"(tid)
			~ `,"unconfirmedUserEvent":` ~ userEvent
			~ `}`;

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
						dr.hasMessages = cachedp.hasMessages;
						dr.fromCache = true;
					}
					else
					{
						try
						{
							auto meta = agent.readSessionMeta(ds.sessionId);
							dr.title = meta.title;
							dr.projectPath = meta.projectPath;
							dr.hasMessages = meta.hasMessages;
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

				if (!r.hasMessages)
				{
					// Ghost session: no user messages. Cache the result so we don't re-read it.
					if (!r.fromCache)
						persistence.upsertSessionMetaCache(r.agentType, r.sessionId, r.mtime,
							finalProjectPath, r.title, false);
					continue;
				}

				string finalTitle;
				if (r.title.length > 0)
					finalTitle = r.title;
				else
					finalTitle = "(untitled)"; // safety net — should not happen for sessions with messages

				if (!r.fromCache)
					persistence.upsertSessionMetaCache(r.agentType, r.sessionId, r.mtime,
						finalProjectPath, finalTitle, true);

				// Create importable task row — workspace resolved at display time
				auto tid = createTask("", finalProjectPath, r.agentType);
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

				broadcast(toJson(TaskCreatedMessage("task_created", tid, "", finalProjectPath, 0, "")));
				broadcastTaskUpdate(tid);
			}

			// Refresh virtual projects now that importable tasks are known
			{
				import std.algorithm : filter;
				import std.array : array;
				foreach (ref wi; workspacesInfo)
					wi.projects = wi.projects.filter!(p => !p.virtual_).array;
				workspacesInfo = workspacesInfo.filter!(wi => wi.name != "" || wi.projects.length > 0).array;
			}
			injectVirtualProjects();
			broadcast(buildWorkspacesList());
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
			auto isProjectExpr = ws.project_discovery.is_project;
			auto recurseWhenExpr = ws.project_discovery.recurse_when;
			auto cmd = (cmdPrefix !is null ? cmdPrefix : []) ~ cydoBinaryPath
				~ ["discover", ws.root, ws.name, isProjectExpr, recurseWhenExpr]
				~ ws.exclude;

			typeof(execute(cmd)) result;
			try
				result = execute(cmd);
			catch (Exception e)
			{
				sandbox.cleanup();
				warningf("Discovery subprocess failed for workspace '%s': %s", ws.name, e.msg);
				workspacesInfo ~= WorkspaceInfo(ws.name, null, ws.default_agent_type, ws.default_task_type);
				continue;
			}
			sandbox.cleanup();

			if (result.status != 0)
			{
				warningf("Discovery failed for workspace '%s': exit %d", ws.name, result.status);
				workspacesInfo ~= WorkspaceInfo(ws.name, null, ws.default_agent_type, ws.default_task_type);
				continue;
			}

			ProjectInfo[] projInfos;
			try
			{
				auto json = parseJSON(result.output);
				foreach (entry; json.array)
					projInfos ~= ProjectInfo(entry["name"].str, entry["path"].str, false, true);
			}
			catch (Exception e)
				warningf("Discovery JSON parse failed for workspace '%s': %s", ws.name, e.msg);

			workspacesInfo ~= WorkspaceInfo(ws.name, projInfos, ws.default_agent_type, ws.default_task_type);

			infof("Workspace '%s' (%s): %d project(s)", ws.name, ws.root, projInfos.length);
			foreach (ref p; projInfos)
				infof("  - %s (%s)", p.name, p.path);
		}
		injectVirtualProjects();
	}

	/// Inject virtual ProjectInfo entries for task projectPaths not already covered by
	/// discovered projects. Must be called after workspacesInfo is populated.
	private void injectVirtualProjects()
	{
		import std.algorithm : startsWith;
		import std.path : relativePath;

		// Collect all distinct projectPaths from all tasks
		bool[string] seen;
		string[] taskPaths;
		foreach (ref td; tasks)
			if (td.projectPath.length > 0 && td.projectPath !in seen)
			{
				seen[td.projectPath] = true;
				taskPaths ~= td.projectPath;
			}

		// Build set of already-covered paths
		bool[string] coveredPaths;
		foreach (ref wi; workspacesInfo)
			foreach (ref pi; wi.projects)
				coveredPaths[pi.path] = true;

		// For each uncovered path, find which workspace(s) it belongs to
		string[] orphanedPaths;
		foreach (projectPath; taskPaths)
		{
			if (projectPath in coveredPaths)
				continue;

			bool matched = false;
			foreach (ref ws; config.workspaces)
			{
				auto wsRoot = ws.root;
				if (projectPath == wsRoot ||
				    projectPath.startsWith(wsRoot ~ "/"))
				{
					matched = true;
					auto relName = relativePath(projectPath, wsRoot);
					auto vp = ProjectInfo(relName, projectPath, true, exists(projectPath));
					// Find WorkspaceInfo for this workspace
					bool found = false;
					foreach (ref wi; workspacesInfo)
						if (wi.name == ws.name)
						{
							wi.projects ~= vp;
							found = true;
							break;
						}
					if (!found)
						workspacesInfo ~= WorkspaceInfo(ws.name, [vp], ws.default_agent_type, ws.default_task_type);
				}
			}
			if (!matched)
				orphanedPaths ~= projectPath;
		}

		// Handle orphaned paths (not under any workspace root)
		if (orphanedPaths.length > 0)
		{
			// Find or create synthetic workspace with name ""
			WorkspaceInfo* synthWs = null;
			foreach (ref wi; workspacesInfo)
				if (wi.name == "")
				{ synthWs = &wi; break; }

			if (synthWs is null)
			{
				workspacesInfo ~= WorkspaceInfo("", null, "", "");
				synthWs = &workspacesInfo[$ - 1];
			}

			// Re-check coverage (synthetic workspace may already have some paths)
			bool[string] synthCovered;
			foreach (ref pi; synthWs.projects)
				synthCovered[pi.path] = true;

			foreach (projectPath; orphanedPaths)
				if (projectPath !in synthCovered)
					synthWs.projects ~= ProjectInfo(projectPath, projectPath, true, exists(projectPath));
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
		broadcast(buildAgentTypesList());
		broadcast(buildWorkspacesList());
		broadcast(buildServerStatus());
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

		auto titleHandle = agentForTask(tid).completeOneShot(prompt, "small", td.launch);
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
			td.taskType, td.entryPoint, td.agentType, td.archived, td.archiving, td.draft, td.error,
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

		auto types = getTaskTypes();
		auto entryPoints = getEntryPoints();
		EntryPointEntry[] eps;
		foreach (ref ep; entryPoints)
		{
			auto typeDef = types.byName(ep.resolvedType);
			EntryPointEntry entry;
			entry.name = ep.name;
			entry.task_type = ep.resolvedType;
			entry.description = ep.description;
			if (typeDef !is null)
			{
				entry.model_class = typeDef.model_class;
				entry.read_only = typeDef.read_only;
				entry.icon = typeDef.icon;
			}
			eps ~= entry;
		}
		TypeInfoEntry[] typeInfo;
		foreach (ref def; types)
			typeInfo ~= TypeInfoEntry(def.name, def.icon);
		return toJson(TaskTypesListMessage("task_types_list", eps, typeInfo, config.default_task_type));
	}

	private string buildAgentTypesList()
	{
		import ae.utils.json : toJson;
		import cydo.agent.registry : agentRegistry;
		import std.path : expandTilde;

		AgentTypeListEntry[] entries;
		foreach (ref entry; agentRegistry)
		{
			auto agent = entry.create();
			string[string] env;
			foreach (k, v; config.sandbox.env)
				env[k] = expandTilde(v);
			auto agentSandbox = findAgentTypeSandbox(entry.name);
			foreach (k, v; agentSandbox.env)
				env[k] = expandTilde(v);
			auto available = resolveExecutablePath(agent.executableName(env), env).length > 0;
			entries ~= AgentTypeListEntry(entry.name, entry.displayName, available);
		}
		return toJson(AgentTypesListMessage("agent_types_list", entries, config.default_agent_type));
	}

	private string buildServerStatus()
	{
		import ae.utils.json : toJson;
		return toJson(ServerStatusMessage(
			"server_status",
			authUser.length > 0 || authPass.length > 0,
			config.dev_mode,
		));
	}

	private string buildNoticesList()
	{
		import ae.utils.json : toJson;
		return toJson(NoticesListMessage("notices_list", activeNotices));
	}

	private void setNotice(string id, Nullable!Notice n)
	{
		if (!n.isNull)
		{
			auto newNotice = n.get();
			auto existing = id in activeNotices;
			if (existing !is null && *existing == newNotice)
				return;
			activeNotices[id] = newNotice;
			if (newNotice.level == NoticeLevel.alert || newNotice.level == NoticeLevel.warning)
				warningf("NOTICE [%s]: %s — %s — %s", id, newNotice.description, newNotice.impact, newNotice.action);
			else
				infof("NOTICE [%s]: %s", id, newNotice.description);
			broadcast(buildNoticesList());
		}
		else
		{
			if (id !in activeNotices)
				return;
			activeNotices.remove(id);
			broadcast(buildNoticesList());
		}
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

		string debugDir;
		{
			if (config.dev_mode)
			{
				import std.datetime : Clock;
				import std.path : buildPath;
				import ae.sys.paths : getDataDir;
				auto now = Clock.currTime;
				debugDir = buildPath(getDataDir("cydo"), format("suggestion-debug/%04d-%02d-%02dT%02d:%02d:%02d-%d",
					now.year, cast(int)now.month, now.day,
					now.hour, now.minute, now.second, tid));
				import std.file : mkdirRecurse, write;
				mkdirRecurse(debugDir);
				// Write context.jsonl — one raw history envelope per line
				string jsonlContent;
				foreach (ref d; tasks[tid].history)
					jsonlContent ~= cast(string) d.toGC() ~ "\n";
				write(debugDir ~ "/context.jsonl", jsonlContent);
				// Write meta.json
				static struct DebugMeta { int tid; string agentType; string taskType; string timestamp; }
				auto timestamp = format("%04d-%02d-%02dT%02d:%02d:%02d",
					now.year, cast(int)now.month, now.day,
					now.hour, now.minute, now.second);
				write(debugDir ~ "/meta.json", DebugMeta(tid, td.agentType, td.taskType, timestamp).toJson);
			}
		}

		td.suggestGeneration++;
		auto capturedGen = td.suggestGeneration;

		auto suggestHandle = agentForTask(tid).completeOneShot(prompt, "small", td.launch);
		td.suggestGenHandle = suggestHandle.promise;
		td.suggestGenKill = suggestHandle.cancel;
		td.suggestGenHandle.then((string result) {
			if (tid !in tasks)
				return;
			if (tasks[tid].suggestGeneration != capturedGen)
				return;
			tasks[tid].suggestGenHandle = null;
			tasks[tid].suggestGenKill = null;

			if (debugDir.length)
			{
				import std.file : write;
				write(debugDir ~ "/input.txt", prompt);
				write(debugDir ~ "/output.txt", result);
			}

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
			if (debugDir.length)
			{
				import std.file : write;
				write(debugDir ~ "/input.txt", prompt);
				write(debugDir ~ "/error.txt", e.msg);
			}
		}).ignoreResult();

	}

	/// Build an abbreviated conversation history string for suggestion generation.
	private string buildAbbreviatedHistory(int tid)
	{
		if (tid !in tasks)
			return "";
		string[] envelopes;
		foreach (ref d; tasks[tid].history)
			envelopes ~= cast(string) d.toGC();
		return buildAbbreviatedHistoryFromStrings(envelopes);
	}

}

/// Extract text content from a translated protocol event. Handles agnostic
/// protocol (item/started user_message, item/completed) and legacy formats.
private string extractMessageText(string event)
{
	import ae.utils.json : jsonParse, JSONPartial;

	// Try top-level text field first (item/started user_message, item/completed text items)
	@JSONPartial
	static struct TopTextProbe { string text; bool pending; }

	try
	{
		auto probe = jsonParse!TopTextProbe(event);
		if (probe.text.length > 0 && !probe.pending)
			return probe.text;
	}
	catch (Exception) {}

	// Try result field (turn/result events — Codex emits the assistant text here)
	@JSONPartial
	static struct ResultFieldProbe { string result; }

	try
	{
		auto probe = jsonParse!ResultFieldProbe(event);
		if (probe.result.length > 0)
			return probe.result;
	}
	catch (Exception) {}

	// Try top-level string content (item/delta text_delta merged events)
	@JSONPartial
	static struct FlatStringProbe { string content; string delta_type; }

	try
	{
		auto probe = jsonParse!FlatStringProbe(event);
		if (probe.delta_type == "text_delta" && probe.content.length > 0)
			return probe.content;
	}
	catch (Exception) {}

	// Try string content (legacy user messages)
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

private string abbreviateText(string text, size_t threshold)
{
	import std.regex : replaceAll;
	import ae.utils.regex : re;

	text = text.replaceAll(re!`\s+`, " ");
	if (text.length <= threshold)
		return text;
	auto keepEach = threshold / 2 - 3;
	return text[0 .. keepEach] ~ " [...] " ~ text[$ - keepEach .. $];
}

/// Build an abbreviated conversation history string from raw history envelope strings.
/// Performs two passes: first counting stats for the header, then building abbreviated
/// entries walking history in reverse.
private string buildAbbreviatedHistoryFromStrings(string[] envelopes)
{
	// First pass: count stats for structured header
	int userMsgCount = 0;
	int toolUseCount = 0;
	foreach (envelope; envelopes)
	{
		auto event = extractEventFromEnvelope(envelope);
		if (event.length == 0)
			continue;
		import std.algorithm : canFind;
		if (event.canFind(`"user_message"`))
			userMsgCount++;
		if (event.canFind(`"tool_use"`))
			toolUseCount++;
	}

	// Second pass: build entries walking history in reverse
	string[] entries;
	size_t totalLen = 0;
	enum maxLen = 2_500;
	enum truncThreshold = 256;

	bool seenAssistantText = false;
	bool turnCollapsed = false;

	foreach_reverse (envelope; envelopes)
	{
		auto event = extractEventFromEnvelope(envelope);
		if (event.length == 0)
			continue;

		import std.algorithm : canFind;

		string entry;

		if (event.canFind(`"user_message"`))
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
		else if (event.canFind(`"item/completed"`) || event.canFind(`"turn/result"`) ||
		         (event.canFind(`"item/delta"`) && event.canFind(`"text_delta"`)))
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
