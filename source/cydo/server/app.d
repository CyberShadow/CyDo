module cydo.server.app;

import core.lifetime : move;
import core.time : seconds;

import std.file : exists, isFile, thisExePath;
import std.format : format;
import std.logger : tracef, infof, warningf, errorf, fatalf;
import std.stdio : File, stderr;
import std.string : representation;

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
import cydo.mcp.tools;
import cydo.workflow.workspace.archive_manager : ArchiveManager, ArchiveManagerHost, ArchiveTaskSnapshot;
import cydo.workflow.workspace.task_path_resolver : TaskPathResolver, TaskPathResolverHost;
import cydo.workflow.workspace.worktree_allocator : WorktreeAllocator, WorktreeAllocatorHost;
import cydo.web.client_hub : ClientHub;
import cydo.runtime.config.watcher : ConfigWatcher, ConfigWatcherHost;
import cydo.workflow.discovery.service : DiscoveryService, DiscoveryServiceHost,
	DiscoveryTaskSnapshot, ImportableTaskSpec;
import cydo.web.snapshots : buildAgentsList, buildNoticesList,
	buildServerStatus, buildTaskEntry, buildTasksList, buildTaskTypesList,
	buildTaskTypesListForProject, buildWorkspacesList;
import cydo.workflow.history.pipeline : HistoryBroadcastPlan, HistoryEventPipeline,
	HistoryEventPipelineHost;
import cydo.workflow.history.abbrev : extractMessageText;
import cydo.runtime.logging : installRobustLogger;
import cydo.workflow.system_message_normalizer : SystemMessageNormalizer,
	SystemMessageNormalizerHost, buildCydoMeta;
import cydo.workflow.tasks.derived_text : DerivedTextJobs, DerivedTextJobsHost;
import cydo.workflow.tasks.mutations : TaskMutationService, TaskMutationServiceHost;
import cydo.workflow.tools.backend : WorkflowToolsBackend, WorkflowToolsHost;
import cydo.domain.task_types.catalog : TaskTypeCatalog;
import cydo.workflow.sessions.task_runner : TaskSessionLaunch, TaskSessionRunner,
	TaskSessionRunnerHost;
import cydo.web.transport : McpCallbacks, RawSourceLookupResult, RawSourceLookupStatus,
	TransportAdapter, WebSocketCallbacks;
import cydo.domain.usage.tracker : AgentUsageTracker;

import cydo.agent.contract : Agent;
import cydo.protocol : AgentAckEnvelope, BatchResultEnvelope, ContentBlock,
	ItemStartedEvent, SessionRateLimitEvent, TaskEventEnvelope, TaskEventSeqEnvelope, TranslatedEvent,
	UnconfirmedUserEventEnvelope, extractContentText;
import cydo.agent.drivers.registry : isRegisteredAgent;
import cydo.agent.session : AgentSession;
import cydo.runtime.config : AgentConfig, AgentDriver, CydoConfig, PathMode, SandboxConfig, WorkspaceConfig;
import cydo.domain.storage.persistence : Persistence, openDatabase;
import cydo.server.config_resolution : loadRuntimeConfig, reloadRuntimeConfig;
import cydo.runtime.launch.sandbox : cleanup, resolveExecutablePath, runtimeDir;
import cydo.domain.task_types.definition : TaskTypeDef, OutputType, WorktreeMode, byName, loadTaskTypes,
	loadTaskTypeSystemPrompt, renderPrompt, substituteVars,
	loadProjectMemory, resolveAgent;
import cydo.foundation.system.framing : prependTaskFraming, validateTemplateSource;
import cydo.foundation.system.known_messages : KnownSystemMessageKind,
	sessionStartSubject, systemMessagePrefix, wrapKnownSystemMessage;
import cydo.domain.tasks.model;
import cydo.foundation.text.title : truncateTitle;
import cydo.workflow.history.jsonl_store : findNextUserUuid;
import cydo.workflow.workspace.worktree;

class App
{
	import cydo.workflow.history.jsonl_tracker : JsonlTracker;

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
			taskTypeCatalog = new TaskTypeCatalog(taskTypesDir, taskTypesPath, &isRegisteredAgent);
			webDistDir = buildPath(baseDir, "web/dist/");
		}
		{
			persistence = openDatabase();
			import cydo.runtime.launch.sandbox : runtimeDir;
			createPidFile("cydo.pid", runtimeDir());
		}
		config = loadRuntimeConfig();
		taskDirTemplate = config.task_dir.length > 0 ? config.task_dir : defaultTaskDirTemplate;
		applyConfiguredLogLevel(config.log_level);
		taskPathResolver = new TaskPathResolver(TaskPathResolverHost(
			getTask: (int tid) => tid in tasks ? &tasks[tid] : null,
			workspaces: () => config.workspaces,
			taskDirTemplate: () => taskDirTemplate,
		));
		foreach (name, ref ac; config.agents)
		{
			auto driver = ac.driver.value;
			auto a = createAgentByDriver(driver);
			a.setModelAliases(ac.model_aliases);
			{
				import cydo.agent.drivers.copilot : CopilotAgent;
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
			persistStatus: (int tid, string status) {
				persistence.setStatus(tid, status);
			},
			persistNeedsAttention: (int tid, bool needsAttention) {
				persistence.setNeedsAttention(tid, needsAttention);
			},
			persistLastActive: (int tid, long lastActive) {
				persistence.setLastActive(tid, lastActive);
			},
			persistResultText: (int tid, string resultText) {
				persistence.setResultText(tid, resultText);
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
			resolveTaskAgent: (string requestedAgent, string parentAgent) {
				return resolveAgent(requestedAgent, parentAgent);
			},
			isRegisteredAgent: (string agentName) {
				return isRegisteredAgent(agentName);
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
			worktreeForkBaseHead: (int tid) {
				auto td = tid in tasks;
				assert(td !is null,
					format!"Worktree fork base requested for missing task %d"(tid));
				return getWorktreeForkBaseHead(*td);
			},
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
				return tasks[tid].processQueue.setGoal(ProcessState.Alive);
			},
			sendTaskMessage: &sendTaskMessage,
			emitTaskReload: &emitTaskReload,
			appendSynthesizedHistoryError: (int tid, string subject, string body) {
				historyPipeline.appendSynthesizedHistoryError(tid, subject, body);
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
			reactivateTask: (int tid, void delegate() onReady) {
				auto td = tid in tasks;
				assert(td !is null,
					format!"WorkflowTools reactivation requested for missing task %d"(tid));
				assert(td.processQueue !is null,
					format!"WorkflowTools reactivation requested without process queue for task %d"(tid));
				td.processQueue.setGoal(ProcessState.Alive).then(onReady).ignoreResult();
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
			tryAgentForTask: &tryAgentForTask,
			effectiveCwd: (int tid) {
				auto td = tid in tasks;
				return taskPathResolver.effectiveCwd(td);
			},
			injectAgentNameIntoSessionInit: &injectAgentNameIntoSessionInit,
			normalizeKnownSystemMessageMeta: (string translated, int tid) {
				return systemMessageNormalizer.normalizeKnownSystemMessageMeta(translated, tid);
			},
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
					taskPathResolver.effectiveCwd(td));
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
			globalSandbox: () => config.sandbox,
			findWorkspaceSandbox: &findWorkspaceSandbox,
			findWorkspaceRoot: &taskPathResolver.findWorkspaceRoot,
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
			hasPendingSubTask: &workflowTools.hasPendingSubTask,
			hasTaskDependency: &workflowTools.hasTaskDependency,
			hasPendingChildQuestion: &workflowTools.hasPendingChildQuestion,
			sendPendingChildAnswerReminder: &workflowTools.sendPendingChildAnswerReminder,
			checkDeclaredOutputs: &checkDeclaredOutputs,
			finalizeCompletedSubTask: &workflowTools.finalizeCompletedSubTask,
			deliverFailedPendingSubTaskResult: &workflowTools.deliverFailedPendingSubTaskResult,
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
			persistStatus: (int tid, string status) {
				persistence.setStatus(tid, status);
			},
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
			stopJsonlWatch: (int tid) {
				jsonlTracker.stopJsonlWatch(tid);
			},
			broadcastForkableUuidsFromFile: (int tid) {
				jsonlTracker.broadcastForkableUuidsFromFile(tid);
			},
			sendSystemRestartNudge: &workflowTools.sendSystemRestartNudge,
			loadPersistedTaskDeps: &workflowTools.loadPersistedTaskDeps,
			snapshotTaskIds: &snapshotTaskIdsForResume,
			waitingTaskChildrenAllDone: &workflowTools.waitingTaskChildrenAllDone,
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
			effectiveCwd: &taskPathResolver.effectiveCwd,
			prepareTaskSessionLaunch: &prepareTaskSessionLaunch,
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
			persistStatus: (int tid, string status) {
				persistence.setStatus(tid, status);
			},
			ensureHistoryLoaded: (int tid) {
				historyPipeline.ensureHistoryLoaded(tid);
			},
			getUndoJsonl: (int tid) => jsonlTracker.getUndoJsonl(tid),
			clearUndoJsonl: (int tid) {
				jsonlTracker.clearUndoJsonl(tid);
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
		jsonlTracker.getAgent = &agentForTask;
		jsonlTracker.getTask = (int tid) => tid in tasks ? &tasks[tid] : null;
		jsonlTracker.getEffectiveCwd = (int tid) {
			auto td = tid in tasks;
			return taskPathResolver.effectiveCwd(td);
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
							cwd = taskPathResolver.effectiveCwd(td2);
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
					auto ta = agentForTask(td.tid);
					auto jp = ta.historyPath(td.agentSessionId, taskPathResolver.effectiveCwd(&td));
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
		).representation));
		ws.send(Data(buildAgentsList(snapshotAgentEntries(), config.default_agent).representation));
		ws.send(Data(buildCurrentTasksList().representation));
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
			tasks[tid].processQueue.setGoal(ProcessState.Alive).then(() {
				sendTaskMessage(tid, messageToSend, msgContent, msgMeta);
			}).ignoreResult();

			td.description = textContent;
			persistence.setDescription(tid, textContent);

			td.title = truncateTitle(textContent, 80);
			persistence.setTitle(tid, td.title);
			broadcastTitleUpdate(tid, td.title);
			tasks[tid].processQueue.setGoal(ProcessState.Alive).then(() {
				derivedTextJobs.generateTitle(tid, textContent);
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
							import cydo.protocol : ItemStartedEvent;
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
		derivedTextJobs.clearSuggestions(tid);
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
				derivedTextJobs.generateTitle(tid, textContent);
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
		if (taskAlive(tid))
			return;
		td.needsAttention = false;
		persistence.setNeedsAttention(tid, false);
		td.notificationBody = "";
		td.processQueue.setGoal(ProcessState.Alive).then(() {
			auto td = &tasks[tid];
			td.status = "alive";
			persistence.setStatus(tid, "alive");
			try
				derivedTextJobs.generateSuggestions(tid);
			catch (Exception e)
				warningf("Error generating suggestions: %s", e.msg);

			workflowTools.deliverBatchFallbackIfReady(tid);

			broadcastTaskUpdate(tid);
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
		auto session = sessionForTask(tid);
		assert(session !is null, "Task session must exist when sending a message");
		const(ContentBlock)[] toSend = session.supportsImages
			? content
			: content.filter!(b => b.type != "image").array;
		session.sendMessage(toSend, nonce);
		td.isProcessing = true;
		touchTask(tid);
		td.needsAttention = false;
		persistence.setNeedsAttention(tid, false);
		td.notificationBody = "";
		derivedTextJobs.discardInFlightSuggestions(tid);
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
		sendPreparedTaskMessage(tid, reminderBlocks, null, reminderMeta, false);
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
		return agentForTask(tid).historyPath(td.agentSessionId,
			taskPathResolver.effectiveCwd(td));
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
			import cydo.agent.drivers.copilot : CopilotAgent;
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
		import cydo.agent.drivers.registry : agentRegistry;
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
				auto jp = ta.historyPath(tasks[tid].agentSessionId,
					taskPathResolver.effectiveCwd(&tasks[tid]));
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
			auto outputsMeta = systemMessageNormalizer.buildKnownSystemMessageMeta(
				KnownSystemMessageKind.missingRequiredOutputs);
			sendTaskMessage(tid, [ContentBlock("text", msg)], null, outputsMeta);
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

	private void sendKnownSystemMessage(int tid, KnownSystemMessageKind kind,
		string body)
	{
		auto msg = wrapKnownSystemMessage(config.system_keyword, kind, body);
		auto meta = systemMessageNormalizer.buildKnownSystemMessageMeta(kind);
		sendTaskMessage(tid, [ContentBlock("text", msg)], null, meta);
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
		derivedTextJobs.invalidateSuggestions(tid);
		clientHub.broadcast(toJson(TaskReloadMessage("task_reload", tid, reason)));
	}

	/// Wrap text in [SYSTEM: ...] tags so the agent knows the message is
	/// injected by CyDo, not typed by the user.
	private string wrapSystemMessage(string subject, string body = null)
	{
		import cydo.foundation.system.framing : wrapSystemMessageFn = wrapSystemMessage;
		return wrapSystemMessageFn(config.system_keyword, subject, body);
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
					import cydo.agent.drivers.copilot : CopilotAgent;
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

	private bool taskAlive(int tid)
	{
		return taskSessionRunner.taskAlive(tid);
	}

	private bool taskCanStop(int tid)
	{
		return taskSessionRunner.taskCanStop(tid, tasks[tid].stdinClosed);
	}

	private string buildCurrentTasksList()
	{
		TaskListEntry[] entries;
		foreach (tid, ref td; tasks)
			entries ~= buildTaskEntry(td, taskAlive(tid), taskCanStop(tid));
		return buildTasksList(entries);
	}

	private void broadcastTaskUpdate(int tid)
	{
		import ae.utils.json : toJson;

		clientHub.broadcast(toJson(TaskUpdatedMessage("task_updated",
			buildTaskEntry(tasks[tid], taskAlive(tid), taskCanStop(tid)))));
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
		import cydo.agent.drivers.registry : agentRegistry;
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
	import std.algorithm : canFind;
	import std.file : exists, mkdirRecurse, rmdirRecurse, write;
	import std.path : buildPath;
	import std.process : environment;

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
	app.taskDirTemplate = "{{ workspace_root }}/.cydo/tasks/{{ tid }}";
	app.taskTypeCatalog = new TaskTypeCatalog(buildPath(tmp, "defs"),
		buildPath(tmp, "defs", "task-types.yaml"),
		&isKnownPromptParityAgent);
	app.tasks[41] = TaskData(41, "local", projectPath);
	app.tasks[41].taskType = "parent";
	app.tasks[41].agentType = "codex";
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
		globalSandbox: () => SandboxConfig(
			isolate_filesystem: SetInfo!bool(false),
			isolate_processes: SetInfo!bool(false),
			isolate_environment: SetInfo!bool(false),
		),
		findWorkspaceSandbox: (string workspaceName) => SandboxConfig(
			isolate_filesystem: SetInfo!bool(false),
			isolate_processes: SetInfo!bool(false),
			isolate_environment: SetInfo!bool(false),
		),
		findWorkspaceRoot: (string workspaceName) => workspaceRoot,
		findWorkspacePermissionPolicy: (string workspaceName) => "",
		findAgentSandbox: (string agentName) => SandboxConfig(
			isolate_filesystem: SetInfo!bool(false),
			isolate_processes: SetInfo!bool(false),
			isolate_environment: SetInfo!bool(false),
		),
		resolveSharedTmpPath: (int tid) => buildPath(tmp, "shared-tmp"),
		mcpSocketPath: () => "",
		taskTypeCatalog: app.taskTypeCatalog,
	));

	app.tasks[41].agentType = "claude";
	auto claudeLaunch = runner.prepareTaskSessionLaunch(41, new TestClaudePromptAgent(),
		currentTypeDef());
	assert(claudeLaunch.sessionConfig.appendSystemPrompt == codexPrompt);

	app.tasks[41].agentType = "copilot";
	auto copilotLaunch = runner.prepareTaskSessionLaunch(41, new TestCopilotPromptAgent(),
		currentTypeDef());
	assert(copilotLaunch.sessionConfig.appendSystemPrompt == codexPrompt);
}
