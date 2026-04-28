module cydo.app;

import core.lifetime : move;
import core.time : seconds;

// Write end of the shutdown self-pipe; written to by the C signal handler.
// Initialised in setupShutdownPipe() before socketManager.loop() runs.
private shared int shutdownPipeFd = -1;

/// Async-signal-safe SIGTERM/SIGINT handler: writes one byte to the self-pipe
/// so the event loop thread picks it up without any GC interaction.
extern(C) private nothrow @nogc
void shutdownSignalHandler(int sig) @system
{
    import core.sys.posix.unistd : write;
    int fd = shutdownPipeFd;
    if (fd >= 0)
    {
        ubyte[1] b = [1];
        write(fd, b.ptr, 1);
    }
}

import std.file : exists, isFile, thisExePath;
import std.format : format;
import std.logger : tracef, infof, warningf, errorf, fatalf;
import std.stdio : File, stderr;
import std.string : representation;

import ae.utils.funopt : funopt, funoptDispatch, funoptDispatchUsage, FunOptConfig, Option, Parameter;
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
import ae.utils.json : JSONFragment, JSONOptional, JSONPartial, jsonParse, toJson;
import ae.utils.promise : Promise, resolve, reject;
import std.typecons : Nullable;
import ae.utils.promise.concurrency : threadAsync;
import ae.utils.statequeue : StateQueue;

mixin SSLUseLib;

import cydo.mcp : McpResult;
import cydo.mcp.tools : AskQuestion, LaunchedTask, ToolsBackend, ValidatedTask;
import cydo.task : BatchSignal;
import cydo.batchrouter : BatchConsumeKind, BatchState, buildBatchState,
	consumeBatchSignal, validateBatchCompletion;
import cydo.inotify : RefCountedINotify;

import cydo.agent.agent : Agent, DiscoveredSession, SessionConfig, SessionMeta;
import cydo.agent.protocol : BatchResultEnvelope, ContentBlock, PermissionAllow, PermissionDeny,
	ItemStartedEvent, QuestionResult, TaskEventEnvelope, TaskEventSeqEnvelope, TranslatedEvent,
	UnconfirmedUserEventEnvelope, extractContentText;
import cydo.agent.session : AgentSession;
import cydo.agent.terminal : TerminalProcess;
import cydo.config : AgentConfig, CydoConfig, PathMode, SandboxConfig, WorkspaceConfig, loadConfig, reloadConfig;
import cydo.persist : ForkResult, LoadedHistory, Persistence, countLinesAfterForkId, createForkTask, openDatabase,
	editJsonlByContent, editJsonlMessage, findNextUserUuid, forkTask, lastForkIdInJsonl, loadTaskHistory, truncateJsonl, writeJsonlPrefix;
import cydo.sandbox : ProcessLaunch, buildCommandPrefix, cleanup, cydoBinaryDir, cydoBinaryPath,
	prepareProcessLaunch, resolveExecutablePath,
	resolveSandbox, resolveSandboxForDiscovery, runtimeDir;
import cydo.tasktype : TaskTypeDef, UserEntryPointDef, TaskTypeConfig, ContinuationDef, OutputType, WorktreeMode, byName, isInteractive, loadTaskTypes, validateTaskTypes,
	renderPrompt, renderContinuationPrompt, substituteVars, formatCreatableTaskTypes, formatSwitchModes, formatHandoffs,
	loadSystemPrompt, computeReachesWorktree, computeTreeReadOnly;
import cydo.task;
import cydo.worktree;

import uninode.node : UniNode;

private struct BatchHandle
{
	int parentTid;
	ulong batchId;
}

private string resolveTaskTypesPath()
{
	import ae.utils.path : findProgramDirectory;
	import std.path : buildPath;
	auto dir = findProgramDirectory("defs/task-types.yaml");
	if (dir is null)
	{
		warningf("Could not locate defs/task-types.yaml relative to binary");
		return "defs/task-types.yaml";
	}
	return buildPath(dir, "defs/task-types.yaml");
}

@(`CyDo backend and tooling.`)
struct Program
{
static:
	@(`Start the CyDo backend.`)
	void server()
	{
		auto app = new App();
		app.start();

		// Install signal-safe SIGTERM/SIGINT handlers using a self-pipe.
		//
		// ae.net.shutdown (and ae.sys.shutdown) calls thread_suspendAll() inside
		// the signal handler to acquire the GC lock before invoking callbacks.
		// When SIGTERM fires while the main thread holds the GC lock (e.g. during
		// a GC allocation), thread_suspendAll() deadlocks and App.shutdown() is
		// never called, leaving the event loop hanging indefinitely.
		//
		// Instead we bypass that mechanism entirely: a raw POSIX signal handler
		// writes one byte to a pipe (write(2) is async-signal-safe), and a daemon
		// FileConnection on the read end calls app.shutdown() from inside the
		// event loop thread — no GC lock involved.
		setupShutdownPipe(app);

		socketManager.loop();
	}

	/// Run the MCP server.
	void mcpServer()
	{
		import cydo.mcp.server : runMcpServer;
		runMcpServer();
	}

	@(`Simulate task type workflow.`)
	void simulate()
	{
		import cydo.tasktype : runSimulator;
		runSimulator(resolveTaskTypesPath());
	}

	@(`Generate Graphviz dot output for task types.`)
	void dot()
	{
		import cydo.tasktype : runDot;
		runDot(resolveTaskTypesPath());
	}

	@(`Dump agent context for a task type.`)
	void dumpContext(
		Parameter!(string, "Task type name.") typeName,
	)
	{
		import cydo.tasktype : runDumpContext;
		runDumpContext(resolveTaskTypesPath(), typeName);
	}

	/// Discover projects in a workspace.
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

	@(`Open CyDo in a browser.`)
	void open(
		Parameter!(string, "Path to open.") path = null,
	)
	{
		import cydo.config : loadConfig;
		import cydo.discover : discoverProjects, ProjectDiscoveryConfig;
		import std.file : getcwd;
		import std.path : absolutePath, expandTilde;
		import std.process : browse, environment, execute, spawnProcess;
		import std.algorithm : startsWith;
		import std.string : replace, strip;

		auto config = loadConfig();

		// Determine target directory
		string targetDir = path.length > 0
			? absolutePath(expandTilde(path))
			: getcwd();

		// Discover workspace and project for targetDir
		string workspace;
		string projectName;

		foreach (ref ws; config.workspaces)
		{
			auto wsRoot = expandTilde(ws.root);

			// Check if targetDir is under this workspace root
			if (!targetDir.startsWith(wsRoot))
				continue;
			// Make sure it's a proper prefix (not just a partial directory name match)
			if (targetDir.length > wsRoot.length && targetDir[wsRoot.length] != '/')
				continue;

			// Run discovery for this workspace
			auto projects = discoverProjects(wsRoot, ws.name, ws.exclude, ws.project_discovery);

			// Find the project that contains targetDir (longest match)
			string bestPath;
			string bestName;
			foreach (ref p; projects)
			{
				if (targetDir.startsWith(p.path) &&
					(targetDir.length == p.path.length || targetDir[p.path.length] == '/'))
				{
					if (p.path.length > bestPath.length)
					{
						bestPath = p.path;
						bestName = p.name;
					}
				}
			}

			if (bestPath.length > 0)
			{
				workspace = ws.name;
				projectName = bestName;
				break;
			}

			// targetDir is under workspace but not a discovered project —
			// still use this workspace (will open at workspace level)
			workspace = ws.name;
			break;
		}

		// Build URL
		auto sslCert = environment.get("CYDO_TLS_CERT", null);
		auto proto = sslCert ? "https" : "http";
		auto listenAddr = environment.get("CYDO_LISTEN_ADDRESS", "localhost");
		if (listenAddr == "*") listenAddr = "localhost";
		auto listenPort = environment.get("CYDO_LISTEN_PORT", "3940");
		auto authUser = environment.get("CYDO_AUTH_USER", null);

		string hostPort = listenAddr ~ ":" ~ listenPort;

		// Build path portion: /{workspace}/{encoded-project}
		// Project names use : instead of / in URLs
		string urlPath = "/";
		if (workspace.length > 0)
		{
			urlPath = "/" ~ workspace ~ "/";
			if (projectName.length > 0)
				urlPath ~= projectName.replace("/", ":");
		}

		string url;
		if (authUser.length > 0)
			url = proto ~ "://" ~ authUser ~ "@" ~ hostPort ~ urlPath;
		else
			url = proto ~ "://" ~ hostPort ~ urlPath;

		// Try chromium --app mode first, fall back to browse()
		auto chromiumResult = execute(["which", "chromium"]);
		if (chromiumResult.status == 0)
		{
			auto chromiumPath = chromiumResult.output.strip();
			spawnProcess([chromiumPath, "--app=" ~ url]);
		}
		else
			browse(url);
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

		initLogLevel();

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

		import ae.utils.path : findProgramDirectory;
		auto defsBase = () { auto d = findProgramDirectory("defs/task-types.yaml"); return d !is null ? d : ""; }();
		auto promptPath = buildPath(defsBase, "defs", "prompts/generate-suggestions.md");
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
			if (result.length == 0)
				stderr.writeln("Warning: got empty response from agent");
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

	@(`Export tasks as a self-contained HTML file.`)
	void exportHtml(
		Parameter!(int[], "Task IDs to export.") tids,
		Option!(string, "Output file path (default: export.html).") output = "export.html",
	)
	{
		import std.file : write;
		import std.format : format;
		import std.path : buildPath;

		import ae.utils.path : findProgramDirectory;

		import cydo.export_ : buildExportHtml, collectTaskTree, exportTaskData;
		import cydo.persist : openDatabase;

		if (tids.length == 0)
		{
			stderr.writeln("Error: at least one task ID is required");
			import core.stdc.stdlib : exit;
			exit(1);
		}

		// Open database
		Persistence persistence;
		try
			persistence = openDatabase();
		catch (Exception e)
		{
			stderr.writeln("Error: could not open database: ", e.msg);
			import core.stdc.stdlib : exit;
			exit(1);
		}

		// Collect task tree
		auto taskRows = collectTaskTree(persistence, tids);
		if (taskRows.length == 0)
		{
			stderr.writeln("Error: no tasks found for the given IDs");
			import core.stdc.stdlib : exit;
			exit(1);
		}

		// Check for invalid TIDs
		bool[int] foundTids;
		foreach (ref t; taskRows)
			foundTids[t.tid] = true;
		foreach (tid; tids)
			if (tid !in foundTids)
				stderr.writeln("Warning: task ID ", tid, " not found in database");

		// Locate the export HTML template
		auto baseDir = findProgramDirectory("defs/task-types.yaml");
		if (baseDir is null)
		{
			stderr.writeln("Error: could not locate application directory");
			import core.stdc.stdlib : exit;
			exit(1);
		}
		auto templatePath = buildPath(baseDir, "web/dist-export/export.html");

		// Load task type definitions for icon info
		import cydo.task : TypeInfoEntry;
		import cydo.tasktype : loadTaskTypes;
		auto taskTypesPath = buildPath(baseDir, "defs/task-types.yaml");
		auto taskTypeConfig = loadTaskTypes(taskTypesPath);
		TypeInfoEntry[] typeInfo;
		foreach (ref def; taskTypeConfig.types)
			typeInfo ~= TypeInfoEntry(def.name, def.icon);

		// Export task data as JSON
		auto jsonData = exportTaskData(persistence, taskRows, typeInfo);

		// Inject data and write output
		auto html = buildExportHtml(templatePath, jsonData);
		write(output, html);
		stderr.writeln(format!"Exported %d task(s) to %s"(taskRows.length, output));
	}
}

/// Self-pipe shutdown: installs signal handlers that write to a pipe; a
/// daemon FileConnection on the read end drives App.shutdown() from within
/// the event loop thread without acquiring the GC lock.
// pipe2 is Linux-only; declare it directly rather than relying on druntime bindings.
private extern(C) int pipe2(int* pipefd, int flags) nothrow @nogc @system;

private void setupShutdownPipe(App app)
{
	import core.sys.posix.fcntl : O_CLOEXEC, O_NONBLOCK;
	import core.sys.posix.signal : SIGTERM, SIGINT, sigaction, sigaction_t, sigemptyset, SA_RESETHAND;
	import ae.net.asockets : FileConnection;
	import ae.sys.data : Data;

	// pipe2 with O_CLOEXEC|O_NONBLOCK: FDs are not inherited by child processes
	// (claude, codex, etc.) and the write end never blocks in the signal handler.
	int[2] fds;
	pipe2(fds.ptr, O_CLOEXEC | O_NONBLOCK);

	// Store write fd globally for the C-level signal handler.
	shutdownPipeFd = fds[1];

	// Daemon read connection — does not keep the event loop alive by itself.
	auto readConn = new FileConnection(fds[0]);
	readConn.daemonRead = true;
	bool shutdownTriggered;
	readConn.handleReadData = (Data) {
		import std.logger : infof;
		if (!shutdownTriggered)
		{
			shutdownTriggered = true;
			infof("shutdown pipe fired, calling app.shutdown()");
			app.shutdown();
			infof("app.shutdown() returned");
		}
	};
	readConn.handleDisconnect = (string reason, DisconnectType) {
		import std.logger : infof;
		infof("shutdown pipe read end disconnected: %s", reason);
	};

	// Install raw signal handler — no D runtime involved, no GC.
	sigaction_t sa;
	sa.sa_handler = &shutdownSignalHandler;
	sigemptyset(&sa.sa_mask);
	sa.sa_flags = SA_RESETHAND; // reset to SIG_DFL after first delivery
	sigaction(SIGTERM, &sa, null);
	sigaction(SIGINT,  &sa, null);
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
	enum config = () { import std.getopt : config; FunOptConfig c; c.getoptConfig = [config.stopOnFirstNonOption]; return c; }();
	funopt!(dispatch, config, usageFun)(args);
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
	/// after receiving the full history buffer. Every task_reload is a hard
	/// boundary: clients are unsubscribed and must re-subscribe via request_history.
	private bool[int][WebSocketAdapter] clientSubscriptions;
	private TaskData[int] tasks;
	private Persistence persistence;
	private CydoConfig config;
	private WorkspaceInfo[] workspacesInfo;
	private Agent agent; // default agent
	private Agent[string] agentsByType;
	// Task type definitions loaded from YAML, cached per project path ("" = global)
	private struct ProjectTypeCache
	{
		TaskTypeDef[] types;
		UserEntryPointDef[] entryPoints;
		bool[string] reachesWorktree;
		bool[string] treeReadOnly;
	}
	private ProjectTypeCache[string] taskTypesByProject;
	private string taskTypesDir;
	private string taskTypesPath;
	private string webDistDir;
	// Pending sub-task promises (childTid → promise fulfilled on task exit)
	private Promise!(McpResult)[int] pendingSubTasks;
	// In-memory mirror of task_deps table (childTid → parentTid)
	private int[int] taskDeps;
	// Child tids whose result was already delivered to a live Task() batch via
	// pendingSubTasks, used to suppress duplicate onExit fallback delivery.
	private bool[int] liveDeliveredSubTasks;
	// Pending AskUserQuestion promises (tid -> promise fulfilled when user responds)
	private Promise!(McpResult)[int] pendingAskUserQuestions;
	// Pending PermissionPrompt promises (tid -> promise fulfilled when user responds)
	private Promise!(McpResult)[int] pendingPermissionPrompts;
	// Original input JSON per tid for building Allow response
	private string[int] pendingPermissionInputs;
	// Per-parent batch state, keyed by parent tid
	private BatchState[int] activeBatches;
	private ulong nextBatchId = 1;
	// App-global question ID counter and registry
	private int nextQid = 1;
	private Promise!McpResult[int] pendingQuestions;  // qid → promise waiting for answer
	private int[int] questionToTask;                   // qid → tid of the task that asked
	private ulong[int] questionToBatch;                // qid → originating parent batch id
	// JSONL file tracking state
	private JsonlTracker jsonlTracker;
	// inotify watches for config file hot-reload
	private INotify.WatchDescriptor configFileWatch;
	private INotify.WatchDescriptor configDirWatch;
	private bool configFileWatchActive;
	private bool configDirWatchActive;
	// inotify watches for per-project config hot-reload (projectPath → watch)
	private RefCountedINotify projectINotify;
	private RefCountedINotify.Handle[string] projectDirWatches;
	private RefCountedINotify.Handle[string] projectFileWatches;
	// HTTP basic auth credentials (from environment)
	private string authUser;
	private string authPass;
	// Active notices keyed by notice ID
	private Notice[string] activeNotices;
	// Set during SIGTERM shutdown — suppress onExit status updates so tasks
	// stay "alive" in the DB and can be resumed after restart.
	private bool shuttingDown;

	// Active TerminalProcess instances (Bash MCP tool calls in flight).
	// Tracked so shutdown() can SIGKILL them to unblock the event loop.
	private TerminalProcess[] activeTerminals;

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

	private string[] promptSearchPath(string projectPath)
	{
		import std.path : buildPath, expandTilde;
		string[] dirs;
		if (projectPath.length > 0)
			dirs ~= buildPath(projectPath, ".cydo/defs");
		dirs ~= buildPath(expandTilde("~/.config/cydo"), "defs");
		dirs ~= taskTypesDir;
		return dirs;
	}

	private TaskTypeDef[] getTaskTypesForProject(string projectPath)
	{
		import std.path : buildPath, expandTilde;
		try
		{
			auto userTypesPath = buildPath(expandTilde("~/.config/cydo"), "task-types.yaml");
			auto projectTypesPath = projectPath.length > 0
				? buildPath(projectPath, ".cydo/task-types.yaml") : "";
			auto config = loadTaskTypes(taskTypesPath, userTypesPath, projectTypesPath);
			auto errors = validateTaskTypes(config.types, config.entryPoints, promptSearchPath(projectPath));
			foreach (e; errors)
				warningf("task type: %s", e);
			taskTypesByProject[projectPath] = ProjectTypeCache(
				config.types,
				config.entryPoints,
				computeReachesWorktree(config.types),
				computeTreeReadOnly(config.types),
			);
			return taskTypesByProject[projectPath].types;
		}
		catch (Exception e)
		{
			warningf("task types file changed but failed to parse, keeping previous version: %s", e.msg);
			if (auto p = projectPath in taskTypesByProject)
				return p.types;
			return null;
		}
	}

	private UserEntryPointDef[] getEntryPointsForProject(string projectPath)
	{
		if (auto p = projectPath in taskTypesByProject)
			return p.entryPoints;
		getTaskTypesForProject(projectPath);
		if (auto p = projectPath in taskTypesByProject)
			return p.entryPoints;
		return null;
	}

	private TaskTypeDef[] getTaskTypes()
	{
		return getTaskTypesForProject("");
	}

	private UserEntryPointDef[] getEntryPoints()
	{
		return getEntryPointsForProject("");
	}

	private bool[string] reachesWorktreeFor(string projectPath)
	{
		if (projectPath.length > 0)
			if (auto p = projectPath in taskTypesByProject)
				return p.reachesWorktree;
		if (auto p = "" in taskTypesByProject)
			return p.reachesWorktree;
		return null;
	}

	private bool[string] treeReadOnlyFor(string projectPath)
	{
		if (projectPath.length > 0)
			if (auto p = projectPath in taskTypesByProject)
				return p.treeReadOnly;
		if (auto p = "" in taskTypesByProject)
			return p.treeReadOnly;
		return null;
	}

	void start()
	{
		initLogLevel();
		{
			import ae.utils.path : findProgramDirectory;
			import std.path : buildPath;
			auto baseDir = findProgramDirectory("defs/task-types.yaml");
			if (baseDir is null)
			{
				warningf("Could not locate application directory (defs/task-types.yaml not found relative to binary)");
				baseDir = "";
			}
			else if (baseDir != "")
				infof("Application base directory: %s", baseDir);
			taskTypesDir = buildPath(baseDir, "defs");
			taskTypesPath = buildPath(baseDir, "defs/task-types.yaml");
			webDistDir = buildPath(baseDir, "web/dist/");
		}
		{
			persistence = openDatabase();
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
		jsonlTracker.sendToSubscribed = (int tid, string msg) =>
			sendToSubscribed(tid, Data(msg.representation));
		jsonlTracker.onAnchorResolved = (int tid, size_t seq, string anchor) =>
			backfillHistoryAnchor(tid, seq, anchor);

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
			td.needsAttention = row.needsAttention;
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
	/// Called from the self-pipe shutdown handler (runs in the event loop thread).
	void shutdown()
	{
		infof("shutdown() called, cleaning up resources");
		shuttingDown = true;
		foreach (ref td; tasks)
		{
			if (td.session)
			{
				// stop() only if the process is still alive; killAfterTimeout is
				// always needed — when bwrap exits from the process-group SIGTERM
				// before shutdown() runs, asyncWait fires first (exited=true, alive=false)
				// but an orphaned child inside the namespace may still hold the pipe
				// write-ends open.  killAfterTimeout's forceClosePipes (2.5 s) closes
				// the backend side of the pipes so the event loop can drain.
				if (td.session.alive)
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
		// SIGKILL any in-flight Bash MCP tool calls so the event loop can drain.
		foreach (t; activeTerminals)
			t.forceKill();
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
		// loop can drain. WebSocket-upgraded connections have conn = null
		// (set during upgrade in ae's BaseHttpServerConnection), so guard
		// against that before accessing conn.state.
		{
			import std.array : array;
			import ae.net.asockets : disconnectable;
			foreach (c; server.connections.iterator.array)
				if (c.conn !is null && c.conn.state.disconnectable)
					c.conn.disconnect("shutting down");
		}
		// WebSocket-upgraded connections have conn=null but retain a non-daemon
		// idle TimerTask in ae's mainTimer, which prevents the event loop from
		// exiting. Cancel those timers so the event loop can drain cleanly.
		{
			import std.array : array;
			foreach (c; server.connections.iterator.array)
				if (c.conn is null && c.timer !is null && !c.timer.when().isNull)
					c.timer.cancelIdleTimeout();
		}
		if (mcpServer)
		{
			mcpServer.close();
			// mcpServer.close() only disconnects idle connections; force-close any
			// remaining active ones (e.g. in-flight MCP tool calls) so the event
			// loop can drain.
			{
				import std.array : array;
				import ae.net.asockets : disconnectable;
				foreach (c; mcpServer.connections.iterator.array)
					if (c.conn !is null && c.conn.state.disconnectable)
						c.conn.disconnect("shutting down");
			}
		}
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
		foreach (projectPath, handle; projectFileWatches)
			projectINotify.remove(handle);
		projectFileWatches = null;
		foreach (projectPath, handle; projectDirWatches)
			projectINotify.remove(handle);
		projectDirWatches = null;
		infof("shutdown() complete");
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
				response.serveFile(pub, webDistDir);
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
		if (path == "" || !exists(webDistDir ~ path) || !isFile(webDistDir ~ path))
			path = "index.html";
		response.serveFile(path, webDistDir);
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

		auto raw = seq < td.rawSource.length ? td.rawSource[seq] : null;

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
			import std.conv : to;
			if (!conn.connected)
			{
				// MCP delivery failed — trigger fallback delivery for Task tool calls.
				onMcpDeliveryFailed(call.tid);
				return;
			}
			// If the tool set a pendingContinuation (SwitchMode/Handoff), interrupt
			// the agent instead of returning the result — force an immediate stop.
			auto parsedTid = to!int(call.tid);
			if (auto tdp = parsedTid in tasks)
			{
				if (tdp.pendingContinuation !is null)
				{
					tdp.processQueue.setGoal(ProcessState.Dead).ignoreResult();
					tdp.session.interrupt();
					return;
				}
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
				if (tdp.pendingContinuation !is null)
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

	/// Handle Task — validates the spec and returns a delegate that, when called,
	/// creates the child task and returns `{childTid, promise}`.
	/// On validation failure, returns a ValidatedTask with a null launch delegate.
	ValidatedTask handleCreateTask(string callerTid,
		string description, string taskType, string prompt)
	{
		import ae.utils.json : toJson;
		import std.algorithm : canFind, map;
		import std.array : join;
		import std.conv : to;

		McpResult structuredTaskError(string message)
		{
			auto taskResultJson = toJson(TaskResult(message, null, null, null, message));
			return McpResult.structured(taskResultJson, true);
		}

		// Look up calling task
		int parentTid;
		try
			parentTid = to!int(callerTid);
		catch (Exception)
			return ValidatedTask(structuredTaskError("Invalid calling task ID"));

		auto parentTd = parentTid in tasks;
		if (parentTd is null)
			return ValidatedTask(structuredTaskError("Calling task not found"));

		// Validate task_type against parent's creatable_tasks and resolve alias
		auto parentTypeDef = getTaskTypesForProject(parentTd.projectPath).byName(parentTd.taskType);
		string resolvedTaskType = taskType;
		if (parentTypeDef !is null &&
			parentTypeDef.creatable_tasks.length > 0)
		{
			auto edge = parentTypeDef.creatable_tasks.byName(taskType);
			if (edge is null)
			{
				return ValidatedTask(structuredTaskError(
					"Task type '" ~ taskType ~ "' is not in creatable_tasks for '" ~
					parentTd.taskType ~ "'. Allowed: " ~
					parentTypeDef.creatable_tasks.map!(c => c.name).join(", ")));
			}
			resolvedTaskType = edge.resolvedType;
		}

		// Validate child task type exists
		auto childTypeDef = getTaskTypesForProject(parentTd.projectPath).byName(resolvedTaskType);
		if (childTypeDef is null)
			return ValidatedTask(structuredTaskError("Unknown task type: " ~ resolvedTaskType));

		// All validation passed — return a delegate that performs the actual creation.
		// Capture only simple values; re-fetch pointers at launch time to avoid
		// stale AA pointers if sibling delegates caused reallocation.
		return ValidatedTask(McpResult.init, () {
			auto pd = parentTid in tasks;
			auto ptd = getTaskTypesForProject(pd.projectPath).byName(pd.taskType);
			auto ctd = getTaskTypesForProject(pd.projectPath).byName(resolvedTaskType);

			// Create child task
			auto childTid = createTask(pd.workspace, pd.projectPath, pd.agentType);
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
			pd.status = "waiting";
			persistence.setStatus(parentTid, "waiting");
			broadcastTaskUpdate(parentTid);

			// Broadcast to UI
			broadcast(toJson(TaskCreatedMessage("task_created", childTid,
				pd.workspace, pd.projectPath, parentTid, "subtask")));
			broadcastTaskUpdate(childTid);
			broadcastFocusHint(parentTid, childTid);

			// Set up worktree from edge config: create new or inherit from parent
			string edgeTemplate;
			if (ptd !is null)
			{
				if (auto edge = ptd.creatable_tasks.byName(taskType))
				{
					edgeTemplate = edge.prompt_template;
					childTd.resultNote = substituteVars(edge.result_note,
						["output_dir": pd.taskDir]);
					setupWorktreeForEdge(childTid, parentTid, edge.worktree);
				}
			}

			// Configure and spawn child agent
			auto renderedPrompt = renderPrompt(*ctd, prompt, promptSearchPath(childTd.projectPath), childTd.outputPath, edgeTemplate);
			renderedPrompt = prependTaskSystemPrompt(renderedPrompt,
				taskSystemPromptForMessage(childTid, ctd));
			auto taskPromptMsgSubject = taskPromptSubject(resolvedTaskType);
			auto subtaskMeta = buildKnownSystemMessageMeta(
				KnownSystemMessageKind.taskPrompt,
				taskPromptMsgSubject,
				["task_description": prompt], "task_description", true);
			tasks[childTid].processQueue.setGoal(ProcessState.Alive).then(() {
				sendTaskMessage(childTid, [ContentBlock("text", wrapKnownSystemMessage(
					KnownSystemMessageKind.taskPrompt, renderedPrompt, taskPromptMsgSubject))], null, subtaskMeta);
			}).ignoreResult();

			if (description.length == 0)
			{
				auto promptForTitle = prompt;
				tasks[childTid].processQueue.setGoal(ProcessState.Alive).then(() {
					generateTitle(childTid, promptForTitle);
				}).ignoreResult();
			}
			infof("Task: tid=%d type=%s parent=%d", childTid, resolvedTaskType, parentTid);

			return LaunchedTask(childTid, promise);
		});
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

		auto parentTypeDef = getTaskTypesForProject(parentTd.projectPath).byName(parentTd.taskType);
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

		auto treeReadOnly = treeReadOnlyFor(parentTd.projectPath);
		auto childRO = resolvedType in treeReadOnly;
		return childRO is null || !(*childRO);
	}

	private McpResult makeInternalBatchError(string message)
	{
		errorf("batch router error: %s", message);
		return McpResult("Internal batch routing error: " ~ message, true);
	}

	private bool createActiveBatch(int parentTid, int[] childTids, out BatchHandle handle, out string error)
	{
		auto batch = buildBatchState(nextBatchId++, childTids, error);
		if (error.length > 0)
		{
			handle = BatchHandle.init;
			return false;
		}
		activeBatches[parentTid] = batch;
		handle = BatchHandle(parentTid, batch.batchId);
		return true;
	}

	private void enqueueChildDoneSignal(BatchHandle handle, size_t slot, int childTid, McpResult result)
	{
		auto batch = handle.parentTid in activeBatches;
		if (batch is null)
			return;
		if (batch.batchId != handle.batchId)
			return;
		if (slot >= batch.childTids.length || batch.childTids[slot] != childTid)
		{
			errorf("dropping childDone with invalid slot ownership: parent=%d batch=%s child=%d slot=%s",
				handle.parentTid, handle.batchId, childTid, slot);
			return;
		}
		batch.eventQueue.fulfillOne(BatchSignal.childDone(handle.batchId, slot, childTid, result));
	}

	private void enqueueQuestionSignal(BatchHandle handle, size_t slot, int childTid, string questionText, int qid)
	{
		auto batch = handle.parentTid in activeBatches;
		if (batch is null)
			return;
		if (batch.batchId != handle.batchId)
			return;
		if (slot >= batch.childTids.length || batch.childTids[slot] != childTid)
		{
			errorf("dropping question with invalid slot ownership: parent=%d batch=%s child=%d slot=%s qid=%d",
				handle.parentTid, handle.batchId, childTid, slot, qid);
			return;
		}
		batch.eventQueue.fulfillOne(BatchSignal.question(handle.batchId, slot, childTid, questionText, qid));
	}

	/// Set up batch event stream and enter the wait loop.
	/// Called from createTasks — parent fiber blocks here.
	Promise!McpResult registerBatchAndAwait(string callerTidStr,
		LaunchedTask[] launchedTasks)
	{
		import std.conv : to;
		int parentTid;
		try
			parentTid = to!int(callerTidStr);
		catch (Exception)
			return resolve(makeInternalBatchError("invalid calling task ID for Task batch"));

		int[] childTids = new int[launchedTasks.length];
		foreach (i, ref launchedTask; launchedTasks)
		{
			if (launchedTask.promise is null)
				return resolve(makeInternalBatchError(format!"missing child promise for slot %s"(i)));
			childTids[i] = launchedTask.childTid;
		}

		BatchHandle handle;
		string batchError;
		if (!createActiveBatch(parentTid, childTids, handle, batchError))
			return resolve(makeInternalBatchError(batchError));

		foreach (i, ref launchedTask; launchedTasks)
		{
			(BatchHandle h, size_t slot, int cTid, Promise!McpResult promise) {
				promise.then((McpResult r) {
					enqueueChildDoneSignal(h, slot, cTid, r);
				});
			}(handle, i, launchedTask.childTid, launchedTask.promise);
		}

		return awaitBatchLoop(parentTid, handle.batchId);
	}

	/// Enter (or re-enter) the batch wait loop for a parent.
	/// Blocks until all children complete or a child asks a question.
	private Promise!McpResult awaitBatchLoop(int parentTid, ulong batchId)
	{
		import ae.utils.json : JSONFragment, toJson;
		import ae.utils.promise.await : await;

		auto current = parentTid in activeBatches;
		if (current is null)
			return resolve(makeInternalBatchError(
				format!"no active batch for parent tid=%d (expected batch=%s)"(parentTid, batchId)));
		if (current.batchId != batchId)
			return resolve(makeInternalBatchError(
				format!"active batch mismatch for parent tid=%d: expected=%s got=%s"(parentTid, batchId, current.batchId)));

		while (true)
		{
			current = parentTid in activeBatches;
			if (current is null)
				return resolve(makeInternalBatchError(
					format!"batch disappeared while waiting for parent tid=%d batch=%s"(parentTid, batchId)));
			if (current.batchId != batchId)
				return resolve(makeInternalBatchError(
					format!"batch replaced while waiting for parent tid=%d: expected=%s got=%s"(parentTid, batchId, current.batchId)));
			if (current.completed >= current.totalChildren)
				break;

			auto sig = current.eventQueue.waitOne().await();

			current = parentTid in activeBatches;
			if (current is null)
				return resolve(makeInternalBatchError(
					format!"batch disappeared after event for parent tid=%d batch=%s"(parentTid, batchId)));
			if (current.batchId != batchId)
				return resolve(makeInternalBatchError(
					format!"batch replaced after event for parent tid=%d: expected=%s got=%s"(parentTid, batchId, current.batchId)));

			auto consumed = consumeBatchSignal(*current, sig, (int childTid, int qid) {
				if (childTid !in tasks)
					return false;
				auto childTd = &tasks[childTid];
				return childTd.pendingAskPromise !is null && childTd.pendingAskQid == qid;
			});

			final switch (consumed.kind)
			{
				case BatchConsumeKind.ignored:
				case BatchConsumeKind.childDone:
					break;
				case BatchConsumeKind.question:
					// Return question to parent agent — parent answers via Answer,
					// which re-enters this same batch instance.
					return resolve(buildQuestionResult(consumed.childTid, consumed.qid, consumed.questionText));
				case BatchConsumeKind.invalid:
					errorf("ignoring invalid batch signal for parent=%d batch=%s: %s",
						parentTid, batchId, consumed.error);
					break;
			}
		}

		current = parentTid in activeBatches;
		if (current is null || current.batchId != batchId)
			return resolve(makeInternalBatchError(
				format!"batch missing before finalization for parent tid=%d batch=%s"(parentTid, batchId)));

		auto invariantError = validateBatchCompletion(*current);
		if (invariantError.length > 0)
		{
			activeBatches.remove(parentTid);
			return resolve(makeInternalBatchError(
				format!"cannot finalize parent tid=%d batch=%s: %s"(parentTid, batchId, invariantError)));
		}

		// All children done — assemble results and clean up
		auto results = current.results.dup;
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
		auto wrappedJson = toJson(BatchResultEnvelope(items));
		return resolve(McpResult.structured(wrappedJson, anyError));
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

		auto typeDef = getTaskTypesForProject(td.projectPath).byName(td.taskType);
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

		td.pendingContinuation = new PendingContinuation(PendingContinuation.Kind.switchMode, continuation);
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

		auto typeDef = getTaskTypesForProject(td.projectPath).byName(td.taskType);
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

		// Reject Handoff while the current task owns unanswered child questions.
		// A handoff successor does not inherit batch ownership or question-answer
		// authority; the question would be permanently stranded.
		if (auto batch = tid in activeBatches)
		{
			foreach (cTid; batch.childTids)
			{
				if (cTid in tasks && tasks[cTid].pendingAskPromise !is null)
				{
					auto childTd = &tasks[cTid];
					import std.conv : to;
					return McpResult(
						"Handoff cannot continue while sub-task question qid="
						~ to!string(childTd.pendingAskQid)
						~ " is waiting for your answer. "
						~ "Use Answer(...) first, or SwitchMode if you need a different mode before answering.",
						true);
				}
			}
		}

		td.pendingContinuation = new PendingContinuation(PendingContinuation.Kind.handoff, continuation, prompt);
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
		auto taskTypes = getTaskTypesForProject(tdp.projectPath);
		auto typeDef = taskTypes.byName(tdp.taskType);
		if (typeDef is null || !taskTypes.isInteractive(getEntryPointsForProject(tdp.projectPath), tdp.taskType))
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
		auto msg = toJson(AskUserQuestionMessage("ask_user_question", tid,
			toolUseId, JSONFragment(questionsJson)));
		sendToSubscribed(tid, Data(msg.representation));

		// Update task state for sidebar
		tdp.needsAttention = true;
		persistence.setNeedsAttention(tid, true);
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
		auto terminal = new TerminalProcess(
			["/bin/sh", "-c", command],
			null,   // inherit env
			null,   // inherit working directory
			1024 * 1024
		);

		activeTerminals ~= terminal;

		auto promise = new Promise!McpResult;
		terminal.onExit = () {
			import std.algorithm : remove;
			activeTerminals = activeTerminals.remove!(t => t is terminal);
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

		// Child completed/failed/active → resume or send follow-up
		if (childTd.status == "completed" || childTd.status == "failed" || childTd.status == "active")
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
			broadcastFocusHint(parentTid, childTid);

			// Register a single-child batch so we can reuse awaitBatchLoop
			BatchHandle batchHandle;
			string batchError;
			if (!createActiveBatch(parentTid, [childTid], batchHandle, batchError))
				return resolve(makeInternalBatchError(batchError));

			// Hook the promise into the event queue
			subTaskPromise.then((McpResult r) { enqueueChildDoneSignal(batchHandle, 0, childTid, r); });

			// Resume child process and send follow-up message with qid
			childTd.processQueue.setGoal(ProcessState.Alive).then(() {
				auto followUpMsgSubject = followUpFromParentSubject(qid);
				auto msg = wrapKnownSystemMessage(
					KnownSystemMessageKind.followUpFromParent,
					message
						~ "\n\nAnswer with Answer(" ~ to!string(qid) ~ ", \"your response\").",
					followUpMsgSubject);
				auto followUpMeta = buildKnownSystemMessageMeta(
					KnownSystemMessageKind.followUpFromParent,
					followUpMsgSubject,
					["message": message], "message", true);
				sendTaskMessage(childTid, [ContentBlock("text", msg)], null, followUpMeta);
			}).ignoreResult();

			// When child calls Answer(qid, ...), the promise is fulfilled directly.
			// We still need to await the batch in case child exits without answering.
			// The Answer handler will fulfill pendingQuestions[qid] which resolves promise.
			// We return the promise that's fulfilled when child answers.
			// But we must also enter awaitBatchLoop so the parent waits properly.
			// Wire: when promise is fulfilled (child answers), deliver to parent via awaitBatchLoop.
			promise.then((McpResult r) {
				// Child answered the follow-up — deliver as batch result
				enqueueChildDoneSignal(batchHandle, 0, childTid, r);
				pendingQuestions.remove(qid);
				questionToTask.remove(qid);
				questionToBatch.remove(qid);
			});

			return awaitBatchLoop(parentTid, batchHandle.batchId);
		}

		// Child is busy (waiting on its own sub-tasks, etc.) — enqueue for delivery when idle.
		{
			int qid = nextQid++;
			auto promise = new Promise!McpResult;
			pendingQuestions[qid] = promise;
			questionToTask[qid] = parentTid;

			BatchHandle batchHandle;
			size_t childSlot;
			if (auto batch = parentTid in activeBatches)
			{
				if (!batch.trySlotForChild(childTid, childSlot))
				{
					return resolve(makeInternalBatchError(
						format!"active batch for parent tid=%d does not own child tid=%d"(parentTid, childTid)));
				}
				batchHandle = BatchHandle(parentTid, batch.batchId);
			}
			else
			{
				string batchError;
				if (!createActiveBatch(parentTid, [childTid], batchHandle, batchError))
					return resolve(makeInternalBatchError(batchError));
				childSlot = 0;
			}

			// Wire the question promise to fire a batch signal when answered
			promise.then((McpResult r) {
				enqueueChildDoneSignal(batchHandle, childSlot, childTid, r);
				pendingQuestions.remove(qid);
				questionToTask.remove(qid);
				questionToBatch.remove(qid);
			});

			// Set parent to waiting
			tasks[parentTid].status = "waiting";
			persistence.setStatus(parentTid, "waiting");
			broadcastTaskUpdate(parentTid);

			// Attach a callback that delivers the question when the child becomes idle
			childTd.onIdleCallbacks ~= () {
				if (childTid !in tasks || !tasks[childTid].alive)
				{
					// Child died before question could be delivered
					if (auto qp = qid in pendingQuestions)
					{
						(*qp).fulfill(McpResult("Sub-task exited before the queued question could be delivered", true));
						pendingQuestions.remove(qid);
						questionToTask.remove(qid);
						questionToBatch.remove(qid);
					}
					return;
				}
				auto ctd = &tasks[childTid];
				ctd.status = "active";
				persistence.setStatus(childTid, "active");
				broadcastTaskUpdate(childTid);
				broadcastFocusHint(parentTid, childTid);
				auto followUpMsgSubject = followUpFromParentSubject(qid);
				auto followUpMsg = wrapKnownSystemMessage(
					KnownSystemMessageKind.followUpFromParent,
					message ~ "\n\nAnswer with Answer(" ~ to!string(qid) ~ ", \"your response\").",
					followUpMsgSubject);
				auto followUpMeta = buildKnownSystemMessageMeta(
					KnownSystemMessageKind.followUpFromParent,
					followUpMsgSubject,
					["message": message], "message", true);
				sendTaskMessage(childTid, [ContentBlock("text", followUpMsg)], null, followUpMeta);
			};

			return awaitBatchLoop(parentTid, batchHandle.batchId);
		}
	}

	private Promise!McpResult handleAskParent(int childTid, int parentTid, string message)
	{
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
		{
			size_t slot;
			if (batch.trySlotForChild(childTid, slot))
			{
				questionToBatch[qid] = batch.batchId;
				enqueueQuestionSignal(BatchHandle(parentTid, batch.batchId), slot, childTid, message, qid);
			}
			else
				errorf("dropping question for parent tid=%d child tid=%d: child not in active batch",
					parentTid, childTid);
		}

		// Update child status
		childTd.status = "waiting";
		childTd.notificationBody = "Asking parent: " ~ truncateTitle(message, 100);
		persistence.setStatus(childTid, "waiting");
		broadcastTaskUpdate(childTid);
		broadcastFocusHint(childTid, parentTid);

		return promise;
	}

	Promise!McpResult handleAnswer(string callerTidStr, int qid, string message)
	{
		import std.conv : to;
		import cydo.agent.protocol : AnswerResult;
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
			auto expectedBatchIdPtr = qid in questionToBatch;
			if (expectedBatchIdPtr is null)
			{
				return resolve(makeInternalBatchError(
					format!"missing originating batch for child question: parent tid=%d qid=%d"(callerTidInt, qid)));
			}
			auto expectedBatchId = *expectedBatchIdPtr;

			auto batch = callerTidInt in activeBatches;
			if (batch is null)
			{
				return resolve(makeInternalBatchError(
					format!"no active batch while answering child question: parent tid=%d qid=%d"(callerTidInt, qid)));
			}
			if (batch.batchId != expectedBatchId)
			{
				return resolve(makeInternalBatchError(
					format!"batch mismatch while answering child question: parent tid=%d qid=%d expected=%s got=%s"(callerTidInt, qid, expectedBatchId, batch.batchId)));
			}

			// Fulfill child's blocking Ask call with the answer
			auto answerJson = toJson(AnswerResult("answered", callerTidInt, 0,
				tasks[callerTidInt].title, message,
				"Use Ask(question) to ask follow-up questions."));
			(*questionPromise).fulfill(McpResult.structured(answerJson));

			// Clean up child state
			if (askTd.pendingAskPromise !is null)
			{
				askTd.pendingAskPromise = null;
				askTd.pendingAskQuestion = null;
				askTd.pendingAskQid = 0;
			}
			pendingQuestions.remove(qid);
			questionToTask.remove(qid);
			questionToBatch.remove(qid);

			// Update child status
			askTd.status = "active";
			askTd.notificationBody = "";
			persistence.setStatus(askTid, "active");
			broadcastTaskUpdate(askTid);
			broadcastFocusHint(callerTidInt, askTid);

			// Re-enter the batch wait loop — blocks until next event
			return awaitBatchLoop(callerTidInt, expectedBatchId);
		}
		else if (childAnsweringParent)
		{
			// Child answering parent's follow-up question.
			// Defer fulfillment until the child's turn completes (becomes idle),
			// so the parent doesn't receive the answer mid-turn.
			auto answerJson = toJson(AnswerResult("answered", callerTidInt, 0,
				tasks[callerTidInt].title, message,
				"Use Ask(question, " ~ to!string(callerTidInt) ~ ") for further follow-ups."));
			auto answerResult = McpResult.structured(answerJson);
			int childTid = callerTidInt;

			tasks[childTid].onIdleCallbacks ~= () {
				// Fulfill the promise — handleAskChild's .then() delivers to parent's batch.
				if (auto qp = qid in pendingQuestions)
					(*qp).fulfill(answerResult);
				// pendingQuestions/questionToTask cleanup done in handleAskChild's .then()

				// Complete the child task.
				if (childTid in tasks)
				{
					tasks[childTid].status = "completed";
					persistence.setStatus(childTid, "completed");
					persistence.setResultText(childTid, tasks[childTid].resultText);
				}
				if (childTid in pendingSubTasks)
					pendingSubTasks.remove(childTid);
				if (auto parentTidPtr = childTid in taskDeps)
				{
					auto parentTid2 = *parentTidPtr;
					removeTaskDependency(parentTid2, childTid);
				}
				broadcastFocusHint(childTid, askTid);
			};

			// Return simple success to the child immediately.
			auto deliveredJson = toJson(AnswerResult("delivered", askTid, qid,
				null, null, "Answer delivered to parent task. End the session now."));
			return resolve(McpResult.structured(deliveredJson));
		}
		else
		{
			return resolve(McpResult(
				"Unknown question ID: " ~ to!string(qid), true));
		}
	}

	Promise!McpResult handlePermissionPrompt(string callerTidStr, string toolUseId,
		string toolName, JSONFragment input)
	{
		import std.conv : to;
		int callerTidInt;
		try callerTidInt = to!int(callerTidStr);
		catch (Exception) return resolve(McpResult("Invalid calling task ID", true));

		auto callerTd = callerTidInt in tasks;
		if (callerTd is null) return resolve(McpResult("Task not found", true));

		string policy = findWorkspacePermissionPolicy(callerTd.workspace);
		string resolved = evaluatePermissionPolicy(policy, toolName, input.json);

		if (resolved == "deny")
			return resolve(McpResult(makePermissionDenyJson("Permission denied by policy"), false));
		if (resolved == "allow")
			return resolve(McpResult(makePermissionAllowJson(input.json), false));

		// "ask" mode — prompt the user via WebSocket
		return promptUserForPermission(callerTidInt, toolUseId, toolName, input);
	}

	private Promise!McpResult promptUserForPermission(int tid, string toolUseId,
		string toolName, JSONFragment input)
	{
		// Only one pending permission prompt per task
		if (tid in pendingPermissionPrompts)
			return resolve(McpResult(makePermissionDenyJson("Another permission prompt is already pending"), false));

		auto promise = new Promise!McpResult;
		pendingPermissionPrompts[tid] = promise;
		pendingPermissionInputs[tid] = input.json;

		// Store fields for late-joining clients
		auto tdp = &tasks[tid];
		tdp.pendingPermissionToolUseId = toolUseId;
		tdp.pendingPermissionToolName = toolName;
		tdp.pendingPermissionInput = input;

		// Broadcast to subscribed clients
		sendToSubscribed(tid, Data(toJson(PermissionPromptMessage("permission_prompt",
			tid, toolUseId, toolName, input)).representation));

		// Update task state for sidebar
		tdp.needsAttention = true;
		persistence.setNeedsAttention(tid, true);
		tdp.hasPendingQuestion = true;
		tdp.notificationBody = "Permission requested";
		tdp.isProcessing = false;
		touchTask(tid);
		persistence.setLastActive(tid, tasks[tid].lastActive);
		broadcastTaskUpdate(tid);

		return promise;
	}

	private McpResult buildQuestionResult(int childTid, int qid, string questionText)
	{
		auto childTitle = (childTid in tasks) ? tasks[childTid].title : null;
		auto questionJson = toJson(QuestionResult("question", childTid, qid, childTitle, questionText));
		return McpResult.structured(questionJson);
	}

	private void removeTaskDependency(int parentTid, int childTid)
	{
		persistence.removeTaskDep(parentTid, childTid);
		taskDeps.remove(childTid);
		liveDeliveredSubTasks.remove(childTid);
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
			removeTaskDependency(tid, childTid);
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
		persistence.setNeedsAttention(tid, false);
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
		sendToSubscribed(tid, Data(toJson(AskUserQuestionMessage("ask_user_question",
			tid, "", JSONFragment("[]"))).representation));

		broadcastTaskUpdate(tid);
	}

	private void handlePermissionPromptResponse(WsMessage json)
	{
		auto tid = json.tid;
		if (tid < 0 || tid !in tasks)
			return;

		auto pending = tid in pendingPermissionPrompts;
		if (pending is null)
			return;

		auto td = &tasks[tid];
		td.pendingPermissionToolUseId = null;
		td.pendingPermissionToolName = null;
		td.pendingPermissionInput = JSONFragment.init;
		td.needsAttention = false;
		persistence.setNeedsAttention(tid, false);
		td.hasPendingQuestion = false;
		td.notificationBody = "";
		td.isProcessing = true;

		// json.content is JSON from the frontend:
		//   {"behavior":"allow"} or {"behavior":"deny","message":"..."}
		string rawContent = json.content.json !is null ? jsonParse!string(json.content.json) : "{}";
		string resultText;
		try
		{
			import std.json : parseJSON;
			auto parsed = parseJSON(rawContent);
			if (auto behavior = "behavior" in parsed)
			{
				if (behavior.str == "allow")
					resultText = makePermissionAllowJson(pendingPermissionInputs[tid]);
				else
				{
					string denyMsg = "User denied permission";
					if (auto msg = "message" in parsed)
						if (msg.str.length > 0)
							denyMsg = msg.str;
					resultText = makePermissionDenyJson(denyMsg);
				}
			}
			else
				resultText = makePermissionDenyJson("Invalid response");
		}
		catch (Exception)
			resultText = makePermissionDenyJson("Invalid response");

		pending.fulfill(McpResult(resultText, false));
		pendingPermissionPrompts.remove(tid);
		pendingPermissionInputs.remove(tid);

		// Broadcast clear to all subscribed clients (empty tool_use_id signals clear)
		sendToSubscribed(tid, Data(toJson(PermissionPromptMessage("permission_prompt",
			tid, "", "", JSONFragment("{}"))).representation));

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
			case "edit_raw_event":    handleEditRawEvent(ws, json); break;
			case "set_archived":      handleSetArchivedMsg(ws, json); break;
			case "set_draft":         handleSetDraftMsg(ws, json); break;
			case "delete_task":       handleDeleteTaskMsg(json); break;
			case "ask_user_response": handleAskUserResponse(json); break;
			case "permission_prompt_response": handlePermissionPromptResponse(json); break;
			case "refresh_workspaces": handleRefreshWorkspacesMsg(); break;
			case "promote_task":     handlePromoteTaskMsg(json); break;
			case "set_task_type":    handleSetTaskTypeMsg(json); break;
			case "set_entry_point":  handleSetEntryPointMsg(json); break;
			case "set_agent_type":   handleSetAgentTypeMsg(json); break;
			case "request_task_types": handleRequestTaskTypesMsg(ws, json); break;
			default: break;
		}
	}

	private void handleSetTaskTypeMsg(WsMessage json)
	{
		auto tid = json.tid;
		if (tid < 0 || tid !in tasks) return;
		if (tasks[tid].alive) return; // can't change type of a running task
		if (json.task_type.length == 0) return;
		if (getTaskTypesForProject(tasks[tid].projectPath).byName(json.task_type) is null) return;
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
		auto ep = getEntryPointsForProject(tasks[tid].projectPath).byName(json.entry_point);
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
		auto entryPoints = getEntryPointsForProject(json.project_path);
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
		// Call getTaskTypesForProject() after getEntryPointsForProject() so the cache is populated.
		auto taskTypes = getTaskTypesForProject(json.project_path);
		tasks[tid].entryPoint = json.entry_point;
		persistence.setEntryPoint(tid, json.entry_point);
		tasks[tid].taskType = ep.resolvedType;
		if (taskTypes.byName(ep.resolvedType) !is null)
			persistence.setTaskType(tid, ep.resolvedType);
		// Send task_created only to the requesting client (unicast) so that
		// parallel test workers don't steal each other's task IDs.
		ws.send(Data(toJson(TaskCreatedMessage("task_created", tid, json.workspace, json.project_path, 0, "", json.correlation_id)).representation));
		unicastFocusHint(ws, 0, tid);
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
			string sessionStartMsgSubject;
			if (typeDef !is null)
			{
				import std.algorithm : filter;
				import std.array : array;
				auto rendered = renderPrompt(*typeDef, textContent, promptSearchPath(td.projectPath), td.outputPath, epTemplate);
				rendered = prependTaskSystemPrompt(rendered,
					taskSystemPromptForMessage(tid, typeDef));
				auto sessionStartLabelSource = td.entryPoint.length > 0 ? td.entryPoint : td.taskType;
				sessionStartMsgSubject = sessionStartSubject(sessionStartLabelSource);
				// Preserve image blocks alongside the rendered text prompt.
				messageToSend = ContentBlock("text", wrapKnownSystemMessage(
					KnownSystemMessageKind.sessionStart, rendered, sessionStartMsgSubject))
					~ blocks.filter!(b => b.type == "image").array;
			}
			// Record text so ensureHistoryLoaded can produce correct synthetics
			// for queue-operation:remove lines (same as handleUserMessage does).
			td.pendingSteeringTexts ~= textContent;
			auto msgContent = blocks;
			auto msgMeta = typeDef !is null
				? buildKnownSystemMessageMeta(
					KnownSystemMessageKind.sessionStart,
					sessionStartMsgSubject,
					["task_description": textContent], "task_description", false)
				: null;
			tasks[tid].processQueue.setGoal(ProcessState.Alive).then(() {
				sendTaskMessage(tid, messageToSend, msgContent, msgMeta);
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

		// Pre-compute rollback skip lines for Codex agents
		bool[int] rollbackSkipLines;
		if (td.agentType == "codex" && jsonlPath.length > 0)
		{
			import std.file : exists, readText;
			if (exists(jsonlPath))
			{
				import cydo.agent.codex : computeRollbackSkipLines;
				rollbackSkipLines = computeRollbackSkipLines(readText(jsonlPath));
			}
		}

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
		auto stripTransientStatus = (TranslatedEvent[] events) {
			return filterTransientSessionStatusEvents(events);
		};
		ta.resetHistoryReplay();
		auto loaded = loadTaskHistory(tid, jsonlPath, delegate TranslatedEvent[](string line, int lineNum) {
			// Skip lines that are part of rolled-back turns
			if (lineNum in rollbackSkipLines)
				return [];
			if (isQueueOperation(line))
			{
				import ae.utils.json : jsonParse;
				import std.format : format;
				auto op = jsonParse!QueueOperationProbe(line);
				if (op.operation == "enqueue")
				{
					hasQueueOps = true;
					string text = op.content;
					steeringStash ~= text;
					steeringEnqueueLineNums ~= lineNum;
					steeringEnqueueRawLines ~= line;
					return []; // Dequeue+echo/compaction will emit the confirmed version
				}
				else if (op.operation == "dequeue" || op.operation == "remove")
				{
					TranslatedEvent[] result;
					// Flush any deferred synthetic from a prior dequeue/remove
					// (handles compacted back-to-back dequeues)
					if (lastDequeuedText.length > 0)
					{
						auto synEv = buildSyntheticUserEvent(lastDequeuedText);
						result ~= TranslatedEvent(toJsonWithSyntheticUserMeta(lastDequeuedText, synEv),
							lastDequeuedRawLine.length > 0 ? lastDequeuedRawLine : null);
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
							auto synEv = buildSyntheticUserEvent(text, true);
							synEv.uuid = enqueueUuid;
							result ~= TranslatedEvent(toJsonWithSyntheticUserMeta(text, synEv),
								enqRaw.length > 0 ? enqRaw : null);
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
					return stripTransientStatus(result);
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
							import std.format : format;
							auto enqueueUuid = format!"enqueue-%d"(savedEnqueueLineNum);
							// Inject enqueue UUID into the first event (item/started type=user_message).
							import cydo.agent.protocol : ItemStartedEvent;
							auto ev = jsonParse!ItemStartedEvent(ts[0].translated);
							// Only steering echoes should use enqueue-N as the visible anchor.
							// Regular user turns keep the raw user UUID.
							if (ev.is_steering)
								ev.uuid = enqueueUuid;
							return stripTransientStatus([TranslatedEvent(toJson(ev), ts[0].raw)] ~ ts[1 .. $]);
						}
					return [];
				}
				if (ta.isAssistantMessageLine(line))
				{
					// Compacted: assistant response appeared without preceding user echo —
					// emit synthetic with enqueue UUID before the assistant line.
					import std.format : format;
					auto enqueueUuid = format!"enqueue-%d"(lastDequeuedEnqueueLineNum);
					auto synEv = buildSyntheticUserEvent(lastDequeuedText, true);
					synEv.uuid = enqueueUuid;
					auto synthetic = toJsonWithSyntheticUserMeta(lastDequeuedText, synEv);
					auto syntheticRaw = lastDequeuedRawLine.length > 0 ? lastDequeuedRawLine : null;
					lastDequeuedText = null;
					lastDequeuedEnqueueLineNum = 0;
					lastDequeuedRawLine = null;
					auto ts = ta.translateHistoryLine(line, lineNum);
					return stripTransientStatus([TranslatedEvent(synthetic, syntheticRaw)] ~ ts);
				}
				// Other lines (file-history-snapshot, progress, etc.) are translated/dropped;
				// stay in deferred mode waiting for type:"user" or type:"assistant".
				return stripTransientStatus(ta.translateHistoryLine(line, lineNum));
			}
			if (ta.isUserMessageLine(line))
				userMsgFromJsonl++;
			return stripTransientStatus(ta.translateHistoryLine(line, lineNum));
		});
		td.setHistory(loaded.history, loaded.rawSource);
		td.clearPendingDequeuedSteering();
		td.historyLoaded = true;
		// For agents without queue-operations (e.g. Copilot), emit synthetics for
		// user messages that were sent but not yet flushed to JSONL at kill time.
		if (!hasQueueOps && td.pendingSteeringTexts.length > userMsgFromJsonl)
		{
			import std.datetime : Clock;
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
				auto synEv = buildSyntheticUserEvent(text);
				synEv.uuid = uuid;
				td.appendHistory(Data(
					toJson(TaskEventEnvelope(tid, Clock.currStdTime,
						JSONFragment(toJsonWithSyntheticUserMeta(text, synEv)))).representation), null);
			}
			// Broadcast updated forkable UUIDs now that events.jsonl has new entries.
			jsonlTracker.broadcastForkableUuidsFromFile(tid);
		}
		rebuildVisibleTurnAnchors(tid);
	}

	private void handleRequestHistory(WebSocketAdapter ws, WsMessage json)
	{
		import ae.utils.json : toJson;

		auto tid = json.tid;
		if (tid < 0 || tid !in tasks)
			return;
		auto td = &tasks[tid];

		ensureHistoryLoaded(tid);

		// Send unified history to requesting client (add _seq)
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
			import cydo.task : extractTsFromEnvelope;
			event = normalizeKnownSystemMessageMeta(event);
			auto clientEnvelope = toJson(TaskEventSeqEnvelope(
				tid,
				cast(int) i,
				extractTsFromEnvelope(envelope),
				JSONFragment(event)));
			ws.send(Data(clientEnvelope.representation));
		}

		// Send forkable UUIDs extracted from JSONL
		if (td.agentSessionId.length > 0)
			jsonlTracker.sendForkableUuidsFromFile(ws, tid, td.agentSessionId,
				td.effectiveCwd);

		// Send end marker
		ws.send(Data(toJson(TaskHistoryEndMessage("task_history_end", tid)).representation));

		// Re-broadcast live session status only for active runs.
		if (td.isProcessing && td.hasLastSessionStatus)
		{
			ws.send(Data(toJson(TaskEventEnvelope(tid, td.lastSessionStatusTs,
				JSONFragment(td.lastSessionStatus))).representation));
		}

		// Send cached suggestions if available
		if (td.lastSuggestions.length > 0)
			ws.send(Data(toJson(SuggestionsUpdateMessage("suggestions_update", tid,
				td.lastSuggestions)).representation));

		// Re-broadcast pending AskUserQuestion (client reconnect / tab switch)
		if (tid in pendingAskUserQuestions && tasks[tid].pendingAskToolUseId.length > 0)
		{
			auto tdask = &tasks[tid];
			ws.send(Data(toJson(AskUserQuestionMessage("ask_user_question", tid,
				tdask.pendingAskToolUseId, tdask.pendingAskQuestions)).representation));
		}

		// Re-broadcast pending PermissionPrompt (client reconnect / tab switch)
		if (tid in pendingPermissionPrompts && tasks[tid].pendingPermissionToolUseId.length > 0)
		{
			auto tdperm = &tasks[tid];
			ws.send(Data(toJson(PermissionPromptMessage("permission_prompt", tid,
				tdperm.pendingPermissionToolUseId, tdperm.pendingPermissionToolName,
				tdperm.pendingPermissionInput)).representation));
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
			auto typeDef = getTaskTypesForProject(td.projectPath).byName(td.taskType);
			if (typeDef !is null)
			{
				import std.algorithm : filter;
				import std.array : array;
				string entryPointTemplate;
				if (td.entryPoint.length > 0)
				{
					auto ep = getEntryPointsForProject(td.projectPath).byName(td.entryPoint);
					if (ep !is null)
						entryPointTemplate = ep.prompt_template;
				}
				auto rendered = renderPrompt(*typeDef, textContent, promptSearchPath(td.projectPath),
					td.outputPath, entryPointTemplate);
				rendered = prependTaskSystemPrompt(rendered,
					taskSystemPromptForMessage(tid, typeDef));
				auto sessionStartLabelSource = td.entryPoint.length > 0 ? td.entryPoint : td.taskType;
				auto sessionStartMsgSubject = sessionStartSubject(sessionStartLabelSource);
				// Preserve image blocks alongside the rendered text prompt.
				messageToSend = ContentBlock("text", wrapKnownSystemMessage(
					KnownSystemMessageKind.sessionStart, rendered, sessionStartMsgSubject))
					~ blocks.filter!(b => b.type == "image").array;
				// Attach metadata so the frontend can render this as a collapsible system message.
				userMsgMeta = buildKnownSystemMessageMeta(
					KnownSystemMessageKind.sessionStart,
					sessionStartMsgSubject,
					["task_description": textContent], "task_description", false);
			}
		}
		td.lastSuggestions = null;
		td.processQueue.setGoal(ProcessState.Alive).then(() {
			auto td = &tasks[tid];
			if (td.status == "alive")
			{
				td.status = "active";
				persistence.setStatus(tid, "active");
			}
			sendTaskMessage(tid, messageToSend, blocks, userMsgMeta);
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
		persistence.setNeedsAttention(tid, false);
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
			td.stdinClosed = true;
			broadcastTaskUpdate(tid);
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
			persistence.setNeedsAttention(tid, false);
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
			auto childTypeDef = getTaskTypesForProject(tasks[childTid].projectPath).byName(tasks[childTid].taskType);
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
					broadcastFocusHint(tid, childTid);
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
		broadcastFocusHint(tid, result.tid);
	}

	private void handleUndoTaskMsg(WebSocketAdapter ws, WsMessage json)
	{
		import ae.utils.json : toJson;
		import cydo.agent.codex : CodexAgent;

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
			if (cast(CodexAgent) ta !is null)
			{
				import std.file : exists, readText;
				import cydo.agent.codex : CodexActiveUserTurnsAfterStatus, countActiveUserTurnsAfterForkId;

				auto jsonlPath = ta.historyPath(td.agentSessionId, td.effectiveCwd);
				if (jsonlPath.length == 0 || !exists(jsonlPath))
				{
					ws.send(Data(toJson(ErrorMessage("error", "UUID not found in task history", tid)).representation));
					return;
				}

				auto result = countActiveUserTurnsAfterForkId(readText(jsonlPath), json.after_uuid);
				final switch (result.status)
				{
					case CodexActiveUserTurnsAfterStatus.targetMissing:
						ws.send(Data(toJson(ErrorMessage("error", "UUID not found in task history", tid)).representation));
						return;
					case CodexActiveUserTurnsAfterStatus.targetNotUser:
						ws.send(Data(toJson(ErrorMessage("error", "Undo target is not a user message", tid)).representation));
						return;
					case CodexActiveUserTurnsAfterStatus.ok:
						break;
				}
				// +1 to include the target user message itself
				ws.send(Data(toJson(UndoPreviewMessage("undo_preview", tid, result.visibleCount + 1)).representation));
				return;
			}

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
			if (td.session && td.session.alive)
			{
				// Codex alive path: use thread/rollback RPC instead of killing
				import cydo.agent.codex : ThreadRollbackOutcome;
				if (auto ca = cast(CodexAgent) ta)
				{
					import std.file : exists, readText;
					import cydo.agent.codex : CodexActiveUserTurnsAfterStatus, countActiveUserTurnsAfterForkId;

					auto jsonlPath = ta.historyPath(td.agentSessionId, td.effectiveCwd);
					if (jsonlPath.length == 0 || !exists(jsonlPath))
					{
						ws.send(Data(toJson(ErrorMessage("error", "UUID not found in task history", tid)).representation));
						return;
					}

					auto result = countActiveUserTurnsAfterForkId(readText(jsonlPath), json.after_uuid);
					final switch (result.status)
					{
						case CodexActiveUserTurnsAfterStatus.targetMissing:
							ws.send(Data(toJson(ErrorMessage("error", "UUID not found in task history", tid)).representation));
							return;
						case CodexActiveUserTurnsAfterStatus.targetNotUser:
							warningf("tid=%d: thread/rollback invariant: after_uuid=%s is not a user-message line — falling back to kill+truncate",
								tid, json.after_uuid);
							fallbackUndoKillAndTruncate(ws, tid, json);
							return;
						case CodexActiveUserTurnsAfterStatus.ok:
							break;
					}

					// +1: include the target turn itself
					auto numTurns = cast(uint)(result.count + 1);

					ca.rollbackThread(td.agentSessionId, numTurns, td.launch, td.workspace)
						.then((r) {
							if (!r.ok)
							{
								warningf("thread/rollback failed (tid=%d): %s — falling back to kill+truncate",
									tid, r.error);
								fallbackUndoKillAndTruncate(ws, tid, json);
								return;
							}
							// Rollback succeeded — Codex appended a ThreadRolledBack marker.
							// Clear the undo snapshot (no longer needed for this undo).
							jsonlTracker.clearUndoJsonl(tid);
							// Reload history (marker-aware reading skips rolled-back turns).
							auto td2 = &tasks[tid];
							td2.history = DataVec();
							td2.rawSource = null;
							td2.historyLoaded = false;
							unsubscribeAll(tid);

							// Reset JSONL tracker so it re-reads fork IDs
							jsonlTracker.stopJsonlWatch(tid);

							// Clip pendingSteeringTexts to match remaining user messages
							if (td2.pendingSteeringTexts.length > 0)
							{
								import std.file : readText, exists;
								auto histPath = ta.historyPath(td2.agentSessionId, td2.effectiveCwd);
								if (histPath.length > 0 && histPath.exists)
								{
									auto forkIds = ta.extractForkableIdsWithInfo(readText(histPath));
									int remaining = 0;
									foreach (ref f; forkIds)
										if (f.isUser) remaining++;
									if (remaining < cast(int)td2.pendingSteeringTexts.length)
										td2.pendingSteeringTexts = td2.pendingSteeringTexts[0 .. remaining].dup;
								}
							}

							ws.send(Data(toJson(UndoResultMessage("undo_result", tid, "")).representation));
							emitTaskReload(tid);
							broadcastTaskUpdate(tid);
						}).ignoreResult();
					return;
				}

				// Non-Codex alive session: kill + JSONL truncation
				fallbackUndoKillAndTruncate(ws, tid, json);
				return;
			}

			performUndoExecution(ws, tid, json);
		}
	}

	/// Kill the alive session and then perform JSONL-based undo.
	/// Used as fallback when thread/rollback is unavailable or fails.
	private void fallbackUndoKillAndTruncate(WebSocketAdapter ws, int tid, WsMessage json)
	{
		import ae.utils.json : toJson;

		if (tid < 0 || tid !in tasks)
			return;
		auto td = &tasks[tid];
		auto ta = agentForTask(tid);

		// Use the pre-compaction JSONL snapshot saved by JsonlTracker.
		// Agents like Codex compact the JSONL file ~270ms after a new
		// turn starts (triggered by response.created), well before the
		// undo click arrives.  The snapshot was taken on the last
		// forkId-producing event, preserving line-based fork IDs that
		// would otherwise be invalidated by compaction.
		auto jsonlPathSnap = ta.historyPath(td.agentSessionId, td.effectiveCwd);
		auto jsonlSnap = jsonlTracker.getUndoJsonl(tid);
		jsonlTracker.clearUndoJsonl(tid);

		bool snapshotContainsUndoAnchor(string snapshot, string forkId)
		{
			import std.string : lineSplitter;

			if (snapshot.length == 0 || forkId.length == 0)
				return false;

			int lnum = 0;
			foreach (rawLine; snapshot.lineSplitter)
			{
				lnum++;
				if (rawLine.length == 0)
					continue;
				if (ta.forkIdMatchesLine(rawLine, lnum, forkId))
					return true;
			}
			return false;
		}

		td.processQueue.setGoal(ProcessState.Dead).then(() {
			if (jsonlSnap.length > 0 && jsonlPathSnap.length > 0 &&
				snapshotContainsUndoAnchor(jsonlSnap, json.after_uuid))
			{
				import std.file : write;
				write(jsonlPathSnap, jsonlSnap);
			}
			performUndoExecution(ws, tid, json);
		}).ignoreResult();
		td.session.stop();
	}

	private void performUndoExecution(WebSocketAdapter ws, int tid, WsMessage json)
	{
		import ae.utils.json : toJson;

		if (tid < 0 || tid !in tasks)
			return;
		auto td = &tasks[tid];

		auto ta = agentForTask(tid);

		// 1. Revert file changes via one-shot --rewind-files invocation
		// (done first so that on failure we haven't modified anything yet)
		import std.algorithm : canFind, startsWith;
		string rewindOutput;
		if (json.revert_files && ta.supportsFileRevert())
		{
			// Synthetic enqueue-N anchors need explicit resolution to the
			// corresponding raw user UUID before file rewind.
			string rewindUuid = json.after_uuid;
			if (rewindUuid.startsWith("enqueue-"))
			{
				ensureHistoryLoaded(tid);
				rewindUuid = td.checkpointUuidForAnchor(json.after_uuid);
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
			td.resetHistory();
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

		emitTaskReload(tid);

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

	private void handleEditMessage(WebSocketAdapter ws, WsMessage json)
	{
		import ae.utils.json : toJson;
		import std.algorithm : startsWith;

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
		string fallbackUuid;
		if (targetUuid.startsWith("enqueue-"))
		{
			ensureHistoryLoaded(tid);
			fallbackUuid = td.checkpointUuidForAnchor(targetUuid);
		}
		if (targetUuid.length == 0)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Message UUID not found in history", tid)).representation));
			return;
		}

		auto edited = editJsonlMessage(jsonlPath, targetUuid,
			&ta.forkIdMatchesLine,
			(string line) => replaceUserMessageContent(line, newContent));
		if (!edited && fallbackUuid.length > 0)
		{
			edited = editJsonlMessage(jsonlPath, fallbackUuid,
				&ta.forkIdMatchesLine,
				(string line) => replaceUserMessageContent(line, newContent));
		}

		if (!edited)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Message UUID not found in history", tid)).representation));
			return;
		}

		td.resetHistory();
		td.historyLoaded = false;
		unsubscribeAll(tid);

		emitTaskReload(tid, "edit");
		broadcastTaskUpdate(tid);
	}

	private void handleEditRawEvent(WebSocketAdapter ws, WsMessage json)
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
			ws.send(Data(toJson(ErrorMessage("error", "Stop the session before editing events", tid)).representation));
			return;
		}

		auto seq = json.seq;
		if (seq < 0)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Invalid seq number", tid)).representation));
			return;
		}

		ensureHistoryLoaded(tid);

		if (seq >= td.rawSource.length || td.rawSource[seq] is null)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Seq out of range or no raw source", tid)).representation));
			return;
		}

		auto originalLine = td.rawSource[seq];
		auto ta = agentForTask(tid);
		auto jsonlPath = ta.historyPath(td.agentSessionId, td.effectiveCwd);
		auto newContent = json.content.json !is null ? jsonParse!string(json.content.json) : "";

		// Compact to single line — JSONL requires one JSON object per line.
		string compactContent;
		try
		{
			import std.json : parseJSON;
			compactContent = parseJSON(newContent).toString();
		}
		catch (Exception)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Invalid JSON in edited event", tid)).representation));
			return;
		}

		auto edited = editJsonlByContent(jsonlPath, originalLine, compactContent);

		if (!edited)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Raw event not found in JSONL file", tid)).representation));
			return;
		}

		td.resetHistory();
		td.historyLoaded = false;
		unsubscribeAll(tid);

		emitTaskReload(tid, "edit");
		broadcastTaskUpdate(tid);
	}

	/// Send a user message to a task's agent session.
	///
	/// This is the sole entry point for delivering messages to an agent. It
	/// writes the message to the agent's stdin and flips the task into the
	/// "processing" state (yellow dot in the UI), which is later cleared when
	/// the agent emits a `result` event or the process exits.
	/// Broadcast an unconfirmed user message to subscribed clients and send it to the
	/// agent.  Every code path that delivers a message must use this method so
	/// that (a) the UI sees a pending bubble immediately and (b) processing
	/// state stays consistent.
	///
	/// `broadcastContent` — if non-null, broadcast this to the UI instead of
	/// `content`.  Use this when the agent receives a rendered prompt template
	/// but the UI should display the user's original text.
	private void sendTaskMessage(int tid, const(ContentBlock)[] content,
		const(ContentBlock)[] broadcastContent = null, string cydoMeta = null)
	{
		sendPreparedTaskMessage(tid, content, broadcastContent, cydoMeta, true);
	}

	/// Send a prepared message to the agent and emit the matching pending UI echo.
	///
	/// System messages are ordinary prepared messages with a stable wrapper format
	/// and CyDo metadata for collapsed rendering.
	private void sendPreparedTaskMessage(int tid, const(ContentBlock)[] content,
		const(ContentBlock)[] broadcastContent = null, string cydoMeta = null,
		bool captureUndoSnapshot = true)
	{
		import std.algorithm : min, filter;
		import std.array : array;
		import cydo.agent.protocol : ItemStartedEvent;

		auto td = &tasks[tid];
		assert(td.taskType.length > 0, "Task must have a task_type when sending a message");

		// --- broadcast unconfirmed user message to UI ---
		auto uiContent = broadcastContent !is null ? broadcastContent : content;
		ItemStartedEvent ev;
		ev.item_id   = "cc-user-msg";
		ev.item_type = "user_message";
		ev.text      = extractContentText(uiContent);
		ev.content   = uiContent.dup;
		ev.pending   = true;
		auto userEvent = toJson(ev);
		if (cydoMeta.length > 0)
			userEvent = userEvent[0 .. $ - 1] ~ `,"meta":` ~ cydoMeta ~ `}`;
		auto data = Data(toJson(UnconfirmedUserEventEnvelope(
			tid,
			JSONFragment(userEvent))).representation);
		if (tid in tasks)
		{
			ensureHistoryLoaded(tid);
			tasks[tid].appendHistory(data, null);
		}
		sendToSubscribed(tid, data);

		// --- send to agent ---
		// Snapshot the JSONL before the agent processes the new message.
		// Agents like Codex may compact the JSONL on the first streaming event
		// (response.created), invalidating line-based fork IDs.  Capturing here,
		// before any agent write, preserves the pre-compaction content for undo.
		if (captureUndoSnapshot)
			jsonlTracker.captureUndoSnapshot(tid);
		const(ContentBlock)[] toSend = td.session.supportsImages
			? content
			: content.filter!(b => b.type != "image").array;
		td.session.sendMessage(toSend);
		td.isProcessing = true;
		touchTask(tid);
		td.needsAttention = false;
		persistence.setNeedsAttention(tid, false);
		td.notificationBody = "";
		td.suggestGenHandle = null; // cancel any in-flight suggestion generation
		td.suggestGeneration++;
		broadcastTaskUpdate(tid);
	}

	private string taskSystemPromptForMessage(int tid, TaskTypeDef* typeDef)
	{
		if (typeDef is null)
			return null;

		auto taskAgent = agentForTask(tid);
		if (taskAgent.supportsDeveloperPrompt)
			return null;

		auto td = &tasks[tid];
		return loadSystemPrompt(*typeDef, promptSearchPath(td.projectPath), td.outputPath);
	}

	private static string prependTaskSystemPrompt(string promptText, string systemPrompt)
	{
		if (systemPrompt.length == 0)
			return promptText;
		return "[TASK DESCRIPTION]\n" ~ systemPrompt
			~ "\n\n[END TASK DESCRIPTION]\n\n[TASK PROMPT]\n" ~ promptText;
	}

	private enum KnownSystemMessageKind
	{
		taskPrompt,
		sessionStart,
		followUpFromParent,
		subTaskWaitingForAnswer,
		missingRequiredOutputs,
		handoff,
		subTaskResults,
		restartNudge,
		postCompactionTaskModeReminder,
		modeSwitch,
	}

	private struct KnownSystemMessageMatch
	{
		KnownSystemMessageKind kind;
		string label;
		Nullable!int qid;
		Nullable!int tid;
		Nullable!string title;
	}

	private static string systemMessageSubject(KnownSystemMessageKind kind)
	{
		final switch (kind)
		{
		case KnownSystemMessageKind.taskPrompt:
			return "Task prompt";
		case KnownSystemMessageKind.sessionStart:
			return "Session start";
		case KnownSystemMessageKind.followUpFromParent:
			return "Follow-up question from parent task";
		case KnownSystemMessageKind.subTaskWaitingForAnswer:
			return "Sub-task waiting for answer";
		case KnownSystemMessageKind.missingRequiredOutputs:
			return "Missing required outputs";
		case KnownSystemMessageKind.handoff:
			return "Handoff";
		case KnownSystemMessageKind.subTaskResults:
			return "Sub-task results";
		case KnownSystemMessageKind.restartNudge:
			return "Restart nudge";
		case KnownSystemMessageKind.postCompactionTaskModeReminder:
			return "Post-compaction task mode reminder";
		case KnownSystemMessageKind.modeSwitch:
			return "Mode switch";
		}
	}

	private static string taskPromptSubject(string taskType)
	{
		return systemMessageSubject(KnownSystemMessageKind.taskPrompt) ~ ": " ~ taskType;
	}

	private static string sessionStartSubject(string entryPointOrTaskType)
	{
		return systemMessageSubject(KnownSystemMessageKind.sessionStart) ~ ": " ~ entryPointOrTaskType;
	}

	private static string followUpFromParentSubject(int qid)
	{
		import std.conv : to;
		return systemMessageSubject(KnownSystemMessageKind.followUpFromParent)
			~ " (qid=" ~ to!string(qid) ~ ")";
	}

	private static string subTaskWaitingForAnswerSubject(string title, int tid, int qid)
	{
		import std.conv : to;
		return "Sub-task \"" ~ title ~ "\" (tid=" ~ to!string(tid)
			~ ") is waiting for your answer (qid=" ~ to!string(qid) ~ ")";
	}

	/// Find the first child of tid that has an unanswered Ask question.
	/// Returns true if found; sets childTid, question, and qid via out params.
	private bool findPendingChildQuestion(int tid, out int childTid, out string question, out int qid)
	{
		auto batch = tid in activeBatches;
		if (batch is null)
			return false;
		foreach (cTid; batch.childTids)
		{
			if (cTid in tasks && tasks[cTid].pendingAskPromise !is null)
			{
				childTid = cTid;
				question = tasks[cTid].pendingAskQuestion;
				qid = tasks[cTid].pendingAskQid;
				return true;
			}
		}
		return false;
	}

	/// Send a "Sub-task waiting for answer" reminder for the first pending child
	/// question owned by tid. Does nothing if no such question exists.
	private void sendPendingChildAnswerReminder(int tid)
	{
		import std.conv : to;

		int childTid;
		string question;
		int qid;
		if (!findPendingChildQuestion(tid, childTid, question, qid))
			return;
		auto childTd = &tasks[childTid];
		auto reminderSubject = subTaskWaitingForAnswerSubject(
			childTd.title, childTid, qid);
		auto reminder = wrapKnownSystemMessage(
			KnownSystemMessageKind.subTaskWaitingForAnswer,
			"Question: " ~ question ~ "\n\n"
				~ "Use Answer(" ~ to!string(qid)
				~ ", \"your answer\") to respond. You must answer before you can complete your turn.",
			reminderSubject);
		auto reminderBlocks = [ContentBlock("text", reminder)];
		auto askReminderMeta = buildKnownSystemMessageMeta(
			KnownSystemMessageKind.subTaskWaitingForAnswer,
			reminderSubject,
			["question": question], "question", true);
		sendTaskMessage(tid, reminderBlocks, null, askReminderMeta);
	}

	private static string modeSwitchSubject(string taskType)
	{
		return systemMessageSubject(KnownSystemMessageKind.modeSwitch) ~ ": " ~ taskType;
	}

	private static string handoffSubject(string taskType)
	{
		return systemMessageSubject(KnownSystemMessageKind.handoff) ~ ": " ~ taskType;
	}

	private string systemMessagePrefix(KnownSystemMessageKind kind)
	{
		return "[" ~ config.system_keyword ~ ": " ~ systemMessageSubject(kind) ~ "]";
	}

	private string wrapKnownSystemMessage(KnownSystemMessageKind kind, string body = null,
		string subject = null)
	{
		auto resolvedSubject = subject.length > 0 ? subject : systemMessageSubject(kind);
		return wrapSystemMessage(resolvedSubject, body);
	}

	private string buildKnownSystemMessageMeta(KnownSystemMessageKind kind, string subject = null,
		string[string] vars = null, string bodyVar = null, bool bodyMarkdown = false)
	{
		auto resolvedSubject = subject.length > 0 ? subject : systemMessageSubject(kind);
		KnownSystemMessageMatch match;
		auto label = tryKnownSystemMessageMatch(resolvedSubject, match)
			? match.label
			: resolvedSubject;
		return buildCydoMeta(label, vars, bodyVar, bodyMarkdown);
	}

	private static bool tryParseStrictPositiveInt(string text, out int value)
	{
		import std.conv : to;

		if (text.length == 0)
			return false;
		foreach (ch; text)
			if (ch < '0' || ch > '9')
				return false;
		try
			value = to!int(text);
		catch (Exception)
			return false;
		return true;
	}

	private static bool tryKnownSystemMessageMatch(string subject, out KnownSystemMessageMatch match)
	{
		import std.algorithm : startsWith, endsWith;
		import std.algorithm.searching : countUntil;

		match = KnownSystemMessageMatch.init;

		enum taskPromptPrefix = "Task prompt: ";
		if (subject.startsWith(taskPromptPrefix) && subject.length > taskPromptPrefix.length)
		{
			match.kind = KnownSystemMessageKind.taskPrompt;
			match.label = subject;
			return true;
		}

		enum sessionStartPrefix = "Session start: ";
		if (subject.startsWith(sessionStartPrefix) && subject.length > sessionStartPrefix.length)
		{
			match.kind = KnownSystemMessageKind.sessionStart;
			match.label = subject;
			return true;
		}

		enum modeSwitchPrefix = "Mode switch: ";
		if (subject.startsWith(modeSwitchPrefix) && subject.length > modeSwitchPrefix.length)
		{
			match.kind = KnownSystemMessageKind.modeSwitch;
			match.label = subject;
			return true;
		}

		enum handoffPrefix = "Handoff: ";
		if (subject.startsWith(handoffPrefix) && subject.length > handoffPrefix.length)
		{
			match.kind = KnownSystemMessageKind.handoff;
			match.label = subject;
			return true;
		}

		enum followUpPrefix = "Follow-up question from parent task (qid=";
		enum followUpSuffix = ")";
		if (subject.startsWith(followUpPrefix) && subject.endsWith(followUpSuffix))
		{
			auto qidText = subject[followUpPrefix.length .. $ - followUpSuffix.length];
			int qid;
			if (!tryParseStrictPositiveInt(qidText, qid))
				return false;
			match.kind = KnownSystemMessageKind.followUpFromParent;
			match.label = "Follow-up from parent";
			match.qid = Nullable!int(qid);
			return true;
		}

		enum waitingPrefix = "Sub-task \"";
		enum waitingTitleSuffix = "\" (tid=";
		enum waitingMid = ") is waiting for your answer (qid=";
		enum waitingSuffix = ")";
		if (subject.startsWith(waitingPrefix) && subject.endsWith(waitingSuffix))
		{
			auto tail = subject[waitingPrefix.length .. $];
			auto titleEnd = tail.countUntil(waitingTitleSuffix);
			if (titleEnd < 0)
				return false;
			auto titleLen = cast(size_t) titleEnd;
			auto title = tail[0 .. titleLen];
			auto afterTitle = tail[titleLen + waitingTitleSuffix.length .. $];

			auto midPos = afterTitle.countUntil(waitingMid);
			if (midPos < 0)
				return false;
			auto tidText = afterTitle[0 .. cast(size_t) midPos];
			auto qidText = afterTitle[cast(size_t) midPos + waitingMid.length .. $ - waitingSuffix.length];
			int tid, qid;
			if (!tryParseStrictPositiveInt(tidText, tid) || !tryParseStrictPositiveInt(qidText, qid))
				return false;
			match.kind = KnownSystemMessageKind.subTaskWaitingForAnswer;
			match.label = "Sub-task waiting for answer";
			match.tid = Nullable!int(tid);
			match.qid = Nullable!int(qid);
			match.title = Nullable!string(title);
			return true;
		}

		if (subject == systemMessageSubject(KnownSystemMessageKind.missingRequiredOutputs))
		{
			match.kind = KnownSystemMessageKind.missingRequiredOutputs;
			match.label = subject;
			return true;
		}
		if (subject == systemMessageSubject(KnownSystemMessageKind.subTaskResults))
		{
			match.kind = KnownSystemMessageKind.subTaskResults;
			match.label = subject;
			return true;
		}
		if (subject == systemMessageSubject(KnownSystemMessageKind.restartNudge))
		{
			match.kind = KnownSystemMessageKind.restartNudge;
			match.label = subject;
			return true;
		}
		if (subject == systemMessageSubject(KnownSystemMessageKind.postCompactionTaskModeReminder))
		{
			match.kind = KnownSystemMessageKind.postCompactionTaskModeReminder;
			match.label = subject;
			return true;
		}
		return false;
	}

	private bool tryExtractSystemMessageSubject(string text, out string subject)
	{
		import std.algorithm : startsWith;
		import std.algorithm.searching : countUntil;

		auto prefix = "[" ~ config.system_keyword ~ ": ";
		if (!text.startsWith(prefix))
			return false;
		auto remaining = text[prefix.length .. $];
		auto closeIndex = remaining.countUntil("]");
		if (closeIndex <= 0)
			return false;
		subject = remaining[0 .. cast(size_t) closeIndex];
		return true;
	}

	private bool tryExtractWrappedSystemBody(string text, string subject, out string body)
	{
		import std.algorithm : startsWith, endsWith;

		auto prefix = "[" ~ config.system_keyword ~ ": " ~ subject ~ "]\n\n";
		auto suffix = "\n\n[/" ~ config.system_keyword ~ "]";
		if (!text.startsWith(prefix) || !text.endsWith(suffix) || text.length <= prefix.length + suffix.length)
			return false;
		body = text[prefix.length .. $ - suffix.length];
		return body.length > 0;
	}

	private static bool tryExtractTaskDescriptionFromWrappedBody(string body, out string taskDescription)
	{
		import std.string : strip, lastIndexOf;

		enum promptSeparator = "\n\n--------------------------------------------------------------------------------\n\n";
		auto sepPos = body.lastIndexOf(promptSeparator);
		if (sepPos < 0)
			return false;

		auto start = cast(size_t) sepPos + promptSeparator.length;
		auto candidate = body[start .. $].strip;
		if (candidate.length == 0)
			return false;
		taskDescription = candidate;
		return true;
	}

	private string cydoMetaForKnownSystemSubject(string subject, string text)
	{
		KnownSystemMessageMatch match;
		if (!tryKnownSystemMessageMatch(subject, match))
			return null;

		switch (match.kind)
		{
		case KnownSystemMessageKind.taskPrompt:
		case KnownSystemMessageKind.sessionStart:
			string wrappedBody;
			string taskDescription;
			if (tryExtractWrappedSystemBody(text, subject, wrappedBody)
				&& tryExtractTaskDescriptionFromWrappedBody(wrappedBody, taskDescription))
			{
				return buildCydoMeta(match.label, ["task_description": taskDescription], "task_description",
					match.kind == KnownSystemMessageKind.taskPrompt);
			}
			break;
		default:
			break;
		}

		return buildCydoMeta(match.label);
	}

	private string normalizeKnownSystemMessageMeta(string translated)
	{
		import std.algorithm : canFind;

		if (translated.length == 0
			|| translated.canFind(`"meta":`)
			|| !translated.canFind(`"type":"item/started"`)
			|| !translated.canFind(`"item_type":"user_message"`))
			return translated;

		string subject;
		auto text = extractMessageText(translated);
		if (!tryExtractSystemMessageSubject(text, subject))
			return translated;

		auto meta = cydoMetaForKnownSystemSubject(subject, text);
		if (meta.length == 0)
			return translated;
		return translated[0 .. $ - 1] ~ `,"meta":` ~ meta ~ `}`;
	}

	private string buildPostCompactionReminder(int tid)
	{
		if (tid !in tasks)
			return null;
		auto td = &tasks[tid];
		TaskTypeDef* typeDef = null;
		if (auto cache = td.projectPath in taskTypesByProject)
			typeDef = cache.types.byName(td.taskType);
		if (typeDef is null)
			typeDef = getTaskTypesForProject(td.projectPath).byName(td.taskType);
		auto systemPrompt = taskSystemPromptForMessage(tid, typeDef);
		if (systemPrompt.length == 0)
			return null;
		auto body = "[CYDO TASK MODE REMINDER]\n\n"
			~ "This is CyDo task metadata, not project or user content.\n\n"
			~ "Active task mode: " ~ td.taskType
			~ "\n\n[TASK DESCRIPTION]\n" ~ systemPrompt
			~ "\n[END TASK DESCRIPTION]\n\n"
			~ "Use this as the active CyDo task mode metadata for interpreting what kind of work to do next.\n\n";
		return wrapKnownSystemMessage(KnownSystemMessageKind.postCompactionTaskModeReminder, body);
	}

	private static bool isCompactionReminderTriggerEvent(string translated)
	{
		import std.algorithm : canFind;

		if (translated.length == 0)
			return false;
		if (translated.canFind(`"type":"session/compacted"`))
			return true;
		if (!translated.canFind(`"type":"session/status"`))
			return false;

		@JSONPartial static struct SessionStatusProbe
		{
			string type;
			@JSONOptional string status;
		}
		try
		{
			auto probe = jsonParse!SessionStatusProbe(translated);
			if (probe.type == "session/status" && probe.status.length > 0
				&& probe.status.canFind("Compacting context"))
				return true;
		}
		catch (Exception)
		{
			// Fall back to a substring match if the payload shape changes.
		}
		return translated.canFind("Compacting context");
	}

	private static bool isCompactionReminderTriggerRaw(string raw)
	{
		import std.algorithm : canFind;

		return raw.length > 0
			&& raw.canFind(`"method":"item/started"`)
			&& raw.canFind(`"type":"contextCompaction"`);
	}

	private bool isCompactionReminderEchoEvent(string translated)
	{
		import std.algorithm : canFind, startsWith;

		if (!translated.canFind(`"type":"item/started"`)
			|| !translated.canFind(`"item_type":"user_message"`))
			return false;
		auto text = extractMessageText(translated);
		return text.startsWith(systemMessagePrefix(KnownSystemMessageKind.postCompactionTaskModeReminder));
	}

	private string toJsonWithSyntheticUserMeta(string text, ItemStartedEvent ev)
	{
		import std.algorithm : startsWith;

		auto translated = toJson(ev);
		return text.startsWith("[" ~ config.system_keyword ~ ":")
			? normalizeKnownSystemMessageMeta(translated)
			: translated;
	}

	private static bool isCompactionReminderSteerFailureEvent(string translated)
	{
		import std.algorithm : canFind;

		if (translated.length == 0 || !translated.canFind(`"type":"agent/error"`))
			return false;

		@JSONPartial static struct AgentErrorProbe
		{
			string type;
			@JSONOptional string message;
		}
		try
		{
			auto probe = jsonParse!AgentErrorProbe(translated);
			if (probe.type == "agent/error" && probe.message.length > 0
				&& probe.message.canFind("no active turn to steer"))
				return true;
		}
		catch (Exception)
		{
			// Fall back to substring matching if payload shape changes.
		}
		return translated.canFind("no active turn to steer");
	}

	/// Send post-compaction reminder as an in-flight steering message when possible.
	/// Returns true if reminder was queued to the agent.
	private bool maybeSendCompactionReminderSteering(int tid)
	{
		if (tid !in tasks)
			return false;

		auto td = &tasks[tid];
		if (td.compactionReminderInFlight)
			return false;
		if (td.session is null || !td.session.alive)
			return false;
		if (td.processQueue.goalState != ProcessState.Alive)
			return false;

		auto reminder = buildPostCompactionReminder(tid);
		if (reminder.length == 0)
			return false;
		td.compactionReminderInFlight = true;

		import std.algorithm : filter;
		import std.array : array;
		auto reminderBlocks = [ContentBlock("text", reminder)];
		auto reminderMeta = buildKnownSystemMessageMeta(
			KnownSystemMessageKind.postCompactionTaskModeReminder);
		sendPreparedTaskMessage(tid, reminderBlocks, null, reminderMeta, false);
		return true;
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

		auto ep = getEntryPointsForProject(td.projectPath).byName(td.entryPoint);
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
			if (taskAgent.supportsDeveloperPrompt)
				sessionConfig.appendSystemPrompt = loadSystemPrompt(*typeDef,
					promptSearchPath(td.projectPath), td.outputPath);
		}
		auto taskTypes = getTaskTypesForProject(td.projectPath);
		sessionConfig.creatableTaskTypes = formatCreatableTaskTypes(taskTypes, td.taskType);
		sessionConfig.switchModes = formatSwitchModes(taskTypes, td.taskType);
		sessionConfig.handoffs = formatHandoffs(taskTypes, td.taskType);
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
		auto reachesWorktree = reachesWorktreeFor(td.projectPath);
		if (workDir.length > 0 && td.taskType in reachesWorktree
			&& reachesWorktree[td.taskType])
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
		if (taskTypes.isInteractive(getEntryPointsForProject(td.projectPath), td.taskType))
			sessionConfig.includeTools ~= "AskUserQuestion";
		if (sessionConfig.creatableTaskTypes.length > 0 || td.parentTid > 0 || tid in activeBatches)
		{
			sessionConfig.includeTools ~= "Ask";
			sessionConfig.includeTools ~= "Answer";
		}
		if (typeDef !is null && typeDef.allow_native_subagents)
			sessionConfig.allowNativeSubagents = true;

		sessionConfig.permissionPolicy = findWorkspacePermissionPolicy(td.workspace);

		return TaskSessionLaunch(td.launch, sessionConfig);
	}

	private void spawnTaskSession(int tid)
	{
		auto td = &tasks[tid];
		assert(td.taskType.length > 0, "Task must have a task_type before spawning session");
		td.wasKilledByUser = false;
		td.hadTurnResult = false;
		td.stdinClosed = false;
		td.clearLastSessionStatus();
		td.compactionReminderInFlight = false;

		// Look up the correct agent for this task's agent type
		auto taskAgent = agentForTask(tid);

		auto typeDef = getTaskTypesForProject(td.projectPath).byName(td.taskType);
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

		td.session.onOutput = (TranslatedEvent ev) {
			broadcastTask(tid, ev);

			if (!td.isProcessing && td.hadTurnResult)
			{
				td.isProcessing = true;
				broadcastTaskUpdate(tid);
			}

			if (taskAgent.isTurnResult(ev.translated))
			{
				// Turn completed — no longer processing, but still alive.
				td.isProcessing = false;
				td.hadTurnResult = true;
				td.compactionReminderInFlight = false;

				// Re-try JSONL watch if not yet established (Codex may
				// not have the file at session-start time).
				// Guard against calling startJsonlWatch after shutdown() has
				// already removed all watches — a new watch would re-open the
				// inotify fd and create a non-daemon FileConnection, keeping
				// the event loop alive indefinitely after SIGTERM.
				if (!shuttingDown)
					jsonlTracker.startJsonlWatch(tid);

				// Broadcast forkable UUIDs now that JSONL should exist.
				if (!shuttingDown)
					jsonlTracker.broadcastForkableUuidsFromFile(tid);

				// Capture the canonical result text for sub-task output.
				td.resultText = taskAgent.extractResultText(ev.translated);

				// For sub-tasks and continuations: close stdin so the process exits cleanly.
				// Interactive tasks stay open for user input — flag for attention.
				// Also check taskDeps for post-restart sub-tasks (no promise in pendingSubTasks).
				// Also close stdin for tasks with on_yield (they auto-continue on exit).
				auto onYieldTypeDef = getTaskTypesForProject(td.projectPath).byName(td.taskType);
				bool hasOnYield = onYieldTypeDef !is null && onYieldTypeDef.on_yield.task_type.length > 0;
				if (tid in pendingSubTasks || td.pendingContinuation !is null
					|| tid in taskDeps || hasOnYield || td.onIdleCallbacks.length > 0)
				{
					// Drain idle callbacks if any — they take priority over normal completion.
					if (td.onIdleCallbacks.length > 0)
					{
						auto cbs = td.onIdleCallbacks.dup;
						td.onIdleCallbacks = null;
						foreach (cb; cbs)
							cb();
						// If the callback set the task to "active" (e.g., sent a question),
						// the task has new work — don't close stdin, don't complete.
						if (td.status == "active")
						{
							broadcastTaskUpdate(tid);
							return;
						}
						// Otherwise fall through — e.g., deferred answer was delivered,
						// task is "completed", proceed with normal stdin close.
					}
					else if (tid in pendingSubTasks)
					{
						if (td.pendingContinuation is null && !hasOnYield)
						{
							auto missingOutputs = checkDeclaredOutputs(tid);
							if (missingOutputs is null)
								finalizeCompletedSubTask(tid, true);
							else
								tracef("onOutput: tid=%d deferring sub-task finalization; %s",
									tid, missingOutputs);
						}
					}

					// If a pendingContinuation (SwitchMode/Handoff) was accepted, this is a
					// backend-requested terminal yield — close stdin and let onExit handle it.
					// Otherwise, enforce unanswered child questions: send the reminder instead
					// of closing stdin so the agent answers before completing its turn.
					int _pcChildTid;
					string _pcQuestion;
					int _pcQid;
					bool hasPendingChildQuestion =
						td.pendingContinuation is null &&
						findPendingChildQuestion(tid, _pcChildTid, _pcQuestion, _pcQid);

					if (hasPendingChildQuestion)
					{
						sendPendingChildAnswerReminder(tid);
					}
					else
					{
						td.processQueue.setGoal(ProcessState.Dead).ignoreResult();
						td.session.closeStdin();
						td.session.killAfterTimeout(5.seconds);
					}
				}
				else
				{
					if (td.onIdleCallbacks.length > 0)
					{
						auto cbs = td.onIdleCallbacks.dup;
						td.onIdleCallbacks = null;
						foreach (cb; cbs)
							cb();
						// Don't set "alive" — callbacks took over.
					}
					else
					{
						td.status = "alive";
						persistence.setStatus(tid, "alive");
						td.needsAttention = true;
						persistence.setNeedsAttention(tid, true);
						td.notificationBody = td.resultText.length > 0 ? truncateTitle(td.resultText, 200) : extractLastAssistantText(tid);
						touchTask(tid);
						persistence.setLastActive(tid, tasks[tid].lastActive);
						try
							generateSuggestions(tid);
						catch (Exception e)
							warningf("Error generating suggestions: %s", e.msg);
					}
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
			broadcastTask(tid, TranslatedEvent(toJson(ev), null));
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
			// Compute hasOnYield from task type alone — independent of exit code,
			// since killAfterTimeout may produce non-zero exits for valid continuations.
			auto onYieldDef = (tasks[tid].pendingContinuation is null)
				? getTaskTypesForProject(tasks[tid].projectPath).byName(tasks[tid].taskType) : null;
			bool hasOnYield = onYieldDef !is null && onYieldDef.on_yield.task_type.length > 0;
			// Treat intentional kills as clean when there's a pending continuation
			// or on_yield — we know we killed the process via killAfterTimeout.
			// Explicit user kills are never clean regardless.
			auto cleanExit = (exitCode == 0 || tasks[tid].pendingContinuation !is null || hasOnYield)
				&& !tasks[tid].wasKilledByUser;
			if (cleanExit && (tasks[tid].pendingContinuation !is null || hasOnYield))
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
			broadcastTask(tid, TranslatedEvent(toJson(ev), null));
			if (tid !in tasks)
				return;
			tasks[tid].isProcessing = false;
			tasks[tid].stdinClosed = false;
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
				persistence.setNeedsAttention(tid, false);
				tasks[tid].hasPendingQuestion = false;
				tasks[tid].notificationBody = "";
			}

			// Fulfill pending PermissionPrompt promise with deny if session dies
			if (auto permPending = tid in pendingPermissionPrompts)
			{
				permPending.fulfill(McpResult(makePermissionDenyJson("Task exited"), false));
				pendingPermissionPrompts.remove(tid);
				pendingPermissionInputs.remove(tid);
				tasks[tid].pendingPermissionToolUseId = null;
				tasks[tid].pendingPermissionToolName = null;
				tasks[tid].pendingPermissionInput = JSONFragment.init;
			}

			// Drain idle callbacks on exit — task won't yield again.
			if (tasks[tid].onIdleCallbacks.length > 0)
			{
				auto cbs = tasks[tid].onIdleCallbacks.dup;
				tasks[tid].onIdleCallbacks = null;
				foreach (cb; cbs)
					cb();
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
				questionToBatch.remove(qid);
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
			tasks[tid].resetHistory();
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
				if (tasks[tid].relationType != "fork")
				{
					auto ancestor = findAliveAncestor(tid);
					if (ancestor >= 0)
						broadcastFocusHint(tid, ancestor);
				}
				broadcastTaskUpdate(tid);
				return;
			}

			// Continuation: transition to successor instead of completing
			if (cleanExit && tasks[tid].pendingContinuation !is null)
			{
				spawnContinuation(tid);
				return;
			}

			// on_yield: auto-continuation on clean exit without explicit SwitchMode/Handoff
			if (hasOnYield && cleanExit)
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
						auto msg = wrapKnownSystemMessage(KnownSystemMessageKind.missingRequiredOutputs,
							"Your task type declares outputs that were not produced:\n"
								~ enfMissing ~ "\n\n"
								~ "Please produce the missing output(s) before finishing. "
								~ "Write your report to your output file if you haven't already.");
						auto outputsMeta = buildKnownSystemMessageMeta(
							KnownSystemMessageKind.missingRequiredOutputs);
						sendTaskMessage(tid, [ContentBlock("text", msg)], null, outputsMeta);
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

			bool deliveredPendingSubTask = false;
			if (tasks[tid].status == "completed")
			{
				// Keep completion finalization behavior aligned with onOutput.
				deliveredPendingSubTask = finalizeCompletedSubTask(tid);
			}
			else if (auto pending = tid in pendingSubTasks)
			{
				auto taskResult = buildTaskResult(tid);
				auto resultJson = toJson(taskResult);
				pending.fulfill(McpResult.structured(resultJson, true));
				pendingSubTasks.remove(tid);
				deliveredPendingSubTask = true;
				// Deps left intact — cleaned by onToolCallDelivered() on success,
				// or used by deliverBatchResults() as fallback if MCP delivery fails.
			}

			if (!deliveredPendingSubTask)
			{
				if (auto parentTidPtr = tid in taskDeps)
				{
					if (tid in liveDeliveredSubTasks)
					{
						tracef("onExit Branch B: child tid=%d already delivered to live batch, skipping fallback",
							tid);
					}
					else
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
				}
			}

			// Notify frontends to re-request history (in-memory history
			// already contains both JSONL and stdout-only messages like result).
			emitTaskReload(tid);
			// No attention on exit — the session is over and there's
			// nothing for the user to act on.  Turn-complete attention
			// (in onOutput) is sufficient for interactive tasks.
			if (tasks[tid].relationType != "fork")
			{
				auto ancestor = findAliveAncestor(tid);
				if (ancestor >= 0)
					broadcastFocusHint(tid, ancestor);
			}
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
			if (shuttingDown)
				return reject!ProcessState(new Exception("Shutting down"));
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
	private void executeContinuation(int tid, ContinuationDef contDef, string handoffPrompt,
		string switchModeContinuation = null)
	{
		import ae.utils.json : toJson;

		auto td = &tasks[tid];

		auto newTypeDef = getTaskTypesForProject(td.projectPath).byName(contDef.task_type);
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
			emitTaskReload(tid, "continuation");

			td.status = "active";
			persistence.setStatus(tid, "active");

			// Send the continuation's prompt template as first message to successor.
			auto renderedContinuationPrompt = renderContinuationPrompt(contDef,
				"Continue from where you left off.", promptSearchPath(td.projectPath),
				["result_text": resultText, "output_dir": td.taskDir]);
			if (switchModeContinuation.length > 0)
				renderedContinuationPrompt = "`SwitchMode` to `" ~ switchModeContinuation
					~ "` successful.\n\n" ~ renderedContinuationPrompt;
			renderedContinuationPrompt = prependTaskSystemPrompt(
				renderedContinuationPrompt, taskSystemPromptForMessage(tid, newTypeDef));
			auto modeSwitchMsgSubject = modeSwitchSubject(contDef.task_type);
			auto contMeta = buildKnownSystemMessageMeta(KnownSystemMessageKind.modeSwitch,
				modeSwitchMsgSubject);
			td.processQueue.setGoal(ProcessState.Alive).then(() {
				sendTaskMessage(tid,
					[ContentBlock("text", wrapKnownSystemMessage(
						KnownSystemMessageKind.modeSwitch, renderedContinuationPrompt, modeSwitchMsgSubject))],
					null, contMeta);
				// If a child question is still pending (the agent switched modes before
				// answering), send the reminder now so the resumed mode can answer it.
				sendPendingChildAnswerReminder(tid);
			}).ignoreResult();
		}
		else
		{
			// Complete the current task normally (preserving its history),
			// then create a new child task for the successor.
			td.status = "completed";
			persistence.setStatus(tid, "completed");

			// Notify frontends to re-request history
			emitTaskReload(tid, "continuation");

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
			broadcastFocusHint(tid, childTid);

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
				liveDeliveredSubTasks.remove(tid);
				taskDeps[childTid] = td.parentTid;
			}

			// Set up worktree from edge config
			setupWorktreeForEdge(childTid, tid, contDef.worktree);

			// Spawn the successor agent
			auto renderedSuccessorPrompt = renderPrompt(*newTypeDef, successorPrompt,
				promptSearchPath(childTd.projectPath), childTd.outputPath, contDef.prompt_template,
				["result_text": resultText]);
			renderedSuccessorPrompt = prependTaskSystemPrompt(renderedSuccessorPrompt,
				taskSystemPromptForMessage(childTid, newTypeDef));
			auto handoffMsgSubject = handoffSubject(contDef.task_type);
			auto handoffMeta = buildKnownSystemMessageMeta(KnownSystemMessageKind.handoff,
				handoffMsgSubject, ["task_description": successorPrompt], "task_description", false);
			tasks[childTid].processQueue.setGoal(ProcessState.Alive).then(() {
				sendTaskMessage(childTid, [ContentBlock("text", wrapKnownSystemMessage(
					KnownSystemMessageKind.handoff, renderedSuccessorPrompt, handoffMsgSubject))], null, handoffMeta);
			}).ignoreResult();

			broadcastTaskUpdate(tid);
		}
	}

	/// Transition a task to its successor via continuation.
	/// Called from onExit when pendingContinuation is set.
	private void spawnContinuation(int tid)
	{
		auto td = &tasks[tid];
		auto typeDef = getTaskTypesForProject(td.projectPath).byName(td.taskType);
		auto contKey = td.pendingContinuation.key;
		auto hPrompt = td.pendingContinuation.handoffPrompt;
		td.pendingContinuation = null;

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

		auto switchModeKey = contDefP.keep_context ? contKey : null;
		executeContinuation(tid, *contDefP, hPrompt, switchModeKey);
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

	private string findWorkspacePermissionPolicy(string workspaceName)
	{
		foreach (ref ws; config.workspaces)
			if (ws.name == workspaceName && ws.permission_policy.length > 0)
				return ws.permission_policy;
		return "";
	}

	private static string makePermissionAllowJson(string inputJson)
	{
		return toJson(PermissionAllow("allow", JSONFragment(inputJson)));
	}

	private static string makePermissionDenyJson(string message)
	{
		return toJson(PermissionDeny("deny", message));
	}

	/// Convert a JSON string to a UniNode for use as a Djinja template context variable.
	private static UniNode jsonToUniNode(string json)
	{
		import std.json : parseJSON, JSONValue, JSONType;

		UniNode convert(JSONValue v)
		{
			final switch (v.type)
			{
			case JSONType.null_:   return UniNode(null);
			case JSONType.string:  return UniNode(v.str);
			case JSONType.integer: return UniNode(v.integer);
			case JSONType.uinteger: return UniNode(v.uinteger);
			case JSONType.float_:  return UniNode(v.floating);
			case JSONType.true_:   return UniNode(true);
			case JSONType.false_:  return UniNode(false);
			case JSONType.array:
				UniNode[] seq;
				foreach (ref el; v.array)
					seq ~= convert(el);
				return UniNode(seq);
			case JSONType.object:
				UniNode[string] map;
				foreach (key, ref val; v.objectNoRef)
					map[key] = convert(val);
				return UniNode(map);
			}
		}

		try
			return convert(parseJSON(json));
		catch (Exception)
			return UniNode(null);
	}

	/// Evaluate a permission policy string. Returns "allow", "deny", or "ask".
	private static string evaluatePermissionPolicy(string policy, string toolName, string inputJson)
	{
		if (policy == "allow" || policy == "deny" || policy == "ask")
			return policy;

		// Empty policy defaults to allow
		if (policy.length == 0)
			return "allow";

		// Evaluate as Djinja template expression
		try
		{
			import djinja.djinja : loadData;
			import djinja.render : Render;
			import std.string : strip;

			auto renderer = new Render(loadData(policy));

			UniNode[string] ctx;
			ctx["tool_name"] = UniNode(toolName);
			ctx["input"] = jsonToUniNode(inputJson);

			string result = renderer.render(UniNode(ctx)).strip();

			if (result == "allow" || result == "deny" || result == "ask")
				return result;

			warningf("Permission policy expression returned invalid value %(%s%), defaulting to deny", [result]);
			return "deny";
		}
		catch (Exception e)
		{
			warningf("Permission policy expression evaluation failed: %s", e.msg);
			return "deny";
		}
	}

	private SandboxConfig findAgentTypeSandbox(string agentType)
	{
		if (config.agents !is null)
			if (auto ac = agentType in config.agents)
				return ac.sandbox;
		return SandboxConfig.init;
	}

	/// Get the HEAD SHA of the parent task's working directory.
	/// Returns empty string if the parent path cannot be determined or git fails.
	private string getParentHead(ref TaskData td)
	{
		import std.process : execute;
		import std.string : strip;

		string parentPath;
		if (td.parentTid > 0 && td.parentTid in tasks)
		{
			auto parentTd = &tasks[td.parentTid];
			if (parentTd.hasWorktree)
				parentPath = parentTd.worktreePath;
			else
				parentPath = parentTd.projectPath;
		}
		if (parentPath.length == 0)
			parentPath = td.projectPath;
		if (parentPath.length == 0)
			return "";

		auto result = execute(["git", "-C", parentPath, "rev-parse", "HEAD"]);
		if (result.status != 0)
		{
			warningf("getParentHead: git rev-parse HEAD failed in %s: %s", parentPath, result.output);
			return "";
		}
		return result.output.strip;
	}

	/// Check whether a completing task has produced all declared outputs.
	/// Returns null if all outputs are present, or a message describing what's missing.
	private string checkDeclaredOutputs(int tid)
	{
		import std.algorithm : min;
		import std.file : exists;
		import std.process : execute;
		import std.string : strip;

		auto td = &tasks[tid];
		auto typeDef = getTaskTypesForProject(td.projectPath).byName(td.taskType);
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
				if (!td.hasWorktree)
				{
					missing ~= "worktree (no worktree)";
					break;
				}
				{
					auto wtPath = td.worktreePath;
					auto parentHead = getParentHead(*td);
					bool hasCommits;
					if (parentHead.length > 0)
					{
						auto logResult = execute(["git", "-C", wtPath, "log",
							"--oneline", parentHead ~ "..HEAD"]);
						hasCommits = logResult.status == 0 && logResult.output.strip.length > 0;
					}
					auto statusResult = execute(["git", "-C", wtPath, "status", "--porcelain"]);
					bool hasDirtyChanges = statusResult.status != 0
						|| statusResult.output.strip.length > 0;
					if (!hasCommits && !hasDirtyChanges)
						missing ~= "worktree (no changes — commit or leave uncommitted changes)";
				}
				break;

			case OutputType.commit:
				if (!td.hasWorktree)
				{
					missing ~= "commit (no worktree)";
					break;
				}
				{
					auto wtPath = td.worktreePath;
					auto statusResult = execute(["git", "-C", wtPath, "status", "--porcelain"]);
					if (statusResult.status == 0 && statusResult.output.strip.length > 0)
					{
						missing ~= "commit (worktree has uncommitted changes"
							~ " — commit all changes before finishing)\n"
							~ "git status:\n" ~ statusResult.output.strip;
						break;
					}
					auto parentHead = getParentHead(*td);
					if (parentHead.length == 0)
					{
						missing ~= "commit (could not determine parent HEAD)";
						break;
					}
					auto logResult = execute(["git", "-C", wtPath, "log",
						"--oneline", parentHead ~ "..HEAD"]);
					if (logResult.status != 0 || logResult.output.strip.length == 0)
						missing ~= "commit (no commits since worktree base "
							~ parentHead[0 .. min(8, $)]
							~ " — make at least one commit)";
				}
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
		import std.algorithm : canFind;
		import std.array : join;
		import std.conv : to;
		import std.file : exists;
		import std.process : execute;
		import std.range : retro;
		import std.string : splitLines, strip;
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

		// For commit output types, extract commit SHAs from the worktree.
		auto typeDef = getTaskTypesForProject(td.projectPath).byName(td.taskType);
		if (typeDef !is null && typeDef.output_type.canFind(OutputType.commit) && td.hasWorktree)
		{
			auto parentHead = getParentHead(*td);
			if (parentHead.length > 0)
			{
				auto logResult = execute(["git", "-C", td.worktreePath,
					"log", "--format=%H", parentHead ~ "..HEAD"]);
				if (logResult.status == 0 && logResult.output.strip.length > 0)
					result.commits = logResult.output.strip.splitLines;
			}
			if (result.commits.length > 0)
				note = "Cherry-pick commits from the worktree: git cherry-pick "
					~ result.commits.retro.join(" ") ~ talkNote;
			result.note = note.length > 0 ? note : td.resultNote;
		}

		return result;
	}

	/// Finalize a successful sub-task completion when a pending Task() call exists.
	/// Returns true when the pending sub-task promise was fulfilled.
	private bool finalizeCompletedSubTask(int childTid, bool eagerDepCleanup = false)
	{
		import ae.utils.json : toJson;
		if (childTid !in tasks)
			return false;

		auto td = &tasks[childTid];
		td.status = "completed";
		persistence.setStatus(childTid, "completed");
		persistence.setResultText(childTid, td.resultText);

		auto pending = childTid in pendingSubTasks;
		if (pending is null)
			return false;

		auto taskResult = buildTaskResult(childTid);
		auto resultJson = toJson(taskResult);
		pending.fulfill(McpResult.structured(resultJson));
		pendingSubTasks.remove(childTid);

		// Early result delivery can race onExit for agents with synchronous stdin
		// close. Record this child so onExit does not trigger duplicate fallback.
		if (eagerDepCleanup)
			liveDeliveredSubTasks[childTid] = true;

		return true;
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
		auto msg = wrapKnownSystemMessage(KnownSystemMessageKind.subTaskResults,
			"The following sub-task(s) completed while your session was interrupted. "
				~ "Their results are provided below exactly as they would have been "
				~ "returned by the Task tool.\n\n"
				~ "<task_results>\n" ~ resultsArray ~ "\n</task_results>\n\n"
				~ "Continue from where you left off. Process these results as if they "
				~ "were returned normally by the Task tool.");
		auto resultsMeta = buildKnownSystemMessageMeta(KnownSystemMessageKind.subTaskResults);
		sendTaskMessage(parentTid, [ContentBlock("text", msg)], null, resultsMeta);

		// Clean up all deps
		foreach (childTid; children)
		{
			removeTaskDependency(parentTid, childTid);
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
			enum nudgeBody = "Your session was interrupted by a backend restart. "
				~ "Continue from where you left off. If you had a tool call in progress "
				~ "(Task, Handoff, SwitchMode, or any other tool), retry it.";
			auto nudgeText = wrapKnownSystemMessage(KnownSystemMessageKind.restartNudge, nudgeBody);
			auto nudgeMeta = buildKnownSystemMessageMeta(KnownSystemMessageKind.restartNudge);
			sendTaskMessage(tid, [ContentBlock("text", nudgeText)], null, nudgeMeta);
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

	/// Broadcast a task reload boundary and invalidate in-flight derived work.
	/// This is a hard barrier: clients are unsubscribed first and must call
	/// request_history to re-subscribe after replay.
	private void emitTaskReload(int tid, string reason = "")
	{
		import ae.utils.json : toJson;

		if (tid !in tasks)
			return;
		unsubscribeAll(tid);
		auto td = &tasks[tid];
		// Invalidate cached/in-flight suggestions so pre-reload content cannot replay.
		td.lastSuggestions = null;
		td.suggestGeneration++;
		if (td.suggestGenKill !is null)
			td.suggestGenKill();
		td.suggestGenHandle = null;
		td.suggestGenKill = null;
		broadcast(toJson(TaskReloadMessage("task_reload", tid, reason)));
	}

	/// Wrap text in [SYSTEM: ...] tags so the agent knows the message is
	/// injected by CyDo, not typed by the user.
	private string wrapSystemMessage(string subject, string body = null)
	{
		auto kw = config.system_keyword;
		if (body is null || body.length == 0)
			return "[" ~ kw ~ ": " ~ subject ~ "]";
		return "[" ~ kw ~ ": " ~ subject ~ "]\n\n" ~ body ~ "\n\n[/" ~ kw ~ "]";
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

	private void registerVisibleTurnAnchorFromEvent(int tid, size_t seq, string translated, string rawLine = null)
	{
		import std.algorithm : canFind, startsWith;

		if (tid !in tasks || translated.length == 0)
			return;
		auto td = &tasks[tid];

		if (translated.canFind(`"type":"item/started"`) && translated.canFind(`"item_type":"user_message"`))
		{
			@JSONPartial
			static struct UserAnchorProbe
			{
				string type;
				string item_type;
				@JSONOptional bool is_meta;
				@JSONOptional bool is_steering;
				@JSONOptional bool pending;
				@JSONOptional string uuid;
			}

			UserAnchorProbe probe;
			try
				probe = jsonParse!UserAnchorProbe(translated);
			catch (Exception)
				return;

			if (probe.type != "item/started" || probe.item_type != "user_message")
				return;
			if (probe.is_meta || probe.pending)
				return;

			auto uuid = probe.uuid;
			auto isEnqueue = uuid.length > "enqueue-".length && uuid.startsWith("enqueue-");
			string checkpointUuid;
			if (!isEnqueue && uuid.length > 0)
				checkpointUuid = uuid;
			else if (rawLine.length > 0)
			{
				@JSONPartial static struct RawUserUuidProbe
				{
					string type;
					@JSONOptional string uuid;
				}
				try
				{
					auto rawProbe = jsonParse!RawUserUuidProbe(rawLine);
					if (rawProbe.type == "user" && rawProbe.uuid.length > 0)
						checkpointUuid = rawProbe.uuid;
				}
				catch (Exception)
				{
				}
			}
			auto shouldPend = probe.is_steering && uuid.length == 0;
			auto anchor = shouldPend ? null : uuid;
			if (!shouldPend && anchor.length == 0)
				return;

			td.registerVisibleTurnAnchor(seq, true, probe.is_steering,
				anchor, checkpointUuid, shouldPend);
			return;
		}

		if (translated.canFind(`"type":"turn/stop"`))
		{
			@JSONPartial static struct TurnStopAnchorProbe { string type; @JSONOptional string uuid; }
			TurnStopAnchorProbe probe;
			try
				probe = jsonParse!TurnStopAnchorProbe(translated);
			catch (Exception)
				return;
			if (probe.type == "turn/stop" && probe.uuid.length > 0)
				td.registerVisibleTurnAnchor(seq, false, false, probe.uuid, probe.uuid, false);
			return;
		}

		if (translated.canFind(`"type":"turn/delta"`))
		{
			@JSONPartial static struct TurnDeltaAnchorProbe { string type; @JSONOptional string uuid; }
			TurnDeltaAnchorProbe probe;
			try
				probe = jsonParse!TurnDeltaAnchorProbe(translated);
			catch (Exception)
				return;
			if (probe.type == "turn/delta" && probe.uuid.length > 0)
				td.registerVisibleTurnAnchor(seq, false, false, probe.uuid, probe.uuid, false);
		}
	}

	private void rebuildVisibleTurnAnchors(int tid)
	{
		import cydo.task : extractEventFromEnvelope;

		if (tid !in tasks)
			return;
		auto td = &tasks[tid];
		td.visibleTurnAnchors = null;
		foreach (i, ref entry; td.history)
		{
			auto event = extractEventFromEnvelope(cast(string) entry.unsafeContents);
			if (event.length == 0)
				continue;
			registerVisibleTurnAnchorFromEvent(tid, i, event, i < td.rawSource.length ? td.rawSource[i] : null);
		}
	}

	private void backfillHistoryAnchor(int tid, size_t seq, string anchor)
	{
		import std.algorithm : canFind;
		import cydo.task : extractEventFromEnvelope, extractTsFromEnvelope;
		import cydo.agent.protocol : ItemStartedEvent;

		if (tid !in tasks || anchor.length == 0)
			return;
		auto td = &tasks[tid];
		if (seq >= td.history.length)
			return;

		auto envelope = cast(string) td.history[seq].unsafeContents;
		auto event = extractEventFromEnvelope(envelope);
		if (event.length == 0
			|| !event.canFind(`"type":"item/started"`)
			|| !event.canFind(`"item_type":"user_message"`))
			return;

		ItemStartedEvent userEv;
		try
			userEv = jsonParse!ItemStartedEvent(event);
		catch (Exception)
			return;
		if (userEv.uuid == anchor)
			return;
		userEv.uuid = anchor;
		td.history[seq] = Data(toJson(TaskEventEnvelope(
			tid, extractTsFromEnvelope(envelope), JSONFragment(toJson(userEv)))).representation);
	}

	private static bool isSessionStatusEvent(string translated)
	{
		import std.algorithm : canFind;
		return translated.canFind(`"type":"session/status"`)
			|| translated.canFind(`"type":"session\/status"`);
	}

	private static bool isTurnResultEvent(string translated)
	{
		import std.algorithm : canFind;
		return translated.canFind(`"type":"turn/result"`)
			|| translated.canFind(`"type":"turn\/result"`);
	}

	private static bool isProcessExitEvent(string translated)
	{
		import std.algorithm : canFind;
		return translated.canFind(`"type":"process/exit"`)
			|| translated.canFind(`"type":"process\/exit"`);
	}

	private void cacheSessionStatusEvent(int tid, string translated, long ts)
	{
		if (tid !in tasks)
			return;

		@JSONPartial static struct StatusProbe
		{
			string type;
			@JSONOptional string status;
		}

		try
		{
			auto probe = jsonParse!StatusProbe(translated);
			if (probe.type != "session/status")
				return;
			import std.string : strip;
			if (probe.status.strip.length == 0)
			{
				tasks[tid].clearLastSessionStatus();
				return;
			}
			tasks[tid].setLastSessionStatus(translated, ts);
		}
		catch (Exception)
		{
			// Malformed status payloads are never durable and should not linger.
			tasks[tid].clearLastSessionStatus();
		}
	}

	private static TranslatedEvent[] filterTransientSessionStatusEvents(
		TranslatedEvent[] events)
	{
		if (events.length == 0)
			return events;

		TranslatedEvent[] filtered;
		foreach (ev; events)
		{
			if (!isSessionStatusEvent(ev.translated))
			{
				filtered ~= ev;
				continue;
			}
		}
		return filtered;
	}

	private size_t appendAndBroadcastTaskEvent(int tid, TranslatedEvent ev)
	{
		if (tid !in tasks)
			return 0;

		if (isTurnResultEvent(ev.translated) || isProcessExitEvent(ev.translated))
			tasks[tid].clearLastSessionStatus();

		if (isSessionStatusEvent(ev.translated))
		{
			cacheSessionStatusEvent(tid, ev.translated, ev.ts.stdTime);
			sendToSubscribed(tid, Data(
				toJson(TaskEventEnvelope(tid, ev.ts.stdTime,
					JSONFragment(ev.translated))).representation));
			return cast(size_t) -1;
		}

		ensureHistoryLoaded(tid);
		auto historyData = Data(toJson(TaskEventEnvelope(tid, ev.ts.stdTime, JSONFragment(ev.translated))).representation);
		if (!mergeStreamingDelta(tid, ev.translated, historyData))
		{
			tasks[tid].appendHistory(historyData, ev.raw);
			auto seq = tasks[tid].history.length - 1;
			registerVisibleTurnAnchorFromEvent(tid, seq, ev.translated, ev.raw);
		}

		auto seq = tasks[tid].history.length - 1;
		sendToSubscribed(tid, Data(
			toJson(TaskEventSeqEnvelope(tid, cast(int) seq, ev.ts.stdTime,
				JSONFragment(ev.translated))).representation));
		return seq;
	}

	private void broadcastTask(int tid, TranslatedEvent ev)
	{
		// Apply timestamp fallback: use backend receipt time if agent provided none.
		import std.datetime : Clock;
		import std.algorithm : canFind, startsWith;
		import ae.utils.time.types : AbsTime;
		if (ev.ts == AbsTime.init)
			ev.ts = AbsTime(Clock.currStdTime);

		// Extract agent session ID from translated event
		if (tid in tasks && tasks[tid].agentSessionId.length == 0)
			tryExtractAgentSessionId(tid, ev.translated);
		ev.translated = normalizeKnownSystemMessageMeta(ev.translated);
		if (tid in tasks && isCompactionReminderEchoEvent(ev.translated))
			tasks[tid].compactionReminderInFlight = true;
		auto shouldSendCompactionReminder = tid in tasks
			&& (isCompactionReminderTriggerRaw(ev.raw)
				|| isCompactionReminderTriggerEvent(ev.translated));
		if (shouldSendCompactionReminder)
			maybeSendCompactionReminderSteering(tid);

		// Intercept queue-operation events for steering message handling
		if (isQueueOperation(ev.translated))
		{
				if (auto td = tid in tasks)
				{
					import ae.utils.json : jsonParse;
					auto op = jsonParse!QueueOperationProbe(ev.translated);
					if (op.operation == "enqueue")
					{
						if (op.content.startsWith(systemMessagePrefix(
							KnownSystemMessageKind.postCompactionTaskModeReminder)))
							td.compactionReminderInFlight = true;
						td.enqueueSteering(op.content, ev.translated);
						return; // already displayed via unconfirmedUserEvent
					}

				// Compacted back-to-back queue operations can leave one dequeued
				// steering turn without a following user echo; flush it now.
				if ((op.operation == "dequeue" || op.operation == "remove")
					&& td.hasPendingDequeuedSteering())
				{
					string pendingText, pendingRaw;
					if (td.popPendingDequeuedSteering(pendingText, pendingRaw))
					{
						auto pendingSteeringEv = buildSyntheticUserEvent(pendingText, true);
						appendAndBroadcastTaskEvent(tid,
							TranslatedEvent(toJsonWithSyntheticUserMeta(pendingText, pendingSteeringEv),
								pendingRaw.length > 0 ? pendingRaw : null, ev.ts));
					}
				}

				if (op.operation == "dequeue")
				{
					string text, enqueueRaw;
					if (td.popSteering(text, enqueueRaw))
						td.setPendingDequeuedSteering(text, enqueueRaw);
					else
						td.clearPendingDequeuedSteering();
					return; // the real message/user follows
				}
				else if (op.operation == "remove")
				{
					string text, enqueueRaw;
					if (td.popSteering(text, enqueueRaw))
					{
						// Broadcast synthetic steering confirmation
						auto steeringEv = buildSyntheticUserEvent(text, true);
						appendAndBroadcastTaskEvent(tid,
							TranslatedEvent(toJsonWithSyntheticUserMeta(text, steeringEv),
								enqueueRaw.length > 0 ? enqueueRaw : null, ev.ts));
					}
					return;
				}
			}
			return; // unknown queue operation — consume silently
		}

		if (tid in tasks && tasks[tid].hasPendingDequeuedSteering())
		{
			auto td = &tasks[tid];
			auto ta = agentForTask(tid);
			if (ev.raw.length > 0 && ta.isAssistantMessageLine(ev.raw))
			{
				string pendingText, pendingRaw;
				if (td.popPendingDequeuedSteering(pendingText, pendingRaw))
				{
					auto steeringEv = buildSyntheticUserEvent(pendingText, true);
					appendAndBroadcastTaskEvent(tid,
						TranslatedEvent(toJsonWithSyntheticUserMeta(pendingText, steeringEv),
							pendingRaw.length > 0 ? pendingRaw : null, ev.ts));
				}
			}
			else if (ev.translated.canFind(`"type":"item/started"`)
				&& ev.translated.canFind(`"item_type":"user_message"`))
			{
				@JSONPartial static struct SteeringEchoProbe
				{
					string type;
					string item_type;
					@JSONOptional bool is_steering;
					@JSONOptional string uuid;
				}
				SteeringEchoProbe probe;
				try
				{
					probe = jsonParse!SteeringEchoProbe(ev.translated);
					if (probe.type == "item/started"
						&& probe.item_type == "user_message"
						&& probe.is_steering)
					{
						if (probe.uuid.length > 0 && !probe.uuid.startsWith("enqueue-"))
						{
							import cydo.agent.protocol : ItemStartedEvent;
							auto userEv = jsonParse!ItemStartedEvent(ev.translated);
							userEv.uuid = null;
							ev.translated = toJson(userEv);
						}
						td.clearPendingDequeuedSteering();
					}
				}
				catch (Exception)
				{
					// Keep the original event if parsing fails.
				}
			}
		}
		if (tid in tasks && isCompactionReminderSteerFailureEvent(ev.translated))
			tasks[tid].compactionReminderInFlight = false;

		appendAndBroadcastTaskEvent(tid, ev);
	}

	/// Try to merge an item/delta into the last history entry.
	/// Returns true if merged (caller should NOT append), false otherwise.
	private bool mergeStreamingDelta(int tid, string translated, Data data)
	{
		import std.algorithm : canFind;

		// Only merge item/delta events.
		if (!translated.canFind(`"type":"item/delta"`))
			return false;

		auto td = &tasks[tid];
		if (td.history.length == 0)
			return false;

		auto lastEntry = cast(const(char)[])td.history[$ - 1].unsafeContents;
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

		// Reconstruct envelope from merged content, preserving the original ts.
		import std.json : parseJSON;
		import cydo.task : extractTsFromEnvelope;
		auto prevTs = extractTsFromEnvelope(cast(string)td.history[$ - 1].unsafeContents);
		auto mergedObj = parseJSON(merged);
		auto canonical = toJson(TaskEventEnvelope(tid, prevTs,
			JSONFragment(mergedObj["event"].toString())));
		td.replaceLastHistory(Data(canonical.representation));
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
			if (!shuttingDown)
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
		sendToSubscribed(tid, Data(toJson(
			SuggestionsUpdateMessage("suggestions_update", tid, suggestions)).representation));
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

			tracef("Workspace '%s' (%s): %d project(s)", ws.name, ws.root, projInfos.length);
			foreach (ref p; projInfos)
				tracef("  - %s (%s)", p.name, p.path);
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

	private void ensureProjectWatch(string projectPath)
	{
		import std.path : buildPath;
		if (projectPath in projectDirWatches)
			return;  // already watching

		auto cydoDir = buildPath(projectPath, ".cydo");
		if (!exists(cydoDir))
			return;  // nothing to watch yet

		projectDirWatches[projectPath] = projectINotify.add(
			cydoDir,
			INotify.Mask.closeWrite | INotify.Mask.create | INotify.Mask.movedTo,
			(in char[] name, INotify.Mask mask, uint cookie)
			{
				if (name == "task-types.yaml" || name == "defs")
					onProjectConfigChanged(projectPath);
			}
		);

		auto typesFile = buildPath(cydoDir, "task-types.yaml");
		if (exists(typesFile))
		{
			projectFileWatches[projectPath] = projectINotify.add(
				typesFile,
				INotify.Mask.closeWrite,
				(in char[] name, INotify.Mask mask, uint cookie)
				{
					onProjectConfigChanged(projectPath);
				}
			);
		}
	}

	private void onProjectConfigChanged(string projectPath)
	{
		infof("Project config changed for %s, reloading task types...", projectPath);
		taskTypesByProject.remove(projectPath);
		broadcast(buildTaskTypesListForProject(projectPath));
	}

	private void handleRefreshWorkspacesMsg()
	{
		discoverAllWorkspaces();
		broadcast(buildWorkspacesList());
		enumerateSessions();
	}

	/// Read a prompt template file from the prompt search path and substitute variables.
	private string readPromptFile(string relativePath, string projectPath, string[string] vars)
	{
		import std.file : exists, readText;
		import std.path : buildPath;

		foreach (dir; promptSearchPath(projectPath))
		{
			auto path = buildPath(dir, relativePath);
			if (exists(path))
				return substituteVars(readText(path), vars);
		}
		warningf("Prompt file not found: %s", relativePath);
		return "";
	}

	/// Spawn a lightweight claude process to generate a concise title
	/// from the user's initial message.
	private void generateTitle(int tid, string userMessage)
	{
		auto td = &tasks[tid];

		if (td.titleGenDone || td.titleGenHandle !is null)
			return;

		auto msg = userMessage.length > 500 ? userMessage[0 .. 500] : userMessage;
		auto prompt = readPromptFile("prompts/generate-title.md", td.projectPath, ["user_message": msg]);
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
			broadcastTask(tid, TranslatedEvent(toJson(ev), null));
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
			td.isProcessing, td.stdinClosed, td.needsAttention, td.hasPendingQuestion, td.notificationBody,
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

	private void broadcastFocusHint(int fromTid, int toTid)
	{
		import ae.utils.json : toJson;
		broadcast(toJson(FocusHintMessage("focus_hint", fromTid, toTid)));
	}

	private void unicastFocusHint(WebSocketAdapter ws, int fromTid, int toTid)
	{
		import ae.utils.json : toJson;
		ws.send(Data(toJson(FocusHintMessage("focus_hint", fromTid, toTid)).representation));
	}

	/// Find the first alive ancestor of a task, walking up through dead parents.
	/// Returns -1 if no ancestor is found.
	private int findAliveAncestor(int tid)
	{
		if (tid !in tasks || tasks[tid].parentTid == 0)
			return -1;
		int targetTid = tasks[tid].parentTid;
		while (targetTid in tasks)
		{
			auto target = &tasks[targetTid];
			if (target.parentTid == 0 || target.alive)
				break;
			targetTid = target.parentTid;
		}
		return (targetTid in tasks) ? targetTid : -1;
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

	private string buildTaskTypesListForProject(string projectPath)
	{
		import ae.utils.json : toJson;

		auto types = getTaskTypesForProject(projectPath);
		auto entryPoints = getEntryPointsForProject(projectPath);
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
		return toJson(ProjectTaskTypesListMessage("project_task_types_list", projectPath, eps, typeInfo));
	}

	private void handleRequestTaskTypesMsg(WebSocketAdapter ws, WsMessage json)
	{
		if (json.project_path.length == 0)
			ws.send(Data(buildTaskTypesList().representation));
		else
		{
			ensureProjectWatch(json.project_path);
			ws.send(Data(buildTaskTypesListForProject(json.project_path).representation));
		}
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

		auto prompt = readPromptFile("prompts/generate-suggestions.md", td.projectPath, ["conversation": history]);
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
				{
					warningf("generateSuggestions: failed to parse result: %s\n---\n%s\n---", e.msg, result);
					broadcastSuggestionsUpdate(tid, []);
					return;
				}

			tasks[tid].lastSuggestions = suggestionList;
			broadcastSuggestionsUpdate(tid, suggestionList);
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

	// Try nested params.item.text (Codex item/completed agentMessage events)
	@JSONPartial
	static struct ParamsItemTextInner { string text; }
	@JSONPartial
	static struct ParamsItemParamsInner { ParamsItemTextInner item; }
	@JSONPartial
	static struct ParamsItemProbe { ParamsItemParamsInner params; }

	try
	{
		auto probe = jsonParse!ParamsItemProbe(event);
		if (probe.params.item.text.length > 0)
			return probe.params.item.text;
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
	// True when the most-recent "A:" entry came from a non-streaming source
	// (turn/result or item/completed) that can be superseded by a later
	// item/delta text_delta event for the same turn.  This prevents spurious
	// "[...]" entries when multiple event types carry the same assistant text:
	//   Claude live:   item/delta (set) → item/completed (no text) → turn/result (skip)
	//   Claude history: item/completed (set, no delta follows) → correct
	//   Codex:         turn/result (set, no delta follows) → correct
	//   Copilot:       turn/result (set) → item/completed (replace) → item/delta (replace)
	bool lastEntryFromNonDelta = false;

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
				lastEntryFromNonDelta = false;
				entry = "USER: " ~ abbreviateText(text, truncThreshold);
			}
			else
				continue;
		}
		else if (event.canFind(`"turn/result"`))
		{
			// turn/result echoes the full assistant response. Used as a fallback source
			// when no item/delta text_delta events are present (e.g. Codex). For Claude
			// and Copilot, item/delta text_delta arrives later in the reverse scan and
			// replaces this entry, so we mark it as supersedable (lastEntryFromNonDelta).
			if (seenAssistantText)
				continue;  // already have text from a delta — skip
			auto text = extractMessageText(event);
			if (text.length == 0)
				continue;
			seenAssistantText = true;
			lastEntryFromNonDelta = true;
			entry = "A: " ~ abbreviateText(text, truncThreshold);
		}
		else if (event.canFind(`"item/completed"`) ||
		         (event.canFind(`"item/delta"`) && event.canFind(`"text_delta"`)))
		{
			auto text = extractMessageText(event);
			if (text.length == 0)
				continue;

			if (!seenAssistantText)
			{
				seenAssistantText = true;
				// item/completed is supersedable; item/delta is authoritative.
				lastEntryFromNonDelta = event.canFind(`"item/completed"`);
				entry = "A: " ~ abbreviateText(text, truncThreshold);
			}
			else if (lastEntryFromNonDelta && !turnCollapsed)
			{
				// The preceding "A:" came from a lower-priority source (turn/result or
				// item/completed); replace it with the more specific source.
				// item/completed is still supersedable; item/delta is authoritative.
				entries[$ - 1] = "A: " ~ abbreviateText(text, truncThreshold);
				lastEntryFromNonDelta = event.canFind(`"item/completed"`);
				continue;
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
					lastEntryFromNonDelta = false;
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

	// Structured context: header + last 4 turns (user-assistant pairs).
	// After reversing, entries alternate as "USER: ..." then "A: ..." per turn.
	// We scan backward to find the 4th USER: from the end and slice from there.
	enum maxTurns = 4;
	int turnCount = 0;
	size_t sliceFrom = 0;
	foreach_reverse (i, ref e; entries)
	{
		if (e.length > 5 && e[0 .. 5] == "USER:")
		{
			turnCount++;
			if (turnCount <= maxTurns)
				sliceFrom = i;
		}
	}
	if (turnCount > maxTurns)
		entries = entries[sliceFrom .. $];

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

/// Replace text content for editable user-facing messages in JSONL.
/// Supports both type:"user" message lines and queue-operation enqueue lines.
private string replaceUserMessageContent(string line, string newContent)
{
	import std.json : parseJSON, JSONValue;

	auto json = parseJSON(line);
	if ("message" in json)
		json["message"]["content"] = JSONValue(newContent);
	else if ("type" in json && "operation" in json
		&& json["type"].str == "queue-operation"
		&& json["operation"].str == "enqueue")
		json["content"] = JSONValue(newContent);
	return json.toString();
}
