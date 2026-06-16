module cydo.application;

import core.lifetime : move;
import core.time : seconds;

import std.file : exists, isFile, thisExePath;
import std.format : format;
import std.logger : tracef, infof, warningf, errorf, fatalf;
import std.stdio : File, stderr;
import std.string : representation;

import ae.utils.funopt : funopt, funoptDispatch, funoptDispatchUsage, FunOptConfig, Option, Parameter;
import ae.utils.main : main;

import ae.net.asockets : socketManager, DisconnectType;
import ae.net.http.websocket : WebSocketAdapter;
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
import cydo.mcp.payloads : TaskResult;
import cydo.mcp.tools : AskQuestion, LaunchedTask, ToolsBackend, ValidatedTask;
import cydo.task : BatchSignal;
import cydo.archive_manager : ArchiveManager, ArchiveManagerHost, ArchiveTaskSnapshot;
import cydo.batchrouter : BatchConsumeKind;
import cydo.batchregistry : BatchHandle, BatchRegistry;
import cydo.client_hub : ClientHub;
import cydo.config_watcher : ConfigWatcher, ConfigWatcherHost;
import cydo.discovery_service : DiscoveryService, DiscoveryServiceHost,
	DiscoveryTaskSnapshot, ImportableTaskSpec;
import cydo.frontend_snapshots : buildAgentsList, buildNoticesList,
	buildServerStatus, buildTaskEntry, buildTasksList, buildTaskTypesList,
	buildTaskTypesListForProject, buildWorkspacesList;
import cydo.history_pipeline : HistoryBroadcastPlan, HistoryEventPipeline,
	HistoryEventPipelineHost;
import cydo.history_abbrev : buildAbbreviatedHistoryFromStrings, extractMessageText;
import cydo.jsonl_edit : replaceUserMessageContent;
import cydo.runtime.logging : installRobustLogger;
import cydo.question_router : QuestionRouter, QuestionRouterHost;
import cydo.policy.permissions : evaluatePermissionPolicy, makePermissionAllowJson, makePermissionDenyJson;
import cydo.task_type_catalog : TaskTypeCatalog;
import cydo.task_session_runner : TaskSessionLaunch, TaskSessionRunner,
	TaskSessionRunnerHost;
import cydo.transport : McpCallbacks, RawSourceLookupResult, RawSourceLookupStatus,
	TransportAdapter, WebSocketCallbacks;
import cydo.usage.tracker : AgentUsageTracker;

import cydo.agent.agent : Agent;
import cydo.agent.protocol : AgentAckEnvelope, BatchResultEnvelope, ContentBlock,
	ItemStartedEvent, SessionRateLimitEvent, TaskEventEnvelope, TaskEventSeqEnvelope, TranslatedEvent,
	UnconfirmedUserEventEnvelope, extractContentText;
import cydo.agent.session : AgentSession;
import cydo.agent.terminal : TerminalProcess;
import cydo.config : AgentConfig, AgentDriver, CydoConfig, PathMode, SandboxConfig, WorkspaceConfig;
import cydo.persist : ForkResult, LoadedHistory, Persistence, countLinesAfterForkId, createForkTask, openDatabase,
	editJsonlByContent, editJsonlMessage, findNextUserUuid, forkTask, lastForkIdInJsonl, loadTaskHistory, truncateJsonl, writeJsonlPrefix;
import cydo.runtime.config_resolution : loadRuntimeConfig, reloadRuntimeConfig;
import cydo.sandbox : cleanup, resolveExecutablePath, runtimeDir;
import cydo.tasktype : TaskTypeDef, ContinuationDef, OutputType, WorktreeMode, byName, isInteractive, loadTaskTypes,
	renderPrompt, renderContinuationPrompt, substituteVars, loadSystemPrompt,
	loadProjectMemory, resolveAgent, isRegisteredAgent;
import cydo.system.framing : tryParseSystemFraming, tryExtractSubject,
	stripTaskSystemPromptWrapper, ParsedSystemFraming, CompiledTemplate, compileTemplate,
	tryMatchTemplate, validateTemplateSource;
import cydo.system.known_messages : KnownSystemMessageKind, KnownSystemMessageMatch,
	handoffSubject, modeSwitchSubject, sessionStartSubject,
	subTaskWaitingForAnswerSubject, systemMessagePrefix, systemMessageSubject,
	taskPromptSubject, tryKnownSystemMessageMatch, wrapKnownSystemMessage;
import cydo.task;
import cydo.text.title : truncateTitle;
import cydo.worktree;

class App : ToolsBackend
{
	import cydo.jsonl : JsonlTracker;

	private TransportAdapter transport;
	private ClientHub clientHub = new ClientHub();
	private TaskData[int] tasks;
	private Persistence persistence;
	private CydoConfig config;
	private string taskDirTemplate;
	private DiscoveryService discoveryService;
	private ConfigWatcher configWatcher;
	private Agent agent; // default agent
	private Agent[string] agentsByName;
	private TaskTypeCatalog taskTypeCatalog;
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
	private BatchRegistry batchRegistry;
	private QuestionRouter questionRouter;
	// JSONL file tracking state
	private JsonlTracker jsonlTracker;
	// HTTP basic auth credentials (from environment)
	private string authUser;
	private string authPass;
	// Active notices keyed by notice ID
	private Notice[string] activeNotices;
	private AgentUsageTracker agentUsageTracker = new AgentUsageTracker();
	private ArchiveManager archiveManager;
	private HistoryEventPipeline historyPipeline;
	private TaskSessionRunner taskSessionRunner;
	// Set during SIGTERM shutdown — suppress onExit status updates so tasks
	// stay "alive" in the DB and can be resumed after restart.
	private bool shuttingDown;

	// Active TerminalProcess instances (Bash MCP tool calls in flight).
	// Tracked so shutdown() can SIGKILL them to unblock the event loop.
	private TerminalProcess[] activeTerminals;

	// Cache of compiled template regexes keyed on raw template source text.
	// Avoids recompiling the same template on every history replay event.
	private CompiledTemplate[string] compiledTemplateCache;

	void start()
	{
		initLogger();
		applyConfiguredLogLevel("info");
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
			auto taskTypesDir = buildPath(baseDir, "defs");
			auto taskTypesPath = buildPath(baseDir, "defs/task-types.yaml");
			taskTypeCatalog = new TaskTypeCatalog(taskTypesDir, taskTypesPath);
			webDistDir = buildPath(baseDir, "web/dist/");
		}
		{
			persistence = openDatabase();
			import cydo.sandbox : runtimeDir;
			createPidFile("cydo.pid", runtimeDir());
		}
		config = loadRuntimeConfig();
		taskDirTemplate = config.task_dir.length > 0 ? config.task_dir : defaultTaskDirTemplate;
		applyConfiguredLogLevel(config.log_level);
		foreach (name, ref ac; config.agents)
		{
			auto driver = ac.driver.value;
			auto a = createAgentByDriver(driver);
			a.setModelAliases(ac.model_aliases);
			{
				import cydo.agent.copilot : CopilotAgent;
				if (auto ca = cast(CopilotAgent) a)
					ca.toolDispatch_ = (string tool, string callerTid, JSONFragment args) =>
						dispatchTool(tool, callerTid, args);
			}
			agentsByName[name] = a;
		}
		auto defaultName = defaultAgentName("");
		agent = agentsByName[defaultName];
		transport = new TransportAdapter(
			webDistDir,
			WebSocketCallbacks(
				onAccepted: &onWebSocketAccepted,
				onMessage: &handleWsMessage,
				onDisconnected: &onWebSocketDisconnected,
			),
			&lookupRawSource,
			McpCallbacks(
				dispatchTool: &dispatchTool,
				interruptForPendingContinuation: &interruptForPendingContinuation,
				onDeliveryFailed: &onMcpDeliveryFailed,
				onDelivered: &onToolCallDelivered,
			),
		);
		archiveManager = new ArchiveManager(ArchiveManagerHost(
			tryGetTask: &tryGetArchiveTask,
			snapshotTasks: &snapshotArchiveTasks,
			tryTaskDir: &tryResolveArchiveTaskDir,
			updateTaskState: &updateArchiveTaskState,
			persistArchived: (int tid, bool archived) {
				persistence.setArchived(tid, archived);
			},
			broadcastTaskUpdate: &broadcastTaskUpdate,
			sendError: &sendArchiveError,
			setArchiveGoal: (int tid, ArchiveState goal) {
				auto td = tid in tasks;
				assert(td !is null, format!"Archive queue requested for missing task %d"(tid));
				assert(td.archiveQueue !is null,
					format!"Archive queue missing for task %d"(tid));
				return td.archiveQueue.setGoal(goal);
			},
		));
		discoveryService = new DiscoveryService(DiscoveryServiceHost(
			snapshotTasks: &snapshotDiscoveryTasks,
			loadSessionMetaCache: () => persistence.loadSessionMetaCache(),
			withMutationTransaction: &withDiscoveryMutationTransaction,
			importableHistoryPath: &importableHistoryPath,
			deleteImportableTask: &deleteImportableTask,
			createImportableTask: &createImportableTask,
			broadcastWorkspaces: &broadcastDiscoveryWorkspaces,
			broadcastScanStatus: &broadcastDiscoveryScanStatus,
			deleteSessionMetaCacheEntry: (string agentType, string sessionId) {
				persistence.deleteSessionMetaCacheEntry(agentType, sessionId);
			},
			upsertSessionMetaCache: (string agentType, string sessionId, long mtime,
				string projectPath, string title, bool hasMessages) {
				persistence.upsertSessionMetaCache(agentType, sessionId, mtime,
					projectPath, title, hasMessages);
			},
		));
		configWatcher = new ConfigWatcher(ConfigWatcherHost(
			onConfigChanged: &onConfigChanged,
			onProjectConfigChanged: &onProjectConfigChanged,
		));
		historyPipeline = new HistoryEventPipeline(HistoryEventPipelineHost(
			getTask: (int tid) => tid in tasks ? &tasks[tid] : null,
			tryAgentForTask: &tryAgentForTask,
			effectiveCwd: (int tid) {
				auto td = tid in tasks;
				return effectiveCwd(td);
			},
			injectAgentNameIntoSessionInit: &injectAgentNameIntoSessionInit,
			normalizeKnownSystemMessageMeta: &normalizeKnownSystemMessageMeta,
			synthesizeHistoryErrorEventJson: &synthesizeHistoryErrorEventJson,
			sendToSubscribed: (int tid, Data data) {
				clientHub.sendToSubscribed(tid, data);
			},
			subscribe: (WebSocketAdapter ws, int tid) {
				clientHub.subscribe(ws, tid);
			},
			sendForkableUuids: (WebSocketAdapter ws, int tid) {
				auto td = tid in tasks;
				assert(td !is null,
					format!"Forkable UUID replay requested for missing task %d"(tid));
				jsonlTracker.sendForkableUuidsFromFile(ws, tid, td.agentSessionId,
					effectiveCwd(td));
			},
			broadcastForkableUuids: (int tid) {
				jsonlTracker.broadcastForkableUuidsFromFile(tid);
			},
			sendReplaySupplementalState: &sendHistoryReplaySupplementalState,
			onHistorySubscribed: &onHistorySubscribed,
			ensureAgentSessionIdFromEvent: &ensureHistoryAgentSessionIdFromEvent,
			updateClaudeUsageFromEvent: &updateClaudeUsageFromEvent,
			planBroadcast: &planHistoryBroadcast,
		));
		taskSessionRunner = new TaskSessionRunner(TaskSessionRunnerHost(
			getTask: (int tid) => tid in tasks ? &tasks[tid] : null,
			taskDir: &taskDir,
			outputPath: &outputPath,
			effectiveCwd: &effectiveCwd,
			worktreePath: &worktreePath,
			globalSandbox: () => config.sandbox,
			findWorkspaceSandbox: &findWorkspaceSandbox,
			findWorkspaceRoot: &findWorkspaceRoot,
			findWorkspacePermissionPolicy: &findWorkspacePermissionPolicy,
			findAgentSandbox: &findAgentSandbox,
			resolveSharedTmpPath: &resolveSharedTmpPath,
			mcpSocketPath: () => transport.mcpSocketPath,
			agentForTask: &agentForTask,
			tryAgentForTask: &tryAgentForTask,
			clearLastActive: (int tid) {
				persistence.clearLastActive(tid);
			},
			broadcastTask: (int tid, TranslatedEvent ev) {
				historyPipeline.broadcastTask(tid, ev);
			},
			appendSynthesizedHistoryError: (int tid, string subject, string body) {
				return historyPipeline.appendSynthesizedHistoryError(tid, subject, body);
			},
			broadcastAppendedTaskEvent: &broadcastAppendedTaskEvent,
			sendAgentAck: &sendAgentAck,
			broadcastTaskUpdate: &broadcastTaskUpdate,
			onTaskTurnCompletedAlive: &onTaskTurnCompletedAlive,
			drainIdleCallbacksForTurnResult: &drainIdleCallbacksForTurnResult,
			drainIdleCallbacksOnExit: &drainIdleCallbacksOnExit,
			hasPendingSubTask: &hasPendingSubTask,
			hasTaskDependency: &hasTaskDependency,
			hasPendingChildQuestion: &hasPendingChildQuestion,
			sendPendingChildAnswerReminder: &sendPendingChildAnswerReminder,
			checkDeclaredOutputs: &checkDeclaredOutputs,
			finalizeCompletedSubTask: &finalizeCompletedSubTask,
			deliverFailedPendingSubTaskResult: &deliverFailedPendingSubTaskResult,
			deliverWaitingParentResultsIfReady: &deliverWaitingParentResultsIfReady,
			deliverBatchResults: &deliverBatchResults,
			failPendingAskUserQuestionOnExit: &failPendingAskUserQuestionOnExit,
			failPendingPermissionPromptOnExit: &failPendingPermissionPromptOnExit,
			failPendingAskRouteOnExit: &failPendingAskRouteOnExit,
			cancelExitBackgroundWork: &cancelExitBackgroundWork,
			resetHistoryWatermarkOnly: &resetHistoryWatermarkOnly,
			resetHistoryWatermarkAfterExit: &resetHistoryWatermarkAfterExit,
			unsubscribeTaskHistorySubscribers: (int tid) {
				clientHub.unsubscribeAll(tid);
			},
			touchAndPersistLastActive: &touchAndPersistLastActive,
			findAliveAncestor: &findAliveAncestor,
			broadcastFocusHint: &broadcastFocusHint,
			persistStatus: (int tid, string status) {
				persistence.setStatus(tid, status);
			},
			persistResultText: (int tid, string resultText) {
				persistence.setResultText(tid, resultText);
			},
			requestMissingOutputs: &requestMissingOutputs,
			spawnContinuation: &spawnContinuation,
			spawnOnYieldContinuation: &spawnOnYieldContinuation,
			emitTaskReload: (int tid) {
				emitTaskReload(tid);
			},
			startJsonlWatch: (int tid) {
				jsonlTracker.startJsonlWatch(tid);
			},
			stopJsonlWatch: (int tid) {
				jsonlTracker.stopJsonlWatch(tid);
			},
			broadcastForkableUuidsFromFile: (int tid) {
				jsonlTracker.broadcastForkableUuidsFromFile(tid);
			},
			sendSystemRestartNudge: &sendSystemNudge,
			loadPersistedTaskDeps: &loadPersistedTaskDeps,
			snapshotTaskIds: &snapshotTaskIdsForResume,
			waitingTaskChildrenAllDone: &waitingTaskChildrenAllDone,
			shuttingDown: () => shuttingDown,
			taskTypeCatalog: taskTypeCatalog,
		));
		questionRouter = new QuestionRouter(QuestionRouterHost(
			getTask: (int tid) => tid in tasks ? &tasks[tid] : null,
			tasksShareWorkspace: (int aTid, int bTid) {
				auto aTd = aTid in tasks;
				auto bTd = bTid in tasks;
				assert(aTd !is null && bTd !is null,
					format!"QuestionRouter workspace lookup requires live tasks %d and %d"
						(aTid, bTid));
				return tasksShareWorkspace(*aTd, *bTd);
			},
			taskWorkspaceLabel: (int tid) {
				auto td = tid in tasks;
				assert(td !is null,
					format!"QuestionRouter workspace label requested for missing task %d"(tid));
				return taskWorkspaceLabel(*td);
			},
			systemKeyword: () => config.system_keyword,
			readPromptFile: &readPromptFile,
			buildKnownSystemMessageMeta: &buildKnownSystemMessageMeta,
			sendTaskMessage: (int tid, const(ContentBlock)[] content,
				string cydoMeta, string nonce) {
				sendTaskMessage(tid, content, null, cydoMeta, nonce);
			},
			persistStatus: (int tid, string status) {
				persistence.setStatus(tid, status);
			},
			persistResultText: (int tid, string resultText) {
				persistence.setResultText(tid, resultText);
			},
			broadcastTaskUpdate: &broadcastTaskUpdate,
			broadcastFocusHint: &broadcastFocusHint,
			addIdleCallback: (int tid, void delegate() cb) {
				auto td = tid in tasks;
				assert(td !is null,
					format!"QuestionRouter idle callback requested for missing task %d"(tid));
				td.onIdleCallbacks ~= cb;
			},
			reactivateTask: (int tid, void delegate() onReady) {
				auto td = tid in tasks;
				assert(td !is null,
					format!"QuestionRouter reactivation requested for missing task %d"(tid));
				assert(td.processQueue !is null,
					format!"QuestionRouter reactivation requested without process queue for task %d"(tid));
				td.processQueue.setGoal(ProcessState.Alive).then(onReady).ignoreResult();
			},
			hasPendingSubTask: &hasPendingSubTask,
			registerFollowUpBatchChild: (int parentTid, int childTid,
				BatchHandle handle) {
				auto subTaskPromise = new Promise!McpResult;
				pendingSubTasks[childTid] = subTaskPromise;
				taskDeps[childTid] = parentTid;
				persistence.addTaskDep(parentTid, childTid);
				subTaskPromise.then((McpResult r) {
					string error;
					if (!batchRegistry.enqueueChildDone(handle, 0, childTid, r, error))
						errorf("batch router error: %s", error);
				});
			},
			cleanupAfterFollowUpAnswerDelivery: (int childTid) {
				if (childTid in pendingSubTasks)
					pendingSubTasks.remove(childTid);
				if (auto parentTidPtr = childTid in taskDeps)
					removeTaskDependency(*parentTidPtr, childTid);
			},
			awaitBatchLoop: &awaitBatchLoop,
			makeInternalBatchError: &makeInternalBatchError,
		), &batchRegistry);

		jsonlTracker.getAgent = &agentForTask;
		jsonlTracker.getTask = (int tid) => tid in tasks ? &tasks[tid] : null;
		jsonlTracker.getEffectiveCwd = (int tid) {
			auto td = tid in tasks;
			return effectiveCwd(td);
		};
		jsonlTracker.sendToSubscribed = (int tid, string msg) =>
			clientHub.sendToSubscribed(tid, Data(msg.representation));
		jsonlTracker.onAnchorResolved = (int tid, size_t seq, string anchor) =>
			historyPipeline.backfillHistoryAnchor(tid, seq, anchor);

		// Load task type definitions
		auto types = taskTypeCatalog.getTaskTypes();
		if (types.length == 0)
			warningf("no task types loaded");
		else
			infof("Loaded %d task types", types.length);

		// Discover projects in all workspaces
		discoveryService.discoverAllWorkspaces(config);

		// Watch config file for hot-reload
		configWatcher.start();

		// Load persisted tasks (metadata only — history loaded on demand)
		foreach (row; persistence.loadTasks())
		{
			auto td = TaskData(row.tid, row.workspace, row.projectPath);
			td.agentSessionId = row.agentSessionId;
			td.description = row.description;
			td.entryPoint = row.entryPoint;
			td.taskType = row.taskType;
			td.agentType = row.agentType;
			td.parentTid = row.parentTid;
			td.relationType = row.relationType;
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
				makeArchiveQueueSF(rowTid),
				tasks[rowTid].archived ? ArchiveState.Archived : ArchiveState.Unarchived,
			);

			// Snapshot the JSONL byte size as the deferred-load watermark so that
			// live events arriving during resume are buffered rather than blocked
			// on a synchronous JSONL parse. Watermark.none() only for tasks with
			// no agent session at all; tasks with an agentSessionId stay deferred
			// so that ensureHistoryLoaded can run the full load path (including
			// orphan error synthesis for unconfigured agent types).
			{
				auto td2 = &tasks[rowTid];
				Watermark wm;
				if (td2.agentSessionId.length > 0)
				{
					auto startTa = tryAgentForTask(rowTid);
					if (startTa)
					{
						// effectiveCwd may throw for tasks whose workspace is no
						// longer configured — treat as JSONL absent, the same as
						// an orphan agent: keep deferred and synthesize on demand.
						string cwd;
						try
							cwd = effectiveCwd(td2);
						catch (Exception)
							cwd = "";
						if (cwd.length == 0)
							wm = Watermark.unreadable();
						else
						{
							auto jp = startTa.historyPath(td2.agentSessionId, cwd);
							auto fromPath = watermarkFromPath(jp);
							wm = fromPath.isDeferred
								? fromPath
								: Watermark.unreadable(); // JSONL absent; load delegate returns empty
						}
					}
					else
						wm = Watermark.unreadable(); // Orphan agent: keep deferred so ensureHistoryLoaded synthesizes error
				}
				td2.history.reset(wm);
			}
		}
		// Post-migration cleanup: remove stale worktree symlinks from pre-v2 sessions
		foreach (tid, ref td; tasks)
		{
			import std.file : isSymlink, remove;
			auto td_dir = tryTaskDir(td);
			if (td_dir.length == 0)
				continue;
			auto wtPath = worktreePathForTaskDir(td_dir);
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
		transport.startMcpSocket();

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
					auto jp = ta.historyPath(td.agentSessionId, effectiveCwd(&td));
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

		discoveryService.enumerateSessions(config, agentsByName);

		import std.process : environment;

		auto sslCert = environment.get("CYDO_TLS_CERT", null);
		auto sslKey = environment.get("CYDO_TLS_KEY", null);
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
		transport.setAuthCredentials(authUser, authPass);
		transport.startHttpServer(sslCert, sslKey);
		auto server = transport.server;

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
			foreach (a; agentsByName)
				if (auto ca = cast(CodexAgent) a)
					ca.shutdownAllServers();
		}
		{
			import ae.net.asockets : disconnectable;
			auto clientsSnapshot = clientHub.snapshotClients();
			foreach (ws; clientsSnapshot)
			{
				if (ws is null)
					continue;
				clientHub.remove(ws);
				if (ws.state.disconnectable)
					ws.disconnect("shutting down");
			}
		}
		auto server = transport is null ? null : transport.server;
		if (server)
		{
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
		}
		auto mcpServer = transport is null ? null : transport.mcpServer;
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
		if (configWatcher !is null)
			configWatcher.stop();
		infof("shutdown() complete");
	}

	private void onWebSocketAccepted(WebSocketAdapter ws)
	{
		clientHub.add(ws);
		ws.send(Data(buildWorkspacesList(discoveryService.workspacesInfo).representation));
		ws.send(Data(buildTaskTypesList(
			taskTypeCatalog.getTaskTypes(),
			taskTypeCatalog.getEntryPoints(),
			config.default_task_type,
		).representation));
		ws.send(Data(buildAgentsList(snapshotAgentEntries(), config.default_agent).representation));
		ws.send(Data(buildTasksList(tasks).representation));
		ws.send(Data(buildServerStatus(
			authUser.length > 0 || authPass.length > 0,
			config.dev_mode,
			webDistDir,
		).representation));
		ws.send(Data(buildNoticesList(activeNotices).representation));
		if (discoveryService.scanInProgress)
			ws.send(Data(toJson(ScanStatusMessage("scan_status", true)).representation));
		foreach (payload; agentUsageTracker.snapshotMessages())
			ws.send(Data(payload.representation));
	}

	private void onWebSocketDisconnected(WebSocketAdapter ws, string reason, DisconnectType type)
	{
		clientHub.remove(ws);
	}

	private RawSourceLookupResult lookupRawSource(int tid, size_t seq)
	{
		if (tid !in tasks)
			return RawSourceLookupResult(RawSourceLookupStatus.taskNotFound, null);

		auto td = &tasks[tid];
		historyPipeline.ensureHistoryLoaded(tid);
		if (seq >= td.history.length)
			return RawSourceLookupResult(RawSourceLookupStatus.seqOutOfRange, null);

		return RawSourceLookupResult(RawSourceLookupStatus.ok, td.history.rawAt(seq));
	}

	private bool interruptForPendingContinuation(string tidStr)
	{
		import std.conv : to;

		int parsedTid;
		try
			parsedTid = to!int(tidStr);
		catch (Exception)
			return false;

		auto tdp = parsedTid in tasks;
		if (tdp is null || tdp.pendingContinuation is null)
			return false;

		tdp.processQueue.setGoal(ProcessState.Dead).ignoreResult();
		tdp.session.interrupt();
		return true;
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
	ValidatedTask handleCreateTask(string callerTid, int specIndex,
		string description, string taskType, string prompt)
	{
		import ae.utils.json : toJson;
		import std.algorithm : canFind, map;
		import std.array : join;
		import std.conv : to;

		McpResult structuredTaskError(string message)
		{
			auto taskResultJson = toJson(TaskResult(
				summary: message,
				error: message,
				status: "error",
			));
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
		auto parentTypeDef = taskTypeCatalog.getTaskTypesForProject(parentTd.projectPath).byName(parentTd.taskType);
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
		auto childTypeDef = taskTypeCatalog.getTaskTypesForProject(parentTd.projectPath).byName(resolvedTaskType);
		if (childTypeDef is null)
			return ValidatedTask(structuredTaskError("Unknown task type: " ~ resolvedTaskType));

		// Resolve the child's agent (may differ from parent via agent: field)
		auto childAgent = resolveAgent(childTypeDef.agent, parentTd.agentType);
		if (childAgent.length == 0 || !isRegisteredAgent(childAgent))
			return ValidatedTask(structuredTaskError(format(
				"task type '%s' resolves agent to '%s' (parent='%s') — not a registered agent",
				resolvedTaskType, childAgent, parentTd.agentType)));

		// All validation passed — return a delegate that performs the actual creation.
		// Capture only simple values; re-fetch pointers at launch time to avoid
		// stale AA pointers if sibling delegates caused reallocation.
		return ValidatedTask(McpResult.init, () {
			auto pd = parentTid in tasks;
			auto ptd = taskTypeCatalog.getTaskTypesForProject(pd.projectPath).byName(pd.taskType);
			auto ctd = taskTypeCatalog.getTaskTypesForProject(pd.projectPath).byName(resolvedTaskType);

			// Create child task
			auto childTid = createTask(pd.workspace, pd.projectPath, childAgent);
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
			clientHub.broadcast(toJson(TaskCreatedMessage("task_created", childTid,
				pd.workspace, pd.projectPath, parentTid, "subtask")));
			broadcastTaskUpdate(childTid);
			broadcastFocusHint(parentTid, childTid);

			// Inject cydo/task_spawned into parent's event stream so the frontend
			// can show an "Open task →" link without any side-channel state.
			{
				import cydo.agent.protocol : CydoTaskSpawnedEvent, TranslatedEvent;
				import ae.utils.time.types : AbsTime;
				import std.datetime : Clock;
				CydoTaskSpawnedEvent spawnEv;
				spawnEv.child_tid  = childTid;
				spawnEv.spec_index = specIndex;
				historyPipeline.appendAndBroadcastTaskEvent(parentTid,
					TranslatedEvent(toJson(spawnEv), null, AbsTime(Clock.currStdTime)));
			}

			// Set up worktree from edge config: create new or inherit from parent
			string edgeTemplate;
			if (ptd !is null)
			{
				if (auto edge = ptd.creatable_tasks.byName(taskType))
				{
					edgeTemplate = edge.prompt_template;
					childTd.resultNote = substituteVars(edge.result_note,
						["output_dir": taskDir(pd)]);
					setupWorktreeForEdge(childTid, parentTid, edge.worktree);
				}
			}

			// Configure and spawn child agent
			auto renderedPrompt = renderPrompt(*ctd, prompt, taskTypeCatalog.promptSearchPath(childTd.projectPath), outputPath(childTd), edgeTemplate);
			renderedPrompt = prependTaskFraming(renderedPrompt,
				taskSystemPromptForMessage(childTid, ctd),
				loadProjectMemory(ctd, childTd.repoPath, taskTypeCatalog.promptSearchPath(childTd.projectPath)));
			// Encode edge identity in subject: "<parentType> -> <edgeName>".
			// When ptd has no creatable_tasks (degenerate), fall back to no-arrow form.
			auto parentTypeForSubject = (ptd !is null && ptd.creatable_tasks.length > 0) ? pd.taskType : "";
			auto taskPromptMsgSubject = taskPromptSubject(parentTypeForSubject, taskType);
			auto subtaskMeta = buildKnownSystemMessageMeta(
				KnownSystemMessageKind.taskPrompt,
				taskPromptMsgSubject,
				["task_description": prompt], "task_description");
			tasks[childTid].processQueue.setGoal(ProcessState.Alive).then(() {
				sendTaskMessage(childTid, [ContentBlock("text", wrapKnownSystemMessage(
					config.system_keyword,
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

		auto parentTypeDef = taskTypeCatalog.getTaskTypesForProject(parentTd.projectPath).byName(parentTd.taskType);
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

		auto treeReadOnly = taskTypeCatalog.treeReadOnlyFor(parentTd.projectPath);
		auto childRO = resolvedType in treeReadOnly;
		return childRO is null || !(*childRO);
	}

	private McpResult makeInternalBatchError(string message)
	{
		errorf("batch router error: %s", message);
		return McpResult("Internal batch routing error: " ~ message, true);
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
		if (!batchRegistry.create(parentTid, childTids, handle, batchError))
			return resolve(makeInternalBatchError(batchError));

		foreach (i, ref launchedTask; launchedTasks)
		{
			(BatchHandle h, size_t slot, int cTid, Promise!McpResult promise) {
				promise.then((McpResult r) {
					string error;
					if (!batchRegistry.enqueueChildDone(h, slot, cTid, r, error))
						errorf("batch router error: %s", error);
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
		auto handle = BatchHandle(parentTid, batchId);
		if (!batchRegistry.exists(handle))
			return resolve(makeInternalBatchError(
				format!"no active batch for parent tid=%d batch=%s"(parentTid, batchId)));

		while (true)
		{
			Promise!BatchSignal event;
			string batchError;
			if (!batchRegistry.waitOne(handle, event, batchError))
			{
				if (batchError.length > 0)
					return resolve(makeInternalBatchError(batchError));
				break;
			}

			auto sig = event.await();
			auto consumed = batchRegistry.consume(handle, sig,
				(int childTid, int qid) => questionRouter.childHasPendingQuestion(childTid, qid),
				batchError);
			if (batchError.length > 0)
				return resolve(makeInternalBatchError(batchError));

			final switch (consumed.kind)
			{
				case BatchConsumeKind.ignored:
					break;
				case BatchConsumeKind.childDone:
					break;
				case BatchConsumeKind.question:
					// Return question to parent agent — parent answers via Answer,
					// which re-enters this same batch instance.
					return resolve(questionRouter.buildQuestionResult(
						consumed.childTid, consumed.qid, consumed.questionText));
				case BatchConsumeKind.invalid:
					errorf("ignoring invalid batch signal for parent=%d batch=%s: %s",
						parentTid, batchId, consumed.error);
					break;
			}
		}

		McpResult[] results;
		string batchError;
		if (!batchRegistry.finalize(handle, results, batchError))
			return resolve(makeInternalBatchError(batchError));

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

		auto typeDef = taskTypeCatalog.getTaskTypesForProject(td.projectPath).byName(td.taskType);
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

		auto typeDef = taskTypeCatalog.getTaskTypesForProject(td.projectPath).byName(td.taskType);
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
		int pendingChildTid;
		string pendingQuestion;
		int pendingQid;
		if (findPendingChildQuestion(tid, pendingChildTid, pendingQuestion, pendingQid))
			return McpResult(
				"Handoff cannot continue while sub-task question qid="
				~ to!string(pendingQid)
				~ " is waiting for your answer. "
				~ "Use mcp__cydo__Answer(...) first, or mcp__cydo__SwitchMode if you need a different mode before answering.",
				true);

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
		auto taskTypes = taskTypeCatalog.getTaskTypesForProject(tdp.projectPath);
		auto typeDef = taskTypes.byName(tdp.taskType);
		if (typeDef is null || !taskTypes.isInteractive(taskTypeCatalog.getEntryPointsForProject(tdp.projectPath), tdp.taskType))
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
		clientHub.sendToSubscribed(tid, Data(msg.representation));

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
		import std.conv : to;

		int tid;
		try
			tid = to!int(callerTid);
		catch (Exception)
			return resolve(McpResult("Invalid calling task ID", true));

		auto td = tid in tasks;
		if (td is null)
			return resolve(McpResult("Task not found", true));

		string[] args;
		if (td.launch.cmdPrefix !is null)
			args = td.launch.cmdPrefix ~ ["/bin/sh", "-c", command];
		else
			args = ["/bin/sh", "-c", command];

		string workDir;
		if (td.launch.cmdPrefix is null && td.launch.workDir.length > 0)
			workDir = td.launch.workDir;

		auto terminal = new TerminalProcess(
			args,
			null,   // inherit env
			workDir,
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

	private string taskWorkspaceLabel(ref TaskData td)
	{
		if (td.workspace.length > 0)
			return td.workspace;
		if (td.projectPath.length > 0)
			return td.projectPath;
		return "(none)";
	}

	private bool workspaceHasProjectPath(string workspaceName, string projectPath)
	{
		if (workspaceName.length == 0 || projectPath.length == 0)
			return false;
		foreach (ref wi; discoveryService.workspacesInfo)
		{
			if (wi.name != workspaceName)
				continue;
			foreach (ref project; wi.projects)
				if (project.path == projectPath)
					return true;
			break;
		}
		return false;
	}

	private void discoveredWorkspacesForProjectPath(string projectPath, ref bool[string] names)
	{
		if (projectPath.length == 0)
			return;
		foreach (ref wi; discoveryService.workspacesInfo)
		{
			foreach (ref project; wi.projects)
			{
				if (project.path == projectPath)
				{
					names[wi.name] = true;
					break;
				}
			}
		}
	}

	private bool tasksShareWorkspace(ref TaskData a, ref TaskData b)
	{
		if (a.workspace.length > 0 && b.workspace.length > 0)
			return a.workspace == b.workspace;

		if (a.workspace.length > 0 || b.workspace.length > 0)
		{
			auto pinnedWorkspace = a.workspace.length > 0 ? a.workspace : b.workspace;
			auto unpinnedProjectPath = a.workspace.length == 0 ? a.projectPath : b.projectPath;
			return workspaceHasProjectPath(pinnedWorkspace, unpinnedProjectPath);
		}

		bool[string] aWorkspaces;
		bool[string] bWorkspaces;
		discoveredWorkspacesForProjectPath(a.projectPath, aWorkspaces);
		discoveredWorkspacesForProjectPath(b.projectPath, bWorkspaces);
		foreach (wsName, _; aWorkspaces)
			if (wsName in bWorkspaces)
				return true;

		// Legacy fallback for tasks created before workspace pinning.
		return a.projectPath.length > 0 && a.projectPath == b.projectPath;
	}

	Promise!McpResult handleAsk(string callerTidStr, string message, int targetTid)
	{
		return questionRouter.handleAsk(callerTidStr, message, targetTid);
	}

	Promise!McpResult handleAnswer(string callerTidStr, int qid, string message)
	{
		return questionRouter.handleAnswer(callerTidStr, qid, message);
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
		clientHub.sendToSubscribed(tid, Data(toJson(PermissionPromptMessage("permission_prompt",
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

		// Don't clean up deps if there's any live batch (Answer may re-enter one)
		bool hasLiveBatches;
		string batchError;
		if (!batchRegistry.parentHasLiveBatches(tid, hasLiveBatches, batchError))
		{
			errorf("batch router invariant violated: %s", batchError);
			return;
		}
		if (hasLiveBatches)
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
		clientHub.sendToSubscribed(tid, Data(toJson(AskUserQuestionMessage("ask_user_question",
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
		clientHub.sendToSubscribed(tid, Data(toJson(PermissionPromptMessage("permission_prompt",
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
			case "set_agent_name":   handleSetAgentNameMsg(json); break;
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
		if (taskTypeCatalog.getTaskTypesForProject(tasks[tid].projectPath).byName(json.task_type) is null) return;
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
		auto ep = taskTypeCatalog.getEntryPointsForProject(tasks[tid].projectPath).byName(json.entry_point);
		if (ep is null) return;
		auto td = &tasks[tid];
		td.entryPoint = json.entry_point;
		persistence.setEntryPoint(tid, td.entryPoint);
		td.taskType = ep.resolvedType;
		persistence.setTaskType(tid, td.taskType);
		broadcastTaskUpdate(tid);
	}

	private void handleSetAgentNameMsg(WsMessage json)
	{
		auto tid = json.tid;
		if (tid < 0 || tid !in tasks) return;
		if (tasks[tid].alive) return; // can't change type of a running task
		if (json.agent_name.length == 0) return;
		// config.agents always contains at least the three driver names (overlay in commit 1).
		bool found = false;
		foreach (name; config.agents.byKey)
			if (name == json.agent_name) { found = true; break; }
		if (!found) return;
		tasks[tid].agentType = json.agent_name;
		persistence.setAgentType(tid, json.agent_name);
		broadcastTaskUpdate(tid);
	}

	private void handleCreateTaskMsg(WebSocketAdapter ws, WsMessage json)
	{
		auto at = json.agent_name.length > 0 ? json.agent_name : defaultAgentName(json.workspace);
		// Top-level user task creation must always come through a concrete entry point.
		// Internal tasks (subtasks, continuations, imports) are created through other paths.
		auto entryPoints = taskTypeCatalog.getEntryPointsForProject(json.project_path);
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
		auto taskTypes = taskTypeCatalog.getTaskTypesForProject(json.project_path);
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
				auto rendered = renderPrompt(*typeDef, textContent, taskTypeCatalog.promptSearchPath(td.projectPath), outputPath(td), epTemplate);
				rendered = prependTaskFraming(rendered,
					taskSystemPromptForMessage(tid, typeDef),
					loadProjectMemory(typeDef, td.repoPath, taskTypeCatalog.promptSearchPath(td.projectPath)));
				auto sessionStartMsgName = td.entryPoint.length > 0 ? td.entryPoint : td.taskType;
				sessionStartMsgSubject = sessionStartSubject(sessionStartMsgName);
				// Preserve image blocks alongside the rendered text prompt.
				messageToSend = ContentBlock("text", wrapKnownSystemMessage(
					config.system_keyword,
					KnownSystemMessageKind.sessionStart, rendered, sessionStartMsgSubject))
					~ blocks.filter!(b => b.type == "image").array;
			}
			auto msgContent = blocks;
			auto msgMeta = typeDef !is null
				? buildKnownSystemMessageMeta(
					KnownSystemMessageKind.sessionStart,
					sessionStartMsgSubject,
					["task_description": textContent], "task_description")
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

	private void handleRequestHistory(WebSocketAdapter ws, WsMessage json)
	{
		historyPipeline.handleRequestHistory(ws, json.tid);
	}

	private void sendHistoryReplaySupplementalState(WebSocketAdapter ws, int tid)
	{
		import ae.utils.json : toJson;

		auto td = tid in tasks;
		assert(td !is null, format!"History replay tail requested for missing task %d"(tid));

		if (td.isProcessing && td.hasLastSessionStatus)
		{
			ws.send(Data(toJson(TaskEventEnvelope(tid, td.lastSessionStatusTs,
				JSONFragment(td.lastSessionStatus))).representation));
		}

		if (td.lastSuggestions.length > 0)
			ws.send(Data(toJson(SuggestionsUpdateMessage("suggestions_update", tid,
				td.lastSuggestions)).representation));

		if (tid in pendingAskUserQuestions && td.pendingAskToolUseId.length > 0)
		{
			ws.send(Data(toJson(AskUserQuestionMessage("ask_user_question", tid,
				td.pendingAskToolUseId, td.pendingAskQuestions)).representation));
		}

		if (tid in pendingPermissionPrompts && td.pendingPermissionToolUseId.length > 0)
		{
			ws.send(Data(toJson(PermissionPromptMessage("permission_prompt", tid,
				td.pendingPermissionToolUseId, td.pendingPermissionToolName,
				td.pendingPermissionInput)).representation));
		}
	}

	private void onHistorySubscribed(int tid)
	{
		auto td = tid in tasks;
		assert(td !is null, format!"History subscribe callback for missing task %d"(tid));

		if (td.suggestGenHandle is null && td.lastSuggestions.length == 0 && td.status == "alive")
		{
			try
				generateSuggestions(tid);
			catch (Exception e)
				warningf("Error generating suggestions on subscribe: %s", e.msg);
		}
	}

	private void ensureHistoryAgentSessionIdFromEvent(int tid, string line)
	{
		if (line.length == 0 || tid !in tasks || tasks[tid].agentSessionId.length > 0)
			return;
		tryExtractAgentSessionId(tid, line);
	}

	private HistoryBroadcastPlan planHistoryBroadcast(int tid, TranslatedEvent ev)
	{
		import std.algorithm : canFind, startsWith;

		HistoryBroadcastPlan plan;
		plan.currentEvent = ev;

		auto td = tid in tasks;
		if (td is null)
			return plan;

		if (isCompactionReminderEchoEvent(plan.currentEvent.translated))
			td.compactionReminderInFlight = true;
		auto shouldSendCompactionReminder =
			isCompactionReminderTriggerRaw(plan.currentEvent.raw)
			|| isCompactionReminderTriggerEvent(plan.currentEvent.translated);
		if (shouldSendCompactionReminder)
			maybeSendCompactionReminderSteering(tid);

		if (isQueueOperation(plan.currentEvent.translated))
		{
			auto op = jsonParse!QueueOperationProbe(plan.currentEvent.translated);
			if (op.operation == "enqueue")
			{
				if (op.content.startsWith(systemMessagePrefix(
					config.system_keyword,
					KnownSystemMessageKind.postCompactionTaskModeReminder)))
					td.compactionReminderInFlight = true;
				td.enqueueSteering(op.content, plan.currentEvent.translated);
				plan.consumeCurrent = true;
				return plan;
			}

			if ((op.operation == "dequeue" || op.operation == "remove")
				&& td.hasPendingDequeuedSteering())
			{
				string pendingText, pendingRaw;
				if (td.popPendingDequeuedSteering(pendingText, pendingRaw))
				{
					auto pendingSteeringEv = buildSyntheticUserEvent(pendingText, true);
					plan.prependedEvents ~= TranslatedEvent(
						toJsonWithSyntheticUserMeta(pendingText, pendingSteeringEv, tid),
						pendingRaw.length > 0 ? pendingRaw : null,
						plan.currentEvent.ts);
				}
			}

			if (op.operation == "dequeue")
			{
				string text, enqueueRaw;
				if (td.popSteering(text, enqueueRaw))
					td.setPendingDequeuedSteering(text, enqueueRaw);
				else
					td.clearPendingDequeuedSteering();
				plan.consumeCurrent = true;
				return plan;
			}
			else if (op.operation == "remove")
			{
				string text, enqueueRaw;
				if (td.popSteering(text, enqueueRaw))
				{
					auto steeringEv = buildSyntheticUserEvent(text, true);
					plan.prependedEvents ~= TranslatedEvent(
						toJsonWithSyntheticUserMeta(text, steeringEv, tid),
						enqueueRaw.length > 0 ? enqueueRaw : null,
						plan.currentEvent.ts);
				}
				plan.consumeCurrent = true;
				return plan;
			}

			plan.consumeCurrent = true;
			return plan;
		}

		if (td.hasPendingDequeuedSteering())
		{
			auto ta = agentForTask(tid);
			if (plan.currentEvent.raw.length > 0 && ta.isAssistantMessageLine(plan.currentEvent.raw))
			{
				string pendingText, pendingRaw;
				if (td.popPendingDequeuedSteering(pendingText, pendingRaw))
				{
					auto steeringEv = buildSyntheticUserEvent(pendingText, true);
					plan.prependedEvents ~= TranslatedEvent(
						toJsonWithSyntheticUserMeta(pendingText, steeringEv, tid),
						pendingRaw.length > 0 ? pendingRaw : null,
						plan.currentEvent.ts);
				}
			}
			else if (plan.currentEvent.translated.canFind(`"type":"item/started"`)
				&& plan.currentEvent.translated.canFind(`"item_type":"user_message"`))
			{
				@JSONPartial static struct SteeringEchoProbe
				{
					string type;
					string item_type;
					@JSONOptional bool is_steering;
					@JSONOptional string uuid;
				}
				try
				{
					auto probe = jsonParse!SteeringEchoProbe(plan.currentEvent.translated);
					if (probe.type == "item/started"
						&& probe.item_type == "user_message"
						&& probe.is_steering)
					{
						if (probe.uuid.length > 0 && !probe.uuid.startsWith("enqueue-"))
						{
							import cydo.agent.protocol : ItemStartedEvent;
							auto userEv = jsonParse!ItemStartedEvent(plan.currentEvent.translated);
							userEv.uuid = null;
							plan.currentEvent.translated = toJson(userEv);
						}
						td.clearPendingDequeuedSteering();
					}
				}
				catch (Exception)
				{
				}
			}
		}

		if (isCompactionReminderSteerFailureEvent(plan.currentEvent.translated))
			td.compactionReminderInFlight = false;

		if (td.pendingUserNonce.length > 0
			&& plan.currentEvent.translated.canFind(`"type":"item/started"`)
			&& plan.currentEvent.translated.canFind(`"item_type":"user_message"`))
		{
			@JSONPartial static struct UserMsgTagProbe
			{
				string type;
				string item_type;
				@JSONOptional bool is_replay;
				@JSONOptional bool is_meta;
				@JSONOptional bool pending;
			}
			try
			{
				auto probe = jsonParse!UserMsgTagProbe(plan.currentEvent.translated);
				if (probe.type == "item/started"
					&& probe.item_type == "user_message"
					&& !probe.is_replay && !probe.is_meta && !probe.pending)
				{
					auto taggedNonce = td.pendingUserNonce;
					td.pendingUserNonce = null;
					plan.currentEvent.translated = plan.currentEvent.translated[0 .. $ - 1]
						~ `,"correlation_id":` ~ toJson(taggedNonce) ~ `}`;
				}
			}
			catch (Exception)
			{
			}
		}

		return plan;
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

		// Deduplicate: ignore a message whose nonce we've already processed.
		if (json.correlation_id.length > 0)
		{
			if (json.correlation_id in td.recentNonces)
				return;
			td.recentNonces[json.correlation_id] = true;
		}

		ContentBlock[] blocks;
		if (json.content.json !is null)
			blocks = jsonParse!(ContentBlock[])(json.content.json);
		auto textContent = extractContentText(blocks);

		// Wrap first message in prompt template (e.g. conversation.md)
		auto messageToSend = blocks;
		string userMsgMeta;
		if (td.description.length == 0)
		{
			materializePendingTask(tid);
			auto typeDef = taskTypeCatalog.getTaskTypesForProject(td.projectPath).byName(td.taskType);
			if (typeDef !is null)
			{
				import std.algorithm : filter;
				import std.array : array;
				string entryPointTemplate;
				if (td.entryPoint.length > 0)
				{
					auto ep = taskTypeCatalog.getEntryPointsForProject(td.projectPath).byName(td.entryPoint);
					if (ep !is null)
						entryPointTemplate = ep.prompt_template;
				}
				auto rendered = renderPrompt(*typeDef, textContent, taskTypeCatalog.promptSearchPath(td.projectPath),
					outputPath(td), entryPointTemplate);
				rendered = prependTaskFraming(rendered,
					taskSystemPromptForMessage(tid, typeDef),
					loadProjectMemory(typeDef, td.repoPath, taskTypeCatalog.promptSearchPath(td.projectPath)));
				auto sessionStartMsgName = td.entryPoint.length > 0 ? td.entryPoint : td.taskType;
				auto sessionStartMsgSubject = sessionStartSubject(sessionStartMsgName);
				// Preserve image blocks alongside the rendered text prompt.
				messageToSend = ContentBlock("text", wrapKnownSystemMessage(
					config.system_keyword,
					KnownSystemMessageKind.sessionStart, rendered, sessionStartMsgSubject))
					~ blocks.filter!(b => b.type == "image").array;
				// Attach metadata so the frontend can render this as a collapsible system message.
				userMsgMeta = buildKnownSystemMessageMeta(
					KnownSystemMessageKind.sessionStart,
					sessionStartMsgSubject,
					["task_description": textContent], "task_description");
			}
		}
		td.lastSuggestions = null;
		auto msgNonce = json.correlation_id;
		td.processQueue.setGoal(ProcessState.Alive).then(() {
			auto td = &tasks[tid];
			if (td.status == "alive")
			{
				td.status = "active";
				persistence.setStatus(tid, "active");
			}
			sendTaskMessage(tid, messageToSend, blocks, userMsgMeta, msgNonce);
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
			clientHub.sendToSubscribed(tid, draftData);
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
		return archiveManager.isTransitioning(tid);
	}

	private void handleSetArchivedMsg(WebSocketAdapter ws, WsMessage json)
	{
		bool archived = json.content.json == `"true"`;
		archiveManager.handleSetArchived(ws, json.tid, archived);
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
		clientHub.sendToSubscribedExcept(tid, senderWs, data);
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
		clientHub.unsubscribeAll(tid);
		// Remove from in-memory state
		tasks.remove(tid);
		// Remove from database
		persistence.deleteTask(tid);
		// Broadcast deletion to all clients
		clientHub.broadcast(toJson(TaskDeletedMessage("task_deleted", tid)));
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
			auto sourcePath = ta.historyPath(td.agentSessionId, effectiveCwd(td));
			if (sourcePath.length == 0)
			{
				ws.send(Data(toJson(ErrorMessage("error",
					"Fork failed: task history file not found", tid)).representation));
				return;
			}

			auto childTid = createForkTask(persistence, tid, "", td.projectPath, td.workspace,
				td.title, td.description, td.taskType, td.agentType);

			auto newTd = TaskData(childTid, td.workspace, td.projectPath);
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
			tasks[childTid].history.reset(Watermark.none()); // No JSONL yet; updated in .then() after fork

			auto childAgent = agentForTask(childTid);
			auto childTypeDef = taskTypeCatalog.getTaskTypesForProject(tasks[childTid].projectPath).byName(tasks[childTid].taskType);
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
						makeProcessQueueSF(childTid),
						ProcessState.Dead,
					);
					tasks[childTid].archiveQueue = new StateQueue!ArchiveState(
						makeArchiveQueueSF(childTid),
						ArchiveState.Unarchived,
					);
					// Fork JSONL now exists: update the watermark so ensureHistoryLoaded
					// reads the correct post-fork byte range.
					{
						auto jp = childAgent.historyPath(outcome.threadId,
							effectiveCwd(&tasks[childTid]));
						tasks[childTid].history.reset(watermarkFromPath(jp));
					}

					clientHub.broadcast(toJson(TaskCreatedMessage("task_created", childTid, td.workspace,
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
				sid == td.agentSessionId ? effectiveCwd(td) : td.projectPath),
			&ta.rewriteSessionId, &ta.forkIdMatchesLine,
			td.description, td.taskType, td.agentType);
		if (result.tid < 0)
		{
			ws.send(Data(toJson(ErrorMessage("error",
				"Fork failed: message UUID not found in task history", tid)).representation));
			return;
		}

		auto newTd = TaskData(result.tid, td.workspace, td.projectPath);
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
			makeProcessQueueSF(result.tid),
			ProcessState.Dead,
		);
		tasks[result.tid].archiveQueue = new StateQueue!ArchiveState(
			makeArchiveQueueSF(result.tid),
			ArchiveState.Unarchived,
		);
		{
			auto jp = ta.historyPath(result.agentSessionId, effectiveCwd(&tasks[result.tid]));
			tasks[result.tid].history.reset(watermarkFromPath(jp));
		}

		clientHub.broadcast(toJson(TaskCreatedMessage("task_created", result.tid, td.workspace, td.projectPath, tid, "fork")));
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

				auto jsonlPath = ta.historyPath(td.agentSessionId, effectiveCwd(td));
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
				ta.historyPath(td.agentSessionId, effectiveCwd(td)), json.after_uuid,
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
					import cydo.agent.codex : CodexActiveUserTurnsAfterStatus, CodexSession,
						countActiveUserTurnsAfterForkId;

					auto codexSession = cast(CodexSession) td.session;
					if (codexSession is null || !codexSession.canRollbackThread)
					{
						fallbackUndoKillAndTruncate(ws, tid, json);
						return;
					}

					auto jsonlPath = ta.historyPath(td.agentSessionId, effectiveCwd(td));
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
							{
								auto jp = ta.historyPath(td2.agentSessionId, effectiveCwd(td2));
								td2.history.reset(watermarkFromPath(jp));
							}
							clientHub.unsubscribeAll(tid);

							// Reset JSONL tracker so it re-reads fork IDs
							jsonlTracker.stopJsonlWatch(tid);

							// Clip pendingSteeringTexts to match remaining user messages
							if (td2.pendingSteeringTexts.length > 0)
							{
								import std.file : readText, exists;
								auto histPath = ta.historyPath(td2.agentSessionId, effectiveCwd(td2));
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
		auto jsonlPathSnap = ta.historyPath(td.agentSessionId, effectiveCwd(td));
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

		td.undoStopInProgress = true;
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
				historyPipeline.ensureHistoryLoaded(tid);
				rewindUuid = td.checkpointUuidForAnchor(json.after_uuid);
			}

			if (rewindUuid.length > 0 && !rewindUuid.startsWith("enqueue-"))
			{
				auto rewindResult = ta.rewindFiles(td.agentSessionId, rewindUuid, effectiveCwd(td), td.launch);
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
			auto lastForkId = lastForkIdInJsonl(ta.historyPath(td.agentSessionId, effectiveCwd(td)),
				&ta.extractForkableIds);
			if (lastForkId.length > 0)
			{
				auto backup = forkTask(persistence, tid, td.agentSessionId, lastForkId,
					td.projectPath, td.workspace, td.title,
					(string sid) => ta.historyPath(sid,
						sid == td.agentSessionId ? effectiveCwd(td) : td.projectPath),
					&ta.rewriteSessionId, &ta.forkIdMatchesLine,
					td.description, td.taskType, td.agentType);
				if (backup.tid >= 0)
				{
					auto bTd = TaskData(backup.tid, td.workspace, td.projectPath);
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
						makeProcessQueueSF(backup.tid),
						ProcessState.Dead,
					);
					tasks[backup.tid].archiveQueue = new StateQueue!ArchiveState(
						makeArchiveQueueSF(backup.tid),
						ArchiveState.Unarchived,
					);
					{
							auto jp = ta.historyPath(backup.agentSessionId, effectiveCwd(&tasks[backup.tid]));
							tasks[backup.tid].history.reset(watermarkFromPath(jp));
						}
					clientHub.broadcast(toJson(TaskCreatedMessage("task_created", backup.tid, td.workspace, td.projectPath, tid, "undo-backup")));
					broadcastTaskUpdate(backup.tid);
				}
			}
		}

		// 3. Truncate conversation history
		if (json.revert_conversation)
		{
			auto histJsonlPath = ta.historyPath(td.agentSessionId, effectiveCwd(td));
			auto removed = truncateJsonl(histJsonlPath, json.after_uuid, &ta.forkIdMatchesLine, true);
			if (removed < 0)
			{
				ws.send(Data(toJson(ErrorMessage("error", "UUID not found for truncation", tid)).representation));
				return;
			}
			td.history.reset(watermarkFromPath(histJsonlPath));
			clientHub.unsubscribeAll(tid);
			// Clip pendingSteeringTexts to match remaining user messages in the
			// truncated JSONL. Without this, ensureHistoryLoaded would re-emit
			// synthetics for messages that were intentionally undone.
			if (td.pendingSteeringTexts.length > 0)
			{
				import std.file : readText, exists;
				import std.string : splitLines;
				auto histPath = ta.historyPath(td.agentSessionId, effectiveCwd(td));
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
		auto jsonlPath = ta.historyPath(td.agentSessionId, effectiveCwd(td));
		auto newContent = json.content.json !is null ? jsonParse!string(json.content.json) : "";
		auto targetUuid = json.after_uuid;
		string fallbackUuid;
		if (targetUuid.startsWith("enqueue-"))
		{
			historyPipeline.ensureHistoryLoaded(tid);
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

		td.history.reset(watermarkFromPath(jsonlPath));
		clientHub.unsubscribeAll(tid);

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

		historyPipeline.ensureHistoryLoaded(tid);

		if (seq >= td.history.length || td.history.rawAt(seq) is null)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Seq out of range or no raw source", tid)).representation));
			return;
		}

		auto originalLine = td.history.rawAt(seq);
		auto ta = agentForTask(tid);
		auto jsonlPath = ta.historyPath(td.agentSessionId, effectiveCwd(td));
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

		td.history.reset(watermarkFromPath(jsonlPath));
		clientHub.unsubscribeAll(tid);

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
		const(ContentBlock)[] broadcastContent = null, string cydoMeta = null,
		string nonce = null)
	{
		sendPreparedTaskMessage(tid, content, broadcastContent, cydoMeta, true, nonce);
	}

	/// Send a prepared message to the agent and emit the matching pending UI echo.
	///
	/// System messages are ordinary prepared messages with a stable wrapper format
	/// and CyDo metadata for collapsed rendering.
	private void sendPreparedTaskMessage(int tid, const(ContentBlock)[] content,
		const(ContentBlock)[] broadcastContent = null, string cydoMeta = null,
		bool captureUndoSnapshot = true, string nonce = null)
	{
		import std.algorithm : min, filter;
		import std.array : array;

		auto td = &tasks[tid];
		assert(td.taskType.length > 0, "Task must have a task_type when sending a message");

		historyPipeline.appendUnconfirmedUserMessage(tid, content, broadcastContent,
			cydoMeta, nonce);

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
		td.session.sendMessage(toSend, nonce);
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
		return loadSystemPrompt(*typeDef, taskTypeCatalog.promptSearchPath(td.projectPath), outputPath(*td));
	}

	private static string prependTaskFraming(string promptText, string systemPrompt,
		string projectMemory = null)
	{
		string head;
		if (projectMemory.length > 0)
			head ~= projectMemory ~ "\n\n";
		if (systemPrompt.length > 0)
			head ~= "[TASK DESCRIPTION]\n" ~ systemPrompt
				~ "\n\n[END TASK DESCRIPTION]\n\n[TASK PROMPT]\n";
		if (head.length == 0)
			return promptText;
		return head ~ promptText;
	}

	unittest
	{
		import std.algorithm : canFind, countUntil;

		// system prompt alone — byte-for-byte matches old prependTaskSystemPrompt
		assert(prependTaskFraming("text", "sys") ==
			"[TASK DESCRIPTION]\nsys\n\n[END TASK DESCRIPTION]\n\n[TASK PROMPT]\ntext");
		// neither — no-op
		assert(prependTaskFraming("text", null, null) == "text");
		// memory alone — no [TASK PROMPT] wrapper
		assert(prependTaskFraming("text", null, "mem\n") ==
			"mem\n\n\ntext");
		// both — memory before task description, [TASK PROMPT] present
		auto both = prependTaskFraming("text", "sys", "mem\n");
		assert(both.canFind("mem\n"), both);
		assert(both.canFind("[TASK DESCRIPTION]"), both);
		assert(both.canFind("[TASK PROMPT]"), both);
		// memory precedes task description
		assert(both.countUntil("mem") < both.countUntil("[TASK DESCRIPTION]"), both);
	}

	/// Find the first child of tid that has an unanswered Ask question.
	/// Returns true if found; sets childTid, question, and qid via out params.
	private bool findPendingChildQuestion(int tid, out int childTid, out string question, out int qid)
	{
		string batchError;
		if (!batchRegistry.findFirstLiveChild(tid, (int cTid) {
			return cTid in tasks && tasks[cTid].pendingAskPromise !is null;
		}, childTid, batchError))
		{
			if (batchError.length > 0)
				errorf("batch router invariant violated: %s", batchError);
			return false;
		}
		question = tasks[childTid].pendingAskQuestion;
		qid = tasks[childTid].pendingAskQid;
		return true;
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
		// Use tid's projectPath for template lookup (the parent asking the question)
		auto reminderBody = readPromptFile("prompts/sub_task_waiting_for_answer.md",
			tasks[tid].projectPath, ["question": question, "qid": to!string(qid)]);
		if (reminderBody.length == 0)
			reminderBody = "Question: " ~ question ~ "\n\n"
				~ "Use mcp__cydo__Answer(" ~ to!string(qid)
				~ ", \"your answer\") to respond. You must answer before you can complete your turn.";
		auto reminder = wrapKnownSystemMessage(
			config.system_keyword,
			KnownSystemMessageKind.subTaskWaitingForAnswer,
			reminderBody,
			reminderSubject);
		auto reminderBlocks = [ContentBlock("text", reminder)];
		auto askReminderMeta = buildKnownSystemMessageMeta(
			KnownSystemMessageKind.subTaskWaitingForAnswer,
			reminderSubject,
			["question": question], "question");
		sendTaskMessage(tid, reminderBlocks, null, askReminderMeta);
	}

	private string buildKnownSystemMessageMeta(KnownSystemMessageKind kind, string subject = null,
		string[string] vars = null, string bodyVar = null)
	{
		auto resolvedSubject = subject.length > 0 ? subject : systemMessageSubject(kind);
		KnownSystemMessageMatch match;
		auto label = tryKnownSystemMessageMatch(resolvedSubject, match)
			? match.label
			: resolvedSubject;
		return buildCydoMeta(label, vars, bodyVar, bodyMarkdownForKind(kind));
	}

	private bool tryExtractSystemMessageSubject(string text, out string subject)
	{
		return tryExtractSubject(config.system_keyword, text, subject);
	}

	/// Return the template variable name that holds the body content for a given
	/// kind, or null if the kind produces label-only meta.
	private static string bodyVarForKind(KnownSystemMessageKind kind)
	{
		switch (kind)
		{
		case KnownSystemMessageKind.taskPrompt:
		case KnownSystemMessageKind.sessionStart:
		case KnownSystemMessageKind.handoff:
			return "task_description";
		case KnownSystemMessageKind.followUpFromParent:
		case KnownSystemMessageKind.questionFromTask:
			return "message";
		case KnownSystemMessageKind.subTaskWaitingForAnswer:
			return "question";
		default:
			return null;
		}
	}

	/// Whether the body of a known-system-message of this kind should be rendered
	/// as Markdown.
	///
	/// Rule: Markdown for content originating from an LLM/agent or a .md prompt
	/// file; plain text for content typed by the user. `sessionStart` is the only
	/// kind whose body is user-typed (the user's first message wrapped into a
	/// session-start system message); everything else carries agent-generated content.
	private static bool bodyMarkdownForKind(KnownSystemMessageKind kind)
	{
		final switch (kind)
		{
		case KnownSystemMessageKind.taskPrompt:
		case KnownSystemMessageKind.followUpFromParent:
		case KnownSystemMessageKind.questionFromTask:
		case KnownSystemMessageKind.subTaskWaitingForAnswer:
		case KnownSystemMessageKind.handoff:
			return true;
		case KnownSystemMessageKind.sessionStart:
			return false;
		case KnownSystemMessageKind.missingRequiredOutputs:
		case KnownSystemMessageKind.subTaskResults:
		case KnownSystemMessageKind.restartNudge:
		case KnownSystemMessageKind.postCompactionTaskModeReminder:
		case KnownSystemMessageKind.modeSwitch:
			return false; // label-only kinds — no body, value is unused
		}
	}

	/// Resolve (sourceType, edgeName) → prompt-template path using the same
	/// project-scoped task-type config the renderer used.
	/// Returns null when the edge can't be resolved (renamed/removed/legacy).
	private string resolveEdgePromptTemplate(string projectPath,
		KnownSystemMessageKind kind, string sourceType, string edgeName)
	{
		switch (kind)
		{
		case KnownSystemMessageKind.taskPrompt:
			if (sourceType.length == 0 || edgeName.length == 0) return null;
			auto parentDef = taskTypeCatalog.getTaskTypesForProject(projectPath).byName(sourceType);
			if (parentDef is null) return null;
			auto edge = parentDef.creatable_tasks.byName(edgeName);
			return edge !is null ? edge.prompt_template : null;

		case KnownSystemMessageKind.sessionStart:
			if (edgeName.length == 0) return null;
			auto ep = taskTypeCatalog.getEntryPointsForProject(projectPath).byName(edgeName);
			return ep !is null ? ep.prompt_template : null;

		case KnownSystemMessageKind.handoff:
		case KnownSystemMessageKind.modeSwitch:
			if (sourceType.length == 0 || edgeName.length == 0) return null;
			auto srcDef = taskTypeCatalog.getTaskTypesForProject(projectPath).byName(sourceType);
			if (srcDef is null) return null;
			if (edgeName == "on_yield")
				return srcDef.on_yield.prompt_template;
			if (auto contP = edgeName in srcDef.continuations)
				return contP.prompt_template;
			return null;

		case KnownSystemMessageKind.followUpFromParent:
			return "prompts/follow_up_from_parent.md";

		case KnownSystemMessageKind.questionFromTask:
			return "prompts/question_from_task.md";

		case KnownSystemMessageKind.subTaskWaitingForAnswer:
			return "prompts/sub_task_waiting_for_answer.md";

		default:
			return null;
		}
	}

	/// Read a prompt template file from the search path without variable substitution.
	private string readTemplateText(string templateName, string projectPath)
	{
		import std.file : exists, readText;
		import std.path : buildPath;

		foreach (dir; taskTypeCatalog.promptSearchPath(projectPath))
		{
			auto path = buildPath(dir, templateName);
			if (exists(path))
				return readText(path);
		}
		return null;
	}

	/// Reverse-extract meta from a known-system-message user event by matching
	/// the rendered body against the template that produced it.
	/// tid is used to look up the project path for template resolution.
	private string cydoMetaForKnownSystemSubject(int tid, string subject, string text)
	{
		KnownSystemMessageMatch match;
		if (!tryKnownSystemMessageMatch(subject, match))
			return null;

		auto bodyVar = bodyVarForKind(match.kind);
		if (bodyVar is null)
			return buildCydoMeta(match.label);

		ParsedSystemFraming framing;
		if (!tryParseSystemFraming(config.system_keyword, text, framing))
			return buildCydoMeta(match.label);

		auto inner = stripTaskSystemPromptWrapper(framing.body);

		string projectPath = (tid in tasks) ? tasks[tid].projectPath : null;
		auto templatePath = resolveEdgePromptTemplate(projectPath, match.kind,
			match.sourceType, match.edgeName);
		if (templatePath.length == 0)
			return buildCydoMeta(match.label);

		auto templateText = readTemplateText(templatePath, projectPath);
		if (templateText.length == 0)
		{
			warningf("template '%s' not found on prompt search path; falling back to label-only meta",
				templatePath);
			return buildCydoMeta(match.label);
		}

		if (templateText !in compiledTemplateCache)
			compiledTemplateCache[templateText] = compileTemplate(templateText);
		auto compiled = compiledTemplateCache[templateText];

		string[string] vars;
		if (!tryMatchTemplate(compiled, inner, vars))
			return buildCydoMeta(match.label);

		string[string] bodyVars;
		if (auto v = bodyVar in vars)
			bodyVars[bodyVar] = *v;

		return buildCydoMeta(match.label, bodyVars, bodyVar,
			bodyMarkdownForKind(match.kind));
	}

	/// Inject agent_name into session/init events whose translation pipeline
	/// didn't have per-task agent name (history replay paths).
	private string injectAgentNameIntoSessionInit(string translated, string agentName)
	{
		import std.algorithm : canFind;
		import cydo.agent.protocol : SessionInitEvent;

		if (translated.length == 0
			|| agentName.length == 0
			|| !translated.canFind(`"type":"session/init"`))
			return translated;

		SessionInitEvent ev;
		try
			ev = jsonParse!SessionInitEvent(translated);
		catch (Exception)
			return translated;

		if (ev.agent_name.length > 0)
			return translated;

		ev.agent_name = agentName;
		return toJson(ev);
	}

	private string normalizeKnownSystemMessageMeta(string translated, int tid = -1)
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

		auto meta = cydoMetaForKnownSystemSubject(tid, subject, text);
		if (meta.length == 0)
			return translated;
		return translated[0 .. $ - 1] ~ `,"meta":` ~ meta ~ `}`;
	}

	private string buildPostCompactionReminder(int tid)
	{
		if (tid !in tasks)
			return null;
		auto td = &tasks[tid];
		auto typeDef = taskTypeCatalog.getTaskTypesForProject(td.projectPath).byName(td.taskType);

		auto systemPrompt = taskSystemPromptForMessage(tid, typeDef);
		if (systemPrompt.length == 0)
			return null;
		auto body = "[CYDO TASK MODE REMINDER]\n\n"
			~ "This is CyDo task metadata, not project or user content.\n\n"
			~ "Active task mode: " ~ td.taskType
			~ "\n\n[TASK DESCRIPTION]\n" ~ systemPrompt
			~ "\n[END TASK DESCRIPTION]\n\n"
			~ "Use this as the active CyDo task mode metadata for interpreting what kind of work to do next.\n\n";
		return wrapKnownSystemMessage(config.system_keyword,
			KnownSystemMessageKind.postCompactionTaskModeReminder, body);
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
		return text.startsWith(systemMessagePrefix(config.system_keyword,
			KnownSystemMessageKind.postCompactionTaskModeReminder));
	}

	private string toJsonWithSyntheticUserMeta(string text, ItemStartedEvent ev, int tid = -1)
	{
		import std.algorithm : startsWith;

		auto translated = toJson(ev);
		return text.startsWith("[" ~ config.system_keyword ~ ":")
			? normalizeKnownSystemMessageMeta(translated, tid)
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

	private static bool pathIsUnderRoot(string path, string root)
	{
		import std.algorithm : startsWith;
		return root.length > 0 && (path == root || path.startsWith(root ~ "/"));
	}

	private string workspaceRootForTask(int tid, string workspace, string projectPath)
	{
		if (workspace.length > 0)
		{
			auto wsRoot = findWorkspaceRoot(workspace);
			if (wsRoot.length == 0)
				throw new Exception(format!"Cannot resolve task_dir for task %d: unknown workspace '%s'"(tid, workspace));
			return wsRoot;
		}

		string matchedRoot;
		if (projectPath.length > 0)
			foreach (ref ws; config.workspaces)
				if (pathIsUnderRoot(projectPath, ws.root))
				{
					if (matchedRoot.length > 0 && matchedRoot != ws.root)
						throw new Exception(format!"Cannot resolve task_dir for task %d: project path '%s' matches multiple workspace roots ('%s' and '%s')"(
							tid, projectPath, matchedRoot, ws.root));
					matchedRoot = ws.root;
				}
		if (matchedRoot.length > 0)
			return matchedRoot;

		throw new Exception(format!"Cannot resolve task_dir for task %d: missing workspace_root"(tid));
	}

	private string resolveTaskDirForTask(int tid, string workspace, string projectPath)
	{
		auto repoPath = resolveProjectRepoPath(projectPath);
		auto wsRoot = workspaceRootForTask(tid, workspace, projectPath);
		return resolveTaskDir(tid, workspace, wsRoot, projectPath, repoPath, taskDirTemplate);
	}

	/// Resolve a task's directory on demand. Throws if the task lacks the
	/// workspace metadata needed to compute the path — operations that need
	/// taskDir fail fast at the point of use, while tasks that only sit in
	/// the in-memory map (legacy completed runs, importable rows that haven't
	/// been activated) can still be loaded.
	private string taskDir(ref const TaskData td)
	{
		return resolveTaskDirForTask(td.tid, td.workspace, td.projectPath);
	}

	private string taskDir(const TaskData* td)
	{
		if (td is null)
			throw new Exception("TaskData pointer must not be null");
		return taskDir(*td);
	}

	/// Resolve a task's output.md path on demand.
	private string outputPath(ref const TaskData td)
	{
		return outputPathForTaskDir(taskDir(td));
	}

	private string outputPath(const TaskData* td)
	{
		if (td is null)
			throw new Exception("TaskData pointer must not be null");
		return outputPath(*td);
	}

	/// Best-effort variant for code that runs over every task and must
	/// tolerate legacy rows that can't resolve a workspace. Returns "" on
	/// failure instead of throwing.
	private string tryTaskDir(ref const TaskData td)
	{
		try
			return taskDir(td);
		catch (Exception)
			return "";
	}

	private bool tryGetArchiveTask(int tid, out ArchiveTaskSnapshot task)
	{
		auto td = tid in tasks;
		if (td is null)
			return false;
		task = ArchiveTaskSnapshot(td.tid, td.parentTid, td.archived, td.archiving,
			td.alive, td.workspace, td.projectPath);
		return true;
	}

	private ArchiveTaskSnapshot[int] snapshotArchiveTasks()
	{
		ArchiveTaskSnapshot[int] snapshot;
		foreach (tid, ref td; tasks)
			snapshot[tid] = ArchiveTaskSnapshot(td.tid, td.parentTid, td.archived,
				td.archiving, td.alive, td.workspace, td.projectPath);
		return snapshot;
	}

	private string tryResolveArchiveTaskDir(int tid, string workspace, string projectPath)
	{
		try
			return resolveTaskDirForTask(tid, workspace, projectPath);
		catch (Exception)
			return "";
	}

	private bool updateArchiveTaskState(int tid, bool archived, bool archiving)
	{
		auto td = tid in tasks;
		if (td is null)
			return false;
		td.archived = archived;
		td.archiving = archiving;
		return true;
	}

	private void sendArchiveError(WebSocketAdapter ws, int tid, string message)
	{
		ws.send(Data(toJson(ErrorMessage("error", message, tid)).representation));
	}

	private DiscoveryTaskSnapshot[int] snapshotDiscoveryTasks()
	{
		DiscoveryTaskSnapshot[int] snapshot;
		foreach (tid, ref td; tasks)
			snapshot[tid] = DiscoveryTaskSnapshot(
				tid,
				td.parentTid,
				td.status,
				td.agentSessionId,
				td.agentType,
				td.projectPath,
			);
		return snapshot;
	}

	private void withDiscoveryMutationTransaction(scope void delegate() work)
	{
		persistence.db.db.exec("BEGIN TRANSACTION;");
		scope(success) persistence.db.db.exec("COMMIT TRANSACTION;");
		scope(failure) persistence.db.db.exec("ROLLBACK TRANSACTION;");
		work();
	}

	private string importableHistoryPath(int tid)
	{
		auto td = tid in tasks;
		assert(td !is null, format!"Importable task %d not found"(tid));
		return agentForTask(tid).historyPath(td.agentSessionId, effectiveCwd(td));
	}

	private void deleteImportableTask(int tid)
	{
		tasks.remove(tid);
		persistence.deleteTask(tid);
		clientHub.broadcast(toJson(TaskDeletedMessage("task_deleted", tid)));
	}

	private void createImportableTask(ImportableTaskSpec spec)
	{
		auto tid = createTask("", spec.projectPath, spec.agentName);
		auto td = &tasks[tid];
		td.status = "importable";
		td.agentSessionId = spec.sessionId;
		td.title = spec.title;
		td.lastActive = spec.lastActive;
		{
			Watermark wm;
			auto importTa = tryAgentForTask(tid);
			if (importTa)
			{
				auto jp = importTa.historyPath(spec.sessionId, spec.projectPath);
				wm = watermarkFromPath(jp);
			}
			td.history.reset(wm);
		}
		persistence.setStatus(tid, "importable");
		persistence.setAgentSessionId(tid, spec.sessionId);
		persistence.setTitle(tid, spec.title);
		persistence.setLastActive(tid, spec.lastActive);

		clientHub.broadcast(toJson(TaskCreatedMessage("task_created", tid, "", spec.projectPath, 0, "")));
		broadcastTaskUpdate(tid);
	}

	private void broadcastDiscoveryWorkspaces(WorkspaceInfo[] workspaces)
	{
		clientHub.broadcast(buildWorkspacesList(workspaces));
	}

	private void broadcastDiscoveryScanStatus(bool active)
	{
		clientHub.broadcast(toJson(ScanStatusMessage("scan_status", active)));
	}

	private string worktreePath(const TaskData* td)
	{
		if (td is null)
			throw new Exception("TaskData pointer must not be null");
		if (td.worktreeTid <= 0)
			return "";

		auto ownerTd = td.worktreeTid in tasks;
		if (ownerTd is null)
			throw new Exception(format!"Task %d references missing worktree owner task %d"(td.tid, td.worktreeTid));
		return worktreePathForTaskDir(taskDir(ownerTd));
	}

	private string effectiveCwd(const TaskData* td)
	{
		if (td is null)
			throw new Exception("TaskData pointer must not be null");
		return td.effectiveCwd(worktreePath(td));
	}

	private void setTaskWorktreeTid(int tid, int worktreeTid)
	{
		auto td = tid in tasks;
		if (td is null)
			throw new Exception(format!"Task %d not found while setting worktree owner %d"(tid, worktreeTid));
		td.worktreeTid = worktreeTid;
		persistence.setWorktreeTid(tid, worktreeTid);
	}

	private int createTask(string workspace = "", string projectPath = "", string agentName = "",
		string entryPoint = "")
	{
		auto tid = persistence.createTask(workspace, projectPath, agentName, entryPoint);
		auto td = TaskData(tid, workspace, projectPath);
		td.agentType = agentName;
		td.entryPoint = entryPoint;
		td.history.reset(Watermark.none()); // New tasks have no JSONL to load
		import std.datetime : Clock;
		td.createdAt = Clock.currStdTime;
		td.lastActive = td.createdAt;
		tasks[tid] = move(td);
		tasks[tid].processQueue = new StateQueue!ProcessState(
			makeProcessQueueSF(tid),
			ProcessState.Dead,
		);
		tasks[tid].archiveQueue = new StateQueue!ArchiveState(
			makeArchiveQueueSF(tid),
			ArchiveState.Unarchived,
		);
		return tid;
	}

	/// Return the Agent instance for a task's agent name, creating it on demand.
	/// Returns null if the agent name isn't in config (orphan task).
	private Agent tryAgentForTask(int tid)
	{
		auto td = &tasks[tid];
		if (auto p = td.agentType in agentsByName)
			return *p;
		auto a = tryCreateAgentByName(td.agentType);
		if (!a)
			return null;
		if (auto ac = td.agentType in config.agents)
			a.setModelAliases(ac.model_aliases);
		{
			import cydo.agent.copilot : CopilotAgent;
			if (auto ca = cast(CopilotAgent) a)
				ca.toolDispatch_ = (string tool, string callerTid, JSONFragment args) =>
					dispatchTool(tool, callerTid, args);
		}
		agentsByName[td.agentType] = a;
		return a;
	}

	/// Like tryAgentForTask but throws if the agent type isn't registered.
	/// Use this in happy-path code that has already established the task's
	/// agent is configured; orphan-aware code should call tryAgentForTask
	/// and null-check.
	private Agent agentForTask(int tid)
	{
		auto a = tryAgentForTask(tid);
		if (!a)
			throw new Exception("Unknown agent type: " ~ tasks[tid].agentType);
		return a;
	}

	/// Create an Agent by registered driver enum. Throws if registry doesn't know the driver.
	private static Agent createAgentByDriver(AgentDriver driver)
	{
		import cydo.agent.registry : agentRegistry;
		import std.conv : to;
		auto driverName = to!string(driver);
		foreach (ref entry; agentRegistry)
			if (entry.name == driverName)
				return entry.create();
		throw new Exception("Unknown driver: " ~ driverName);
	}

	/// Create an Agent by user-chosen agent name (config.agents key).
	/// Returns null if the name isn't in config.agents.
	private Agent tryCreateAgentByName(string agentName)
	{
		auto ac = agentName in config.agents;
		if (!ac)
			return null;
		return createAgentByDriver(ac.driver.value);
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

		auto ep = taskTypeCatalog.getEntryPointsForProject(td.projectPath).byName(td.entryPoint);
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
		setTaskWorktreeTid(childTid, parentTd.worktreeTid);
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
				setTaskWorktreeTid(childTid, ancestorTd.worktreeTid);
				return;
			}
			current = ancestorTd.parentTid;
		}
		// No ancestor has a worktree — create one at the root task's directory
		int rootTid = findRootTid(childTid);
		auto rootTd = rootTid in tasks;
		if (rootTd is null)
			throw new Exception(format!"Root task %d not found while creating required worktree for task %d"(rootTid, childTid));

		import std.file : exists, mkdirRecurse;
		auto rootTaskDir = taskDir(rootTd);
		auto wtPath = worktreePathForTaskDir(rootTaskDir);
		if (!exists(wtPath))
		{
			mkdirRecurse(rootTaskDir);
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
		setTaskWorktreeTid(childTid, rootTid);
	}

	/// Fork: create a new isolated worktree for this task.
	private void setupWorktreeFork(int childTid, int parentTid)
	{
		auto td = &tasks[childTid];
		if (td.worktreeTid > 0)
			return;

		import std.file : mkdirRecurse;
		import std.process : execute;

		auto childTaskDir = taskDir(*td);
		mkdirRecurse(childTaskDir);
		auto wtPath = worktreePathForTaskDir(childTaskDir);

		// Determine base: parent's worktree if available, else project dir
		auto parentTd = parentTid in tasks;
		string baseFrom;
		if (parentTd !is null && parentTd.worktreeTid > 0)
			baseFrom = worktreePath(parentTd);
		auto workDir = baseFrom.length > 0 ? baseFrom : (td.projectPath.length > 0 ? td.projectPath : null);

		auto gitResult = execute(["git", "-C", workDir, "worktree", "add", "--detach", wtPath]);
		if (gitResult.status == 0)
		{
			setTaskWorktreeTid(childTid, childTid);  // owns its own worktree
			infof("Created fork worktree for task %d: %s", childTid, wtPath);
		}
		else
			errorf("Failed to create fork worktree for task %d: %s", childTid, gitResult.output);
	}

	private TaskSessionLaunch prepareTaskSessionLaunch(int tid, Agent taskAgent,
		TaskTypeDef* typeDef)
	{
		return taskSessionRunner.prepareTaskSessionLaunch(tid, taskAgent, typeDef);
	}

	private void spawnTaskSession(int tid)
	{
		taskSessionRunner.spawnTaskSession(tid);
	}

	/// Returns a stateFunc delegate bound to a specific tid.
	/// Using a helper function (rather than an inline lambda in a foreach) avoids
	/// the D closure-capture bug where all loop iterations share the same `rowTid`.
	private Promise!ProcessState delegate(ProcessState) makeProcessQueueSF(int tid)
	{
		return taskSessionRunner.makeProcessQueueSF(tid);
	}

	/// Returns an archive transition stateFunc bound to a specific tid.
	/// Using a helper function (rather than an inline lambda in a foreach) avoids
	/// the D closure-capture bug where all loop iterations share the same `tid`.
	private Promise!ArchiveState delegate(ArchiveState) makeArchiveQueueSF(int tid)
	{
		return archiveManager.makeQueueStateFunc(tid);
	}

	private Promise!ProcessState processTransition(int tid, ProcessState goal)
	{
		return taskSessionRunner.processTransition(tid, goal);
	}

	/// Execute a continuation transition — shared by explicit (SwitchMode/Handoff)
	/// and implicit (on_yield) paths.
	/// edgeName is the YAML map key (or "on_yield") that identifies this edge.
	private void executeContinuation(int tid, ContinuationDef contDef, string handoffPrompt,
		string edgeName)
	{
		import ae.utils.json : toJson;

		auto td = &tasks[tid];

		auto newTypeDef = taskTypeCatalog.getTaskTypesForProject(td.projectPath).byName(contDef.task_type);
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
			// Capture source type before mutating td.taskType
			auto sourceTaskType = td.taskType;

			// Mutate task type in-place, resume the same session
			td.taskType = contDef.task_type;
			persistence.setTaskType(tid, contDef.task_type);

			// Notify frontends to re-request history
			emitTaskReload(tid, "continuation");

			td.status = "active";
			persistence.setStatus(tid, "active");

			// Send the continuation's prompt template as first message to successor.
			auto renderedContinuationPrompt = renderContinuationPrompt(contDef,
				"Continue from where you left off.", taskTypeCatalog.promptSearchPath(td.projectPath),
				["result_text": resultText, "output_dir": taskDir(*td)]);
			renderedContinuationPrompt = "`SwitchMode` to `" ~ edgeName
				~ "` successful.\n\n" ~ renderedContinuationPrompt;
			renderedContinuationPrompt = prependTaskFraming(
				renderedContinuationPrompt, taskSystemPromptForMessage(tid, newTypeDef),
				loadProjectMemory(newTypeDef, td.repoPath, taskTypeCatalog.promptSearchPath(td.projectPath)));
			auto modeSwitchMsgSubject = modeSwitchSubject(sourceTaskType, edgeName);
			auto contMeta = buildKnownSystemMessageMeta(KnownSystemMessageKind.modeSwitch,
				modeSwitchMsgSubject);
			td.processQueue.setGoal(ProcessState.Alive).then(() {
				sendTaskMessage(tid,
					[ContentBlock("text", wrapKnownSystemMessage(
						config.system_keyword,
						KnownSystemMessageKind.modeSwitch, renderedContinuationPrompt, modeSwitchMsgSubject))],
					null, contMeta);
				// If a child question is still pending (the agent switched modes before
				// answering), send the reminder now so the resumed mode can answer it.
				sendPendingChildAnswerReminder(tid);
			}).ignoreResult();
		}
		else
		{
			// Resolve successor's agent before committing to the transition.
			auto contAgent = resolveAgent(newTypeDef.agent, td.agentType);
			if (contAgent.length == 0 || !isRegisteredAgent(contAgent))
			{
				td.status = "failed";
				td.error = format(
					"Successor type '%s' resolved agent to '%s' (parent='%s') — not a registered agent",
					contDef.task_type, contAgent, td.agentType);
				persistence.setStatus(tid, "failed");
				historyPipeline.appendSynthesizedHistoryError(tid, "Continuation failed", td.error);
				broadcastTaskUpdate(tid);
				return;
			}

			// Complete the current task normally (preserving its history),
			// then create a new child task for the successor.
			td.status = "completed";
			persistence.setStatus(tid, "completed");

			// Notify frontends to re-request history
			emitTaskReload(tid, "continuation");

			// Create child task for the successor with the handoff prompt
			auto successorPrompt = handoffPrompt.length > 0 ? handoffPrompt : td.description;
			auto childTid = createTask(td.workspace, td.projectPath, contAgent);
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

			clientHub.broadcast(toJson(TaskCreatedMessage("task_created", childTid,
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
				taskTypeCatalog.promptSearchPath(childTd.projectPath), outputPath(*childTd), contDef.prompt_template,
				["result_text": resultText]);
			renderedSuccessorPrompt = prependTaskFraming(renderedSuccessorPrompt,
				taskSystemPromptForMessage(childTid, newTypeDef),
				loadProjectMemory(newTypeDef, childTd.repoPath, taskTypeCatalog.promptSearchPath(childTd.projectPath)));
			auto handoffMsgSubject = handoffSubject(td.taskType, edgeName);
			auto handoffMeta = buildKnownSystemMessageMeta(KnownSystemMessageKind.handoff,
				handoffMsgSubject, ["task_description": successorPrompt], "task_description");
			tasks[childTid].processQueue.setGoal(ProcessState.Alive).then(() {
				sendTaskMessage(childTid, [ContentBlock("text", wrapKnownSystemMessage(
					config.system_keyword,
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
		auto typeDef = taskTypeCatalog.getTaskTypesForProject(td.projectPath).byName(td.taskType);
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

		executeContinuation(tid, *contDefP, hPrompt, contKey);
	}

	private void spawnOnYieldContinuation(int tid)
	{
		auto td = tid in tasks;
		assert(td !is null, format!"Task %d not found for on_yield continuation"(tid));

		auto onYieldDef = taskTypeCatalog.getTaskTypesForProject(td.projectPath)
			.byName(td.taskType);
		assert(onYieldDef !is null && onYieldDef.on_yield.task_type.length > 0,
			format!"Task %d has no on_yield continuation"(tid));

		executeContinuation(tid, onYieldDef.on_yield, td.resultText, "on_yield");
	}

	private void sendAgentAck(int tid, string nonce)
	{
		if (nonce.length == 0)
			return;
		auto ackEnv = AgentAckEnvelope(tid, nonce);
		clientHub.sendToSubscribed(tid, Data(toJson(ackEnv).representation));
	}

	private void broadcastAppendedTaskEvent(int tid, string translated)
	{
		import std.datetime : Clock;

		if (translated.length == 0)
			return;
		clientHub.sendToSubscribed(tid, Data(
			toJson(TaskEventEnvelope(tid, Clock.currStdTime,
				JSONFragment(translated))).representation));
	}

	private void touchAndPersistLastActive(int tid)
	{
		if (tid !in tasks)
			return;
		touchTask(tid);
		persistence.setLastActive(tid, tasks[tid].lastActive);
	}

	private void onTaskTurnCompletedAlive(int tid)
	{
		if (tid !in tasks)
			return;
		auto td = &tasks[tid];
		td.status = "alive";
		persistence.setStatus(tid, "alive");
		td.needsAttention = true;
		persistence.setNeedsAttention(tid, true);
		td.notificationBody = td.resultText.length > 0
			? truncateTitle(td.resultText, 200)
			: extractLastAssistantText(tid);
		touchAndPersistLastActive(tid);
		try
			generateSuggestions(tid);
		catch (Exception e)
			warningf("Error generating suggestions: %s", e.msg);
	}

	private bool drainIdleCallbacksForTurnResult(int tid)
	{
		if (tid !in tasks)
			return false;
		auto td = &tasks[tid];
		if (td.onIdleCallbacks.length == 0)
			return false;

		auto callbacks = td.onIdleCallbacks.dup;
		td.onIdleCallbacks = null;
		foreach (cb; callbacks)
			cb();

		if (tid !in tasks)
			return false;
		td = &tasks[tid];
		return td.status == "active" || td.status == "alive";
	}

	private void drainIdleCallbacksOnExit(int tid)
	{
		if (tid !in tasks)
			return;
		auto td = &tasks[tid];
		if (td.onIdleCallbacks.length == 0)
			return;

		auto callbacks = td.onIdleCallbacks.dup;
		td.onIdleCallbacks = null;
		foreach (cb; callbacks)
			cb();
	}

	private bool hasPendingSubTask(int tid)
	{
		return (tid in pendingSubTasks) !is null;
	}

	private bool hasTaskDependency(int tid)
	{
		return (tid in taskDeps) !is null;
	}

	private bool hasPendingChildQuestion(int tid)
	{
		int childTid;
		string question;
		int qid;
		return findPendingChildQuestion(tid, childTid, question, qid);
	}

	private void failPendingAskUserQuestionOnExit(int tid)
	{
		if (tid !in tasks)
			return;
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
	}

	private void failPendingPermissionPromptOnExit(int tid)
	{
		if (tid !in tasks)
			return;
		if (auto permPending = tid in pendingPermissionPrompts)
		{
			permPending.fulfill(McpResult(makePermissionDenyJson("Task exited"), false));
			pendingPermissionPrompts.remove(tid);
			pendingPermissionInputs.remove(tid);
			tasks[tid].pendingPermissionToolUseId = null;
			tasks[tid].pendingPermissionToolName = null;
			tasks[tid].pendingPermissionInput = JSONFragment.init;
		}
	}

	private void failPendingAskRouteOnExit(int tid)
	{
		if (tid !in tasks)
			return;
		if (tasks[tid].pendingAskPromise !is null && tasks[tid].pendingAskQid > 0)
			questionRouter.failQuestionRoute(tasks[tid].pendingAskQid,
				"Session ended while waiting for Ask response");
	}

	private void cancelExitBackgroundWork(int tid)
	{
		if (tid !in tasks)
			return;
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
	}

	private void resetHistoryWatermarkAfterExit(int tid)
	{
		resetHistoryWatermark(tid, true);
	}

	private void resetHistoryWatermarkOnly(int tid)
	{
		resetHistoryWatermark(tid, false);
	}

	private void resetHistoryWatermark(int tid, bool unsubscribeSubscribers)
	{
		if (tid !in tasks)
			return;
		auto ta = tryAgentForTask(tid);
		{
			Watermark wm;
			if (ta && tasks[tid].agentSessionId.length > 0)
			{
				auto jp = ta.historyPath(tasks[tid].agentSessionId, effectiveCwd(&tasks[tid]));
				wm = watermarkFromPath(jp);
			}
			tasks[tid].history.reset(wm);
		}
		if (unsubscribeSubscribers)
			clientHub.unsubscribeAll(tid);
	}

	private void requestMissingOutputs(int tid, string missing)
	{
		if (tid !in tasks)
			return;
		auto enfMissing = missing;
		tasks[tid].processQueue.setGoal(ProcessState.Alive).then(() {
			auto msg = wrapKnownSystemMessage(config.system_keyword,
				KnownSystemMessageKind.missingRequiredOutputs,
				"Your task type declares outputs that were not produced:\n"
					~ enfMissing ~ "\n\n"
					~ "Please produce the missing output(s) before finishing. "
					~ "Write your report to your output file if you haven't already.");
			auto outputsMeta = buildKnownSystemMessageMeta(
				KnownSystemMessageKind.missingRequiredOutputs);
			sendTaskMessage(tid, [ContentBlock("text", msg)], null, outputsMeta);
		}).ignoreResult();
	}

	private bool deliverFailedPendingSubTaskResult(int tid)
	{
		import ae.utils.json : toJson;

		auto pending = tid in pendingSubTasks;
		if (pending is null)
			return false;

		auto taskResult = buildTaskResult(tid);
		auto resultJson = toJson(taskResult);
		pending.fulfill(McpResult.structured(resultJson, true));
		pendingSubTasks.remove(tid);
		// Deps left intact — cleaned by onToolCallDelivered() on success,
		// or used by deliverBatchResults() as fallback if MCP delivery fails.
		return true;
	}

	private void deliverWaitingParentResultsIfReady(int tid)
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
				auto parentTid = *parentTidPtr;
				tracef("onExit Branch B: child tid=%d (status=%s) finished, parent tid=%d",
					tid, tasks[tid].status, parentTid);
				if (parentTid in tasks)
				{
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
				}
				else
					tracef("onExit Branch B: parent tid=%d not in tasks", parentTid);
			}
		}
	}

	private void loadPersistedTaskDeps()
	{
		foreach (parentTid, children; persistence.loadTaskDeps())
			foreach (childTid; children)
				taskDeps[childTid] = parentTid;
	}

	private int[] snapshotTaskIdsForResume()
	{
		int[] tids;
		foreach (tid, ref td; tasks)
			tids ~= tid;
		return tids;
	}

	private bool waitingTaskChildrenAllDone(int tid)
	{
		foreach (childTid, parentTid; taskDeps)
			if (parentTid == tid && childTid in tasks
				&& tasks[childTid].status != "completed"
				&& tasks[childTid].status != "failed"
				&& tasks[childTid].status != "importable")
			{
				tracef("resumeInFlightTasks: tid=%d waiting, child tid=%d still %s",
					tid, childTid, tasks[childTid].status);
				return false;
			}

		return true;
	}

	private string defaultAgentName(string workspaceName)
	{
		foreach (ref ws; config.workspaces)
			if (ws.name == workspaceName && ws.default_agent.length > 0)
				return ws.default_agent;
		if (config.default_agent.length > 0)
			return config.default_agent;
		// Post-overlay agentsByName is non-empty; fall through to first key.
		foreach (name, _; agentsByName)
			return name;
		throw new Exception("no agents configured");
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

	private SandboxConfig findAgentSandbox(string agentName)
	{
		if (config.agents !is null)
			if (auto ac = agentName in config.agents)
				return ac.sandbox;
		return SandboxConfig.init;
	}

	/// Returns the HEAD SHA of the worktree (or main checkout) that the
	/// caller's worktree was forked from, by walking up `td`'s parent chain
	/// past any ancestors that share the same `worktreeTid`. Returns "" if
	/// no suitable ancestor is found or git fails.
	private string getWorktreeForkBaseHead(ref TaskData td)
	{
		import std.process : execute;
		import std.string : strip;

		string forkPath;
		int current = td.parentTid;
		while (current > 0 && current in tasks)
		{
			auto ancestor = &tasks[current];
			if (td.worktreeTid > 0 && ancestor.worktreeTid == td.worktreeTid)
			{
				current = ancestor.parentTid;
				continue;
			}
			if (ancestor.hasWorktree && ancestor.worktreeTid != td.worktreeTid)
				forkPath = worktreePath(ancestor);
			else
				forkPath = ancestor.projectPath;
			break;
		}
		if (forkPath.length == 0)
			forkPath = td.projectPath;
		if (forkPath.length == 0)
			return "";

		auto result = execute(["git", "-C", forkPath, "rev-parse", "HEAD"]);
		if (result.status != 0)
		{
			warningf("getWorktreeForkBaseHead: git rev-parse HEAD failed in %s: %s", forkPath, result.output);
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
		auto typeDef = taskTypeCatalog.getTaskTypesForProject(td.projectPath).byName(td.taskType);
		if (typeDef is null || typeDef.output_type.length == 0)
			return null;

		string[] missing;

		foreach (ot; typeDef.output_type)
		{
			final switch (ot)
			{
			case OutputType.report:
				auto tdOut = outputPath(*td);
				if (tdOut.length == 0 || !exists(tdOut))
					missing ~= "report (expected at " ~ tdOut ~ ")";
				break;

			case OutputType.worktree:
				if (!td.hasWorktree)
				{
					missing ~= "worktree (no worktree)";
					break;
				}
				{
					auto wtPath = worktreePath(td);
					auto parentHead = getWorktreeForkBaseHead(*td);
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
					auto wtPath = worktreePath(td);
					auto statusResult = execute(["git", "-C", wtPath, "status", "--porcelain"]);
					if (statusResult.status == 0 && statusResult.output.strip.length > 0)
					{
						missing ~= "commit (worktree has uncommitted changes"
							~ " — commit all changes before finishing)\n"
							~ "git status:\n" ~ statusResult.output.strip;
						break;
					}
					auto parentHead = getWorktreeForkBaseHead(*td);
					if (parentHead.length == 0)
					{
						missing ~= "commit (could not determine parent HEAD)";
						break;
					}
					auto logResult = execute(["git", "-C", wtPath, "log",
						"--oneline", parentHead ~ "..HEAD"]);
					if (logResult.status != 0 || logResult.output.strip.length == 0)
						missing ~= "commit (no commits in this worktree that aren't already in "
							~ "the parent worktree at " ~ parentHead[0 .. min(8, $)]
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
		auto tdOut = outputPath(*td);
		bool hasOutput = tdOut.length > 0 && exists(tdOut);
		bool hasWorktree = td.hasWorktree;
		bool isFailed = td.status == "failed";
		auto summary = td.resultText;
		auto talkNote = " Use mcp__cydo__Ask(question, " ~ to!string(tid) ~ ") to ask follow-up questions.";
		string note;
		if (hasOutput && hasWorktree)
			note = "Read the output file for full findings. The worktree path is included for adopting changes." ~ talkNote;
		else if (hasOutput)
			note = "Read the output file for full findings." ~ talkNote;
		else if (hasWorktree)
			note = "The worktree contains the implementation." ~ talkNote;
		auto result = TaskResult(
			summary: summary,
			output_file: hasOutput ? tdOut : null,
			worktree: hasWorktree ? worktreePath(td) : null,
			note: note.length > 0 ? note : td.resultNote,
			error: isFailed ? summary : null,
			status: isFailed ? "error" : "success",
		);
		result.tid = tid;

		// For commit output types, extract commit SHAs from the worktree.
		auto typeDef = taskTypeCatalog.getTaskTypesForProject(td.projectPath).byName(td.taskType);
		if (typeDef !is null && typeDef.output_type.canFind(OutputType.commit) && td.hasWorktree)
		{
			auto parentHead = getWorktreeForkBaseHead(*td);
			if (parentHead.length > 0)
			{
				auto logResult = execute(["git", "-C", worktreePath(td),
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
		auto msg = wrapKnownSystemMessage(config.system_keyword,
			KnownSystemMessageKind.subTaskResults,
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
		taskSessionRunner.resumeInFlightTasks();
	}

	private Promise!void resumeTask(int tid)
	{
		return taskSessionRunner.resumeTask(tid);
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
			auto nudgeText = wrapKnownSystemMessage(config.system_keyword,
				KnownSystemMessageKind.restartNudge, nudgeBody);
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

	private int findRootTid(int tid)
	{
		return archiveManager.findRootTid(tid);
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
		taskSessionRunner.resumeAndDeliverResults(tid);
	}

	private void resumeWaitingTask(int tid)
	{
		taskSessionRunner.resumeWaitingTask(tid);
	}

	/// Resume an "active" task and send it a system nudge once alive.
	/// Using a helper function (rather than an inline lambda in a foreach) avoids
	/// the D closure-capture bug where all loop iterations share the same `tid`.
	private void resumeActiveTask(int tid)
	{
		taskSessionRunner.resumeActiveTask(tid);
	}

	/// Broadcast a task reload boundary and invalidate in-flight derived work.
	/// task_reload is a hard history-lineage boundary on the wire: clients are
	/// unsubscribed before it is sent, must discard pre-reload live assumptions,
	/// and must call request_history to subscribe to the new replayed lineage.
	private void emitTaskReload(int tid, string reason = "")
	{
		import ae.utils.json : toJson;

		if (tid !in tasks)
			return;
		clientHub.unsubscribeAll(tid);
		auto td = &tasks[tid];
		// Invalidate cached/in-flight suggestions so pre-reload content cannot replay.
		td.lastSuggestions = null;
		td.suggestGeneration++;
		if (td.suggestGenKill !is null)
			td.suggestGenKill();
		td.suggestGenHandle = null;
		td.suggestGenKill = null;
		clientHub.broadcast(toJson(TaskReloadMessage("task_reload", tid, reason)));
	}

	/// Wrap text in [SYSTEM: ...] tags so the agent knows the message is
	/// injected by CyDo, not typed by the user.
	private string wrapSystemMessage(string subject, string body = null)
	{
		import cydo.system.framing : wrapSystemMessageFn = wrapSystemMessage;
		return wrapSystemMessageFn(config.system_keyword, subject, body);
	}

	/// Build metadata JSON for a system-generated user message.
	/// The result is a JSON string (or null) to be injected as "meta" in the
	/// unconfirmed-user-event envelope. NOT sent to the agent.
	private string buildCydoMeta(string label, string[string] vars = null,
		string bodyVar = null, bool bodyMarkdown = false, string severity = null)
	{
		import ae.utils.json : JSONOptional, toJson;
		struct CydoMeta {
			string label;
			@JSONOptional string[string] vars;
			@JSONOptional string bodyVar;
			@JSONOptional bool bodyMarkdown;
			@JSONOptional string severity;
		}
		CydoMeta m;
		m.label = label;
		m.vars = vars;
		m.bodyVar = bodyVar;
		m.bodyMarkdown = bodyMarkdown;
		m.severity = severity;
		return toJson(m);
	}

	/// Build an `item/started` envelope JSON for a synthesized error system-message.
	private string synthesizeHistoryErrorEventJson(string subject, string body)
	{
		auto wrappedText = wrapSystemMessage(subject, body);
		ItemStartedEvent ev;
		ev.item_id   = "cydo-history-error";
		ev.item_type = "user_message";
		ev.text      = wrappedText;
		ev.content   = [ContentBlock("text", wrappedText)];
		ev.is_meta   = true;
		auto json = toJson(ev);
		auto meta = buildCydoMeta(subject, ["details": body], "details",
			true /*bodyMarkdown*/, "error" /*severity*/);
		return json[0 .. $ - 1] ~ `,"meta":` ~ meta ~ `}`;
	}

	private bool updateClaudeUsageFromEvent(int tid, string translated)
	{
		if (tid !in tasks)
			return false;

		string payload;
		auto changed = agentUsageTracker.updateFromClaudeEvent(
			tasks[tid].agentType, translated, payload);
		if (changed)
			clientHub.broadcast(payload);
		return changed;
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
		clientHub.broadcast(toJson(TitleUpdateMessage("title_update", tid, title)));
	}

	private void broadcastSuggestionsUpdate(int tid, string[] suggestions)
	{
		import ae.utils.json : toJson;
		clientHub.sendToSubscribed(tid, Data(toJson(
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

	private void onConfigChanged()
	{
		infof("Config file changed, reloading...");
		auto result = reloadRuntimeConfig();
		if (result.isNull())
		{
			warningf("Config reload failed (parse error), keeping current config");
			return;
		}
		auto oldAgents = config.agents;
		auto oldTaskDirTemplate = taskDirTemplate;
		config = result.get();
		applyConfiguredLogLevel(config.log_level);
		auto reloadedTaskDirTemplate = config.task_dir.length > 0
			? config.task_dir : defaultTaskDirTemplate;
		if (reloadedTaskDirTemplate != oldTaskDirTemplate)
			warningf("Config task_dir changed; restart CyDo for the new task directory template to take effect");

		// Diff old vs new: keep entries whose driver and sandbox.env match; recreate otherwise.
		Agent[string] rebuilt;
		foreach (name, ref ac; config.agents)
		{
			bool reuseExisting = false;
			if (auto existing = name in agentsByName)
			{
				auto oldAcP = name in oldAgents;
				if (oldAcP && oldAcP.driver.value == ac.driver.value
					&& oldAcP.sandbox.env == ac.sandbox.env)
					reuseExisting = true;
				if (reuseExisting)
				{
					(*existing).setModelAliases(ac.model_aliases);
					rebuilt[name] = *existing;
				}
			}
			if (!reuseExisting)
			{
				auto a = createAgentByDriver(ac.driver.value);
				a.setModelAliases(ac.model_aliases);
				{
					import cydo.agent.copilot : CopilotAgent;
					if (auto ca = cast(CopilotAgent) a)
						ca.toolDispatch_ = (string tool, string callerTid, JSONFragment args) =>
							dispatchTool(tool, callerTid, args);
				}
				rebuilt[name] = a;
			}
		}
		agentsByName = rebuilt;
		auto defaultName = defaultAgentName("");
		agent = agentsByName[defaultName];

		taskTypeCatalog.invalidateAll();
		discoveryService.beginScan();
		discoveryService.discoverAllWorkspaces(config);
		clientHub.broadcast(buildAgentsList(snapshotAgentEntries(), config.default_agent));
		clientHub.broadcast(buildWorkspacesList(discoveryService.workspacesInfo));
		clientHub.broadcast(buildServerStatus(
			authUser.length > 0 || authPass.length > 0,
			config.dev_mode,
			webDistDir,
		));
		infof("Config reloaded successfully");
		discoveryService.endScan();
	}

	private void onProjectConfigChanged(string projectPath)
	{
		infof("Project config changed for %s, reloading task types...", projectPath);
		taskTypeCatalog.invalidateProject(projectPath);
		clientHub.broadcast(buildTaskTypesListForProject(
			projectPath,
			taskTypeCatalog.getTaskTypesForProject(projectPath),
			taskTypeCatalog.getEntryPointsForProject(projectPath),
		));
	}

	private void handleRefreshWorkspacesMsg()
	{
		discoveryService.discoverAllWorkspaces(config);
		clientHub.broadcast(buildWorkspacesList(discoveryService.workspacesInfo));
		discoveryService.enumerateSessions(config, agentsByName);
	}

	/// Read a prompt template file from the prompt search path and substitute variables.
	private string readPromptFile(string relativePath, string projectPath, string[string] vars)
	{
		import std.file : exists, readText;
		import std.path : buildPath;

		foreach (dir; taskTypeCatalog.promptSearchPath(projectPath))
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
			historyPipeline.broadcastTask(tid, TranslatedEvent(toJson(ev), null));
		}).ignoreResult();

	}

	private void touchTask(int tid)
	{
		import std.datetime : Clock;
		tasks[tid].lastActive = Clock.currStdTime;
	}

	private void broadcastTaskUpdate(int tid)
	{
		import ae.utils.json : toJson;

		clientHub.broadcast(toJson(TaskUpdatedMessage("task_updated", buildTaskEntry(tasks[tid]))));
	}

	private void broadcastFocusHint(int fromTid, int toTid)
	{
		import ae.utils.json : toJson;
		clientHub.broadcast(toJson(FocusHintMessage("focus_hint", fromTid, toTid)));
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

	private void handleRequestTaskTypesMsg(WebSocketAdapter ws, WsMessage json)
	{
		if (json.project_path.length == 0)
			ws.send(Data(buildTaskTypesList(
				taskTypeCatalog.getTaskTypes(),
				taskTypeCatalog.getEntryPoints(),
				config.default_task_type,
			).representation));
		else
		{
			configWatcher.ensureProjectWatch(json.project_path);
			ws.send(Data(buildTaskTypesListForProject(
				json.project_path,
				taskTypeCatalog.getTaskTypesForProject(json.project_path),
				taskTypeCatalog.getEntryPointsForProject(json.project_path),
			).representation));
		}
	}

	private AgentInfoEntry[] snapshotAgentEntries()
	{
		import cydo.agent.registry : agentRegistry;
		import std.conv : to;
		import std.path : expandTilde;
		import std.process : environment;
		import std.string : toUpper;

		AgentInfoEntry[] entries;
		foreach (name, ref ac; config.agents)
		{
			// Build merged env: global sandbox.env → per-agent sandbox.env
			// (per-agent layered on top, matching resolveSandbox launch logic).
			string[string] env;
			foreach (k, v; config.sandbox.env)
				env[k] = expandTilde(v);
			foreach (k, v; ac.sandbox.env)
				env[k] = expandTilde(v);

			auto driver = ac.driver.value;  // SetInfo: post-overlay always set
			auto a = agentsByName.get(name, null);
			if (a is null)
				a = createAgentByDriver(driver);

			auto execPath = resolveExecutablePath(a.executableName(env), env);
			// Honor CYDO_<DRIVER>_BIN env-var fallback when the resolved path
			// is empty. Mirrors the launch-time fallback used for testing.
			if (execPath.length == 0)
			{
				auto fallbackVar = "CYDO_" ~ to!string(driver).toUpper ~ "_BIN";
				execPath = environment.get(fallbackVar, "");
			}

			// Display name resolution priority:
			//   1. ac.display_name (user-configured override)
			//   2. driver registry's display name (e.g. "Claude Code")
			//   3. agent name itself (final fallback)
			string displayName = name;
			foreach (ref reg; agentRegistry)
				if (to!AgentDriver(reg.name) == driver)
				{
					displayName = reg.displayName;
					break;
				}
			if (ac.display_name.length > 0)
				displayName = ac.display_name;

			entries ~= AgentInfoEntry(
				name,
				to!string(driver),
				displayName,
				execPath.length > 0,
			);
		}
		return entries;
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
			clientHub.broadcast(buildNoticesList(activeNotices));
		}
		else
		{
			if (id !in activeNotices)
				return;
			activeNotices.remove(id);
			clientHub.broadcast(buildNoticesList(activeNotices));
		}
	}

	/// Extract the last assistant text from a task's history, truncated.
	/// Used for notification body when a task needs attention.
	private string extractLastAssistantText(int tid)
	{
		if (tid !in tasks)
			return "";
		historyPipeline.ensureHistoryLoaded(tid);
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
		if (!clientHub.hasSubscribers(tid))
		{
			tracef("generateSuggestions[%d]: no subscribers, skipping", tid);
			return;
		}

		historyPipeline.ensureHistoryLoaded(tid);
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

/// Install robust logger implementation once.
package(cydo) void initLogger()
{
	installRobustLogger();
}

/// Apply configured log level (trace/info/warning/error). Invalid values fall
/// back to info.
package(cydo) void applyConfiguredLogLevel(string level)
{
	import std.logger : sharedLog, LogLevel;
	switch (level)
	{
		case "trace":    (cast()sharedLog).logLevel = LogLevel.trace; break;
		case "info":     (cast()sharedLog).logLevel = LogLevel.info; break;
		case "warning":  (cast()sharedLog).logLevel = LogLevel.warning; break;
		case "error":    (cast()sharedLog).logLevel = LogLevel.error; break;
		default:
			warningf("Invalid config log_level '%s', falling back to info", level);
			(cast()sharedLog).logLevel = LogLevel.info;
			break;
	}
}
