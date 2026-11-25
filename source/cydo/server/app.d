module cydo.server.app;

import core.lifetime : move;
import core.time : seconds;

import std.algorithm : sort;
import std.array : appender;
import std.exception : enforce;
import std.file : exists, isFile, thisExePath;
import std.format : format;
import std.logger : tracef, infof, warningf, errorf, fatalf;
import std.stdio : File, stderr;
import std.string : representation, strip;

import ae.utils.funopt : funopt, funoptDispatch, funoptDispatchUsage, FunOptConfig, Option, Parameter;
import ae.utils.main : main;

import ae.net.asockets : socketManager, DisconnectType, onNextTick;
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

import cydo.mcp : McpResult, ToolCallCancellation;
import cydo.mcp.tool_descriptions : RenderedCydoToolsOptions,
	ToolDescriptionViolation, checkRenderedCydoToolDescriptionViolations,
	mcpToolDescriptionMaxChars;
import cydo.mcp.tools;
import cydo.workflow.workspace.archive_manager : ArchiveManager, ArchiveManagerHost, ArchiveTaskSnapshot;
import cydo.workflow.workspace.task_path_resolver : TaskPathResolver, TaskPathResolverHost;
import cydo.workflow.sessions.disk_usage : DiskUsageHost, buildDiskScanInput, measureDiskUsageAsync;
import cydo.runtime.storage.disk_usage : DiskScanInput;
import cydo.workflow.workspace.worktree_allocator : WorktreeAllocator, WorktreeAllocatorHost;
import cydo.web.client_hub : ClientHub;
import cydo.runtime.config.watcher : ConfigWatcher, ConfigWatcherHost;
import cydo.workflow.discovery.service : DiscoveryService, DiscoveryServiceHost,
	DiscoveryTaskSnapshot, ImportableReconciliationCommit, ImportableScanRecord,
	ImportableTaskSpec;
import cydo.web.request_policy : isLoopbackListenAddress;
import cydo.web.snapshots : buildAgentsList, buildNoticesList,
	buildServerStatus, buildTaskEntry, buildTasksListPackets, buildTaskTypesList,
	buildTaskTypesListForProject, buildWorkspacesList;
import cydo.workflow.tools.live_calls : LiveToolCalls, LiveToolCallsHost;
import cydo.workflow.history.pipeline : HistoryBroadcastPlan, HistoryEventPipeline,
	HistoryEventPipelineHost, LocalUserProvenance;
import cydo.workflow.history.native_history : ConfiguredNativeHistoryContext,
	HistoryAccess, LiveHistoryWatchResolution, LiveHistoryWatchResolutionKind,
	LiveHistoryWatchTarget, ResolvedNativeHistoryContext,
	TaskHistoryResolution, TaskHistoryResolutionKind, UnavailableHistory,
	UnavailableHistoryKind, resolveNativeHistoryContext;
import cydo.workflow.history.abbrev : extractMessageText;
import cydo.workflow.history.operations : HistoryOperations, NativeSessionState,
	selectHistoryOperations, supportsMessageEditing, supportsRawEventEditing;
import cydo.runtime.logging : installRobustLogger;
import cydo.workflow.system_message_normalizer : SystemMessageNormalizer,
	SystemMessageNormalizerHost;
import cydo.workflow.tasks.derived_text : DerivedTextJobs, DerivedTextJobsHost;
import cydo.workflow.tasks.mutations : TaskMutationService, TaskMutationServiceHost;
import cydo.workflow.tools.backend : AgentSubmissionRejected, UserTaskSpec, WorkflowToolsBackend, WorkflowToolsHost;
import cydo.domain.policy.permissions : PermissionEscalation, PermissionPrompt,
	PermissionSettings, ToolCallRuling;
import cydo.domain.task_types.catalog : TaskTypeCatalog;
import cydo.domain.tasks.yield_gate : YieldGate;
import cydo.workflow.sessions.yield_gates : YieldGateFinding, evaluateWorktreeBranchGate;
import cydo.workflow.sessions.task_runner : TaskSessionLaunch, TaskSessionRunner,
	TaskSessionRunnerHost;
import cydo.web.transport : LiveFileLookupResult, LiveFileLookupStatus, LiveFileReady,
	McpCallbacks, RawSourceLookupResult, RawSourceLookupStatus,
	RawSourceReady, TransportAdapter, WebSocketCallbacks;
import cydo.workflow.usage.service : ClaudeUsageService;

import cydo.agent.resolver : createConfiguredAgent, displayNameForDriver,
	effectiveDefaultAgentName, isConfiguredAgentName, resolvePermissionSettings,
	tryCreateConfiguredAgent;
import cydo.agent.contract : Agent;
import cydo.protocol : RequestHistory;
import cydo.protocol : AgentAckEnvelope, BatchResultEnvelope,
	BrowserSubmissionRejectedEvent, BrowserSubmissionRejectionKind, ContentBlock,
	HistoryBoundary, ItemStartedEvent, SessionRateLimitEvent, TaskDiagnosticEvent,
	TaskDiagnosticSeverity, TaskEventEnvelope, TaskEventSeqEnvelope,
	TranslatedEvent, UnconfirmedUserEventEnvelope, UserMessageConsumedEvent,
	extractContentText;
import cydo.agent.session : AgentSession, AgentSubmissionReceipt, BackgroundWork,
	MessageSource, SubmissionHistoryCancelled;
import cydo.agent.drivers.claude : ClaudeCodeSession;
import cydo.agent.drivers.codex : CodexSession;
import cydo.runtime.config : AgentConfig, AgentDriver, CydoConfig, PathMode, SandboxConfig, WorkspaceConfig;
import cydo.domain.storage.persistence : LoadedHistory, Persistence, openDatabase;
import cydo.server.config_resolution : loadRuntimeConfig;
import cydo.runtime.config.yaml : ConfigErrorKind, ConfigFileException;
import cydo.runtime.image.converter : HeicConverter, createHeicConverter;
version (unittest) import cydo.runtime.image.converter : UnavailableHeicConverter;
import cydo.server.attachment_intake : AttachmentRejection, SubmissionIntake, needsNormalization;
import cydo.server.environment : consumeServerEnvironment;
import cydo.runtime.launch.sandbox : cleanup, resolveExecutablePath, runtimeDir, sharedTmpBaseDir;
import cydo.runtime.launch.types : NativeHistoryProfile, NativeHistoryRule;
import cydo.domain.task_types.definition : DjinjaTemplate, TaskTypeDef, UserEntryPointDef, OutputType, WorktreeMode, byName, loadTaskTypes,
	loadTaskTypeSystemPrompt, formatCompactSingletonToolSummary, singletonsOfferedTo, promptTemplateSource, renderPrompt, substituteVars,
	loadProjectMemory, resolveAgent;
import cydo.foundation.system.framing : isSystemFramed, prependTaskFraming, validateTemplateSource;
import cydo.foundation.system.known_messages : KnownSystemMessageKind,
	sessionStartSubject, systemMessagePrefix, wrapKnownSystemMessage,
	tryKnownSystemMessageMatch, KnownSystemMessageMatch;
import cydo.foundation.platform.path : bestEffortProjectPathIdentity, canonicalProjectPath;
import cydo.domain.tasks.model;
import cydo.domain.tasks.lifecycle : TaskLifecycle, TaskNotificationChange,
	isLegalTaskStatusTransition;
import cydo.foundation.text.title : truncateTitle;
import cydo.workflow.history.jsonl_store : findNextUserUuid,
	HistoryForkDestination;
import cydo.workflow.workspace.worktree;

private enum maxToolDescriptionNoticeViolations = 3;

private struct TaskListScope
{
	int tid;
	int parentTid;
	string workspace;
	string projectPath;
}

private size_t[int] countTaskListChildren(TaskListScope[] scopes)
{
	size_t[int] indexByTid;
	size_t[int] childCounts;
	foreach (index, taskScope; scopes)
	{
		enforce(taskScope.tid > 0, "Task list scope tid must be positive");
		enforce((taskScope.tid in indexByTid) is null,
			"Task list scopes must not contain duplicate tids");
		indexByTid[taskScope.tid] = index;
		childCounts[taskScope.tid] = 0;
	}

	foreach (child; scopes)
	{
		auto parentIndex = child.parentTid in indexByTid;
		if (parentIndex is null)
			continue;
		auto parent = scopes[*parentIndex];
		if (parent.projectPath.length > 0
			&& child.workspace == parent.workspace
			&& child.projectPath == parent.projectPath)
			childCounts[parent.tid]++;
	}
	return childCounts;
}

private string encodeNoticeProjectPath(string projectPath)
{
	auto encodedPath = appender!string();
	foreach (immutable ubyte b; cast(const(ubyte)[]) projectPath)
		encodedPath.put(format!"%02x"(b));
	return encodedPath.data;
}

private string mcpToolDescriptionLimitNoticeId(string projectPath, string taskType)
{
	return "mcp-tool-description-limit:" ~ encodeNoticeProjectPath(projectPath) ~ ":" ~ taskType;
}

private Notice buildMcpToolDescriptionLimitNotice(
	ToolDescriptionViolation[] violations)
{
	auto sortedViolations = violations.dup;
	sortedViolations.sort!((a, b) {
		if (a.actualChars != b.actualChars)
			return a.actualChars > b.actualChars;
		if (a.taskType != b.taskType)
			return a.taskType < b.taskType;
		return a.toolName < b.toolName;
	});

	string impact = "Largest violations: ";
	foreach (i, ref violation; sortedViolations[0 .. maxToolDescriptionNoticeViolations <
			sortedViolations.length ? maxToolDescriptionNoticeViolations :
			sortedViolations.length])
	{
		if (i > 0)
			impact ~= "; ";
		impact ~= format("%s/%s %s > %s", violation.taskType, violation.toolName,
			violation.actualChars, violation.maxChars);
	}

	return Notice(
		NoticeLevel.warning,
		format("Current task-type configuration renders oversized MCP tool descriptions over the %s-character limit.",
			mcpToolDescriptionMaxChars),
		impact,
		"Shorten user/project task-type guidance or move verbose guidance into system prompts.",
		"",
	);
}

class App
{
	private LiveToolCalls liveToolCalls;

	private void abandonToolCalls(int tid)
	{
		liveToolCalls.abandonToolCalls(tid);
	}

	private void closeToolCalls(int tid)
	{
		liveToolCalls.closeTask(tid);
	}

	private void openToolCalls(int tid)
	{
		liveToolCalls.openTask(tid);
	}

	import cydo.workflow.history.jsonl_tracker : JsonlTracker;

	private TransportAdapter transport;
	private ClientHub clientHub;
	private bool[int] pendingHistoryOperations;
	private TaskData[int] tasks;
	private Persistence persistence;
	private TaskLifecycle taskLifecycle;
	private CydoConfig config;
	private string taskDirTemplate;
	private DiscoveryService discoveryService;
	private ImportableScanRecord[int] importableScanRecords_;
	private ulong importableScanGeneration_;
	private ConfigWatcher configWatcher;
	private Agent agent; // default agent
	private Agent[string] agentsByName;
	private TaskTypeCatalog taskTypeCatalog;
	private string webDistDir;
	private HeicConverter heicConverter;
	private SubmissionIntake submissionIntake;
	// JSONL file tracking state
	private JsonlTracker jsonlTracker;
	// HTTP basic auth credentials (from environment)
	private string authUser;
	private string authPass;
	// Active notices keyed by notice ID
	private Notice[string] activeNotices;
	private ClaudeUsageService claudeUsageService;
	private ArchiveManager archiveManager;
	private TaskPathResolver taskPathResolver;
	private WorktreeAllocator worktreeAllocator;
	private HistoryEventPipeline historyPipeline;
	private TaskSessionRunner taskSessionRunner;
	private DerivedTextJobs derivedTextJobs;
	private TaskMutationService taskMutationService;
	private SystemMessageNormalizer systemMessageNormalizer;
	private WorkflowToolsBackend workflowTools;
	// Set during SIGTERM shutdown — suppress onExit status updates so tasks
	// stay "alive" in the DB and can be resumed after restart.
	private bool shuttingDown;
	this()
	{
		clientHub = new ClientHub();
		liveToolCalls = new LiveToolCalls(LiveToolCallsHost(
			appendTaskEvent: (int tid, TranslatedEvent ev) {
				historyPipeline.appendAndBroadcastTaskEvent(tid, ev);
			},
			historyGeneration: (int tid) => tasks[tid].history.generation,
		));
		import core.time : Duration, MonoTime;
		import ae.sys.timing : setTimeout;

		claudeUsageService = new ClaudeUsageService(&clientHub.broadcast,
			(Duration delay, void delegate() callback) {
				auto timer = setTimeout(callback, delay);
				return &timer.cancel;
			}, () => MonoTime.currTime);
	}

	void start()
	{
		// Consume server-only settings before anything can spawn a child.
		auto serverEnv = consumeServerEnvironment();
		heicConverter = createHeicConverter(serverEnv.heicConverter, &broadcastServerStatus);
		submissionIntake = new SubmissionIntake(heicConverter);
		initLogger();
		applyConfiguredLogLevel("info");

		import core.sys.posix.unistd : isatty, STDERR_FILENO;

		auto userEnv = serverEnv.authUser;
		auto passEnv = serverEnv.authPass;
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
				"Any local user or process that can reach the server can view and control all sessions.",
				"Set CYDO_AUTH_PASS to enable authentication.")));

		auto listenAddrEnv = serverEnv.listenAddress is null ? "localhost" : serverEnv.listenAddress;
		if (authUser.length == 0 && authPass.length == 0 && serverEnv.listenSocket is null)
		{
			if (!isLoopbackListenAddress(listenAddrEnv))
				fatalf("Authentication is disabled (CYDO_AUTH_PASS is empty) but CYDO_LISTEN_ADDRESS is '%s'. " ~
					"Without authentication CyDo only listens on localhost, 127.0.0.1 or ::1. " ~
					"Set CYDO_AUTH_PASS to enable authentication, or set CYDO_LISTEN_ADDRESS to a loopback address.",
					listenAddrEnv);
		}

		config = loadRuntimeConfig();
		claudeUsageService.configChanged(config);
		{
			import ae.utils.path : findProgramDirectory;
			import std.path : buildPath;
			auto baseDir = findProgramDirectory("defs/task-types.yaml");
			if (baseDir is null)
				throw new ConfigFileException(ConfigErrorKind.unreadable, "defs/task-types.yaml",
					"could not locate application directory");
			if (baseDir != "")
				infof("Application base directory: %s", baseDir);
			auto taskTypesDir = buildPath(baseDir, "defs");
			auto taskTypesPath = buildPath(baseDir, "defs/task-types.yaml");
			webDistDir = buildPath(baseDir, "web/dist/");
			taskTypeCatalog = new TaskTypeCatalog(taskTypesDir, taskTypesPath,
				(string name) => isConfiguredAgentName(config, name), &reportProjectTaskTypeLoad,
				projectPath => configWatcher.ensureProjectWatch(projectPath));
		}
		taskTypeCatalog.reloadGlobal();
		{
			persistence = openDatabase();
			taskLifecycle = TaskLifecycle(
				getTask: (int tid) => tid in tasks ? &tasks[tid] : null,
				persistStatus: (int tid, string status) => persistence.setStatus(tid, status),
				persistNeedsAttention: (int tid, bool needsAttention) =>
					persistence.setNeedsAttention(tid, needsAttention),
				publishSnapshot: &broadcastTaskUpdate,
				onTaskTerminal: (int tid) {
					if (workflowTools !is null) workflowTools.onTaskTerminal(tid);
				},
			);
			import cydo.runtime.launch.sandbox : runtimeDir;
			createPidFile("cydo.pid", runtimeDir());
		}
		persistence.normalizeProjectPaths(&bestEffortProjectPathIdentity);
		taskDirTemplate = config.task_dir.length > 0 ? config.task_dir : defaultTaskDirTemplate;
		applyConfiguredLogLevel(config.log_level);
		taskPathResolver = new TaskPathResolver(TaskPathResolverHost(
			getTask: (int tid) => tid in tasks ? &tasks[tid] : null,
			workspaces: () => config.workspaces,
			taskDirTemplate: () => taskDirTemplate,
		));
		foreach (name, ref ac; config.agents)
			agentsByName[name] = createConfiguredAppAgent(config, name);
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
			&lookupLiveFile,
			McpCallbacks(
				dispatchTool: &dispatchTool,
				interruptForPendingContinuation: &interruptForPendingContinuation,
				onDeliveryFailed: (string callerTid, McpResult result) {
					workflowTools.onMcpDeliveryFailed(callerTid, result);
				},
				onDelivered: (string callerTid, McpResult result) {
					workflowTools.onToolCallDelivered(callerTid, result);
				},
			),
		);
		archiveManager = new ArchiveManager(ArchiveManagerHost(
			tryGetTask: &tryGetArchiveTask,
			snapshotTasks: &snapshotArchiveTasks,
			tryTaskDir: &taskPathResolver.tryResolveTaskDir,
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
			pendingBatchParent: (int childTid) => workflowTools.pendingBatchParent(childTid),
		));
		worktreeAllocator = new WorktreeAllocator(WorktreeAllocatorHost(
			getTask: (int tid) => tid in tasks ? &tasks[tid] : null,
			persistWorktreeTid: (int tid, int worktreeTid) {
				persistence.setWorktreeTid(tid, worktreeTid);
			},
			findRootTid: &findRootTid,
			taskDir: &taskPathResolver.taskDir,
			worktreePath: &taskPathResolver.worktreePath,
		));
		discoveryService = new DiscoveryService(DiscoveryServiceHost(
			snapshotTasks: &snapshotDiscoveryTasks,
			snapshotNativeHistoryContexts: &snapshotNativeHistoryContexts,
			tryConfiguredAgent: &tryCreateConfiguredAppAgent,
			resolveCurrentNativeHistoryContext: (Agent configured,
				const ref ConfiguredNativeHistoryContext context) {
				return resolveNativeHistoryContext(config, configured, context);
			},
			loadSessionMetaCache: () => persistence.loadSessionMetaCache(),
			withMutationTransaction: &withDiscoveryMutationTransaction,
			reconcileImportableTasks: &reconcileImportableTasks,
			broadcastWorkspaces: &broadcastDiscoveryWorkspaces,
			broadcastScanStatus: &broadcastDiscoveryScanStatus,
			deleteSessionMetaCacheEntry: (string driverName, string profileRoot,
				string sessionId) {
				persistence.deleteSessionMetaCacheEntry(driverName, profileRoot, sessionId);
			},
			deleteSessionMetaCacheGroup: (string driverName, string profileRoot) {
				persistence.deleteSessionMetaCacheGroup(driverName, profileRoot);
			},
			upsertSessionMetaCache: (string driverName, string profileRoot,
				string sessionId, long mtime, string projectPath, string title,
				bool hasMessages) {
				persistence.upsertSessionMetaCache(driverName, profileRoot, sessionId,
					mtime, projectPath, title, hasMessages);
			},
		));
		configWatcher = new ConfigWatcher(ConfigWatcherHost(
			onConfigChanged: &onConfigChanged,
			onProjectConfigChanged: &onProjectConfigChanged,
			onUserTaskTypesChanged: &onUserTaskTypesChanged,
		));
		systemMessageNormalizer = new SystemMessageNormalizer(
			SystemMessageNormalizerHost(
				systemKeyword: () => config.system_keyword,
				projectPathForTask: (int tid) {
					auto td = tid in tasks;
					return td !is null ? td.projectPath : null;
				},
				taskTypesForProject: (string projectPath) {
					return taskTypeCatalog.getTaskTypesForProject(projectPath);
				},
				entryPointsForProject: (string projectPath) {
					return taskTypeCatalog.getEntryPointsForProject(projectPath);
				},
				loadTemplateText: &loadTemplateText,
			));
		workflowTools = new WorkflowToolsBackend(WorkflowToolsHost(
			getTask: (int tid) => tid in tasks ? &tasks[tid] : null,
			createTask: (string workspace, string projectPath, string agentName) {
				return createTask(workspace, projectPath, agentName);
			},
			persistTaskType: (int tid, string taskType) {
				persistence.setTaskType(tid, taskType);
			},
			persistDescription: (int tid, string description) {
				persistence.setDescription(tid, description);
			},
			persistParentTid: (int tid, int parentTid) {
				persistence.setParentTid(tid, parentTid);
			},
			persistRelationType: (int tid, string relationType) {
				persistence.setRelationType(tid, relationType);
			},
			persistTitle: (int tid, string title) {
				persistence.setTitle(tid, title);
			},
			transitionTask: &transitionTask,
			transitionTaskFrom: &transitionTask,
			persistNeedsAttention: (int tid, bool needsAttention) {
				persistence.setNeedsAttention(tid, needsAttention);
			},
			persistLastActive: (int tid, long lastActive) {
				persistence.setLastActive(tid, lastActive);
			},
			persistResultText: (int tid, string resultText) {
				persistence.setResultText(tid, resultText);
			},
			persistTaskStartHead: (int tid, string taskStartHead) {
				persistence.setTaskStartHead(tid, taskStartHead);
			},
			touchTask: &touchTask,
			taskTypesForProject: (string projectPath) {
				return taskTypeCatalog.getTaskTypesForProject(projectPath);
			},
			entryPointsForProject: (string projectPath) {
				return taskTypeCatalog.getEntryPointsForProject(projectPath);
			},
			promptSearchPath: (string projectPath) {
				return taskTypeCatalog.promptSearchPath(projectPath);
			},
			treeReadOnlyForProject: (string projectPath) {
				return taskTypeCatalog.treeReadOnlyFor(projectPath);
			},
			resolveTaskAgent: (DjinjaTemplate requestedAgent, string parentAgent, string workspace) {
				return resolveAgent(requestedAgent, parentAgent, workspace);
			},
			isConfiguredAgentName: (string agentName) {
				return isConfiguredAgentName(config, agentName);
			},
			agentForTask: &agentForTask,
			taskSystemPromptForMessage: &taskSystemPromptForMessage,
			readPromptFile: &readPromptFile,
			buildKnownSystemMessageMeta: (KnownSystemMessageKind kind,
				string subject, string[string] vars, string bodyVar) {
				return systemMessageNormalizer.buildKnownSystemMessageMeta(
					kind, subject, vars, bodyVar);
			},
			systemKeyword: () => config.system_keyword,
			taskDir: &taskPathResolver.taskDir,
			outputPath: &taskPathResolver.outputPath,
			worktreePath: &taskPathResolver.worktreePath,
			taskProducesCommitOutput: (string projectPath, string taskTypeName) {
				import std.algorithm : canFind;

				auto typeDef = taskTypeCatalog.getTaskTypesForProject(projectPath)
					.byName(taskTypeName);
				return typeDef !is null && typeDef.output_type.canFind(OutputType.commit);
			},
			setupWorktreeForEdge: &worktreeAllocator.setupForEdge,
			shuttingDown: () => shuttingDown,
			correctAbortedToolCall: (int tid, string correction) {
				import cydo.agent.session : AbortedToolCallCorrection;

				auto session = cast(AbortedToolCallCorrection) sessionForTask(tid);
				return session is null ? resolve() : session.correctAbortedToolCall(correction);
			},
			ensureProcessQueueAlive: (int tid) {
				assert((tid in tasks) !is null,
					format!"Process queue requested for missing task %d"(tid));
				if (tasks[tid].status == TaskStatus.pending)
					transitionTask(tid, TaskStatus.pending, TaskStatus.active,
						TaskNotificationChange.preserve);
				return tasks[tid].processQueue.setGoal(ProcessState.Alive);
			},
			sendTaskMessage: (int tid, const(ContentBlock)[] content,
				const(ContentBlock)[] broadcastContent, string cydoMeta, string nonce) {
				return sendTaskMessage(tid, content, broadcastContent, cydoMeta, nonce);
			},
			emitTaskReload: &emitTaskReload,
			appendTaskDiagnostic: (int tid, string subject, string body) {
				historyPipeline.appendTaskDiagnostic(tid, subject, body);
			},
			appendAndBroadcastRecoveryDeliveryDiagnostic: (int tid, string subject,
				string body) {
				auto translated = historyPipeline.appendTaskDiagnostic(tid, subject, body);
				broadcastAppendedTaskEvent(tid, translated);
				broadcastTaskUpdate(tid);
			},
			taskAlive: &taskAlive,
			singletonForTask: &singletonForTask,
			workspacesWithProject: &workspacesWithProject,
			createUserTask: &createUserTask,
			startUserTask: &startUserTask,
			singletonsForProject: &taskTypeCatalog.singletonsForProject,
			effectiveCwd: &taskPathResolver.effectiveCwd,
			tasksShareWorkspace: (int aTid, int bTid) {
				auto aTd = aTid in tasks;
				auto bTd = bTid in tasks;
				assert(aTd !is null && bTd !is null,
					format!"WorkflowTools workspace lookup requires live tasks %d and %d"
						(aTid, bTid));
				return tasksShareWorkspace(*aTd, *bTd);
			},
			taskWorkspaceLabel: (int tid) {
				auto td = tid in tasks;
				assert(td !is null,
					format!"WorkflowTools workspace label requested for missing task %d"(tid));
				return taskWorkspaceLabel(*td);
			},

			reactivateTask: (int tid) {
				auto td = tid in tasks;
				assert(td !is null,
					format!"WorkflowTools reactivation requested for missing task %d"(tid));
				assert(td.processQueue !is null,
					format!"WorkflowTools reactivation requested without process queue for task %d"(tid));
				if (td.status != TaskStatus.active)
					transitionTask(tid, [TaskStatus.pending, TaskStatus.alive,
						TaskStatus.waiting, TaskStatus.completed, TaskStatus.failed],
						TaskStatus.active, TaskNotificationChange.preserve);
				return td.processQueue.setGoal(ProcessState.Alive);
			},
			sendKnownSystemMessage: (int tid, KnownSystemMessageKind kind, string body) =>
				sendKnownSystemMessage(tid, kind, body),
			sendPreparedKnownSystemMessage: (int tid, const(ContentBlock)[] blocks,
				string cydoMeta, string nonce) =>
				sendPreparedKnownSystemMessage(tid, blocks, cydoMeta, nonce),
			persistAddTaskDep: &persistence.addTaskDep,
			persistReplaceTaskDepChild: &persistence.replaceTaskDepChild,
			persistRemoveTaskBatch: &persistence.removeTaskBatch,
			loadTaskDeps: &persistence.loadTaskDeps,
			loadQuestions: &persistence.loadQuestions,
			persistInsertQuestion: &persistence.insertQuestion,
			persistAnswerQuestion: &persistence.answerQuestion,
			persistCancelQuestion: &persistence.cancelQuestion,
			persistDeleteQuestion: &persistence.deleteQuestion,
			broadcastTaskUpdate: &broadcastTaskUpdate,
			broadcastFocusHint: &broadcastFocusHint,
			sendAskUserQuestionPrompt: (int tid, JSONFragment questions,
				string toolUseId) {
				clientHub.sendToSubscribed(tid, Data(toJson(
					AskUserQuestionMessage("ask_user_question", tid,
						toolUseId, questions)).representation));
			},
			clearAskUserQuestionPrompt: (int tid) {
				clientHub.sendToSubscribed(tid, Data(toJson(
					AskUserQuestionMessage("ask_user_question", tid,
						"", JSONFragment("[]"))).representation));
			},
			sendPermissionPrompt: (int tid, const PendingPermission pending) {
				clientHub.sendToSubscribed(tid, Data(toJson(
					PermissionPromptMessage.of(tid, pending)).representation));
			},
			clearPermissionPrompt: (int tid) {
				clientHub.sendToSubscribed(tid, Data(toJson(
					PermissionPromptMessage("permission_prompt", tid,
						"", "", JSONFragment("{}"))).representation));
			},
			broadcastTaskCreated: (TaskCreatedMessage message) {
				clientHub.broadcast(toJson(message));
			},
			permissionSettings: &findPermissionSettings,
			onNextTick: (void delegate() cb) {
				onNextTick(socketManager, cb);
			},
			generateTitle: (int tid, string prompt) {
				derivedTextJobs.generateTitle(tid, prompt);
			},
		));
		historyPipeline = new HistoryEventPipeline(HistoryEventPipelineHost(
			liveToolStarted: &liveToolCalls.toolStarted,
			liveTurnEnded: &liveToolCalls.turnEnded,
			getTask: (int tid) => tid in tasks ? &tasks[tid] : null,
			resolveTaskHistory: &resolveTaskHistory,
			reportUnavailableHistory: &reportUnavailableHistory,
			injectAgentNameIntoSessionInit: &injectAgentNameIntoSessionInit,
			normalizeKnownSystemMessageMeta: (string translated, int tid) {
				return systemMessageNormalizer.normalizeKnownSystemMessageMeta(translated, tid);
			},
			configuredAgentNames: () {
				import std.array : array;
				return config.agents.byKey.array;
			},
			makeTaskDiagnosticEventJson: &makeTaskDiagnosticEventJson,
			sendToSubscribed: (int tid, Data data) {
				clientHub.sendToSubscribed(tid, data);
			},
			subscribe: (WebSocketAdapter ws, int tid, Nullable!HistoryOperations operations) {
				clientHub.subscribe(ws, tid, operations);
			},
			historyOperations: &historyOperationsForTask,
			broadcastHistoryOperations: &scheduleHistoryOperations,
			noteLiveBoundaryCandidate: (int tid, size_t seq, string event, string raw, int sourceLine,
				LocalUserProvenance localUserProvenance) {
				// Boundaries of a driver-served history arrive with its events.
				if (HistoryAccess.driverServingHistory(tryAgentForTask(tid)) is null)
					jsonlTracker.noteLiveBoundaryCandidate(tid, seq, event, raw, sourceLine,
						localUserProvenance == LocalUserProvenance.registeredLocal);
			},
			sendReplaySupplementalState: &sendHistoryReplaySupplementalState,
			onHistorySubscribed: &onHistorySubscribed,
			planBroadcast: &planHistoryBroadcast,
			loadDriverHistory: (int tid, HistoryAccess access) =>
				taskSessionRunner.loadDriverHistory(tid, access),
		));
		derivedTextJobs = new DerivedTextJobs(DerivedTextJobsHost(
			getTask: (int tid) => tid in tasks ? &tasks[tid] : null,
			suggestionsEnabled: () => config.suggestions,
			snapshotTaskIds: &snapshotTaskIdsForResume,
			agentForTask: &agentForTask,
			hasSubscribers: (int tid) => clientHub.hasSubscribers(tid),
			whenHistoryLoaded: &historyPipeline.whenHistoryLoaded,
			readPromptFile: (int tid, string relativePath, string[string] vars) {
				auto td = tid in tasks;
				assert(td !is null,
					format!"Prompt read requested for missing task %d"(tid));
				return readPromptFile(relativePath, td.projectPath, vars);
			},
			persistTitle: (int tid, string title) {
				persistence.setTitle(tid, title);
			},
			broadcastTitleUpdate: &broadcastTitleUpdate,
			broadcastSuggestionsUpdate: &broadcastSuggestionsUpdate,
			emitTitleGenerationFailure: (int tid, string text) {
				import ae.utils.json : toJson;
				import cydo.protocol : ProcessStderrEvent;

				ProcessStderrEvent ev;
				ev.text = text;
				historyPipeline.broadcastTask(tid, TranslatedEvent(toJson(ev), null));
			},
			devMode: () => config.dev_mode,
		));
		taskSessionRunner = new TaskSessionRunner(TaskSessionRunnerHost(
			usageSessionStarted: &claudeUsageService.sessionStarted,
			usageSessionEnded: &claudeUsageService.sessionEnded,
			usageProfileForSession: &claudeUsageService.profileForSession,
			observeUsageEvent: &claudeUsageService.observeEvent,
			getTask: (int tid) => tid in tasks ? &tasks[tid] : null,
			taskDir: &taskPathResolver.taskDir,
			outputPath: &taskPathResolver.outputPath,
			effectiveCwd: &taskPathResolver.effectiveCwd,
			worktreePath: &taskPathResolver.worktreePath,
			currentConfig: () => &config,
			permissionSettings: &findPermissionSettings,
			reportMcpToolDescriptionLimit: &reportMcpToolDescriptionLimit,
			resolveSharedTmpPath: &resolveSharedTmpPath,
			mcpSocketPath: () => transport.mcpSocketPath,
			agentForTask: &agentForTask,
			tryAgentForTask: &tryAgentForTask,
			setAgentSessionId: (int tid, string agentSessionId) {
				persistence.setAgentSessionId(tid, agentSessionId);
			},
			broadcastTask: (int tid, TranslatedEvent ev) {
				historyPipeline.broadcastTask(tid, ev);
			},
			appendTaskDiagnostic: (int tid, string subject, string body) {
				return historyPipeline.appendTaskDiagnostic(tid, subject, body);
			},
			broadcastAppendedTaskEvent: &broadcastAppendedTaskEvent,
			publishTaskSnapshot: &broadcastTaskUpdate,
			onTaskTurnCompletedAlive: &onTaskTurnCompletedAlive,
			sendBackgroundWorkReminder: &sendBackgroundWorkReminder,
			pump: &workflowTools.pump,
			hasLiveBatchOwner: &workflowTools.hasLiveBatchOwner,
			hasBatchChild: &workflowTools.hasBatchChild,
			hasPendingChildQuestion: &workflowTools.hasPendingChildQuestion,
			sendPendingChildAnswerReminder: &workflowTools.sendPendingChildAnswerReminder,
			checkOutputGate: &checkOutputGate,
			checkWorktreeBranchGate: &checkWorktreeBranchGate,
			evaluateDiskUsage: (int tid) => measureDiskUsageAsync(diskScanInput(tid)),
			finalizeCompletedSubTask: &workflowTools.finalizeCompletedSubTask,
			recordChildTerminal: &workflowTools.recordChildTerminal,
			failPendingAskUserQuestionOnExit: &workflowTools.failPendingAskUserQuestionOnExit,
			failPendingPermissionPromptOnExit: &workflowTools.failPendingPermissionPromptOnExit,
			abandonToolCalls: &abandonToolCalls,
			closeToolCalls: &closeToolCalls,
			openToolCalls: &openToolCalls,
			decideToolPermission: &workflowTools.decideToolPermission,
			decidePreToolUse: &workflowTools.decidePreToolUse,
			withdrawToolPermissionPrompt: &workflowTools.withdrawToolPermissionPrompt,
			cancelExitBackgroundWork: &cancelExitBackgroundWork,
			resetHistoryWatermarkOnly: &resetHistoryWatermarkOnly,
			resetHistoryWatermarkAfterExit: &resetHistoryWatermarkAfterExit,
			unsubscribeTaskHistorySubscribers: (int tid) {
				clientHub.unsubscribeAll(tid);
			},
			touchAndPersistLastActive: &touchAndPersistLastActive,
			transitionTask: &transitionTask,
			transitionTaskFrom: &transitionTask,
			applyTaskTransition: &taskLifecycle.applyTransition,
			persistResultText: (int tid, string resultText) {
				persistence.setResultText(tid, resultText);
			},
			markYieldGateNagged: &markYieldGateNagged,
			requestYieldGateRetry: &requestYieldGateRetry,
			spawnContinuation: &workflowTools.spawnContinuation,
			spawnOnYieldContinuation: &workflowTools.spawnOnYieldContinuation,
			emitTaskReload: (int tid) {
				emitTaskReload(tid);
			},
			ingestTranscriptRows: (tid, rows) => jsonlTracker.ingestMirrorRows(tid, rows),
			startJsonlWatch: (int tid) {
				jsonlTracker.startJsonlWatch(tid);
				scheduleHistoryOperations(tid);
			},
			ensureHistoryLoadedForExit: (int tid) => historyPipeline.ensureHistoryLoadedForExit(tid),
			finalReconcileJsonlIfPresent: (int tid, Nullable!TaskHistoryResolution resolution) {
				jsonlTracker.finalReconcileJsonlIfPresent(tid, resolution);
			},
			stopJsonlWatch: (int tid) {
				jsonlTracker.stopJsonlWatch(tid);
			},
			broadcastHistoryOperations: &scheduleHistoryOperations,
			sendSystemRestartNudge: &workflowTools.sendSystemRestartNudge,
			snapshotTaskIds: &snapshotTaskIdsForResume,
			isSingletonTask: &isSingletonTask,
			hasRestoredWork: &workflowTools.hasRestoredWork,
			shuttingDown: () => shuttingDown,
			taskTypeCatalog: taskTypeCatalog,
		));
		taskMutationService = new TaskMutationService(TaskMutationServiceHost(
			getTask: (int tid) => tid in tasks ? &tasks[tid] : null,
			putTask: (int tid, TaskData td) {
				tasks[tid] = move(td);
			},
			agentForTask: &agentForTask,
			sessionForTask: &sessionForTask,
			taskAlive: &taskAlive,
			stopTask: (int tid) {
				taskSessionRunner.stopTask(tid);
			},
			prepareOperationSessionLaunch: (int tid, Agent taskAgent,
				TaskTypeDef* typeDef) {
				return taskSessionRunner.prepareOperationSessionLaunch(tid,
					taskAgent, typeDef);
			},
			taskTypeForProject: (string projectPath, string taskTypeName) {
				return taskTypeCatalog.getTaskTypesForProject(projectPath).byName(taskTypeName);
			},
			makeProcessQueueSF: &makeProcessQueueSF,
			makeArchiveQueueSF: &makeArchiveQueueSF,
			persistence: () => &persistence,
			deleteTask: &deleteWorkflowTask,
			setAgentSessionId: (int tid, string agentSessionId) {
				persistence.setAgentSessionId(tid, agentSessionId);
			},
			setRelationType: (int tid, string relationType) {
				persistence.setRelationType(tid, relationType);
			},
			setTitle: (int tid, string title) {
				persistence.setTitle(tid, title);
			},
			transitionTask: &transitionTask,
			transitionTaskFrom: &transitionTask,
			ensureHistoryLoaded: (int tid) {
				historyPipeline.ensureHistoryLoaded(tid);
			},
			whenHistoryLoaded: (int tid, void delegate() ready) {
				historyPipeline.whenHistoryLoaded(tid, ready);
			},
			servedHistoryMode: &servedHistoryMode,
			resolveTaskHistory: &resolveTaskHistory,
			reportUnavailableHistory: &reportUnavailableHistory,
			requireLiveHistoryLaunch: (int tid, const ref HistoryAccess access) {
				return taskSessionRunner.requireLiveHistoryLaunch(tid, access);
			},
			openCodexForkSourceOperation: (int tid,
				const ref HistoryAccess access) {
				return taskSessionRunner.openCodexForkSourceOperation(tid, access);
			},
			nativeSessionState: &nativeSessionState,
			historyOperationsChanged: &scheduleHistoryOperations,
			resolveFreshPersistedBoundary: (int tid, const ref HistoryAccess access,
				string requestedAnchor, out HistoryBoundary boundary, out bool opensConversation) {
				return historyPipeline.resolveFreshPersistedBoundary(tid, access,
					requestedAnchor, boundary, opensConversation);
			},
			prepareHistoryForkDestination: &prepareHistoryForkDestination,
			getUndoJsonl: (int tid) => jsonlTracker.getUndoJsonl(tid),
			clearUndoJsonl: (int tid) {
				jsonlTracker.clearUndoJsonl(tid);
			},
			invalidateJsonlLineage: (int tid) {
				auto td = tid in tasks;
				assert(td !is null,
					"History lineage invalidated for missing task");
				td.clearSubmissionCorrelationState();
				jsonlTracker.invalidateLineage(tid);
			},
			startJsonlWatch: (int tid) {
				jsonlTracker.startJsonlWatch(tid);
			},
			stopJsonlWatch: (int tid) {
				jsonlTracker.stopJsonlWatch(tid);
			},
			generateSuggestions: (int tid) {
				derivedTextJobs.generateSuggestions(tid);
			},
			unsubscribeTaskHistorySubscribers: (int tid) {
				clientHub.unsubscribeAll(tid);
			},
			emitTaskReload: &emitTaskReload,
			broadcastTaskCreated: (TaskCreatedMessage message) {
				import ae.utils.json : toJson;
				clientHub.broadcast(toJson(message));
			},
			broadcastTaskUpdate: &broadcastTaskUpdate,
			broadcastFocusHint: &broadcastFocusHint,
		));
		jsonlTracker.getTask = (int tid) => tid in tasks ? &tasks[tid] : null;
		jsonlTracker.resolveTaskHistory = &resolveTaskHistory;
		jsonlTracker.resolveLiveHistoryWatch = &resolveLiveHistoryWatch;
		jsonlTracker.historyGeneration = (int tid) {
			auto td = tid in tasks;
			assert(td !is null, "history generation requested for missing task");
			return td.history.generation;
		};
		jsonlTracker.sendToSubscribed = (int tid, string msg) =>
			clientHub.sendToSubscribed(tid, Data(msg.representation));
		jsonlTracker.onBoundaryResolved = (int tid, size_t seq, HistoryBoundary boundary,
			bool publish, ulong generation) {
			auto td = tid in tasks;
			if (td is null || td.history.generation != generation)
				return;
			historyPipeline.backfillHistoryBoundary(tid, seq, boundary, publish);
		};
		// Only Copilot's file shrink detection fires this hook.
		jsonlTracker.onLineageInvalidated = (int tid) {
			auto td = tid in tasks;
			assert(td !is null, "history lineage invalidated for missing task");
			td.clearSubmissionCorrelationState();
			jsonlTracker.invalidateLineage(tid);
			auto resolution = resolveTaskHistory(tid);
			if (resolution.kind == TaskHistoryResolutionKind.access)
				td.history.reset(historyWatermark(resolution.requireAccess()));
			else if (resolution.kind == TaskHistoryResolutionKind.unavailable)
			{
				reportUnavailableHistory(tid, resolution);
				return;
			}
			else
				td.history.reset(Watermark.none());
			emitTaskReload(tid, "history_lineage");
			jsonlTracker.startJsonlWatch(tid);
		};
		jsonlTracker.onClaudeTranscriptRow = &onClaudeTranscriptRow;
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
			td.agentName = row.agentName;
			td.parentTid = row.parentTid;
			td.relationType = row.relationType;
			td.creatorTid = row.creatorTid;
			td.worktreeTid = row.worktreeTid;
			td.taskStartHead = row.taskStartHead;
			td.title = row.title;
			td.status = parseTaskStatus(row.status);
			td.archived = row.archived;
			td.draft = row.draft;
			td.resultText = row.resultText;
			td.createdAt = row.createdAt;
			td.lastActive = row.lastActive;
			td.naggedYieldGates = row.naggedYieldGates;
			td.needsAttention = row.needsAttention;
			td.titleGenDone = row.title.length > 0;
			auto rowTid = row.tid;
			tasks[rowTid] = move(td);
			if (tasks[rowTid].status == TaskStatus.importable)
			{
				persistence.deleteTask(rowTid);
				taskSessionRunner.discardPendingExit(rowTid);
				tasks.remove(rowTid);
				continue;
			}
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
					auto resolution = resolveTaskHistory(rowTid);
					if (resolution.kind == TaskHistoryResolutionKind.access)
						wm = historyWatermark(resolution.requireAccess());
					else
						wm = Watermark.unreadable();
				}
				td2.history.reset(wm);
			}
		}
		// Post-migration cleanup: remove stale worktree symlinks from pre-v2 sessions
		foreach (tid, ref td; tasks)
		{
			import std.file : isSymlink, remove;
			auto td_dir = taskPathResolver.tryTaskDir(td);
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

		recoverLastActive();

		resumeInFlightTasks();

		discoveryService.enumerateSessions();

		auto sslCert = serverEnv.tlsCert;
		auto sslKey = serverEnv.tlsKey;
		transport.setAuthCredentials(authUser, authPass);
		transport.startHttpServer(sslCert, sslKey);
		auto server = transport.server;

		auto listenSocket = serverEnv.listenSocket;
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
			auto listenPort = to!ushort(serverEnv.listenPort is null ? "3940" : serverEnv.listenPort);
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
		liveToolCalls.closeAll();
		taskSessionRunner.shutdownSessions();
		derivedTextJobs.cancelAll();
		workflowTools.killActiveTerminals();
		jsonlTracker.stopAllWatches();
		{
			import cydo.agent.drivers.codex : CodexAgent;
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
			"",
			defaultAgentName(""),
			configuredAgentNames(),
		).representation));
		ws.send(Data(buildAgentsList(snapshotAgentEntries(), config.default_agent).representation));
		auto taskListPackets = buildCurrentTasksListPackets();
		foreach (packet; taskListPackets)
			ws.send(Data(packet.representation));
		ws.send(Data(buildServerStatus(
			authUser.length > 0 || authPass.length > 0,
			config.dev_mode,
			webDistDir,
			config.ui,
			heicConverter.status,
		).representation));
		ws.send(Data(buildNoticesList(activeNotices).representation));
		if (discoveryService.scanInProgress)
			ws.send(Data(toJson(ScanStatusMessage("scan_status", true)).representation));
		foreach (payload; claudeUsageService.snapshotMessages())
			ws.send(Data(payload.representation));
	}

	private void onWebSocketDisconnected(WebSocketAdapter ws, string reason, DisconnectType type)
	{
		clientHub.remove(ws);
	}

	private void recoverLastActive()
	{
		import std.datetime.stopwatch : StopWatch;
		import ae.utils.time.types : AbsTime;
		import cydo.workflow.history.last_work : lastWorkRecordTime;

		// Recover rows from before last_active was persisted at work boundaries.
		StopWatch sw;
		sw.start();
		size_t recovered, scanned;
		foreach (ref td; tasks)
		{
			if (td.lastActive != 0)
				continue;

			++recovered;
			auto resolution = resolveTaskHistory(td.tid);
			auto lastActive = td.createdAt;
			final switch (resolution.kind)
			{
				case TaskHistoryResolutionKind.access:
					auto access = resolution.requireAccess();
					if (!access.isDriverServed)
					{
						auto path = access.path;
						++scanned;
						Nullable!AbsTime workTime;
						try
							workTime = lastWorkRecordTime(access.agent, path);
						catch (Exception e)
						{
							errorf("last_active recovery for task %d failed: %s", td.tid, e.msg);
							td.lastActive = td.createdAt;
							continue;
						}
						if (!workTime.isNull)
							lastActive = workTime.get.stdTime;
					}
					break;
				case TaskHistoryResolutionKind.noSession:
					break;
				case TaskHistoryResolutionKind.orphanAgent:
				case TaskHistoryResolutionKind.unavailable:
					td.lastActive = td.createdAt;
					continue;
			}
			persistence.setLastActive(td.tid, lastActive);
			td.lastActive = lastActive;
		}
		if (recovered != 0)
			infof("Recovered last_active for %d tasks (%d transcripts scanned) in %d ms",
				recovered, scanned, sw.peek.total!"msecs");
	}

	private void lookupLiveFile(int tid, string path, LiveFileReady ready)
	{
		import cydo.workflow.show : readShownFile, ShownFile;

		alias Status = LiveFileLookupStatus;
		auto task = tid in tasks;
		if (task is null)
		{
			ready(LiveFileLookupResult(Status.taskNotFound));
			return;
		}
		if (task.status == TaskStatus.importable)
		{
			ready(LiveFileLookupResult(status: Status.unavailable, reason: "The task is importable"));
			return;
		}
		if (task.archived || isArchiveTransitioning(tid))
		{
			ready(LiveFileLookupResult(status: Status.unavailable, reason: "The task is archived"));
			return;
		}
		void unavailable(Exception e)
		{
			ready(LiveFileLookupResult(status: Status.unavailable, reason: e.msg));
		}
		Promise!ShownFile read;
		try
			read = readShownFile(&taskSessionRunner.runInTaskSandbox, tid, path);
		catch (Exception e)
		{
			unavailable(e);
			return;
		}
		read.then((ShownFile file) {
			ready(LiveFileLookupResult(Status.ok, file.mediaType, file.bytes));
		}, &unavailable).ignoreResult();
	}

	private void lookupRawSource(int tid, size_t seq, RawSourceReady ready)
	{
		auto task = tid in tasks;
		if (task !is null && task.status == TaskStatus.importable)
		{
			if (!task.history.isLoaded)
				ready(RawSourceLookupResult(RawSourceLookupStatus.historyNotLoaded, null));
			else if (seq >= task.history.length)
				ready(RawSourceLookupResult(RawSourceLookupStatus.seqOutOfRange, null));
			else
				ready(RawSourceLookupResult(RawSourceLookupStatus.ok, task.history.rawAt(seq)));
			return;
		}
		historyPipeline.whenHistoryLoaded(tid, () {
			auto td = tid in tasks;
			if (td is null)
				ready(RawSourceLookupResult(RawSourceLookupStatus.taskNotFound, null));
			else if (seq >= td.history.length)
				ready(RawSourceLookupResult(RawSourceLookupStatus.seqOutOfRange, null));
			else
				ready(RawSourceLookupResult(RawSourceLookupStatus.ok, td.history.rawAt(seq)));
		});
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
		taskSessionRunner.interruptTask(parsedTid);
		return true;
	}

	/// Dispatch an MCP tool call. Returns a promise that resolves when the
	/// tool completes — immediately for sync tools, later for async tools
	/// (e.g. Task, which awaits the child task's completion in a fiber).
	private Promise!McpResult dispatchTool(string tool, string tid, string itemId, JSONFragment args,
		ToolCallCancellation cancellation)
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

		// Handlers reject an unparsable tid before attempting to enrich the call.
		auto call = hasParsedTid ? liveToolCalls.register(parsedTid, itemId, cancellation) : null;
		return async({
			scope (exit)
				if (call)
					liveToolCalls.settle(call);
			auto impl = new CydoToolsImpl(workflowTools, tid, call, cancellation);
			auto dispatcher = mcpToolDispatcher!CydoTools(impl);
			return dispatcher.dispatch(tool, args);
		});
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

	private string workspaceNameForProjectPath(string projectPath)
	{
		foreach (ref wi; discoveryService.workspacesInfo)
			foreach (ref project; wi.projects)
				if (project.path == projectPath)
					return wi.name;
		return "";
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

	private string[] workspacesWithProject(string projectPath)
	{
		import std.algorithm : sort;
		import std.array : array;

		bool[string] names;
		discoveredWorkspacesForProjectPath(projectPath, names);
		return names.keys.sort.array;
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

	private void handleWsMessage(WebSocketAdapter ws, string text)
	{
		import ae.utils.json : jsonParse;
		auto json = jsonParse!WsMessage(text);

		auto task = json.tid in tasks;
		if (task !is null && task.status == TaskStatus.importable
			&& json.type != "request_history" && json.type != "promote_task")
		{
			ws.send(Data(toJson(ErrorMessage("error",
				"Import this session before using task commands", json.tid)).representation));
			return;
		}

		switch (json.type)
		{
			case "create_task":       handleCreateTaskMsg(ws, json); break;
			case "request_history":   handleRequestHistory(ws, jsonParse!RequestHistory(text)); break;
			case "message":           handleUserMessage(ws, json); break;
			case "resume":            handleResumeMsg(json); break;
			case "interrupt":         handleInterruptMsg(json); break;
			case "unsend_message":    handleUnsendMessage(ws, json); break;
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
			case "ask_user_response": workflowTools.handleAskUserResponse(json); break;
			case "permission_prompt_response": workflowTools.handlePermissionPromptResponse(json); break;
			case "approve_retry":     handleApproveRetryMsg(json); break;
			case "refresh_workspaces": handleRefreshWorkspacesMsg(); break;
			case "promote_task":     handlePromoteTaskMsg(ws, json); break;
			case "set_task_type":    handleSetTaskTypeMsg(json); break;
			case "set_entry_point":  handleSetEntryPointMsg(json); break;
			case "set_agent_name":   handleSetAgentNameMsg(json); break;
			case "request_task_types": handleRequestTaskTypesMsg(ws, json); break;
			default: break;
		}
	}

	private static final class NativeUndoSubmissionRefusal : Exception
	{
		this(string reason)
		{
			super(reason);
		}
	}

	private static BrowserSubmissionRejectionKind submissionRejectionKind(Exception failure)
	{
		if (auto rejection = cast(AgentSubmissionRejected) failure)
			failure = cast(Exception) rejection.next;
		if (cast(SubmissionHistoryCancelled) failure)
			return BrowserSubmissionRejectionKind.history_cancelled;
		if (cast(NativeUndoSubmissionRefusal) failure)
			return BrowserSubmissionRejectionKind.native_undo_refused;
		return BrowserSubmissionRejectionKind.delivery_failed;
	}

	/// Send a terminal submission disposition to its originating browser.
	private void sendBrowserSubmissionRejected(WebSocketAdapter ws,
		string correlationId, int tid, BrowserSubmissionRejectionKind kind,
		string reason, int attachment = -1)
	{
		if (kind == BrowserSubmissionRejectionKind.native_undo_refused)
			clientHub.sendToSubscribed(tid,
				Data(toJson(ErrorMessage("error", reason, tid)).representation));
		if (correlationId.length == 0)
			return;
		BrowserSubmissionRejectedEvent event;
		event.correlation_id = correlationId;
		if (tid >= 0)
			event.tid = tid;
		event.kind = kind;
		event.reason = reason;
		event.attachment = attachment;
		clientHub.sendTo(ws, Data(toJson(event).representation));
	}

	private void handleSetTaskTypeMsg(WsMessage json)
	{
		auto tid = json.tid;
		if (tid < 0 || tid !in tasks) return;
		if (taskAlive(tid)) return; // can't change type of a running task
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
		if (taskAlive(tid)) return; // can't change type of a running task
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
		if (taskAlive(tid)) return; // can't change type of a running task
		if (json.agent_name.length == 0) return;
		if (!isConfiguredAgentName(config, json.agent_name)) return;
		tasks[tid].agentName = json.agent_name;
		persistence.setAgentName(tid, json.agent_name);
		scheduleHistoryOperations(tid);
		broadcastTaskUpdate(tid);
	}

	private string taskTypeLoadRefusal(string projectPath)
	{
		if (!taskTypeCatalog.hasTaskTypes(projectPath))
			return "Task types for this project failed to load: " ~ taskTypeCatalog.loadError(projectPath);
		return null;
	}

	private void handleCreateTaskMsg(WebSocketAdapter ws, WsMessage json)
	{
		auto at = json.agent_name.length > 0 ? json.agent_name : defaultAgentName(json.workspace);
		string projectPath;
		if (json.project_path.length > 0)
		{
			try
				projectPath = canonicalProjectPath(json.project_path);
			catch (Exception)
			{
				auto reason = "Project path must be an existing directory";
				ws.send(Data(toJson(ErrorMessage("error", reason)).representation));
				sendBrowserSubmissionRejected(ws, json.correlation_id, -1,
					BrowserSubmissionRejectionKind.validation, reason);
				return;
			}
		}
		// Top-level user task creation must always come through a concrete entry point.
		// Internal tasks (subtasks, continuations, imports) are created through other paths.
		if (json.entry_point.length == 0)
		{
			auto reason = "Top-level task creation requires an entry point";
			ws.send(Data(toJson(ErrorMessage("error", reason)).representation));
			sendBrowserSubmissionRejected(ws, json.correlation_id, -1,
				BrowserSubmissionRejectionKind.validation, reason);
			return;
		}
		auto ep = validateBrowserEntryPoint(ws, projectPath, json.entry_point, json.correlation_id);
		if (ep is null)
			return;

		ContentBlock[] blocks;
		if (json.content.json !is null)
			blocks = jsonParse!(ContentBlock[])(json.content.json);
		if (!needsNormalization(blocks))
			return createBrowserTask(ws, json, projectPath, at, ep, blocks);

		submissionIntake.normalize(blocks).then((ContentBlock[] normalized) {
			// Run creation in the event loop so exceptions follow the synchronous create path.
			onNextTick(socketManager, {
				auto current = validateBrowserEntryPoint(ws, projectPath, json.entry_point, json.correlation_id);
				if (current !is null)
					createBrowserTask(ws, json, projectPath, at, current, normalized);
			});
		}, (Exception e) {
			auto rejection = cast(AttachmentRejection) e;
			assert(rejection !is null);
			sendBrowserSubmissionRejected(ws, json.correlation_id, -1,
				BrowserSubmissionRejectionKind.attachment_rejected, rejection.msg, rejection.attachment);
		}).ignoreResult();
	}

	private const(UserEntryPointDef)* validateBrowserEntryPoint(WebSocketAdapter ws,
		string projectPath, string entryPoint, string correlationId)
	{
		if (auto refusal = taskTypeLoadRefusal(projectPath))
		{
			clientHub.sendTo(ws, Data(toJson(ErrorMessage("error", refusal)).representation));
			sendBrowserSubmissionRejected(ws, correlationId, -1,
				BrowserSubmissionRejectionKind.validation, refusal);
			return null;
		}
		auto ep = taskTypeCatalog.getEntryPointsForProject(projectPath).byName(entryPoint);
		if (ep !is null && !ep.system)
			return ep;

		auto reason = "Unknown entry point: " ~ entryPoint;
		clientHub.sendTo(ws, Data(toJson(ErrorMessage("error", reason)).representation));
		sendBrowserSubmissionRejected(ws, correlationId, -1,
			BrowserSubmissionRejectionKind.validation, reason);
		return null;
	}

	private void createBrowserTask(WebSocketAdapter ws, WsMessage json, string projectPath,
		string agentName, const UserEntryPointDef* ep, ContentBlock[] blocks)
	{
		auto tid = createEntryPointTask(json.workspace, projectPath, agentName, ep);
		// Send task_created only to the requesting client (unicast) so that
		// parallel test workers don't steal each other's task IDs.
		clientHub.sendTo(ws, Data(toJson(TaskCreatedMessage("task_created", tid, json.workspace, projectPath, 0, "", json.correlation_id)).representation));
		unicastFocusHint(ws, 0, tid);
		// Broadcast updated task state so all other clients see the new task.
		broadcastTaskUpdate(tid);

		// If content is provided, send it as the first message atomically
		if (blocks.length > 0)
			submitInitialMessage(tid, blocks, MessageSource.user).except((Exception failure) {
				sendBrowserSubmissionRejected(ws, json.correlation_id, tid,
					submissionRejectionKind(failure), failure.msg);
			}).ignoreResult();
	}

	/// Create a top-level task at an entry point. It has no session until it
	/// is sent its first message.
	private int createEntryPointTask(string workspace, string projectPath, string agentName,
		const UserEntryPointDef* ep)
	{
		auto tid = createTask(workspace, projectPath, agentName, ep.name);
		// Call getTaskTypesForProject() after getEntryPointsForProject() so the cache is populated.
		auto taskTypes = taskTypeCatalog.getTaskTypesForProject(projectPath);
		persistence.setEntryPoint(tid, ep.name);
		tasks[tid].taskType = ep.resolvedType;
		if (taskTypes.byName(ep.resolvedType) !is null)
			persistence.setTaskType(tid, ep.resolvedType);
		return tid;
	}

	private int createUserTask(UserTaskSpec spec)
	{
		auto ep = taskTypeCatalog.getEntryPointsForProject(spec.projectPath).byName(spec.entryPoint);
		assert(ep !is null && !ep.system, "CreateTask target must be a user entry point");

		auto tid = createEntryPointTask(spec.workspace, spec.projectPath,
			defaultAgentName(spec.workspace), ep);
		auto task = &tasks[tid];
		task.title = spec.title;
		task.creatorTid = spec.creatorTid;
		task.draft = spec.draft;
		persistence.setTitle(tid, spec.title);
		persistence.setCreatorTid(tid, spec.creatorTid);
		persistence.setDraft(tid, spec.draft);
		clientHub.broadcast(toJson(TaskCreatedMessage("task_created", tid, spec.workspace,
			spec.projectPath, 0, "")));
		broadcastTaskUpdate(tid);
		return tid;
	}

	private Promise!void startUserTask(int tid, string prompt)
	{
		return submitInitialMessage(tid, [ContentBlock("text", prompt)], MessageSource.harness);
	}

	/// Find the newest available singleton in the caller's project and workspace.
	/// If none exists, start one and wait until it accepts its first message.
	private Promise!int singletonForTask(int callerTid, string name)
	{
		auto caller = &tasks[callerTid];
		auto singleton = taskTypeCatalog.singletonsForProject(caller.projectPath).byName(name);
		assert(singleton !is null, "Request target must be an enabled singleton");
		auto ep = taskTypeCatalog.getEntryPointsForProject(caller.projectPath).byName(name);

		int found;
		foreach (tid, ref td; tasks)
			if (tid > found && td.parentTid <= 0 && td.entryPoint == ep.name
				&& td.projectPath == caller.projectPath && td.workspace == caller.workspace
				&& !td.archived && !td.archiving && td.status != TaskStatus.importable)
				found = tid;
		if (found > 0)
			return resolve(found);

		auto typeDef = taskTypeCatalog.getTaskTypesForProject(caller.projectPath)
			.byName(ep.resolvedType);
		enforce(typeDef !is null, "Singleton entry point '" ~ ep.name
			~ "' has unknown task type '" ~ ep.resolvedType ~ "'");
		auto workspace = caller.workspace;
		auto projectPath = caller.projectPath;
		// A singleton serves every task in its workspace, so it is nobody's
		// child: its `parent_agent_type` is the workspace's default agent.
		auto agentName = resolveAgent(typeDef.agent, defaultAgentName(workspace), workspace);
		// `caller` dangles from here on: creating a task grows `tasks`.
		auto tid = createEntryPointTask(workspace, projectPath, agentName, ep);
		tasks[tid].title = singleton.title;
		persistence.setTitle(tid, tasks[tid].title);
		clientHub.broadcast(toJson(TaskCreatedMessage("task_created", tid, workspace,
			projectPath, 0, "")));
		broadcastTaskUpdate(tid);
		return submitInitialMessage(tid, [ContentBlock("text", readPromptFile(
			"prompts/singleton_started_by_request.md", projectPath, null))],
			MessageSource.harness).then(() => true, (Exception) => false).then((bool accepted) {
				enforce(accepted, format!"Could not start singleton %s (task %d): %s"(
					name, tid, tasks[tid].error));
				return tid;
			});
	}

	/// Start a new top-level task's session with its first message: `blocks`,
	/// wrapped in the prompt of the task's entry point. Record any failure
	/// on the task before propagating it to the caller.
	private Promise!void submitInitialMessage(int tid, ContentBlock[] blocks, MessageSource source)
	{
		Promise!void submission;
		try
			submission = prepareAndSubmitInitialMessage(tid, blocks, source);
		catch (Exception e)
			submission = reject!void(e);

		return submission.except((Exception e) {
			auto failed = tid in tasks;
			assert(failed !is null,
				"Initial message submission task disappeared");
			// TaskSessionRunner already owns a failed launch and its diagnostic.
			if (failed.status == TaskStatus.failed)
				throw e;
			assert(failed.status == TaskStatus.pending || failed.status == TaskStatus.active,
				"Initial message submission failed outside a pending or active task");
			failed.error = e.msg;
			failed.resultText = e.msg;
			persistence.setResultText(tid, failed.resultText);
			transitionTask(tid, failed.status, TaskStatus.failed,
				TaskNotificationChange.preserve);
			auto translated = historyPipeline.appendTaskDiagnostic(tid,
				"Failed to submit initial message", e.msg);
			broadcastAppendedTaskEvent(tid, translated);
			workflowTools.recordChildTerminal(tid);
			broadcastTaskUpdate(tid);
			throw e;
		});
	}

	private Promise!void prepareAndSubmitInitialMessage(int tid, ContentBlock[] blocks,
		MessageSource source)
	{
		auto td = &tasks[tid];
		auto taskTypes = taskTypeCatalog.getTaskTypesForProject(td.projectPath);
		auto epTemplate = taskTypeCatalog.getEntryPointsForProject(td.projectPath)
			.byName(td.entryPoint).prompt_template;
		auto typeDef = taskTypes.byName(td.taskType);
		auto textContent = extractContentText(blocks);
		auto messageToSend = blocks;
		string sessionStartMsgSubject;
		if (typeDef !is null)
		{
			import std.algorithm : filter;
			import std.array : array;
			auto rendered = renderPrompt(*typeDef, textContent,
				taskTypeCatalog.promptSearchPath(td.projectPath),
				taskPathResolver.outputPath(td), epTemplate);
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
			? systemMessageNormalizer.buildKnownSystemMessageMeta(
				KnownSystemMessageKind.sessionStart,
				sessionStartMsgSubject,
				["task_description": textContent], "task_description")
			: null;
		void commitAcceptedInitialSubmission(TaskData* accepted)
		{
			if (accepted.description.length == 0)
			{
				accepted.description = textContent;
				persistence.setDescription(tid, textContent);
			}
			if (accepted.title.length == 0)
			{
				accepted.title = truncateTitle(textContent, 80);
				persistence.setTitle(tid, accepted.title);
				broadcastTitleUpdate(tid, accepted.title);
				derivedTextJobs.generateTitle(tid, textContent);
			}
		}
		materializePendingTask(tid);
		return tasks[tid].processQueue.setGoal(ProcessState.Alive).then(() {
			return sendTaskMessage(tid, messageToSend, msgContent, msgMeta,
				null, true, &commitAcceptedInitialSubmission, source);
		});
	}

	private void handleRequestHistory(WebSocketAdapter ws, RequestHistory json)
	{
		auto td = json.tid in tasks;
		if (td is null || td.status != TaskStatus.importable || !td.history.isDriverServed)
		{
			historyPipeline.handleRequestHistory(ws, json.tid);
			return;
		}

		HistoryAccess access;
		try
			access = resolveImportPreview(*td, json.workspace);
		catch (Exception e)
		{
			ws.send(Data(toJson(ErrorMessage("error", e.msg, json.tid)).representation));
			return;
		}
		historyPipeline.handleRequestHistory(ws, json.tid, Nullable!HistoryAccess(access));
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

		workflowTools.replayPendingClientPrompts(tid, (string payload) {
			ws.send(Data(payload.representation));
		});
	}

	private void onHistorySubscribed(int tid)
	{
		try
			derivedTextJobs.onHistorySubscribed(tid);
		catch (Exception e)
			warningf("Error generating suggestions on subscribe: %s", e.msg);
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

		// Queue-operation records live in the session file, not the agent's
		// stdout; any that appear in a translated event stream (pre-2.1.2xx
		// CLIs) are simply consumed.
		if (isQueueOperation(plan.currentEvent.translated))
		{
			plan.consumeCurrent = true;
			return plan;
		}

		if (isCompactionReminderSteerFailureEvent(plan.currentEvent.translated))
			td.compactionReminderInFlight = false;

		if (plan.currentEvent.translated.canFind(`"type":"item/started"`)
			&& plan.currentEvent.translated.canFind(`"item_type":"user_message"`))
		{
			@JSONPartial static struct UserMsgTagProbe
			{
				string type;
				string item_type;
				@JSONOptional bool is_replay;
				@JSONOptional bool is_meta;
				@JSONOptional bool pending;
				@JSONOptional string correlation_id;
				@JSONOptional string uuid;
			}
			UserMsgTagProbe probe;
			try
				probe = jsonParse!UserMsgTagProbe(plan.currentEvent.translated);
			catch (Exception)
				return plan;
			if (probe.type == "item/started"
				&& probe.item_type == "user_message"
				&& !probe.is_meta && !probe.pending)
			{
					auto local = td.observeNativeStdout(probe.uuid, td.history.generation);
					if (local.found)
					{
						plan.localUserProvenance = LocalUserProvenance.registeredLocal;
						if (local.browserNonce.length > 0)
							plan.currentEvent.translated = plan.currentEvent.translated[0 .. $ - 1]
								~ `,"correlation_id":` ~ toJson(local.browserNonce) ~ `}`;
					}
				if (!probe.is_replay && probe.correlation_id.length > 0)
					td.consumeAppServerAcceptedNonce(probe.correlation_id,
						td.history.generation);
			}
		}

		return plan;
	}

	/// Refusal text for a task whose native undo forbids delivery, or
	/// null when delivery is allowed. Callers report it in their own idiom:
	/// the entry guard sends it to task subscribers, while the delivery funnel
	/// rejects the submission promise.
	private string nativeUndoDeliveryRefusal(TaskData* td)
	{
		if (!td.nativeUndoBlocksDelivery)
			return null;
		final switch (td.nativeUndoState)
		{
			case NativeUndoState.idle:
				assert(false, "idle native undo state cannot block delivery");
			case NativeUndoState.backingUp:
			case NativeUndoState.inFlight:
				return "Native undo is in progress and this message was not sent";
			case NativeUndoState.unverified:
				return "The agent may already have changed or lost history; sends are blocked only in this running CyDo process and this message was not sent";
		}
	}

	private void removeUnobservedNativeSubmissionReservation(TaskData* td,
		string nativeUuid, ulong generation)
	{
		td.cancelUnobservedNativeSubmission(nativeUuid, generation);
	}

	/// A person overrules the auto mode classifier's denial of a tool call:
	/// tell the agent it may retry exactly that call. `content` holds the
	/// call (`{"tool_name":…,"input":…}`).
	private void handleApproveRetryMsg(WsMessage json)
	{
		auto tid = json.tid;
		if (tid < 0 || tid !in tasks)
			return;
		@JSONPartial static struct DeniedCall
		{
			string tool_name;
			JSONFragment input;
		}
		auto call = jsonParse!DeniedCall(json.content.json);
		@JSONPartial static struct CommandInput { @JSONOptional string command; }
		auto command = jsonParse!CommandInput(call.input.json).command;
		auto text = readPromptFile("prompts/approve_and_retry.md", tasks[tid].projectPath, [
			"tool_name": call.tool_name,
			"noun": command.length > 0 ? "command" : "call",
			"quoted": command.length > 0 ? toJson(command) : call.input.json,
		]);
		// The person's decision, worded by CyDo.
		sendKnownSystemMessage(tid, KnownSystemMessageKind.approveRetry, text,
			MessageSource.user).except((Exception e) {
			clientHub.sendToSubscribed(tid,
				Data(toJson(ErrorMessage("error", e.msg, tid)).representation));
		}).ignoreResult();
	}

	private struct BrowserSubmissionRefusal
	{
		BrowserSubmissionRejectionKind kind;
		string reason;
	}

	private BrowserSubmissionRefusal browserSubmissionRefusal(int tid, ulong generation)
	{
		auto td = tid in tasks;
		if (td is null)
			return BrowserSubmissionRefusal(BrowserSubmissionRejectionKind.task_unavailable,
				"Task is no longer available");
		if (td.history.generation != generation)
			return BrowserSubmissionRefusal(BrowserSubmissionRejectionKind.history_cancelled,
				"Submission was cancelled because task history changed");
		if (auto refusal = nativeUndoDeliveryRefusal(td))
			return BrowserSubmissionRefusal(BrowserSubmissionRejectionKind.native_undo_refused,
				refusal);
		if (isArchiveTransitioning(tid))
			return BrowserSubmissionRefusal(BrowserSubmissionRejectionKind.task_archiving,
				"Task is being archived");
		if (auto refusal = taskTypeLoadRefusal(td.projectPath))
			return BrowserSubmissionRefusal(BrowserSubmissionRejectionKind.validation, refusal);
		return BrowserSubmissionRefusal.init;
	}

	private void releaseUiNonceLease(TaskData* td, string nonce, ulong generation)
	{
		if (nonce.length > 0)
			if (auto leasedGeneration = nonce in td.inFlightUiNonceGeneration)
				if (*leasedGeneration == generation)
					td.inFlightUiNonceGeneration.remove(nonce);
	}

	private void handleUserMessage(WebSocketAdapter ws, WsMessage json)
	{
		auto tid = json.tid;
		auto msgNonce = json.correlation_id;
		auto td = tid in tasks;
		if (tid < 0 || td is null)
		{
			sendBrowserSubmissionRejected(ws, msgNonce, tid,
				BrowserSubmissionRejectionKind.task_unavailable,
				"Task is no longer available");
			return;
		}

		auto submissionGeneration = td.history.generation;
		if (msgNonce.length > 0)
		{
			if (msgNonce in td.recentNonces)
				return;
			if (auto leasedGeneration = msgNonce in td.inFlightUiNonceGeneration)
				if (*leasedGeneration == submissionGeneration)
					return;
		}

		auto refusal = browserSubmissionRefusal(tid, submissionGeneration);
		if (refusal.reason.length)
		{
			sendBrowserSubmissionRejected(ws, msgNonce, tid, refusal.kind, refusal.reason);
			return;
		}
		assert(td.taskType.length > 0, "Task must have a task_type when receiving a message");

		ContentBlock[] blocks;
		if (json.content.json !is null)
			blocks = jsonParse!(ContentBlock[])(json.content.json);
		if (msgNonce.length > 0)
			td.inFlightUiNonceGeneration[msgNonce] = submissionGeneration;

		auto initializesDescription = td.description.length == 0;
		auto initializesTitle = td.title.length == 0;
		auto draftAtSubmission = td.draft;
		submissionIntake.submit(tid, blocks, (ContentBlock[] normalized) {
			dispatchBrowserSubmission(ws, tid, msgNonce, submissionGeneration, normalized,
				initializesDescription, initializesTitle, draftAtSubmission);
		}, (AttachmentRejection rejection) {
			if (auto current = tid in tasks)
				releaseUiNonceLease(current, msgNonce, submissionGeneration);
			sendBrowserSubmissionRejected(ws, msgNonce, tid,
				BrowserSubmissionRejectionKind.attachment_rejected, rejection.msg, rejection.attachment);
		});
	}

	private void dispatchBrowserSubmission(WebSocketAdapter ws, int tid, string msgNonce,
		ulong submissionGeneration, ContentBlock[] blocks, bool initializesDescription,
		bool initializesTitle, string draftAtSubmission)
	{
		auto td = tid in tasks;
		auto refusal = browserSubmissionRefusal(tid, submissionGeneration);
		if (refusal.reason.length)
		{
			if (td !is null)
				releaseUiNonceLease(td, msgNonce, submissionGeneration);
			sendBrowserSubmissionRejected(ws, msgNonce, tid, refusal.kind, refusal.reason);
			return;
		}
		void rejectSubmission(Exception e)
		{
			auto rejected = tid in tasks;
			assert(rejected !is null,
				"User message submission task disappeared");
			releaseUiNonceLease(rejected, msgNonce, submissionGeneration);
			if (rejected.history.generation == submissionGeneration
				&& rejected.status != TaskStatus.failed)
			{
				auto translated = historyPipeline.appendTaskDiagnostic(tid,
					"Failed to submit message", e.msg);
				broadcastAppendedTaskEvent(tid, translated);
				broadcastTaskUpdate(tid);
			}
			sendBrowserSubmissionRejected(ws, msgNonce, tid,
				submissionRejectionKind(e), e.msg);
		}

		scope (failure) releaseUiNonceLease(td, msgNonce, submissionGeneration);
		prepareBrowserSubmission(td, tid, msgNonce, submissionGeneration, blocks,
			initializesDescription, initializesTitle, draftAtSubmission)
			.except(&rejectSubmission).ignoreResult();
	}

	private Promise!void prepareBrowserSubmission(TaskData* td, int tid, string msgNonce,
		ulong submissionGeneration, ContentBlock[] blocks, bool initializesDescription,
		bool initializesTitle, string draftAtSubmission)
	{
		auto textContent = extractContentText(blocks);

		// Wrap first message in prompt template (e.g. conversation.md)
		auto messageToSend = blocks;
		string userMsgMeta;
		if (initializesDescription)
		{
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
					taskPathResolver.outputPath(td), entryPointTemplate);
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
				userMsgMeta = systemMessageNormalizer.buildKnownSystemMessageMeta(
					KnownSystemMessageKind.sessionStart,
					sessionStartMsgSubject,
					["task_description": textContent], "task_description");
			}
		}
		if (initializesDescription)
			materializePendingTask(tid);
		void commitAcceptedBrowserSubmission(TaskData* accepted)
		{
			if (initializesDescription && accepted.description.length == 0)
			{
				accepted.description = textContent;
				persistence.setDescription(tid, textContent);
			}
			// A waiting task resumes when a tool result is delivered or
			// assistant work is observed.
			if (accepted.status != TaskStatus.active && accepted.status != TaskStatus.waiting)
			{
				assert(isLegalTaskStatusTransition(accepted.status, TaskStatus.active),
					"Accepted browser submission has an illegal status transition");
				accepted.status = TaskStatus.active;
				persistence.setStatus(tid, cast(string) TaskStatus.active);
			}
			if (initializesTitle && accepted.title.length == 0)
			{
				accepted.title = truncateTitle(textContent, 80);
				persistence.setTitle(tid, accepted.title);
				broadcastTitleUpdate(tid, accepted.title);
				derivedTextJobs.generateTitle(tid, textContent);
			}
			if (draftAtSubmission.length > 0 && accepted.draft == draftAtSubmission)
			{
				auto oldDraft = accepted.draft;
				accepted.draft = "";
				persistence.setDraft(tid, "");
				auto draftData = Data(toJson(DraftUpdatedMessage("draft_updated", tid, oldDraft, "")).representation);
				clientHub.sendToSubscribed(tid, draftData);
			}
		}
		return td.processQueue.setGoal(ProcessState.Alive).then(() {
			auto queued = tid in tasks;
			assert(queued !is null,
				"User message submission task disappeared before dispatch");
			if (queued.history.generation != submissionGeneration)
				return reject!(void, Exception)(new SubmissionHistoryCancelled(
					"Submission was cancelled because task history changed"));
			return sendTaskMessage(tid, messageToSend, blocks, userMsgMeta, msgNonce,
				userMsgMeta.length > 0, &commitAcceptedBrowserSubmission, MessageSource.user);
		});
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
		if (taskAlive(tid))
			return;
		if (taskSessionRunner.forkSourceOperationInProgress(tid))
			return;
		transitionTask(tid, [TaskStatus.pending, TaskStatus.active,
			TaskStatus.waiting, TaskStatus.completed, TaskStatus.failed],
			TaskStatus.alive, TaskNotificationChange.clearAttention);
			td.processQueue.setGoal(ProcessState.Alive).then(() {
				try
					derivedTextJobs.generateSuggestions(tid);
				catch (Exception e)
					warningf("Error generating suggestions: %s", e.msg);

				workflowTools.pump(tid);
			}).except((Exception e) {
				auto current = tid in tasks;
				assert(current !is null,
					"Manual recovery delivery rejected after task deletion");
				if (current.status == TaskStatus.alive)
					transitionTask(tid, TaskStatus.alive, TaskStatus.waiting,
						TaskNotificationChange.preserve);
				assert(current.status == TaskStatus.waiting
					|| current.status == TaskStatus.failed,
					"Manual recovery delivery rejection escaped its process owner state");
			}).ignoreResult();
	}

	private void handleInterruptMsg(WsMessage json)
	{
		auto tid = json.tid;
		if (tid < 0 || tid !in tasks)
			return;
		taskSessionRunner.interruptTask(tid);
	}

	/// Withdraw a user message the agent has queued but not yet consumed.
	/// On success every client drops the message (a "cancelled" queue
	/// confirmation); the requesting client returns its text to the composer.
	private void handleUnsendMessage(WebSocketAdapter ws, WsMessage json)
	{
		auto tid = json.tid;
		auto td = tid in tasks;
		if (td is null)
			return;
		void refuse(string message)
		{
			ws.send(Data(toJson(ErrorMessage("error", message, tid)).representation));
		}
		auto claude = cast(ClaudeCodeSession) sessionForTask(tid);
		if (claude is null)
			return refuse("Only messages queued in a running Claude session can be un-sent");
		auto nonce = json.correlation_id;
		auto uuid = td.unconsumedNativeSubmission(nonce);
		if (uuid is null)
			return refuse("The message was already delivered");
		auto generation = td.history.generation;
		claude.withdrawQueuedMessage(uuid).then((bool withdrawn) {
			import std.datetime : Clock;

			auto current = tid in tasks;
			if (current is null)
				return;
			if (!withdrawn)
				return refuse("The message was already delivered");
			// A history reload meanwhile forgets submissions; the CLI still
			// withdrew the message, so the confirmation goes out regardless.
			if (current.nativeSubmission(uuid).found)
				current.withdrawNativeSubmission(uuid, generation);
			auto translated = toJson(UserMessageConsumedEvent(uuid: uuid,
				consumed_as: "cancelled", correlation_id: nonce));
			current.history.appendLive(Data(toJson(TaskEventEnvelope(tid,
				Clock.currStdTime, JSONFragment(translated))).representation), null);
			broadcastAppendedTaskEvent(tid, translated);
		}, (Exception e) {
			refuse("Un-send failed: " ~ e.msg);
		}).ignoreResult();
	}

	private void handleSigintMsg(WsMessage json)
	{
		auto tid = json.tid;
		if (tid < 0 || tid !in tasks)
			return;
		taskSessionRunner.sigintTask(tid);
	}

	private void handleCloseStdinMsg(WsMessage json)
	{
		auto tid = json.tid;
		if (tid < 0 || tid !in tasks)
			return;
		auto td = &tasks[tid];
		if (sessionForTask(tid) !is null)
		{
			td.processQueue.setGoal(ProcessState.Dead).ignoreResult();
			td.stdinClosed = true;
			broadcastTaskUpdate(tid);
			taskSessionRunner.closeTaskStdin(tid);
		}
	}

	private void handleStopMsg(WsMessage json)
	{
		auto tid = json.tid;
		if (tid < 0 || tid !in tasks)
			return;
		auto td = &tasks[tid];
		if (sessionForTask(tid) !is null)
		{
			td.wasKilledByUser = true;
			td.processQueue.setGoal(ProcessState.Dead).ignoreResult();
		}
		taskSessionRunner.stopTask(tid);
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
		auto oldDraft = td.draft;
		td.draft = draft;
		persistence.setDraft(tid, draft);
		// Broadcast to every other client (not the sender): draft text is task metadata,
		// not history-subscription-only state.
		auto data = Data(toJson(DraftUpdatedMessage("draft_updated", tid, oldDraft, draft)).representation);
		clientHub.broadcastExcept(senderWs, data);
		if (json.correlation_id.length > 0)
			clientHub.sendTo(senderWs, Data(toJson(DraftUpdatedMessage(
				"draft_updated", tid, oldDraft, draft, json.correlation_id)).representation));
	}

	private void handleDeleteTaskMsg(WsMessage json)
	{
		import ae.utils.json : toJson;
		auto tid = json.tid;
		if (tid < 0 || tid !in tasks)
			return;
		auto td = &tasks[tid];
		// Only allow deletion of empty pending tasks (no agent has run)
		if (td.agentSessionId.length > 0 || taskAlive(tid) || td.status != "pending")
			return;
		// Clean up subscriptions
		clientHub.unsubscribeAll(tid);
		deleteWorkflowTask(tid);
		// Broadcast deletion to all clients
		clientHub.broadcast(toJson(TaskDeletedMessage("task_deleted", tid)));
	}

	private void deleteWorkflowTask(int tid)
	{
		workflowTools.onTaskTerminal(tid, true);
		persistence.deleteTask(tid);
		taskSessionRunner.discardPendingExit(tid);
		tasks.remove(tid);
		workflowTools.removeDeletedBatchChild(tid);
	}

	private void handleForkTaskMsg(WebSocketAdapter ws, WsMessage json)
	{
		taskMutationService.handleForkTaskMsg(ws, json);
	}

	private void handleUndoTaskMsg(WebSocketAdapter ws, WsMessage json)
	{
		taskMutationService.handleUndoTaskMsg(ws, json);
	}

	private void handleEditMessage(WebSocketAdapter ws, WsMessage json)
	{
		taskMutationService.handleEditMessage(ws, json);
	}

	private void handleEditRawEvent(WebSocketAdapter ws, WsMessage json)
	{
		taskMutationService.handleEditRawEvent(ws, json);
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
	private Promise!void sendTaskMessage(int tid, const(ContentBlock)[] content,
		const(ContentBlock)[] broadcastContent = null, string cydoMeta = null,
		string nonce = null, bool isContextBootstrap = false,
		void delegate(TaskData*) acceptedSubmissionMutation = null,
		MessageSource source = MessageSource.harness)
	{
		return sendPreparedTaskMessage(tid, content, broadcastContent, cydoMeta, true, nonce,
			isContextBootstrap, acceptedSubmissionMutation, source);
	}

	/// Send a prepared message to the agent and emit the matching pending UI echo.
	///
	/// System messages are ordinary prepared messages with a stable wrapper format
	/// and CyDo metadata for collapsed rendering.
	private Promise!void sendPreparedTaskMessage(int tid, const(ContentBlock)[] content,
		const(ContentBlock)[] broadcastContent = null, string cydoMeta = null,
		bool captureUndoSnapshot = true, string nonce = null,
		bool isContextBootstrap = false,
		void delegate(TaskData*) acceptedSubmissionMutation = null,
		MessageSource source = MessageSource.harness)
	{
		import std.algorithm : min, filter;
		import std.array : array;

		auto td = tid in tasks;
		assert(td !is null, "Task must exist when sending a message");
		assert(td.taskType.length > 0, "Task must have a task_type when sending a message");
		// Fail-closed backstop for internal and already-scheduled sends: a
		// refused submission was never accepted, so it must reject.
		if (auto refusal = nativeUndoDeliveryRefusal(td))
			return reject!(void, Exception)(
				new AgentSubmissionRejected(new NativeUndoSubmissionRefusal(refusal)));

		// --- send to agent ---
		// Snapshot the JSONL before the agent processes the new message.
		// Agents like Codex may compact the JSONL on the first streaming event
		// (response.created), invalidating line-based fork IDs.  Capturing here,
		// before any agent write, preserves the pre-compaction content for undo.
		if (captureUndoSnapshot)
			jsonlTracker.captureUndoSnapshot(tid);
		auto session = sessionForTask(tid);
		assert(session !is null, "Task session must exist when sending a message");
		const(ContentBlock)[] toSend = session.supportsImages
			? content
			: content.filter!(b => b.type != "image").array;
		auto submissionGeneration = td.history.generation;
		import std.uuid : randomUUID;
		auto nativeSubmissionUuid = agentForTask(tid).driver == AgentDriver.claude
			? randomUUID().toString() : null;
		if (nativeSubmissionUuid.length > 0)
			td.reserveNativeSubmission(nativeSubmissionUuid,
				nonce is null ? "" : nonce, submissionGeneration,
				extractContentText(broadcastContent !is null ? broadcastContent : content));
		Promise!AgentSubmissionReceipt submission;
		try
			submission = session.sendMessage(toSend, nonce, isContextBootstrap,
				nativeSubmissionUuid, source);
		catch (Exception e)
		{
			removeUnobservedNativeSubmissionReservation(td, nativeSubmissionUuid,
				submissionGeneration);
			return reject!(void, Exception)(new AgentSubmissionRejected(e));
		}

		return submission.then((AgentSubmissionReceipt receipt) {
			auto accepted = tid in tasks;
			assert(accepted !is null,
				"Task disappeared while committing accepted message submission");
			if (accepted.history.generation != submissionGeneration)
				throw new SubmissionHistoryCancelled(
					"Message submission invalidated by history lineage reset");
			assert(sessionForTask(tid) is session,
				"Task session changed while committing accepted message submission");

			final switch (receipt)
			{
			case AgentSubmissionReceipt.localEnqueued:
				break;
			case AgentSubmissionReceipt.appServerAccepted:
				if (nonce.length > 0)
					accepted.reserveAppServerAcceptedNonce(nonce, submissionGeneration);
				break;
			}

			if (acceptedSubmissionMutation !is null)
				acceptedSubmissionMutation(accepted);
			historyPipeline.appendUnconfirmedUserMessage(tid, content,
				broadcastContent, cydoMeta, nonce);
			if (nonce.length > 0)
			{
				accepted.recentNonces[nonce] = true;
				releaseUiNonceLease(accepted, nonce, submissionGeneration);
			}
			accepted.isProcessing = true;
			touchAndPersistLastActive(tid);
			accepted.needsAttention = false;
			persistence.setNeedsAttention(tid, false);
			accepted.notificationBody = "";
			derivedTextJobs.clearSuggestions(tid);
			derivedTextJobs.discardInFlightSuggestions(tid);
			broadcastTaskUpdate(tid);
			if (receipt == AgentSubmissionReceipt.appServerAccepted)
				sendAgentAck(tid, nonce);
		}, (Exception e) {
			throw new AgentSubmissionRejected(e);
		}).except((Exception e) {
			if (auto current = tid in tasks)
				removeUnobservedNativeSubmissionReservation(current, nativeSubmissionUuid,
					submissionGeneration);
			throw e;
		});
	}

	private string taskSystemPromptForMessage(int tid, TaskTypeDef* typeDef)
	{
		if (typeDef is null)
			return null;

		auto taskAgent = agentForTask(tid);
		if (taskAgent.supportsDeveloperPrompt)
			return null;

		auto td = &tasks[tid];
		auto taskTypes = taskTypeCatalog.getTaskTypesForProject(td.projectPath);
		auto singletons = singletonsOfferedTo(taskTypes,
			taskTypeCatalog.getEntryPointsForProject(td.projectPath),
			taskTypeCatalog.singletonsForProject(td.projectPath), td.taskType);
		return loadTaskTypeSystemPrompt(*typeDef, taskTypes, td.taskType,
			taskTypeCatalog.promptSearchPath(td.projectPath), taskPathResolver.outputPath(*td),
			singletons: singletons);
	}

	/// Inject agent_name into session/init events whose translation pipeline
	/// didn't have per-task agent name (history replay paths).
	private string injectAgentNameIntoSessionInit(string translated, string agentName)
	{
		import std.algorithm : canFind;
		import cydo.protocol : SessionInitEvent;

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
		auto translated = toJson(ev);
		return isSystemFramed(config.system_keyword, text)
			? systemMessageNormalizer.normalizeKnownSystemMessageMeta(translated, tid)
			: translated;
	}

	private static bool isCompactionReminderSteerFailureEvent(string translated)
	{
		import std.algorithm : canFind;

		if (translated.length == 0 || !translated.canFind(`"type":"cydo/task_diagnostic"`))
			return false;

		@JSONPartial static struct TaskDiagnosticProbe
		{
			string type;
			@JSONOptional string body;
		}
		try
		{
			auto probe = jsonParse!TaskDiagnosticProbe(translated);
			return probe.type == "cydo/task_diagnostic" && probe.body.length > 0
				&& probe.body.canFind("no active turn to steer");
		}
		catch (Exception)
		{
			// Fall back to substring matching if payload shape changes.
			return translated.canFind("no active turn to steer");
		}
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
		if (!taskAlive(tid))
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
		auto reminderMeta = systemMessageNormalizer.buildKnownSystemMessageMeta(
			KnownSystemMessageKind.postCompactionTaskModeReminder);
		sendPreparedTaskMessage(tid, reminderBlocks, null, reminderMeta, false)
			.except((Exception e) {
				auto rejected = tid in tasks;
				assert(rejected !is null,
					"Compaction reminder task disappeared during submission");
				rejected.compactionReminderInFlight = false;
				auto translated = historyPipeline.appendTaskDiagnostic(tid,
					"Failed to deliver post-compaction reminder", e.msg);
				broadcastAppendedTaskEvent(tid, translated);
				broadcastTaskUpdate(tid);
			}).ignoreResult();
		return true;
	}

	private bool tryGetArchiveTask(int tid, out ArchiveTaskSnapshot task)
	{
		auto td = tid in tasks;
		if (td is null)
			return false;
		task = ArchiveTaskSnapshot(td.tid, td.parentTid, td.archived, td.archiving,
			taskAlive(tid), td.workspace, td.projectPath);
		return true;
	}

	private ArchiveTaskSnapshot[int] snapshotArchiveTasks()
	{
		ArchiveTaskSnapshot[int] snapshot;
		foreach (tid, ref td; tasks)
			snapshot[tid] = ArchiveTaskSnapshot(td.tid, td.parentTid, td.archived,
				td.archiving, taskAlive(tid), td.workspace, td.projectPath);
		return snapshot;
	}

	private bool updateArchiveTaskState(int tid, bool archived, bool archiving)
	{
		auto td = tid in tasks;
		if (td is null)
			return false;
		if (archived && archiving)
		{
			taskSessionRunner.settlePendingExit(tid);
			td = tid in tasks;
			if (td is null)
				return false;
		}
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
				td.agentName,
				td.workspace,
				td.projectPath,
			);
		return snapshot;
	}

	private ConfiguredNativeHistoryContext[] snapshotNativeHistoryContexts()
	{
		import std.algorithm : sort;
		import std.array : array;

		auto agentNames = config.agents.byKey.array;
		agentNames.sort();
		auto workspaceNames = config.workspaces.dup;
		workspaceNames.sort!((a, b) => a.name < b.name);
		ConfiguredNativeHistoryContext[] contexts;
		foreach (agentName; agentNames)
		{
			contexts ~= ConfiguredNativeHistoryContext(agentName, "", "", false);
			foreach (ref workspace; workspaceNames)
				contexts ~= ConfiguredNativeHistoryContext(agentName, workspace.name,
					"", false);
		}
		return contexts;
	}

	private void withDiscoveryMutationTransaction(scope void delegate() work)
	{
		persistence.db.db.exec("BEGIN TRANSACTION;");
		scope(success) persistence.db.db.exec("COMMIT TRANSACTION;");
		scope(failure) persistence.db.db.exec("ROLLBACK TRANSACTION;");
		work();
	}


	private ImportableReconciliationCommit reconcileImportableTasks(
		ulong scanGeneration, ImportableTaskSpec[] desired)
	{
		import std.datetime : Clock;

		if (scanGeneration < importableScanGeneration_)
			return null;

		ImportableTaskSpec[] accepted;
		HistoryAccess[] acceptedAccess;
		foreach (ref spec; desired)
		{
			auto resolution = resolveImportableScanRecord(spec.scanRecord);
			if (resolution.kind != TaskHistoryResolutionKind.access)
				continue;
			accepted ~= spec;
			acceptedAccess ~= resolution.requireAccess();
		}

		int[] existing;
		foreach (tid, ref td; tasks)
			if (td.status == TaskStatus.importable)
				existing ~= tid;

		TaskData[int] stagedTasks;
		ImportableScanRecord[int] stagedRecords;
		int[] created;
		foreach (tid; existing)
			persistence.deleteTask(tid);
		foreach (i, ref spec; accepted)
		{
			auto tid = persistence.createTask("", spec.projectPath, spec.agentName);
			auto access = acceptedAccess[i];
			auto scannedPath = spec.scanRecord.discovered.exactHistoryPath;
			enforce(exists(scannedPath) && isFile(scannedPath),
				"Validated importable history locator disappeared before reconciliation");
			auto td = TaskData(tid, "", spec.projectPath);
			td.status = TaskStatus.importable;
			td.agentName = spec.agentName;
			td.agentSessionId = spec.scanRecord.key.sessionId;
			td.title = spec.title;
			td.createdAt = Clock.currStdTime;
			td.lastActive = spec.lastActive;
			td.history.reset(historyWatermark(access));
			td.processQueue = new StateQueue!ProcessState(
				makeProcessQueueSF(tid),
				ProcessState.Dead,
			);
			td.archiveQueue = new StateQueue!ArchiveState(
				makeArchiveQueueSF(tid),
				ArchiveState.Unarchived,
			);
			persistence.setStatus(tid, "importable");
			persistence.setAgentSessionId(tid, td.agentSessionId);
			persistence.setTitle(tid, td.title);
			persistence.setLastActive(tid, td.lastActive);
			stagedTasks[tid] = move(td);
			stagedRecords[tid] = spec.scanRecord;
			created ~= tid;
		}

		return () {
			enforce(scanGeneration >= importableScanGeneration_,
				"A stale discovery generation cannot replace importable session records");
			foreach (tid; existing)
			{
				taskSessionRunner.discardPendingExit(tid);
				tasks.remove(tid);
			}
			foreach (tid, ref td; stagedTasks)
				tasks[tid] = move(td);
			importableScanGeneration_ = scanGeneration;
			importableScanRecords_ = move(stagedRecords);
			foreach (tid; existing)
				clientHub.broadcast(toJson(TaskDeletedMessage("task_deleted", tid)));
			foreach (tid; created)
			{
				auto td = tid in tasks;
				assert(td !is null,
					"Committed importable task is missing before its broadcast");
				clientHub.broadcast(toJson(TaskCreatedMessage("task_created", tid, "",
					(*td).projectPath, 0, "")));
				broadcastTaskUpdate(tid);
			}
		};
	}

	private void broadcastDiscoveryWorkspaces(WorkspaceInfo[] workspaces)
	{
		clientHub.broadcast(buildWorkspacesList(workspaces));
	}

	private void broadcastDiscoveryScanStatus(bool active)
	{
		clientHub.broadcast(toJson(ScanStatusMessage("scan_status", active)));
	}

	private int createTask(string workspace = "", string projectPath = "", string agentName = "",
		string entryPoint = "")
	{
		auto tid = persistence.createTask(workspace, projectPath, agentName, entryPoint);
		auto td = TaskData(tid, workspace, projectPath);
		td.agentName = agentName;
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

	private TaskHistoryResolution resolveTaskHistory(int tid)
	{
		auto td = tid in tasks;
		assert(td !is null, format!"History requested for missing task %d"(tid));
		if (td.status != TaskStatus.importable)
			return taskSessionRunner.resolveTaskHistory(tid);
		auto record = tid in importableScanRecords_;
		if (record is null || (*record).scanGeneration != importableScanGeneration_)
			return TaskHistoryResolution.unavailable(UnavailableHistory(
				UnavailableHistoryKind.context, td.agentName, td.agentSessionId,
				"The importable session offer is no longer part of the current scan",
				NativeHistoryRule.init, NativeHistoryProfile.init));
		return resolveImportableScanRecord(*record);
	}

	private HistoryAccess resolveImportPreview(ref TaskData task, string workspace)
	{
		auto resolution = resolveTaskHistory(task.tid);
		enforce(resolution.kind == TaskHistoryResolutionKind.access,
			resolution.kind == TaskHistoryResolutionKind.unavailable
				? resolution.requireUnavailable().detail : "Import preview history is unavailable");
		auto access = resolution.requireAccess();
		enforce(workspace.length == 0 || workspaceHasProjectPath(workspace, task.projectPath),
			"The selected workspace does not contain the import preview checkout");
		auto context = ConfiguredNativeHistoryContext(task.agentName, workspace, task.repoPath, false);
		auto resolved = resolveNativeHistoryContext(config, access.agent, context);
		enforce(resolved.profile == access.profile && task.agentSessionId == access.sessionId,
			"Import preview for session " ~ access.sessionId ~ " belongs to " ~ access.profile.root
				~ " but the selected checkout resolves to " ~ resolved.profile.root);
		access.previewWorkspace = Nullable!string(workspace);
		return access;
	}

	private TaskHistoryResolution resolveImportableScanRecord(
		const ref ImportableScanRecord record)
	{
		string failure = "No current configured profile produces this importable session";
		foreach (ref context; record.producingContexts)
		{
			auto agent = tryCreateConfiguredAppAgent(context.agentName);
			if (agent is null)
				continue;
			ResolvedNativeHistoryContext resolved;
			try
				resolved = resolveNativeHistoryContext(config, agent, context);
			catch (Exception e)
			{
				failure = e.msg;
				continue;
			}
			if (resolved.profile.driver != record.key.driver
				|| resolved.profile.root != record.key.profileRoot)
				continue;
			if (!exists(record.discovered.exactHistoryPath)
				|| !isFile(record.discovered.exactHistoryPath))
				return TaskHistoryResolution.unavailable(UnavailableHistory(
					UnavailableHistoryKind.profilePath, record.agentName,
					record.key.sessionId,
					"The importable session locator is unavailable", resolved.rule,
					resolved.profile));
			try
			{
				auto file = File(record.discovered.exactHistoryPath, "r");
			}
			catch (Exception e)
				return TaskHistoryResolution.unavailable(UnavailableHistory(
					UnavailableHistoryKind.profilePath, record.agentName,
					record.key.sessionId, e.msg, resolved.rule, resolved.profile));
			if (auto driver = HistoryAccess.driverServingHistory(resolved.agent))
			{
				if (context.agentName != record.agentName)
					continue;
				return TaskHistoryResolution.access(HistoryAccess.driverServed(driver,
					resolved.profile, record.key.sessionId));
			}
			return TaskHistoryResolution.access(HistoryAccess(resolved.agent,
				resolved.profile, record.key.sessionId,
				record.discovered.exactHistoryPath));
		}
		return TaskHistoryResolution.unavailable(UnavailableHistory(
			UnavailableHistoryKind.context, record.agentName, record.key.sessionId,
			failure, NativeHistoryRule.init, NativeHistoryProfile.init));
	}

	private LiveHistoryWatchResolution resolveLiveHistoryWatch(int tid)
	{
		return taskSessionRunner.resolveLiveHistoryWatch(tid);
	}

	private void reportUnavailableHistory(int tid,
		const ref TaskHistoryResolution resolution)
	{
		assert(resolution.kind == TaskHistoryResolutionKind.unavailable,
			"Only unavailable history resolutions may be reported");
		auto td = tid in tasks;
		assert(td !is null, "Unavailable history report requires an existing task");
		auto unavailable = resolution.requireUnavailable();
		auto location = "session " ~ unavailable.sessionId ~ " under "
			~ unavailable.profile.root ~ " (agent '" ~ unavailable.agentName ~ "').\n\nCheck "
			~ unavailable.rule.profileEnvName
			~ " and the configured profile location, then reload the task.";
		if (unavailable.kind == UnavailableHistoryKind.driverRead)
		{
			// The read was made for clients that asked for the history, and
			// leaves it loaded: they are about to be given it, diagnostic
			// included.
			historyPipeline.appendTaskDiagnostic(tid, "Failed to load session history",
				unavailable.detail ~ "\n\nThe agent was asked for " ~ location);
			return;
		}
		auto body = unavailable.kind == UnavailableHistoryKind.profilePath
			? "No history for " ~ location : unavailable.detail;
		td.history.reset(Watermark.unreadable());
		td.history.load((ulong) => LoadedHistory.init);
		historyPipeline.appendTaskDiagnostic(tid, "Failed to load session history", body);
		emitTaskReload(tid, "history_unavailable");
	}

	private HistoryForkDestination prepareHistoryForkDestination(int sourceTid)
	{
		import std.exception : enforce;
		import std.uuid : randomUUID;

		auto td = sourceTid in tasks;
		assert(td !is null, "History fork destination requires an existing source task");
		auto source = resolveTaskHistory(sourceTid);
		enforce(source.kind == TaskHistoryResolutionKind.access,
			"History fork destination requires readable source history");
		auto sourceAccess = source.requireAccess();
		auto agent = tryAgentForTask(sourceTid);
		enforce(agent !is null, "History fork destination requires a configured agent");
		enforce(agent.driver == sourceAccess.agent.driver,
			"Generic history forks cannot convert between native history drivers");
		auto typeDef = taskTypeCatalog.getTaskTypesForProject(td.projectPath)
			.byName(td.taskType);
		auto context = ConfiguredNativeHistoryContext(td.agentName, td.workspace,
			td.repoPath, typeDef !is null && typeDef.read_only);
		auto resolved = resolveNativeHistoryContext(config, agent, context);
		enforce(resolved.profile.root == sourceAccess.profile.root,
			"Generic history forks cannot move between native history profiles");
		auto sessionId = randomUUID().toString();
		return HistoryForkDestination(sessionId,
			agent.createHistoryForkDestination(sessionId, sourceAccess.path,
				resolved.profile));
	}

	/// Return the Agent instance for a task's agent name, creating it on demand.
	/// Returns null if the agent name isn't in config (orphan task).
	private Agent tryAgentForTask(int tid)
	{
		auto td = &tasks[tid];
		if (auto p = td.agentName in agentsByName)
			return *p;
		auto a = tryCreateConfiguredAppAgent(td.agentName);
		if (!a)
			return null;
		agentsByName[td.agentName] = a;
		return a;
	}

	/// Like tryAgentForTask but throws if the configured agent is unknown.
	/// Use this in happy-path code that has already established the task's
	/// agent is configured; orphan-aware code should call tryAgentForTask
	/// and null-check.
	private Agent agentForTask(int tid)
	{
		auto a = tryAgentForTask(tid);
		if (!a)
			throw new Exception("Unknown configured agent: " ~ tasks[tid].agentName);
		return a;
	}

	private Agent decorateConfiguredAgent(Agent a, ref AgentConfig ac)
	{
		a.setModelAliases(ac.model_aliases);
		{
			import cydo.agent.drivers.copilot : CopilotAgent;
			if (auto ca = cast(CopilotAgent) a)
			{
				ca.toolDispatch_ = (string tool, string callerTid, string itemId, JSONFragment args, ToolCallCancellation cancellation) =>
					dispatchTool(tool, callerTid, itemId, args, cancellation);
				ca.onToolResultDelivered_ = (string callerTid, McpResult result) =>
					workflowTools.onToolCallDelivered(callerTid, result);
				ca.onToolResultDeliveryFailed_ = (string callerTid, McpResult result) =>
					workflowTools.onMcpDeliveryFailed(callerTid, result);
			}
		}
		return a;
	}

	private Agent createConfiguredAppAgent(ref CydoConfig config, string agentName)
	{
		auto ac = agentName in config.agents;
		assert(ac !is null);
		return decorateConfiguredAgent(createConfiguredAgent(config, agentName), *ac);
	}

	/// Create an Agent by user-chosen agent name (config.agents key).
	/// Returns null if the name isn't in config.agents.
	private Agent tryCreateConfiguredAppAgent(string agentName)
	{
		auto ac = agentName in config.agents;
		if (!ac)
			return null;
		return decorateConfiguredAgent(tryCreateConfiguredAgent(config, agentName), *ac);
	}

	/// Finalize pending task runtime state right before the first message starts it.
	/// This keeps draft tasks cheap and defers worktree creation until the task
	/// is actually materialized by the first send.
	private void materializePendingTask(int tid)
	{
		auto td = &tasks[tid];
		if (taskAlive(tid) || td.status != "pending" || td.description.length > 0)
			return;

		if (td.entryPoint.length == 0)
			return;

		auto ep = taskTypeCatalog.getEntryPointsForProject(td.projectPath).byName(td.entryPoint);
		if (ep is null)
			return;
		if (td.worktreeTid > 0 || ep.worktree == WorktreeMode.inherit)
			return;
		worktreeAllocator.setupForEdge(tid, td.parentTid, ep.worktree);
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

	private void sendAgentAck(int tid, string nonce)
	{
		if (nonce.length == 0)
			return;
		auto ackEnv = AgentAckEnvelope(tid, nonce);
		clientHub.sendToSubscribed(tid, Data(toJson(ackEnv).representation));
	}

	/// PR #28 hook for the single lineage-scoped stream of persisted Claude
	/// main-transcript rows from the attach catch-up (a file read at attach),
	/// live mirror frames, and the exit catch-up. Within a generation,
	/// UUID-bearing rows are delivered exactly once in file order. UUID-less
	/// rows are delivered at most once and in file order. Consumers must not
	/// depend on their delivery.
	/// This runs synchronously within td.history.generation. The generation
	/// ends at invalidateLineage and td.clearSubmissionCorrelationState().
	private void onClaudeTranscriptRow(int tid, string row)
	{
		auto td = tid in tasks;
		if (td is null)
			return;

		@JSONPartial static struct AttachmentProbe
		{
			string type;
			@JSONOptional static struct Attachment { string type; @JSONOptional string source_uuid; }
			@JSONOptional Attachment attachment;
		}
		AttachmentProbe attachment;
		try
			attachment = jsonParse!AttachmentProbe(row);
		catch (Exception)
			attachment = AttachmentProbe.init;
		if (attachment.type == "attachment"
			&& attachment.attachment.type == "queued_command"
			&& attachment.attachment.source_uuid.length > 0)
		{
			auto absorbed = td.observeNativeTail(attachment.attachment.source_uuid,
				SubmissionTailState.absorbed, td.history.generation);
			if (absorbed.found)
				jsonlTracker.noteAbsorbedLocalUser(tid,
					attachment.attachment.source_uuid, td.history.generation);
			return;
		}

		import cydo.agent.drivers.claude : ClaudeCodeAgent;
		auto uuid = ClaudeCodeAgent.canonicalHistoryPromptUuid(row);
		// The echo carries the UUID CyDo submitted the message under.
		if (uuid.length == 0 || !td.nativeSubmission(uuid).found)
			return;
		td.observeNativeTail(uuid, SubmissionTailState.canonical, td.history.generation);
		jsonlTracker.noteQueueCanonicalIdentity(tid, uuid, td.history.generation);
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

	private bool isSingletonTask(const TaskData* td)
	{
		return td.parentTid <= 0 && td.entryPoint.length > 0
			&& taskTypeCatalog.singletonsForProject(td.projectPath).byName(td.entryPoint) !is null;
	}

	private void onTaskTurnCompletedAlive(int tid)
	{
		if (tid !in tasks)
			return;
		auto td = &tasks[tid];
		if (!isSingletonTask(td))
		{
			td.needsAttention = true;
			persistence.setNeedsAttention(tid, true);
			if (td.resultText.length > 0)
				td.notificationBody = truncateTitle(td.resultText, 200);
			else
			{
				// Only the text waits for history. It belongs to the notification
				// this turn raises, on the history lineage the turn ran on.
				td.notificationBody = "";
				auto lineage = td.history.generation;
				bool announced;
				historyPipeline.whenHistoryLoaded(tid, () {
					auto current = tid in tasks;
					if (current is null || current.history.generation != lineage
						|| !current.needsAttention || current.notificationBody.length > 0)
						return;
					current.notificationBody = extractLastAssistantText(tid);
					if (announced)
						broadcastTaskUpdate(tid);
				});
				announced = true;
			}
		}
		if (td.status != TaskStatus.alive)
				transitionTask(tid, [TaskStatus.active, TaskStatus.waiting, TaskStatus.completed,
					TaskStatus.failed], TaskStatus.alive,
				TaskNotificationChange.preserve);
		else
			broadcastTaskUpdate(tid);
		try
			derivedTextJobs.generateSuggestions(tid);
		catch (Exception e)
			warningf("Error generating suggestions: %s", e.msg);
	}

	/// Ask an agent that ended its turn with background work running whether
	/// it is waiting for that work or forgot about it.
	private void sendBackgroundWorkReminder(int tid, const(BackgroundWork)[] running)
	{
		import std.algorithm : map;
		import std.array : join;

		auto text = readPromptFile("prompts/background_work_reminder.md", tasks[tid].projectPath, [
			"background_work": running
				.map!(work => "- " ~ work.description ~ " (task ID: " ~ work.id ~ ")")
				.join("\n"),
		]);
		sendKnownSystemMessage(tid, KnownSystemMessageKind.backgroundWorkReminder, text)
			.except((Exception e) {
				// The session is gone, and with it the work and the question.
				warningf("Could not send background work reminder to tid=%d: %s", tid, e.msg);
			}).ignoreResult();
	}

	private void cancelExitBackgroundWork(int tid)
	{
		derivedTextJobs.cancelSessionBackgroundWork(tid);
	}

	private static Watermark historyWatermark(HistoryAccess access)
	{
		return access.isDriverServed ? Watermark.driverServed() : watermarkFromPath(access.path);
	}

	/// Returns true when the reset already emitted a task reload (unavailable
	/// history), so the caller must not emit a redundant one.
	private bool resetHistoryWatermarkAfterExit(int tid)
	{
		return resetHistoryWatermark(tid, true);
	}

	private bool resetHistoryWatermarkOnly(int tid)
	{
		return resetHistoryWatermark(tid, false);
	}

	private bool resetHistoryWatermark(int tid, bool unsubscribeSubscribers)
	{
		if (tid !in tasks)
			return false;
		auto previousHistoryMode = servedHistoryMode(tid);
		jsonlTracker.invalidateLineage(tid);
		tasks[tid].clearSubmissionCorrelationState();
		bool reloadEmitted;
		{
			Watermark wm;
			auto resolution = resolveTaskHistory(tid);
			if (resolution.kind == TaskHistoryResolutionKind.access)
			{
				wm = historyWatermark(resolution.requireAccess());
				tasks[tid].history.reset(wm);
			}
			else if (resolution.kind == TaskHistoryResolutionKind.unavailable)
			{
				reportUnavailableHistory(tid, resolution);
				reloadEmitted = true;
			}
			else
			{
				if (resolution.kind == TaskHistoryResolutionKind.orphanAgent)
					wm = Watermark.unreadable();
				tasks[tid].history.reset(wm);
			}
		}
		if (unsubscribeSubscribers)
			clientHub.unsubscribeAll(tid);
		else if (previousHistoryMode != servedHistoryMode(tid))
			scheduleHistoryOperations(tid);
		return reloadEmitted;
	}

	private void markYieldGateNagged(int tid, YieldGate gate)
	{
		auto nagged = tasks[tid].naggedYieldGates;
		nagged.mark(gate);
		persistence.setYieldGatesNagged(tid, nagged);
		tasks[tid].naggedYieldGates = nagged;
	}

	private void requestYieldGateRetry(int tid, YieldGateFinding finding)
	{
		if (tid !in tasks)
			return;
		KnownSystemMessageKind kind;
		string templatePath;
		string failureDiagnostic;
		final switch (finding.gate)
		{
		case YieldGate.outputs:
			kind = KnownSystemMessageKind.missingRequiredOutputs;
			templatePath = "gates/missing_outputs.md";
			failureDiagnostic = "Failed to request missing outputs";
			break;
		case YieldGate.diskCleanup:
			kind = KnownSystemMessageKind.diskCleanupRequest;
			templatePath = "gates/disk_cleanup.md";
			failureDiagnostic = "Failed to request disk cleanup";
			break;
		case YieldGate.worktreeBranch:
			kind = KnownSystemMessageKind.worktreeBranchRequest;
			templatePath = "gates/worktree_branch.md";
			failureDiagnostic = "Failed to request worktree branch switch";
			break;
		}
		auto vars = finding.vars;
		if (finding.gate == YieldGate.outputs)
			vars["missing_outputs"] = finding.detail;
		tasks[tid].processQueue.setGoal(ProcessState.Alive).then(() {
			auto msg = wrapKnownSystemMessage(config.system_keyword,
				kind, readPromptFile(templatePath, tasks[tid].projectPath, vars));
			auto outputsMeta = systemMessageNormalizer.buildKnownSystemMessageMeta(
				kind);
			return sendTaskMessage(tid, [ContentBlock("text", msg)], null,
				outputsMeta);
		}).except((Exception e) {
			auto failed = tid in tasks;
			assert(failed !is null,
				"Missing-output retry task disappeared during submission");
			if (failed.status == TaskStatus.failed)
				return;
			assert(failed.status == TaskStatus.active,
				"Missing-output retry failed outside an active task");
			failed.error = e.msg;
			failed.resultText = e.msg;
			persistence.setResultText(tid, failed.resultText);
			transitionTask(tid, TaskStatus.active, TaskStatus.failed,
				TaskNotificationChange.preserve);
			auto translated = historyPipeline.appendTaskDiagnostic(tid, failureDiagnostic, e.msg);
			broadcastAppendedTaskEvent(tid, translated);
			workflowTools.recordChildTerminal(tid);
			broadcastTaskUpdate(tid);
		}).ignoreResult();
	}

	private Promise!void sendKnownSystemMessage(int tid, KnownSystemMessageKind kind,
		string body, MessageSource source = MessageSource.harness)
	{
		auto msg = wrapKnownSystemMessage(config.system_keyword, kind, body);
		auto meta = systemMessageNormalizer.buildKnownSystemMessageMeta(kind);
		return sendPreparedKnownSystemMessage(tid, [ContentBlock("text", msg)],
			meta, null, source);
	}

	private Promise!void sendPreparedKnownSystemMessage(int tid,
		const(ContentBlock)[] blocks, string cydoMeta, string nonce,
		MessageSource source = MessageSource.harness)
	{
		assert((tid in tasks) !is null, "Known system message task must exist");
		return sendTaskMessage(tid, blocks, null, cydoMeta, nonce, false, null, source)
			.then(() {
				auto accepted = tid in tasks;
				assert(accepted !is null,
					"Known system message task disappeared after acceptance");
				if (accepted.status != TaskStatus.active)
					transitionTask(tid, [TaskStatus.pending, TaskStatus.alive,
						TaskStatus.waiting, TaskStatus.completed, TaskStatus.failed],
						TaskStatus.active, TaskNotificationChange.preserve);
			});
	}

	private int[] snapshotTaskIdsForResume()
	{
		int[] tids;
		foreach (tid, ref td; tasks)
			tids ~= tid;
		return tids;
	}

	private string defaultAgentName(string workspaceName)
	{
		return effectiveDefaultAgentName(config, workspaceName);
	}

	private string[] configuredAgentNames()
	{
		string[] names;
		foreach (name; config.agents.byKey)
			names ~= name;
		names.sort;
		return names;
	}

	private string defaultTaskType(string workspaceName)
	{
		foreach (ref ws; config.workspaces)
			if (ws.name == workspaceName && ws.default_task_type.length > 0)
				return ws.default_task_type;
		return config.default_task_type;
	}

	private PermissionSettings findPermissionSettings(string agentName, string workspaceName)
	{
		return resolvePermissionSettings(config, agentName, workspaceName);
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
				forkPath = taskPathResolver.worktreePath(ancestor);
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

	private DiskScanInput diskScanInput(int tid)
	{
		return buildDiskScanInput(tid, DiskUsageHost(
			taskDir: (int taskTid) => taskPathResolver.taskDir(tasks[taskTid]),
			sharedTmpPath: &resolveSharedTmpPath,
			ownsWorktree: (int taskTid) => tasks[taskTid].ownsWorktree,
			worktreePath: (int taskTid) => taskPathResolver.worktreePath(&tasks[taskTid]),
			forkBaseSha: (int taskTid) => getWorktreeForkBaseHead(tasks[taskTid]),
			forkRepository: (int taskTid) => tasks[taskTid].repoPath,
		));
	}

	private YieldGateFinding checkOutputGate(int tid)
	{
		return YieldGateFinding(YieldGate.outputs, checkDeclaredOutputs(tid));
	}

	private YieldGateFinding checkWorktreeBranchGate(int tid)
	{
		auto td = &tasks[tid];
		if (!td.hasWorktree)
			return YieldGateFinding(YieldGate.worktreeBranch);
		auto typeDef = taskTypeCatalog.getTaskTypesForProject(td.projectPath).byName(td.taskType);
		if (typeDef !is null && typeDef.read_only)
			return YieldGateFinding(YieldGate.worktreeBranch);

		auto wtPath = taskPathResolver.worktreePath(td);
		return evaluateWorktreeBranchGate(worktreeHeadStatus(wtPath, td.worktreeTid),
			wtPath, td.worktreeTid);
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
				auto tdOut = taskPathResolver.outputPath(*td);
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
					auto wtPath = taskPathResolver.worktreePath(td);
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
					auto wtPath = taskPathResolver.worktreePath(td);
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

	private void resumeInFlightTasks()
	{
		workflowTools.rebuildWaits();
		taskSessionRunner.resumeInFlightTasks();
		workflowTools.pumpRestoredMailboxes();
	}

	private Promise!void resumeTask(int tid)
	{
		return taskSessionRunner.resumeTask(tid);
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
		auto path = buildPath(sharedTmpBaseDir(), "tmp-" ~ rootTid.to!string);
		if (!exists(path))
			mkdirRecurse(path);
		return path;
	}

	/// Broadcast a task reload boundary and invalidate in-flight derived work.
	/// task_reload is a hard history-lineage boundary on the wire: clients are
	/// unsubscribed before it is sent, must discard pre-reload live assumptions,
	/// and must call request_history to subscribe to the new replayed lineage.
	private void emitTaskReload(int tid)
	{
		emitTaskReload(tid, "", null);
	}

	private void emitTaskReload(int tid, string reason)
	{
		emitTaskReload(tid, reason, null);
	}

	private void emitTaskReload(int tid, string reason,
		string excludedUserUuid)
	{
		import ae.utils.json : toJson;

		if (tid !in tasks)
			return;
		jsonlTracker.invalidateLineage(tid);
		tasks[tid].clearSubmissionCorrelationState();
		clientHub.unsubscribeAll(tid);
		derivedTextJobs.invalidateSuggestions(tid);
		clientHub.broadcast(toJson(TaskReloadMessage("task_reload", tid, reason,
			excludedUserUuid)));
	}

	private string makeTaskDiagnosticEventJson(string subject, string body)
	{
		TaskDiagnosticEvent event;
		event.severity = TaskDiagnosticSeverity.error;
		event.subject = subject;
		event.body = body;
		return toJson(event);
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

	private void handlePromoteTaskMsg(WebSocketAdapter ws, WsMessage json)
	{
		auto tid = json.tid;
		auto rejectPromotion = (string message) {
			ws.send(Data(toJson(ErrorMessage("error", message, tid)).representation));
		};
		if (tid < 0 || tid !in tasks)
			return;
		auto td = &tasks[tid];
		if (td.status != "importable")
			return;
		auto record = tid in importableScanRecords_;
		if (record is null || (*record).scanGeneration != importableScanGeneration_)
		{
			rejectPromotion("This importable session offer is no longer current");
			return;
		}
		if (td.agentSessionId != (*record).key.sessionId)
		{
			rejectPromotion("This importable session offer no longer matches its session ID");
			return;
		}
		if (json.workspace.length == 0
			|| !workspaceHasProjectPath(json.workspace, td.projectPath))
		{
			rejectPromotion("Select a configured workspace containing this project before importing");
			return;
		}
		auto selectedAgent = tryCreateConfiguredAppAgent((*record).agentName);
		if (selectedAgent is null)
		{
			rejectPromotion("The agent configured for this imported session is unavailable");
			return;
		}
		ResolvedNativeHistoryContext selectedContext;
		try
		{
			auto context = ConfiguredNativeHistoryContext((*record).agentName,
				json.workspace, td.repoPath, false);
			selectedContext = resolveNativeHistoryContext(config, selectedAgent, context);
		}
		catch (Exception e)
		{
			rejectPromotion(e.msg);
			return;
		}
		if (selectedContext.profile.driver != (*record).key.driver
			|| selectedContext.profile.root != (*record).key.profileRoot)
		{
			rejectPromotion("Cannot import session " ~ (*record).key.sessionId
				~ " into workspace '" ~ json.workspace ~ "': it resolves to "
				~ selectedContext.profile.root ~ " but the scanned session belongs to "
				~ (*record).key.profileRoot);
			return;
		}
		bool producingContextCurrent;
		foreach (ref context; (*record).producingContexts)
		{
			auto configured = tryCreateConfiguredAppAgent(context.agentName);
			if (configured is null)
				continue;
			try
			{
				auto resolved = resolveNativeHistoryContext(config, configured, context);
				if (resolved.profile.driver == (*record).key.driver
					&& resolved.profile.root == (*record).key.profileRoot)
				{
					producingContextCurrent = true;
					break;
				}
			}
			catch (Exception)
			{
			}
		}
		if (!producingContextCurrent)
		{
			rejectPromotion("This importable session offer is no longer produced by current configuration");
			return;
		}
		auto history = resolveImportableScanRecord(*record);
		if (history.kind != TaskHistoryResolutionKind.access)
		{
			rejectPromotion("The imported session history is no longer available");
			return;
		}
		auto taskAgent = tryAgentForTask(tid);
		if (taskAgent is null)
		{
			rejectPromotion("The agent configured for this imported session is unavailable");
			return;
		}
		auto access = history.requireAccess();
		if (!access.isDriverServed)
		{
			try
				// Teach the persistent agent the path found by discovery.
				taskAgent.registerHistoryPath(access.sessionId, access.path, selectedContext.profile);
			catch (Exception e)
			{
				rejectPromotion(e.msg);
				return;
			}
		}
		persistence.promoteImportableTask(tid, json.workspace);
		enforce(persistence.db.db.changes == 1,
			"Importable task promotion must update exactly one task row");
		td.workspace = json.workspace;
		td.status = TaskStatus.completed;
		importableScanRecords_.remove(tid);
		broadcastTaskUpdate(tid);
	}

	private bool tryApplyRuntimeConfig()
	{
		CydoConfig candidate;
		Agent[string] planned;
		string[] reused;
		string newDefault;
		try
		{
			candidate = loadRuntimeConfig();
			taskTypeCatalog.checkAgents(name => isConfiguredAgentName(candidate, name));
			foreach (name, ref ac; candidate.agents)
			{
				auto existing = name in agentsByName;
				auto old = name in config.agents;
				if (existing && old && old.driver.value == ac.driver.value
					&& old.sandbox.env == ac.sandbox.env)
				{
					planned[name] = *existing;
					reused ~= name;
				}
				else
					planned[name] = createConfiguredAppAgent(candidate, name);
			}
			newDefault = effectiveDefaultAgentName(candidate);
		}
		catch (ConfigFileException e)
		{
			warningf("Config reload rejected; keeping the current config: %s", e.msg);
			reportLoadFailure("config", "config.yaml was not reloaded", e.msg, true);
			return false;
		}

		config = candidate;
		claudeUsageService.configChanged(config);
		applyConfiguredLogLevel(config.log_level);
		auto reloadedTaskDirTemplate = config.task_dir.length > 0
			? config.task_dir : defaultTaskDirTemplate;
		if (reloadedTaskDirTemplate != taskDirTemplate)
			warningf("Config task_dir changed; restart CyDo for the new task directory template to take effect");

		foreach (name; reused)
		{
			planned[name].setModelAliases(config.agents[name].model_aliases);
			planned[name].setSystemKeyword(config.system_keyword);
		}
		agentsByName = planned;
		agent = planned[newDefault];
		setNotice("config", Nullable!Notice.init);
		return true;
	}

	private void onConfigChanged()
	{
		infof("Config file changed, reloading...");
		if (!tryApplyRuntimeConfig())
			return;

		foreach (tid, ref task; tasks)
			scheduleHistoryOperations(tid);

		taskTypeCatalog.reloadProjects();
		taskSessionRunner.invalidateUsageProfiles();
		discoveryService.beginScan();
		discoveryService.discoverAllWorkspaces(config);
		clientHub.broadcast(buildAgentsList(snapshotAgentEntries(), config.default_agent));
		clientHub.broadcast(buildWorkspacesList(discoveryService.workspacesInfo));
		broadcastTaskTypeLists();
		broadcastServerStatus();
		infof("Config reloaded successfully");
		discoveryService.endScan();
	}

	private void broadcastServerStatus()
	{
		clientHub.broadcast(buildServerStatus(
			authUser.length > 0 || authPass.length > 0,
			config.dev_mode,
			webDistDir,
			config.ui,
			heicConverter.status,
		));
	}

	private void onProjectConfigChanged(string projectPath)
	{
		infof("Project config changed for %s, reloading task types...", projectPath);
		taskTypeCatalog.reloadProject(projectPath);
		taskSessionRunner.invalidateUsageProfiles();
		clientHub.broadcast(buildTaskTypesListForProject(
			projectPath,
			taskTypeCatalog.getTaskTypesForProject(projectPath),
			taskTypeCatalog.getEntryPointsForProject(projectPath),
			workspaceNameForProjectPath(projectPath),
			defaultAgentName(workspaceNameForProjectPath(projectPath)),
			configuredAgentNames(),
		));
	}

	private void onUserTaskTypesChanged()
	{
		infof("User task types file changed, reloading task types...");
		if (tryReloadGlobalTaskTypes())
		{
			taskTypeCatalog.reloadProjects();
			taskSessionRunner.invalidateUsageProfiles();
			broadcastTaskTypeLists();
		}
	}

	private bool tryReloadGlobalTaskTypes()
	{
		try
			taskTypeCatalog.reloadGlobal();
		catch (ConfigFileException e)
		{
			warningf("Global task types rejected; keeping the previous version: %s", e.msg);
			reportLoadFailure("task-types", "Global task types were not reloaded", e.msg, true);
			return false;
		}
		setNotice("task-types", Nullable!Notice.init);
		return true;
	}

	private void broadcastTaskTypeLists()
	{
		clientHub.broadcast(buildTaskTypesList(
			taskTypeCatalog.getTaskTypes(),
			taskTypeCatalog.getEntryPoints(),
			config.default_task_type,
		));
		foreach (projectPath; configWatcher.watchedProjects())
			clientHub.broadcast(buildTaskTypesListForProject(
				projectPath,
				taskTypeCatalog.getTaskTypesForProject(projectPath),
				taskTypeCatalog.getEntryPointsForProject(projectPath),
				workspaceNameForProjectPath(projectPath),
				defaultAgentName(workspaceNameForProjectPath(projectPath)),
				configuredAgentNames(),
			));
	}

	private void handleRefreshWorkspacesMsg()
	{
		tryReloadGlobalTaskTypes();
		taskTypeCatalog.reloadProjects();
		taskSessionRunner.invalidateUsageProfiles();
		discoveryService.discoverAllWorkspaces(config);
		clientHub.broadcast(buildWorkspacesList(discoveryService.workspacesInfo));
		broadcastTaskTypeLists();
		discoveryService.enumerateSessions();
	}

	/// Read a prompt template file from the prompt search path and substitute variables.
	private string readPromptFile(string relativePath, string projectPath, string[string] vars)
	{
		auto source = promptTemplateSource(taskTypeCatalog.promptSearchPath(projectPath),
			relativePath);
		enforce(source !is null, "Prompt file not found: " ~ relativePath);
		auto prompt = substituteVars(source, vars);
		return prompt.strip.length == 0 ? "" : prompt;
	}

	/// Read a prompt template file from the search path without variable substitution.
	private string loadTemplateText(string templateName, string projectPath)
	{
		return promptTemplateSource(taskTypeCatalog.promptSearchPath(projectPath), templateName);
	}

	private void touchTask(int tid)
	{
		import std.datetime : Clock;
		tasks[tid].lastActive = Clock.currStdTime;
	}

	private AgentSession sessionForTask(int tid)
	{
		return taskSessionRunner.sessionForTask(tid);
	}

	private NativeSessionState nativeSessionState(int tid)
	{
		auto session = sessionForTask(tid);
		auto claude = cast(ClaudeCodeSession) session;
		if (claude !is null)
			return claude.canRewindConversation
				? NativeSessionState.liveReady
				: NativeSessionState.liveBusy;
		if (tasks[tid].nativeUndoBlocksDelivery
			|| taskSessionRunner.forkSourceOperationInProgress(tid))
			return NativeSessionState.liveBusy;
		if (auto codex = cast(CodexSession) session)
			return codex.canRevertThread
				? NativeSessionState.liveReady
				: NativeSessionState.liveBusy;
		return NativeSessionState.dead;
	}

	private HistoryOperations historyOperationsForTask(int tid, Agent agent)
	{
		auto operations = selectHistoryOperations(agent.driver,
			nativeSessionState(tid), servedHistoryMode(tid));
		operations.edit_message = supportsMessageEditing(agent);
		operations.edit_raw_event = supportsRawEventEditing(agent);
		return operations;
	}

	/// Drivers, the runner and history loads can all signal in one transition.
	/// Read the matrix once those synchronous changes have finished.
	private void scheduleHistoryOperations(int tid)
	{
		if (shuttingDown || !clientHub.hasSubscribers(tid) || tid in pendingHistoryOperations)
			return;
		pendingHistoryOperations[tid] = true;
		onNextTick(socketManager, () {
			pendingHistoryOperations.remove(tid);
			if (shuttingDown || tid !in tasks || !clientHub.hasSubscribers(tid))
				return;
			auto resolution = resolveTaskHistory(tid);
			auto operations = resolution.kind == TaskHistoryResolutionKind.access
				? historyOperationsForTask(tid, resolution.requireAccess().agent)
				: HistoryOperations.init;
			clientHub.sendHistoryOperations(tid, operations);
		});
	}

	/// What the driver said of the history it served for the task: 0 when
	/// it has served none.
	private ubyte servedHistoryMode(int tid)
	{
		auto history = &tasks[tid].history;
		return history.isLoaded && history.isDriverServed ? history.historyMode : 0;
	}

	private bool taskAlive(int tid)
	{
		return taskSessionRunner.taskAlive(tid);
	}

	private bool taskCanStop(int tid)
	{
		return taskSessionRunner.taskCanStop(tid, tasks[tid].stdinClosed);
	}

	/// Resolved runtime driver for a task's configured agent, or "" if orphaned.
	private string driverForTask(int tid)
	{
		import std.conv : to;

		auto a = tryAgentForTask(tid);
		return a is null ? "" : to!string(a.driver);
	}

	private TaskListScope[] captureTaskListScopes()
	{
		TaskListScope[] scopes;
		foreach (tid, ref td; tasks)
			scopes ~= TaskListScope(tid, td.parentTid, td.workspace, td.projectPath);
		return scopes;
	}

	private string[4] buildCurrentTasksListPackets()
	{
		auto scopes = captureTaskListScopes();
		auto childCounts = countTaskListChildren(scopes);
		TaskListEntry[] entries;
		foreach (taskScope; scopes)
		{
			auto td = taskScope.tid in tasks;
			assert(td !is null, "Captured task disappeared while building task list");
			auto alive = taskAlive(taskScope.tid);
			auto canStop = taskCanStop(taskScope.tid);
			auto driver = driverForTask(taskScope.tid);
			entries ~= buildTaskEntry(*td, childCounts[taskScope.tid], alive, canStop, driver,
				taskSessionRunner.usageProfileForTask(taskScope.tid));
		}
		return buildTasksListPackets(entries);
	}

	private void broadcastTaskUpdate(int tid)
	{
		import ae.utils.json : toJson;

		auto scopes = captureTaskListScopes();
		auto childCounts = countTaskListChildren(scopes);
		auto td = tid in tasks;
		assert(td !is null, "Task update requested for missing task");
		clientHub.broadcast(toJson(TaskUpdatedMessage("task_updated",
			buildTaskEntry(*td, childCounts[tid], taskAlive(tid), taskCanStop(tid),
				driverForTask(tid), taskSessionRunner.usageProfileForTask(tid)))));
	}

	private void transitionTask(int tid, TaskStatus expectedFrom, TaskStatus to,
		TaskNotificationChange notification = TaskNotificationChange.preserve)
	{
		taskLifecycle.transitionTask(tid, expectedFrom, to, notification);
	}

	private void transitionTask(int tid, TaskStatus[] expectedFrom, TaskStatus to,
		TaskNotificationChange notification = TaskNotificationChange.preserve)
	{
		taskLifecycle.transitionTask(tid, expectedFrom, to, notification);
	}

	private void broadcastFocusHint(int fromTid, int toTid)
	{
		import ae.utils.json : toJson;
		clientHub.broadcast(toJson(FocusHintMessage("focus_hint", fromTid, toTid)));
	}

	private void unicastFocusHint(WebSocketAdapter ws, int fromTid, int toTid)
	{
		import ae.utils.json : toJson;
		clientHub.sendTo(ws, Data(toJson(FocusHintMessage("focus_hint", fromTid, toTid)).representation));
	}

	private void handleRequestTaskTypesMsg(WebSocketAdapter ws, WsMessage json)
	{
		if (json.project_path.length == 0)
			ws.send(Data(buildTaskTypesList(
				taskTypeCatalog.getTaskTypes(),
				taskTypeCatalog.getEntryPoints(),
				config.default_task_type,
				json.workspace,
				defaultAgentName(json.workspace),
				configuredAgentNames(),
			).representation));
		else
		{
			string projectPath;
			try
				projectPath = canonicalProjectPath(json.project_path);
			catch (Exception)
			{
				ws.send(Data(toJson(ErrorMessage("error",
					"Project path must be an existing directory")).representation));
				return;
			}
			auto workspace = workspaceNameForProjectPath(projectPath);
			ws.send(Data(buildTaskTypesListForProject(
				projectPath,
				taskTypeCatalog.getTaskTypesForProject(projectPath),
				taskTypeCatalog.getEntryPointsForProject(projectPath),
				workspace,
				defaultAgentName(workspace),
				configuredAgentNames(),
			).representation));
		}
	}

	private AgentInfoEntry[] snapshotAgentEntries()
	{
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
				a = createConfiguredAppAgent(config, name);

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
			string displayName = displayNameForDriver(driver);
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

	private void setNotice(string id, Nullable!Notice n, bool logNotice = true)
	{
		if (!n.isNull)
		{
			auto newNotice = n.get();
			auto existing = id in activeNotices;
			if (existing !is null && *existing == newNotice)
				return;
			activeNotices[id] = newNotice;
			if (logNotice)
			{
				if (newNotice.level == NoticeLevel.alert || newNotice.level == NoticeLevel.warning)
					warningf("NOTICE [%s]: %s — %s — %s", id, newNotice.description, newNotice.impact, newNotice.action);
				else
					infof("NOTICE [%s]: %s", id, newNotice.description);
			}
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

	private void reportProjectTaskTypeLoad(string projectPath, string error, bool keptPrevious)
	{
		auto id = "task-types:" ~ encodeNoticeProjectPath(projectPath);
		if (error is null)
			setNotice(id, Nullable!Notice.init);
		else
			reportLoadFailure(id, "Task types for " ~ projectPath ~ " failed to load", error,
				keptPrevious);
	}

	private void reportLoadFailure(string id, string description, string error, bool keptPrevious)
	{
		auto impact = keptPrevious
			? "Keeping the previously loaded version."
			: "Tasks in this project cannot be started until this is fixed.";
		setNotice(id, Nullable!Notice(Notice(NoticeLevel.alert, description, impact, error)),
			logNotice: false);
	}

	private void reportMcpToolDescriptionLimit(string projectPath, string taskType,
		ToolDescriptionViolation[] violations)
	{
		auto id = mcpToolDescriptionLimitNoticeId(projectPath, taskType);
		if (violations.length == 0)
		{
			setNotice(id, Nullable!Notice.init);
			return;
		}

		setNotice(id, Nullable!Notice(buildMcpToolDescriptionLimitNotice(
			violations)));
	}

	/// Extract the last assistant text from a task's history, truncated.
	/// Used for notification body when a task needs attention.
	private string extractLastAssistantText(int tid)
	{
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

unittest
{
	assert(App.isCompactionReminderSteerFailureEvent(
		`{"type":"cydo/task_diagnostic","severity":"error","subject":"Agent error","body":"no active turn to steer"}`));
	assert(!App.isCompactionReminderSteerFailureEvent(
		`{"type":"cydo/task_diagnostic","severity":"error","subject":"Agent error","body":"ordinary diagnostic"}`));
	assert(!App.isCompactionReminderSteerFailureEvent(
		`{"type":"cydo/task_diagnostic","severity":"error","subject":"no active turn to steer","body":"ordinary diagnostic"}`));
	assert(App.isCompactionReminderSteerFailureEvent(
		`{"type":"cydo/task_diagnostic","body":"no active turn to steer"`));
}

unittest
{
	import ae.net.asockets : ConnectionState, IConnection;
	import ae.sys.dataset : joinData;
	import ae.utils.array : as;
	import std.algorithm : canFind;

	class StubWebSocketAdapter : WebSocketAdapter
	{
		string[] sent;

		this()
		{
			super(new class IConnection
			{
				ConnectionState state_ = ConnectionState.connected;
				void delegate(string, DisconnectType) disconnectHandler;

				@property ConnectionState state() { return state_; }
				void send(scope Data[] data, int priority) {}
				void disconnect(string reason, DisconnectType type)
				{
					state_ = ConnectionState.disconnected;
					disconnectHandler(reason, type);
				}
				@property void handleConnect(void delegate() value) {}
				@property void handleReadData(void delegate(Data) value) {}
				@property void handleDisconnect(void delegate(string, DisconnectType) value)
				{
					disconnectHandler = value;
				}
				@property void handleBufferFlushed(void delegate() value) {}
			});
		}

		override void send(scope Data[] data, int priority)
		{
			sent ~= cast(string) data.joinData().toGC().as!string;
		}
	}

	enum tid = 91;
	auto app = new App;
	app.tasks[tid] = TaskData(tid, "local", "/tmp");
	app.tasks[tid].taskType = "implement";
	auto ws = new StubWebSocketAdapter;
	scope(exit) ws.disconnect("test complete", DisconnectType.requested);
	app.clientHub.add(ws);
	app.clientHub.subscribe(ws, tid);

	app.tasks[tid].beginConfirmedNativeUndo();

	// The entry guard precedes idle-start/active-steer work. It rejects both
	// paths to the task's subscribers without materializing a message.
	app.handleUserMessage(ws, WsMessage(type: "message", tid: tid));
	app.tasks[tid].isProcessing = true;
	app.handleUserMessage(ws, WsMessage(type: "message", tid: tid));
	assert(ws.sent.length == 2 && ws.sent[0].canFind("in progress")
		&& ws.sent[1].canFind("in progress"));

	// The final delivery funnel independently protects internal and already
	// scheduled sends. It has no requesting socket, so it reports refusal the
	// way every other non-acceptance does: by rejecting the submission promise,
	// which the callers' `.except` handlers surface as a task diagnostic.
	// Reaching the agent at all would trip the "session must exist" assert
	// below it, so a silently-fulfilled refusal cannot pass this test either.
	void drainPromiseNextTicks()
	{
		for (;;)
		{
			auto handlers = __traits(getMember, socketManager, "nextTickHandlers");
			if (handlers.length == 0)
				return;
			mixin(`__traits(getMember, socketManager, "nextTickHandlers") = null;`);
			foreach (handler; handlers)
				handler();
		}
	}

	string[] funnelRefusals;
	foreach (text; ["internal", "queued before undo"])
		app.sendPreparedTaskMessage(tid, [ContentBlock("text", text)])
			.except((Exception e) { funnelRefusals ~= e.msg; }).ignoreResult();
	drainPromiseNextTicks();
	assert(funnelRefusals.length == 2 && funnelRefusals[0].canFind("not sent")
		&& funnelRefusals[1].canFind("not sent"),
		"Refused funnel delivery must reject the submission promise");
	assert(ws.sent.length == 2, "Funnel refusal must not emit a socket error");

	app.tasks[tid].markNativeUndoUnverified();
	app.handleUserMessage(ws, WsMessage(type: "message", tid: tid,
		correlation_id: "native-undo-nonce"));
	assert(ws.sent.length == 4
		&& ws.sent[$ - 2].canFind("may already have changed or lost history")
		&& ws.sent[$ - 2].canFind("blocked only in this running CyDo process")
		&& ws.sent[$ - 1].canFind(`"type":"cydo/submission_rejected"`)
		&& ws.sent[$ - 1].canFind(`"correlation_id":"native-undo-nonce"`)
		&& parseJSON(ws.sent[$ - 1])["tid"].integer == tid
		&& ws.sent[$ - 1].canFind(`"kind":"native_undo_refused"`));
}

/// Install robust logger implementation once.
package(cydo) void initLogger()
{
	installRobustLogger();
}

/// Apply the validated log level.
package(cydo) void applyConfiguredLogLevel(string level)
{
	import std.logger : sharedLog, LogLevel;
	switch (level)
	{
		case "trace":    (cast()sharedLog).logLevel = LogLevel.trace; break;
		case "info":     (cast()sharedLog).logLevel = LogLevel.info; break;
		case "warning":  (cast()sharedLog).logLevel = LogLevel.warning; break;
		case "error":    (cast()sharedLog).logLevel = LogLevel.error; break;
		default: assert(false);
	}
}

unittest
{
	auto app = new App;
	app.taskSessionRunner = new TaskSessionRunner(TaskSessionRunnerHost.init);
	app.derivedTextJobs = new DerivedTextJobs(DerivedTextJobsHost(
		snapshotTaskIds: () => app.tasks.keys,
	));
	app.workflowTools = new WorkflowToolsBackend(WorkflowToolsHost.init);
	auto pending = new ToolCallCancellation;
	app.liveToolCalls.openTask(1);
	app.liveToolCalls.register(1, "pending", pending);
	assert(!pending.cancelled);
	app.shutdown();
	assert(pending.cancelled);

	auto late = new ToolCallCancellation;
	app.liveToolCalls.openTask(2);
	app.liveToolCalls.register(2, "late", late);
	assert(late.cancelled);
}

version (unittest)
{
	import std.json : parseJSON;
	import configy.attributes : SetInfo;
	import core.exception : AssertError;
	import core.time : Duration;
	import std.algorithm : canFind, count, countUntil;
	import std.conv : to;
	import std.exception : assertThrown;
	import std.file : exists, mkdirRecurse, remove, rmdirRecurse, tempDir, write;
	import std.path : buildPath;
	import std.process : environment, execute;
	import ae.net.asockets : ConnectionState, IConnection;
	import ae.sys.dataset : joinData;
	import ae.utils.array : as;

	import cydo.agent.contract : SessionConfig;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import cydo.agent.drivers.codex : CodexAgent;
	import cydo.agent.drivers.copilot : CopilotAgent;
	import cydo.runtime.launch.types : ProcessLaunch;
}

version (unittest) private final class TestClaudePromptAgent : ClaudeCodeAgent
{
	override string executableName(string[string] env)
	{
		return "/bin/sh";
	}
}

version (unittest) private final class TestCopilotPromptAgent : CopilotAgent
{
	override string executableName(string[string] env)
	{
		return "/bin/sh";
	}
}

version (unittest) private final class TestCodexPromptAgent : CodexAgent
{
	override string executableName(string[string] env)
	{
		return "/bin/sh";
	}
}

version (unittest) private final class GatedSubmissionSession : AgentSession
{
	Promise!AgentSubmissionReceipt[] gates;
	string[] correlations;
	string[] nativeSubmissionUuids;
	ContentBlock[][] contents;
	MessageSource[] sources;
	size_t sendCalls;
	bool acceptsImages;
	private void delegate(TranslatedEvent) outputHandler_;
	private void delegate(string) nativeSessionStartedHandler_;
	private void delegate(int) exitHandler_;
	private string nativeSessionId_;
	private bool alive_ = true;

	Promise!AgentSubmissionReceipt sendMessage(const(ContentBlock)[] content,
		string correlationId = null, bool isContextBootstrap = false,
		string nativeSubmissionUuid = null, MessageSource source = MessageSource.harness)
	{
		sendCalls++;
		correlations ~= correlationId;
		nativeSubmissionUuids ~= nativeSubmissionUuid;
		contents ~= content.dup;
		sources ~= source;
		auto gate = new Promise!AgentSubmissionReceipt;
		gates ~= gate;
		return gate;
	}

	void accept(size_t index, AgentSubmissionReceipt receipt)
	{
		gates[index].fulfill(receipt);
	}

	void reject(size_t index, string message)
	{
		gates[index].reject(new Exception(message));
	}

	void deliverServerExit(int status)
	{
		alive_ = false;
		auto cb = exitHandler_;
		exitHandler_ = null;
		if (cb !is null)
			cb(status);
	}

	TranslatedEvent nativeUserEcho(string text, string correlationId = null,
		string nativeSubmissionUuid = null)
	{
		ItemStartedEvent event;
		event.item_id = "gated-user";
		event.uuid = nativeSubmissionUuid;
		event.item_type = "user_message";
		event.content = [ContentBlock("text", text)];
		event.correlation_id = correlationId;
		return TranslatedEvent(toJson(event), null);
	}

	void emitNativeUserEcho(string text, string correlationId = null,
		string nativeSubmissionUuid = null)
	{
		auto event = nativeUserEcho(text, correlationId, nativeSubmissionUuid);
		auto output = outputHandler_;
		onNextTick(socketManager, {
			if (output)
				output(event);
		});
	}

	void acceptAndEmitUserEcho(size_t index, string text)
	{
		accept(index, AgentSubmissionReceipt.appServerAccepted);
		emitNativeUserEcho(text, correlations[index]);
	}

	void emitNativeSessionStarted(string sessionId)
	{
		nativeSessionId_ = sessionId;
		if (nativeSessionStartedHandler_ !is null)
			nativeSessionStartedHandler_(sessionId);
	}

	void invalidatePendingSubmittedMessages() {}
	@property bool supportsImages() const { return acceptsImages; }
	void interrupt() {}
	void sigint() {}
	void stop() {}
	void closeStdin() {}
	void killAfterTimeout(Duration timeout) {}
	@property bool canStopAfterCloseStdin() const { return true; }
	@property const(BackgroundWork)[] backgroundWork() { return null; }
	@property void onNativeSessionStarted(void delegate(string) dg)
	{
		nativeSessionStartedHandler_ = dg;
		if (nativeSessionId_.length > 0 && dg !is null)
			dg(nativeSessionId_);
	}
	@property void onOutput(void delegate(TranslatedEvent) dg) { outputHandler_ = dg; }
	@property string startupFailure() { return null; }
	@property void onStderr(void delegate(string line) dg) {}
	@property void onExit(void delegate(int status) dg) { exitHandler_ = dg; }
	@property void onToolCallsAbandoned(void delegate() dg) {}
	@property bool toolCallsSurviveStdinClose() { return false; }
	@property bool alive() { return alive_; }
}

version (unittest) private final class GatedSubmissionRunner : TaskSessionRunner
{
	private AgentSession session_;
	private bool deferSessionUntilAlive_;
	private bool[int] launched_;
	size_t[int] sessionForTaskLookups;
	void delegate(int) onLaunch;
	/// When set, replaces the default `noSession()` resolution — used by
	/// tests that need `resolveTaskHistory` to resolve some other kind.
	TaskHistoryResolution delegate(int tid) resolveTaskHistoryOverride;

	this(AgentSession session, bool deferSessionUntilAlive = false)
	{
		super(TaskSessionRunnerHost.init);
		session_ = session;
		deferSessionUntilAlive_ = deferSessionUntilAlive;
	}

	override AgentSession sessionForTask(int tid)
	{
		sessionForTaskLookups[tid]++;
		if (deferSessionUntilAlive_ && tid !in launched_)
			return null;
		return session_;
	}

	override TaskHistoryResolution resolveTaskHistory(int tid)
	{
		return resolveTaskHistoryOverride is null
			? TaskHistoryResolution.noSession()
			: resolveTaskHistoryOverride(tid);
	}

	override Promise!ProcessState delegate(ProcessState) makeProcessQueueSF(int tid)
	{
		return (ProcessState state) {
			assert(state == ProcessState.Alive);
			if (onLaunch !is null)
				onLaunch(tid);
			launched_[tid] = true;
			return resolve(state);
		};
	}
}

version (unittest)
	import cydo.agent.contract : DriverHistory, DriverHistoryLaunch, DriverServedHistoryAgent;

version (unittest) private final class GatedSubmissionCodexAgent : CodexAgent
{
	GatedSubmissionSession session;

	override AgentSession createSession(int tid, string resumeSessionId,
		ProcessLaunch launch, SessionConfig config = SessionConfig.init)
	{
		session = new GatedSubmissionSession;
		return session;
	}

	override Promise!DriverHistory loadHistory(string sessionId,
		const ref NativeHistoryProfile profile, AgentSession delegate() currentOwner,
		DriverHistoryLaunch delegate() obtainLaunch)
	{
		assert(0, "Exit fixture does not request driver history");
	}
}

/// Avoid process-launch setup while retaining TaskSessionRunner's production
/// session callback wiring and exit handling.
version (unittest) private final class PreparedSubmissionExitRunner : TaskSessionRunner
{
	this(TaskSessionRunnerHost host)
	{
		super(host);
	}

	override TaskSessionLaunch prepareTaskSessionLaunch(int tid, Agent taskAgent,
		TaskTypeDef* typeDef)
	{
		return TaskSessionLaunch.init;
	}
}

version (unittest) private final class SubmissionCaptureWebSocket : WebSocketAdapter
{
	string[] sent;
	private void delegate(string) onSend_;

	this(void delegate(string) onSend = null)
	{
		onSend_ = onSend;
		super(new class IConnection
		{
			ConnectionState state_ = ConnectionState.connected;
			void delegate(string, DisconnectType) disconnectHandler;

			@property ConnectionState state() { return state_; }
			void send(scope Data[] data, int priority) {}
			void disconnect(string reason, DisconnectType type)
			{
				state_ = ConnectionState.disconnected;
				disconnectHandler(reason, type);
			}
			@property void handleConnect(void delegate() value) {}
			@property void handleReadData(void delegate(Data) value) {}
			@property void handleDisconnect(void delegate(string, DisconnectType) value)
			{
				disconnectHandler = value;
			}
			@property void handleBufferFlushed(void delegate() value) {}
		});
	}

	override void send(scope Data[] data, int priority)
	{
		// Mirrors ae's own TcpConnection.send assert: a real disconnected
		// socket would abort the process here, so the fake must too, or a
		// caller that forgets to route through ClientHub's liveness check
		// would pass this test suite while still crashing in production.
		assert(state == ConnectionState.connected,
			"Attempted to send on a disconnected fake socket");
		auto payload = cast(string) data.joinData().toGC().as!string;
		sent ~= payload;
		if (onSend_)
			onSend_(payload);
	}
}

unittest
{
	auto childCounts = countTaskListChildren([
		TaskListScope(1, 0, "main", "/repo"),
		TaskListScope(2, 1, "main", "/repo"),
		TaskListScope(3, 2, "main", "/repo"),
		TaskListScope(4, 1, "main", "/other-project"),
		TaskListScope(5, 1, "other", "/repo"),
		TaskListScope(6, 0, "main", ""),
		TaskListScope(7, 6, "main", ""),
		TaskListScope(8, 1, "main", "/repo"),
	]);
	assert(childCounts[1] == 2,
		"Only same-workspace, same-project direct children count");
	assert(childCounts[2] == 1, "Grandchildren count only for their direct parent");
	assert(childCounts[6] == 0, "Parents without a project do not advertise children");
	assert(childCounts[3] == 0 && childCounts[4] == 0 && childCounts[5] == 0
		&& childCounts[7] == 0 && childCounts[8] == 0);
}

unittest
{
	auto defs = buildPath(tempDir(), "cydo-app-websocket-snapshot");
	mkdirRecurse(buildPath(defs, "prompts"));
	scope (exit) rmdirRecurse(defs);
	auto definitions = buildPath(defs, "task-types.yaml");
	write(definitions, "task_types: {}\n");
	write(buildPath(defs, "prompts", "blank.md"), "Blank prompt\n");

	auto app = new App;
	AgentConfig agentConfig;
	agentConfig.driver = typeof(agentConfig.driver)(AgentDriver.claude, true);
	app.config.agents["claude"] = agentConfig;
	app.config.default_agent = "claude";
	app.agentsByName["claude"] = new TestClaudePromptAgent;
	app.taskTypeCatalog = new TaskTypeCatalog(defs, definitions, (string) => true);
	app.discoveryService = new DiscoveryService(DiscoveryServiceHost.init);
	app.heicConverter = new UnavailableHeicConverter("not configured");
	auto runner = new GatedSubmissionRunner(new GatedSubmissionSession);
	app.taskSessionRunner = runner;

	void addTask(int tid, int parentTid, string workspace, string projectPath,
		bool archived = false)
	{
		app.tasks[tid] = TaskData(tid, workspace, projectPath);
		app.tasks[tid].parentTid = parentTid;
		app.tasks[tid].archived = archived;
	}

	addTask(1, 0, "main", "/repo");
	addTask(2, 1, "main", "/repo", true);
	addTask(3, 2, "main", "/repo");
	addTask(4, 1, "main", "/other-project");
	addTask(5, 1, "other", "/repo");
	addTask(6, 0, "main", "");
	addTask(7, 6, "main", "");

	auto ws = new SubmissionCaptureWebSocket;
	scope(exit)
	{
		ws.disconnect("test complete", DisconnectType.requested);
		app.clientHub.remove(ws);
	}
	app.onWebSocketAccepted(ws);
	foreach (tid; [1, 2, 3, 4, 5, 6, 7])
		assert(runner.sessionForTaskLookups[tid] == 2,
			"Each snapshot task samples taskAlive and taskCanStop once");
	app.broadcastTaskUpdate(1);

	assert(ws.sent.length == 10);
	assert(ws.sent[0].canFind(`"type":"workspaces_list"`));
	assert(ws.sent[1].canFind(`"type":"task_types_list"`));
	assert(ws.sent[2].canFind(`"type":"agents_list"`));

	int[] snapshotTids;
	foreach (index; 3 .. 7)
	{
		auto packet = jsonParse!TasksListMessage(ws.sent[index]);
		assert(packet.type == "tasks_list");
		assert(packet.complete == (index == 6));
		foreach (entry; packet.tasks)
		{
			assert(!snapshotTids.canFind(entry.tid));
			snapshotTids ~= entry.tid;
		}
	}
	assert(snapshotTids == [1, 6, 4, 5, 7, 2, 3]);
	auto earlyPacket = jsonParse!TasksListMessage(ws.sent[3]);
	assert(earlyPacket.tasks.length == 2);
	assert(earlyPacket.tasks[0].tid == 1);
	assert(earlyPacket.tasks[0].childCount == 1,
		"Raw-archived same-scope children count in the frozen early packet");
	auto finalPacket = jsonParse!TasksListMessage(ws.sent[6]);
	assert(finalPacket.tasks.length == 2);
	assert(finalPacket.tasks[0].tid == 2 && finalPacket.tasks[0].archived);
	assert(finalPacket.tasks[1].tid == 3 && !finalPacket.tasks[1].archived,
		"Archived ancestry delivers descendants last without changing raw archive state");
	assert(ws.sent[7].canFind(`"type":"server_status"`));
	assert(ws.sent[8].canFind(`"type":"notices_list"`));
	assert(ws.sent[9].canFind(`"type":"task_updated"`));

	auto update = jsonParse!TaskUpdatedMessage(ws.sent[9]);
	assert(update.task.tid == 1);
	assert(update.task.childCount == 1,
		"Raw-archived same-scope children count, while cross-scope rows do not");
}

version (unittest)
	import cydo.server.attachment_intake : GatedFakeConverter, testHeicBlock, testJpegBytes;

version (unittest) private final class GatedSubmissionFixture
{
	App app;
	GatedFakeConverter converter;
	GatedSubmissionSession session;
	SubmissionCaptureWebSocket socket;
	string[] submissionMessages;
	int[] submissionTids;
	string[] publicationOrder;
	size_t titlePromptReads;
	int[] titlePromptTids;
	int tid;

	void attachClaudeMirror(int tid, string path = null)
	{
		import cydo.runtime.launch.types : NativeHistoryProfile;
		import cydo.workflow.history.native_history : LiveHistoryContext;

		auto agent = app.agentsByName["claude"];
		auto context = LiveHistoryContext(agent,
			NativeHistoryProfile(agent.driver, "/tmp/cydo-app-attachment-profile"),
			"attachment-session");
		auto target = LiveHistoryWatchTarget(context, path is null
			? buildPath(context.profile.root, "attachment-session.jsonl") : path);
		app.jsonlTracker.onClaudeTranscriptRow = &app.onClaudeTranscriptRow;
		app.jsonlTracker.resolveLiveHistoryWatch = (int lookupTid) {
			assert(lookupTid == tid);
			return LiveHistoryWatchResolution.target(target);
		};
		app.jsonlTracker.startJsonlWatch(tid);
	}

	this(string dbPath)
	{
		app = new App();
		converter = new GatedFakeConverter;
		app.heicConverter = converter;
		app.submissionIntake = new SubmissionIntake(converter);
		app.persistence = Persistence(dbPath);
		tid = app.persistence.createTask();
		app.tasks[tid] = TaskData(tid, "local", "/tmp/cydo-app-submission");
		app.tasks[tid].taskType = "test";
		app.tasks[tid].description = "existing description";
		app.tasks[tid].title = "existing title";
		app.tasks[tid].status = TaskStatus.active;
		app.tasks[tid].history.reset(Watermark.none());
		AgentConfig testConfig;
		testConfig.driver = typeof(testConfig.driver)(AgentDriver.codex, true);
		app.config.agents["test"] = testConfig;
		app.agentsByName["test"] = new TestCodexPromptAgent;
		AgentConfig claudeConfig;
		claudeConfig.driver = typeof(claudeConfig.driver)(AgentDriver.claude, true);
		app.config.agents["claude"] = claudeConfig;
		app.agentsByName["claude"] = new TestClaudePromptAgent;
		auto defs = buildPath(tempDir(), "cydo-app-submission-task-types");
		mkdirRecurse(defs);
		scope (exit) rmdirRecurse(defs);
		auto definitions = buildPath(defs, "task-types.yaml");
		write(definitions, "task_types: {}\n");
		auto bundled = environment.get("CYDO_TEST_DEFS", "defs");
		app.taskTypeCatalog = new TaskTypeCatalog(bundled, definitions, (string name) => true);
		app.taskTypeCatalog.reloadGlobal();
		socket = new SubmissionCaptureWebSocket((string payload) {
			if (payload.canFind(`"type":"task_updated"`))
				publicationOrder ~= "task_update";
			else if (payload.canFind(`"agentAck"`))
				publicationOrder ~= "agent_ack";
			else if (payload.canFind(`"type":"task_reload"`))
				publicationOrder ~= "task_reload";
			else if (payload.canFind(`"type":"title_update"`))
				publicationOrder ~= "title_update";
			else if (payload.canFind(`"type":"draft_updated"`))
				publicationOrder ~= "draft_updated";
		});
		app.clientHub.add(socket);
		app.clientHub.subscribe(socket, tid);
		app.tasks[tid].processQueue = new StateQueue!ProcessState(
			(ProcessState state) { return resolve(state); },
			ProcessState.Alive,
		);
			app.jsonlTracker.getTask = (int lookupTid) {
				auto task = lookupTid in app.tasks;
				return task is null ? null : task;
			};
		app.jsonlTracker.resolveTaskHistory = (int lookupTid) =>
			TaskHistoryResolution.noSession();
		app.jsonlTracker.historyGeneration = (int lookupTid) {
			auto task = lookupTid in app.tasks;
			assert(task !is null,
				"history generation requested for missing task");
			return task.history.generation;
		};
		app.jsonlTracker.onBoundaryResolved = (int resolvedTid, size_t seq,
			HistoryBoundary boundary, bool publish, ulong generation) {
			auto task = resolvedTid in app.tasks;
			if (task is null || task.history.generation != generation)
				return;
			app.historyPipeline.backfillHistoryBoundary(resolvedTid, seq, boundary, publish);
		};
		app.archiveManager = new ArchiveManager(ArchiveManagerHost(
			tryGetTask: (int lookupTid, out ArchiveTaskSnapshot snapshot) {
				auto task = lookupTid in app.tasks;
				if (task is null)
					return false;
				snapshot.tid = lookupTid;
				snapshot.archiving = task.archiving;
				return true;
			},
		));
		app.historyPipeline = new HistoryEventPipeline(HistoryEventPipelineHost(
			getTask: (int lookupTid) {
				auto task = lookupTid in app.tasks;
				return task is null ? null : task;
			},
			makeTaskDiagnosticEventJson: (string subject, string body) {
				TaskDiagnosticEvent event;
				event.severity = TaskDiagnosticSeverity.error;
				event.subject = subject;
				event.body = body;
				return toJson(event);
			},
			sendToSubscribed: (int broadcastTid, Data data) {
				submissionTids ~= broadcastTid;
				submissionMessages ~= cast(string) data.toGC().as!string;
				publicationOrder ~= "unconfirmed";
			},
			normalizeKnownSystemMessageMeta: (string translated, int) => translated,
			noteLiveBoundaryCandidate: (int broadcastTid, size_t seq, string event,
				string raw, int sourceLine,
				LocalUserProvenance localUserProvenance) {
				app.jsonlTracker.noteLiveBoundaryCandidate(broadcastTid, seq, event, raw,
					sourceLine,
					localUserProvenance == LocalUserProvenance.registeredLocal);
			},
			planBroadcast: (int broadcastTid, TranslatedEvent event) {
				return app.planHistoryBroadcast(broadcastTid, event);
			},
			broadcastHistoryOperations: (int) {},
		));
		app.derivedTextJobs = new DerivedTextJobs(DerivedTextJobsHost(
			getTask: (int lookupTid) {
				auto task = lookupTid in app.tasks;
				return task is null ? null : task;
			},
			suggestionsEnabled: () => app.config.suggestions,
			readPromptFile: (int lookupTid, string relativePath,
				string[string] vars) {
				assert(relativePath == "prompts/generate-title.md");
				titlePromptReads++;
				titlePromptTids ~= lookupTid;
				return "";
			},
		));
		session = new GatedSubmissionSession;
		app.taskSessionRunner = new GatedSubmissionRunner(session);
	}
}

// A turn/start reply received just before EOF must commit and ACK while
// the application can still use the session and its history generation.
unittest
{
	import cydo.agent.drivers.codex : makeCodexSubmissionSessionForTest;
	import cydo.foundation.testing : drainNextTicksAndDueTimers;

	auto fixture = new GatedSubmissionFixture(":memory:");
	void delegate(int) replyThenExit;
	auto session = makeCodexSubmissionSessionForTest(fixture.tid, replyThenExit);
	fixture.app.taskSessionRunner = new GatedSubmissionRunner(session);
	auto task = &fixture.app.tasks[fixture.tid];
	auto generation = task.history.generation;
	enum nonce = "last-turn-nonce";
	int[] exits;
	session.onExit = (int status) {
		assert(nonce in task.recentNonces);
		assert(task.history.generation == generation);
		assert(fixture.publicationOrder == ["unconfirmed", "task_update", "agent_ack"]);
		exits ~= status;
		fixture.app.taskSessionRunner = new GatedSubmissionRunner(null);
		task.history.reset(Watermark.none());
	};

	bool committed;
	fixture.app.sendPreparedTaskMessage(fixture.tid, [ContentBlock("text", "last turn")],
		null, null, false, nonce)
		.then(() { committed = true; }, (Exception e) { assert(false, e.msg); }).ignoreResult();
	assert(fixture.publicationOrder.length == 0);
	replyThenExit(42);
	drainNextTicksAndDueTimers();

	assert(committed && exits == [42]);
	assert(fixture.submissionMessages.length == 1
		&& fixture.submissionMessages[0].canFind("last turn"));
	assert(fixture.app.sessionForTask(fixture.tid) is null);
}

unittest
{
	auto fixture = new GatedSubmissionFixture(":memory:");
	scope (exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	auto app = fixture.app;
	auto tid = fixture.tid;
	enum previousActivity = 42;
	app.persistence.setLastActive(tid, previousActivity);
	app.tasks[tid].lastActive = previousActivity;

	bool committed;
	app.sendPreparedTaskMessage(tid, [ContentBlock("text", "accepted work")],
		null, null, false, "last-active-nonce")
		.then(() { committed = true; }, (Exception e) { assert(false, e.msg); }).ignoreResult();
	assert(fixture.session.gates.length == 1);
	assert(app.persistence.loadTasks()[0].lastActive == previousActivity);

	fixture.session.accept(0, AgentSubmissionReceipt.localEnqueued);
	drainSubmissionNextTicks();
	assert(committed);
	assert(app.tasks[tid].lastActive > previousActivity);
	assert(app.persistence.loadTasks()[0].lastActive == app.tasks[tid].lastActive);
}

version (unittest) private WsMessage testBrowserSubmission(int tid, string text,
	string nonce)
{
	WsMessage message;
	message.type = "message";
	message.tid = tid;
	message.content = JSONFragment(toJson([ContentBlock("text", text)]));
	message.correlation_id = nonce;
	return message;
}

version (unittest) private string testUserCorrelation(TranslatedEvent event)
{
	return jsonParse!ItemStartedEvent(event.translated).correlation_id;
}

version (unittest) private void drainSubmissionNextTicks()
{
	for (;;)
	{
		auto handlers = __traits(getMember, socketManager, "nextTickHandlers");
		if (handlers.length == 0)
			return;
		mixin(`__traits(getMember, socketManager, "nextTickHandlers") = null;`);
		foreach (handler; handlers)
			handler();
	}
}

version (unittest) private WsMessage testBrowserHeicSubmission(int tid, string text, string nonce)
{
	auto message = testBrowserSubmission(tid, text, nonce);
	message.content = JSONFragment(toJson([ContentBlock("text", text), testHeicBlock()]));
	return message;
}

version (unittest) private auto assertBrowserRejection(
	SubmissionCaptureWebSocket socket, string nonce, int tid, BrowserSubmissionRejectionKind kind)
{
	import std.conv : to;

	assert(submissionRejectionCount(socket.sent) == 1);
	auto rejection = parseJSON(socket.sent[$ - 1]);
	assert(rejection["type"].str == "cydo/submission_rejected"
		&& rejection["correlation_id"].str == nonce && rejection["kind"].str == kind.to!string);
	if (tid >= 0)
		assert(rejection["tid"].integer == tid);
	else
		assert("tid" !in rejection);
	return rejection;
}

version (unittest) private ContentBlock testNormalizedJpeg()
{
	import std.base64 : Base64;
	return ContentBlock(type: "image", data: Base64.encode(testJpegBytes), media_type: "image/jpeg");
}

unittest
{
	auto fixture = new GatedSubmissionFixture(":memory:");
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	auto task = &fixture.app.tasks[fixture.tid];
	task.agentName = "test";
	auto message = testBrowserHeicSubmission(fixture.tid, "photo", "duplicate-photo");
	fixture.app.handleUserMessage(fixture.socket, message);
	drainSubmissionNextTicks();
	assert(message.correlation_id in task.inFlightUiNonceGeneration);
	fixture.app.handleUserMessage(fixture.socket, message);
	drainSubmissionNextTicks();
	assert(fixture.converter.gates.length == 1 && fixture.session.sendCalls == 0
		&& fixture.socket.sent.length == 0);

	fixture.converter.gates[0].fulfill(testJpegBytes);
	drainSubmissionNextTicks();
	assert(fixture.session.sendCalls == 1);
	fixture.session.accept(0, AgentSubmissionReceipt.appServerAccepted);
	drainSubmissionNextTicks();
	assert(fixture.session.sendCalls == 1 && message.correlation_id in task.recentNonces);
}

unittest
{
	auto fixture = new GatedSubmissionFixture(":memory:");
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	fixture.app.tasks[fixture.tid].agentName = "test";
	fixture.session.acceptsImages = true;
	auto message = testBrowserHeicSubmission(fixture.tid, "photo", "normalized-photo");
	fixture.app.handleUserMessage(fixture.socket, message);
	drainSubmissionNextTicks();
	fixture.converter.gates[0].fulfill(testJpegBytes);
	drainSubmissionNextTicks();

	auto expected = [ContentBlock("text", "photo"), testNormalizedJpeg()];
	assert(fixture.session.sendCalls == 1 && fixture.session.contents[0] == expected);
	fixture.session.accept(0, AgentSubmissionReceipt.appServerAccepted);
	drainSubmissionNextTicks();
	assert(fixture.submissionMessages.length == 1);
	auto envelope = jsonParse!UnconfirmedUserEventEnvelope(fixture.submissionMessages[0]);
	auto event = jsonParse!ItemStartedEvent(envelope.unconfirmedUserEvent.json);
	assert(envelope.tid == fixture.tid && event.content == expected);
}

unittest
{
	auto fixture = new GatedSubmissionFixture(":memory:");
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	fixture.app.tasks[fixture.tid].agentName = "test";
	fixture.app.handleUserMessage(fixture.socket,
		testBrowserHeicSubmission(fixture.tid, "first", "first-photo"));
	fixture.app.handleUserMessage(fixture.socket,
		testBrowserSubmission(fixture.tid, "second", "second-text"));
	drainSubmissionNextTicks();
	assert(fixture.converter.gates.length == 1 && fixture.session.sendCalls == 0);
	fixture.converter.gates[0].fulfill(testJpegBytes);
	drainSubmissionNextTicks();
	assert(fixture.session.correlations == ["first-photo", "second-text"]);
	fixture.session.accept(0, AgentSubmissionReceipt.appServerAccepted);
	fixture.session.accept(1, AgentSubmissionReceipt.appServerAccepted);
	drainSubmissionNextTicks();
}

unittest
{
	auto fixture = new GatedSubmissionFixture(":memory:");
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	auto task = &fixture.app.tasks[fixture.tid];
	task.agentName = "test";
	fixture.session.acceptsImages = true;
	enum submittedDraft = "draft being submitted";
	enum newerDraft = "new draft saved during conversion";

	void saveDraft(string draft)
	{
		fixture.app.handleSetDraftMsg(fixture.socket, WsMessage(type: "set_draft",
			tid: fixture.tid, content: JSONFragment(toJson(draft))));
		assert(task.draft == draft && fixture.app.persistence.loadTasks()[0].draft == draft);
	}

	saveDraft(submittedDraft);
	fixture.app.handleUserMessage(fixture.socket,
		testBrowserHeicSubmission(fixture.tid, submittedDraft, "photo-with-draft"));
	fixture.app.handleUserMessage(fixture.socket,
		testBrowserSubmission(fixture.tid, submittedDraft, "queued-text-with-draft"));
	drainSubmissionNextTicks();
	assert(fixture.converter.gates.length == 1 && fixture.session.sendCalls == 0);

	saveDraft(newerDraft);
	fixture.converter.gates[0].fulfill(testJpegBytes);
	drainSubmissionNextTicks();
	assert(fixture.session.correlations == ["photo-with-draft", "queued-text-with-draft"]);
	foreach (i, nonce; fixture.session.correlations)
	{
		fixture.session.accept(i, AgentSubmissionReceipt.appServerAccepted);
		drainSubmissionNextTicks();
		assert(nonce in task.recentNonces);
		assert(task.draft == newerDraft, "Accepting " ~ nonce ~ " erased the newer in-memory draft");
		assert(fixture.app.persistence.loadTasks()[0].draft == newerDraft,
			"Accepting " ~ nonce ~ " erased the newer persisted draft");
	}
}

unittest
{
	foreach (undo; [true, false])
	{
		auto fixture = new GatedSubmissionFixture(":memory:");
		scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
		auto task = &fixture.app.tasks[fixture.tid];
		task.agentName = "test";
		if (undo)
			task.beginConfirmedNativeUndo();
		else
			task.archiving = true;
		auto message = testBrowserHeicSubmission(fixture.tid, "blocked photo", "blocked-photo");
		fixture.app.handleUserMessage(fixture.socket, message);
		assertBrowserRejection(fixture.socket, message.correlation_id, fixture.tid, undo
			? BrowserSubmissionRejectionKind.native_undo_refused
			: BrowserSubmissionRejectionKind.task_archiving);
		drainSubmissionNextTicks();
		assert(fixture.converter.inputs.length == 0 && fixture.session.sendCalls == 0);
	}
}

unittest
{
	auto fixture = new GatedSubmissionFixture(":memory:");
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	fixture.app.tasks[fixture.tid].agentName = "test";
	fixture.app.heicConverter = new UnavailableHeicConverter("no bwrap");
	fixture.app.submissionIntake = new SubmissionIntake(fixture.app.heicConverter);
	auto message = testBrowserHeicSubmission(fixture.tid, "photo", "unavailable-photo");
	fixture.app.handleUserMessage(fixture.socket, message);
	drainSubmissionNextTicks();
	auto rejection = assertBrowserRejection(fixture.socket, message.correlation_id, fixture.tid,
		BrowserSubmissionRejectionKind.attachment_rejected);
	assert(rejection["attachment"].integer == 0 && rejection["reason"].str.canFind("no bwrap"));
	assert(fixture.session.sendCalls == 0);
}

version (linux) unittest
{
	import cydo.runtime.image.converter : makeGatedStartupConverter;

	auto fixture = new GatedSubmissionFixture(":memory:");
	scope (exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	fixture.app.tasks[fixture.tid].agentName = "test";
	auto gate = new Promise!(immutable(ubyte)[]);
	fixture.app.heicConverter = makeGatedStartupConverter(gate, &fixture.app.broadcastServerStatus);
	fixture.app.submissionIntake = new SubmissionIntake(fixture.app.heicConverter);

	auto message = testBrowserHeicSubmission(fixture.tid, "photo", "checking-photo");
	fixture.app.handleUserMessage(fixture.socket, message);
	drainSubmissionNextTicks();
	auto rejection = assertBrowserRejection(fixture.socket, message.correlation_id, fixture.tid,
		BrowserSubmissionRejectionKind.attachment_rejected);
	assert(rejection["attachment"].integer == 0);
	assert(rejection["reason"].str ==
		"HEIC conversion is unavailable on this server: checking the HEIC converter");
	assert(fixture.session.sendCalls == 0);
	gate.fulfill(testJpegBytes);
	drainSubmissionNextTicks();
}

version (linux) unittest
{
	import cydo.runtime.image.converter : makeGatedStartupConverter;

	auto app = new App;
	auto first = new SubmissionCaptureWebSocket;
	scope (exit) first.disconnect("test complete", DisconnectType.requested);
	auto second = new SubmissionCaptureWebSocket;
	scope (exit) second.disconnect("test complete", DisconnectType.requested);
	app.clientHub.add(first);
	app.clientHub.add(second);
	auto gate = new Promise!(immutable(ubyte)[]);
	app.heicConverter = makeGatedStartupConverter(gate, &app.broadcastServerStatus);
	assert(first.sent.length == 0 && second.sent.length == 0);
	gate.fulfill(testJpegBytes);
	drainSubmissionNextTicks();

	foreach (client; [first, second])
	{
		assert(client.sent.length == 1);
		auto packet = parseJSON(client.sent[0]);
		assert(packet["type"].str == "server_status");
		assert(packet["heic_conversion"]["available"].boolean);
	}
}

unittest
{
	import std.conv : to;

	auto app = new App;
	app.persistence = Persistence(":memory:");
	auto asker = app.persistence.createTask();
	auto target = app.persistence.createTask();
	app.tasks[asker] = TaskData(asker, "local", "/tmp/cydo-app-delete-ask");
	app.tasks[asker].status = TaskStatus.waiting;
	app.tasks[target] = TaskData(target, "local", "/tmp/cydo-app-delete-ask");
	app.taskSessionRunner = new TaskSessionRunner(TaskSessionRunnerHost.init);
	app.workflowTools = new WorkflowToolsBackend(WorkflowToolsHost(
		getTask: (int tid) => tid in app.tasks,
		tasksShareWorkspace: (int, int) => true,
		shuttingDown: () => false,
		persistInsertQuestion: &app.persistence.insertQuestion,
		persistDeleteQuestion: &app.persistence.deleteQuestion,
		broadcastFocusHint: (int, int) {},
	));

	McpResult[] results;
	app.workflowTools.handleAsk(asker.to!string, null, "question for pending task", target)
		.then((McpResult result) { results ~= result; }).ignoreResult();
	drainSubmissionNextTicks();
	auto questions = app.persistence.loadQuestions();
	assert(questions.length == 1);
	assert(questions[0].askerTid == asker && questions[0].answererTid == target);
	assert(questions[0].text == "question for pending task");
	assert(results.length == 0);

	WsMessage deletion;
	deletion.type = "delete_task";
	deletion.tid = target;
	app.handleDeleteTaskMsg(deletion);
	drainSubmissionNextTicks();

	assert(target !in app.tasks);
	auto remaining = app.persistence.loadTasks();
	assert(remaining.length == 1 && remaining[0].tid == asker);
	assert(results.length == 1, "Deleting the target must settle the blocked Ask once");
	assert(results[0].isError);
	assert(results[0].text == "Question " ~ questions[0].qid.to!string
		~ ": Session ended while waiting for Ask response");
	assert(app.persistence.loadQuestions().length == 0);
}

version (unittest) private final class PendingBatchDeletionFixture
{
	App app;
	int parent, deleted, survivor;
	string[] deliveries;
	int[2][] focusHints;

	this(bool hasSibling)
	{
		app = new App;
		app.persistence = Persistence(":memory:");
		parent = app.persistence.createTask();
		deleted = app.persistence.createTask();
		app.tasks[parent] = TaskData(parent, "local", "/tmp/cydo-app-delete-batch");
		addChild(deleted, 0);
		if (hasSibling)
		{
			survivor = app.persistence.createTask();
			addChild(survivor, 1);
			app.tasks[survivor].status = TaskStatus.active;
		}
		app.taskSessionRunner = new TaskSessionRunner(TaskSessionRunnerHost.init);
		app.workflowTools = new WorkflowToolsBackend(WorkflowToolsHost(
			getTask: (int tid) => tid in app.tasks,
			broadcastFocusHint: (int fromTid, int toTid) {
				focusHints ~= [fromTid, toTid];
			},
			loadTaskDeps: &app.persistence.loadTaskDeps,
			loadQuestions: &app.persistence.loadQuestions,
			persistRemoveTaskBatch: &app.persistence.removeTaskBatch,
			shuttingDown: () => false,
			systemKeyword: () => "SYSTEM",
			buildKnownSystemMessageMeta: (KnownSystemMessageKind kind, string subject,
				string[string] vars, string bodyVar) => "{}",
			sendPreparedKnownSystemMessage: (int tid, const(ContentBlock)[] blocks,
				string meta, string nonce) {
				assert(tid == parent && blocks.length == 1);
				deliveries ~= blocks[0].text;
				return resolve();
			},
			ensureProcessQueueAlive: (int tid) => resolve(),
			outputPath: (const TaskData* td) => "",
			taskProducesCommitOutput: (string path, string typ) => false,
		));
	}

	private void addChild(int tid, size_t ordinal)
	{
		app.tasks[tid] = TaskData(tid, "local", "/tmp/cydo-app-delete-batch");
		app.tasks[tid].parentTid = parent;
		app.tasks[tid].relationType = "subtask";
		app.persistence.addTaskDep(parent, tid, cast(ulong) deleted, ordinal);
	}

	void deletePendingChild()
	{
		app.handleDeleteTaskMsg(WsMessage(type: "delete_task", tid: deleted));
		assert(deleted !in app.tasks);
		drainSubmissionNextTicks();
	}

	void completeSibling()
	{
		app.tasks[survivor].status = TaskStatus.completed;
		app.tasks[survivor].resultText = "survivor-result";
		assert(app.workflowTools.recordChildTerminal(survivor));
		drainSubmissionNextTicks();
	}

	void assertBatchCleared()
	{
		assert(!app.workflowTools.hasRestoredWork(parent));
		assert(app.persistence.loadTaskDeps().length == 0);
	}
}

unittest
{
	import std.algorithm : canFind;

	enum Sibling { completesAfterDeletion, alreadyRecorded, none }

	foreach (sibling; [Sibling.completesAfterDeletion, Sibling.alreadyRecorded, Sibling.none])
	{
		auto f = new PendingBatchDeletionFixture(sibling != Sibling.none);
		f.app.tasks[f.parent].status = TaskStatus.waiting;
		f.app.workflowTools.rebuildWaits();

		if (sibling == Sibling.alreadyRecorded)
			f.completeSibling();
		assert(f.deliveries.length == 0 && f.focusHints.length == 0);

		f.deletePendingChild();
		if (sibling == Sibling.completesAfterDeletion)
		{
			auto batches = f.app.persistence.loadTaskDeps();
			assert(batches.length == 1 && batches[0].childTids == [f.survivor]);
			assert(f.deliveries.length == 0 && f.focusHints.length == 0);
			f.completeSibling();
		}

		assert(f.deliveries.length == 1, "Deleting the legacy pending slot must let the batch settle");
		if (sibling == Sibling.none)
		{
			assert(f.deliveries[0].canFind("<task_results>\n[]\n</task_results>"));
			assert(f.focusHints.length == 0);
		}
		else
		{
			assert(f.deliveries[0].canFind("survivor-result"));
			assert(f.focusHints == [[f.survivor, f.parent]]);
		}
		f.assertBatchCleared();
	}
}

unittest
{
	auto dbPath = buildPath(tempDir(), "cydo-app-claude-alias-native-uuid.sqlite");
	if (exists(dbPath)) remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);

	auto fixture = new GatedSubmissionFixture(dbPath);
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	AgentConfig config;
	config.driver = typeof(config.driver)(AgentDriver.claude, true);
	fixture.app.config.agents["work-claude"] = config;
	fixture.app.agentsByName["work-claude"] = new TestClaudePromptAgent;
	auto aliasTid = fixture.app.persistence.createTask();
	fixture.app.tasks[aliasTid] = TaskData(aliasTid, "local", "/tmp/alias");
	auto task = &fixture.app.tasks[aliasTid];
	task.taskType = "test";
	task.agentName = "work-claude";
	task.status = TaskStatus.active;
	task.history.reset(Watermark.none());
	task.processQueue = new StateQueue!ProcessState(
		(ProcessState state) { return resolve(state); }, ProcessState.Alive);
	fixture.app.clientHub.subscribe(fixture.socket, aliasTid);

	fixture.app.sendTaskMessage(aliasTid, [ContentBlock("text", "alias prompt")])
		.ignoreResult();
	assert(fixture.session.gates.length == 1);
	fixture.session.accept(0, AgentSubmissionReceipt.localEnqueued);
	drainSubmissionNextTicks();
	assert(task.nativeSubmissionCount == 1);
}

unittest
{
	auto dbPath = buildPath(tempDir(), "cydo-app-submission-transaction.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);

	auto app = new App();
	app.persistence = Persistence(dbPath);
	auto tid = app.persistence.createTask();
	app.tasks[tid] = TaskData(tid, "local", "/tmp/cydo-app-submission");
	app.tasks[tid].agentName = "test";
	app.tasks[tid].taskType = "test";
	app.tasks[tid].status = TaskStatus.active;
	app.tasks[tid].history.reset(Watermark.none());
	AgentConfig testConfig;
	testConfig.driver = typeof(testConfig.driver)(AgentDriver.codex, true);
	app.config.agents["test"] = testConfig;
	app.agentsByName["test"] = new TestCodexPromptAgent;
	app.jsonlTracker.getTask = (int lookupTid) {
		auto task = lookupTid in app.tasks;
		return task is null ? null : task;
	};
	app.jsonlTracker.resolveTaskHistory = (int lookupTid) =>
		TaskHistoryResolution.noSession();

	size_t userEventBroadcasts;
	app.historyPipeline = new HistoryEventPipeline(HistoryEventPipelineHost(
		getTask: (int lookupTid) {
			auto task = lookupTid in app.tasks;
			return task is null ? null : task;
		},
		sendToSubscribed: (int broadcastTid, Data data) {
			assert(broadcastTid == tid);
			userEventBroadcasts++;
		},
	));
	app.derivedTextJobs = new DerivedTextJobs(DerivedTextJobsHost(
		getTask: (int lookupTid) {
			auto task = lookupTid in app.tasks;
			return task is null ? null : task;
		},
		suggestionsEnabled: () => app.config.suggestions,
	));
	auto session = new GatedSubmissionSession;
	app.taskSessionRunner = new GatedSubmissionRunner(session);
	TranslatedEvent[] userEchoes;
	session.onOutput = (TranslatedEvent event) {
		auto plan = app.planHistoryBroadcast(tid, event);
		assert(!plan.consumeCurrent);
		userEchoes ~= plan.currentEvent;
	};

	void assertSingleCorrelation(TranslatedEvent event, string expectedNonce)
	{
		enum marker = `"correlation_id"`;
		auto first = event.translated.countUntil(marker);
		assert(first >= 0);
		assert(event.translated[first + marker.length .. $].countUntil(marker) < 0);
		auto user = jsonParse!ItemStartedEvent(event.translated);
		assert(user.correlation_id == expectedNonce);
	}

	bool fulfilled;
	app.sendTaskMessage(tid, [ContentBlock("text", "gated submission")], null,
		null, "submission-nonce").then(() {
		fulfilled = true;
	}).ignoreResult();

	assert(session.sendCalls == 1);
	assert(!fulfilled);
	assert(!app.tasks[tid].isProcessing);
	assert(app.tasks[tid].history.length == 0);
	assert(("submission-nonce" in app.tasks[tid].recentNonces) is null);
	assert(app.tasks[tid].nativeSubmissionCount == 0);
	assert(app.tasks[tid].pendingSteeringTexts.length == 0);
	assert(userEventBroadcasts == 0);

	session.acceptAndEmitUserEcho(0, "gated submission");
	drainSubmissionNextTicks();

	assert(fulfilled);
	assert(app.tasks[tid].isProcessing);
	assert(app.tasks[tid].history.length == 1);
	assert(("submission-nonce" in app.tasks[tid].recentNonces) !is null);
	assert(userEventBroadcasts == 1);
	assert(userEchoes.length == 1);
	assertSingleCorrelation(userEchoes[0], "submission-nonce");
	assert(app.tasks[tid].nativeSubmissionCount == 0);

	bool secondFulfilled;
	app.sendTaskMessage(tid, [ContentBlock("text", "following submission")], null,
		null, "following-nonce").then(() {
		secondFulfilled = true;
	}).ignoreResult();
	assert(session.sendCalls == 2);
	assert(!secondFulfilled);
	session.acceptAndEmitUserEcho(1, "following submission");
	drainSubmissionNextTicks();

	assert(secondFulfilled);
	assert(app.tasks[tid].history.length == 2);
	assert(userEventBroadcasts == 2);
	assert(userEchoes.length == 2);
	assertSingleCorrelation(userEchoes[1], "following-nonce");
	assert(app.tasks[tid].nativeSubmissionCount == 0);
}

unittest
{
	auto dbPath = buildPath(tempDir(), "cydo-app-submission-browser-nonce.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);

	auto fixture = new GatedSubmissionFixture(dbPath);
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	fixture.app.tasks[fixture.tid].agentName = "claude";
	auto message = testBrowserSubmission(fixture.tid, "browser submission",
		"browser-nonce");
	fixture.app.handleUserMessage(fixture.socket, message);
	fixture.app.handleUserMessage(fixture.socket, message);

	assert(("browser-nonce" in fixture.app.tasks[fixture.tid]
		.inFlightUiNonceGeneration) !is null);
	drainSubmissionNextTicks();
	assert(fixture.session.sendCalls == 1 && fixture.session.gates.length == 1);
	assert(fixture.app.tasks[fixture.tid].nativeSubmissionCount == 1
		&& !fixture.app.tasks[fixture.tid].nativeSubmission(
			fixture.session.nativeSubmissionUuids[0]).stdoutSeen);

	fixture.session.reject(0, "submission rejected");
	drainSubmissionNextTicks();
	assert(("browser-nonce" in fixture.app.tasks[fixture.tid]
		.inFlightUiNonceGeneration) is null);
	assert(("browser-nonce" in fixture.app.tasks[fixture.tid].recentNonces)
		is null);
	assert(fixture.app.tasks[fixture.tid].nativeSubmissionCount == 0);

	fixture.app.handleUserMessage(fixture.socket, message);
	drainSubmissionNextTicks();
	assert(fixture.session.sendCalls == 2 && fixture.session.gates.length == 2);
	assert(("browser-nonce" in fixture.app.tasks[fixture.tid]
		.inFlightUiNonceGeneration) !is null);
}

unittest
{
	auto dbPath = buildPath(tempDir(), "cydo-app-browser-acceptance.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);

	auto fixture = new GatedSubmissionFixture(dbPath);
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	auto td = &fixture.app.tasks[fixture.tid];
	td.agentName = "test";
	auto draftSender = new SubmissionCaptureWebSocket;
	scope(exit) draftSender.disconnect("test complete", DisconnectType.requested);
	fixture.app.clientHub.add(draftSender);
	assert(td.draft == "");
	WsMessage setDraft;
	setDraft.type = "set_draft";
	setDraft.tid = fixture.tid;
	setDraft.content = JSONFragment(toJson("first draft"));
	fixture.app.handleSetDraftMsg(draftSender, setDraft);
	assert(draftSender.sent.length == 0);
	assert(fixture.socket.sent.length == 1
		&& fixture.socket.sent[0].canFind(`"old_draft":""`)
		&& fixture.socket.sent[0].canFind(`"new_draft":"first draft"`));
	setDraft.content = JSONFragment(toJson("recovered draft"));
	setDraft.correlation_id = "draft-write";
	fixture.app.handleSetDraftMsg(draftSender, setDraft);
	assert(draftSender.sent.length == 1
		&& draftSender.sent[0].canFind(`"correlation_id":"draft-write"`)
		&& draftSender.sent[0].canFind(`"new_draft":"recovered draft"`));
	assert(fixture.socket.sent.length == 2
		&& !fixture.socket.sent[1].canFind("draft-write"));
	fixture.socket.sent = null;
	fixture.publicationOrder = null;
	td.status = TaskStatus.waiting;
	fixture.app.persistence.setStatus(fixture.tid, cast(string) td.status);
	td.description = "";
	td.title = "";
	td.draft = "saved retry draft";
	fixture.app.persistence.setDraft(fixture.tid, td.draft);
	td.lastSuggestions = ["pending suggestion"];
	auto suggestionHandle = new Promise!string;
	td.suggestGenHandle = suggestionHandle;
	td.suggestGeneration = 41;
	Persistence.TaskRow readPersistedTask()
	{
		foreach (row; fixture.app.persistence.loadTasks())
			if (row.tid == fixture.tid)
				return row;
		assert(false, "Expected persisted browser task row");
	}
	auto message = testBrowserSubmission(fixture.tid, "first browser message",
		"first-browser-nonce");
	fixture.app.handleUserMessage(fixture.socket, message);
	drainSubmissionNextTicks();

	assert(fixture.session.sendCalls == 1);
	assert(td.status == TaskStatus.waiting);
	assert(td.description.length == 0 && td.title.length == 0
		&& td.draft == "saved retry draft");
	assert(td.history.length == 0 && !td.isProcessing);
	assert(("first-browser-nonce" in td.recentNonces) is null);
	assert(td.nativeSubmissionCount == 0
		&& td.pendingSteeringTexts.length == 0);
	assert(fixture.submissionMessages.length == 0 && fixture.socket.sent.length == 0
		&& fixture.titlePromptReads == 0);
	assert(td.lastSuggestions == ["pending suggestion"]
		&& td.suggestGenHandle is suggestionHandle && td.suggestGeneration == 41);
	assert(readPersistedTask().draft == "saved retry draft");

	fixture.publicationOrder = null;
	fixture.submissionMessages = null;
	fixture.submissionTids = null;
	fixture.socket.sent = null;
	fixture.session.reject(0, "first submission rejected");
	drainSubmissionNextTicks();
	assert(td.status == TaskStatus.waiting);
	assert(td.description.length == 0 && td.title.length == 0
		&& td.draft == "saved retry draft");
	assert(td.history.length == 1 && !td.isProcessing);
	assert(td.history.lastEventContents().canFind(`"type":"cydo/task_diagnostic"`)
		&& td.history.lastEventContents().canFind(`"subject":"Failed to submit message"`)
		&& td.history.lastEventContents().canFind(`"body":"first submission rejected"`));
	assert(("first-browser-nonce" in td.recentNonces) is null
		&& ("first-browser-nonce" in td.inFlightUiNonceGeneration) is null);
	assert(td.nativeSubmissionCount == 0);
	assert(fixture.titlePromptReads == 0);
	assert(td.lastSuggestions == ["pending suggestion"]
		&& td.suggestGenHandle is suggestionHandle && td.suggestGeneration == 41);
	assert(readPersistedTask().draft == "saved retry draft");
	assert(fixture.socket.sent.length == 3);
	assert(fixture.socket.sent[0].canFind(`"type":"cydo/task_diagnostic"`)
		&& fixture.socket.sent[0].canFind(`"subject":"Failed to submit message"`)
		&& fixture.socket.sent[0].canFind(`"body":"first submission rejected"`));
	assert(fixture.socket.sent[1].canFind(`"type":"task_updated"`));
	assert(fixture.socket.sent[2].canFind(`"type":"cydo/submission_rejected"`)
		&& fixture.socket.sent[2].canFind(`"correlation_id":"first-browser-nonce"`)
		&& parseJSON(fixture.socket.sent[2])["tid"].integer == fixture.tid
		&& fixture.socket.sent[2].canFind(`"kind":"delivery_failed"`)
		&& fixture.socket.sent[2].canFind(`"reason":"first submission rejected"`));
	foreach (payload; fixture.socket.sent)
	{
		assert(!payload.canFind(`"type":"task_reload"`));
		assert(!payload.canFind(`"type":"unconfirmedUserEvent"`));
		assert(!payload.canFind(`"type":"agentAck"`));
	}

	fixture.publicationOrder = null;
	fixture.submissionMessages = null;
	fixture.submissionTids = null;
	fixture.socket.sent = null;
	fixture.app.handleUserMessage(fixture.socket, message);
	drainSubmissionNextTicks();
	assert(fixture.session.sendCalls == 2);
	assert(toJson(fixture.session.contents[0]) == toJson(fixture.session.contents[1]));
	assert(td.status == TaskStatus.waiting && td.description.length == 0
		&& td.title.length == 0 && td.draft == "saved retry draft");
	assert(readPersistedTask().draft == "saved retry draft");

	td.archiving = true;
	fixture.app.handleUserMessage(fixture.socket, message);
	assert(fixture.socket.sent.length == 0,
		"An in-flight nonce replay must not be refused while archiving");
	td.archiving = false;

	fixture.session.accept(1, AgentSubmissionReceipt.appServerAccepted);
	drainSubmissionNextTicks();
	assert(td.status == TaskStatus.waiting && readPersistedTask().status == TaskStatus.waiting);
	assert(td.description == "first browser message");
	assert(td.title == truncateTitle("first browser message", 80));
	assert(td.draft.length == 0 && td.history.length == 2 && td.isProcessing);
	assert(("first-browser-nonce" in td.recentNonces) !is null);
	assert(td.nativeSubmissionCount == 0);
	assert(fixture.titlePromptReads == 1);
	assert(td.lastSuggestions.length == 0 && td.suggestGenHandle is null
		&& td.suggestGeneration == 42);
	assert(readPersistedTask().draft.length == 0);
	assert(fixture.publicationOrder == ["title_update", "draft_updated",
		"unconfirmed", "task_update", "agent_ack"]);
	bool sentDraftClear;
	foreach (payload; fixture.socket.sent)
	{
		if (payload.canFind(`"type":"draft_updated"`))
		{
			assert(payload.canFind(`"old_draft":"saved retry draft"`));
			assert(payload.canFind(`"new_draft":""`));
			sentDraftClear = true;
		}
		if (payload.canFind(`"type":"task_updated"`))
			assert(payload.canFind(`"status":"waiting"`) && payload.canFind(`"isProcessing":true`));
	}
	assert(sentDraftClear);

	fixture.socket.sent = null;
	fixture.app.handleUserMessage(fixture.socket, message);
	drainSubmissionNextTicks();
	assert(fixture.session.sendCalls == 2 && fixture.socket.sent.length == 0,
		"An accepted nonce is a duplicate, not a submission rejection");

	td.archiving = true;
	fixture.app.handleUserMessage(fixture.socket, message);
	drainSubmissionNextTicks();
	assert(fixture.session.sendCalls == 2 && fixture.socket.sent.length == 0,
		"Archiving must not turn an accepted duplicate into a rejection");

	td.archiving = false;
	td.status = TaskStatus.alive;
	fixture.app.persistence.setStatus(fixture.tid, cast(string) td.status);
	td.isProcessing = false;
	fixture.app.handleUserMessage(fixture.socket,
		testBrowserSubmission(fixture.tid, "new turn", "new-turn-nonce"));
	drainSubmissionNextTicks();
	assert(fixture.session.sendCalls == 3 && td.status == TaskStatus.alive);
	fixture.session.accept(2, AgentSubmissionReceipt.appServerAccepted);
	drainSubmissionNextTicks();
	assert(td.status == TaskStatus.active && readPersistedTask().status == TaskStatus.active);
}

unittest
{
	// A browser can disconnect after submitting but before the async
	// sendMessage continuation fires. The continuation still holds the now-
	// stale ws it captured; sending a rejection to it must not crash the
	// single-threaded backend (a bare ws.send would assert on a disconnected
	// socket) and must not be delivered, since there is no longer a browser
	// to receive it.
	auto dbPath = buildPath(tempDir(),
		"cydo-app-browser-submission-disconnect.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);

	auto fixture = new GatedSubmissionFixture(dbPath);
	auto td = &fixture.app.tasks[fixture.tid];
	td.status = TaskStatus.waiting;
	td.description = "";
	td.title = "";

	auto message = testBrowserSubmission(fixture.tid, "disconnecting message",
		"disconnecting-nonce");
	fixture.app.handleUserMessage(fixture.socket, message);
	drainSubmissionNextTicks();
	assert(fixture.session.sendCalls == 1);

	// Wire disconnection the way transport.d wires every real socket, so
	// disconnect() drives both the connection state and clientHub removal
	// through the same path production uses.
	fixture.socket.handleDisconnect = (string reason, DisconnectType type) {
		fixture.app.onWebSocketDisconnected(fixture.socket, reason, type);
	};
	fixture.socket.disconnect();
	fixture.socket.sent = null;
	fixture.session.reject(0, "submission rejected after disconnect");
	drainSubmissionNextTicks();

	assert(fixture.socket.sent.length == 0,
		"A disconnected client must not receive a submission rejection");
	assert(td.status == TaskStatus.waiting);
	assert(("disconnecting-nonce" in td.recentNonces) is null
		&& ("disconnecting-nonce" in td.inFlightUiNonceGeneration) is null);
}

version (unittest) private size_t submissionRejectionCount(string[] frames)
{
	return frames.count!(frame => frame.canFind(`"type":"cydo/submission_rejected"`));
}

unittest
{
	auto dbPath = buildPath(tempDir(), "cydo-app-browser-history-cancelled.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);

	auto fixture = new GatedSubmissionFixture(dbPath);
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	auto message = testBrowserSubmission(fixture.tid, "cancelled browser submission",
		"history-cancelled-nonce");
	fixture.app.handleUserMessage(fixture.socket, message);
	fixture.app.resetHistoryWatermarkOnly(fixture.tid);
	drainSubmissionNextTicks();

	assert(fixture.session.sendCalls == 0);
	assert(submissionRejectionCount(fixture.socket.sent) == 1);
	assert(fixture.socket.sent[$ - 1].canFind(`"type":"cydo/submission_rejected"`)
		&& fixture.socket.sent[$ - 1].canFind(`"correlation_id":"history-cancelled-nonce"`)
		&& parseJSON(fixture.socket.sent[$ - 1])["tid"].integer == fixture.tid
		&& fixture.socket.sent[$ - 1].canFind(`"kind":"history_cancelled"`));
}

unittest
{
	import cydo.agent.drivers.copilot : CopilotSession;

	auto dbPath = buildPath(tempDir(), "cydo-app-driver-history-cancellation.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);

	auto fixture = new GatedSubmissionFixture(dbPath);
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	AgentSession[] sessions = [
		cast(AgentSession) new CodexSession(null, fixture.tid, SessionConfig.init, "SYSTEM"),
		new CopilotSession(null, fixture.tid, "copilot-undo", "", "."),
	];
	foreach (session; sessions)
	{
		// Both drivers buffer messages before app-server readiness. Undo
		// invalidates those messages before stopping the session.
		fixture.app.taskSessionRunner = new GatedSubmissionRunner(session);
		fixture.socket.sent = null;
		enum nonce = "undo-invalidated-send";
		fixture.app.handleWsMessage(fixture.socket,
			toJson(testBrowserSubmission(fixture.tid, "queued before undo", nonce)));
		drainSubmissionNextTicks();
		assert(submissionRejectionCount(fixture.socket.sent) == 0);
		assert(nonce in fixture.app.tasks[fixture.tid].inFlightUiNonceGeneration);

		session.invalidatePendingSubmittedMessages();
		fixture.app.resetHistoryWatermarkOnly(fixture.tid);
		drainSubmissionNextTicks();

		assert(submissionRejectionCount(fixture.socket.sent) == 1);
		auto receipt = parseJSON(fixture.socket.sent[$ - 1]);
		assert(receipt["type"].str == "cydo/submission_rejected"
			&& receipt["correlation_id"].str == nonce && receipt["tid"].integer == fixture.tid
			&& receipt["kind"].str == "history_cancelled"
			&& receipt["reason"].str.canFind("message submission was invalidated"));
		assert(nonce !in fixture.app.tasks[fixture.tid].inFlightUiNonceGeneration);
	}
}

unittest
{
	auto dbPath = buildPath(tempDir(), "cydo-app-browser-queued-native-undo.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);

	auto fixture = new GatedSubmissionFixture(dbPath);
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	enum nonce = "queued-native-undo-nonce";
	fixture.app.handleUserMessage(fixture.socket,
		testBrowserSubmission(fixture.tid, "queued before undo", nonce));
	fixture.app.tasks[fixture.tid].beginConfirmedNativeUndo();
	drainSubmissionNextTicks();

	assert(fixture.session.sendCalls == 0);
	assert(nonce !in fixture.app.tasks[fixture.tid].inFlightUiNonceGeneration);
	void assertPairedRefusal(string expectedNonce)
	{
		assert(submissionRejectionCount(fixture.socket.sent) == 1);
		auto error = parseJSON(fixture.socket.sent[$ - 2]);
		auto receipt = parseJSON(fixture.socket.sent[$ - 1]);
		assert(error["type"].str == "error" && error["tid"].integer == fixture.tid);
		assert(receipt["type"].str == "cydo/submission_rejected"
			&& receipt["correlation_id"].str == expectedNonce
			&& receipt["tid"].integer == fixture.tid
			&& receipt["kind"].str == "native_undo_refused"
			&& receipt["reason"].str == error["message"].str);
	}

	assertPairedRefusal(nonce);
	fixture.socket.sent = null;
	enum entryNonce = "entry-native-undo-nonce";
	fixture.app.handleUserMessage(fixture.socket,
		testBrowserSubmission(fixture.tid, "new send during undo", entryNonce));
	assert(fixture.session.sendCalls == 0);
	assert(fixture.socket.sent.length == 2);
	assertPairedRefusal(entryNonce);
}

unittest
{
	// A tid supplied for a task that no longer exists — as opposed to the
	// create-path's omitted tid, covered by the create-validation-nonce
	// assertion — must still carry that tid back on the receipt.
	auto dbPath = buildPath(tempDir(), "cydo-app-browser-task-unavailable.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);

	auto fixture = new GatedSubmissionFixture(dbPath);
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	auto missingTid = fixture.tid + 1;
	assert(missingTid !in fixture.app.tasks);
	auto message = testBrowserSubmission(missingTid, "message for a missing task",
		"task-unavailable-nonce");
	fixture.app.handleUserMessage(fixture.socket, message);

	assert(fixture.session.sendCalls == 0);
	assert(submissionRejectionCount(fixture.socket.sent) == 1);
	assert(fixture.socket.sent[$ - 1].canFind(`"type":"cydo/submission_rejected"`)
		&& fixture.socket.sent[$ - 1].canFind(`"correlation_id":"task-unavailable-nonce"`)
		&& parseJSON(fixture.socket.sent[$ - 1])["tid"].integer == missingTid
		&& fixture.socket.sent[$ - 1].canFind(`"kind":"task_unavailable"`));
}

unittest
{
	auto dbPath = buildPath(tempDir(), "cydo-app-browser-task-archiving.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);

	auto fixture = new GatedSubmissionFixture(dbPath);
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	fixture.app.tasks[fixture.tid].archiving = true;
	auto message = testBrowserSubmission(fixture.tid, "message during archiving",
		"task-archiving-nonce");
	fixture.app.handleUserMessage(fixture.socket, message);

	assert(fixture.session.sendCalls == 0);
	assert(submissionRejectionCount(fixture.socket.sent) == 1);
	assert(fixture.socket.sent[$ - 1].canFind(`"type":"cydo/submission_rejected"`)
		&& fixture.socket.sent[$ - 1].canFind(`"correlation_id":"task-archiving-nonce"`)
		&& parseJSON(fixture.socket.sent[$ - 1])["tid"].integer == fixture.tid
		&& fixture.socket.sent[$ - 1].canFind(`"kind":"task_archiving"`));
}

unittest
{
	// Only the submitting client should receive the rejection: two clients
	// subscribed to the same task, only one of them submits. Picks
	// task_archiving specifically because native_undo_refused additionally
	// broadcasts a separate "error" to all subscribers, which would make an
	// absence-of-any-frame assertion ambiguous about which frame is meant.
	auto dbPath = buildPath(tempDir(), "cydo-app-browser-sender-only.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);

	auto fixture = new GatedSubmissionFixture(dbPath);
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	auto bystander = new SubmissionCaptureWebSocket();
	scope(exit) bystander.disconnect("test complete", DisconnectType.requested);
	fixture.app.clientHub.add(bystander);
	fixture.app.clientHub.subscribe(bystander, fixture.tid);
	fixture.app.tasks[fixture.tid].archiving = true;

	auto message = testBrowserSubmission(fixture.tid, "message during archiving",
		"sender-only-nonce");
	fixture.app.handleUserMessage(fixture.socket, message);

	assert(fixture.session.sendCalls == 0);
	assert(submissionRejectionCount(fixture.socket.sent) == 1);
	assert(fixture.socket.sent[$ - 1].canFind(`"type":"cydo/submission_rejected"`)
		&& parseJSON(fixture.socket.sent[$ - 1])["tid"].integer == fixture.tid
		&& fixture.socket.sent[$ - 1].canFind(`"correlation_id":"sender-only-nonce"`)
		&& fixture.socket.sent[$ - 1].canFind(`"kind":"task_archiving"`));
	assert(submissionRejectionCount(bystander.sent) == 0,
		"A submission rejection must be sender-only");
}

unittest
{
	auto root = buildPath(tempDir(), "cydo-app-create-submission-acceptance");
	if (exists(root))
		rmdirRecurse(root);
	scope(exit) if (exists(root)) rmdirRecurse(root);
	mkdirRecurse(root);

	auto oldHome = environment.get("HOME", "");
	auto hadHome = "HOME" in environment;
	scope(exit)
	{
		if (hadHome)
			environment["HOME"] = oldHome;
		else
			environment.remove("HOME");
	}
	auto home = buildPath(root, "home");
	mkdirRecurse(home);
	environment["HOME"] = home;

	auto projectPath = buildPath(root, "project");
	mkdirRecurse(projectPath);
	execute(["git", "-C", projectPath, "init", "-q"]);
	execute(["git", "-C", projectPath, "config", "user.email", "test@test"]);
	execute(["git", "-C", projectPath, "config", "user.name", "Test"]);
	write(buildPath(projectPath, "README.md"), "initial\n");
	execute(["git", "-C", projectPath, "add", "."]);
	execute(["git", "-C", projectPath, "commit", "-qm", "init"]);

	auto defs = buildPath(root, "defs");
	mkdirRecurse(buildPath(defs, "prompts"));
	write(buildPath(defs, "prompts", "blank.md"), "Blank prompt\n");
	write(buildPath(defs, "prompts", "start.md"), "Review request: {{task_description}}\n");
	write(buildPath(defs, "task-types.yaml"),
		"user_entry_points:\n"
		~ "  isolated:\n"
		~ "    task_type: direct_test\n"
		~ "    description: Isolated\n"
		~ "    prompt_template: prompts/start.md\n"
		~ "    worktree: require\n"
		~ "task_types:\n"
		~ "  direct_test:\n"
		~ "    model_class: large\n"
		~ "    creatable_entry_points: { isolated: {} }\n"
		~ "singletons:\n"
		~ "  internal:\n"
		~ "    task_type: direct_test\n"
		~ "    title: Internal\n"
		~ "    description: Internal\n"
		~ "    prompt_template: prompts/start.md\n");

	auto dbPath = buildPath(tempDir(), "cydo-app-create-submission-acceptance.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);
	auto fixture = new GatedSubmissionFixture(dbPath);
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	fixture.app.config.system_keyword = "SYSTEM";
	fixture.app.config.workspaces = [WorkspaceConfig(name: "create", root: root)];
	fixture.app.taskDirTemplate = "{{ workspace_root }}/tasks/{{ tid }}";
	fixture.app.taskTypeCatalog = new TaskTypeCatalog(defs,
		buildPath(defs, "task-types.yaml"), (string name) => name == "claude");
	fixture.app.agentsByName["claude"] = new TestClaudePromptAgent;
	size_t taskDirReads;
	fixture.app.taskPathResolver = new TaskPathResolver(TaskPathResolverHost(
		getTask: (int lookupTid) {
			auto task = lookupTid in fixture.app.tasks;
			return task is null ? null : task;
		},
		workspaces: () => fixture.app.config.workspaces,
		taskDirTemplate: () {
			taskDirReads++;
			return fixture.app.taskDirTemplate;
		},
	));
	fixture.app.worktreeAllocator = new WorktreeAllocator(WorktreeAllocatorHost(
		getTask: (int lookupTid) {
			auto task = lookupTid in fixture.app.tasks;
			return task is null ? null : task;
		},
		persistWorktreeTid: (int lookupTid, int worktreeTid) {
			fixture.app.persistence.setWorktreeTid(lookupTid, worktreeTid);
		},
		findRootTid: (int lookupTid) {
			return fixture.app.findRootTid(lookupTid);
		},
		taskDir: (const TaskData* task) => fixture.app.taskPathResolver.taskDir(task),
		worktreePath: (const TaskData* task) => fixture.app.taskPathResolver.worktreePath(task),
	));
	fixture.app.taskLifecycle = TaskLifecycle(
		getTask: (int lookupTid) {
			auto task = lookupTid in fixture.app.tasks;
			return task is null ? null : task;
		},
		persistStatus: (int lookupTid, string status) {
			fixture.app.persistence.setStatus(lookupTid, status);
		},
		persistNeedsAttention: (int lookupTid, bool needsAttention) {
			fixture.app.persistence.setNeedsAttention(lookupTid, needsAttention);
		},
		publishSnapshot: (int lookupTid) {
			fixture.app.broadcastTaskUpdate(lookupTid);
		},
	);
	fixture.app.systemMessageNormalizer = new SystemMessageNormalizer(
		SystemMessageNormalizerHost(
			systemKeyword: () => fixture.app.config.system_keyword,
			projectPathForTask: (int lookupTid) {
				auto task = lookupTid in fixture.app.tasks;
				return task is null ? null : task.projectPath;
			},
			taskTypesForProject: (string lookupProjectPath) =>
				fixture.app.taskTypeCatalog.getTaskTypesForProject(lookupProjectPath),
			entryPointsForProject: (string lookupProjectPath) =>
				fixture.app.taskTypeCatalog.getEntryPointsForProject(lookupProjectPath),
			loadTemplateText: (string templateName, string lookupProjectPath) => "",
		));
	fixture.app.archiveManager = new ArchiveManager(ArchiveManagerHost(
		tryGetTask: (int lookupTid, out ArchiveTaskSnapshot snapshot) {
			auto task = lookupTid in fixture.app.tasks;
			if (task is null)
				return false;
			snapshot = ArchiveTaskSnapshot(
				tid: lookupTid,
				parentTid: task.parentTid,
				archived: task.archived,
				archiving: task.archiving,
				alive: false,
				workspace: task.workspace,
				projectPath: task.projectPath,
			);
			return true;
		},
		snapshotTasks: () {
			ArchiveTaskSnapshot[int] snapshots;
			foreach (lookupTid, ref task; fixture.app.tasks)
				snapshots[lookupTid] = ArchiveTaskSnapshot(
					tid: lookupTid,
					parentTid: task.parentTid,
					archived: task.archived,
					archiving: task.archiving,
					alive: false,
					workspace: task.workspace,
					projectPath: task.projectPath,
				);
			return snapshots;
		},
	));
	fixture.app.workflowTools = new WorkflowToolsBackend(WorkflowToolsHost.init);
	auto runner = new GatedSubmissionRunner(fixture.session, true);
	size_t launchCount;
	bool launchSawAssignedWorktree;
	runner.onLaunch = (int launchTid) {
		launchCount++;
		auto launched = &fixture.app.tasks[launchTid];
		launchSawAssignedWorktree = launched.worktreeTid == launchTid
			&& exists(fixture.app.taskPathResolver.worktreePath(launched));
		fixture.app.tasks[launchTid].status = TaskStatus.active;
		fixture.app.persistence.setStatus(launchTid, cast(string) TaskStatus.active);
	};
	fixture.app.taskSessionRunner = runner;

	Persistence.TaskRow rowFor(int lookupTid)
	{
		foreach (row; fixture.app.persistence.loadTasks())
			if (row.tid == lookupTid)
				return row;
		assert(false, "Expected persisted task row");
	}

	int latestTid()
	{
		int result;
		foreach (row; fixture.app.persistence.loadTasks())
			if (row.tid > result)
				result = row.tid;
		return result;
	}

	WsMessage createMessage(string content, string correlationId = "")
	{
		WsMessage message;
		message.type = "create_task";
		message.workspace = "create";
		message.project_path = projectPath;
		message.agent_name = "claude";
		message.entry_point = "isolated";
		message.content = JSONFragment(toJson([ContentBlock("text", content)]));
		message.correlation_id = correlationId;
		return message;
	}

	void assertCreateValidationRejected(WsMessage message, string reason)
	{
		auto previousTid = latestTid();
		fixture.socket.sent = null;
		fixture.app.handleCreateTaskMsg(fixture.socket, message);
		assert(fixture.socket.sent.length == 2
			&& fixture.socket.sent[0].canFind(`"type":"error"`)
			&& fixture.socket.sent[1].canFind(`"type":"cydo/submission_rejected"`)
			&& fixture.socket.sent[1].canFind(`"correlation_id":` ~ toJson(message.correlation_id))
			&& fixture.socket.sent[1].canFind(`"kind":"validation"`)
			&& fixture.socket.sent[1].canFind(`"reason":` ~ toJson(reason))
			&& !fixture.socket.sent[1].canFind(`"tid":`));
		assert(latestTid() == previousTid);
	}

	auto invalid = createMessage("invalid submission", "create-invalid-path-nonce");
	invalid.project_path = buildPath(root, "missing-project");
	assertCreateValidationRejected(invalid, "Project path must be an existing directory");

	invalid = createMessage("invalid submission", "create-validation-nonce");
	invalid.entry_point = "";
	assertCreateValidationRejected(invalid, "Top-level task creation requires an entry point");

	invalid = createMessage("invalid submission", "create-unknown-entry-point-nonce");
	invalid.entry_point = "unknown";
	assertCreateValidationRejected(invalid, "Unknown entry point: unknown");

	auto systemEntryPoint = fixture.app.taskTypeCatalog.getEntryPointsForProject(projectPath)
		.byName("internal");
	assert(systemEntryPoint !is null && systemEntryPoint.system);
	invalid = createMessage("invalid submission", "create-system-entry-point-nonce");
	invalid.entry_point = "internal";
	assertCreateValidationRejected(invalid, "Unknown entry point: internal");

	fixture.socket.sent = null;
	fixture.app.handleCreateTaskMsg(fixture.socket,
		createMessage("cancelled direct first message", "create-history-nonce"));
	assert(fixture.socket.sent.length > 0
		&& fixture.socket.sent[0].canFind(`"type":"task_created"`)
		&& fixture.converter.inputs.length == 0, "Text-only creation is synchronous");
	auto cancelledTid = latestTid();
	auto cancelled = &fixture.app.tasks[cancelledTid];
	drainSubmissionNextTicks();
	assert(fixture.session.sendCalls == 1);
	// Master has no generation guard in this dispatch continuation: a reset
	// landing before dispatch just proceeds under the new generation. This
	// reset lands after the send, so it is caught by sendPreparedTaskMessage's
	// own post-acceptance lineage check once the agent accepts.
	fixture.app.resetHistoryWatermarkOnly(cancelledTid);
	fixture.session.accept(0, AgentSubmissionReceipt.appServerAccepted);
	drainSubmissionNextTicks();
	assert(submissionRejectionCount(fixture.socket.sent) == 1);
	assert(cancelled.status == TaskStatus.failed && cancelled.history.length == 1
		&& fixture.socket.sent[$ - 1].canFind(`"type":"cydo/submission_rejected"`)
		&& fixture.socket.sent[$ - 1].canFind(`"correlation_id":"create-history-nonce"`)
		&& parseJSON(fixture.socket.sent[$ - 1])["tid"].integer == cancelledTid
		&& fixture.socket.sent[$ - 1].canFind(`"kind":"history_cancelled"`));

	fixture.publicationOrder = null;
	fixture.submissionMessages = null;
	fixture.submissionTids = null;
	fixture.socket.sent = null;
	fixture.app.handleCreateTaskMsg(fixture.socket,
		createMessage("rejected direct first message", "create-rejection-nonce"));
	auto rejectedTid = latestTid();
	fixture.app.clientHub.subscribe(fixture.socket, rejectedTid);
	auto rejected = &fixture.app.tasks[rejectedTid];
	auto rejectedCreationPublications = fixture.socket.sent.dup;
	assert(rejectedCreationPublications.length == 3
		&& rejectedCreationPublications[0].canFind(`"type":"task_created"`)
		&& rejectedCreationPublications[1].canFind(`"type":"focus_hint"`)
		&& rejectedCreationPublications[2].canFind(`"type":"task_updated"`));
	assert(rejected.worktreeTid == rejectedTid
		&& exists(fixture.app.taskPathResolver.worktreePath(rejected)));
	auto beforeRejectedReceipt = rowFor(rejectedTid);
	assert(rejected.description.length == 0 && rejected.title.length == 0
		&& beforeRejectedReceipt.description.length == 0
		&& beforeRejectedReceipt.title.length == 0 && beforeRejectedReceipt.draft.length == 0);
	fixture.publicationOrder = null;
	fixture.submissionMessages = null;
	fixture.submissionTids = null;
	fixture.socket.sent = null;
	drainSubmissionNextTicks();
	assert(launchSawAssignedWorktree && fixture.session.sendCalls == 2);
	assert(rejected.status == TaskStatus.active && rejected.history.length == 0
		&& rejected.nativeSubmissionCount == 1
		&& rejected.pendingSteeringTexts.length == 0 && rejected.recentNonces.length == 0
		&& !rejected.isProcessing && rejected.lastSuggestions.length == 0
		&& fixture.titlePromptReads == 0 && fixture.socket.sent.length == 0
		&& fixture.submissionMessages.length == 0 && fixture.publicationOrder.length == 0);

	// An agent can reject its outstanding delivery before exit resets history.
	fixture.session.reject(1, "initial direct submission rejected");
	fixture.app.resetHistoryWatermarkOnly(rejectedTid);
	drainSubmissionNextTicks();
	auto afterRejectedReceipt = rowFor(rejectedTid);
	assert(rejected.status == TaskStatus.failed && rejected.history.length == 1
		&& rejected.nativeSubmissionCount == 0
		&& rejected.description.length == 0 && rejected.title.length == 0
		&& afterRejectedReceipt.description.length == 0
		&& afterRejectedReceipt.title.length == 0
		&& rejected.worktreeTid == rejectedTid
		&& exists(fixture.app.taskPathResolver.worktreePath(rejected)));
	assert(submissionRejectionCount(fixture.socket.sent) == 1);
	assert(fixture.socket.sent[$ - 1].canFind(`"type":"cydo/submission_rejected"`)
		&& fixture.socket.sent[$ - 1].canFind(`"correlation_id":"create-rejection-nonce"`)
		&& parseJSON(fixture.socket.sent[$ - 1])["tid"].integer == rejectedTid
		&& fixture.socket.sent[$ - 1].canFind(`"kind":"delivery_failed"`)
		&& fixture.socket.sent[$ - 1].canFind(`"reason":"initial direct submission rejected"`));

	// A failed, promoted task remains a valid draft target. This is what lets
	// browser recovery persist its retained editor text before a retry/reload.
	fixture.app.handleSetDraftMsg(fixture.socket, WsMessage(type: "set_draft",
		tid: rejectedTid,
		content: JSONFragment(toJson("rejected direct first message"))));
	assert(rejected.draft == "rejected direct first message"
		&& rowFor(rejectedTid).draft == "rejected direct first message");

	fixture.publicationOrder = null;
	fixture.submissionMessages = null;
	fixture.submissionTids = null;
	fixture.socket.sent = null;
	fixture.app.handleUserMessage(fixture.socket, testBrowserSubmission(rejectedTid,
		"rejected direct first message", "retry-rejected-create-nonce"));
	drainSubmissionNextTicks();
	assert(fixture.session.sendCalls == 3 && rejected.status == TaskStatus.failed);
	fixture.session.accept(2, AgentSubmissionReceipt.appServerAccepted);
	drainSubmissionNextTicks();
	assert(rejected.status == TaskStatus.active
		&& rejected.description == "rejected direct first message"
		&& rejected.title == truncateTitle("rejected direct first message", 80)
		&& rejected.draft.length == 0 && rowFor(rejectedTid).draft.length == 0
		&& rejected.history.length == 2 && rejected.isProcessing
		&& ("retry-rejected-create-nonce" in rejected.recentNonces) !is null);

	fixture.publicationOrder = null;
	fixture.submissionMessages = null;
	fixture.submissionTids = null;
	fixture.socket.sent = null;
	fixture.titlePromptReads = 0;
	fixture.titlePromptTids = null;
	fixture.app.handleCreateTaskMsg(fixture.socket,
		createMessage("accepted direct first message", "create-acceptance-nonce"));
	auto acceptedTid = latestTid();
	fixture.app.clientHub.subscribe(fixture.socket, acceptedTid);
	auto accepted = &fixture.app.tasks[acceptedTid];
	auto acceptedCreationPublications = fixture.socket.sent.dup;
	assert(acceptedCreationPublications.length == 3
		&& acceptedCreationPublications[0].canFind(`"type":"task_created"`)
		&& acceptedCreationPublications[1].canFind(`"type":"focus_hint"`)
		&& acceptedCreationPublications[2].canFind(`"type":"task_updated"`));
	assert(accepted.worktreeTid == acceptedTid
		&& exists(fixture.app.taskPathResolver.worktreePath(accepted)));
	auto beforeAcceptedReceipt = rowFor(acceptedTid);
	assert(accepted.description.length == 0 && accepted.title.length == 0
		&& beforeAcceptedReceipt.description.length == 0
		&& beforeAcceptedReceipt.title.length == 0 && beforeAcceptedReceipt.draft.length == 0);
	fixture.publicationOrder = null;
	fixture.submissionMessages = null;
	fixture.submissionTids = null;
	fixture.socket.sent = null;
	drainSubmissionNextTicks();
	assert(fixture.session.sendCalls == 4 && accepted.status == TaskStatus.active);
	assert(accepted.history.length == 0 && accepted.nativeSubmissionCount == 1
		&& accepted.recentNonces.length == 0
		&& accepted.pendingSteeringTexts.length == 0 && !accepted.isProcessing
		&& accepted.lastSuggestions.length == 0 && fixture.titlePromptReads == 0
		&& fixture.socket.sent.length == 0 && fixture.submissionMessages.length == 0
		&& fixture.publicationOrder.length == 0);
	fixture.session.accept(3, AgentSubmissionReceipt.appServerAccepted);
	drainSubmissionNextTicks();
	auto afterAcceptedReceipt = rowFor(acceptedTid);
	assert(accepted.description == "accepted direct first message"
		&& accepted.title == truncateTitle("accepted direct first message", 80)
		&& afterAcceptedReceipt.description == accepted.description
		&& afterAcceptedReceipt.title == accepted.title);
	assert(accepted.history.length == 1 && accepted.nativeSubmissionCount == 1
		&& accepted.pendingSteeringTexts.length == 1);
	assert(fixture.titlePromptReads == 1 && fixture.titlePromptTids == [acceptedTid]);
	assert(fixture.submissionTids == [acceptedTid]);
	assert(fixture.publicationOrder == ["title_update", "unconfirmed", "task_update"]);
	foreach (payload; fixture.socket.sent)
		assert(!payload.canFind(`"agentAck"`));

	fixture.publicationOrder = null;
	fixture.submissionMessages = null;
	fixture.submissionTids = null;
	fixture.socket.sent = null;
	fixture.titlePromptReads = 0;
	fixture.titlePromptTids = null;
	auto orderedStart = fixture.session.sendCalls;
	fixture.app.handleCreateTaskMsg(fixture.socket,
		createMessage("ordered atomic first", "ordered-create-nonce"));
	auto orderedTid = latestTid();
	fixture.app.handleUserMessage(fixture.socket,
		testBrowserSubmission(orderedTid, "ordered normal second", "ordered-normal-nonce"));
	drainSubmissionNextTicks();
	assert(fixture.session.sendCalls == orderedStart + 2);
	assert(extractContentText(fixture.session.contents[orderedStart]).canFind("ordered atomic first"));
	assert(extractContentText(fixture.session.contents[orderedStart + 1]).canFind("ordered normal second"));
	fixture.session.accept(orderedStart, AgentSubmissionReceipt.appServerAccepted);
	fixture.session.accept(orderedStart + 1, AgentSubmissionReceipt.appServerAccepted);
	drainSubmissionNextTicks();
	assert(fixture.app.tasks[orderedTid].description == "ordered atomic first");
	assert(submissionRejectionCount(fixture.socket.sent) == 0);

	auto browserTid = fixture.app.createTask("create", projectPath, "claude", "isolated");
	fixture.app.tasks[browserTid].taskType = "direct_test";
	fixture.app.persistence.setTaskType(browserTid, "direct_test");
	fixture.app.tasks[browserTid].draft = "browser worktree retry draft";
	fixture.app.persistence.setDraft(browserTid, "browser worktree retry draft");
	fixture.app.clientHub.subscribe(fixture.socket, browserTid);
	auto browserMessage = testBrowserSubmission(browserTid,
		"browser worktree retry message", "browser-worktree-nonce");
	fixture.app.handleUserMessage(fixture.socket, browserMessage);
	drainSubmissionNextTicks();
	auto browser = &fixture.app.tasks[browserTid];
	auto browserWorktreePath = fixture.app.taskPathResolver.worktreePath(browser);
	auto beforeBrowserReceipt = rowFor(browserTid);
	assert(fixture.session.sendCalls == 7 && browser.status == TaskStatus.active
		&& browser.worktreeTid == browserTid && exists(browserWorktreePath));
	assert(browser.description.length == 0 && browser.title.length == 0
		&& browser.draft == "browser worktree retry draft"
		&& browser.history.length == 0 && !browser.isProcessing
		&& beforeBrowserReceipt.description.length == 0
		&& beforeBrowserReceipt.title.length == 0
		&& beforeBrowserReceipt.draft == "browser worktree retry draft");

	fixture.session.reject(6, "browser worktree submission rejected");
	drainSubmissionNextTicks();
	auto afterBrowserRejection = rowFor(browserTid);
	assert(browser.status == TaskStatus.active && browser.worktreeTid == browserTid
		&& fixture.app.taskPathResolver.worktreePath(browser) == browserWorktreePath
		&& exists(browserWorktreePath));
	assert(browser.description.length == 0 && browser.title.length == 0
		&& browser.draft == "browser worktree retry draft"
		&& afterBrowserRejection.description.length == 0
		&& afterBrowserRejection.title.length == 0
		&& afterBrowserRejection.draft == "browser worktree retry draft"
		&& ("browser-worktree-nonce" in browser.recentNonces) is null
		&& ("browser-worktree-nonce" in browser.inFlightUiNonceGeneration) is null);
	assert(submissionRejectionCount(fixture.socket.sent) == 1);
	assert(fixture.socket.sent[$ - 1].canFind(`"type":"cydo/submission_rejected"`)
		&& fixture.socket.sent[$ - 1].canFind(`"correlation_id":"browser-worktree-nonce"`)
		&& parseJSON(fixture.socket.sent[$ - 1])["tid"].integer == browserTid
		&& fixture.socket.sent[$ - 1].canFind(`"kind":"delivery_failed"`));

	fixture.app.handleUserMessage(fixture.socket, browserMessage);
	drainSubmissionNextTicks();
	assert(fixture.session.sendCalls == 8
		&& fixture.session.correlations[6] == fixture.session.correlations[7]
		&& toJson(fixture.session.contents[6]) == toJson(fixture.session.contents[7])
		&& browser.worktreeTid == browserTid
		&& fixture.app.taskPathResolver.worktreePath(browser) == browserWorktreePath);

	// A client can disconnect after create_task dispatch but before the async
	// failure surfaces. The captured ws in handleCreateTaskMsg's continuation is
	// then stale; the rejection must not be delivered to it and must not crash
	// (a bare ws.send would assert on a disconnected socket). Uses a throwaway
	// socket rather than fixture.socket, since disconnecting the shared one
	// would break every scenario after it in this test.
	auto disconnectingSocket = new SubmissionCaptureWebSocket();
	fixture.app.clientHub.add(disconnectingSocket);
	disconnectingSocket.handleDisconnect = (string reason, DisconnectType type) {
		fixture.app.onWebSocketDisconnected(disconnectingSocket, reason, type);
	};
	fixture.app.handleCreateTaskMsg(disconnectingSocket,
		createMessage("disconnected direct first message", "create-disconnect-nonce"));
	auto disconnectingTid = latestTid();
	auto disconnecting = &fixture.app.tasks[disconnectingTid];
	drainSubmissionNextTicks();
	assert(fixture.session.sendCalls == 9);
	disconnectingSocket.disconnect();
	disconnectingSocket.sent = null;
	fixture.session.reject(8, "disconnected direct first message rejected");
	drainSubmissionNextTicks();
	assert(disconnectingSocket.sent.length == 0,
		"A disconnected client must not receive a submission rejection");
	assert(disconnecting.status == TaskStatus.failed && disconnecting.history.length == 1);

	// Keep the production runner's launch failure bookkeeping and diagnostic.
	enum launchFailure = "test session launch failed";
	static class FailingLaunchRunner : TaskSessionRunner
	{
		this(TaskSessionRunnerHost host)
		{
			super(host);
		}

		override TaskSessionLaunch prepareTaskSessionLaunch(int tid, Agent taskAgent,
			TaskTypeDef* typeDef)
		{
			throw new Exception(launchFailure);
		}
	}

	fixture.app.taskSessionRunner = new FailingLaunchRunner(TaskSessionRunnerHost(
		getTask: (int tid) => tid in fixture.app.tasks,
		agentForTask: (int tid) => fixture.app.agentsByName["claude"],
		shuttingDown: () => false,
		taskTypeCatalog: fixture.app.taskTypeCatalog,
		persistResultText: (int tid, string result) {
			fixture.app.persistence.setResultText(tid, result);
		},
		transitionTaskFrom: (int tid, TaskStatus[] from, TaskStatus to,
			TaskNotificationChange notification) {
			fixture.app.taskLifecycle.transitionTask(tid, from, to, notification);
		},
		appendTaskDiagnostic: &fixture.app.historyPipeline.appendTaskDiagnostic,
		broadcastAppendedTaskEvent: &fixture.app.broadcastAppendedTaskEvent,
		recordChildTerminal: (int tid) => false,
	));

	auto sendsBeforeLaunchFailures = fixture.session.sendCalls;
	void assertLaunchRejected(int tid, string correlationId)
	{
		drainSubmissionNextTicks();
		auto task = &fixture.app.tasks[tid];
		assert(task.status == TaskStatus.failed && rowFor(tid).resultText == launchFailure);
		assert(task.history.length == 1
			&& task.history.lastEventContents().canFind(`"subject":"Failed to resume session"`));
		assert(fixture.session.sendCalls == sendsBeforeLaunchFailures);
		assert(submissionRejectionCount(fixture.socket.sent) == 1);
		assert(fixture.socket.sent[$ - 1].canFind(`"type":"cydo/submission_rejected"`)
			&& fixture.socket.sent[$ - 1].canFind(`"correlation_id":` ~ toJson(correlationId))
			&& parseJSON(fixture.socket.sent[$ - 1])["tid"].integer == tid
			&& fixture.socket.sent[$ - 1].canFind(`"kind":"delivery_failed"`)
			&& fixture.socket.sent[$ - 1].canFind(`"reason":` ~ toJson(launchFailure)));
	}

	fixture.socket.sent = null;
	fixture.app.handleCreateTaskMsg(fixture.socket,
		createMessage("atomic launch failure", "create-launch-failure-nonce"));
	assertLaunchRejected(latestTid(), "create-launch-failure-nonce");

	auto normalTid = fixture.app.createTask("create", projectPath, "claude", "isolated");
	fixture.app.tasks[normalTid].taskType = "direct_test";
	fixture.app.persistence.setTaskType(normalTid, "direct_test");
	fixture.app.clientHub.subscribe(fixture.socket, normalTid);
	fixture.socket.sent = null;
	enum normalLaunchNonce = "browser-launch-failure-nonce";
	fixture.app.handleUserMessage(fixture.socket,
		testBrowserSubmission(normalTid, "normal launch failure", normalLaunchNonce));
	assertLaunchRejected(normalTid, normalLaunchNonce);
	assert(normalLaunchNonce !in fixture.app.tasks[normalTid].inFlightUiNonceGeneration);

	fixture.app.taskSessionRunner = runner;
	fixture.app.config.default_agent = "test";
	fixture.app.config.workspaces[0].default_agent = "claude";
	fixture.app.tasks[fixture.tid].agentName = "test";

	void assertUserTaskDraft()
	{
		fixture.socket.sent = null;
		auto sendCount = fixture.session.sendCalls;
		launchSawAssignedWorktree = false;
		auto spec = UserTaskSpec("create", projectPath, "isolated", "Review draft",
			"Please review the changes", fixture.tid);
		auto workspaceAgent = fixture.app.defaultAgentName(spec.workspace);
		assert(workspaceAgent != fixture.app.tasks[spec.creatorTid].agentName);
		assert(workspaceAgent != fixture.app.defaultAgentName(""));
		auto tid = fixture.app.createUserTask(spec);
		drainSubmissionNextTicks();

		auto task = &fixture.app.tasks[tid];
		assert(task.status == TaskStatus.pending && task.entryPoint == spec.entryPoint);
		assert(task.agentName == "claude"
			&& task.agentName == workspaceAgent);
		assert(task.title == spec.title && task.creatorTid == spec.creatorTid
			&& task.draft == spec.draft);
		auto row = rowFor(tid);
		assert(row.status == TaskStatus.pending && row.entryPoint == spec.entryPoint
			&& row.agentName == task.agentName && row.title == spec.title
			&& row.creatorTid == spec.creatorTid && row.draft == spec.draft);
		assert(!launchSawAssignedWorktree && !fixture.app.taskAlive(tid)
			&& fixture.session.sendCalls == sendCount);

		assert(fixture.socket.sent.length == 2);
		auto created = parseJSON(fixture.socket.sent[0]);
		assert(created["type"].str == "task_created" && created["tid"].integer == tid);
		auto updated = parseJSON(fixture.socket.sent[1]);
		assert(updated["type"].str == "task_updated");
		auto snapshot = updated["task"];
		assert(snapshot["tid"].integer == tid && snapshot["draft"].str == spec.draft
			&& snapshot["creator_tid"].integer == spec.creatorTid);
	}

	void assertUserTaskStart(string title)
	{
		import cydo.foundation.system.framing : ParsedSystemFraming, tryParseSystemFraming;
		import std.string : strip;

		enum prompt = "Review the changes and document all findings, including the full reproduction steps and suggested fixes.";
		auto tid = fixture.app.createUserTask(
			UserTaskSpec("create", projectPath, "isolated", title, "", fixture.tid));
		auto sendIndex = fixture.session.sendCalls;
		bool finished;
		fixture.app.startUserTask(tid, prompt).then(() { finished = true; }).ignoreResult();
		drainSubmissionNextTicks();

		assert(fixture.session.sendCalls == sendIndex + 1 && !finished);
		auto blocks = fixture.session.contents[sendIndex];
		assert(blocks.length == 1 && blocks[0].type == "text");
		ParsedSystemFraming framing;
		assert(tryParseSystemFraming("SYSTEM", blocks[0].text, framing));
		assert(framing.subject == sessionStartSubject("isolated"));
		assert(framing.body.strip == "Review request: " ~ prompt);
		assert(fixture.session.sources[sendIndex] == MessageSource.harness);

		fixture.session.accept(sendIndex, AgentSubmissionReceipt.appServerAccepted);
		drainSubmissionNextTicks();
		assert(finished && fixture.session.sendCalls == sendIndex + 1);
		auto expectedTitle = title.length ? title : truncateTitle(prompt, 80);
		assert(fixture.app.tasks[tid].title == expectedTitle && rowFor(tid).title == expectedTitle);
	}

	assertUserTaskDraft();
	assertUserTaskStart("Keep this title");
	assertUserTaskStart("");

	// Reuse the real entry point and worktree fixture for the attachment cases.
	fixture.session.acceptsImages = true;
	auto photoCreate = createMessage("first photo", "create-photo");
	photoCreate.content = JSONFragment(toJson([ContentBlock("text", "first photo"), testHeicBlock()]));
	auto beforePhotoTid = latestTid();
	auto beforePhotoTaskCount = fixture.app.tasks.length;
	auto photoSendIndex = fixture.session.sendCalls;
	fixture.socket.sent = null;
	fixture.app.handleCreateTaskMsg(fixture.socket, photoCreate);
	drainSubmissionNextTicks();
	assert(fixture.converter.gates.length == 1 && fixture.socket.sent.length == 0
		&& latestTid() == beforePhotoTid && fixture.app.tasks.length == beforePhotoTaskCount
		&& fixture.session.sendCalls == photoSendIndex);

	fixture.converter.gates[0].fulfill(testJpegBytes);
	drainSubmissionNextTicks();
	auto photoTid = latestTid();
	assert(photoTid > beforePhotoTid && fixture.app.tasks.length == beforePhotoTaskCount + 1);
	auto createdPhotoTask = parseJSON(fixture.socket.sent[0]);
	assert(createdPhotoTask["type"].str == "task_created"
		&& createdPhotoTask["tid"].integer == photoTid
		&& createdPhotoTask["correlation_id"].str == photoCreate.correlation_id);
	assert(fixture.session.sendCalls == photoSendIndex + 1);
	auto photoContent = fixture.session.contents[photoSendIndex];
	assert(photoContent.length == 2 && photoContent[1] == testNormalizedJpeg());
	fixture.session.accept(photoSendIndex, AgentSubmissionReceipt.appServerAccepted);
	drainSubmissionNextTicks();

	import cydo.runtime.image.bounded_filter : FilterFailure, FilterFailureKind;
	photoCreate.correlation_id = "create-photo-refused";
	fixture.socket.sent = null;
	fixture.app.handleCreateTaskMsg(fixture.socket, photoCreate);
	drainSubmissionNextTicks();
	assert(fixture.converter.gates.length == 2 && fixture.socket.sent.length == 0);
	fixture.converter.gates[1].reject(new FilterFailure(FilterFailureKind.failed));
	drainSubmissionNextTicks();
	auto photoRejection = assertBrowserRejection(fixture.socket, photoCreate.correlation_id, -1,
		BrowserSubmissionRejectionKind.attachment_rejected);
	assert(photoRejection["attachment"].integer == 0 && photoRejection["reason"].str == "conversion failed");
	assert(fixture.socket.sent.length == 1);
	assert(latestTid() == photoTid && fixture.app.tasks.length == beforePhotoTaskCount + 1
		&& fixture.session.sendCalls == photoSendIndex + 1);

	void assertPendingPhoto(bool cancelHistory)
	{
		auto ep = fixture.app.taskTypeCatalog.getEntryPointsForProject(projectPath).byName("isolated");
		auto tid = fixture.app.createEntryPointTask("create", projectPath, "claude", ep);
		auto task = &fixture.app.tasks[tid];
		fixture.app.clientHub.subscribe(fixture.socket, tid);
		fixture.socket.sent = null;
		auto message = testBrowserHeicSubmission(tid, "pending photo", "pending-photo");
		auto sends = fixture.session.sendCalls;
		auto launches = launchCount;
		auto gateIndex = fixture.converter.gates.length;
		auto path = worktreePathForTaskDir(fixture.app.taskPathResolver.taskDir(task));
		auto reads = taskDirReads;
		assert(task.status == TaskStatus.pending && task.worktreeTid == 0 && !exists(path));
		assert(task.processQueue.goalState == ProcessState.Dead && !fixture.app.taskAlive(tid));

		fixture.app.handleUserMessage(fixture.socket, message);
		drainSubmissionNextTicks();
		assert(fixture.converter.gates.length == gateIndex + 1);
		assert(message.correlation_id in task.inFlightUiNonceGeneration);
		assert(taskDirReads == reads && launchCount == launches);
		if (cancelHistory)
		{
			task.history.reset(Watermark.none());
			fixture.converter.gates[gateIndex].fulfill(testJpegBytes);
			drainSubmissionNextTicks();
			assertBrowserRejection(fixture.socket, message.correlation_id, tid,
				BrowserSubmissionRejectionKind.history_cancelled);
		}
		else
		{
			fixture.converter.gates[gateIndex].reject(new FilterFailure(FilterFailureKind.failed));
			drainSubmissionNextTicks();
			auto refusal = assertBrowserRejection(fixture.socket, message.correlation_id, tid,
				BrowserSubmissionRejectionKind.attachment_rejected);
			assert(refusal["attachment"].integer == 0 && refusal["reason"].str == "conversion failed");
		}

		assert(taskDirReads == reads, "A refused submission must stop before prompt framing");
		assert(task.processQueue.goalState == ProcessState.Dead && launchCount == launches);
		assert(task.status == TaskStatus.pending && task.description.length == 0
			&& task.worktreeTid == 0 && !exists(path) && task.history.length == 0);
		auto row = rowFor(tid);
		assert(row.status == TaskStatus.pending && row.description.length == 0 && row.worktreeTid == 0);
		assert(message.correlation_id !in task.inFlightUiNonceGeneration);
		assert(fixture.session.sendCalls == sends && fixture.socket.sent.length == 1);

		fixture.app.handleUserMessage(fixture.socket, message);
		drainSubmissionNextTicks();
		assert(fixture.converter.gates.length == gateIndex + 2);
		fixture.converter.gates[gateIndex + 1].fulfill(testJpegBytes);
		drainSubmissionNextTicks();
		assert(taskDirReads > reads && launchCount == launches + 1);
		assert(task.worktreeTid == tid && rowFor(tid).worktreeTid == tid && exists(path));
		assert(fixture.session.sendCalls == sends + 1);
		fixture.session.accept(sends, AgentSubmissionReceipt.appServerAccepted);
		drainSubmissionNextTicks();
		assert(message.correlation_id in task.recentNonces && task.description == "pending photo");
		assert(submissionRejectionCount(fixture.socket.sent) == 1);
	}

	assertPendingPhoto(false);
	assertPendingPhoto(true);

	{
		import std.exception : collectException;

		enum insertFailure = "test task insert failure";
		fixture.app.persistence.db.db.exec("CREATE TEMP TRIGGER fail_task_insert BEFORE INSERT ON tasks "
			~ "BEGIN SELECT RAISE(ABORT, '" ~ insertFailure ~ "'); END;");
		scope(exit) fixture.app.persistence.db.db.exec("DROP TRIGGER fail_task_insert;");
		auto taskCount = fixture.app.tasks.length;
		auto previousTid = latestTid();
		auto sends = fixture.session.sendCalls;
		fixture.socket.sent = null;
		auto synchronous = collectException(fixture.app.handleCreateTaskMsg(fixture.socket,
			createMessage("cannot insert text task", "insert-text-failure")));
		assert(synchronous !is null && synchronous.msg.canFind(insertFailure));
		assert(fixture.socket.sent.length == 0 && latestTid() == previousTid
			&& fixture.app.tasks.length == taskCount && fixture.session.sendCalls == sends);

		auto gateIndex = fixture.converter.gates.length;
		photoCreate.correlation_id = "insert-photo-failure";
		fixture.app.handleCreateTaskMsg(fixture.socket, photoCreate);
		drainSubmissionNextTicks();
		assert(fixture.converter.gates.length == gateIndex + 1 && fixture.socket.sent.length == 0);
		fixture.converter.gates[gateIndex].fulfill(testJpegBytes);
		auto deferred = collectException(drainSubmissionNextTicks());
		assert(deferred !is null && deferred.msg == synchronous.msg);
		drainSubmissionNextTicks();
		assert(fixture.socket.sent.length == 0 && latestTid() == previousTid
			&& fixture.app.tasks.length == taskCount && fixture.session.sendCalls == sends);
	}

	// An unborn repository cannot supply the HEAD required by git worktree add.
	auto unbornProject = buildPath(root, "unborn");
	mkdirRecurse(unbornProject);
	auto gitInit = execute(["git", "-C", unbornProject, "init", "-q"]);
	assert(gitInit.status == 0, gitInit.output);

	{
		import std.exception : collectException;

		auto ep = fixture.app.taskTypeCatalog.getEntryPointsForProject(unbornProject).byName("isolated");
		auto tid = fixture.app.createEntryPointTask("create", unbornProject, "claude", ep);
		auto task = &fixture.app.tasks[tid];
		fixture.app.clientHub.subscribe(fixture.socket, tid);
		fixture.socket.sent = null;
		auto sends = fixture.session.sendCalls;
		auto launches = launchCount;
		auto gateIndex = fixture.converter.gates.length;
		auto text = testBrowserSubmission(tid, "text to unborn repo", "unborn-fast-text");
		auto synchronous = collectException(fixture.app.handleUserMessage(fixture.socket, text));
		assert(synchronous !is null && synchronous.msg.canFind("Failed to create required worktree"));
		assert(text.correlation_id !in task.inFlightUiNonceGeneration);
		assert(fixture.socket.sent.length == 0 && task.history.length == 0
			&& fixture.converter.gates.length == gateIndex);

		auto photo = testBrowserHeicSubmission(tid, "photo to unborn repo", "unborn-photo");
		auto queued = testBrowserSubmission(tid, "text to unborn repo", "unborn-queued-text");
		fixture.app.handleUserMessage(fixture.socket, photo);
		fixture.app.handleUserMessage(fixture.socket, queued);
		drainSubmissionNextTicks();
		assert(fixture.converter.gates.length == gateIndex + 1 && fixture.socket.sent.length == 0);
		assert(photo.correlation_id in task.inFlightUiNonceGeneration
			&& queued.correlation_id in task.inFlightUiNonceGeneration);

		fixture.converter.gates[gateIndex].fulfill(testJpegBytes);
		auto deferred = collectException(drainSubmissionNextTicks());
		assert(deferred !is null && deferred.msg == synchronous.msg);
		assert(photo.correlation_id !in task.inFlightUiNonceGeneration
			&& queued.correlation_id in task.inFlightUiNonceGeneration);
		auto afterPhoto = collectException(drainSubmissionNextTicks());
		assert(afterPhoto !is null && afterPhoto.msg == synchronous.msg);
		drainSubmissionNextTicks();
		assert(fixture.socket.sent.length == 0 && task.history.length == 0);
		assert(photo.correlation_id !in task.inFlightUiNonceGeneration
			&& queued.correlation_id !in task.inFlightUiNonceGeneration);
		assert(task.worktreeTid == 0 && task.status == TaskStatus.pending
			&& launchCount == launches && fixture.session.sendCalls == sends);
	}

	auto caller = &fixture.app.tasks[fixture.tid];
	caller.workspace = "create";
	caller.projectPath = unbornProject;
	caller.taskType = "direct_test";
	fixture.app.workflowTools = new WorkflowToolsBackend(WorkflowToolsHost(
		getTask: (int tid) => tid in fixture.app.tasks,
		taskTypesForProject: &fixture.app.taskTypeCatalog.getTaskTypesForProject,
		entryPointsForProject: &fixture.app.taskTypeCatalog.getEntryPointsForProject,
		createUserTask: &fixture.app.createUserTask,
		startUserTask: &fixture.app.startUserTask,
	));
	auto previousTid = latestTid();
	auto sendsBeforePreparationFailure = fixture.session.sendCalls;
	McpResult[] toolResults;
	fixture.app.dispatchTool("CreateTask", format!"%d"(fixture.tid), "create-task-call",
		JSONFragment(`{"prompt":"Review the project","entry_point":"isolated","start":true}`),
		new ToolCallCancellation)
		.then((McpResult result) { toolResults ~= result; }).ignoreResult();
	drainSubmissionNextTicks();
	auto failedTid = latestTid();
	assert(failedTid > previousTid);
	auto failedRow = rowFor(failedTid);
	assert(failedRow.status == TaskStatus.failed);
	assert(failedRow.resultText.canFind("Failed to create required worktree"));
	assert(toolResults.length == 1 && toolResults[0].isError
		&& toolResults[0].text == format!"Task %d was created but could not start: %s"(
			failedTid, failedRow.resultText));
	auto failedTask = &fixture.app.tasks[failedTid];
	assert(failedTask.history.length == 1);
	auto diagnostic = failedTask.history.lastEventContents();
	assert(diagnostic.canFind(`"subject":"Failed to submit initial message"`)
		&& diagnostic.canFind("Failed to create required worktree"));
	assert(fixture.session.sendCalls == sendsBeforePreparationFailure
		&& !fixture.app.taskAlive(failedTid));
}

// Regression: a rejected initial Codex turn/start can settle before a later
// process-exit callback observes the same task.
unittest
{
	auto root = buildPath(tempDir(), "cydo-app-codex-initial-submission-exit");
	if (exists(root))
		rmdirRecurse(root);
	scope(exit) if (exists(root)) rmdirRecurse(root);
	mkdirRecurse(root);

	auto projectPath = buildPath(root, "project");
	mkdirRecurse(projectPath);
	auto defs = buildPath(root, "defs");
	mkdirRecurse(buildPath(defs, "prompts"));
	write(buildPath(defs, "prompts", "blank.md"), "Blank prompt\n");
	write(buildPath(defs, "prompts", "start.md"), "{{task_description}}\n");
	write(buildPath(defs, "task-types.yaml"),
		"user_entry_points:\n"
		~ "  direct:\n"
		~ "    task_type: direct_test\n"
		~ "    description: Direct\n"
		~ "    prompt_template: prompts/start.md\n"
		~ "task_types:\n"
		~ "  direct_test:\n"
		~ "    model_class: large\n");

	auto dbPath = buildPath(tempDir(),
		"cydo-app-codex-initial-submission-exit.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);
	auto fixture = new GatedSubmissionFixture(dbPath);
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	fixture.app.config.system_keyword = "SYSTEM";
	fixture.app.config.workspaces = [WorkspaceConfig(name: "test", root: root)];
	fixture.app.taskDirTemplate = "{{ workspace_root }}/tasks/{{ tid }}";
	fixture.app.taskTypeCatalog = new TaskTypeCatalog(defs,
		buildPath(defs, "task-types.yaml"), (string name) => name == "codex");
	fixture.app.taskPathResolver = new TaskPathResolver(TaskPathResolverHost(
		getTask: (int tid) {
			auto task = tid in fixture.app.tasks;
			return task is null ? null : task;
		},
		workspaces: () => fixture.app.config.workspaces,
		taskDirTemplate: () => fixture.app.taskDirTemplate,
	));
	fixture.app.taskLifecycle = TaskLifecycle(
		getTask: (int tid) {
			auto task = tid in fixture.app.tasks;
			return task is null ? null : task;
		},
		persistStatus: (int tid, string status) {
			fixture.app.persistence.setStatus(tid, status);
		},
		persistNeedsAttention: (int tid, bool needsAttention) {
			fixture.app.persistence.setNeedsAttention(tid, needsAttention);
		},
		publishSnapshot: (int tid) {
			fixture.app.broadcastTaskUpdate(tid);
		},
	);
	fixture.app.systemMessageNormalizer = new SystemMessageNormalizer(
		SystemMessageNormalizerHost(
			systemKeyword: () => fixture.app.config.system_keyword,
			projectPathForTask: (int tid) {
				auto task = tid in fixture.app.tasks;
				return task is null ? null : task.projectPath;
			},
			taskTypesForProject: (string path) =>
				fixture.app.taskTypeCatalog.getTaskTypesForProject(path),
			entryPointsForProject: (string path) =>
				fixture.app.taskTypeCatalog.getEntryPointsForProject(path),
			loadTemplateText: (string templateName, string path) => "",
		));
	fixture.app.workflowTools = new WorkflowToolsBackend(WorkflowToolsHost.init);

	auto agent = new GatedSubmissionCodexAgent;
	fixture.app.agentsByName["codex"] = agent;
	bool historyReset;
	auto runner = new PreparedSubmissionExitRunner(TaskSessionRunnerHost(
		getTask: (int tid) {
			auto task = tid in fixture.app.tasks;
			return task is null ? null : task;
		},
		agentForTask: (int tid) => cast(Agent) agent,
		tryAgentForTask: (int tid) => cast(Agent) agent,
		setAgentSessionId: (int tid, string sessionId) {},
		broadcastTask: (int tid, TranslatedEvent event) {},
		publishTaskSnapshot: (int tid) {
			fixture.app.broadcastTaskUpdate(tid);
		},
		pump: (int tid) => false,
		hasLiveBatchOwner: (int tid) => false,
		hasBatchChild: (int tid) => false,
		hasPendingChildQuestion: (int tid) => false,
		recordChildTerminal: (int tid) => false,
		failPendingAskUserQuestionOnExit: (int tid) {},
		failPendingPermissionPromptOnExit: (int tid) {},
		abandonToolCalls: (int tid) {},
		closeToolCalls: (int tid) {},
		openToolCalls: (int tid) {},
		decideToolPermission: delegate Promise!string(int tid, PermissionPrompt prompt,
			PermissionEscalation escalation) { assert(0, "unexpected call"); },
		decidePreToolUse: delegate ToolCallRuling(int tid, string toolName,
			JSONFragment input) { assert(0, "unexpected call"); },
		withdrawToolPermissionPrompt: (int tid, string toolUseId) {},
		cancelExitBackgroundWork: (int tid) {},
		resetHistoryWatermarkAfterExit: (int tid) {
			historyReset = true;
			return false;
		},
		touchAndPersistLastActive: (int tid) {},
		transitionTask: (int tid, TaskStatus expectedFrom, TaskStatus to,
			TaskNotificationChange notification) {
			fixture.app.taskLifecycle.transitionTask(tid, expectedFrom, to,
				notification);
		},
		transitionTaskFrom: (int tid, TaskStatus[] expectedFrom, TaskStatus to,
			TaskNotificationChange notification) {
			fixture.app.taskLifecycle.transitionTask(tid, expectedFrom, to,
				notification);
		},
		persistResultText: (int tid, string resultText) {
			fixture.app.persistence.setResultText(tid, resultText);
		},
		emitTaskReload: (int tid) {},
		ensureHistoryLoadedForExit: delegate Nullable!TaskHistoryResolution(int tid) {
			assert(0, "Driver-served exit must skip file history loading");
		},
		finalReconcileJsonlIfPresent: (int tid, Nullable!TaskHistoryResolution resolution) {
			assert(0, "Driver-served exit must skip file reconciliation");
		},
		stopJsonlWatch: (int tid) {},
		broadcastHistoryOperations: (int tid) {},
		shuttingDown: () => false,
		taskTypeCatalog: fixture.app.taskTypeCatalog,
	));
	fixture.app.taskSessionRunner = runner;

	WsMessage message;
	message.type = "create_task";
	message.workspace = "test";
	message.project_path = projectPath;
	message.agent_name = "codex";
	message.entry_point = "direct";
	message.content = JSONFragment(toJson(
		[ContentBlock("text", "first Codex message")]));
	fixture.app.handleCreateTaskMsg(fixture.socket, message);
	drainSubmissionNextTicks();

	int createdTid;
	foreach (row; fixture.app.persistence.loadTasks())
		if (row.tid > createdTid)
			createdTid = row.tid;
	auto task = &fixture.app.tasks[createdTid];
	assert(agent.session !is null && agent.session.gates.length == 1
		&& task.status == TaskStatus.active);

	// A turn/start error rejects the submission without ending CodexSession.
	// Let the application's initial-submission callback commit active -> failed.
	agent.session.reject(0, "Codex turn/start rejected initial submission");
	drainSubmissionNextTicks();
	assert(agent.session.alive && task.status == TaskStatus.failed);

	// If the app-server subsequently exits, the production runner callback must
	// accept that the task is already failed and leave it failed without throwing.
	agent.session.deliverServerExit(17);
	assert(runner.sessionForTask(createdTid) is null);
	assert(historyReset);
	assert(task.status == TaskStatus.failed
		&& task.error == "Codex turn/start rejected initial submission"
		&& task.resultText == "Codex turn/start rejected initial submission");
}

unittest
{
	auto dbPath = buildPath(tempDir(), "cydo-app-rejected-newer.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);

	auto fixture = new GatedSubmissionFixture(dbPath);
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	auto td = &fixture.app.tasks[fixture.tid];
	td.agentName = "claude";

	foreach (index, nonce; ["queue-one-nonce", "queue-two-nonce",
		"queue-three-nonce"])
	{
		fixture.app.sendTaskMessage(fixture.tid,
			[ContentBlock("text", "accepted queue message " ~ nonce)], null, null,
			nonce).ignoreResult();
		fixture.session.accept(index, AgentSubmissionReceipt.localEnqueued);
		drainSubmissionNextTicks();
	}
	assert(td.nativeSubmissionCount == 3 && td.pendingSteeringTexts == [
		"accepted queue message queue-one-nonce",
		"accepted queue message queue-two-nonce",
		"accepted queue message queue-three-nonce",
	]);

	auto pendingSteeringTexts = td.pendingSteeringTexts.dup;
	auto nativeSubmissionCount = td.nativeSubmissionCount;
	auto historyGeneration = td.history.generation;
	string[] historyPrefix;
	foreach (index; 0 .. td.history.length)
		historyPrefix ~= cast(string) td.history.opIndex(index).toGC().as!string;

	fixture.app.handleUserMessage(fixture.socket, testBrowserSubmission(fixture.tid,
		"rejected newer message", "rejected-newer-nonce"));
	fixture.app.handleUserMessage(fixture.socket, testBrowserSubmission(fixture.tid,
		"unrelated pending message", "unrelated-nonce"));
	drainSubmissionNextTicks();
	assert(fixture.session.sendCalls == 5);
	assert(("rejected-newer-nonce" in td.inFlightUiNonceGeneration) !is null
		&& ("unrelated-nonce" in td.inFlightUiNonceGeneration) !is null);

	fixture.session.reject(3, "newer submission rejected");
	drainSubmissionNextTicks();
	assert(td.pendingSteeringTexts == pendingSteeringTexts);
	assert(td.nativeSubmissionCount == nativeSubmissionCount + 1);
	assert(td.history.generation == historyGeneration
		&& td.history.length == historyPrefix.length + 1);
	foreach (index; 0 .. historyPrefix.length)
		assert(cast(string) td.history.opIndex(index).toGC().as!string == historyPrefix[index]);
	assert(td.history.lastEventContents().canFind(`"subject":"Failed to submit message"`)
		&& td.history.lastEventContents().canFind(`"body":"newer submission rejected"`));
	assert(("rejected-newer-nonce" in td.inFlightUiNonceGeneration) is null);
	assert(("rejected-newer-nonce" in td.recentNonces) is null);
	assert(("unrelated-nonce" in td.inFlightUiNonceGeneration) !is null);

	fixture.app.handleUserMessage(fixture.socket, testBrowserSubmission(fixture.tid,
		"rejected newer message", "rejected-newer-nonce"));
	drainSubmissionNextTicks();
	assert(fixture.session.sendCalls == 6 && fixture.session.gates.length == 6);
	assert(("rejected-newer-nonce" in td.inFlightUiNonceGeneration) !is null);
}

unittest
{
	auto dbPath = buildPath(tempDir(), "cydo-app-local-receipt-echoes.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);

	auto fixture = new GatedSubmissionFixture(dbPath);
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	fixture.app.tasks[fixture.tid].agentName = "claude";
	fixture.app.sendTaskMessage(fixture.tid,
		[ContentBlock("text", "first local prompt")], null, null,
		"first-local-nonce").ignoreResult();
	fixture.app.sendTaskMessage(fixture.tid,
		[ContentBlock("text", "[SYSTEM: internal reminder]")]).ignoreResult();
	fixture.app.sendTaskMessage(fixture.tid,
		[ContentBlock("text", "second local prompt")], null, null,
		"second-local-nonce").ignoreResult();
	assert(fixture.session.sendCalls == 3);

	foreach (index; 0 .. fixture.session.gates.length)
	{
		fixture.session.accept(index, AgentSubmissionReceipt.localEnqueued);
		drainSubmissionNextTicks();
	}
	assert(fixture.app.tasks[fixture.tid].nativeSubmissionCount == 3);
	assert(fixture.session.nativeSubmissionUuids.length == 3);
	foreach (payload; fixture.socket.sent)
		assert(!payload.canFind(`"agentAck"`));

	auto first = fixture.app.planHistoryBroadcast(fixture.tid,
		fixture.session.nativeUserEcho("first local prompt", null,
			fixture.session.nativeSubmissionUuids[0]));
	assert(testUserCorrelation(first.currentEvent) == "first-local-nonce");
	auto system = fixture.app.planHistoryBroadcast(fixture.tid,
		fixture.session.nativeUserEcho("[SYSTEM: internal reminder]", null,
			fixture.session.nativeSubmissionUuids[1]));
	assert(testUserCorrelation(system.currentEvent).length == 0);
	auto second = fixture.app.planHistoryBroadcast(fixture.tid,
		fixture.session.nativeUserEcho("second local prompt", null,
			fixture.session.nativeSubmissionUuids[2]));
	assert(testUserCorrelation(second.currentEvent) == "second-local-nonce");
	assert(fixture.app.tasks[fixture.tid].nativeSubmissionCount == 3);
	foreach (uuid; fixture.session.nativeSubmissionUuids)
		assert(fixture.app.tasks[fixture.tid].nativeSubmission(uuid).stdoutSeen);
}

unittest
{
	auto dbPath = buildPath(tempDir(), "cydo-app-server-receipt-echoes.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);

	auto fixture = new GatedSubmissionFixture(dbPath);
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	fixture.app.tasks[fixture.tid].agentName = "test";
	fixture.app.sendTaskMessage(fixture.tid,
		[ContentBlock("text", "first app-server prompt")], null, null,
		"first-app-server-nonce").ignoreResult();
	fixture.app.sendTaskMessage(fixture.tid,
		[ContentBlock("text", "second app-server prompt")], null, null,
		"second-app-server-nonce").ignoreResult();
	drainSubmissionNextTicks();
	assert(fixture.session.sendCalls == 2);

	fixture.session.accept(0, AgentSubmissionReceipt.appServerAccepted);
	drainSubmissionNextTicks();
	fixture.session.accept(1, AgentSubmissionReceipt.appServerAccepted);
	drainSubmissionNextTicks();
	assert(fixture.app.tasks[fixture.tid].nativeSubmissionCount == 0);
	assertThrown!AssertError(fixture.app.planHistoryBroadcast(fixture.tid,
		fixture.session.nativeUserEcho("unknown app-server prompt", "unknown-nonce")));
	assert(fixture.app.tasks[fixture.tid].nativeSubmissionCount == 0);

	auto second = fixture.app.planHistoryBroadcast(fixture.tid,
		fixture.session.nativeUserEcho("second app-server prompt",
			"second-app-server-nonce"));
	assert(testUserCorrelation(second.currentEvent) == "second-app-server-nonce");
	auto first = fixture.app.planHistoryBroadcast(fixture.tid,
		fixture.session.nativeUserEcho("first app-server prompt",
			"first-app-server-nonce"));
	assert(testUserCorrelation(first.currentEvent) == "first-app-server-nonce");
	assert(fixture.app.tasks[fixture.tid].nativeSubmissionCount == 0);
	assertThrown!AssertError(fixture.app.planHistoryBroadcast(fixture.tid,
		fixture.session.nativeUserEcho("second app-server prompt",
			"second-app-server-nonce")));
}

unittest
{
	auto dbPath = buildPath(tempDir(), "cydo-app-replay-app-server-receipt.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);

	auto fixture = new GatedSubmissionFixture(dbPath);
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	fixture.app.tasks[fixture.tid].agentName = "test";
	fixture.app.sendTaskMessage(fixture.tid,
		[ContentBlock("text", "receipt prompt")], null, null,
		"replay-receipt-nonce").ignoreResult();
	drainSubmissionNextTicks();
	fixture.session.accept(0, AgentSubmissionReceipt.appServerAccepted);
	drainSubmissionNextTicks();

	ItemStartedEvent replay;
	replay.item_id = "replay-user";
	replay.item_type = "user_message";
	replay.content = [ContentBlock("text", "receipt prompt")];
	replay.correlation_id = "replay-receipt-nonce";
	replay.is_replay = true;
	fixture.app.planHistoryBroadcast(fixture.tid,
		TranslatedEvent(toJson(replay), null));

	// Replay can retain public correlation metadata, but it cannot consume the
	// one-shot app-server receipt belonging to a live echo.
	auto live = fixture.app.planHistoryBroadcast(fixture.tid,
		fixture.session.nativeUserEcho("receipt prompt", "replay-receipt-nonce"));
	assert(testUserCorrelation(live.currentEvent) == "replay-receipt-nonce");
}

unittest
{
	auto dbPath = buildPath(tempDir(), "cydo-app-attachment-absorption.sqlite");
	if (exists(dbPath)) remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);
	auto fixture = new GatedSubmissionFixture(dbPath);
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	auto td = &fixture.app.tasks[fixture.tid];
	td.agentName = "claude";
	fixture.attachClaudeMirror(fixture.tid);
	td.reserveNativeSubmission("local-one", "one", td.history.generation, "one");
	td.reserveNativeSubmission("local-two", "two", td.history.generation, "two");

	// Attachments carry the only native identity for absorption. Their order is
	// independent from queue presentation, so each retires only its exact UUID.
	fixture.app.jsonlTracker.ingestMirrorRows(fixture.tid, [
		`{"type":"attachment","uuid":"attach-two","attachment":{"type":"queued_command","source_uuid":"local-two"}}`]);
	assert(td.nativeSubmissionCount == 2
		&& td.nativeSubmission("local-two").tailState == SubmissionTailState.absorbed
		&& td.nativeSubmission("local-one").tailState == SubmissionTailState.pending);
	fixture.app.planHistoryBroadcast(fixture.tid,
		fixture.session.nativeUserEcho("two", null, "local-two"));
	assert(td.nativeSubmissionCount == 1 && td.nativeSubmission("local-one").tailState
		== SubmissionTailState.pending);
	fixture.app.jsonlTracker.ingestMirrorRows(fixture.tid, [
		`{"type":"attachment","uuid":"attach-one","attachment":{"type":"queued_command","source_uuid":"local-one"}}`]);
	assert(td.nativeSubmissionCount == 1
		&& td.nativeSubmission("local-one").tailState == SubmissionTailState.absorbed);
	fixture.app.planHistoryBroadcast(fixture.tid,
		fixture.session.nativeUserEcho("one", null, "local-one"));
	assert(td.nativeSubmissionCount == 0);
	fixture.app.jsonlTracker.ingestMirrorRows(fixture.tid, [
		`{"type":"attachment","uuid":"attach-unknown","attachment":{"type":"queued_command","source_uuid":"unknown"}}`]);
	assert(td.nativeSubmissionCount == 0);
	fixture.app.jsonlTracker.ingestMirrorRows(fixture.tid, [
		`{"type":"attachment","uuid":"attach-no-source","attachment":{"type":"queued_command"}}`]);
	assert(td.nativeSubmissionCount == 0);
}

@("Claude submission reconciliation is independent of mirror frame batching")
unittest
{
	import std.array : join;
	import std.file : write;

	auto dbPath = buildPath(tempDir(), "cydo-app-attachment-frame-equivalence.sqlite");
	if (exists(dbPath)) remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);
	auto fixture = new GatedSubmissionFixture(dbPath);
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	auto splitTid = fixture.app.persistence.createTask();
	fixture.app.tasks[splitTid] = TaskData(splitTid, "local", "/tmp/cydo-app-submission");
	fixture.app.tasks[splitTid].taskType = "test";
	fixture.app.tasks[splitTid].status = TaskStatus.active;
	fixture.app.tasks[splitTid].history.reset(Watermark.none());

	size_t run(int tid, bool split)
	{
		auto td = &fixture.app.tasks[tid];
		td.agentName = "claude";
		td.reserveNativeSubmission("native-one", "one", td.history.generation, "one");
		td.reserveNativeSubmission("native-two", "two", td.history.generation, "two");
		auto path = buildPath(tempDir(), "cydo-app-attachment-frame-equivalence.jsonl");
		if (split)
			write(path, "");
		scope(exit) if (split) remove(path);
		fixture.attachClaudeMirror(tid, split ? path : null);
		scope(exit) fixture.app.jsonlTracker.stopJsonlWatch(tid);
		td.reserveNativeSubmission("native-user", "turn opener", td.history.generation, "turn opener");
		auto publicationStart = fixture.submissionMessages.length;
		string[] rows = [
			`{"type":"queue-operation","operation":"enqueue","timestamp":"2026-06-11T06:00:00Z","sessionId":"S","content":"turn opener"}`,
			`{"type":"queue-operation","operation":"dequeue","timestamp":"2026-06-11T06:00:01Z","sessionId":"S"}`,
			`{"parentUuid":"p","isSidechain":false,"type":"user","uuid":"tool-result-1","toolUseResult":{"stdout":"ok"},"message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"ok"}]}}`,
			`{"type":"atis-latch","atis":"","sessionId":"S"}`,
			`{"type":"user","uuid":"native-user","message":{"role":"user","content":"turn opener"}}`,
			`{"type":"assistant","uuid":"asst-1","apiBlockIndex":0,"message":{"id":"asst-1","content":[{"type":"text","text":"after steer"}],"model":"m","usage":{"input_tokens":1,"output_tokens":1}}}`,
			`{"type":"queue-operation","operation":"enqueue","content":"one"}`,
			`{"type":"queue-operation","operation":"enqueue","content":"two"}`,
			`{"type":"attachment","uuid":"attachment-two","attachment":{"type":"queued_command","source_uuid":"native-two"}}`,
			`{"type":"attachment","uuid":"attachment-one","attachment":{"type":"queued_command","source_uuid":"native-one"}}`,
			`{"type":"queue-operation","operation":"remove"}`,
			`{"type":"queue-operation","operation":"remove"}`,
		];
		if (split)
		{
			write(path, rows[0 .. 2].join("\n") ~ "\n");
			fixture.app.jsonlTracker.ingestMirrorRows(tid, rows[0 .. 2]);
			fixture.app.jsonlTracker.invalidateLineage(tid);
		}
		fixture.app.historyPipeline.broadcastTask(tid,
			fixture.session.nativeUserEcho("turn opener", null, "native-user"));
		if (split)
		{
			write(path, rows[0 .. 10].join("\n") ~ "\n");
			fixture.app.jsonlTracker.ingestMirrorRows(tid, rows[2 .. 10]);
			assert(td.nativeSubmission("native-one").tailState == SubmissionTailState.pending
				&& td.nativeSubmission("native-two").tailState == SubmissionTailState.pending);
			foreach (message; fixture.submissionMessages[publicationStart .. $])
				assert(!message.canFind(`"type":"task_history_boundary_replaced"`));
			fixture.app.jsonlTracker.startJsonlWatch(tid);
			fixture.app.jsonlTracker.ingestMirrorRows(tid, rows[10 .. $]);
		}
		else
			fixture.app.jsonlTracker.ingestMirrorRows(tid, rows);
		assert(td.nativeSubmission("native-one").tailState == SubmissionTailState.absorbed
			&& td.nativeSubmission("native-two").tailState == SubmissionTailState.absorbed);
		size_t canonicalBoundaries;
		foreach (index; 0 .. td.history.length)
		{
			auto event = cast(string) td.history.opIndex(index).unsafeContents;
			if (event.canFind(`"history_boundary"`))
			{
				assert(!event.canFind(`native-one`) && !event.canFind(`native-two`), event);
				if (event.canFind(`"type":"item/started"`)
					&& event.canFind(`"item_type":"user_message"`)
					&& event.canFind(`"uuid":"native-user"`)
					&& event.canFind(`"kind":"user"`)
					&& event.canFind(`"anchor":"native-user"`))
					++canonicalBoundaries;
			}
		}
		assert(canonicalBoundaries == 1);
		size_t canonicalReplacements;
		foreach (message; fixture.submissionMessages[publicationStart .. $])
		{
			if (!message.canFind(`"type":"task_history_boundary_replaced"`))
				continue;
			assert(!message.canFind(`native-one`) && !message.canFind(`native-two`), message);
			assert(message.canFind(`"uuid":"native-user"`)
				&& message.canFind(`"kind":"user"`)
				&& message.canFind(`"anchor":"native-user"`), message);
			++canonicalReplacements;
		}
		assert(canonicalReplacements == 1);
		// The live queue lifecycle is read from stdout; the mirror reports none.
		foreach (index; 0 .. td.history.length)
			assert(!(cast(string) td.history.opIndex(index).unsafeContents)
				.canFind(`"type":"user_message/consumed"`));
		return canonicalBoundaries;
	}

	assert(run(fixture.tid, false) == run(splitTid, true));
}

unittest
{
	auto dbPath = buildPath(tempDir(), "cydo-app-submission-lineage.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);

	auto fixture = new GatedSubmissionFixture(dbPath);
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	fixture.app.tasks[fixture.tid].agentName = "claude";
	fixture.app.sendTaskMessage(fixture.tid,
		[ContentBlock("text", "old echoed prompt")], null, null,
		"old-echo-nonce").ignoreResult();
	fixture.session.accept(0, AgentSubmissionReceipt.localEnqueued);
	drainSubmissionNextTicks();
	assert(fixture.app.tasks[fixture.tid].history.length == 1);
	assert(fixture.app.tasks[fixture.tid].nativeSubmissionCount == 1);

	bool oldReceiptRejected;
	fixture.app.sendTaskMessage(fixture.tid,
		[ContentBlock("text", "old receipt prompt")], null, null,
		"old-receipt-nonce").then(() {
		assert(false, "stale submission receipt was committed");
	}, (Exception error) {
		oldReceiptRejected = true;
	}).ignoreResult();
	fixture.app.handleUserMessage(fixture.socket, testBrowserSubmission(fixture.tid,
		"old rejected prompt", "old-rejection-nonce"));
	drainSubmissionNextTicks();
	assert(fixture.session.gates.length == 3);
	assert(("old-rejection-nonce" in fixture.app.tasks[fixture.tid]
		.inFlightUiNonceGeneration) !is null);

	auto oldGeneration = fixture.app.tasks[fixture.tid].history.generation;
	fixture.app.resetHistoryWatermarkOnly(fixture.tid);
	assert(fixture.app.tasks[fixture.tid].history.generation != oldGeneration);
	assert(fixture.app.tasks[fixture.tid].history.length == 0);
	// The old local echo record must not label the first native echo of the
	// replacement lineage.
	assert(fixture.app.tasks[fixture.tid].nativeSubmissionCount == 0);
	assert(fixture.app.tasks[fixture.tid].inFlightUiNonceGeneration.length == 0);

	fixture.app.handleUserMessage(fixture.socket, testBrowserSubmission(fixture.tid,
		"new generation prompt", "old-rejection-nonce"));
	drainSubmissionNextTicks();
	assert(fixture.session.gates.length == 4);
	assert(("old-rejection-nonce" in fixture.app.tasks[fixture.tid]
		.inFlightUiNonceGeneration) !is null);

	fixture.session.accept(1, AgentSubmissionReceipt.appServerAccepted);
	fixture.session.reject(2, "old submission rejected");
	drainSubmissionNextTicks();
	assert(submissionRejectionCount(fixture.socket.sent) == 1);
	assert(fixture.socket.sent[$ - 1].canFind(`"type":"cydo/submission_rejected"`)
		&& fixture.socket.sent[$ - 1].canFind(`"correlation_id":"old-rejection-nonce"`)
		&& parseJSON(fixture.socket.sent[$ - 1])["tid"].integer == fixture.tid
		&& fixture.socket.sent[$ - 1].canFind(`"kind":"delivery_failed"`)
		&& fixture.socket.sent[$ - 1].canFind(`"reason":"old submission rejected"`));
	assert(oldReceiptRejected);
	assert(fixture.app.tasks[fixture.tid].history.length == 0);
	assert(("old-receipt-nonce" in fixture.app.tasks[fixture.tid].recentNonces)
		is null);
	assert(("old-rejection-nonce" in fixture.app.tasks[fixture.tid].recentNonces)
		is null);
	assert(("old-rejection-nonce" in fixture.app.tasks[fixture.tid]
		.inFlightUiNonceGeneration) !is null);

	fixture.session.accept(3, AgentSubmissionReceipt.localEnqueued);
	drainSubmissionNextTicks();
	assert(fixture.app.tasks[fixture.tid].history.length == 1);
	assert(("old-rejection-nonce" in fixture.app.tasks[fixture.tid].recentNonces)
		!is null);
	assert(("old-rejection-nonce" in fixture.app.tasks[fixture.tid]
		.inFlightUiNonceGeneration) is null);
	assert(fixture.app.tasks[fixture.tid].nativeSubmissionCount == 1);

	auto newEcho = fixture.app.planHistoryBroadcast(fixture.tid,
		fixture.session.nativeUserEcho("new generation prompt", null,
			fixture.session.nativeSubmissionUuids[3]));
	assert(testUserCorrelation(newEcho.currentEvent) == "old-rejection-nonce");
	assert(fixture.app.tasks[fixture.tid].nativeSubmissionCount == 1
		&& fixture.app.tasks[fixture.tid].nativeSubmission(
			fixture.session.nativeSubmissionUuids[3]).stdoutSeen);
}

version (unittest) private bool isKnownPromptParityAgent(string name)
{
	return ["claude", "codex", "copilot"].canFind(name);
}

version (unittest) private void writePromptParityFixture(string root)
{
	auto defsDir = buildPath(root, "defs");
	mkdirRecurse(buildPath(defsDir, "prompts"));
	mkdirRecurse(buildPath(defsDir, "system_prompts"));

	write(buildPath(defsDir, "prompts", "blank.md"), "Blank prompt\n");
	write(buildPath(defsDir, "prompts", "create.md"), "Create prompt\n");
	write(buildPath(defsDir, "prompts", "review.md"), "Review prompt\n");
	write(buildPath(defsDir, "prompts", "verify.md"), "Verify prompt\n");
	write(buildPath(defsDir, "system_prompts", "role.md"),
		"ROLE MARKER {{output_file}}");
	write(buildPath(defsDir, "system_prompts", "master.md"),
		"MASTER\n{{role_prompt}}\nGUIDE\n{{generated_guidance}}\n");
	write(buildPath(defsDir, "task-types.yaml"),
		"task_types:\n"
		~ "  parent:\n"
		~ "    model_class: large\n"
		~ "    system_prompt_template: system_prompts/role.md\n"
		~ "    creatable_tasks:\n"
		~ "      execute:\n"
		~ "        task_type: implement\n"
		~ "        prompt_template: prompts/create.md\n"
		~ "    continuations:\n"
		~ "      review:\n"
		~ "        task_type: review\n"
		~ "        keep_context: true\n"
		~ "        prompt_template: prompts/review.md\n"
		~ "      verify:\n"
		~ "        task_type: verify\n"
		~ "        keep_context: false\n"
		~ "        prompt_template: prompts/verify.md\n"
		~ "  implement:\n"
		~ "    model_class: large\n"
		~ "    agent_description: GUIDANCE TASK MARKER\n"
		~ "    tool_guidance: GUIDANCE TASK TOOL MARKER\n"
		~ "  review:\n"
		~ "    model_class: large\n"
		~ "    agent_description: GUIDANCE SWITCH MARKER\n"
		~ "    tool_guidance: GUIDANCE SWITCH TOOL MARKER\n"
		~ "  verify:\n"
		~ "    model_class: large\n"
		~ "    agent_description: GUIDANCE HANDOFF MARKER\n"
		~ "    tool_guidance: GUIDANCE HANDOFF TOOL MARKER\n");
}

unittest
{
	auto tmp = buildPath("/tmp", "cydo-app-empty-prompt");
	scope (exit)
	{
		if (exists(tmp))
			rmdirRecurse(tmp);
	}
	mkdirRecurse(buildPath(tmp, "prompts"));
	write(buildPath(tmp, "prompts", "blank.md"), "Blank prompt\n");
	write(buildPath(tmp, "prompts", "empty.md"), " \n\t");

	auto app = new App();
	app.taskTypeCatalog = new TaskTypeCatalog(tmp,
		buildPath(tmp, "task-types.yaml"), &isKnownPromptParityAgent);
	assert(app.readPromptFile("prompts/empty.md", "", null) == "");
}

unittest
{
	import std.path : dirName;

	auto root = buildPath(tempDir(), "cydo-app-missing-output-template");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit) if (exists(root)) rmdirRecurse(root);

	auto oldHome = environment.get("HOME", "");
	auto hadHome = "HOME" in environment;
	scope (exit)
	{
		if (hadHome)
			environment["HOME"] = oldHome;
		else
			environment.remove("HOME");
	}
	auto home = buildPath(root, "home");
	if (!exists(home))
		mkdirRecurse(home);
	environment["HOME"] = home;

	auto bundled = environment.get("CYDO_TEST_DEFS", "defs");
	assert(exists(buildPath(bundled, "gates", "missing_outputs.md")),
		"bundled missing-output template is required; set CYDO_TEST_DEFS");
	auto app = new App();
	app.taskTypeCatalog = new TaskTypeCatalog(bundled,
		buildPath(bundled, "task-types.yaml"), &isKnownPromptParityAgent);
	auto project = buildPath(root, "project");
	mkdirRecurse(project);
	string details = "- /output/report.md\n- {{another_placeholder}}";
	auto body = app.readPromptFile("gates/missing_outputs.md", project,
		["missing_outputs": details]);
	assert(body == "Your task type declares outputs that were not produced:\n"
		~ details ~ "\n\n"
		~ "Please produce the missing output(s) before finishing. "
		~ "Write your report to your output file if you haven't already.");
	auto message = wrapKnownSystemMessage("SYSTEM",
		KnownSystemMessageKind.missingRequiredOutputs, body);
	assert(message == "[SYSTEM: Missing required outputs]\n\n" ~ body ~ "\n\n[/SYSTEM]");
	KnownSystemMessageMatch match;
	assert(tryKnownSystemMessageMatch("Missing required outputs", match));
	assert(match.kind == KnownSystemMessageKind.missingRequiredOutputs);

	auto userTemplate = buildPath(home, ".config", "cydo", "defs", "gates", "missing_outputs.md");
	mkdirRecurse(dirName(userTemplate));
	write(userTemplate, "user {{missing_outputs}}");
	assert(app.readPromptFile("gates/missing_outputs.md", project,
		["missing_outputs": details]) == "user " ~ details);
	auto projectTemplate = buildPath(project, ".cydo", "defs", "gates", "missing_outputs.md");
	mkdirRecurse(dirName(projectTemplate));
	write(projectTemplate, "project one {{missing_outputs}}");
	assert(app.readPromptFile("gates/missing_outputs.md", project,
		["missing_outputs": details]) == "project one " ~ details);
	write(projectTemplate, "project two {{missing_outputs}}");
	assert(app.readPromptFile("gates/missing_outputs.md", project,
		["missing_outputs": details]) == "project two " ~ details);
	assertThrown!Exception(app.readPromptFile("gates/absent.md", project, null));
}

unittest
{
	import std.algorithm : canFind;
	import std.path : dirName;
	import cydo.workflow.sessions.disk_usage : DiskEvaluation;
	import cydo.workflow.sessions.yield_gates : checkDiskCleanupGate;
	import cydo.runtime.storage.disk_usage : DiskCategory, DiskTopPath, DiskUnmeasured;
	import cydo.runtime.storage.nix_roots : NixClosureEntry, nixClosureLabel;
	import std.array : replace;

	auto root = buildPath(tempDir(), "cydo-app-disk-cleanup-template");
	if (exists(root)) rmdirRecurse(root);
	scope (exit) if (exists(root)) rmdirRecurse(root);
	auto oldHome = environment.get("HOME", "");
	auto hadHome = "HOME" in environment;
	scope (exit)
	{
		if (hadHome) environment["HOME"] = oldHome;
		else environment.remove("HOME");
	}
	auto home = buildPath(root, "home");
	mkdirRecurse(home);
	environment["HOME"] = home;
	auto bundled = environment.get("CYDO_TEST_DEFS", "defs");
	assert(exists(buildPath(bundled, "gates", "disk_cleanup.md")));
	auto app = new App();
	app.taskTypeCatalog = new TaskTypeCatalog(bundled,
		buildPath(bundled, "task-types.yaml"), &isKnownPromptParityAgent);
	auto project = buildPath(root, "project");
	mkdirRecurse(project);
	DiskEvaluation evaluation;
	evaluation.usage.taskBytes = -3;
	evaluation.usage.temporaryBytes = 15;
	evaluation.usage.totalBytes = 12;
	evaluation.usage.topPaths = [DiskTopPath(DiskCategory.temporary, "build{{x}}", 15)];
	evaluation.usage.unmeasured = [
		DiskUnmeasured(DiskCategory.task, "blocked", "Permission denied"),
	];
	evaluation.nix.entries = [NixClosureEntry(["/task/result"], "/nix/store/example", 100)];
	auto vars = checkDiskCleanupGate(evaluation, 10, "/task", "/tmp/task").vars;
	vars["x"] = "must-not-expand";
	auto bundledBody = app.readPromptFile("gates/disk_cleanup.md", project, vars);
	assert(bundledBody.canFind("Task directory /task: -3 bytes"));
	assert(bundledBody.canFind("Temporary directory /tmp/task: 15 bytes"));
	assert(bundledBody.canFind("Signed total: 12 bytes"));
	assert(bundledBody.canFind("15 temporary build{{x}}"));
	assert(!bundledBody.canFind("must-not-expand"));
	assert(!bundledBody.replace("build{{x}}", "").canFind("{{"));
	assert(bundledBody.canFind("task blocked"));
	assert(bundledBody.canFind(nixClosureLabel));
	assert(bundledBody.canFind("100 /nix/store/example /task/result"));
	assert(bundledBody.canFind("Retain required outputs, shared inputs, and needed build"));
	assert(bundledBody.canFind("sent once per task and will not be repeated"));
	assert(bundledBody.canFind("Other independent requirements"));
	assert(bundledBody.canFind("does not guarantee reclamation"));
	auto userTemplate = buildPath(home, ".config", "cydo", "defs", "gates", "disk_cleanup.md");
	mkdirRecurse(dirName(userTemplate));
	write(userTemplate, "user {{total_bytes}}");
	assert(app.readPromptFile("gates/disk_cleanup.md", project, vars) == "user 12");
	auto projectTemplate = buildPath(project, ".cydo", "defs", "gates", "disk_cleanup.md");
	mkdirRecurse(dirName(projectTemplate));
	write(projectTemplate, "project {{total_bytes}}");
	assert(app.readPromptFile("gates/disk_cleanup.md", project, vars) == "project 12");
	write(projectTemplate, "updated {{total_bytes}}");
	assert(app.readPromptFile("gates/disk_cleanup.md", project, vars) == "updated 12");
	assertThrown!Exception(app.readPromptFile("gates/missing-required-disk.md", project, vars));
}

unittest // Config reload publishes agent changes only after validation.
{
	import std.array : replace;
	import std.logger : sharedLog;
	import cydo.runtime.config : configPath;

	enum original = "workspaces: {}\ndefault_agent: work-claude\n"
		~ "agents:\n  work-claude:\n    driver: claude\n"
		~ "    model_aliases:\n      large: before-reload\n"
		~ "  other:\n    driver: claude\n";

	auto root = buildPath(tempDir(), "cydo-app-rejected-config-reload");
	auto oldHome = environment.get("HOME", "");
	bool hadHome = "HOME" in environment;
	scope (exit)
	{
		if (hadHome)
			environment["HOME"] = oldHome;
		else
			environment.remove("HOME");
		rmdirRecurse(root);
	}

	auto home = buildPath(root, "home");
	mkdirRecurse(buildPath(home, ".config", "cydo"));
	environment["HOME"] = home;
	auto configFile = configPath();
	write(configFile, original);

	mkdirRecurse(buildPath(root, "prompts"));
	write(buildPath(root, "prompts", "blank.md"), "Blank prompt\n");
	auto definitions = buildPath(root, "task-types.yaml");
	write(definitions, "task_types:\n  worker:\n    agent: work-claude\n");
	auto app = new App;
	app.config = loadRuntimeConfig();
	app.taskTypeCatalog = new TaskTypeCatalog(root, definitions,
		name => isConfiguredAgentName(app.config, name));
	app.taskTypeCatalog.reloadGlobal();
	foreach (agentName; app.config.agents.keys)
		app.agentsByName[agentName] = app.createConfiguredAppAgent(app.config, agentName);
	app.agent = app.agentsByName[app.config.default_agent];

	auto acceptedConfig = app.config;
	auto acceptedAgents = app.agentsByName.dup;
	auto acceptedDefault = app.agent;

	foreach (candidate; [
		original.replace("default_agent: work-claude", "default_agent: missing"),
		"workspaces: {}\ndefault_agent: other\nagents:\n  other:\n    driver: claude\n",
	])
	{
		write(configFile, candidate);
		app.onConfigChanged();
		assert(app.config == acceptedConfig, candidate);
		assert(app.agentsByName.length == acceptedAgents.length, candidate);
		foreach (name, originalAgent; acceptedAgents)
			assert(app.agentsByName.get(name, null) is originalAgent, name);
		assert(app.agent is acceptedDefault, candidate);
		auto notice = "config" in app.activeNotices;
		assert(notice !is null, "A rejected config reload should raise a notice");
		assert(notice.level == NoticeLevel.alert);
		assert(notice.description == "config.yaml was not reloaded");
		assert(notice.impact == "Keeping the previously loaded version.");
		assert(notice.action.canFind(configFile));
	}

	// Exercise the same config and agent publication as the watcher callback.
	auto oldLogLevel = (cast()sharedLog).logLevel;
	scope (exit) (cast()sharedLog).logLevel = oldLogLevel;
	assert(acceptedDefault.resolveModelSpec("large").model == "before-reload");
	write(configFile, original.replace("before-reload", "after-reload")
		.replace("other:\n    driver: claude", "other:\n    driver: codex")
		.replace("default_agent: work-claude", "default_agent: other"));
	assert(app.tryApplyRuntimeConfig());
	assert("config" !in app.activeNotices, "An accepted config reload should clear the notice");
	assert(app.agentsByName["work-claude"] is acceptedDefault);
	assert(acceptedDefault.resolveModelSpec("large").model == "after-reload");
	assert(app.agentsByName["other"] !is acceptedAgents["other"]);
	assert(app.agentsByName["other"].driver == AgentDriver.codex);
	assert(app.agent is app.agentsByName["other"]);
}

version (unittest) private struct TaskTypeLoadNoticeFixture
{
	enum invalidYaml = "task_types: [\n";

	App app;
	string root, project, overridePath, projectNoticeId;
	private string oldHome;
	private bool hadHome;

	void setup(string name)
	{
		import std.algorithm : map;
		import std.array : join;

		root = buildPath(tempDir(), "cydo-app-task-type-" ~ name);
		project = buildPath(root, "project");
		auto projectConfig = buildPath(project, ".cydo");
		mkdirRecurse(projectConfig);
		project = canonicalProjectPath(project);
		overridePath = buildPath(project, ".cydo", "task-types.yaml");
		projectNoticeId = "task-types:" ~ (cast(const(ubyte)[]) project).map!(b => format!"%02x"(b)).join;
		auto home = buildPath(root, "home");
		mkdirRecurse(buildPath(home, ".config", "cydo"));
		oldHome = environment.get("HOME", "");
		hadHome = "HOME" in environment;
		environment["HOME"] = home;

		auto defs = buildPath(root, "defs");
		mkdirRecurse(buildPath(defs, "prompts"));
		write(buildPath(defs, "prompts", "blank.md"), "Blank prompt\n");
		auto definitions = buildPath(defs, "task-types.yaml");
		write(definitions, "task_types:\n  worker: {}\n"
			~ "user_entry_points:\n  start:\n    task_type: worker\n    description: Start work\n"
			~ "    prompt_template: prompts/blank.md\n");
		app = new App;
		app.config.default_agent = "claude";
		AgentConfig claudeConfig;
		claudeConfig.driver = typeof(claudeConfig.driver)(AgentDriver.claude, true);
		app.config.agents["claude"] = claudeConfig;
		app.configWatcher = new ConfigWatcher(ConfigWatcherHost(
			onProjectConfigChanged: &app.onProjectConfigChanged,
		));
		app.taskTypeCatalog = new TaskTypeCatalog(defs, definitions, (string name) => name == "claude",
			&app.reportProjectTaskTypeLoad, &app.configWatcher.ensureProjectWatch);
		app.taskTypeCatalog.reloadGlobal();
		app.discoveryService = new DiscoveryService(DiscoveryServiceHost.init);
		app.taskSessionRunner = new TaskSessionRunner(TaskSessionRunnerHost.init);
	}

	void repairThroughWatcher()
	{
		import ae.sys.timing : setTimeout;

		write(overridePath, "task_types: {}\n");
		setTimeout(&app.configWatcher.stop, 1.seconds);
		socketManager.loop();
		assert(projectNoticeId !in app.activeNotices, "Repair should clear the notice via the watcher");
	}

	void cleanup()
	{
		if (hadHome)
			environment["HOME"] = oldHome;
		else
			environment.remove("HOME");
		rmdirRecurse(root);
	}

	void assertLoadNotice(string id, string description, string impact, string path)
	{
		auto notice = id in app.activeNotices;
		assert(notice !is null, "Expected load failure notice " ~ id);
		assert(notice.level == NoticeLevel.alert);
		assert(notice.description == description);
		assert(notice.impact == impact);
		assert(notice.action.canFind(path) && notice.action.canFind("syntax error"), notice.action);
	}

	void assertSubmissionRefused(SubmissionCaptureWebSocket socket, string correlationId, int tid)
	{
		import std.algorithm : startsWith;

		assert(submissionRejectionCount(socket.sent) == 1, "Expected one submission rejection");
		auto rejection = parseJSON(socket.sent[$ - 1]);
		assert(rejection["correlation_id"].str == correlationId);
		assert(tid == -1 ? "tid" !in rejection.object : rejection["tid"].integer == tid);
		assert(rejection["kind"].str == "validation");
		auto reason = rejection["reason"].str;
		assert(reason.startsWith("Task types for this project failed to load: ")
			&& reason.canFind(overridePath) && reason.canFind("syntax error"), reason);
	}
}

unittest // A cold project publishes its load error and clears it after repair.
{
	TaskTypeLoadNoticeFixture fixture;
	fixture.setup("cold");
	scope (exit) fixture.cleanup();
	write(fixture.overridePath, fixture.invalidYaml);
	fixture.app.configWatcher.start();
	{
		auto socket = new SubmissionCaptureWebSocket;
		scope (exit) socket.disconnect("test complete", DisconnectType.requested);
		fixture.app.handleRequestTaskTypesMsg(socket, WsMessage(project_path: fixture.project));
	}

	fixture.assertLoadNotice(fixture.projectNoticeId,
		"Task types for " ~ fixture.project ~ " failed to load",
		"Tasks in this project cannot be started until this is fixed.", fixture.overridePath);

	fixture.repairThroughWatcher();
	assert(fixture.app.taskTypeCatalog.getEntryPointsForProject(fixture.project).byName("start") !is null);
}

unittest // A failed warm reload reports that the previous project snapshot is kept.
{
	TaskTypeLoadNoticeFixture fixture;
	fixture.setup("warm");
	scope (exit) fixture.cleanup();
	fixture.app.configWatcher.start();
	scope (exit) fixture.app.configWatcher.stop();
	assert(fixture.app.taskTypeCatalog.getEntryPointsForProject(fixture.project).byName("start") !is null);

	write(fixture.overridePath, fixture.invalidYaml);
	fixture.app.onProjectConfigChanged(fixture.project);
	fixture.assertLoadNotice(fixture.projectNoticeId,
		"Task types for " ~ fixture.project ~ " failed to load",
		"Keeping the previously loaded version.", fixture.overridePath);
	assert(fixture.app.taskTypeCatalog.getEntryPointsForProject(fixture.project).byName("start") !is null);
}

unittest // A rejected global edit raises a notice until the next accepted edit.
{
	import cydo.runtime.config.paths : userTaskTypesPath;

	TaskTypeLoadNoticeFixture fixture;
	fixture.setup("global");
	scope (exit) fixture.cleanup();
	auto path = userTaskTypesPath();
	write(path, fixture.invalidYaml);
	fixture.app.onUserTaskTypesChanged();
	fixture.assertLoadNotice("task-types", "Global task types were not reloaded",
		"Keeping the previously loaded version.", path);
	assert(fixture.app.taskTypeCatalog.getEntryPoints().byName("start") !is null);

	write(path, "task_types: {}\n");
	fixture.app.onUserTaskTypesChanged();
	assert("task-types" !in fixture.app.activeNotices);
}

unittest // A create-first load rejects until the watcher observes a repair.
{
	TaskTypeLoadNoticeFixture fixture;
	fixture.setup("create-refusal");
	scope (exit) fixture.cleanup();
	write(fixture.overridePath, fixture.invalidYaml);
	auto app = fixture.app;
	app.persistence = Persistence(":memory:");
	app.archiveManager = new ArchiveManager(ArchiveManagerHost.init);

	app.configWatcher.start();
	auto message = WsMessage(type: "create_task", workspace: "local",
		project_path: fixture.project, agent_name: "claude", entry_point: "start",
		correlation_id: "create-with-broken-task-types");
	{
		auto socket = new SubmissionCaptureWebSocket;
		app.clientHub.add(socket);
		scope (exit)
		{
			app.clientHub.remove(socket);
			socket.disconnect("test complete", DisconnectType.requested);
		}
		app.handleCreateTaskMsg(socket, message);
		fixture.assertSubmissionRefused(socket, "create-with-broken-task-types", -1);
	}
	assert(app.persistence.loadTasks().length == 0);
	assert(fixture.projectNoticeId in app.activeNotices);

	fixture.repairThroughWatcher();
	auto socket = new SubmissionCaptureWebSocket;
	app.clientHub.add(socket);
	scope (exit)
	{
		app.clientHub.remove(socket);
		socket.disconnect("test complete", DisconnectType.requested);
	}
	message.correlation_id = "create-after-repair";
	app.handleCreateTaskMsg(socket, message);
	assert(submissionRejectionCount(socket.sent) == 0);
	assert(socket.sent[0].canFind(`"type":"task_created"`)
		&& socket.sent[0].canFind(`"correlation_id":"create-after-repair"`));
	auto rows = app.persistence.loadTasks();
	assert(rows.length == 1 && rows[0].projectPath == fixture.project);
}

unittest // Sending the first message to a pending task requires a project snapshot.
{
	TaskTypeLoadNoticeFixture fixture;
	fixture.setup("pending-refusal");
	scope (exit) fixture.cleanup();
	write(fixture.overridePath, fixture.invalidYaml);
	auto app = fixture.app;
	app.configWatcher.start();
	scope (exit) app.configWatcher.stop();
	app.persistence = Persistence(":memory:");
	auto tid = app.persistence.createTask("local", fixture.project, "claude", "start");
	app.persistence.setTaskType(tid, "worker");
	app.persistence.setDraft(tid, "Start work");
	app.tasks[tid] = TaskData(tid, "local", fixture.project);
	app.tasks[tid].taskType = "worker";
	app.tasks[tid].entryPoint = "start";
	app.tasks[tid].draft = "Start work";
	app.tasks[tid].processQueue = new StateQueue!ProcessState(
		delegate Promise!ProcessState(ProcessState state) {
			assert(false, "A refused draft must not start the task");
		},
		ProcessState.Dead,
	);
	app.archiveManager = new ArchiveManager(ArchiveManagerHost(
		tryGetTask: (int lookupTid, out ArchiveTaskSnapshot snapshot) {
			snapshot.tid = lookupTid;
			return lookupTid == tid;
		},
	));
	auto socket = new SubmissionCaptureWebSocket;
	app.clientHub.add(socket);
	scope (exit) socket.disconnect("test complete", DisconnectType.requested);

	app.handleUserMessage(socket, testBrowserSubmission(tid, "Start work", "send-with-broken-task-types"));
	fixture.assertSubmissionRefused(socket, "send-with-broken-task-types", tid);
	auto rows = app.persistence.loadTasks();
	assert(rows.length == 1 && rows[0].tid == tid);
	assert(rows[0].status == TaskStatus.pending && rows[0].description.length == 0);
	assert(rows[0].draft == "Start work");
}

version (unittest) private final class FailingLaunchAgent : CodexAgent
{
	enum failure = "Injected session creation failure";

	override string executableName(string[string] env)
	{
		return "/bin/sh";
	}

	override AgentSession createSession(int tid, string resumeSessionId,
		ProcessLaunch launch, SessionConfig config = SessionConfig.init)
	{
		assert(config.includeTools.canFind("UnsandboxedCommand"));
		throw new Exception(failure);
	}
}

unittest // Preparing an ask policy cannot authorize tools if session creation fails.
{
	import cydo.runtime.config : UnsandboxedCommandExecution;
	import std.exception : collectException;
	import std.file : tempDir;
	import std.uuid : randomUUID;

	enum tid = 41;
	auto tmp = buildPath(tempDir(), "cydo-failed-launch-" ~ randomUUID().toString());
	mkdirRecurse(tmp);
	scope (exit) rmdirRecurse(tmp);
	writePromptParityFixture(tmp);
	auto projectPath = buildPath(tmp, "project");
	mkdirRecurse(projectPath);

	auto previousShell = environment.get("SHELL");
	environment["SHELL"] = "/bin/sh";
	scope (exit)
	{
		if (previousShell is null)
			environment.remove("SHELL");
		else
			environment["SHELL"] = previousShell;
	}

	auto app = new App();
	auto sandbox = SandboxConfig(
		isolate_filesystem: SetInfo!bool(false),
		isolate_processes: SetInfo!bool(false),
		isolate_environment: SetInfo!bool(false),
		unsandboxed_command_execution: SetInfo!string("ask"),
	);
	app.config.workspaces = [WorkspaceConfig(name: "local", root: tmp, sandbox: sandbox)];
	AgentConfig codexConfig;
	codexConfig.driver = SetInfo!AgentDriver(AgentDriver.codex, true);
	codexConfig.sandbox.env["CODEX_HOME"] = buildPath(tmp, "codex-profile");
	app.config.agents["codex"] = codexConfig;
	app.taskTypeCatalog = new TaskTypeCatalog(buildPath(tmp, "defs"),
		buildPath(tmp, "defs", "task-types.yaml"), &isKnownPromptParityAgent);

	app.tasks[tid] = TaskData(tid, "local", projectPath);
	app.tasks[tid].taskType = "parent";
	app.tasks[tid].agentName = "codex";
	auto agent = new FailingLaunchAgent;
	TaskData* getTask(int id) { return id in app.tasks ? &app.tasks[id] : null; }

	PermissionSettings permissionSettings(string agentName, string workspaceName)
	{
		return PermissionSettings.init;
	}

	app.taskSessionRunner = new TaskSessionRunner(TaskSessionRunnerHost(
		getTask: &getTask,
		taskDir: (const TaskData* td) => buildPath(tmp, "task"),
		outputPath: (const TaskData* td) => buildPath(tmp, "task", "output"),
		effectiveCwd: (const TaskData* td) => projectPath,
		worktreePath: (const TaskData* td) => "",
		currentConfig: () => &app.config,
		permissionSettings: &permissionSettings,
		reportMcpToolDescriptionLimit: (string project, string taskType,
			ToolDescriptionViolation[] violations) {},
		resolveSharedTmpPath: (int id) => buildPath(tmp, "shared-tmp"),
		mcpSocketPath: () => "",
		agentForTask: (int id) => agent,
		openToolCalls: &app.openToolCalls,
		taskTypeCatalog: app.taskTypeCatalog,
	));
	app.workflowTools = new WorkflowToolsBackend(WorkflowToolsHost(
		getTask: &getTask,
		permissionSettings: &permissionSettings,
		sendPermissionPrompt: (int id, const PendingPermission pending) {
			assert(0, "A failed launch must not send a permission prompt");
		},
	));

	auto failure = collectException(app.taskSessionRunner.spawnTaskSession(tid));
	assert(failure && failure.msg == FailingLaunchAgent.failure,
		failure is null ? "Session creation did not fail" : failure.msg);
	assert(app.sessionForTask(tid) is null);
	assert(app.tasks[tid].unsandboxedCommandExecution == UnsandboxedCommandExecution.ask);

	static struct CommandArgs
	{
		string command;
		string cwd;
		int timeout;
	}
	auto args = JSONFragment(toJson(CommandArgs("printf ran > marker", projectPath, 5)));
	bool completed;
	app.dispatchTool("UnsandboxedCommand", "41", "host-command-call", args, new ToolCallCancellation)
		.then((McpResult result) {
			assert(result.isError && result.text == "Cancelled by the agent", result.text);
			completed = true;
		});
	socketManager.loop();
	assert(completed, "Tool call must settle without waiting for permission");
	assert(!exists(buildPath(projectPath, "marker")));
}

unittest
{
	auto tmp = buildPath("/tmp", "cydo-app-task-prompt-parity");
	scope (exit)
	{
		if (exists(tmp))
			rmdirRecurse(tmp);
	}
	writePromptParityFixture(tmp);

	auto oldHome = environment.get("HOME", "");
	auto hadHome = "HOME" in environment;
	scope (exit)
	{
		if (hadHome)
			environment["HOME"] = oldHome;
		else
			environment.remove("HOME");
	}
	auto home = buildPath(tmp, "home");
	mkdirRecurse(home);
	mkdirRecurse(buildPath(home, ".claude"));
	mkdirRecurse(buildPath(home, ".local", "share", "claude"));
	mkdirRecurse(buildPath(home, ".copilot"));
	write(buildPath(home, ".claude.json"), "{}\n");
	environment["HOME"] = home;

	auto workspaceRoot = buildPath(tmp, "workspace");
	auto projectPath = buildPath(workspaceRoot, "project");
	mkdirRecurse(projectPath);

	App app = new App();
	app.config.sandbox = SandboxConfig(
		isolate_filesystem: SetInfo!bool(false),
		isolate_processes: SetInfo!bool(false),
		isolate_environment: SetInfo!bool(false),
	);
	app.config.workspaces = [WorkspaceConfig(name: "local", root: workspaceRoot,
		sandbox: app.config.sandbox)];
	AgentConfig codexConfig;
	codexConfig.driver = SetInfo!AgentDriver(AgentDriver.codex, true);
	codexConfig.sandbox = app.config.sandbox;
	codexConfig.sandbox.env["CODEX_HOME"] = buildPath(tmp, "codex-profile");
	app.config.agents["codex"] = codexConfig;
	AgentConfig claudeConfig;
	claudeConfig.driver = SetInfo!AgentDriver(AgentDriver.claude, true);
	claudeConfig.sandbox = app.config.sandbox;
	claudeConfig.sandbox.env["CLAUDE_CONFIG_DIR"] = buildPath(tmp, "claude-profile");
	app.config.agents["claude"] = claudeConfig;
	AgentConfig copilotConfig;
	copilotConfig.driver = SetInfo!AgentDriver(AgentDriver.copilot, true);
	copilotConfig.sandbox = app.config.sandbox;
	copilotConfig.sandbox.env["COPILOT_HOME"] = buildPath(tmp, "copilot-profile");
	app.config.agents["copilot"] = copilotConfig;
	app.taskDirTemplate = "{{ workspace_root }}/.cydo/tasks/{{ tid }}";
	app.taskTypeCatalog = new TaskTypeCatalog(buildPath(tmp, "defs"),
		buildPath(tmp, "defs", "task-types.yaml"),
		&isKnownPromptParityAgent);
	app.tasks[41] = TaskData(41, "local", projectPath);
	app.tasks[41].taskType = "parent";
	app.tasks[41].agentName = "codex";
	app.taskPathResolver = new TaskPathResolver(TaskPathResolverHost(
		getTask: (int tid) {
			auto td = tid in app.tasks;
			return td is null ? null : &app.tasks[tid];
		},
		workspaces: () => [WorkspaceConfig(name: "local", root: workspaceRoot)],
		taskDirTemplate: () => app.taskDirTemplate,
	));
	app.agentsByName["codex"] = new TestCodexPromptAgent();

	TaskTypeDef* currentTypeDef()
	{
		return app.taskTypeCatalog.getTaskTypesForProject(projectPath).byName("parent");
	}

	auto codexPrompt = app.taskSystemPromptForMessage(41, currentTypeDef());
	assert(codexPrompt.canFind("ROLE MARKER"), codexPrompt);
	assert(codexPrompt.canFind("GUIDANCE TASK MARKER"), codexPrompt);
	assert(codexPrompt.canFind("GUIDANCE SWITCH MARKER"), codexPrompt);
	assert(codexPrompt.canFind("GUIDANCE HANDOFF MARKER"), codexPrompt);

	auto runner = new TaskSessionRunner(TaskSessionRunnerHost(
		getTask: (int tid) {
			auto td = tid in app.tasks;
			return td is null ? null : &app.tasks[tid];
		},
		taskDir: (const TaskData* td) => app.taskPathResolver.taskDir(td),
		outputPath: (const TaskData* td) => app.taskPathResolver.outputPath(td),
		effectiveCwd: (const TaskData* td) => app.taskPathResolver.effectiveCwd(td),
		worktreePath: (const TaskData* td) => app.taskPathResolver.worktreePath(td),
		currentConfig: () => &app.config,
		permissionSettings: (string agentName, string workspaceName) => PermissionSettings.init,
		reportMcpToolDescriptionLimit: (string projectPath, string taskType,
			ToolDescriptionViolation[] violations) {},
		resolveSharedTmpPath: (int tid) => buildPath(tmp, "shared-tmp"),
		mcpSocketPath: () => "",
		taskTypeCatalog: app.taskTypeCatalog,
	));

	// projectPath is deliberately a plain directory. Launch preparation must
	// preserve non-Git projects rather than treating repoPath's fallback as a
	// checkout whose metadata needs mounting.
	assert(!app.tasks[41].isGitCheckout);
	auto codexLaunch = runner.prepareTaskSessionLaunch(41, new TestCodexPromptAgent(),
		currentTypeDef());
	auto codexProjectMode = codexLaunch.processLaunch.sandbox.paths.exact(projectPath);
	assert(!codexProjectMode.isNull);
	final switch (codexProjectMode.get.effectiveMode)
	{
	case PathMode.ro:
	case PathMode.rw:
	case PathMode.always_rw:
		break;
	case PathMode.tmpfs:
	case PathMode.empty_dir:
	case PathMode.empty_file:
		assert(0, "non-Git project is masked");
	}

	app.tasks[41].agentName = "claude";
	auto claudeLaunch = runner.prepareTaskSessionLaunch(41, new TestClaudePromptAgent(),
		currentTypeDef());
	auto claudeProjectMode = claudeLaunch.processLaunch.sandbox.paths.exact(projectPath);
	assert(!claudeProjectMode.isNull);
	final switch (claudeProjectMode.get.effectiveMode)
	{
	case PathMode.ro:
	case PathMode.rw:
	case PathMode.always_rw:
		break;
	case PathMode.tmpfs:
	case PathMode.empty_dir:
	case PathMode.empty_file:
		assert(0, "non-Git project is masked");
	}
	assert(claudeLaunch.sessionConfig.appendSystemPrompt == codexPrompt);

	app.tasks[41].agentName = "copilot";
	auto copilotLaunch = runner.prepareTaskSessionLaunch(41, new TestCopilotPromptAgent(),
		currentTypeDef());
	auto copilotProjectMode = copilotLaunch.processLaunch.sandbox.paths.exact(projectPath);
	assert(!copilotProjectMode.isNull);
	final switch (copilotProjectMode.get.effectiveMode)
	{
	case PathMode.ro:
	case PathMode.rw:
	case PathMode.always_rw:
		break;
	case PathMode.tmpfs:
	case PathMode.empty_dir:
	case PathMode.empty_file:
		assert(0, "non-Git project is masked");
	}
	assert(copilotLaunch.sessionConfig.appendSystemPrompt == codexPrompt);
}

version (unittest) private void writeToolDescriptionLimitFixture(string root,
	string yaml)
{
	auto defsDir = buildPath(root, "defs");
	mkdirRecurse(buildPath(defsDir, "prompts"));
	mkdirRecurse(buildPath(defsDir, "system_prompts"));
	write(buildPath(defsDir, "prompts", "blank.md"), "Blank prompt\n");
	write(buildPath(defsDir, "system_prompts", "role.md"), "Role prompt\n");
	write(buildPath(defsDir, "system_prompts", "master.md"),
		"{{role_prompt}}\n\n{{generated_guidance}}\n");
	write(buildPath(defsDir, "task-types.yaml"), yaml);
}

unittest
{
	import std.algorithm : canFind;
	import std.conv : to;

	string buildTaskTypesYaml(size_t idLength)
	{
		string repeated(char ch)
		{
			string result;
			foreach (_; 0 .. idLength)
				result ~= ch;
			return result;
		}

		string yaml = "task_types:\n"
			~ "  parent:\n"
			~ "    model_class: large\n"
			~ "    creatable_tasks:\n";

		foreach (i; 0 .. 8)
		{
			auto createId = "create-" ~ to!string(i) ~ "-" ~ repeated('a');
			yaml ~= "      " ~ createId ~ ":\n"
				~ "        task_type: child\n"
				~ "        prompt_template: prompts/blank.md\n";
		}

		yaml ~= "    continuations:\n";
		foreach (i; 0 .. 8)
		{
			auto switchId = "switch-" ~ to!string(i) ~ "-" ~ repeated('b');
			yaml ~= "      " ~ switchId ~ ":\n"
				~ "        task_type: mode\n"
				~ "        keep_context: true\n"
				~ "        prompt_template: prompts/blank.md\n";
		}
		foreach (i; 0 .. 8)
		{
			auto handoffId = "handoff-" ~ to!string(i) ~ "-" ~ repeated('c');
			yaml ~= "      " ~ handoffId ~ ":\n"
				~ "        task_type: followup\n"
				~ "        keep_context: false\n"
				~ "        prompt_template: prompts/blank.md\n";
		}

		yaml ~= "  child:\n"
			~ "    model_class: large\n"
			~ "  mode:\n"
			~ "    model_class: large\n"
			~ "  followup:\n"
			~ "    model_class: large\n";
		return yaml;
	}

	auto tmp = buildPath("/tmp", "cydo-app-mcp-tool-description-limit");
	scope (exit)
	{
		if (exists(tmp))
			rmdirRecurse(tmp);
	}
	writeToolDescriptionLimitFixture(tmp, buildTaskTypesYaml(220));

	auto oldHome = environment.get("HOME", "");
	auto hadHome = "HOME" in environment;
	scope (exit)
	{
		if (hadHome)
			environment["HOME"] = oldHome;
		else
			environment.remove("HOME");
	}
	auto home = buildPath(tmp, "home");
	mkdirRecurse(home);
	mkdirRecurse(buildPath(home, ".claude"));
	mkdirRecurse(buildPath(home, ".local", "share", "claude"));
	write(buildPath(home, ".claude.json"), "{}\n");
	environment["HOME"] = home;

	auto workspaceRoot = buildPath(tmp, "workspace");
	auto projectPath = buildPath(workspaceRoot, "project");
	mkdirRecurse(projectPath);
	auto config = new CydoConfig;
	config.sandbox = SandboxConfig(
		isolate_filesystem: SetInfo!bool(false),
		isolate_processes: SetInfo!bool(false),
		isolate_environment: SetInfo!bool(false),
	);
	config.workspaces = [WorkspaceConfig(name: "local", root: workspaceRoot,
		sandbox: config.sandbox)];
	AgentConfig configuredClaude;
	configuredClaude.driver = SetInfo!AgentDriver(AgentDriver.claude, true);
	configuredClaude.sandbox = config.sandbox;
	configuredClaude.sandbox.env["CLAUDE_CONFIG_DIR"] = buildPath(tmp,
		"claude-profile");
	config.agents["claude"] = configuredClaude;

	TaskTypeCatalog catalog = new TaskTypeCatalog(buildPath(tmp, "defs"),
		buildPath(tmp, "defs", "task-types.yaml"),
		&isKnownPromptParityAgent);

	TaskData[int] tasks;
	tasks[7] = TaskData(7, "local", projectPath);
	tasks[7].taskType = "parent";
	tasks[7].agentName = "claude";

	auto taskPathResolver = new TaskPathResolver(TaskPathResolverHost(
		getTask: (int tid) {
			auto td = tid in tasks;
			return td is null ? null : &tasks[tid];
		},
		workspaces: () => [WorkspaceConfig(name: "local", root: workspaceRoot)],
		taskDirTemplate: () => "{{ workspace_root }}/.cydo/tasks/{{ tid }}",
	));

	ToolDescriptionViolation[][] reportedViolations;
	string[] reportedProjects;
	string[] reportedTaskTypes;

	auto runner = new TaskSessionRunner(TaskSessionRunnerHost(
		getTask: (int tid) {
			auto td = tid in tasks;
			return td is null ? null : &tasks[tid];
		},
		taskDir: (const TaskData* td) => taskPathResolver.taskDir(td),
		outputPath: (const TaskData* td) => taskPathResolver.outputPath(td),
		effectiveCwd: (const TaskData* td) => taskPathResolver.effectiveCwd(td),
		worktreePath: (const TaskData* td) => taskPathResolver.worktreePath(td),
		currentConfig: () => config,
		permissionSettings: (string agentName, string workspaceName) => PermissionSettings("allow all"),
		reportMcpToolDescriptionLimit: (string projectPathValue,
			string taskTypeValue, ToolDescriptionViolation[] violations) {
			reportedProjects ~= projectPathValue;
			reportedTaskTypes ~= taskTypeValue;
			reportedViolations ~= violations.dup;
		},
		resolveSharedTmpPath: (int tid) => buildPath(tmp, "shared-tmp"),
		mcpSocketPath: () => "",
		taskTypeCatalog: catalog,
	));

	auto agent = new TestClaudePromptAgent();
	auto typeDef = catalog.getTaskTypesForProject(projectPath).byName("parent");
	auto launch = runner.prepareTaskSessionLaunch(7, agent, typeDef);
	assert(launch.sessionConfig.permissions.policy == "allow all");
	assert(reportedViolations.length == 1);
	assert(reportedProjects == [projectPath]);
	assert(reportedTaskTypes == ["parent"]);

	RenderedCydoToolsOptions options;
	options.includeBash = agent.needsBash();
	auto types = catalog.getTaskTypesForProject(projectPath);
	auto entryPoints = catalog.getEntryPointsForProject(projectPath);
	auto singletons = singletonsOfferedTo(types, entryPoints,
		catalog.singletonsForProject(projectPath), "parent");
	auto expectedViolations = checkRenderedCydoToolDescriptionViolations(
		types, entryPoints, "parent", formatCompactSingletonToolSummary(singletons),
		options: options,
	);
	assert(reportedViolations[0] == expectedViolations);
	assert(expectedViolations.length > 0);

	writeToolDescriptionLimitFixture(tmp, buildTaskTypesYaml(8));
	catalog.reloadGlobal();
	catalog.reloadProject(projectPath);
	typeDef = catalog.getTaskTypesForProject(projectPath).byName("parent");
	runner.prepareTaskSessionLaunch(7, agent, typeDef);
	assert(reportedViolations.length == 2);
	assert(reportedViolations[1].length == 0);
}

unittest
{
	App app = new App();

	auto projectPath = "/tmp/project";
	auto taskType = "review";
	auto noticeId = mcpToolDescriptionLimitNoticeId(projectPath, taskType);
	auto expectedId = "mcp-tool-description-limit:2f746d702f70726f6a656374:review";
	assert(noticeId == expectedId);

	auto violations = [
		ToolDescriptionViolation("review", "Task", 2205, mcpToolDescriptionMaxChars),
		ToolDescriptionViolation("review", "SwitchMode", 2104,
			mcpToolDescriptionMaxChars),
		ToolDescriptionViolation("review", "Handoff", 2055,
			mcpToolDescriptionMaxChars),
		ToolDescriptionViolation("review", "AskUserQuestion", 2001,
			mcpToolDescriptionMaxChars),
	];

	app.reportMcpToolDescriptionLimit(projectPath, taskType, violations);
	auto stored = noticeId in app.activeNotices;
	assert(stored !is null);
	assert(stored.level == NoticeLevel.warning);
	assert(stored.description.canFind("oversized MCP tool descriptions"));
	assert(stored.description.canFind("2000-character limit"));
	assert(stored.impact
		== "Largest violations: review/Task 2205 > 2000; review/SwitchMode 2104 > 2000; review/Handoff 2055 > 2000");
	assert(!stored.impact.canFind("AskUserQuestion"));
	assert(stored.action
		== "Shorten user/project task-type guidance or move verbose guidance into system prompts.");
	assert(stored.action_kind == "");

	app.reportMcpToolDescriptionLimit(projectPath, taskType, []);
	assert((noticeId in app.activeNotices) is null);
}

// Regression for review 34528 Issue A: when the resolution is `unavailable`
// under both the live binding (B, from taskSessionRunner.resolveTaskHistory)
// and current config (C, re-resolved by resetHistoryWatermark) — the
// ordinary single-profile case where B == C — both post-exit reset entry
// points (resetHistoryWatermarkAfterExit and resetHistoryWatermarkOnly) must
// end with exactly one unavailable-history report/broadcast, regardless of
// whether history was already loaded live before exit; ensureHistoryLoadedForExit
// and finalReconcileJsonlIfPresent must both stay silent. Which of onExit's
// three branches selects which entry point is covered by e2e, not here.
unittest
{
	App buildFixture(string dbPath, out int tid, out int* reloadCount,
		out SubmissionCaptureWebSocket socket)
	{
		if (exists(dbPath))
			remove(dbPath);
		auto app = new App();
		app.persistence = Persistence(dbPath);
		tid = app.persistence.createTask();
		app.tasks[tid] = TaskData(tid, "local", "/tmp/cydo-app-exit-unavailable");
		app.tasks[tid].taskType = "test";
		app.tasks[tid].status = TaskStatus.active;

		auto unavailable = TaskHistoryResolution.unavailable(UnavailableHistory(
			UnavailableHistoryKind.context, "claude", "session-1",
			"The derived history file does not exist"));
		auto runner = new GatedSubmissionRunner(new GatedSubmissionSession);
		runner.resolveTaskHistoryOverride = (int) => unavailable;
		app.taskSessionRunner = runner;

		// `App.start()` (not `App`'s default constructor) is what wires
		// historyPipeline/jsonlTracker/derivedTextJobs in production; this
		// fixture wires the same collaborators by hand, using the App's own
		// private resolveTaskHistory/reportUnavailableHistory so the exit
		// path under test exercises the real reporting logic.
		app.historyPipeline = new HistoryEventPipeline(HistoryEventPipelineHost(
			getTask: (int lookupTid) {
				auto task = lookupTid in app.tasks;
				return task is null ? null : task;
			},
			resolveTaskHistory: &app.resolveTaskHistory,
			reportUnavailableHistory: &app.reportUnavailableHistory,
			makeTaskDiagnosticEventJson: &app.makeTaskDiagnosticEventJson,
		));
		app.jsonlTracker.getTask = (int lookupTid) {
			auto task = lookupTid in app.tasks;
			return task is null ? null : task;
		};
		app.jsonlTracker.resolveTaskHistory = &app.resolveTaskHistory;
		app.derivedTextJobs = new DerivedTextJobs(DerivedTextJobsHost(
			getTask: (int lookupTid) {
				auto task = lookupTid in app.tasks;
				return task is null ? null : task;
			},
			suggestionsEnabled: () => app.config.suggestions,
		));

		reloadCount = new int;
		// Capture the pointer by value, not the `out` parameter itself: the
		// closure outlives this call frame, so closing over `reloadCount`
		// directly would leave it pointing at a dangling slot in the caller.
		auto reloadCountRef = reloadCount;
		socket = new SubmissionCaptureWebSocket((string payload) {
			if (payload.canFind(`"type":"task_reload"`))
				(*reloadCountRef)++;
		});
		app.clientHub.add(socket);
		return app;
	}

	// Sub-case A: history was never loaded live (the common case — nobody
	// was viewing the task). ensureHistoryLoadedForExit performs the
	// resolution itself and must not report it.
	void checkNeverLoaded(bool delegate(App, int) reset, string dbSuffix)
	{
		auto dbPath = buildPath(tempDir(), "cydo-app-exit-unavailable-" ~ dbSuffix ~ "-never-loaded.sqlite");
		scope(exit) if (exists(dbPath)) remove(dbPath);
		int tid;
		int* reloadCount;
		SubmissionCaptureWebSocket socket;
		auto app = buildFixture(dbPath, tid, reloadCount, socket);
		scope(exit)
		{
			socket.disconnect("test complete", DisconnectType.requested);
			app.clientHub.remove(socket);
		}

		assert(!app.tasks[tid].history.isLoaded);
		auto historyResolution = app.historyPipeline.ensureHistoryLoadedForExit(tid);
		assert(app.tasks[tid].history.isLoaded);
		app.jsonlTracker.finalReconcileJsonlIfPresent(tid, historyResolution);
		assert(*reloadCount == 0, "pre-boundary exit-path load/reconcile must not report");

		auto reloadEmitted = reset(app, tid);
		assert(reloadEmitted);
		assert(*reloadCount == 1, "post-exit reset must report exactly once: " ~ dbSuffix);
	}

	// Sub-case B: history was already loaded live before onExit ran (a
	// client was subscribed), so ensureHistoryLoadedForExit short-circuits.
	// finalReconcileJsonlIfPresent must self-resolve without reporting.
	void checkAlreadyLoaded(bool delegate(App, int) reset, string dbSuffix)
	{
		auto dbPath = buildPath(tempDir(), "cydo-app-exit-unavailable-" ~ dbSuffix ~ "-already-loaded.sqlite");
		scope(exit) if (exists(dbPath)) remove(dbPath);
		int tid;
		int* reloadCount;
		SubmissionCaptureWebSocket socket;
		auto app = buildFixture(dbPath, tid, reloadCount, socket);
		scope(exit)
		{
			socket.disconnect("test complete", DisconnectType.requested);
			app.clientHub.remove(socket);
		}
		app.tasks[tid].history.reset(Watermark.unreadable());
		app.tasks[tid].history.load((ulong) => LoadedHistory.init);
		assert(app.tasks[tid].history.isLoaded);

		auto historyResolution = app.historyPipeline.ensureHistoryLoadedForExit(tid);
		assert(historyResolution.isNull, "already-loaded history must short-circuit");
		app.jsonlTracker.finalReconcileJsonlIfPresent(tid, historyResolution);
		assert(*reloadCount == 0, "pre-boundary exit-path load/reconcile must not report");

		auto reloadEmitted = reset(app, tid);
		assert(reloadEmitted);
		assert(*reloadCount == 1, "post-exit reset must report exactly once: " ~ dbSuffix);
	}

	// resetHistoryWatermarkAfterExit — the default onExit branch.
	checkNeverLoaded((App app, int tid) => app.resetHistoryWatermarkAfterExit(tid), "after-exit");
	checkAlreadyLoaded((App app, int tid) => app.resetHistoryWatermarkAfterExit(tid), "after-exit");
	// resetHistoryWatermarkOnly — shared by the missingExecutableLaunchFailure
	// and undoStopInProgress onExit branches.
	checkNeverLoaded((App app, int tid) => app.resetHistoryWatermarkOnly(tid), "only");
	checkAlreadyLoaded((App app, int tid) => app.resetHistoryWatermarkOnly(tid), "only");
}

version (unittest) private final class ArchivePendingExitProbeRunner : TaskSessionRunner
{
	bool pending = true;
	int deliveries;

	this()
	{
		super(TaskSessionRunnerHost.init);
	}

	override void settlePendingExit(int tid)
	{
		assert(tid == 1);
		if (pending)
		{
			pending = false;
			deliveries++;
		}
	}
}

unittest
{
	auto app = new App;
	app.tasks[1] = TaskData(1, "local", "/tmp/cydo-archive-pending-exit");
	auto runner = new ArchivePendingExitProbeRunner;
	app.taskSessionRunner = runner;
	assert(app.updateArchiveTaskState(1, true, true));
	assert(runner.deliveries == 1 && !runner.pending);
	assert(app.tasks[1].archived && app.tasks[1].archiving);
	assert(app.updateArchiveTaskState(1, false, false));
	assert(runner.deliveries == 1);
	assert(!app.tasks[1].archived && !app.tasks[1].archiving);
}


@("Claude mirror recognizes the canonical echo after nested user-shaped tool input")
unittest
{
	auto dbPath = buildPath(tempDir(), "cydo-verify-42206-tail.sqlite");
	if (exists(dbPath)) remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);
	auto fixture = new GatedSubmissionFixture(dbPath);
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	auto td = &fixture.app.tasks[fixture.tid];
	td.agentName = "claude";
	fixture.attachClaudeMirror(fixture.tid);
	td.reserveNativeSubmission("local-echo", "next", td.history.generation, "next");
	fixture.app.jsonlTracker.ingestMirrorRows(fixture.tid, [
		`{"type":"assistant","uuid":"assistant-row","apiBlockIndex":0,"message":{"id":"msg_api","content":[{"type":"tool_use","id":"tool-id","name":"mcp__test__save","input":{"type":"user","nested":{"type":"assistant","isMeta":true,"isSidechain":true,"subtype":"compact_boundary","operation":"queue-operation"}}}]}}`]);
	fixture.app.jsonlTracker.ingestMirrorRows(fixture.tid, [
		`{"type":"user","uuid":"local-echo","message":{"role":"user","content":"next"}}`]);
	assert(td.nativeSubmission("local-echo").tailState == SubmissionTailState.canonical);
}

@("Post-compaction reminder echo arms the in-flight guard")
unittest
{
	auto fixture = new GatedSubmissionFixture(":memory:");
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	fixture.app.config.system_keyword = "SYSTEM";
	auto td = &fixture.app.tasks[fixture.tid];
	td.agentName = "claude";
	auto reminder = systemMessagePrefix(fixture.app.config.system_keyword,
		KnownSystemMessageKind.postCompactionTaskModeReminder) ~ "\n\nTask mode reminder";
	foreach (parentToolUseId; [null, "parent-tool"])
	{
		td.compactionReminderInFlight = false;
		ItemStartedEvent event;
		event.item_id = "reminder-echo";
		event.item_type = "user_message";
		event.content = [ContentBlock("text", reminder)];
		event.parent_tool_use_id = parentToolUseId;
		fixture.app.planHistoryBroadcast(fixture.tid, TranslatedEvent(toJson(event), null));
		assert(td.compactionReminderInFlight);
	}
}

version (unittest) private void withLegacyLastActiveTask(
	void delegate(GatedSubmissionFixture, GatedSubmissionRunner, string path) verify)
{
	import ae.sys.database : Database, selectValue;
	import std.file : mkdir, rmdirRecurse;
	import std.uuid : randomUUID;

	auto root = buildPath(tempDir(), "cydo-legacy-last-active-" ~ randomUUID().toString());
	mkdir(root);
	scope (exit) rmdirRecurse(root);
	auto dbPath = buildPath(root, "tasks.sqlite");
	auto fixture = new GatedSubmissionFixture(dbPath);
	scope (exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	auto db = Database(dbPath);
	auto tid = fixture.tid;
	db.stmt!"UPDATE tasks SET last_active = NULL WHERE tid = ?".exec(tid);
	auto row = fixture.app.persistence.loadTasks()[0];
	assert(row.tid == tid && row.lastActive == 0);
	fixture.app.tasks[tid].createdAt = row.createdAt;
	fixture.app.tasks[tid].agentSessionId = "legacy-session";

	verify(fixture, cast(GatedSubmissionRunner) fixture.app.taskSessionRunner,
		buildPath(root, "history.jsonl"));

	auto isNull = db.stmt!"SELECT last_active IS NULL FROM tasks WHERE tid = ?"
		.iterate(tid).selectValue!int;
	assert((isNull != 0) == (fixture.app.persistence.loadTasks()[0].lastActive == 0));
}

unittest
{
	import std.datetime : SysTime;
	import std.file : append, setTimes, write;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;

	withLegacyLastActiveTask((fixture, runner, path) {
		enum timestamp = "2026-03-30T14:29:14.993Z";
		auto expected = SysTime.fromISOExtString(timestamp).stdTime;
		write(path, `{"type":"assistant","timestamp":"` ~ timestamp ~ `"}` ~ "\n"
			~ "{\"type\":\"mode\"}\n");
		auto task = &fixture.app.tasks[fixture.tid];
		auto agent = new ClaudeCodeAgent;
		runner.resolveTaskHistoryOverride = (int tid) => TaskHistoryResolution.access(
			HistoryAccess(agent, NativeHistoryProfile(agent.driver, tempDir()),
				task.agentSessionId, path));

		fixture.app.recoverLastActive();
		assert(task.lastActive == expected);
		assert(fixture.app.persistence.loadTasks()[0].lastActive == expected);

		append(path, "{\"type\":\"last-prompt\"}\n");
		auto newer = SysTime.fromISOExtString("2026-03-31T00:00:00Z");
		setTimes(path, newer, newer);
		// Simulate reloading the persisted value on the next startup.
		task.lastActive = fixture.app.persistence.loadTasks()[0].lastActive;
		runner.resolveTaskHistoryOverride = delegate TaskHistoryResolution(int tid) {
			assert(false, "Recovered tasks must not resolve history again");
		};
		fixture.app.recoverLastActive();
		assert(task.lastActive == expected);
		assert(fixture.app.persistence.loadTasks()[0].lastActive == expected);
	});
}

unittest
{
	import std.file : write;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;

	foreach (malformed; ["", "invalid JSON", "{}",
		`{"type":"attachment","timestamp":"bogus"}`])
	{
		withLegacyLastActiveTask((fixture, runner, path) {
			write(path, malformed.length != 0
				? "{\"type\":\"user\",\"timestamp\":\"2026-03-30T14:29:14Z\"}\n" ~ malformed ~ "\n"
				: "{\"type\":\"last-prompt\"}\n");
			auto task = &fixture.app.tasks[fixture.tid];
			auto agent = new ClaudeCodeAgent;
			runner.resolveTaskHistoryOverride = (int tid) => TaskHistoryResolution.access(
				HistoryAccess(agent, NativeHistoryProfile(agent.driver, tempDir()),
					task.agentSessionId, path));

			fixture.app.recoverLastActive();
			assert(task.lastActive == task.createdAt);
			assert(fixture.app.persistence.loadTasks()[0].lastActive
				== (malformed.length != 0 ? 0 : task.createdAt));
		});
	}
}

unittest
{
	import cydo.workflow.history.native_history : DriverHistoryTestAgent;

	withLegacyLastActiveTask((fixture, runner, path) {
		auto task = &fixture.app.tasks[fixture.tid];
		auto agent = new DriverHistoryTestAgent;
		runner.resolveTaskHistoryOverride = (int tid) => TaskHistoryResolution.access(
			HistoryAccess.driverServed(agent,
				NativeHistoryProfile(agent.driver, "/unused-profile"), task.agentSessionId));

		fixture.app.recoverLastActive();
		assert(task.lastActive == task.createdAt);
		assert(fixture.app.persistence.loadTasks()[0].lastActive == task.createdAt);
	});
}

unittest
{
	withLegacyLastActiveTask((fixture, runner, path) {
		auto task = &fixture.app.tasks[fixture.tid];
		runner.resolveTaskHistoryOverride = (int tid) => TaskHistoryResolution.unavailable(
			UnavailableHistory(UnavailableHistoryKind.context, "claude",
				task.agentSessionId, "The derived history file does not exist"));

		fixture.app.recoverLastActive();
		assert(task.lastActive == task.createdAt);
		assert(fixture.app.persistence.loadTasks()[0].lastActive == 0);
	});
}

@("An armed guard suppresses a second post-compaction reminder")
unittest
{
	import cydo.protocol : SessionCompactedEvent;

	auto root = buildPath(tempDir(), "cydo-app-compaction-reminder");
	if (exists(root)) rmdirRecurse(root);
	scope(exit) rmdirRecurse(root);
	mkdirRecurse(buildPath(root, "system_prompts"));
	write(buildPath(root, "system_prompts", "master.md"), "{{ role_prompt }}");
	write(buildPath(root, "system_prompts", "test.md"), "Test task instructions");
	// The catalog synthesizes a blank entry point whose prompt must exist.
	mkdirRecurse(buildPath(root, "prompts"));
	write(buildPath(root, "prompts", "blank.md"), "Blank prompt\n");
	auto definitions = buildPath(root, "task-types.yaml");
	write(definitions,
		"task_types:\n"
		~ "  test:\n"
		~ "    model_class: large\n"
		~ "    system_prompt_template: system_prompts/test.md\n");

	auto fixture = new GatedSubmissionFixture(":memory:");
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	auto app = fixture.app;
	auto td = &app.tasks[fixture.tid];
	// Use the fixture's Codex agent, which receives task instructions as user messages.
	td.agentName = "test";
	td.projectPath = root;
	app.config.system_keyword = "SYSTEM";
	app.taskTypeCatalog = new TaskTypeCatalog(root, definitions, (string name) => true);
	app.taskPathResolver = new TaskPathResolver(TaskPathResolverHost(
		workspaces: () => [WorkspaceConfig(name: "local", root: root)],
		taskDirTemplate: () => "{{ workspace_root }}/tasks/{{ tid }}",
	));
	app.systemMessageNormalizer = new SystemMessageNormalizer(SystemMessageNormalizerHost.init);

	auto compacted = TranslatedEvent(toJson(SessionCompactedEvent.init), null);
	app.planHistoryBroadcast(fixture.tid, compacted);
	assert(fixture.session.sendCalls == 1, "The first compaction must submit a reminder");
	assert(td.compactionReminderInFlight);

	app.planHistoryBroadcast(fixture.tid, compacted);
	assert(fixture.session.sendCalls == 1, "An in-flight reminder must suppress a second submission");
}

version (unittest) private final class DriverHistoryTurnFixture
{
	GatedSubmissionFixture base;
	Promise!DriverHistory[] reads;
	TaskData* td;

	this()
	{
		import cydo.workflow.history.native_history : DriverHistoryTestAgent;

		base = new GatedSubmissionFixture(":memory:");
		auto app = base.app;
		app.config.suggestions = false;
		auto agent = new DriverHistoryTestAgent;
		auto access = HistoryAccess.driverServed(agent,
			NativeHistoryProfile(agent.driver, "/unused-profile"), "driver-session");
		app.historyPipeline = new HistoryEventPipeline(HistoryEventPipelineHost(
			getTask: (int tid) => tid in app.tasks,
			resolveTaskHistory: (int tid) => TaskHistoryResolution.access(access),
			injectAgentNameIntoSessionInit: (string translated, string agentName) => translated,
			broadcastHistoryOperations: (int tid) {},
			loadDriverHistory: (int tid, HistoryAccess resolved) {
				auto read = new Promise!DriverHistory;
				reads ~= read;
				return read;
			},
		));
		app.taskLifecycle = TaskLifecycle(
			getTask: (int tid) => tid in app.tasks,
			persistStatus: (int tid, string status) => app.persistence.setStatus(tid, status),
			persistNeedsAttention: (int tid, bool needsAttention) =>
				app.persistence.setNeedsAttention(tid, needsAttention),
			publishSnapshot: (int tid) => app.broadcastTaskUpdate(tid),
		);
		td = &app.tasks[base.tid];
		td.agentName = "claude";
		td.history.reset(Watermark.driverServed());
	}
}

// A turn that ends without result text becomes alive at once; only the
// notification text waits for the history read.
unittest
{
	auto fixture = new DriverHistoryTurnFixture;
	scope(exit) fixture.base.socket.disconnect("test complete", DisconnectType.requested);
	auto td = fixture.td;
	fixture.base.app.onTaskTurnCompletedAlive(fixture.base.tid);
	assert(td.status == TaskStatus.alive && td.needsAttention);
	assert(td.notificationBody.length == 0 && fixture.reads.length == 1);

	auto updates = fixture.base.publicationOrder.length;
	fixture.reads[0].fulfill(DriverHistory([TranslatedEvent(
		`{"type":"item/started","item_id":"a","item_type":"text","text":"last words"}`, null)], 0));
	drainSubmissionNextTicks();
	assert(td.notificationBody == "last words");
	assert(fixture.base.publicationOrder[updates .. $] == ["task_update"]);
}

// A configured singleton finishes its turn without raising a notification.
unittest
{
	auto root = buildPath(tempDir(), "cydo-app-singleton-turn");
	if (exists(root))
		rmdirRecurse(root);
	scope(exit) rmdirRecurse(root);
	mkdirRecurse(buildPath(root, "prompts"));
	write(buildPath(root, "prompts", "blank.md"), "Blank prompt\n");
	write(buildPath(root, "prompts", "start.md"), "{{task_description}}\n");
	auto definitions = buildPath(root, "task-types.yaml");
	write(definitions,
		"task_types:\n"
		~ "  test:\n"
		~ "    model_class: large\n"
		~ "singletons:\n"
		~ "  turn_test_singleton:\n"
		~ "    task_type: test\n"
		~ "    title: Turn test singleton\n"
		~ "    description: Turn test singleton\n"
		~ "    prompt_template: prompts/start.md\n");

	auto fixture = new DriverHistoryTurnFixture;
	scope(exit) fixture.base.socket.disconnect("test complete", DisconnectType.requested);
	auto app = fixture.base.app;
	app.taskTypeCatalog = new TaskTypeCatalog(root, definitions, (string name) => true);
	auto td = fixture.td;
	td.projectPath = root;
	td.entryPoint = "turn_test_singleton";
	td.resultText = "Singleton finished";
	app.touchAndPersistLastActive(fixture.base.tid);
	auto lastActive = td.lastActive;

	app.onTaskTurnCompletedAlive(fixture.base.tid);

	assert(td.status == TaskStatus.alive);
	assert(td.lastActive == lastActive);
	assert(!td.needsAttention);
	assert(td.notificationBody.length == 0);
	auto row = app.persistence.loadTasks()[0];
	assert(row.lastActive == td.lastActive);
	assert(!row.needsAttention);
}

// The session exits while the text is being read: the stale read and its
// replacement settle without touching the failed task.
unittest
{
	auto fixture = new DriverHistoryTurnFixture;
	scope(exit) fixture.base.socket.disconnect("test complete", DisconnectType.requested);
	auto td = fixture.td;
	fixture.base.app.onTaskTurnCompletedAlive(fixture.base.tid);
	assert(fixture.reads.length == 1);

	td.history.reset(Watermark.driverServed());
	td.status = TaskStatus.failed;
	auto updates = fixture.base.publicationOrder.length;
	fixture.reads[0].fulfill(DriverHistory.init);
	drainSubmissionNextTicks();
	assert(fixture.reads.length == 2);
	fixture.reads[1].fulfill(DriverHistory([TranslatedEvent(
		`{"type":"item/started","item_id":"a","item_type":"text","text":"last words"}`, null)], 0));
	drainSubmissionNextTicks();
	assert(td.status == TaskStatus.failed && td.notificationBody.length == 0);
	assert(fixture.base.publicationOrder.length == updates);
}

// A release followed by a new claim in the same transition must leave all
// subscribers busy. Replay establishes the starting policy for each socket.
unittest
{
	import cydo.domain.tasks.model : HistoryOperationsMessage;
	import cydo.workflow.history.operations : HistoryOperationMechanism;

	auto app = new App;
	auto runner = new GatedSubmissionRunner(null);
	auto agent = new TestCodexPromptAgent;
	auto access = HistoryAccess.driverServed(agent,
		NativeHistoryProfile(agent.driver, "/unused-profile"), "driver-session");
	runner.resolveTaskHistoryOverride = (int tid) => TaskHistoryResolution.access(access);
	app.taskSessionRunner = runner;
	enum tid = 42;
	app.tasks[tid] = TaskData(tid, "local", "/tmp");
	auto task = &app.tasks[tid];
	task.agentName = "codex";
	auto ws = new SubmissionCaptureWebSocket;
	scope (exit) ws.disconnect("test complete", DisconnectType.requested);
	app.clientHub.add(ws);
	app.clientHub.subscribe(ws, tid, Nullable!HistoryOperations(
		app.historyOperationsForTask(tid, agent)));

	task.beginConfirmedNativeUndo();
	app.scheduleHistoryOperations(tid);
	drainSubmissionNextTicks();
	assert(ws.sent.length == 1);
	auto busy = jsonParse!HistoryOperationsMessage(ws.sent[0]);
	assert(busy.history_operations.fork.agent_turn == HistoryOperationMechanism.none);

	task.completeVerifiedNativeUndoCleanup();
	app.scheduleHistoryOperations(tid);
	task.beginConfirmedNativeUndo();
	app.scheduleHistoryOperations(tid);
	assert(ws.sent.length == 1, "A compound transition cannot publish synchronously");
	drainSubmissionNextTicks();
	assert(ws.sent.length == 1, "A release and reacquisition must not advertise Fork");

	task.completeVerifiedNativeUndoCleanup();
	app.scheduleHistoryOperations(tid);
	drainSubmissionNextTicks();
	assert(ws.sent.length == 2);
	auto ready = jsonParse!HistoryOperationsMessage(ws.sent[1]);
	assert(ready.history_operations.fork.agent_turn == HistoryOperationMechanism.codex_native);
}

// Editing rewrites a history file. A driver-served history has none: both
// edits are refused, and nothing is loaded for them.
unittest
{
	import cydo.workflow.history.native_history : DriverHistoryTestAgent;
	import cydo.workflow.tasks.mutations : TaskMutationService, TaskMutationServiceHost;

	auto fixture = new GatedSubmissionFixture(":memory:");
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	auto app = fixture.app;
	auto agent = new DriverHistoryTestAgent;
	auto access = HistoryAccess.driverServed(agent,
		NativeHistoryProfile(agent.driver, "/unused-profile"), "driver-session");
	auto service = new TaskMutationService(TaskMutationServiceHost(
		getTask: (int tid) => tid in app.tasks,
		taskAlive: (int tid) => false,
		resolveTaskHistory: (int tid) => TaskHistoryResolution.access(access),
		ensureHistoryLoaded: (int tid) {
			assert(0, "A refused edit must not load history");
		},
	));
	auto td = &app.tasks[fixture.tid];
	td.agentSessionId = "driver-session";
	td.history.reset(Watermark.driverServed());

	WsMessage message;
	message.tid = fixture.tid;
	message.seq = 0;
	message.anchor = "enqueue-1";
	service.handleEditRawEvent(fixture.socket, message);
	assert(fixture.socket.sent[$ - 1].canFind("Editing events is not supported for this agent"));
	service.handleEditMessage(fixture.socket, message);
	assert(fixture.socket.sent[$ - 1].canFind("Editing messages is not supported for this agent"));
	assert(!td.history.isLoaded);
}

unittest
{
	import cydo.agent.drivers.copilot : CopilotAgent;
	import cydo.foundation.testing : drainNextTicksAndDueTimers;
	import std.file : readText;

	auto path = buildPath(tempDir(), "cydo-app-copilot-edit-message.jsonl");
	enum original = `{"type": "user.message", "id": "user-id", "data": {"content": "original"}}` ~ "\n";
	write(path, original);
	scope(exit) remove(path);

	auto fixture = new GatedSubmissionFixture(":memory:");
	scope(exit) fixture.socket.disconnect("test complete", DisconnectType.requested);
	auto app = fixture.app;
	auto agent = new CopilotAgent;
	auto access = HistoryAccess(agent,
		NativeHistoryProfile(agent.driver, tempDir()), "copilot-session", path);
	app.tasks[fixture.tid].agentSessionId = access.sessionId;
	app.taskMutationService = new TaskMutationService(TaskMutationServiceHost(
		getTask: (int tid) => tid in app.tasks,
		taskAlive: (int tid) => false,
		resolveTaskHistory: (int tid) => TaskHistoryResolution.access(access),
		invalidateJsonlLineage: (int tid) {
			assert(0, "A refused edit must not invalidate Copilot history");
		},
	));

	auto repliesBefore = fixture.socket.sent.length;
	app.handleEditMessage(fixture.socket, WsMessage(
		tid: fixture.tid, anchor: "user-id", content: JSONFragment(toJson("replacement"))));
	assert(fixture.socket.sent.length == repliesBefore + 1, "Expected an edit refusal");
	auto reply = jsonParse!ErrorMessage(fixture.socket.sent[$ - 1]);
	assert(reply.type == "error" && reply.tid == fixture.tid
		&& reply.message == "Editing messages is not supported for this agent");
	assert(readText(path) == original, "A refused edit must leave Copilot history intact");
	drainNextTicksAndDueTimers();
}

version (unittest) private final class CodexOfferFixture
{
	enum sessionId = "01a1feae-9e4c-7d83-a43c-dbd595e0221d";
	enum retainedEvent = `{"type":"item/started","item_id":"retained","item_type":"text","text":"retained turn"}`;
	GatedSubmissionFixture base;
	App app;
	string profileRoot;
	string rolloutPath;
	int tid;
	size_t driverReads;

	this(string root)
	{
		import cydo.agent.contract : DiscoveredSession;
		import cydo.workflow.discovery.service : NativeSessionKey;

		base = new GatedSubmissionFixture(":memory:");
		app = base.app;
		profileRoot = buildPath(root, "codex-profile");
		rolloutPath = buildPath(profileRoot, "sessions", "rollout.jsonl");
		mkdirRecurse(buildPath(profileRoot, "sessions"));
		write(rolloutPath, "{}\n");
		auto projectPath = buildPath(root, "project");
		mkdirRecurse(projectPath);

		auto sandbox = SandboxConfig(
			isolate_filesystem: SetInfo!bool(false),
			isolate_processes: SetInfo!bool(false),
			isolate_environment: SetInfo!bool(false),
		);
		app.config.sandbox = sandbox;
		app.config.agents["test"].sandbox = sandbox;
		app.config.agents["test"].sandbox.env["CODEX_HOME"] = profileRoot;
		app.config.workspaces = [WorkspaceConfig(name: "local", root: root, sandbox: sandbox)];
		app.discoveryService = new DiscoveryService(DiscoveryServiceHost.init);
		app.discoveryService.workspacesInfo = [
			WorkspaceInfo("local", [ProjectInfo("project", projectPath, false, true)])
		];
		app.taskSessionRunner = new TaskSessionRunner(TaskSessionRunnerHost(
			getTask: (int taskId) => taskId in app.tasks,
			currentConfig: () => &app.config,
			tryAgentForTask: &app.tryAgentForTask,
			taskTypeCatalog: app.taskTypeCatalog,
		));
		app.historyPipeline = new HistoryEventPipeline(HistoryEventPipelineHost(
			getTask: (int taskId) => taskId in app.tasks,
			resolveTaskHistory: &app.resolveTaskHistory,
			normalizeKnownSystemMessageMeta: (string event, int taskId) => event,
			historyOperations: (int taskId, Agent agent) => HistoryOperations.init,
			sendReplaySupplementalState: (WebSocketAdapter ws, int taskId) {},
			subscribe: (WebSocketAdapter ws, int taskId, Nullable!HistoryOperations) {},
			onHistorySubscribed: (int taskId) {},
			injectAgentNameIntoSessionInit: (string event, string agentName) => event,
			broadcastHistoryOperations: (int taskId) {},
			loadDriverHistory: (int taskId, HistoryAccess access) {
				assert(taskId == tid && access.sessionId == sessionId);
				assert(access.profile.root == profileRoot);
				driverReads++;
				return resolve(DriverHistory([TranslatedEvent(retainedEvent, null)], 0));
			},
		));

		auto record = ImportableScanRecord(
			NativeSessionKey(AgentDriver.codex, profileRoot, sessionId),
			DiscoveredSession(sessionId, 42, rolloutPath),
			"test", [ConfiguredNativeHistoryContext("test", "local", "", false)], 1);
		ImportableReconciliationCommit publish;
		app.withDiscoveryMutationTransaction(() {
			publish = app.reconcileImportableTasks(1,
				[ImportableTaskSpec(projectPath, "test", "Discovered Codex thread", 42, record)]);
		});
		publish();
		assert(app.importableScanRecords_.length == 1, "Reconciliation must publish the Codex offer");
		tid = app.importableScanRecords_.keys[0];
	}
}

unittest
{
	import std.conv : to;

	auto root = buildPath(tempDir(), "cydo-app-codex-offer-commands");
	scope(exit) if (exists(root)) rmdirRecurse(root);
	auto fixture = new CodexOfferFixture(root);
	scope(exit) fixture.base.socket.disconnect("test complete", DisconnectType.requested);
	auto app = fixture.app;
	auto task = fixture.tid in app.tasks;
	auto socket = fixture.base.socket;
	auto message = WsMessage(tid: fixture.tid, workspace: "local");
	foreach (command; ["create_task", "message", "resume", "interrupt", "unsend_message",
		"sigint", "close_stdin", "stop", "dismiss_attention", "fork_task", "undo_task",
		"edit_message", "edit_raw_event", "set_archived", "set_draft", "delete_task",
		"ask_user_response", "permission_prompt_response", "approve_retry", "refresh_workspaces",
		"set_task_type", "set_entry_point", "set_agent_name", "request_task_types"])
	{
		message.type = command;
		foreach (dryRun; command == "undo_task" ? [false, true] : [false])
		{
			message.dry_run = dryRun;
			auto before = socket.sent.length;
			app.handleWsMessage(socket, toJson(message));
			assert(socket.sent.length == before + 1, command);
			auto error = jsonParse!ErrorMessage(socket.sent[$ - 1]);
			assert(error.type == "error" && error.tid == fixture.tid
				&& error.message == "Import this session before using task commands", command);
		}
	}
	assert(task.status == TaskStatus.importable && fixture.driverReads == 0);

	app.handleWsMessage(socket, `{"type":"request_history","tid":`
		~ to!string(fixture.tid) ~ `,"workspace":"local"}`);
	drainSubmissionNextTicks();
	assert(fixture.driverReads == 1 && task.history.isLoaded);
	assert(socket.sent[$ - 1].canFind(`"type":"task_history_end"`));
	bool readRaw;
	app.lookupRawSource(fixture.tid, 0, (RawSourceLookupResult result) {
		assert(result.status == RawSourceLookupStatus.ok && result.raw is null);
		readRaw = true;
	});
	assert(readRaw && fixture.driverReads == 1);

	message.type = "promote_task";
	app.handleWsMessage(socket, toJson(message));
	assert(task.status == TaskStatus.completed && task.workspace == "local");
}

unittest
{
	auto root = buildPath(tempDir(), "cydo-app-codex-offer-history");
	scope(exit) if (exists(root)) rmdirRecurse(root);
	auto fixture = new CodexOfferFixture(root);
	scope(exit) fixture.base.socket.disconnect("test complete", DisconnectType.requested);
	auto resolution = fixture.app.resolveTaskHistory(fixture.tid);
	assert(resolution.kind == TaskHistoryResolutionKind.access);
	auto access = resolution.requireAccess();
	assert(access.isDriverServed, "A discovered Codex offer must resolve history through the driver");
	assert(access.sessionId == fixture.sessionId && access.profile.root == fixture.profileRoot);
	assert(fixture.app.tasks[fixture.tid].history.isDriverServed,
		"The offer's history store must match its driver-served access");
}

unittest
{
	import std.exception : assertThrown;

	auto root = buildPath(tempDir(), "cydo-app-codex-offer-selected-workspace");
	scope(exit) if (exists(root)) rmdirRecurse(root);
	auto fixture = new CodexOfferFixture(root);
	scope(exit) fixture.base.socket.disconnect("test complete", DisconnectType.requested);
	auto app = fixture.app;
	auto task = fixture.tid in app.tasks;
	auto other = app.config.workspaces[0];
	other.name = "other";
	other.sandbox.env = ["CODEX_HOME": buildPath(root, "other-profile")];
	app.config.workspaces = [other, app.config.workspaces[0]];
	auto projects = app.discoveryService.workspacesInfo[0].projects;
	app.discoveryService.workspacesInfo = [WorkspaceInfo("other", projects),
		app.discoveryService.workspacesInfo[0]];

	auto access = app.resolveImportPreview(*task, "local");
	assert(access.previewWorkspace.get == "local" && access.profile.root == fixture.profileRoot);
	assertThrown!Exception(app.resolveImportPreview(*task, "other"));
}

unittest
{
	auto root = buildPath(tempDir(), "cydo-app-codex-offer-raw-source");
	scope(exit) if (exists(root)) rmdirRecurse(root);
	auto fixture = new CodexOfferFixture(root);
	scope(exit) fixture.base.socket.disconnect("test complete", DisconnectType.requested);
	bool answered;
	fixture.app.lookupRawSource(fixture.tid, 0, (RawSourceLookupResult result) {
		assert(result.status == RawSourceLookupStatus.historyNotLoaded);
		answered = true;
	});
	assert(answered && fixture.driverReads == 0);
}

unittest
{
	auto root = buildPath(tempDir(), "cydo-app-codex-offer-promotion");
	scope(exit) if (exists(root)) rmdirRecurse(root);
	auto fixture = new CodexOfferFixture(root);
	scope(exit) fixture.base.socket.disconnect("test complete", DisconnectType.requested);
	auto app = fixture.app;
	auto td = fixture.tid in app.tasks;
	assert(!td.history.isLoaded && !td.history.isLoading);
	WsMessage message;
	message.tid = fixture.tid;
	message.workspace = "local";
	app.handlePromoteTaskMsg(fixture.base.socket, message);
	assert(td.status == TaskStatus.completed && td.workspace == "local");

	bool loaded;
	app.historyPipeline.whenHistoryLoaded(fixture.tid, () { loaded = true; });
	drainSubmissionNextTicks();
	assert(loaded && fixture.driverReads == 1 && td.history.length == 1
		&& (cast(string) td.history[0].unsafeContents).canFind("retained turn"),
		"The first load after promotion must deliver the driver transcript");
}

unittest
{
	import std.file : readText;

	auto root = buildPath(tempDir(), "cydo-app-codex-offer-edits");
	scope(exit) if (exists(root)) rmdirRecurse(root);
	auto fixture = new CodexOfferFixture(root);
	scope(exit) fixture.base.socket.disconnect("test complete", DisconnectType.requested);
	auto app = fixture.app;
	size_t editLoads;
	app.taskMutationService = new TaskMutationService(TaskMutationServiceHost(
		getTask: (int tid) => tid in app.tasks,
		taskAlive: &app.taskAlive,
		resolveTaskHistory: &app.resolveTaskHistory,
		ensureHistoryLoaded: (int tid) {
			editLoads++;
			app.tasks[tid].history.load((ulong) => LoadedHistory.init);
		},
	));
	auto socket = fixture.base.socket;
	WsMessage message;
	message.tid = fixture.tid;
	message.anchor = "message-id";
	message.seq = 0;
	app.handleEditMessage(socket, message);
	auto messageReply = socket.sent[$ - 1];
	app.handleEditRawEvent(socket, message);
	auto eventReply = socket.sent[$ - 1];
	assert(messageReply.canFind("Editing messages is not supported for this agent")
		&& eventReply.canFind("Editing events is not supported for this agent"),
		"Expected both Codex offer edits to be refused: " ~ messageReply ~ " / " ~ eventReply);
	assert(editLoads == 0 && readText(fixture.rolloutPath) == "{}\n");
}

unittest // Live-file lookup reads through the task's existing launch.
{
	import std.path : isAbsolute;
	import std.uuid : randomUUID;

	auto cli = environment.get("CYDO_TEST_CYDO_BIN", "");
	assert(isAbsolute(cli) && exists(cli),
		"CYDO_TEST_CYDO_BIN must name an existing absolute path. "
		~ "Run nix develop -ic dub build and set CYDO_TEST_CYDO_BIN=$PWD/build/cydo.");

	auto tmp = buildPath(tempDir(), "cydo-live-file-" ~ randomUUID().toString());
	mkdirRecurse(tmp);
	scope (exit) rmdirRecurse(tmp);
	auto missing = buildPath(tmp, "missing.md");
	auto binary = buildPath(tmp, "binary.bin");
	auto markdown = buildPath(tmp, "a note.md");
	auto png = buildPath(tmp, "image.png");
	enum markdownText = "# Héading\n";
	immutable(ubyte)[] pngBytes = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
	write(binary, [cast(ubyte) 0xFF]);
	write(markdown, markdownText);
	write(png, pngBytes);

	enum tid = 41;
	auto app = new App();
	app.tasks[tid] = TaskData(tid, "local", tmp);
	auto task = &app.tasks[tid];
	task.launch.nativeHistoryProfile.root = buildPath(tmp, "live-profile");
	// The runner supplies the test executable as $2. Forward the CLI arguments.
	task.launch.cmdPrefix = ["/bin/sh", "-c", `exec "$1" "$3" "$4" "$5"`, "cydo", cli];
	app.archiveManager = new ArchiveManager(ArchiveManagerHost(
		tryGetTask: (int id, out ArchiveTaskSnapshot snapshot) {
			assert(id == tid);
			snapshot.tid = id;
			snapshot.archiving = task.archiving;
			return true;
		},
	));
	app.taskSessionRunner = new TaskSessionRunner(TaskSessionRunnerHost(
		getTask: (int id) {
			assert(id == tid);
			return task;
		},
		agentForTask: delegate Agent(int id) {
			assert(0, "A live-file read must reuse the existing launch");
		},
	));

	LiveFileLookupResult lookup(string path)
	{
		Nullable!LiveFileLookupResult result;
		app.lookupLiveFile(tid, path, (LiveFileLookupResult value) { result = value; });
		socketManager.loop();
		assert(!result.isNull, "Live-file lookup did not settle for " ~ path);
		return result.get;
	}

	auto missingResult = lookup(missing);
	assert(missingResult.status == LiveFileLookupStatus.unavailable);
	assert(missingResult.reason.canFind(missing)
		&& missingResult.reason.canFind("No such file or directory"), missingResult.reason);

	auto binaryResult = lookup(binary);
	assert(binaryResult.status == LiveFileLookupStatus.unavailable);
	assert(binaryResult.reason == binary ~ " is neither a PNG/JPEG/GIF/WebP image nor UTF-8 text",
		binaryResult.reason);

	auto markdownResult = lookup(markdown);
	assert(markdownResult.status == LiveFileLookupStatus.ok, markdownResult.reason);
	assert(markdownResult.mediaType == "text/plain; charset=utf-8");
	assert(markdownResult.bytes == cast(immutable(ubyte)[]) markdownText);

	auto pngResult = lookup(png);
	assert(pngResult.status == LiveFileLookupStatus.ok, pngResult.reason);
	assert(pngResult.mediaType == "image/png");
	assert(pngResult.bytes == pngBytes);
}

unittest // An archived task refuses live-file reads before building a launch or loading history.
{
	enum tid = 42;
	auto app = new App();
	app.tasks[tid] = TaskData(tid, "local", "/tmp/cydo-archived-live-file");
	auto task = &app.tasks[tid];
	task.archived = true;
	task.history.reset(Watermark.driverServed());
	app.historyPipeline = new HistoryEventPipeline(HistoryEventPipelineHost(
		getTask: (int id) => id in app.tasks,
		resolveTaskHistory: delegate TaskHistoryResolution(int id) {
			assert(0, "An archived live-file read must not resolve cold history");
		},
	));
	app.taskSessionRunner = new TaskSessionRunner(TaskSessionRunnerHost(
		getTask: (int id) => id in app.tasks,
		agentForTask: delegate Agent(int id) {
			assert(0, "An archived live-file read must not build a launch");
		},
	));

	Nullable!LiveFileLookupResult result;
	app.lookupLiveFile(tid, "/tmp/file.md", (LiveFileLookupResult value) { result = value; });

	assert(!result.isNull);
	assert(result.get.status == LiveFileLookupStatus.unavailable);
	assert(result.get.reason == "The task is archived");
	assert(!task.history.isLoaded && !task.history.isLoading);
}
