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

import cydo.mcp : McpResult;
import cydo.mcp.tool_descriptions : RenderedCydoToolsOptions,
	ToolDescriptionViolation, checkRenderedCydoToolDescriptionViolations,
	mcpToolDescriptionMaxChars;
import cydo.mcp.tools;
import cydo.workflow.workspace.archive_manager : ArchiveManager, ArchiveManagerHost, ArchiveTaskSnapshot;
import cydo.workflow.workspace.task_path_resolver : TaskPathResolver, TaskPathResolverHost;
import cydo.workflow.workspace.worktree_allocator : WorktreeAllocator, WorktreeAllocatorHost;
import cydo.web.client_hub : ClientHub;
import cydo.runtime.config.watcher : ConfigWatcher, ConfigWatcherHost;
import cydo.workflow.discovery.service : DiscoveryService, DiscoveryServiceHost,
	DiscoveryTaskSnapshot, ImportableReconciliationCommit, ImportableScanRecord,
	ImportableTaskSpec;
import cydo.web.snapshots : buildAgentsList, buildNoticesList,
	buildServerStatus, buildTaskEntry, buildTasksList, buildTaskTypesList,
	buildTaskTypesListForProject, buildWorkspacesList;
import cydo.workflow.history.pipeline : HistoryBroadcastPlan, HistoryEventPipeline,
	HistoryEventPipelineHost;
import cydo.workflow.history.native_history : ConfiguredNativeHistoryContext,
	HistoryAccess, LiveHistoryWatchResolution, LiveHistoryWatchResolutionKind,
	LiveHistoryWatchTarget, ResolvedNativeHistoryContext,
	TaskHistoryResolution, TaskHistoryResolutionKind, UnavailableHistory,
	UnavailableHistoryKind, resolveNativeHistoryContext;
import cydo.workflow.history.abbrev : extractMessageText;
import cydo.workflow.history.operations : CodexForkSourceState,
	selectHistoryOperations;
import cydo.runtime.logging : installRobustLogger;
import cydo.workflow.system_message_normalizer : SystemMessageNormalizer,
	SystemMessageNormalizerHost;
import cydo.workflow.tasks.derived_text : DerivedTextJobs, DerivedTextJobsHost;
import cydo.workflow.tasks.mutations : TaskMutationService, TaskMutationServiceHost;
import cydo.workflow.tools.backend : WorkflowToolsBackend, WorkflowToolsHost;
import cydo.domain.task_types.catalog : TaskTypeCatalog;
import cydo.workflow.sessions.task_runner : TaskSessionLaunch, TaskSessionRunner,
	TaskSessionRunnerHost;
import cydo.web.transport : McpCallbacks, RawSourceLookupResult, RawSourceLookupStatus,
	TransportAdapter, WebSocketCallbacks;
import cydo.domain.usage.tracker : AgentUsageTracker;

import cydo.agent.resolver : createConfiguredAgent, displayNameForDriver,
	effectiveDefaultAgentName, isConfiguredAgentName, tryCreateConfiguredAgent;
import cydo.agent.contract : Agent;
import cydo.protocol : AgentAckEnvelope, BatchResultEnvelope, ContentBlock,
	HistoryBoundary, ItemStartedEvent, SessionRateLimitEvent, TaskDiagnosticEvent, TaskDiagnosticSeverity,
	TaskEventEnvelope, TaskEventSeqEnvelope, TranslatedEvent,
	UnconfirmedUserEventEnvelope, UserMessageConsumedEvent, extractContentText;
import cydo.agent.session : AgentSession, AgentSubmissionReceipt;
import cydo.agent.drivers.codex : CodexSession;
import cydo.runtime.config : AgentConfig, AgentDriver, CydoConfig, PathMode, SandboxConfig, WorkspaceConfig;
import cydo.domain.storage.persistence : LoadedHistory, Persistence, openDatabase;
import cydo.server.config_resolution : loadRuntimeConfig, reloadRuntimeConfig;
import cydo.runtime.launch.sandbox : cleanup, resolveExecutablePath, runtimeDir, sharedTmpBaseDir;
import cydo.runtime.launch.types : NativeHistoryProfile, NativeHistoryRule;
import cydo.domain.task_types.definition : DjinjaTemplate, TaskTypeDef, OutputType, WorktreeMode, byName, loadTaskTypes,
	loadTaskTypeSystemPrompt, renderPrompt, substituteVars,
	loadProjectMemory, resolveAgent;
import cydo.foundation.system.framing : prependTaskFraming, validateTemplateSource;
import cydo.foundation.system.known_messages : KnownSystemMessageKind,
	sessionStartSubject, systemMessagePrefix, wrapKnownSystemMessage;
import cydo.foundation.platform.path : bestEffortProjectPathIdentity, canonicalProjectPath;
import cydo.domain.tasks.model;
import cydo.domain.tasks.lifecycle : TaskLifecycle, TaskNotificationChange,
	isLegalTaskStatusTransition;
import cydo.foundation.text.title : truncateTitle;
import cydo.workflow.history.jsonl_store : findNextUserUuid,
	HistoryForkDestination;
import cydo.workflow.workspace.worktree;

private enum maxToolDescriptionNoticeViolations = 3;

private string mcpToolDescriptionLimitNoticeId(string projectPath, string taskType)
{
	auto encodedPath = appender!string();
	foreach (immutable ubyte b; cast(const(ubyte)[]) projectPath)
		encodedPath.put(format!"%02x"(b));
	return "mcp-tool-description-limit:" ~ encodedPath.data ~ ":" ~ taskType;
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
	import cydo.workflow.history.jsonl_tracker : JsonlTracker;

	private TransportAdapter transport;
	private ClientHub clientHub = new ClientHub();
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
	// JSONL file tracking state
	private JsonlTracker jsonlTracker;
	// HTTP basic auth credentials (from environment)
	private string authUser;
	private string authPass;
	// Active notices keyed by notice ID
	private Notice[string] activeNotices;
	private AgentUsageTracker agentUsageTracker = new AgentUsageTracker();
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
			webDistDir = buildPath(baseDir, "web/dist/");
			taskTypeCatalog = new TaskTypeCatalog(taskTypesDir, taskTypesPath,
				(string name) => isConfiguredAgentName(config, name));
		}
		{
			persistence = openDatabase();
			taskLifecycle = TaskLifecycle(
				getTask: (int tid) => tid in tasks ? &tasks[tid] : null,
				persistStatus: (int tid, string status) => persistence.setStatus(tid, status),
				persistNeedsAttention: (int tid, bool needsAttention) =>
					persistence.setNeedsAttention(tid, needsAttention),
				publishSnapshot: &broadcastTaskUpdate,
			);
			import cydo.runtime.launch.sandbox : runtimeDir;
			createPidFile("cydo.pid", runtimeDir());
		}
		config = loadRuntimeConfig();
		persistence.normalizeProjectPaths(&bestEffortProjectPathIdentity);
		taskDirTemplate = config.task_dir.length > 0 ? config.task_dir : defaultTaskDirTemplate;
		applyConfiguredLogLevel(config.log_level);
		taskPathResolver = new TaskPathResolver(TaskPathResolverHost(
			getTask: (int tid) => tid in tasks ? &tasks[tid] : null,
			workspaces: () => config.workspaces,
			taskDirTemplate: () => taskDirTemplate,
		));
		foreach (name, ref ac; config.agents)
			agentsByName[name] = createConfiguredAppAgent(name);
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
				onDeliveryFailed: (string callerTid) {
					workflowTools.onMcpDeliveryFailed(callerTid);
				},
				onDelivered: (string callerTid) {
					workflowTools.onToolCallDelivered(callerTid);
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
			addIdleCallback: (int tid, void delegate() cb) {
				auto td = tid in tasks;
				assert(td !is null,
					format!"WorkflowTools idle callback requested for missing task %d"(tid));
				td.onIdleCallbacks ~= cb;
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
			canSendSystemMessage: &canSendSystemMessage,
			sendKnownSystemMessage: &sendKnownSystemMessage,
			persistAddTaskDep: (int parentTid, int childTid) {
				persistence.addTaskDep(parentTid, childTid);
			},
			persistRemoveTaskDep: (int parentTid, int childTid) {
				persistence.removeTaskDep(parentTid, childTid);
			},
			persistRemoveAllChildDeps: (int childTid) {
				persistence.removeAllChildDeps(childTid);
			},
			loadTaskDeps: () => persistence.loadTaskDeps(),
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
			sendPermissionPrompt: (int tid, string toolUseId, string toolName,
				JSONFragment input) {
				clientHub.sendToSubscribed(tid, Data(toJson(
					PermissionPromptMessage("permission_prompt", tid,
						toolUseId, toolName, input)).representation));
			},
			clearPermissionPrompt: (int tid) {
				clientHub.sendToSubscribed(tid, Data(toJson(
					PermissionPromptMessage("permission_prompt", tid,
						"", "", JSONFragment("{}"))).representation));
			},
			appendTaskSpawnedEvent: (int parentTid, int childTid, int specIndex) {
				import cydo.protocol : CydoTaskSpawnedEvent, TranslatedEvent;
				import ae.utils.time.types : AbsTime;
				import std.datetime : Clock;

				CydoTaskSpawnedEvent spawnEv;
				spawnEv.child_tid = childTid;
				spawnEv.spec_index = specIndex;
				historyPipeline.appendAndBroadcastTaskEvent(parentTid,
					TranslatedEvent(toJson(spawnEv), null,
						AbsTime(Clock.currStdTime)));
			},
			broadcastTaskCreated: (TaskCreatedMessage message) {
				clientHub.broadcast(toJson(message));
			},
			workspacePermissionPolicy: &findWorkspacePermissionPolicy,
			onNextTick: (void delegate() cb) {
				onNextTick(socketManager, cb);
			},
			generateTitle: (int tid, string prompt) {
				derivedTextJobs.generateTitle(tid, prompt);
			},
		));
		historyPipeline = new HistoryEventPipeline(HistoryEventPipelineHost(
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
			subscribe: (WebSocketAdapter ws, int tid) {
				clientHub.subscribe(ws, tid);
			},
			sendHistoryOperations: (WebSocketAdapter ws, int tid) {
				import cydo.domain.tasks.model : HistoryOperationsMessage;
				ws.send(Data(toJson(HistoryOperationsMessage("history_operations", tid,
					historyOperationsForTask(tid))).representation));
			},
			broadcastHistoryOperations: (int tid) {
				import cydo.domain.tasks.model : HistoryOperationsMessage;
				auto message = HistoryOperationsMessage("history_operations", tid,
					historyOperationsForTask(tid));
				clientHub.sendToSubscribed(tid, Data(toJson(message).representation));
			},
			noteLiveBoundaryCandidate: (int tid, size_t seq, string event, string raw, int sourceLine,
				bool isContextBootstrap) {
				jsonlTracker.noteLiveBoundaryCandidate(tid, seq, event, raw, sourceLine,
					isContextBootstrap);
			},
			sendReplaySupplementalState: &sendHistoryReplaySupplementalState,
			onHistorySubscribed: &onHistorySubscribed,
			updateClaudeUsageFromEvent: &updateClaudeUsageFromEvent,
			planBroadcast: &planHistoryBroadcast,
		));
		derivedTextJobs = new DerivedTextJobs(DerivedTextJobsHost(
			getTask: (int tid) => tid in tasks ? &tasks[tid] : null,
			snapshotTaskIds: &snapshotTaskIdsForResume,
			agentForTask: &agentForTask,
			hasSubscribers: (int tid) => clientHub.hasSubscribers(tid),
			ensureHistoryLoaded: (int tid) {
				historyPipeline.ensureHistoryLoaded(tid);
			},
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
			getTask: (int tid) => tid in tasks ? &tasks[tid] : null,
			taskDir: &taskPathResolver.taskDir,
			outputPath: &taskPathResolver.outputPath,
			effectiveCwd: &taskPathResolver.effectiveCwd,
			worktreePath: &taskPathResolver.worktreePath,
			currentConfig: () => &config,
			findWorkspacePermissionPolicy: &findWorkspacePermissionPolicy,
			reportMcpToolDescriptionLimit: &reportMcpToolDescriptionLimit,
			resolveSharedTmpPath: &resolveSharedTmpPath,
			mcpSocketPath: () => transport.mcpSocketPath,
			agentForTask: &agentForTask,
			tryAgentForTask: &tryAgentForTask,
			setAgentSessionId: (int tid, string agentSessionId) {
				persistence.setAgentSessionId(tid, agentSessionId);
			},
			clearLastActive: (int tid) {
				persistence.clearLastActive(tid);
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
			drainIdleCallbacksForTurnResult: &drainIdleCallbacksForTurnResult,
			drainIdleCallbacksOnExit: &drainIdleCallbacksOnExit,
			hasPendingSubTask: &workflowTools.hasPendingSubTask,
			hasTaskDependency: &workflowTools.hasTaskDependency,
			hasPendingChildQuestion: &workflowTools.hasPendingChildQuestion,
			sendPendingChildAnswerReminder: &workflowTools.sendPendingChildAnswerReminder,
			checkDeclaredOutputs: &checkDeclaredOutputs,
			finalizeCompletedSubTask: &workflowTools.finalizeCompletedSubTask,
			deliverFailedPendingSubTaskResult: &workflowTools.deliverFailedPendingSubTaskResult,
			parentTaskForChild: &workflowTools.parentTaskForChild,
			deliverWaitingParentResultsIfReady: &workflowTools.deliverWaitingParentResultsIfReady,
			deliverBatchResults: &workflowTools.deliverBatchResults,
			failPendingAskUserQuestionOnExit: &workflowTools.failPendingAskUserQuestionOnExit,
			failPendingPermissionPromptOnExit: &workflowTools.failPendingPermissionPromptOnExit,
			failPendingAskRouteOnExit: &workflowTools.failPendingAskRouteOnExit,
			cancelExitBackgroundWork: &cancelExitBackgroundWork,
			resetHistoryWatermarkOnly: &resetHistoryWatermarkOnly,
			resetHistoryWatermarkAfterExit: &resetHistoryWatermarkAfterExit,
			unsubscribeTaskHistorySubscribers: (int tid) {
				clientHub.unsubscribeAll(tid);
			},
			touchAndPersistLastActive: &touchAndPersistLastActive,
			findAliveAncestor: &findAliveAncestor,
			broadcastFocusHint: &broadcastFocusHint,
			transitionTask: &transitionTask,
			transitionTaskFrom: &transitionTask,
			persistResultText: (int tid, string resultText) {
				persistence.setResultText(tid, resultText);
			},
			requestMissingOutputs: &requestMissingOutputs,
			spawnContinuation: &workflowTools.spawnContinuation,
			spawnOnYieldContinuation: &workflowTools.spawnOnYieldContinuation,
			emitTaskReload: (int tid) {
				emitTaskReload(tid);
			},
			startJsonlWatch: (int tid) {
				jsonlTracker.startJsonlWatch(tid);
			},
			ensureHistoryLoadedForExit: (int tid) => historyPipeline.ensureHistoryLoadedForExit(tid),
			finalReconcileJsonlIfPresent: (int tid, Nullable!TaskHistoryResolution resolution) {
				jsonlTracker.finalReconcileJsonlIfPresent(tid, resolution);
			},
			stopJsonlWatch: (int tid) {
				jsonlTracker.stopJsonlWatch(tid);
			},
			broadcastHistoryOperations: (int tid) {
				import cydo.domain.tasks.model : HistoryOperationsMessage;
				auto message = HistoryOperationsMessage("history_operations", tid,
					historyOperationsForTask(tid));
				clientHub.sendToSubscribed(tid, Data(toJson(message).representation));
			},
			sendSystemRestartNudge: &workflowTools.sendSystemRestartNudge,
			loadPersistedTaskDeps: &workflowTools.loadPersistedTaskDeps,
			snapshotTaskIds: &snapshotTaskIdsForResume,
			waitingTaskDependencyState: &workflowTools.waitingTaskDependencyState,
			shuttingDown: () => shuttingDown,
			taskTypeCatalog: taskTypeCatalog,
		));
		taskMutationService = new TaskMutationService(TaskMutationServiceHost(
			getTask: (int tid) => tid in tasks ? &tasks[tid] : null,
			putTask: (int tid, TaskData td) {
				tasks[tid] = move(td);
			},
			removeTask: (int tid) {
				tasks.remove(tid);
			},
			agentForTask: &agentForTask,
			sessionForTask: &sessionForTask,
			taskAlive: &taskAlive,
			stopTask: (int tid) {
				taskSessionRunner.stopTask(tid);
			},
			prepareTaskSessionLaunch: &prepareTaskSessionLaunch,
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
			deleteTask: (int tid) {
				persistence.deleteTask(tid);
			},
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
			resolveTaskHistory: &resolveTaskHistory,
			reportUnavailableHistory: &reportUnavailableHistory,
			requireLiveHistoryLaunch: (int tid, const ref HistoryAccess access) {
				return taskSessionRunner.requireLiveHistoryLaunch(tid, access);
			},
			openCodexForkSourceOperation: (int tid,
				const ref HistoryAccess access) {
				return taskSessionRunner.openCodexForkSourceOperation(tid, access);
			},
			codexForkSourceState: &codexForkSourceState,
			resolveFreshPersistedBoundary: (int tid, const ref HistoryAccess access,
				string requestedAnchor, out HistoryBoundary boundary) {
				return historyPipeline.resolveFreshPersistedBoundary(tid, access,
					requestedAnchor, boundary);
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
		jsonlTracker.onLineageInvalidated = (int tid) {
			auto td = tid in tasks;
			assert(td !is null, "history lineage invalidated for missing task");
			td.clearSubmissionCorrelationState();
			jsonlTracker.invalidateLineage(tid);
			auto resolution = resolveTaskHistory(tid);
			if (resolution.kind == TaskHistoryResolutionKind.access)
				td.history.reset(watermarkFromPath(resolution.requireAccess().path));
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
		jsonlTracker.onJsonlLine = &onTailedJsonlLine;
		jsonlTracker.onJsonlFileAttached = (int tid,
			LiveHistoryWatchTarget watchedTarget) {
			auto td = tid in tasks;
			if (td is null || td.agentSessionId != watchedTarget.context.sessionId)
				return;
			auto resolution = resolveLiveHistoryWatch(tid);
			if (resolution.kind != LiveHistoryWatchResolutionKind.target)
				return;
			auto currentTarget = resolution.requireTarget();
			if (!currentTarget.matchesExactly(watchedTarget))
				return;
			auto codex = cast(CodexSession) sessionForTask(tid);
			if (codex is null)
				return;
			codex.bindPendingRolloutIdentity(watchedTarget.context.sessionId,
				watchedTarget.path);
		};

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
			td.agentName = row.agentName;
			td.parentTid = row.parentTid;
			td.relationType = row.relationType;
			td.worktreeTid = row.worktreeTid;
			td.taskStartHead = row.taskStartHead;
			td.title = row.title;
			td.status = parseTaskStatus(row.status);
			td.archived = row.archived;
			td.draft = row.draft;
			td.resultText = row.resultText;
			td.createdAt = row.createdAt;
			td.lastActive = row.lastActive;
			td.needsAttention = row.needsAttention;
			td.titleGenDone = row.title.length > 0;
			auto rowTid = row.tid;
			tasks[rowTid] = move(td);
			if (tasks[rowTid].status == TaskStatus.importable)
			{
				persistence.deleteTask(rowTid);
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
						wm = watermarkFromPath(resolution.requireAccess().path);
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

		resumeInFlightTasks();

		// Recover last_active from .jsonl mtime for tasks that were alive
		// when the backend crashed (last_active was cleared on session start).
		foreach (ref td; tasks)
		{
			if (td.lastActive == 0 && td.agentSessionId.length > 0)
			{
				try
				{
					auto resolution = resolveTaskHistory(td.tid);
					if (resolution.kind == TaskHistoryResolutionKind.access)
					{
						auto jp = resolution.requireAccess().path;
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

		discoveryService.enumerateSessions();

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
		ws.send(Data(buildCurrentTasksList().representation));
		ws.send(Data(buildServerStatus(
			authUser.length > 0 || authPass.length > 0,
			config.dev_mode,
			webDistDir,
			config.history_window.desktop,
			config.history_window.mobile,
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
		taskSessionRunner.interruptTask(parsedTid);
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
			auto impl = new CydoToolsImpl(workflowTools, tid);
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

		switch (json.type)
		{
			case "create_task":       handleCreateTaskMsg(ws, json); break;
			case "request_history":   handleRequestHistory(ws, json); break;
			case "request_history_before": handleRequestHistoryBefore(ws, json); break;
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
			case "ask_user_response": workflowTools.handleAskUserResponse(json); break;
			case "permission_prompt_response": workflowTools.handlePermissionPromptResponse(json); break;
			case "refresh_workspaces": handleRefreshWorkspacesMsg(); break;
			case "promote_task":     handlePromoteTaskMsg(ws, json); break;
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
		broadcastTaskUpdate(tid);
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
				ws.send(Data(toJson(ErrorMessage("error",
					"Project path must be an existing directory")).representation));
				return;
			}
		}
		// Top-level user task creation must always come through a concrete entry point.
		// Internal tasks (subtasks, continuations, imports) are created through other paths.
		auto entryPoints = taskTypeCatalog.getEntryPointsForProject(projectPath);
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
		auto tid = createTask(json.workspace, projectPath, at, json.entry_point);
		// Call getTaskTypesForProject() after getEntryPointsForProject() so the cache is populated.
		auto taskTypes = taskTypeCatalog.getTaskTypesForProject(projectPath);
		tasks[tid].entryPoint = json.entry_point;
		persistence.setEntryPoint(tid, json.entry_point);
		tasks[tid].taskType = ep.resolvedType;
		if (taskTypes.byName(ep.resolvedType) !is null)
			persistence.setTaskType(tid, ep.resolvedType);
		// Send task_created only to the requesting client (unicast) so that
		// parallel test workers don't steal each other's task IDs.
		ws.send(Data(toJson(TaskCreatedMessage("task_created", tid, json.workspace, projectPath, 0, "", json.correlation_id)).representation));
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
			tasks[tid].processQueue.setGoal(ProcessState.Alive).then(() {
				return sendTaskMessage(tid, messageToSend, msgContent, msgMeta,
					null, true, &commitAcceptedInitialSubmission);
			}).except((Exception e) {
				auto failed = tid in tasks;
				assert(failed !is null,
					"Initial message submission task disappeared");
				// TaskSessionRunner already owns a failed launch and its diagnostic.
				if (failed.status == TaskStatus.failed)
					return;
				assert(failed.status == TaskStatus.active,
					"Initial message submission failed outside an active task");
				failed.error = e.msg;
				failed.resultText = e.msg;
				persistence.setResultText(tid, failed.resultText);
				transitionTask(tid, TaskStatus.active, TaskStatus.failed,
					TaskNotificationChange.preserve);
				auto translated = historyPipeline.appendTaskDiagnostic(tid,
					"Failed to submit initial message", e.msg);
				broadcastAppendedTaskEvent(tid, translated);
				workflowTools.deliverFailedPendingSubTaskResult(tid);
				broadcastTaskUpdate(tid);
			}).ignoreResult();
		}
	}

	private void handleRequestHistory(WebSocketAdapter ws, WsMessage json)
	{
		historyPipeline.handleRequestHistory(ws, json.tid,
			resolveHistoryLimit(json.limit, json.device_class));
	}

	private void handleRequestHistoryBefore(WebSocketAdapter ws, WsMessage json)
	{
		historyPipeline.handleRequestHistoryBefore(ws, json.tid, json.before_seq,
			resolveHistoryLimit(json.limit, json.device_class));
	}

	/// Turn a client's request into an actual window size.
	///
	/// The server owns the numbers because it is the only side that always
	/// knows them: a client that has not yet processed server_status would
	/// otherwise ask for everything, which on a long task means replaying tens
	/// of thousands of events.
	private int resolveHistoryLimit(int requested, string deviceClass)
	{
		if (requested != 0)
			return requested < 0 ? 0 : requested; // negative asks for it all
		auto window = deviceClass == "mobile"
			? config.history_window.mobile
			: config.history_window.desktop;
		return window > 0 ? window : 0;
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

		// Queue-operation records reach us via the JSONL tail
		// (onTailedJsonlLine), not the agent's stdout; any that appear in a
		// translated event stream (pre-2.1.2xx CLIs) are simply consumed.
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
			}
			UserMsgTagProbe probe;
			try
				probe = jsonParse!UserMsgTagProbe(plan.currentEvent.translated);
			catch (Exception)
				return plan;
			if (probe.type == "item/started"
				&& probe.item_type == "user_message"
				&& !probe.is_replay && !probe.is_meta && !probe.pending)
			{
				if (probe.correlation_id.length > 0)
				{
					bool found;
					size_t foundIndex;
					foreach (index, ref acceptedEcho; td.acceptedNativeEchoes)
					{
						if (acceptedEcho.receipt != AgentSubmissionReceipt.appServerAccepted
							|| acceptedEcho.generation != td.history.generation
							|| acceptedEcho.nonce != probe.correlation_id)
							continue;
						assert(!found,
							"Agent user echo correlation matches multiple accepted submissions");
						found = true;
						foundIndex = index;
					}
					assert(found,
						"Agent user echo correlation does not match an accepted submission");
					td.acceptedNativeEchoes = td.acceptedNativeEchoes[0 .. foundIndex]
						~ td.acceptedNativeEchoes[foundIndex + 1 .. $];
				}
				else if (td.acceptedNativeEchoes.length > 0
					&& td.acceptedNativeEchoes[0].receipt == AgentSubmissionReceipt.localEnqueued)
				{
					auto acceptedEcho = td.acceptedNativeEchoes[0];
					assert(acceptedEcho.generation == td.history.generation,
						"Local agent echo belongs to a stale history lineage");
					td.acceptedNativeEchoes = td.acceptedNativeEchoes[1 .. $];
					if (acceptedEcho.nonce.length > 0)
						plan.currentEvent.translated = plan.currentEvent.translated[0 .. $ - 1]
							~ `,"correlation_id":` ~ toJson(acceptedEcho.nonce) ~ `}`;
				}
			}
		}

		return plan;
	}

	/// Refusal text for a task whose Codex native undo forbids delivery, or
	/// null when delivery is allowed. Callers report it in their own idiom:
	/// the entry guard sends it to task subscribers, while the delivery funnel
	/// rejects the submission promise.
	private string nativeUndoDeliveryRefusal(TaskData* td)
	{
		if (!td.codexNativeUndoBlocksDelivery)
			return null;
		final switch (td.codexNativeUndoState)
		{
			case CodexNativeUndoState.idle:
				assert(false, "idle native undo state cannot block delivery");
			case CodexNativeUndoState.inFlight:
				return "Native Codex undo is in progress and this message was not sent";
			case CodexNativeUndoState.unverified:
				return "Codex may already have changed or lost history; sends are blocked only in this running CyDo process and this message was not sent";
		}
	}

	private void handleUserMessage(WsMessage json)
	{
		auto tid = json.tid;
		if (tid < 0 || tid !in tasks)
			return;
		auto td = &tasks[tid];
		// Refuse at the entry point so a blocked send performs no task
		// materialization, nonce leasing, or process start on the way to the
		// delivery funnel's fail-closed backstop. The blockage is a property of
		// the task, not of one requester, so every subscribed client hears it.
		if (auto refusal = nativeUndoDeliveryRefusal(td))
		{
			clientHub.sendToSubscribed(tid,
				Data(toJson(ErrorMessage("error", refusal, tid)).representation));
			return;
		}
		if (isArchiveTransitioning(tid))
			return;
		assert(td.taskType.length > 0, "Task must have a task_type when receiving a message");

		// Deduplicate accepted delivery and unresolved outbox replay independently.
		if (json.correlation_id.length > 0 && json.correlation_id in td.recentNonces)
			return;

		ContentBlock[] blocks;
		if (json.content.json !is null)
			blocks = jsonParse!(ContentBlock[])(json.content.json);
		auto textContent = extractContentText(blocks);

		// Wrap first message in prompt template (e.g. conversation.md)
		auto messageToSend = blocks;
		string userMsgMeta;
		auto initializesDescription = td.description.length == 0;
		auto initializesTitle = td.title.length == 0;
		auto draftAtSubmission = td.draft;
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
		auto msgNonce = json.correlation_id;
		auto submissionGeneration = td.history.generation;
		if (msgNonce.length > 0)
		{
			if (auto leasedGeneration = msgNonce in td.inFlightUiNonceGeneration)
				if (*leasedGeneration == submissionGeneration)
					return;
			td.inFlightUiNonceGeneration[msgNonce] = submissionGeneration;
		}
		void commitAcceptedBrowserSubmission(TaskData* accepted)
		{
			if (initializesDescription && accepted.description.length == 0)
			{
				accepted.description = textContent;
				persistence.setDescription(tid, textContent);
			}
			if (accepted.status != TaskStatus.active)
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
				accepted.draft = "";
				persistence.setDraft(tid, "");
				auto draftData = Data(toJson(DraftUpdatedMessage("draft_updated", tid, "")).representation);
				clientHub.sendToSubscribed(tid, draftData);
			}
		}
		td.processQueue.setGoal(ProcessState.Alive).then(() {
			auto queued = tid in tasks;
			assert(queued !is null,
				"User message submission task disappeared before dispatch");
			if (queued.history.generation != submissionGeneration)
			{
				if (msgNonce.length > 0)
					if (auto leasedGeneration = msgNonce in queued.inFlightUiNonceGeneration)
						if (*leasedGeneration == submissionGeneration)
							queued.inFlightUiNonceGeneration.remove(msgNonce);
				return resolve();
			}
			return sendTaskMessage(tid, messageToSend, blocks, userMsgMeta, msgNonce,
				userMsgMeta.length > 0, &commitAcceptedBrowserSubmission);
		}).except((Exception e) {
			auto rejected = tid in tasks;
			assert(rejected !is null,
				"User message submission task disappeared");
			if (rejected.history.generation != submissionGeneration)
				return;
			if (msgNonce.length > 0)
				if (auto leasedGeneration = msgNonce in rejected.inFlightUiNonceGeneration)
					if (*leasedGeneration == submissionGeneration)
						rejected.inFlightUiNonceGeneration.remove(msgNonce);
			if (rejected.status == TaskStatus.failed)
				return;
			auto translated = historyPipeline.appendTaskDiagnostic(tid,
				"Failed to submit message", e.msg);
			broadcastAppendedTaskEvent(tid, translated);
			broadcastTaskUpdate(tid);
		}).ignoreResult();
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

				return workflowTools.deliverBatchFallbackIfReady(tid);
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
			taskSessionRunner.stopTask(tid);
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
		// Broadcast to every other client (not the sender): draft text is task metadata,
		// not history-subscription-only state.
		auto data = Data(toJson(DraftUpdatedMessage("draft_updated", tid, draft)).representation);
		clientHub.broadcastExcept(senderWs, data);
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
		// Remove from in-memory state
		tasks.remove(tid);
		// Remove from database
		persistence.deleteTask(tid);
		// Broadcast deletion to all clients
		clientHub.broadcast(toJson(TaskDeletedMessage("task_deleted", tid)));
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
		void delegate(TaskData*) acceptedSubmissionMutation = null)
	{
		return sendPreparedTaskMessage(tid, content, broadcastContent, cydoMeta, true, nonce,
			isContextBootstrap, acceptedSubmissionMutation);
	}

	/// Send a prepared message to the agent and emit the matching pending UI echo.
	///
	/// System messages are ordinary prepared messages with a stable wrapper format
	/// and CyDo metadata for collapsed rendering.
	private Promise!void sendPreparedTaskMessage(int tid, const(ContentBlock)[] content,
		const(ContentBlock)[] broadcastContent = null, string cydoMeta = null,
		bool captureUndoSnapshot = true, string nonce = null,
		bool isContextBootstrap = false,
		void delegate(TaskData*) acceptedSubmissionMutation = null)
	{
		import std.algorithm : min, filter;
		import std.array : array;

		auto td = tid in tasks;
		assert(td !is null, "Task must exist when sending a message");
		assert(td.taskType.length > 0, "Task must have a task_type when sending a message");
		// Fail-closed backstop for internal and already-scheduled sends: a
		// refused submission was never accepted, so it must reject.
		if (auto refusal = nativeUndoDeliveryRefusal(td))
			return reject!void(new Exception(refusal));

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
		Promise!AgentSubmissionReceipt submission;
		try
			submission = session.sendMessage(toSend, nonce, isContextBootstrap);
		catch (Exception e)
			return reject!void(e);

		return submission.then((AgentSubmissionReceipt receipt) {
			auto accepted = tid in tasks;
			assert(accepted !is null,
				"Task disappeared while committing accepted message submission");
			if (accepted.history.generation != submissionGeneration)
				throw new Exception("Message submission invalidated by history lineage reset");
			assert(sessionForTask(tid) is session,
				"Task session changed while committing accepted message submission");

			final switch (receipt)
			{
			case AgentSubmissionReceipt.localEnqueued:
				accepted.acceptedNativeEchoes ~= AcceptedNativeEcho(receipt,
					nonce is null ? "" : nonce, submissionGeneration);
				break;
			case AgentSubmissionReceipt.appServerAccepted:
				if (nonce.length > 0)
					accepted.acceptedNativeEchoes ~= AcceptedNativeEcho(receipt, nonce,
						submissionGeneration);
				break;
			}

			if (acceptedSubmissionMutation !is null)
				acceptedSubmissionMutation(accepted);
			historyPipeline.appendUnconfirmedUserMessage(tid, content,
				broadcastContent, cydoMeta, nonce);
			if (nonce.length > 0)
			{
				accepted.recentNonces[nonce] = true;
				if (auto leasedGeneration = nonce in accepted.inFlightUiNonceGeneration)
					if (*leasedGeneration == submissionGeneration)
						accepted.inFlightUiNonceGeneration.remove(nonce);
			}
			if (receipt == AgentSubmissionReceipt.localEnqueued)
				accepted.sentNonceFifo ~= nonce is null ? "" : nonce;
			accepted.isProcessing = true;
			touchTask(tid);
			accepted.needsAttention = false;
			persistence.setNeedsAttention(tid, false);
			accepted.notificationBody = "";
			derivedTextJobs.clearSuggestions(tid);
			derivedTextJobs.discardInFlightSuggestions(tid);
			broadcastTaskUpdate(tid);
			if (receipt == AgentSubmissionReceipt.appServerAccepted)
				sendAgentAck(tid, nonce);
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
		return loadTaskTypeSystemPrompt(*typeDef, taskTypes, td.taskType,
			taskTypeCatalog.promptSearchPath(td.projectPath), taskPathResolver.outputPath(*td));
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
		import std.algorithm : startsWith;

		auto translated = toJson(ev);
		return text.startsWith("[" ~ config.system_keyword ~ ":")
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
			enforce(exists(access.path) && isFile(access.path),
				"Validated importable history locator disappeared before reconciliation");
			auto td = TaskData(tid, "", spec.projectPath);
			td.status = TaskStatus.importable;
			td.agentName = spec.agentName;
			td.agentSessionId = spec.scanRecord.key.sessionId;
			td.title = spec.title;
			td.createdAt = Clock.currStdTime;
			td.lastActive = spec.lastActive;
			td.history.reset(watermarkFromPath(access.path));
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
				tasks.remove(tid);
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
		string body;
		if (unavailable.kind == UnavailableHistoryKind.profilePath)
		{
			body = "No history for session " ~ unavailable.sessionId ~ " under "
				~ unavailable.profile.root ~ " (agent '" ~ unavailable.agentName
				~ "').\n\nCheck " ~ unavailable.rule.profileEnvName
				~ " and the configured profile location, then reload the task.";
		}
		else
			body = unavailable.detail;
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
				ca.toolDispatch_ = (string tool, string callerTid, JSONFragment args) =>
					dispatchTool(tool, callerTid, args);
		}
		return a;
	}

	private Agent createConfiguredAppAgent(string agentName)
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

	private void sendAgentAck(int tid, string nonce)
	{
		if (nonce.length == 0)
			return;
		auto ackEnv = AgentAckEnvelope(tid, nonce);
		clientHub.sendToSubscribed(tid, Data(toJson(ackEnv).representation));
	}

	/// Consume a complete JSONL line delivered by the live tail. Claude
	/// ≥2.1.2xx records queue operations only in the session file, so this is
	/// where the live queue lifecycle of user messages is observed: an enqueue
	/// links the record to the oldest unmatched send nonce, a dequeue moves the
	/// entry to the awaiting-echo stage, and the echo user line yields the
	/// user_message/consumed confirmation carrying the CLI's own steering
	/// classification. A remove yields the "removed" confirmation — the
	/// message was withdrawn without ever being consumed.
	private void onTailedJsonlLine(int tid, string line, int lineNum)
	{
		import std.algorithm : startsWith;

		auto td = tid in tasks;
		if (td is null)
			return;

		if (isQueueOperation(line))
		{
			QueueOperationProbe op;
			try
				op = jsonParse!QueueOperationProbe(line);
			catch (Exception e)
			{
				tracef("tail: queue op parse error: %s", e.msg);
				return;
			}
			if (op.operation == "enqueue")
			{
				if (op.content.startsWith(systemMessagePrefix(
					config.system_keyword,
					KnownSystemMessageKind.postCompactionTaskModeReminder)))
					td.compactionReminderInFlight = true;
				string nonce;
				if (td.sentNonceFifo.length > 0)
				{
					nonce = td.sentNonceFifo[0];
					td.sentNonceFifo = td.sentNonceFifo[1 .. $];
				}
				td.queueTailQueuedUuids ~= format!"enqueue-%d"(lineNum);
				td.queueTailQueuedNonces ~= nonce;
			}
			else if (op.operation == "dequeue")
			{
				if (td.queueTailQueuedUuids.length > 0)
				{
					td.queueTailAwaitingUuids ~= td.queueTailQueuedUuids[0];
					td.queueTailAwaitingNonces ~= td.queueTailQueuedNonces[0];
					td.queueTailQueuedUuids = td.queueTailQueuedUuids[1 .. $];
					td.queueTailQueuedNonces = td.queueTailQueuedNonces[1 .. $];
				}
			}
			else if (op.operation == "remove")
			{
				if (td.queueTailQueuedUuids.length > 0)
				{
					emitUserMessageConsumed(tid, td.queueTailQueuedUuids[0],
						"removed", td.queueTailQueuedNonces[0]);
					td.queueTailQueuedUuids = td.queueTailQueuedUuids[1 .. $];
					td.queueTailQueuedNonces = td.queueTailQueuedNonces[1 .. $];
				}
			}
			return;
		}

		if (td.queueTailAwaitingUuids.length == 0)
			return;
		auto ta = tryAgentForTask(tid);
		if (ta is null)
			return;

		if (ta.isUserMessageLine(line))
		{
			auto ts = ta.translateHistoryLine(line, lineNum);
			if (ts.length == 0)
				return;
			@JSONPartial static struct TypeProbe { string type; }
			if (jsonParse!TypeProbe(ts[0].translated).type != "item/started")
				return; // tool_result etc. — keep awaiting the echo
			auto ev = jsonParse!ItemStartedEvent(ts[0].translated);
			// Prefer the echo's native uuid — it matches the bubble the live
			// stdout echo created; the enqueue anchor is the fallback.
			auto uuid = ev.uuid.length > 0 ? ev.uuid : td.queueTailAwaitingUuids[0];
			emitUserMessageConsumed(tid, uuid,
				ev.is_steering ? "steering" : "turn_start",
				td.queueTailAwaitingNonces[0], uuid);
		}
		else if (ta.isAssistantMessageLine(line))
		{
			// No echo before assistant output: the output proves consumption;
			// turn openers always echo first, so classify as steering.
			emitUserMessageConsumed(tid, td.queueTailAwaitingUuids[0],
				"steering", td.queueTailAwaitingNonces[0]);
		}
		else
			return;
		td.queueTailAwaitingUuids = td.queueTailAwaitingUuids[1 .. $];
		td.queueTailAwaitingNonces = td.queueTailAwaitingNonces[1 .. $];
	}

	/// Append a user_message/consumed confirmation to task history and
	/// broadcast it to subscribed clients.
	private void emitUserMessageConsumed(int tid, string uuid, string consumedAs,
		string nonce, string nativeUuid = null)
	{
		import std.datetime : Clock;

		auto td = tid in tasks;
		if (td is null)
			return;
		auto ev = UserMessageConsumedEvent(uuid: uuid, consumed_as: consumedAs);
		if (nonce.length > 0)
			ev.correlation_id = nonce;
		if (nativeUuid.length > 0)
			ev.native_uuid = nativeUuid;
		auto translated = toJson(ev);
		tracef("queue-tail: consumed tid=%d uuid=%s as=%s nonce=%s", tid, uuid,
			consumedAs, nonce);
		td.history.appendLive(Data(toJson(TaskEventEnvelope(tid, Clock.currStdTime,
			JSONFragment(translated))).representation), null);
		broadcastAppendedTaskEvent(tid, translated);
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
		td.needsAttention = true;
		persistence.setNeedsAttention(tid, true);
		td.notificationBody = td.resultText.length > 0
			? truncateTitle(td.resultText, 200)
			: extractLastAssistantText(tid);
		touchAndPersistLastActive(tid);
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

	private void cancelExitBackgroundWork(int tid)
	{
		derivedTextJobs.cancelBackgroundWork(tid);
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
		jsonlTracker.invalidateLineage(tid);
		tasks[tid].clearSubmissionCorrelationState();
		bool reloadEmitted;
		{
			Watermark wm;
			auto resolution = resolveTaskHistory(tid);
			if (resolution.kind == TaskHistoryResolutionKind.access)
			{
				wm = watermarkFromPath(resolution.requireAccess().path);
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
		return reloadEmitted;
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
			auto outputsMeta = systemMessageNormalizer.buildKnownSystemMessageMeta(
				KnownSystemMessageKind.missingRequiredOutputs);
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
			auto translated = historyPipeline.appendTaskDiagnostic(tid,
				"Failed to request missing outputs", e.msg);
			broadcastAppendedTaskEvent(tid, translated);
			workflowTools.deliverFailedPendingSubTaskResult(tid);
			broadcastTaskUpdate(tid);
		}).ignoreResult();
	}

	private bool canSendSystemMessage(int tid, out string sessionState)
	{
		auto session = sessionForTask(tid);
		if (session is null)
		{
			sessionState = "is null";
			return false;
		}
		if (!session.alive)
		{
			sessionState = "not alive";
			return false;
		}

		sessionState = "";
		return true;
	}

	private Promise!void sendKnownSystemMessage(int tid, KnownSystemMessageKind kind,
		string body)
	{
		auto td = tid in tasks;
		assert(td !is null, "Known system message task must exist");
		auto msg = wrapKnownSystemMessage(config.system_keyword, kind, body);
		auto meta = systemMessageNormalizer.buildKnownSystemMessageMeta(kind);
		return sendTaskMessage(tid, [ContentBlock("text", msg)], null, meta)
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

	private string findWorkspacePermissionPolicy(string workspaceName)
	{
		foreach (ref ws; config.workspaces)
			if (ws.name == workspaceName && ws.permission_policy.length > 0)
				return ws.permission_policy;
		return "";
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
		taskSessionRunner.resumeInFlightTasks();
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

	private bool updateClaudeUsageFromEvent(int tid, string translated)
	{
		if (tid !in tasks)
			return false;
		auto agent = tryAgentForTask(tid);
		if (!agent)
			return false;

		string payload;
		auto changed = agentUsageTracker.updateFromClaudeEvent(
			agent.driver, translated, payload);
		if (changed)
			clientHub.broadcast(payload);
		return changed;
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
		try
			// Teach the persistent agent instance the scanned locator, so
			// post-import history resolution finds the session even when it
			// appeared after the agent's profile scan.
			taskAgent.registerHistoryPath((*record).key.sessionId,
				(*record).discovered.exactHistoryPath, selectedContext.profile);
		catch (Exception e)
		{
			rejectPromotion(e.msg);
			return;
		}
		persistence.promoteImportableTask(tid, json.workspace);
		enforce(persistence.db.db.changes == 1,
			"Importable task promotion must update exactly one task row");
		td.workspace = json.workspace;
		td.status = TaskStatus.completed;
		importableScanRecords_.remove(tid);
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
				rebuilt[name] = createConfiguredAppAgent(name);
		}
		agentsByName = rebuilt;
		auto defaultName = defaultAgentName("");
		agent = agentsByName[defaultName];

		taskTypeCatalog.invalidateAll();
		discoveryService.beginScan();
		discoveryService.discoverAllWorkspaces(config);
		clientHub.broadcast(buildAgentsList(snapshotAgentEntries(), config.default_agent));
		clientHub.broadcast(buildWorkspacesList(discoveryService.workspacesInfo));
		broadcastTaskTypeLists();
		clientHub.broadcast(buildServerStatus(
			authUser.length > 0 || authPass.length > 0,
			config.dev_mode,
			webDistDir,
			config.history_window.desktop,
			config.history_window.mobile,
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
			workspaceNameForProjectPath(projectPath),
			defaultAgentName(workspaceNameForProjectPath(projectPath)),
			configuredAgentNames(),
		));
	}

	private void onUserTaskTypesChanged()
	{
		infof("User task types file changed, reloading task types...");
		taskTypeCatalog.invalidateAll();
		broadcastTaskTypeLists();
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
		taskTypeCatalog.invalidateAll();
		discoveryService.discoverAllWorkspaces(config);
		clientHub.broadcast(buildWorkspacesList(discoveryService.workspacesInfo));
		broadcastTaskTypeLists();
		discoveryService.enumerateSessions();
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
			{
				auto prompt = substituteVars(readText(path), vars);
				return prompt.strip.length == 0 ? "" : prompt;
			}
		}
		throw new Exception("Prompt file not found: " ~ relativePath);
	}

	/// Read a prompt template file from the search path without variable substitution.
	private string loadTemplateText(string templateName, string projectPath)
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

	private void touchTask(int tid)
	{
		import std.datetime : Clock;
		tasks[tid].lastActive = Clock.currStdTime;
	}

	private AgentSession sessionForTask(int tid)
	{
		return taskSessionRunner.sessionForTask(tid);
	}

	private CodexForkSourceState codexForkSourceState(int tid)
	{
		auto codex = cast(CodexSession) sessionForTask(tid);
		if (codex !is null)
			return codex.canRollbackThread
				? CodexForkSourceState.liveReady
				: CodexForkSourceState.liveBusy;
		if (taskSessionRunner.forkSourceOperationInProgress(tid))
			return CodexForkSourceState.liveBusy;
		return CodexForkSourceState.dead;
	}

	private auto historyOperationsForTask(int tid)
	{
		return selectHistoryOperations(agentForTask(tid).driver,
			codexForkSourceState(tid));
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

	private string buildCurrentTasksList()
	{
		TaskListEntry[] entries;
		foreach (tid, ref td; tasks)
			entries ~= buildTaskEntry(td, taskAlive(tid), taskCanStop(tid), driverForTask(tid));
		return buildTasksList(entries);
	}

	private void broadcastTaskUpdate(int tid)
	{
		import ae.utils.json : toJson;

		clientHub.broadcast(toJson(TaskUpdatedMessage("task_updated",
			buildTaskEntry(tasks[tid], taskAlive(tid), taskCanStop(tid), driverForTask(tid)))));
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
			if (target.parentTid == 0 || taskAlive(targetTid))
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
			configWatcher.ensureProjectWatch(projectPath);
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
				a = createConfiguredAppAgent(name);

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
	app.handleUserMessage(WsMessage(type: "message", tid: tid));
	app.tasks[tid].isProcessing = true;
	app.handleUserMessage(WsMessage(type: "message", tid: tid));
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

	app.tasks[tid].markCodexNativeUndoUnverified();
	app.handleUserMessage(WsMessage(type: "message", tid: tid));
	assert(ws.sent.length == 3
		&& ws.sent[$ - 1].canFind("may already have changed or lost history")
		&& ws.sent[$ - 1].canFind("blocked only in this running CyDo process"));
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

version (unittest)
{
	import configy.attributes : SetInfo;
	import core.exception : AssertError;
	import core.time : Duration;
	import std.algorithm : canFind, countUntil;
	import std.exception : assertThrown;
	import std.file : exists, mkdirRecurse, remove, rmdirRecurse, tempDir, write;
	import std.path : buildPath;
	import std.process : environment, execute;
	import ae.net.asockets : ConnectionState, IConnection;
	import ae.sys.dataset : joinData;
	import ae.utils.array : as;

	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import cydo.agent.drivers.codex : CodexAgent;
	import cydo.agent.drivers.copilot : CopilotAgent;
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
	ContentBlock[][] contents;
	size_t sendCalls;
	private void delegate(TranslatedEvent) outputHandler_;
	private void delegate(string) nativeSessionStartedHandler_;
	private string nativeSessionId_;

	Promise!AgentSubmissionReceipt sendMessage(const(ContentBlock)[] content,
		string correlationId = null, bool isContextBootstrap = false)
	{
		sendCalls++;
		correlations ~= correlationId;
		contents ~= content.dup;
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

	TranslatedEvent nativeUserEcho(string text, string correlationId = null)
	{
		ItemStartedEvent event;
		event.item_id = "gated-user";
		event.item_type = "user_message";
		event.content = [ContentBlock("text", text)];
		event.correlation_id = correlationId;
		return TranslatedEvent(toJson(event), null);
	}

	void emitNativeUserEcho(string text, string correlationId = null)
	{
		auto event = nativeUserEcho(text, correlationId);
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
	@property bool supportsImages() const { return false; }
	void interrupt() {}
	void sigint() {}
	void stop() {}
	void closeStdin() {}
	void killAfterTimeout(Duration timeout) {}
	@property bool canStopAfterCloseStdin() const { return true; }
	@property void onNativeSessionStarted(void delegate(string) dg)
	{
		nativeSessionStartedHandler_ = dg;
		if (nativeSessionId_.length > 0 && dg !is null)
			dg(nativeSessionId_);
	}
	@property void onOutput(void delegate(TranslatedEvent) dg) { outputHandler_ = dg; }
	@property void onStderr(void delegate(string line) dg) {}
	@property void onExit(void delegate(int status) dg) {}
	@property bool alive() { return true; }
}

version (unittest) private final class GatedSubmissionRunner : TaskSessionRunner
{
	private AgentSession session_;
	private bool deferSessionUntilAlive_;
	private bool[int] launched_;
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
		auto payload = cast(string) data.joinData().toGC().as!string;
		sent ~= payload;
		if (onSend_)
			onSend_(payload);
	}
}

version (unittest) private final class GatedSubmissionFixture
{
	App app;
	GatedSubmissionSession session;
	SubmissionCaptureWebSocket socket;
	string[] submissionMessages;
	int[] submissionTids;
	string[] publicationOrder;
	size_t titlePromptReads;
	int[] titlePromptTids;
	int tid;

	this(string dbPath)
	{
		app = new App();
		app.persistence = Persistence(dbPath);
		tid = app.persistence.createTask();
		app.tasks[tid] = TaskData(tid, "local", "/tmp/cydo-app-submission");
		app.tasks[tid].taskType = "test";
		app.tasks[tid].description = "existing description";
		app.tasks[tid].title = "existing title";
		app.tasks[tid].status = TaskStatus.active;
		app.tasks[tid].history.reset(Watermark.none());
		app.taskTypeCatalog = new TaskTypeCatalog("", "", (string name) => true);
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
		));
		app.derivedTextJobs = new DerivedTextJobs(DerivedTextJobsHost(
			getTask: (int lookupTid) {
				auto task = lookupTid in app.tasks;
				return task is null ? null : task;
			},
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
	app.tasks[tid].taskType = "test";
	app.tasks[tid].status = TaskStatus.active;
	app.tasks[tid].history.reset(Watermark.none());
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
	assert(app.tasks[tid].acceptedNativeEchoes.length == 0);
	assert(app.tasks[tid].sentNonceFifo.length == 0);
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
	assert(app.tasks[tid].acceptedNativeEchoes.length == 0);

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
	assert(app.tasks[tid].acceptedNativeEchoes.length == 0);
}

unittest
{
	auto dbPath = buildPath(tempDir(), "cydo-app-submission-browser-nonce.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);

	auto fixture = new GatedSubmissionFixture(dbPath);
	auto message = testBrowserSubmission(fixture.tid, "browser submission",
		"browser-nonce");
	fixture.app.handleUserMessage(message);
	fixture.app.handleUserMessage(message);

	assert(("browser-nonce" in fixture.app.tasks[fixture.tid]
		.inFlightUiNonceGeneration) !is null);
	drainSubmissionNextTicks();
	assert(fixture.session.sendCalls == 1 && fixture.session.gates.length == 1);

	fixture.session.reject(0, "submission rejected");
	drainSubmissionNextTicks();
	assert(("browser-nonce" in fixture.app.tasks[fixture.tid]
		.inFlightUiNonceGeneration) is null);
	assert(("browser-nonce" in fixture.app.tasks[fixture.tid].recentNonces)
		is null);

	fixture.app.handleUserMessage(message);
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
	auto td = &fixture.app.tasks[fixture.tid];
	td.status = TaskStatus.waiting;
	td.description = "";
	td.title = "";
	td.draft = "saved retry draft";
	fixture.app.persistence.setDraft(fixture.tid, td.draft);
	td.lastSuggestions = ["pending suggestion"];
	auto suggestionHandle = new Promise!string;
	td.suggestGenHandle = suggestionHandle;
	td.suggestGeneration = 41;
	string readPersistedDraft()
	{
		foreach (row; fixture.app.persistence.loadTasks())
			if (row.tid == fixture.tid)
				return row.draft;
		assert(false, "Expected persisted browser task row");
	}
	auto message = testBrowserSubmission(fixture.tid, "first browser message",
		"first-browser-nonce");
	fixture.app.handleUserMessage(message);
	drainSubmissionNextTicks();

	assert(fixture.session.sendCalls == 1);
	assert(td.status == TaskStatus.waiting);
	assert(td.description.length == 0 && td.title.length == 0
		&& td.draft == "saved retry draft");
	assert(td.history.length == 0 && !td.isProcessing);
	assert(("first-browser-nonce" in td.recentNonces) is null);
	assert(td.acceptedNativeEchoes.length == 0 && td.sentNonceFifo.length == 0
		&& td.pendingSteeringTexts.length == 0);
	assert(fixture.submissionMessages.length == 0 && fixture.socket.sent.length == 0
		&& fixture.titlePromptReads == 0);
	assert(td.lastSuggestions == ["pending suggestion"]
		&& td.suggestGenHandle is suggestionHandle && td.suggestGeneration == 41);
	assert(readPersistedDraft() == "saved retry draft");

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
	assert(fixture.titlePromptReads == 0);
	assert(td.lastSuggestions == ["pending suggestion"]
		&& td.suggestGenHandle is suggestionHandle && td.suggestGeneration == 41);
	assert(readPersistedDraft() == "saved retry draft");
	assert(fixture.socket.sent.length == 2);
	assert(fixture.socket.sent[0].canFind(`"type":"cydo/task_diagnostic"`)
		&& fixture.socket.sent[0].canFind(`"subject":"Failed to submit message"`)
		&& fixture.socket.sent[0].canFind(`"body":"first submission rejected"`));
	assert(fixture.socket.sent[1].canFind(`"type":"task_updated"`));
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
	fixture.app.handleUserMessage(message);
	drainSubmissionNextTicks();
	assert(fixture.session.sendCalls == 2);
	assert(toJson(fixture.session.contents[0]) == toJson(fixture.session.contents[1]));
	assert(td.status == TaskStatus.waiting && td.description.length == 0
		&& td.title.length == 0 && td.draft == "saved retry draft");
	assert(readPersistedDraft() == "saved retry draft");

	fixture.session.accept(1, AgentSubmissionReceipt.appServerAccepted);
	drainSubmissionNextTicks();
	assert(td.status == TaskStatus.active);
	assert(td.description == "first browser message");
	assert(td.title == truncateTitle("first browser message", 80));
	assert(td.draft.length == 0 && td.history.length == 2 && td.isProcessing);
	assert(("first-browser-nonce" in td.recentNonces) !is null);
	assert(td.acceptedNativeEchoes.length == 1
		&& td.acceptedNativeEchoes[0].nonce == "first-browser-nonce");
	assert(fixture.titlePromptReads == 1);
	assert(td.lastSuggestions.length == 0 && td.suggestGenHandle is null
		&& td.suggestGeneration == 42);
	assert(readPersistedDraft().length == 0);
	assert(fixture.publicationOrder == ["title_update", "draft_updated",
		"unconfirmed", "task_update", "agent_ack"]);
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
	write(buildPath(defs, "prompts", "start.md"), "{{task_description}}\n");
	write(buildPath(defs, "task-types.yaml"),
		"user_entry_points:\n"
		~ "  isolated:\n"
		~ "    task_type: direct_test\n"
		~ "    description: Isolated\n"
		~ "    prompt_template: prompts/start.md\n"
		~ "    worktree: require\n"
		~ "task_types:\n"
		~ "  direct_test:\n"
		~ "    model_class: large\n");

	auto dbPath = buildPath(tempDir(), "cydo-app-create-submission-acceptance.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);
	auto fixture = new GatedSubmissionFixture(dbPath);
	fixture.app.config.system_keyword = "SYSTEM";
	fixture.app.config.workspaces = [WorkspaceConfig(name: "create", root: root)];
	fixture.app.taskDirTemplate = "{{ workspace_root }}/tasks/{{ tid }}";
	fixture.app.taskTypeCatalog = new TaskTypeCatalog(defs,
		buildPath(defs, "task-types.yaml"), (string name) => name == "claude");
	fixture.app.agentsByName["claude"] = new TestClaudePromptAgent;
	fixture.app.taskPathResolver = new TaskPathResolver(TaskPathResolverHost(
		getTask: (int lookupTid) {
			auto task = lookupTid in fixture.app.tasks;
			return task is null ? null : task;
		},
		workspaces: () => fixture.app.config.workspaces,
		taskDirTemplate: () => fixture.app.taskDirTemplate,
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
	bool launchSawAssignedWorktree;
	runner.onLaunch = (int launchTid) {
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

	WsMessage createMessage(string content)
	{
		WsMessage message;
		message.type = "create_task";
		message.workspace = "create";
		message.project_path = projectPath;
		message.agent_name = "claude";
		message.entry_point = "isolated";
		message.content = JSONFragment(toJson([ContentBlock("text", content)]));
		return message;
	}

	fixture.publicationOrder = null;
	fixture.submissionMessages = null;
	fixture.submissionTids = null;
	fixture.socket.sent = null;
	fixture.app.handleCreateTaskMsg(fixture.socket,
		createMessage("rejected direct first message"));
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
	assert(launchSawAssignedWorktree && fixture.session.sendCalls == 1);
	assert(rejected.status == TaskStatus.active && rejected.history.length == 0
		&& rejected.acceptedNativeEchoes.length == 0 && rejected.sentNonceFifo.length == 0
		&& rejected.queueTailQueuedUuids.length == 0 && rejected.queueTailQueuedNonces.length == 0
		&& rejected.queueTailAwaitingUuids.length == 0 && rejected.queueTailAwaitingNonces.length == 0
		&& rejected.pendingSteeringTexts.length == 0 && rejected.recentNonces.length == 0
		&& !rejected.isProcessing && rejected.lastSuggestions.length == 0
		&& fixture.titlePromptReads == 0 && fixture.socket.sent.length == 0
		&& fixture.submissionMessages.length == 0 && fixture.publicationOrder.length == 0);

	fixture.session.reject(0, "initial direct submission rejected");
	drainSubmissionNextTicks();
	auto afterRejectedReceipt = rowFor(rejectedTid);
	assert(rejected.status == TaskStatus.failed && rejected.history.length == 1
		&& rejected.description.length == 0 && rejected.title.length == 0
		&& afterRejectedReceipt.description.length == 0
		&& afterRejectedReceipt.title.length == 0
		&& rejected.worktreeTid == rejectedTid
		&& exists(fixture.app.taskPathResolver.worktreePath(rejected)));

	fixture.publicationOrder = null;
	fixture.submissionMessages = null;
	fixture.submissionTids = null;
	fixture.socket.sent = null;
	fixture.app.handleCreateTaskMsg(fixture.socket,
		createMessage("accepted direct first message"));
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
	assert(fixture.session.sendCalls == 2 && accepted.status == TaskStatus.active);
	assert(accepted.history.length == 0 && accepted.acceptedNativeEchoes.length == 0
		&& accepted.recentNonces.length == 0 && accepted.sentNonceFifo.length == 0
		&& accepted.queueTailQueuedUuids.length == 0 && accepted.queueTailQueuedNonces.length == 0
		&& accepted.queueTailAwaitingUuids.length == 0 && accepted.queueTailAwaitingNonces.length == 0
		&& accepted.pendingSteeringTexts.length == 0 && !accepted.isProcessing
		&& accepted.lastSuggestions.length == 0 && fixture.titlePromptReads == 0
		&& fixture.socket.sent.length == 0 && fixture.submissionMessages.length == 0
		&& fixture.publicationOrder.length == 0);
	fixture.session.accept(1, AgentSubmissionReceipt.appServerAccepted);
	drainSubmissionNextTicks();
	auto afterAcceptedReceipt = rowFor(acceptedTid);
	assert(accepted.description == "accepted direct first message"
		&& accepted.title == truncateTitle("accepted direct first message", 80)
		&& afterAcceptedReceipt.description == accepted.description
		&& afterAcceptedReceipt.title == accepted.title);
	assert(accepted.history.length == 1 && accepted.acceptedNativeEchoes.length == 0
		&& accepted.sentNonceFifo.length == 0 && accepted.pendingSteeringTexts.length == 1);
	assert(fixture.titlePromptReads == 1 && fixture.titlePromptTids == [acceptedTid]);
	assert(fixture.submissionTids == [acceptedTid]);
	assert(fixture.publicationOrder == ["title_update", "unconfirmed", "task_update"]);
	foreach (payload; fixture.socket.sent)
		assert(!payload.canFind(`"agentAck"`));

	auto browserTid = fixture.app.createTask("create", projectPath, "claude", "isolated");
	fixture.app.tasks[browserTid].taskType = "direct_test";
	fixture.app.persistence.setTaskType(browserTid, "direct_test");
	fixture.app.tasks[browserTid].draft = "browser worktree retry draft";
	fixture.app.persistence.setDraft(browserTid, "browser worktree retry draft");
	fixture.app.clientHub.subscribe(fixture.socket, browserTid);
	auto browserMessage = testBrowserSubmission(browserTid,
		"browser worktree retry message", "browser-worktree-nonce");
	fixture.app.handleUserMessage(browserMessage);
	drainSubmissionNextTicks();
	auto browser = &fixture.app.tasks[browserTid];
	auto browserWorktreePath = fixture.app.taskPathResolver.worktreePath(browser);
	auto beforeBrowserReceipt = rowFor(browserTid);
	assert(fixture.session.sendCalls == 3 && browser.status == TaskStatus.active
		&& browser.worktreeTid == browserTid && exists(browserWorktreePath));
	assert(browser.description.length == 0 && browser.title.length == 0
		&& browser.draft == "browser worktree retry draft"
		&& browser.history.length == 0 && !browser.isProcessing
		&& beforeBrowserReceipt.description.length == 0
		&& beforeBrowserReceipt.title.length == 0
		&& beforeBrowserReceipt.draft == "browser worktree retry draft");

	fixture.session.reject(2, "browser worktree submission rejected");
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

	fixture.app.handleUserMessage(browserMessage);
	drainSubmissionNextTicks();
	assert(fixture.session.sendCalls == 4
		&& fixture.session.correlations[2] == fixture.session.correlations[3]
		&& toJson(fixture.session.contents[2]) == toJson(fixture.session.contents[3])
		&& browser.worktreeTid == browserTid
		&& fixture.app.taskPathResolver.worktreePath(browser) == browserWorktreePath);
}

unittest
{
	auto dbPath = buildPath(tempDir(), "cydo-app-rejected-newer.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);

	auto fixture = new GatedSubmissionFixture(dbPath);
	auto td = &fixture.app.tasks[fixture.tid];

	foreach (index, nonce; ["queue-one-nonce", "queue-two-nonce",
		"queue-three-nonce"])
	{
		fixture.app.sendTaskMessage(fixture.tid,
			[ContentBlock("text", "accepted queue message " ~ nonce)], null, null,
			nonce).ignoreResult();
		fixture.session.accept(index, AgentSubmissionReceipt.localEnqueued);
		drainSubmissionNextTicks();
	}
	assert(td.sentNonceFifo == ["queue-one-nonce", "queue-two-nonce",
		"queue-three-nonce"]);
	assert(td.acceptedNativeEchoes.length == 3 && td.pendingSteeringTexts == [
		"accepted queue message queue-one-nonce",
		"accepted queue message queue-two-nonce",
		"accepted queue message queue-three-nonce",
	]);

	fixture.app.onTailedJsonlLine(fixture.tid,
		`{"type":"queue-operation","operation":"enqueue","content":"queue one"}`, 101);
	fixture.app.onTailedJsonlLine(fixture.tid,
		`{"type":"queue-operation","operation":"enqueue","content":"queue two"}`, 102);
	fixture.app.onTailedJsonlLine(fixture.tid,
		`{"type":"queue-operation","operation":"dequeue"}`, 103);
	assert(td.sentNonceFifo.length > 0 && td.queueTailQueuedUuids.length > 0
		&& td.queueTailQueuedNonces.length > 0
		&& td.queueTailAwaitingUuids.length > 0
		&& td.queueTailAwaitingNonces.length > 0);

	auto sentNonceFifo = td.sentNonceFifo.dup;
	auto queuedUuids = td.queueTailQueuedUuids.dup;
	auto queuedNonces = td.queueTailQueuedNonces.dup;
	auto awaitingUuids = td.queueTailAwaitingUuids.dup;
	auto awaitingNonces = td.queueTailAwaitingNonces.dup;
	auto pendingSteeringTexts = td.pendingSteeringTexts.dup;
	auto acceptedEchoes = td.acceptedNativeEchoes.dup;
	auto historyGeneration = td.history.generation;
	string[] historyPrefix;
	foreach (index; 0 .. td.history.length)
		historyPrefix ~= cast(string) td.history.opIndex(index).toGC().as!string;

	fixture.app.handleUserMessage(testBrowserSubmission(fixture.tid,
		"rejected newer message", "rejected-newer-nonce"));
	fixture.app.handleUserMessage(testBrowserSubmission(fixture.tid,
		"unrelated pending message", "unrelated-nonce"));
	drainSubmissionNextTicks();
	assert(fixture.session.sendCalls == 5);
	assert(("rejected-newer-nonce" in td.inFlightUiNonceGeneration) !is null
		&& ("unrelated-nonce" in td.inFlightUiNonceGeneration) !is null);

	fixture.session.reject(3, "newer submission rejected");
	drainSubmissionNextTicks();
	assert(td.sentNonceFifo == sentNonceFifo);
	assert(td.queueTailQueuedUuids == queuedUuids
		&& td.queueTailQueuedNonces == queuedNonces
		&& td.queueTailAwaitingUuids == awaitingUuids
		&& td.queueTailAwaitingNonces == awaitingNonces);
	assert(td.pendingSteeringTexts == pendingSteeringTexts);
	assert(td.acceptedNativeEchoes == acceptedEchoes);
	assert(td.history.generation == historyGeneration
		&& td.history.length == historyPrefix.length + 1);
	foreach (index; 0 .. historyPrefix.length)
		assert(cast(string) td.history.opIndex(index).toGC().as!string == historyPrefix[index]);
	assert(td.history.lastEventContents().canFind(`"subject":"Failed to submit message"`)
		&& td.history.lastEventContents().canFind(`"body":"newer submission rejected"`));
	assert(("rejected-newer-nonce" in td.inFlightUiNonceGeneration) is null);
	assert(("rejected-newer-nonce" in td.recentNonces) is null);
	assert(("unrelated-nonce" in td.inFlightUiNonceGeneration) !is null);

	fixture.app.handleUserMessage(testBrowserSubmission(fixture.tid,
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
	assert(fixture.app.tasks[fixture.tid].acceptedNativeEchoes.length == 3);
	assert(fixture.app.tasks[fixture.tid].sentNonceFifo == [
		"first-local-nonce", "", "second-local-nonce"]);
	foreach (payload; fixture.socket.sent)
		assert(!payload.canFind(`"agentAck"`));

	auto first = fixture.app.planHistoryBroadcast(fixture.tid,
		fixture.session.nativeUserEcho("first local prompt"));
	assert(testUserCorrelation(first.currentEvent) == "first-local-nonce");
	auto system = fixture.app.planHistoryBroadcast(fixture.tid,
		fixture.session.nativeUserEcho("[SYSTEM: internal reminder]"));
	assert(testUserCorrelation(system.currentEvent).length == 0);
	auto second = fixture.app.planHistoryBroadcast(fixture.tid,
		fixture.session.nativeUserEcho("second local prompt"));
	assert(testUserCorrelation(second.currentEvent) == "second-local-nonce");
	assert(fixture.app.tasks[fixture.tid].acceptedNativeEchoes.length == 0);
}

unittest
{
	auto dbPath = buildPath(tempDir(), "cydo-app-server-receipt-echoes.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);

	auto fixture = new GatedSubmissionFixture(dbPath);
	fixture.app.sendTaskMessage(fixture.tid,
		[ContentBlock("text", "first app-server prompt")], null, null,
		"first-app-server-nonce").ignoreResult();
	fixture.app.sendTaskMessage(fixture.tid,
		[ContentBlock("text", "second app-server prompt")], null, null,
		"second-app-server-nonce").ignoreResult();
	assert(fixture.session.sendCalls == 2);

	fixture.session.accept(0, AgentSubmissionReceipt.appServerAccepted);
	drainSubmissionNextTicks();
	fixture.session.accept(1, AgentSubmissionReceipt.appServerAccepted);
	drainSubmissionNextTicks();
	assert(fixture.app.tasks[fixture.tid].acceptedNativeEchoes.length == 2);
	assertThrown!AssertError(fixture.app.planHistoryBroadcast(fixture.tid,
		fixture.session.nativeUserEcho("unknown app-server prompt", "unknown-nonce")));
	assert(fixture.app.tasks[fixture.tid].acceptedNativeEchoes.length == 2);

	auto second = fixture.app.planHistoryBroadcast(fixture.tid,
		fixture.session.nativeUserEcho("second app-server prompt",
			"second-app-server-nonce"));
	assert(testUserCorrelation(second.currentEvent) == "second-app-server-nonce");
	auto first = fixture.app.planHistoryBroadcast(fixture.tid,
		fixture.session.nativeUserEcho("first app-server prompt",
			"first-app-server-nonce"));
	assert(testUserCorrelation(first.currentEvent) == "first-app-server-nonce");
	assert(fixture.app.tasks[fixture.tid].acceptedNativeEchoes.length == 0);
	assertThrown!AssertError(fixture.app.planHistoryBroadcast(fixture.tid,
		fixture.session.nativeUserEcho("second app-server prompt",
			"second-app-server-nonce")));
}

unittest
{
	auto dbPath = buildPath(tempDir(), "cydo-app-submission-lineage.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);

	auto fixture = new GatedSubmissionFixture(dbPath);
	fixture.app.sendTaskMessage(fixture.tid,
		[ContentBlock("text", "old echoed prompt")], null, null,
		"old-echo-nonce").ignoreResult();
	fixture.session.accept(0, AgentSubmissionReceipt.localEnqueued);
	drainSubmissionNextTicks();
	assert(fixture.app.tasks[fixture.tid].history.length == 1);
	assert(fixture.app.tasks[fixture.tid].acceptedNativeEchoes.length == 1);

	bool oldReceiptRejected;
	fixture.app.sendTaskMessage(fixture.tid,
		[ContentBlock("text", "old receipt prompt")], null, null,
		"old-receipt-nonce").then(() {
		assert(false, "stale submission receipt was committed");
	}, (Exception error) {
		oldReceiptRejected = true;
	}).ignoreResult();
	fixture.app.handleUserMessage(testBrowserSubmission(fixture.tid,
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
	assert(fixture.app.tasks[fixture.tid].acceptedNativeEchoes.length == 0);
	assert(fixture.app.tasks[fixture.tid].inFlightUiNonceGeneration.length == 0);

	fixture.app.handleUserMessage(testBrowserSubmission(fixture.tid,
		"new generation prompt", "old-rejection-nonce"));
	drainSubmissionNextTicks();
	assert(fixture.session.gates.length == 4);
	assert(("old-rejection-nonce" in fixture.app.tasks[fixture.tid]
		.inFlightUiNonceGeneration) !is null);

	fixture.session.accept(1, AgentSubmissionReceipt.appServerAccepted);
	fixture.session.reject(2, "old submission rejected");
	drainSubmissionNextTicks();
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
	assert(fixture.app.tasks[fixture.tid].acceptedNativeEchoes.length == 1);

	auto newEcho = fixture.app.planHistoryBroadcast(fixture.tid,
		fixture.session.nativeUserEcho("new generation prompt"));
	assert(testUserCorrelation(newEcho.currentEvent) == "old-rejection-nonce");
	assert(fixture.app.tasks[fixture.tid].acceptedNativeEchoes.length == 0);
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
	write(buildPath(tmp, "prompts", "empty.md"), " \n\t");

	auto app = new App();
	app.taskTypeCatalog = new TaskTypeCatalog(tmp,
		buildPath(tmp, "task-types.yaml"), &isKnownPromptParityAgent);
	assert(app.readPromptFile("prompts/empty.md", "", null) == "");
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
		findWorkspacePermissionPolicy: (string workspaceName) => "",
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
		findWorkspacePermissionPolicy: (string workspaceName) => "allow all",
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
	assert(launch.sessionConfig.includeTools.canFind("PermissionPrompt"));
	assert(reportedViolations.length == 1);
	assert(reportedProjects == [projectPath]);
	assert(reportedTaskTypes == ["parent"]);

	RenderedCydoToolsOptions options;
	options.includeBash = agent.needsBash();
	options.includePermissionPrompt = true;
	auto expectedViolations = checkRenderedCydoToolDescriptionViolations(
		catalog.getTaskTypesForProject(projectPath),
		catalog.getEntryPointsForProject(projectPath),
		"parent",
		options: options,
	);
	assert(reportedViolations[0] == expectedViolations);
	assert(expectedViolations.length > 0);

	writeToolDescriptionLimitFixture(tmp, buildTaskTypesYaml(8));
	catalog.invalidateProject(projectPath);
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
		ToolDescriptionViolation("review", "PermissionPrompt", 2001,
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
	assert(!stored.impact.canFind("PermissionPrompt"));
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
		scope(exit) app.clientHub.remove(socket);

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
		scope(exit) app.clientHub.remove(socket);
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
