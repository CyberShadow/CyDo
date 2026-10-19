module cydo.workflow.sessions.task_runner;

import core.time : seconds;

import std.file : exists, isFile, mkdirRecurse;
import std.exception : enforce;
import std.path : buildPath, dirName, isAbsolute;
import std.stdio : File;
import std.logger : infof, tracef, warningf;
import std.typecons : Nullable;

import ae.utils.json : JSONOptional, JSONPartial, jsonParse, toJson;
import ae.utils.promise : Promise, reject, resolve;

import cydo.agent.contract : Agent, SessionConfig;
import cydo.agent.session : AgentSession;
import cydo.mcp.tool_descriptions : RenderedCydoToolsOptions,
	ToolDescriptionViolation, checkRenderedCydoToolDescriptionViolations;
import cydo.protocol : ItemDeltaEvent, ItemStartedEvent, ProcessExitEvent,
	ProcessStderrEvent, TranslatedEvent;
import cydo.runtime.config : AgentDriver, CydoConfig, PathMode, SandboxConfig;
import cydo.runtime.launch.sandbox_paths : PathAccess, SandboxPathOrigin,
	SandboxPathOriginKind, SandboxPaths;
import cydo.runtime.launch.types : AgentSandboxConfig, NativeHistoryProfile,
	NativeHistoryRule, ProcessLaunch;
import launchSandbox = cydo.runtime.launch.sandbox;
import cydo.workflow.history.native_history : ConfiguredNativeHistoryContext,
	HistoryAccess, LiveHistoryContext, LiveHistoryWatchResolution,
	LiveHistoryWatchResolutionKind, LiveHistoryWatchTarget,
	ResolvedNativeHistoryContext, TaskHistoryResolution, TaskHistoryResolutionKind, UnavailableHistory,
	UnavailableHistoryKind, resolveNativeHistoryContext;
import cydo.agent.drivers.codex : CodexAgent, CodexForkSourceOwner, CodexSession;
import cydo.domain.tasks.model : PendingContinuation, ProcessState, TaskData, TaskStatus,
	WaitingTaskDependencyState;
import cydo.domain.tasks.lifecycle : TaskNotificationChange;
import cydo.domain.task_types.catalog : TaskTypeCatalog;
import cydo.domain.task_types.definition : TaskTypeDef,
	formatCompactCreatableTaskTypeToolSummary, formatCompactHandoffToolSummary,
	isInteractive, formatCompactSwitchModeToolSummary, loadTaskTypeSystemPrompt, byName;
import cydo.workflow.history.jsonl_store : repairInterruptedToolCallFile;

version (unittest) import std.exception : assertThrown;
version (unittest) import std.process : execute;
version (unittest) import std.string : strip;
version (unittest) import cydo.agent.drivers.claude : ClaudeCodeAgent;
version (unittest) import cydo.agent.drivers.copilot : CopilotAgent;

package(cydo):

private PathAccess pathAccessFor(PathMode mode)
{
	final switch (mode)
	{
	case PathMode.ro:
		return PathAccess.ro;
	case PathMode.rw:
		return PathAccess.rw;
	case PathMode.always_rw:
		return PathAccess.alwaysRw;
	case PathMode.tmpfs:
	case PathMode.empty_dir:
	case PathMode.empty_file:
		assert(false, "Git metadata requires an exposed checkout");
	}
}

private bool isAssistantTurnWork(TranslatedEvent ev)
{
	@JSONPartial struct EventType
	{
		string type;
	}

	auto eventType = jsonParse!EventType(ev.translated).type;
	if (eventType == "item/started")
	{
		auto started = jsonParse!ItemStartedEvent(ev.translated);
		if (started.is_replay || started.is_synthetic || started.is_meta)
			return false;
		return started.item_type == "text"
			|| started.item_type == "thinking"
			|| started.item_type == "tool_use";
	}
	if (eventType == "item/delta")
	{
		auto delta = jsonParse!ItemDeltaEvent(ev.translated);
		return delta.delta_type == "text_delta"
			|| delta.delta_type == "thinking_delta"
			|| delta.delta_type == "input_json_delta";
	}
	return false;
}

unittest
{
	foreach (eventJson; [
		`{"type":"item/started","item_id":"text","item_type":"text"}`,
		`{"type":"item/started","item_id":"thinking","item_type":"thinking"}`,
		`{"type":"item/started","item_id":"tool","item_type":"tool_use"}`,
		`{"type":"item/delta","item_id":"text","delta_type":"text_delta","content":"work"}`,
		`{"type":"item/delta","item_id":"thinking","delta_type":"thinking_delta","content":"work"}`,
		`{"type":"item/delta","item_id":"tool","delta_type":"input_json_delta","content":"{}"}`,
	])
		assert(isAssistantTurnWork(TranslatedEvent(eventJson, null)), eventJson);
}

unittest
{
	foreach (eventJson; [
		`{"type":"session/init","session_id":"session"}`,
		`{"type":"session/status","status":"idle"}`,
		`{"type":"session/compacted"}`,
		`{"type":"item/started","item_id":"user","item_type":"user_message"}`,
		`{"type":"item/started","item_id":"replay","item_type":"text","is_replay":true}`,
		`{"type":"item/started","item_id":"synthetic","item_type":"thinking","is_synthetic":true}`,
		`{"type":"item/started","item_id":"meta","item_type":"tool","is_meta":true}`,
		`{"type":"item/delta","item_id":"background","delta_type":"output_delta","content":"late output"}`,
		`{"type":"item/completed","item_id":"text","text":"done"}`,
		`{"type":"item/result","item_id":"tool","content":"done"}`,
		`{"type":"turn/result","subtype":"success"}`,
		`{"type":"process/stderr","text":"warning"}`,
		`{"type":"process/exit","code":0}`,
		`{"type":"task/notification","message":"waiting"}`,
	])
		assert(!isAssistantTurnWork(TranslatedEvent(eventJson, null)), eventJson);
}

unittest
{
	assertThrown!Exception(isAssistantTurnWork(
		TranslatedEvent(`{"type":"item/started"`, null)));
}

/// Whether a translated turn/result event reports a terminal agent error
/// (e.g. Codex usage limit exceeded) instead of a normal completion.
private bool isErrorTurnResult(string translated)
{
	@JSONPartial struct ResultProbe
	{
		@JSONOptional bool is_error;
	}

	return jsonParse!ResultProbe(translated).is_error;
}

unittest
{
	assert(isErrorTurnResult(
		`{"type":"turn/result","subtype":"error","is_error":true,"result":"limit"}`));
	assert(!isErrorTurnResult(`{"type":"turn/result","subtype":"success","result":"ok"}`));
	assert(!isErrorTurnResult(`{"type":"turn/result"}`));
}

struct TaskSessionLaunch
{
	ProcessLaunch processLaunch;
	SessionConfig sessionConfig;
}

struct TaskSessionRunnerHost
{
	TaskData* delegate(int tid) getTask;
	string delegate(const TaskData* td) taskDir;
	string delegate(const TaskData* td) outputPath;
	string delegate(const TaskData* td) effectiveCwd;
	string delegate(const TaskData* td) worktreePath;
	CydoConfig* delegate() currentConfig;
	string delegate(string workspaceName) findWorkspacePermissionPolicy;
	void delegate(string projectPath, string taskType,
		ToolDescriptionViolation[] violations) reportMcpToolDescriptionLimit;
	string delegate(int tid) resolveSharedTmpPath;
	string delegate() mcpSocketPath;
	Agent delegate(int tid) agentForTask;
	Agent delegate(int tid) tryAgentForTask;
	void delegate(int tid, string agentSessionId) setAgentSessionId;
	void delegate(int tid) clearLastActive;
	void delegate(int tid, TranslatedEvent ev) broadcastTask;
	string delegate(int tid, string subject, string body) appendTaskDiagnostic;
	void delegate(int tid, string translated) broadcastAppendedTaskEvent;
	void delegate(int tid) publishTaskSnapshot;
	void delegate(int tid) onTaskTurnCompletedAlive;
	bool delegate(int tid) drainIdleCallbacksForTurnResult;
	void delegate(int tid) drainIdleCallbacksOnExit;
	bool delegate(int tid) hasPendingSubTask;
	bool delegate(int tid) hasTaskDependency;
	bool delegate(int tid) hasPendingChildQuestion;
	void delegate(int tid) sendPendingChildAnswerReminder;
	string delegate(int tid) checkDeclaredOutputs;
	bool delegate(int tid, bool eagerDepCleanup) finalizeCompletedSubTask;
	bool delegate(int tid) deliverFailedPendingSubTaskResult;
	int delegate(int childTid) parentTaskForChild;
	Promise!void delegate(int tid) deliverWaitingParentResultsIfReady;
	Promise!void delegate(int parentTid) deliverBatchResults;
	void delegate(int tid) failPendingAskUserQuestionOnExit;
	void delegate(int tid) failPendingPermissionPromptOnExit;
	void delegate(int tid) failPendingAskRouteOnExit;
	void delegate(int tid) cancelExitBackgroundWork;
	/// Returns true when the reset already emitted a task reload (unavailable
	/// history), so the caller must not emit a redundant one.
	bool delegate(int tid) resetHistoryWatermarkOnly;
	bool delegate(int tid) resetHistoryWatermarkAfterExit; /// ditto
	void delegate(int tid) unsubscribeTaskHistorySubscribers;
	void delegate(int tid) touchAndPersistLastActive;
	int delegate(int tid) findAliveAncestor;
	void delegate(int fromTid, int toTid) broadcastFocusHint;
	void delegate(int tid, TaskStatus expectedFrom, TaskStatus to,
		TaskNotificationChange notification) transitionTask;
	void delegate(int tid, TaskStatus[] expectedFrom, TaskStatus to,
		TaskNotificationChange notification) transitionTaskFrom;
	void delegate(int tid, string resultText) persistResultText;
	void delegate(int tid, string missingOutputs) requestMissingOutputs;
	void delegate(int tid) spawnContinuation;
	void delegate(int tid) spawnOnYieldContinuation;
	void delegate(int tid) emitTaskReload;
	void delegate(int tid) startJsonlWatch;
	/// Returns the resolution used, or null when history was already loaded
	/// (no resolution was performed). Never reports an unavailable
	/// resolution: the post-exit reset that runs later in onExit is the sole
	/// owner of that diagnostic.
	Nullable!TaskHistoryResolution delegate(int tid) ensureHistoryLoadedForExit;
	/// `resolution` is what the immediately preceding ensureHistoryLoadedForExit
	/// call returned; passing it through avoids re-resolving the same B
	/// resolution. Never reports, for the same reason.
	void delegate(int tid, Nullable!TaskHistoryResolution resolution)
		finalReconcileJsonlIfPresent;
	void delegate(int tid) stopJsonlWatch;
	void delegate(int tid) broadcastHistoryOperations;
	Promise!void delegate(int tid) sendSystemRestartNudge;
	void delegate() loadPersistedTaskDeps;
	int[] delegate() snapshotTaskIds;
	WaitingTaskDependencyState delegate(int parentTid) waitingTaskDependencyState;
	bool delegate() shuttingDown;
	TaskTypeCatalog taskTypeCatalog;
}

private struct LiveHistoryBinding
{
	AgentSession owner;
	Agent agent;
	NativeHistoryProfile profile;
	string sessionId;
}

private enum LaunchOwnership { task, operation }

/// Owns the current-profile launch and private real CodexSession used to
/// resume a stopped source thread solely for one native fork. It is never a
/// normal task session or a live-history binding.
final class CodexForkSourceOperation
{
private:
	CodexForkSourceOwner owner_;
	ProcessLaunch launch_;
	bool released_;
	void delegate() releasedHandler_;

public:
	this(ProcessLaunch launch)
	{
		launch_ = launch;
	}

	void attachOwner(CodexForkSourceOwner owner)
	{
		enforce(owner_ is null,
			"Codex fork source operation already has an owner");
		enforce(owner !is null,
			"Codex fork source operation requires an owner");
		owner_ = owner;
		owner_.onClosed = &release;
	}

	@property Promise!CodexSession routeReady()
	{
		enforce(owner_ !is null,
			"Codex fork source operation has no owner yet");
		return owner_.routeReady;
	}

	void activate(void delegate() releasedHandler)
	{
		enforce(releasedHandler_ is null,
			"Codex fork source operation was activated more than once");
		releasedHandler_ = releasedHandler;
	}

	void closeStdin()
	{
		if (released_)
			return;
		if (owner_ !is null)
			owner_.closeStdin();
		else
			release();
	}

private:
	void release()
	{
		if (released_)
			return;
		released_ = true;
		launchSandbox.cleanup(launch_.sandbox);
		if (releasedHandler_)
			releasedHandler_();
	}
}

class TaskSessionRunner
{
	private TaskSessionRunnerHost host_;
	private AgentSession[int] sessions_;
	private LiveHistoryBinding[int] liveHistoryBindings_;
	private CodexForkSourceOperation[int] forkSourceOperations_;

	this(TaskSessionRunnerHost host)
	{
		host_ = host;
	}

	AgentSession sessionForTask(int tid)
	{
		if (auto session = tid in sessions_)
			return *session;
		return null;
	}

	bool taskAlive(int tid)
	{
		auto session = sessionForTask(tid);
		return session !is null && session.alive;
	}

	bool forkSourceOperationInProgress(int tid)
	{
		return (tid in forkSourceOperations_) !is null;
	}

	CodexForkSourceOperation openCodexForkSourceOperation(int tid,
		const ref HistoryAccess source)
	{
		auto td = requireTask(tid,
			"Codex fork source operation requires an existing task");
		auto sourceAgent = cast(Agent) source.agent;
		auto codex = cast(CodexAgent) sourceAgent;
		enforce(codex !is null && source.profile.driver == AgentDriver.codex,
			"Codex fork source operation requires Codex history access");
		enforce(source.sessionId == td.agentSessionId,
			"Codex fork source operation must use the task's exact session ID");
		auto configuredAgent = host_.tryAgentForTask(tid);
		enforce(configuredAgent !is null && configuredAgent is sourceAgent,
			"Codex fork source operation must use the task's configured Agent");
		enforce(sessionForTask(tid) is null,
			"Codex fork source operation cannot retain a task session");
		enforce(tid !in forkSourceOperations_,
			"Codex fork source operation is already active for this task");

		auto typeDef = currentTaskTypeDef(td);
		TaskSessionLaunch launch;
		CodexForkSourceOperation operation;
		try
		{
			launch = prepareOperationSessionLaunch(tid, sourceAgent, typeDef);
			enforce(launch.processLaunch.nativeHistoryProfile.driver == source.profile.driver
				&& launch.processLaunch.nativeHistoryProfile.root == source.profile.root,
				"Codex fork source operation launch must use the captured source profile");
			operation = new CodexForkSourceOperation(launch.processLaunch);
			forkSourceOperations_[tid] = operation;
			operation.activate(() {
				auto mapped = tid in forkSourceOperations_;
				if (mapped !is null && *mapped is operation)
					forkSourceOperations_.remove(tid);
			});
			auto owner = codex.openForkSourceOwner(tid, source.sessionId,
				launch.processLaunch, launch.sessionConfig);
			operation.attachOwner(owner);
			return operation;
		}
		catch (Exception e)
		{
			if (operation !is null)
				operation.closeStdin();
			else if (launch.processLaunch.nativeHistoryProfile.root.length > 0)
				launchSandbox.cleanup(launch.processLaunch.sandbox);
			throw e;
		}
	}

	bool taskCanStop(int tid, bool stdinClosed)
	{
		auto session = sessionForTask(tid);
		return session !is null
			&& session.alive
			&& (!stdinClosed || session.canStopAfterCloseStdin);
	}

	TaskHistoryResolution resolveTaskHistory(int tid)
	{
		auto td = requireTask(tid,
			"Task history resolution requires an existing task");
		if (td.agentSessionId.length == 0)
			return TaskHistoryResolution.noSession();

		if (auto binding = tid in liveHistoryBindings_)
		{
			auto owner = tid in sessions_;
			enforce(owner !is null && *owner is (*binding).owner,
				"Live history binding does not match the mapped session owner");
			return resolveHistoryAccess((*binding).agent, (*binding).profile,
				(*binding).sessionId, td.agentName,
				(*binding).agent.nativeHistoryRule);
		}

		auto agent = host_.tryAgentForTask(tid);
		if (agent is null)
			return TaskHistoryResolution.orphanAgent(td.agentName, td.agentSessionId);

		ResolvedNativeHistoryContext resolved;
		try
		{
			auto typeDef = currentTaskTypeDef(td);
			auto context = ConfiguredNativeHistoryContext(td.agentName, td.workspace,
				td.repoPath, typeDef !is null && typeDef.read_only);
			resolved = resolveNativeHistoryContext(*host_.currentConfig(), agent, context);
		}
		catch (Exception e)
		{
			return TaskHistoryResolution.unavailable(UnavailableHistory(
				UnavailableHistoryKind.context, td.agentName, td.agentSessionId,
				e.msg, NativeHistoryRule.init, NativeHistoryProfile.init));
		}
		return resolveHistoryAccess(resolved.agent, resolved.profile,
			td.agentSessionId, td.agentName, resolved.rule);
	}

	LiveHistoryWatchResolution resolveLiveHistoryWatch(int tid)
	{
		auto binding = tid in liveHistoryBindings_;
		if (binding is null)
			return LiveHistoryWatchResolution.noLiveBinding();
		auto owner = tid in sessions_;
		enforce(owner !is null && *owner is (*binding).owner,
			"Live history watch binding does not match the mapped session owner");
		auto context = LiveHistoryContext((*binding).agent, (*binding).profile,
			(*binding).sessionId);
		if (auto codex = cast(CodexAgent) (*binding).agent)
		{
			auto codexOwner = cast(CodexSession) (*binding).owner;
			enforce(codexOwner !is null,
				"Codex live history binding must be owned by a Codex session");
			auto path = codex.liveSessionPath(codexOwner, (*binding).profile,
				(*binding).sessionId);
			if (path.length == 0)
				return LiveHistoryWatchResolution.awaitingPath(context);
			return LiveHistoryWatchResolution.target(LiveHistoryWatchTarget(context, path));
		}
		auto path = (*binding).agent.historyPath((*binding).sessionId,
			(*binding).profile);
		return LiveHistoryWatchResolution.target(LiveHistoryWatchTarget(context, path));
	}

	ProcessLaunch requireLiveHistoryLaunch(int tid, const ref HistoryAccess access)
	{
		auto td = requireTask(tid,
			"Live history launch requires an existing task");
		auto binding = tid in liveHistoryBindings_;
		enforce(binding !is null,
			"Live history launch requires a live history binding");
		auto owner = tid in sessions_;
		enforce(owner !is null && *owner is (*binding).owner,
			"Live history launch binding does not match the mapped session owner");
		enforce(access.agent is (*binding).agent
			&& access.profile.driver == (*binding).profile.driver
			&& access.profile.root == (*binding).profile.root
			&& access.sessionId == (*binding).sessionId,
			"Live history access does not match its live binding");
		enforce(td.launch.nativeHistoryProfile.driver == (*binding).profile.driver
			&& td.launch.nativeHistoryProfile.root == (*binding).profile.root,
			"Live history launch does not match its binding profile");
		return td.launch;
	}

private:
	TaskHistoryResolution resolveHistoryAccess(Agent agent,
		const ref NativeHistoryProfile profile, string sessionId,
		string agentName, NativeHistoryRule rule)
	{
		auto path = agent.historyPath(sessionId, profile);
		if (path.length == 0 || !isAbsolute(path))
			return TaskHistoryResolution.unavailable(UnavailableHistory(
				UnavailableHistoryKind.profilePath, agentName, sessionId,
				"The derived history path is unavailable", rule, profile));
		if (!exists(path))
			return TaskHistoryResolution.unavailable(UnavailableHistory(
				UnavailableHistoryKind.profilePath, agentName, sessionId,
				"The derived history file does not exist", rule, profile));
		if (!isFile(path))
			return TaskHistoryResolution.unavailable(UnavailableHistory(
				UnavailableHistoryKind.profilePath, agentName, sessionId,
				"The derived history path is not a regular file", rule, profile));
		try
		{
			auto file = File(path, "r");
		}
		catch (Exception e)
		{
			return TaskHistoryResolution.unavailable(UnavailableHistory(
				UnavailableHistoryKind.profilePath, agentName, sessionId, e.msg,
				rule, profile));
		}
		return TaskHistoryResolution.access(HistoryAccess(agent, profile, sessionId,
			path));
	}

public:

	void shutdownSessions()
	{
		CodexForkSourceOperation[] operationSnapshot;
		foreach (operation; forkSourceOperations_)
			operationSnapshot ~= operation;
		foreach (operation; operationSnapshot)
			operation.closeStdin();

		AgentSession[] snapshot;
		foreach (session; sessions_)
			snapshot ~= session;
		foreach (session; snapshot)
		{
			if (session.alive)
				session.stop();
			session.killAfterTimeout(0.seconds);
		}
	}

	void interruptTask(int tid)
	{
		if (auto session = sessionForTask(tid))
			session.interrupt();
	}

	void sigintTask(int tid)
	{
		if (auto session = sessionForTask(tid))
			session.sigint();
	}

	void closeTaskStdin(int tid)
	{
		if (auto session = sessionForTask(tid))
			session.closeStdin();
	}

	void stopTask(int tid)
	{
		if (auto operation = tid in forkSourceOperations_)
			(*operation).closeStdin();
		if (auto session = sessionForTask(tid))
			session.stop();
	}

	TaskSessionLaunch prepareTaskSessionLaunch(int tid, Agent taskAgent,
		TaskTypeDef* typeDef)
	{
		return buildTaskSessionLaunch(tid, taskAgent, typeDef,
			LaunchOwnership.task);
	}

	/// Build a current-config launch for a one-shot operation without assigning
	/// it to TaskData.launch. The operation caller owns sandbox cleanup.
	TaskSessionLaunch prepareOperationSessionLaunch(int tid, Agent taskAgent,
		TaskTypeDef* typeDef)
	{
		return buildTaskSessionLaunch(tid, taskAgent, typeDef,
			LaunchOwnership.operation);
	}

	private TaskSessionLaunch buildTaskSessionLaunch(int tid, Agent taskAgent,
		TaskTypeDef* typeDef, LaunchOwnership ownership)
	{
		auto td = requireTask(tid,
			"Task must exist before preparing session launch");
		if (ownership == LaunchOwnership.operation)
			enforce(td.launch.nativeHistoryProfile.root.length == 0,
				"Operation launch requires TaskData.launch to have been cleared");

		SessionConfig sessionConfig;
		auto taskTypes = host_.taskTypeCatalog.getTaskTypesForProject(td.projectPath);
		auto entryPoints = host_.taskTypeCatalog.getEntryPointsForProject(td.projectPath);
		sessionConfig.creatableTaskTypes = formatCompactCreatableTaskTypeToolSummary(taskTypes,
			td.taskType);
		sessionConfig.switchModes = formatCompactSwitchModeToolSummary(taskTypes, td.taskType);
		sessionConfig.handoffs = formatCompactHandoffToolSummary(taskTypes, td.taskType);
		if (typeDef !is null)
		{
			import cydo.domain.task_types.definition : resolveModelClass;
			auto modelClass = resolveModelClass(typeDef.model_class, td.workspace,
				td.agentName);
			auto spec = taskAgent.resolveModelSpec(modelClass);
			sessionConfig.model = spec.model;
			sessionConfig.effort = spec.effort;
			if (taskAgent.supportsDeveloperPrompt)
				sessionConfig.appendSystemPrompt = loadTaskTypeSystemPrompt(*typeDef, taskTypes,
					td.taskType,
					host_.taskTypeCatalog.promptSearchPath(td.projectPath),
					host_.outputPath(td));
		}
		sessionConfig.mcpSocketPath = host_.mcpSocketPath();

		auto workDir = td.repoPath.length > 0 ? td.repoPath : null;

		auto tdDir = host_.taskDir(td);
		mkdirRecurse(tdDir);

		auto taskCwd = host_.effectiveCwd(td);
		auto chdir = taskCwd.length > 0 ? taskCwd : workDir;

		bool readOnly = typeDef !is null && typeDef.read_only;
		auto context = ConfiguredNativeHistoryContext(td.agentName, td.workspace,
			td.repoPath, readOnly);
		auto nativeHistoryContext = resolveNativeHistoryContext(*host_.currentConfig(),
			taskAgent, context);
		enforce(nativeHistoryContext.agent.driver == taskAgent.driver,
			"Configured native history Agent does not match the task Agent driver");
		auto sandbox = nativeHistoryContext.sandbox;

		if (td.hasWorktree && workDir.length > 0)
		{
			sandbox.paths.require(workDir, PathAccess.ro,
				SandboxPathOrigin(SandboxPathOriginKind.launchRequirement, workDir,
					"base checkout"));
			sandbox.paths.restrictExactToReadOnly(workDir,
				SandboxPathOrigin(SandboxPathOriginKind.exactReadOnly, workDir,
					"base checkout"));
		}

		if (workDir.length > 0 && (td.isGitCheckout || td.hasWorktree))
		{
			auto workDirView = sandbox.paths.exact(workDir);
			enforce(!workDirView.isNull,
				"Sandbox must expose the task checkout: " ~ workDir);
			bool maskedCheckout;
			if (!workDirView.get.declaration.isNull)
			{
				final switch (workDirView.get.declaration.get.mode)
				{
				case PathMode.ro:
				case PathMode.rw:
				case PathMode.always_rw:
					break;
				case PathMode.tmpfs:
				case PathMode.empty_dir:
				case PathMode.empty_file:
					maskedCheckout = true;
					break;
				}
			}
			if (!maskedCheckout)
				launchSandbox.grantGitMetadata(sandbox.paths, workDir,
					pathAccessFor(workDirView.get.effectiveMode),
					SandboxPathOrigin(SandboxPathOriginKind.launchRequirement, workDir,
						"checkout Git metadata"));
		}

		sandbox.paths.require(tdDir, PathAccess.rw,
			SandboxPathOrigin(SandboxPathOriginKind.launchRequirement, tdDir,
				"task directory"));

		// Other tasks' outputs are part of the workflow contract (sub-task
		// results are delivered to the parent as paths into the sub-tasks'
		// directories), and the tasks container is not necessarily reachable
		// through the workspace-root mount (it may live on another volume) —
		// mount it read-only.
		auto tasksRoot = dirName(tdDir);
		sandbox.paths.require(tasksRoot, PathAccess.ro,
			SandboxPathOrigin(SandboxPathOriginKind.launchRequirement, tasksRoot,
				"task root"));

		if (td.hasWorktree && workDir.length > 0)
		{
			// Read-only tasks need the worktree mounted too: the task
			// directory tree is not necessarily reachable through the
			// workspace-root mount (it may live on another volume).
			auto wtPath = host_.worktreePath(td);
			enforce(wtPath.length > 0, "Worktree path must not be empty for worktree task");
			auto wtAccess = readOnly ? PathAccess.ro : PathAccess.rw;
			sandbox.paths.require(wtPath, wtAccess,
				SandboxPathOrigin(SandboxPathOriginKind.launchRequirement, wtPath,
					"active worktree"));
			if (readOnly)
				sandbox.paths.restrictExactToReadOnly(wtPath,
					SandboxPathOrigin(SandboxPathOriginKind.exactReadOnly, wtPath,
						"active worktree"));
			auto wtView = sandbox.paths.exact(wtPath);
			assert(!wtView.isNull);
			launchSandbox.grantGitMetadata(sandbox.paths, wtPath,
				pathAccessFor(wtView.get.effectiveMode),
				SandboxPathOrigin(SandboxPathOriginKind.launchRequirement, wtPath,
					"active worktree Git metadata"));
		}

		auto reachesWorktree = host_.taskTypeCatalog.reachesWorktreeFor(td.projectPath);
		if (workDir.length > 0 && (td.isGitCheckout || td.hasWorktree)
			&& td.taskType in reachesWorktree && reachesWorktree[td.taskType])
			launchSandbox.grantGitMetadata(sandbox.paths, workDir, PathAccess.alwaysRw,
				SandboxPathOrigin(SandboxPathOriginKind.launchRequirement, workDir,
					"worktree-reachable checkout Git metadata"));

		auto mcpSocketPath = host_.mcpSocketPath();
		if (mcpSocketPath.length > 0)
			sandbox.paths.require(mcpSocketPath, PathAccess.ro,
				SandboxPathOrigin(SandboxPathOriginKind.launchRequirement, mcpSocketPath,
					"MCP socket"));

		if (workDir.length > 0)
		{
			auto memoryDir = buildPath(workDir, ".cydo", "memory");
			mkdirRecurse(memoryDir);
			sandbox.paths.require(memoryDir, PathAccess.alwaysRw,
				SandboxPathOrigin(SandboxPathOriginKind.launchRequirement, memoryDir,
					"canonical memory"));
		}

		sandbox.sharedTmpPath = host_.resolveSharedTmpPath(tid);
		auto processLaunch = launchSandbox.prepareProcessLaunch(sandbox,
			nativeHistoryContext.rule, nativeHistoryContext.profile, chdir,
			taskAgent.executableName(sandbox.env));
		if (ownership == LaunchOwnership.task)
			td.launch = processLaunch;

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
		if (taskTypes.isInteractive(host_.taskTypeCatalog.getEntryPointsForProject(td.projectPath),
			td.taskType))
			sessionConfig.includeTools ~= "AskUserQuestion";
		sessionConfig.includeTools ~= "Ask";
		sessionConfig.includeTools ~= "Answer";
		if (typeDef !is null && typeDef.allow_native_subagents)
			sessionConfig.allowNativeSubagents = true;

		sessionConfig.permissionPolicy = host_.findWorkspacePermissionPolicy(td.workspace);
		if (sessionConfig.permissionPolicy.length > 0)
			sessionConfig.includeTools ~= "PermissionPrompt";

		RenderedCydoToolsOptions renderedToolOptions;
		renderedToolOptions.includeBash = taskAgent.needsBash();
		renderedToolOptions.includePermissionPrompt =
			sessionConfig.permissionPolicy.length > 0;
		host_.reportMcpToolDescriptionLimit(td.projectPath, td.taskType,
			checkRenderedCydoToolDescriptionViolations(taskTypes, entryPoints,
				td.taskType, options: renderedToolOptions));
		sessionConfig.agentName = td.agentName;

		return TaskSessionLaunch(processLaunch, sessionConfig);
	}

	void spawnTaskSession(int tid)
	{
		auto td = requireTask(tid, "Task must exist before spawning session");
		assert(td.taskType.length > 0,
			"Task must have a task_type before spawning session");
		td.wasKilledByUser = false;
		td.hadTurnResult = false;
		td.lastTurnFailed = false;
		td.stdinClosed = false;
		td.clearLastSessionStatus();
		td.compactionReminderInFlight = false;

		auto taskAgent = host_.agentForTask(tid);
		auto typeDef = currentTaskTypeDef(td);
		auto launch = prepareTaskSessionLaunch(tid, taskAgent, typeDef);
		td = requireTask(tid, "Task disappeared before session creation");
		auto session = taskAgent.createSession(tid, td.agentSessionId,
			launch.processLaunch, launch.sessionConfig);
		if (auto binding = tid in liveHistoryBindings_)
		{
			auto previous = tid in sessions_;
			if (previous is null || (*binding).owner is *previous)
				liveHistoryBindings_.remove(tid);
		}
		sessions_[tid] = session;
		host_.clearLastActive(tid);
		session.onNativeSessionStarted = (string sessionId) {
			enforce(sessionId.length > 0,
				"Native session lifecycle callback returned an empty session ID");
			auto current = host_.getTask(tid);
			if (current is null)
				return;
			auto mapped = tid in sessions_;
			enforce(mapped !is null && *mapped is session,
				"Native session lifecycle callback does not own the mapped session");
			if (current.agentSessionId.length > 0)
				enforce(current.agentSessionId == sessionId,
					"Resumed native session ID does not match the persisted task ID");
			else
			{
				current.agentSessionId = sessionId;
				host_.setAgentSessionId(tid, sessionId);
			}
			enforce(launch.processLaunch.nativeHistoryProfile.driver == taskAgent.driver,
				"Native session launch profile does not match the launch Agent");
			liveHistoryBindings_[tid] = LiveHistoryBinding(session, taskAgent,
				launch.processLaunch.nativeHistoryProfile, sessionId);
			if (!host_.shuttingDown())
				host_.startJsonlWatch(tid);
		};

		if (taskAgent.lastMcpConfigPath.length > 0)
			td.launch.sandbox.tempFiles ~= taskAgent.lastMcpConfigPath;

		session.onOutput = (TranslatedEvent ev) {
			auto stored = tid in sessions_;
			if (stored is null || *stored !is session)
				return;
			if (host_.shuttingDown())
				return;
			host_.broadcastTask(tid, ev);

			auto current = host_.getTask(tid);
			if (current is null)
			{
				host_.stopJsonlWatch(tid);
				liveHistoryBindings_.remove(tid);
				sessions_.remove(tid);
				return;
			}

			if (isAssistantTurnWork(ev))
			{
				bool processingChanged = !current.isProcessing;
				if (processingChanged)
					current.isProcessing = true;
				if (current.status == TaskStatus.waiting)
					host_.transitionTask(tid, TaskStatus.waiting, TaskStatus.active,
						TaskNotificationChange.preserve);
				else if (processingChanged)
					host_.publishTaskSnapshot(tid);
			}

			if (!taskAgent.isTurnResult(ev.translated))
				return;

			current = host_.getTask(tid);
			if (current is null)
			{
				host_.stopJsonlWatch(tid);
				liveHistoryBindings_.remove(tid);
				sessions_.remove(tid);
				return;
			}

			current.isProcessing = false;
			current.hadTurnResult = true;
			current.compactionReminderInFlight = false;

			if (!host_.shuttingDown())
				host_.startJsonlWatch(tid);
			if (!host_.shuttingDown())
				host_.broadcastHistoryOperations(tid);

			current = host_.getTask(tid);
			if (current is null)
			{
				host_.stopJsonlWatch(tid);
				liveHistoryBindings_.remove(tid);
				sessions_.remove(tid);
				return;
			}

			current.resultText = taskAgent.extractResultText(ev.translated);
			current.lastTurnFailed = isErrorTurnResult(ev.translated);

			bool hasOnYield = taskHasOnYield(current);
			if (host_.hasPendingSubTask(tid) || current.pendingContinuation !is null
				|| host_.hasTaskDependency(tid) || hasOnYield
				|| current.onIdleCallbacks.length > 0)
			{
				if (current.onIdleCallbacks.length > 0)
				{
					if (host_.drainIdleCallbacksForTurnResult(tid))
					{
						host_.publishTaskSnapshot(tid);
						return;
					}
				}
				else if (host_.hasPendingSubTask(tid))
				{
					// A terminally-errored turn must not finalize the sub-task
					// as a success; onExit delivers the failure instead.
					if (current.pendingContinuation is null && !hasOnYield
						&& !current.lastTurnFailed)
					{
						auto missingOutputs = host_.checkDeclaredOutputs(tid);
						if (missingOutputs is null)
							host_.finalizeCompletedSubTask(tid, true);
						else
							tracef("onOutput: tid=%d deferring sub-task finalization; %s",
								tid, missingOutputs);
					}
				}

				current = host_.getTask(tid);
				if (current is null)
					return;

				// After a terminal agent error, prodding the agent to answer a
				// pending child question would just fail again — close instead.
				bool hasPendingChildQuestion =
					current.pendingContinuation is null
					&& !current.lastTurnFailed
					&& host_.hasPendingChildQuestion(tid);

				if (hasPendingChildQuestion)
				{
					host_.sendPendingChildAnswerReminder(tid);
				}
				else
				{
					current.processQueue.setGoal(ProcessState.Dead).ignoreResult();
					session.closeStdin();
					session.killAfterTimeout(5.seconds);
				}
			}
			else
			{
				if (current.onIdleCallbacks.length > 0)
					host_.drainIdleCallbacksOnExit(tid);
				else if (host_.shuttingDown())
				{
					// The agent aborts its in-flight tool call when shutdown
					// closes stdin (Claude ≥2.1.2xx emits an error turn result).
					// Keep the persisted status as-is so the post-restart resume
					// still sees the task mid-turn and sends the restart nudge.
					return;
				}
				else
				{
					host_.onTaskTurnCompletedAlive(tid);
					return;
				}
			}

			host_.publishTaskSnapshot(tid);
		};

		string lastStderr;

		session.onStderr = (string line) {
			auto stored = tid in sessions_;
			if (stored is null || *stored !is session)
				return;
			if (host_.shuttingDown())
				return;
			ProcessStderrEvent ev;
			ev.text = line;
			host_.broadcastTask(tid, TranslatedEvent(toJson(ev), null));
			lastStderr = line;
		};

		session.onExit = (int exitCode) {
			auto stored = tid in sessions_;
			if (stored is null || *stored !is session)
				return;
			if (auto binding = tid in liveHistoryBindings_)
				enforce((*binding).owner is session,
					"Exiting session does not own its live history binding");
			if (host_.shuttingDown())
			{
				host_.stopJsonlWatch(tid);
				liveHistoryBindings_.remove(tid);
				sessions_.remove(tid);
				auto shutdownTask = host_.getTask(tid);
				if (shutdownTask !is null)
				{
					cleanupTaskLaunch(shutdownTask);
					shutdownTask.launch = ProcessLaunch.init;
				}
				return;
			}

			host_.touchAndPersistLastActive(tid);

			tracef("onExit: tid=%d exitCode=%d status=%s",
				tid, exitCode, currentStatusForLog(tid));

			auto current = host_.getTask(tid);
			if (current is null)
			{
				host_.stopJsonlWatch(tid);
				liveHistoryBindings_.remove(tid);
				sessions_.remove(tid);
				return;
			}

			ProcessExitEvent ev;
			ev.code = exitCode;

			auto onYieldDef = currentOnYieldDef(current);
			bool hasOnYield = onYieldDef !is null;
			auto cleanExit = (exitCode == 0 || current.pendingContinuation !is null || hasOnYield)
				&& !current.wasKilledByUser;
			if (cleanExit && (current.pendingContinuation !is null || hasOnYield))
				ev.is_continuation = true;
			if (!ev.is_continuation && host_.hasPendingChildQuestion(tid))
				ev.is_continuation = true;

			host_.broadcastTask(tid, TranslatedEvent(toJson(ev), null));

			current = host_.getTask(tid);
			if (current is null)
			{
				host_.stopJsonlWatch(tid);
				liveHistoryBindings_.remove(tid);
				sessions_.remove(tid);
				return;
			}

			current.isProcessing = false;
			current.stdinClosed = false;
			if (exitCode != 0 && current.status != TaskStatus.completed
				&& current.status != TaskStatus.failed)
				current.error = lastStderr;
			auto historyResolution = host_.ensureHistoryLoadedForExit(tid);
			host_.finalReconcileJsonlIfPresent(tid, historyResolution);
			host_.stopJsonlWatch(tid);
			repairInterruptedContinuationOnExit(tid, current, cleanExit);
			liveHistoryBindings_.remove(tid);
			sessions_.remove(tid);
			current = host_.getTask(tid);
			if (current is null)
				return;
			cleanupTaskLaunch(current);
			current.launch = ProcessLaunch.init;

			host_.failPendingAskUserQuestionOnExit(tid);
			host_.failPendingPermissionPromptOnExit(tid);
			host_.failPendingAskRouteOnExit(tid);
			host_.drainIdleCallbacksOnExit(tid);
			host_.cancelExitBackgroundWork(tid);

			bool missingExecutableLaunchFailure = exitCode != 0
				&& !current.hadTurnResult
				&& isMissingExecutableMessage(current.error);
			bool reloadEmitted;
			if (missingExecutableLaunchFailure)
			{
				reloadEmitted = host_.resetHistoryWatermarkOnly(tid);
				auto translated = host_.appendTaskDiagnostic(
					tid, "Failed to resume session",
					buildLaunchFailureBody(tid, current.error));
				host_.broadcastAppendedTaskEvent(tid, translated);
				host_.unsubscribeTaskHistorySubscribers(tid);
			}
			else if (current.undoStopInProgress)
				reloadEmitted = host_.resetHistoryWatermarkOnly(tid);
			else
				reloadEmitted = host_.resetHistoryWatermarkAfterExit(tid);

			current = host_.getTask(tid);
			if (current is null)
				return;

			current.recentNonces = null;
			current.clearSubmissionCorrelationState();

			auto ta = host_.tryAgentForTask(tid);
			bool intentionalExit = !missingExecutableLaunchFailure
				&& (current.processQueue.goalState != ProcessState.Alive
					|| (ta !is null && ta.driver == AgentDriver.codex && exitCode == 143));

			if (current.killPromise !is null)
			{
				auto promise = current.killPromise;
				current.killPromise = null;
				promise.fulfill(ProcessState.Dead);
			}
			else
			{
				if (!intentionalExit)
					current.processQueue.setGoal(ProcessState.Dead).ignoreResult();
				current.processQueue.setCurrentState(ProcessState.Dead);
			}

			if (current.undoStopInProgress)
			{
				current.undoStopInProgress = false;
				return;
			}

			if (!intentionalExit && current.status != TaskStatus.completed
				&& current.status != TaskStatus.failed)
			{
				if (current.error.length == 0)
					current.error = "Process exited unexpectedly";
				current.resultText = current.error;
				host_.persistResultText(tid, current.resultText);
				host_.transitionTaskFrom(tid,
					[TaskStatus.pending, TaskStatus.active, TaskStatus.alive,
						TaskStatus.waiting], TaskStatus.failed,
					TaskNotificationChange.preserve);
				if (current.relationType != "fork")
				{
					auto ancestor = host_.findAliveAncestor(tid);
					if (ancestor >= 0)
						host_.broadcastFocusHint(tid, ancestor);
				}
					if (!host_.deliverFailedPendingSubTaskResult(tid))
						observeWaitingParentDeliveryAttempt(tid,
							host_.deliverWaitingParentResultsIfReady(tid));
				return;
			}

			if (cleanExit && current.pendingContinuation !is null)
			{
				host_.spawnContinuation(tid);
				return;
			}

			if (hasOnYield && cleanExit)
			{
				infof("on_yield: tid=%d type=%s → %s",
					tid, current.taskType, onYieldDef.on_yield.task_type);
				host_.spawnOnYieldContinuation(tid);
				return;
			}

			bool consumerWaiting = host_.hasPendingSubTask(tid) || host_.hasTaskDependency(tid);
			if (cleanExit && consumerWaiting && !current.lastTurnFailed)
			{
				auto missing = host_.checkDeclaredOutputs(tid);
				if (missing !is null && !current.outputEnforcementAttempted)
				{
					current.outputEnforcementAttempted = true;
					infof("Output enforcement: tid=%d missing outputs, resuming: %s",
						tid, missing);
					host_.requestMissingOutputs(tid, missing);
					return;
				}
				if (missing !is null)
					warningf("Output enforcement: tid=%d still missing outputs after retry: %s",
						tid, missing);
			}

			bool deliveredPendingSubTask = false;
			bool statusWasAlreadyTarget;
			if (current.status == TaskStatus.completed)
				statusWasAlreadyTarget = true;
			else if (exitCode == 0 && !current.lastTurnFailed && host_.hasPendingSubTask(tid))
				deliveredPendingSubTask = host_.finalizeCompletedSubTask(tid, false);
			else
			{
				auto targetStatus = exitCode == 0 && !current.lastTurnFailed
					? TaskStatus.completed : TaskStatus.failed;
				host_.persistResultText(tid, current.resultText);
				if (current.status != targetStatus)
				{
					host_.transitionTaskFrom(tid,
						targetStatus == TaskStatus.completed
							? [TaskStatus.pending, TaskStatus.active, TaskStatus.alive,
								TaskStatus.waiting, TaskStatus.failed]
							: [TaskStatus.pending, TaskStatus.active, TaskStatus.alive,
								TaskStatus.waiting, TaskStatus.completed],
						targetStatus, TaskNotificationChange.preserve);
				}
				else
					statusWasAlreadyTarget = true;
				if (current.status != TaskStatus.completed)
					deliveredPendingSubTask = host_.deliverFailedPendingSubTaskResult(tid);
			}

			if (!deliveredPendingSubTask)
				observeWaitingParentDeliveryAttempt(tid,
					host_.deliverWaitingParentResultsIfReady(tid));

			if (!reloadEmitted)
				host_.emitTaskReload(tid);

			current = host_.getTask(tid);
			if (current is null)
				return;

			if (current.relationType != "fork")
			{
				auto ancestor = host_.findAliveAncestor(tid);
				if (ancestor >= 0)
					host_.broadcastFocusHint(tid, ancestor);
			}
			if (!deliveredPendingSubTask && statusWasAlreadyTarget)
				host_.publishTaskSnapshot(tid);
		};

		td.error = null;
		if (td.status == TaskStatus.pending)
			host_.transitionTask(tid, TaskStatus.pending, TaskStatus.active,
				TaskNotificationChange.preserve);
		else
			host_.publishTaskSnapshot(tid);
	}

	Promise!ProcessState delegate(ProcessState) makeProcessQueueSF(int tid)
	{
		return (ProcessState goal) => processTransition(tid, goal);
	}

	Promise!ProcessState processTransition(int tid, ProcessState goal)
	{
		auto td = host_.getTask(tid);
		if (td is null)
			return reject!ProcessState(new Exception("Task not found"));

		if (goal == ProcessState.Alive)
		{
			if (host_.shuttingDown())
				return reject!ProcessState(new Exception("Shutting down"));
			if (tid in forkSourceOperations_)
				return reject!ProcessState(new Exception(
					"Codex fork source operation is in progress"));
			try
				spawnTaskSession(tid);
			catch (Exception e)
			{
				td = requireTask(tid, "Task must exist when spawn fails");
				td.error = e.msg;
				td.resultText = e.msg;
				host_.persistResultText(tid, td.resultText);
				host_.transitionTaskFrom(tid,
					[TaskStatus.pending, TaskStatus.active, TaskStatus.alive,
						TaskStatus.waiting, TaskStatus.completed], TaskStatus.failed,
					TaskNotificationChange.preserve);
				auto translated = host_.appendTaskDiagnostic(
					tid, "Failed to resume session", buildLaunchFailureBody(tid, e));
				host_.broadcastAppendedTaskEvent(tid, translated);
				if (!host_.deliverFailedPendingSubTaskResult(tid))
					observeWaitingParentDeliveryAttempt(tid,
						host_.deliverWaitingParentResultsIfReady(tid));
				return reject!ProcessState(e);
			}
			return resolve(ProcessState.Alive);
		}

		if (!taskAlive(tid))
			return resolve(ProcessState.Dead);

		td.killPromise = new Promise!ProcessState;
		return td.killPromise;
	}

	void resumeInFlightTasks()
	{
		host_.loadPersistedTaskDeps();

		int[] toResume;
		foreach (tid; host_.snapshotTaskIds())
		{
			auto td = host_.getTask(tid);
			if (td is null)
				continue;
			if (td.status == "alive" || td.status == "active" || td.status == "waiting")
				toResume ~= tid;
		}

		if (toResume.length == 0)
			return;

		infof("Resuming %d in-flight task(s) after restart", toResume.length);

		foreach (i, tid; toResume)
		{
			auto td = host_.getTask(tid);
			if (td is null)
				continue;

			auto status = td.status;
			infof("Resuming session %d/%d (tid=%d, agent=%s, status=%s)",
				i + 1, toResume.length, tid, td.agentName, status);

			if (status == "waiting")
			{
				final switch (host_.waitingTaskDependencyState(tid))
				{
				case WaitingTaskDependencyState.noChildren:
					tracef("resumeInFlightTasks: tid=%d waiting, no children — resuming with restart nudge",
						tid);
					resumeActiveTask(tid);
					break;
				case WaitingTaskDependencyState.allChildrenTerminal:
					tracef("resumeInFlightTasks: tid=%d waiting, all children terminal — resuming with batch delivery",
						tid);
					resumeAndDeliverResults(tid);
					break;
				case WaitingTaskDependencyState.hasNonTerminalChildren:
					tracef("resumeInFlightTasks: tid=%d waiting, nonterminal children — resuming without message",
						tid);
					resumeWaitingTask(tid);
					break;
				}
			}
			else if (status == "active")
			{
				resumeActiveTask(tid);
			}
			else if (status == "alive")
			{
				if (td.turnOpen)
				{
					// killed mid-turn: the status snapshot can miss this (a
					// turn started by the agent itself, e.g. a background-task
					// notification, never passes through a send that marks the
					// task active), but the persisted turn witness cannot
					infof("resumeInFlightTasks: tid=%d transcript ends mid-turn, resuming with restart nudge",
						tid);
					resumeActiveTask(tid);
				}
				else
					resumeTask(tid).ignoreResult();
			}
		}
	}

	Promise!void resumeTask(int tid)
	{
		auto td = host_.getTask(tid);
		if (td is null)
			return resolve();

		return td.processQueue.setGoal(ProcessState.Alive).then(() {
			auto current = host_.getTask(tid);
			if (current is null)
				return;
		});
	}

	void resumeAndDeliverResults(int tid)
	{
		observeRecoveryAttempt(tid, resumeTask(tid).then(() {
			return host_.deliverBatchResults(tid);
		}));
	}

	void resumeWaitingTask(int tid)
	{
		resumeTask(tid).ignoreResult();
	}

	void resumeActiveTask(int tid)
	{
		observeRecoveryAttempt(tid, resumeTask(tid).then(() {
			return host_.sendSystemRestartNudge(tid);
		}));
	}

private:
	void observeWaitingParentDeliveryAttempt(int childTid, Promise!void attempt)
	{
		requireTask(childTid,
			"Completed child task must exist while observing recovered delivery");
		auto ownerTid = host_.parentTaskForChild(childTid);
		if (ownerTid <= 0)
			ownerTid = childTid;
		observeRecoveryAttempt(ownerTid, attempt);
	}

	void observeRecoveryAttempt(int tid, Promise!void attempt)
	{
		attempt.then({}, (Exception e) {
			auto current = host_.getTask(tid);
			assert(current !is null,
				"Recovered delivery attempt rejected after its task disappeared");
			if (current.status == TaskStatus.active || current.status == TaskStatus.alive)
				host_.transitionTaskFrom(tid,
					[TaskStatus.active, TaskStatus.alive], TaskStatus.waiting,
					TaskNotificationChange.preserve);
			assert(current.status == TaskStatus.waiting
				|| current.status == TaskStatus.failed,
				"Recovered delivery rejection escaped its process owner state");
		}).ignoreResult();
	}

	TaskData* requireTask(int tid, string message)
	{
		auto td = host_.getTask(tid);
		assert(td !is null, message);
		return td;
	}

	TaskTypeDef* currentTaskTypeDef(const TaskData* td)
	{
		return host_.taskTypeCatalog.getTaskTypesForProject(td.projectPath)
			.byName(td.taskType);
	}

	TaskTypeDef* currentOnYieldDef(const TaskData* td)
	{
		if (td.pendingContinuation !is null)
			return null;
		auto typeDef = currentTaskTypeDef(td);
		if (typeDef is null || typeDef.on_yield.task_type.length == 0)
			return null;
		return typeDef;
	}

	bool taskHasOnYield(const TaskData* td)
	{
		return currentOnYieldDef(td) !is null;
	}

	private void repairInterruptedContinuationOnExit(int tid, TaskData* current,
		bool cleanExit)
	{
		auto pc = current.pendingContinuation;
		if (!cleanExit || pc is null || pc.resultText.length == 0)
			return;

		// Must run while the live binding still exists (before it is removed
		// below): the repair needs the exact agent/profile/cwd this session
		// was launched with, not a freshly re-resolved one.
		auto binding = tid in liveHistoryBindings_;
		if (binding is null || (*binding).sessionId.length == 0)
			return;

		string toolName;
		final switch (pc.kind)
		{
		case PendingContinuation.Kind.switchMode:
			toolName = "mcp__cydo__SwitchMode";
			break;
		case PendingContinuation.Kind.handoff:
			toolName = "mcp__cydo__Handoff";
			break;
		}

		pc.repairedInterruptionUuid = repairInterruptedToolCallFile(
			(*binding).agent.historyPath((*binding).sessionId, (*binding).profile),
			&(*binding).agent.repairInterruptedToolCall, toolName, pc.resultText);
	}

	void cleanupTaskLaunch(TaskData* td)
	{
		import cydo.runtime.launch.sandbox : cleanup;

		cleanup(td.launch.sandbox);
	}

	string currentStatusForLog(int tid)
	{
		auto td = host_.getTask(tid);
		return td is null ? "(gone)" : td.status;
	}

	bool isMissingExecutableMessage(string message)
	{
		import std.algorithm : canFind;

		return message.canFind("No such file") || message.canFind("not found");
	}

	string buildLaunchFailureBody(int tid, string message)
	{
		import std.conv : to;
		import std.string : toUpper;

		auto td = requireTask(tid, "Task must exist while rendering launch failure");
		if (isMissingExecutableMessage(message))
		{
			auto ta = host_.tryAgentForTask(tid);
			string binEnvVar;
			string installHint;
			if (ta is null)
			{
				binEnvVar = "CYDO_" ~ td.agentName.toUpper ~ "_BIN";
				installHint = "the appropriate package for your agent";
			}
			else
			{
				binEnvVar = "CYDO_" ~ to!string(ta.driver).toUpper ~ "_BIN";
				final switch (ta.driver)
				{
				case AgentDriver.claude:
					installHint = "`npm install -g @anthropic-ai/claude-code`";
					break;
				case AgentDriver.codex:
					installHint = "`npm install -g @openai/codex`";
					break;
				case AgentDriver.copilot:
					installHint = "the appropriate package for your agent";
					break;
				}
			}
			return "The **`" ~ td.agentName ~ "`** CLI was not found on `PATH`.\n\n"
				~ "Install it (e.g. via " ~ installHint ~ ") or set the `"
				~ binEnvVar ~ "` environment variable to its absolute path, "
				~ "then click **Resume** again.";
		}

		return "Failed to resume session.\n\n```\n"
			~ message ~ "\n```";
	}

	string buildLaunchFailureBody(int tid, Exception e)
	{
		return buildLaunchFailureBody(tid,
			e.classinfo.name ~ ": " ~ e.msg);
	}
}

unittest
{
	import ae.net.asockets : socketManager;

	void drainRecoveryNextTicks()
	{
		for (;;)
		{
			auto handlers = __traits(getMember, socketManager,
				"nextTickHandlers");
			if (handlers.length == 0)
				return;
			mixin(`__traits(getMember, socketManager, "nextTickHandlers") = null;`);
			foreach (handler; handlers)
				handler();
		}
	}

	enum dependencyOwnerTid = 1;
	enum handoffPredecessorTid = 2;
	enum handoffSuccessorTid = 3;
	TaskData[int] tasks;
	foreach (tid; [dependencyOwnerTid, handoffPredecessorTid, handoffSuccessorTid])
		tasks[tid] = TaskData(tid, "local", "/tmp/cydo-handoff-recovery-owner");
	tasks[dependencyOwnerTid].status = TaskStatus.waiting;
	tasks[dependencyOwnerTid].resultText = "existing failed result";
	tasks[handoffPredecessorTid].status = TaskStatus.completed;
	tasks[handoffSuccessorTid].status = TaskStatus.completed;
	tasks[handoffSuccessorTid].parentTid = handoffPredecessorTid;

	int[int] persistedDependencyOwners;
	int[int] runtimeDependencyOwners;
	persistedDependencyOwners[handoffSuccessorTid] = dependencyOwnerTid;
	runtimeDependencyOwners[handoffSuccessorTid] = dependencyOwnerTid;
	int ownerLookups;
	int transitionCalls;
	int resultWrites;
	int diagnosticCalls;
	auto runner = new TaskSessionRunner(TaskSessionRunnerHost(
		getTask: (int tid) {
			auto task = tid in tasks;
			return task is null ? null : &tasks[tid];
		},
		parentTaskForChild: (int childTid) {
			ownerLookups++;
			assert(childTid == handoffSuccessorTid);
			auto persistedOwner = childTid in persistedDependencyOwners;
			auto runtimeOwner = childTid in runtimeDependencyOwners;
			assert(persistedOwner !is null && runtimeOwner !is null);
			assert(*persistedOwner == dependencyOwnerTid
				&& *runtimeOwner == dependencyOwnerTid);
			return *runtimeOwner;
		},
		transitionTaskFrom: (int tid, TaskStatus[] expectedFrom, TaskStatus to,
			TaskNotificationChange notification) { transitionCalls++; },
		persistResultText: (int tid, string resultText) { resultWrites++; },
		appendTaskDiagnostic: (int tid, string subject, string body) {
			diagnosticCalls++;
			return "";
		},
	));

	Promise!void recoveredDeliveryAttempt()
	{
		assert(tasks[dependencyOwnerTid].status == TaskStatus.waiting);
		tasks[dependencyOwnerTid].status = TaskStatus.failed;
		return reject!void(new Exception(
			"simulated recovered delivery activation failure"));
	}

	runner.observeWaitingParentDeliveryAttempt(handoffSuccessorTid,
		recoveredDeliveryAttempt());
	drainRecoveryNextTicks();

	assert(ownerLookups == 1);
	assert(tasks[dependencyOwnerTid].status == TaskStatus.failed
		&& tasks[dependencyOwnerTid].resultText == "existing failed result");
	assert(tasks[handoffPredecessorTid].status == TaskStatus.completed);
	assert(tasks[handoffSuccessorTid].status == TaskStatus.completed
		&& tasks[handoffSuccessorTid].parentTid == handoffPredecessorTid);
	assert(transitionCalls == 0 && resultWrites == 0 && diagnosticCalls == 0);
}

version (unittest) private final class LinkedWorktreeSandboxTestAgent : ClaudeCodeAgent
{
	override string executableName(string[string] env)
	{
		return "/bin/true";
	}
}

version (unittest) private void assertLinkedWorktreeGitMetadataMode(
	string fixtureName, string taskTypeName, PathMode expectedMode,
	bool projectIsMasked = false)
{
	withGitMetadataLaunchFixture(fixtureName,
		(GitMetadataLaunchFixture fixture) {
			auto catalog = gitMetadataTaskCatalog(fixture,
				"task_types:\n"
				~ "  writable:\n"
				~ "    model_class: large\n"
				~ "  readonly:\n"
				~ "    model_class: large\n"
				~ "    read_only: true\n");
			auto taskTypes = catalog.getTaskTypesForProject(fixture.linkedCheckout);
			auto reachesWorktree = catalog.reachesWorktreeFor(fixture.linkedCheckout);
			assert(reachesWorktree !is null);
			assert(!reachesWorktree["writable"]);
			assert(!reachesWorktree["readonly"]);

			TaskData[int] tasks;
			tasks[1] = TaskData(1, "local", fixture.linkedCheckout);
			tasks[1].taskType = taskTypeName;
			tasks[1].agentName = "claude";
			assert(!tasks[1].hasWorktree);

			auto workspaceSandbox = unrestrictedLaunchTestSandbox();
			if (projectIsMasked)
				workspaceSandbox.paths[fixture.linkedCheckout] = expectedMode;

			auto runner = gitMetadataTestRunner(&tasks, catalog, fixture,
				workspaceSandbox, "", fixture.linkedCheckout);
			auto typeDef = taskTypes.byName(taskTypeName);
			assert(typeDef !is null);
			auto launch = runner.prepareTaskSessionLaunch(1,
				new LinkedWorktreeSandboxTestAgent(), typeDef);
			auto projectMode = launch.processLaunch.sandbox.paths.exact(fixture.linkedCheckout);
			auto gitDirMode = launch.processLaunch.sandbox.paths.exact(fixture.linkedGitDir);
			auto gitCommonDirMode = launch.processLaunch.sandbox.paths.exact(fixture.commonGitDir);
			assert(!projectMode.isNull, "linked worktree checkout is not mounted");
			assert(projectMode.get.effectiveMode == expectedMode);
			if (projectIsMasked)
			{
				assert(gitDirMode.isNull, "masked checkout granted its git dir");
				assert(gitCommonDirMode.isNull, "masked checkout granted its common git dir");
			}
			else
			{
				assert(!gitDirMode.isNull, "linked worktree git dir is not mounted");
				assert(!gitCommonDirMode.isNull, "linked worktree common git dir is not mounted");
				assert(gitDirMode.get.effectiveMode == projectMode.get.effectiveMode);
				assert(gitCommonDirMode.get.effectiveMode == projectMode.get.effectiveMode);
			}
		});
}

unittest
{
	assertLinkedWorktreeGitMetadataMode(
		"cydo-task-runner-linked-worktree-writable", "writable", PathMode.rw);
}

unittest
{
	assertLinkedWorktreeGitMetadataMode(
		"cydo-task-runner-linked-worktree-readonly", "readonly", PathMode.ro);
}

unittest
{
	assertLinkedWorktreeGitMetadataMode(
		"cydo-task-runner-linked-worktree-tmpfs", "writable", PathMode.tmpfs, true);
}

unittest
{
	assertLinkedWorktreeGitMetadataMode(
		"cydo-task-runner-linked-worktree-empty-dir", "writable", PathMode.empty_dir, true);
}

unittest
{
	assertLinkedWorktreeGitMetadataMode(
		"cydo-task-runner-linked-worktree-empty-file", "writable", PathMode.empty_file, true);
}

version (unittest) private struct GitMetadataLaunchFixture
{
	string root;
	string workspaceRoot;
	string primaryRepo;
	string linkedCheckout;
	string linkedGitDir;
	string commonGitDir;
}

version (unittest) private void withGitMetadataLaunchFixture(string fixtureName,
	void delegate(GitMetadataLaunchFixture fixture) test)
{
	import std.file : exists, mkdirRecurse, rmdirRecurse, write;
	import std.process : environment;

	auto root = buildPath("/tmp", fixtureName);
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);

	auto oldHome = environment.get("HOME", "");
	auto hadHome = "HOME" in environment;
	scope (exit)
	{
		if (hadHome)
			environment["HOME"] = oldHome;
		else
			environment.remove("HOME");
	}
	environment["HOME"] = buildPath(root, "home");

	auto workspaceRoot = buildPath(root, "workspace");
	auto primaryRepo = buildPath(workspaceRoot, "primary");
	auto linkedCheckout = buildPath(workspaceRoot, "linked");
	mkdirRecurse(primaryRepo);
	assert(execute(["git", "-C", primaryRepo, "init", "-q"]).status == 0);
	assert(execute(["git", "-C", primaryRepo, "config", "user.email", "test@example.com"])
		.status == 0);
	assert(execute(["git", "-C", primaryRepo, "config", "user.name", "CyDo Test"])
		.status == 0);
	write(buildPath(primaryRepo, "README.md"), "linked worktree fixture\n");
	assert(execute(["git", "-C", primaryRepo, "add", "README.md"]).status == 0);
	assert(execute(["git", "-C", primaryRepo, "commit", "-qm", "initial fixture"])
		.status == 0);
	assert(execute(["git", "-C", primaryRepo, "worktree", "add", "--detach", linkedCheckout])
		.status == 0);

	string gitPath(string checkoutPath, string flag)
	{
		auto result = execute(["git", "-C", checkoutPath, "rev-parse",
			"--path-format=absolute", flag]);
		assert(result.status == 0, result.output);
		return result.output.strip;
	}

	GitMetadataLaunchFixture fixture;
	fixture.root = root;
	fixture.workspaceRoot = workspaceRoot;
	fixture.primaryRepo = primaryRepo;
	fixture.linkedCheckout = linkedCheckout;
	fixture.linkedGitDir = gitPath(linkedCheckout, "--git-dir");
	fixture.commonGitDir = gitPath(linkedCheckout, "--git-common-dir");
	assert(fixture.linkedGitDir != fixture.commonGitDir);
	assert(fixture.commonGitDir == buildPath(primaryRepo, ".git"));
	test(fixture);
}

version (unittest) private TaskTypeCatalog gitMetadataTaskCatalog(
	GitMetadataLaunchFixture fixture, string yaml)
{
	import std.file : mkdirRecurse, write;

	auto defsDir = buildPath(fixture.root, "defs");
	mkdirRecurse(buildPath(defsDir, "prompts"));
	write(buildPath(defsDir, "prompts", "blank.md"), "Blank prompt\n");
	write(buildPath(defsDir, "task-types.yaml"), yaml);
	return new TaskTypeCatalog(defsDir, buildPath(defsDir, "task-types.yaml"),
		(string name) => name == "claude");
}

version (unittest) private SandboxConfig unrestrictedLaunchTestSandbox()
{
	import configy.attributes : SetInfo;

	return SandboxConfig(
		isolate_filesystem: SetInfo!bool(false),
		isolate_processes: SetInfo!bool(false),
		isolate_environment: SetInfo!bool(false),
	);
}

version (unittest) private TaskSessionRunner gitMetadataTestRunner(
	TaskData[int]* tasks, TaskTypeCatalog catalog, GitMetadataLaunchFixture fixture,
	SandboxConfig workspaceSandbox, string worktreePath, string taskCwd,
	string mcpSocketPath = "", string taskDirPath = "")
{
	import configy.attributes : SetInfo;
	import cydo.runtime.config : AgentConfig, WorkspaceConfig;

	auto config = new CydoConfig;
	config.sandbox = unrestrictedLaunchTestSandbox();
	AgentConfig configuredAgent;
	configuredAgent.driver = SetInfo!AgentDriver(AgentDriver.claude, true);
	configuredAgent.sandbox = unrestrictedLaunchTestSandbox();
	configuredAgent.sandbox.env = [
		"HOME": buildPath(fixture.root, "home"),
		"CLAUDE_CONFIG_DIR": buildPath(fixture.root, "claude-profile"),
	];
	config.agents["claude"] = configuredAgent;
	config.workspaces = [WorkspaceConfig(name: "local", root: fixture.workspaceRoot,
		sandbox: workspaceSandbox)];

	return new TaskSessionRunner(TaskSessionRunnerHost(
		getTask: (int tid) {
			auto task = tid in *tasks;
			return task is null ? null : &(*tasks)[tid];
		},
		taskDir: (const TaskData* td) => taskDirPath.length > 0
			? taskDirPath : buildPath(fixture.root, "tasks", "task"),
		outputPath: (const TaskData* td) => taskDirPath.length > 0
			? buildPath(taskDirPath, "output.md")
			: buildPath(fixture.root, "tasks", "task", "output.md"),
		effectiveCwd: (const TaskData* td) => taskCwd,
		worktreePath: (const TaskData* td) => worktreePath,
		currentConfig: () => config,
		findWorkspacePermissionPolicy: (string workspaceName) => "",
		reportMcpToolDescriptionLimit: (string projectPath, string taskType,
			ToolDescriptionViolation[] violations) {},
		resolveSharedTmpPath: (int tid) => "",
		mcpSocketPath: () => mcpSocketPath,
		taskTypeCatalog: catalog,
	));
}

unittest
{
	withGitMetadataLaunchFixture("cydo-task-runner-operation-launch",
		(GitMetadataLaunchFixture fixture) {
			auto catalog = gitMetadataTaskCatalog(fixture,
				"task_types:\n"
				~ "  operation:\n"
				~ "    model_class: large\n");
			TaskData[int] tasks;
			tasks[1] = TaskData(1, "local", fixture.linkedCheckout);
			tasks[1].taskType = "operation";
			tasks[1].agentName = "claude";
			auto runner = gitMetadataTestRunner(&tasks, catalog, fixture,
				unrestrictedLaunchTestSandbox(), "", fixture.linkedCheckout);
			auto typeDef = catalog.getTaskTypesForProject(fixture.linkedCheckout)
				.byName("operation");
			auto launch = runner.prepareOperationSessionLaunch(1,
				new LinkedWorktreeSandboxTestAgent(), typeDef);
			assert(tasks[1].launch.nativeHistoryProfile.root.length == 0);
			assert(launch.processLaunch.nativeHistoryProfile.root.length > 0);
			launchSandbox.cleanup(launch.processLaunch.sandbox);
		});
}

// A legacy task that has an agent session but no project path (and no
// worktree) has no effective CWD; history resolution must still locate the
// session by ID via the profile scan.
unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse, write;
	import configy.attributes : SetInfo;
	import cydo.runtime.config : AgentConfig;

	auto root = buildPath("/tmp", "cydo-task-runner-legacy-no-cwd");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	auto defsDir = buildPath(root, "defs");
	mkdirRecurse(buildPath(defsDir, "prompts"));
	write(buildPath(defsDir, "prompts", "blank.md"), "Blank prompt\n");
	write(buildPath(defsDir, "task-types.yaml"),
		"task_types:\n  conversation:\n    model_class: large\n");
	auto catalog = new TaskTypeCatalog(defsDir, buildPath(defsDir, "task-types.yaml"),
		(string name) => name == "claude");

	auto config = new CydoConfig;
	config.sandbox = unrestrictedLaunchTestSandbox();
	AgentConfig configuredAgent;
	configuredAgent.driver = SetInfo!AgentDriver(AgentDriver.claude, true);
	configuredAgent.sandbox = unrestrictedLaunchTestSandbox();
	configuredAgent.sandbox.env = [
		"HOME": buildPath(root, "home"),
		"CLAUDE_CONFIG_DIR": buildPath(root, "claude-profile"),
	];
	config.agents["claude"] = configuredAgent;

	TaskData[int] tasks;
	tasks[1] = TaskData(1, "", "");
	tasks[1].taskType = "conversation";
	tasks[1].agentName = "claude";
	tasks[1].agentSessionId = "faafb5bd-2017-4d88-9ce7-03e1dcce30c9";

	auto projectDir = buildPath(root, "claude-profile", "projects",
		"-some-legacy-project");
	mkdirRecurse(projectDir);
	auto historyFile = buildPath(projectDir,
		tasks[1].agentSessionId ~ ".jsonl");
	write(historyFile, "{\"type\":\"user\"}\n");

	Agent agent = new ClaudeCodeAgent();
	auto runner = new TaskSessionRunner(TaskSessionRunnerHost(
		getTask: (int tid) {
			auto task = tid in tasks;
			return task is null ? null : &tasks[tid];
		},
		effectiveCwd: (const TaskData* td) => td.effectiveCwd(""),
		currentConfig: () => config,
		tryAgentForTask: (int tid) => agent,
		taskTypeCatalog: catalog,
	));

	auto resolution = runner.resolveTaskHistory(1);
	assert(resolution.kind == TaskHistoryResolutionKind.access);
	auto access = resolution.requireAccess();
	assert(access.sessionId == tasks[1].agentSessionId);
	assert(access.path == historyFile);
}

version (unittest) private void assertRunnerMcpConfigCleanup(
	string fixtureName, string agentName, string executableEnvName, Agent agent)
{
	import ae.net.asockets : socketManager;
	import ae.utils.statequeue : StateQueue;
	import configy.attributes : SetInfo;
	import std.algorithm : canFind;
	import std.file : exists, write;
	import cydo.runtime.config : AgentConfig, WorkspaceConfig;

	withGitMetadataLaunchFixture(fixtureName,
		(GitMetadataLaunchFixture fixture) {
			auto profileRoot = buildPath(fixture.root, agentName ~ "-profile");
			auto executable = buildPath(fixture.root, agentName ~ "-blocking-agent");
			write(executable,
				"#!/bin/sh\n"
				~ "while IFS= read -r line; do :; done\n");
			assert(execute(["chmod", "+x", executable]).status == 0);

			auto catalog = gitMetadataTaskCatalog(fixture,
				"task_types:\n"
				~ "  runner:\n"
				~ "    model_class: large\n");
			auto mcpSocket = buildPath(fixture.root, "mcp.sock");
			write(mcpSocket, "");

			auto config = new CydoConfig;
			config.sandbox = unrestrictedLaunchTestSandbox();
			AgentConfig configuredAgent;
			configuredAgent.driver = SetInfo!AgentDriver(agent.driver, true);
			configuredAgent.sandbox = unrestrictedLaunchTestSandbox();
			configuredAgent.sandbox.env["HOME"] = buildPath(fixture.root, "agent-home");
			configuredAgent.sandbox.env[agent.nativeHistoryRule.profileEnvName] = profileRoot;
			configuredAgent.sandbox.env[executableEnvName] = executable;
			config.agents[agentName] = configuredAgent;
			config.workspaces = [WorkspaceConfig(name: "local", root: fixture.workspaceRoot,
				sandbox: unrestrictedLaunchTestSandbox())];

			TaskData[int] tasks;
			tasks[1] = TaskData(1, "local", fixture.linkedCheckout);
			tasks[1].taskType = "runner";
			tasks[1].agentName = agentName;
			auto taskDir = buildPath(fixture.root, "tasks", "task");
			auto runner = new TaskSessionRunner(TaskSessionRunnerHost(
				getTask: (int tid) {
					auto task = tid in tasks;
					return task is null ? null : &tasks[tid];
				},
				taskDir: (const TaskData* td) => taskDir,
				outputPath: (const TaskData* td) => buildPath(taskDir, "output.md"),
				effectiveCwd: (const TaskData* td) => fixture.linkedCheckout,
				worktreePath: (const TaskData* td) => "",
				currentConfig: () => config,
				findWorkspacePermissionPolicy: (string workspaceName) => "",
				reportMcpToolDescriptionLimit: (string projectPath, string taskType,
					ToolDescriptionViolation[] violations) {},
				resolveSharedTmpPath: (int tid) => "",
					mcpSocketPath: () => mcpSocket,
					agentForTask: (int tid) => agent,
					tryAgentForTask: (int tid) => agent,
					setAgentSessionId: (int tid, string sessionId) {
						tasks[tid].agentSessionId = sessionId;
					},
					clearLastActive: (int tid) {},
				broadcastTask: (int tid, TranslatedEvent event) {},
				publishTaskSnapshot: (int tid) {},
				hasPendingSubTask: (int tid) => false,
				hasTaskDependency: (int tid) => false,
				hasPendingChildQuestion: (int tid) => false,
				touchAndPersistLastActive: (int tid) {},
					ensureHistoryLoadedForExit: (int tid) => Nullable!TaskHistoryResolution.init,
					finalReconcileJsonlIfPresent: (int tid, Nullable!TaskHistoryResolution) {},
					startJsonlWatch: (int tid) {},
					stopJsonlWatch: (int tid) {},
				failPendingAskUserQuestionOnExit: (int tid) {},
				failPendingPermissionPromptOnExit: (int tid) {},
				failPendingAskRouteOnExit: (int tid) {},
				drainIdleCallbacksOnExit: (int tid) {},
				cancelExitBackgroundWork: (int tid) {},
				resetHistoryWatermarkAfterExit: (int tid) => false,
				parentTaskForChild: (int childTid) => 0,
				deliverWaitingParentResultsIfReady: (int tid) => resolve(),
				persistResultText: (int tid, string resultText) {},
				transitionTask: (int tid, TaskStatus expectedFrom, TaskStatus to,
					TaskNotificationChange notification) {
					assert(tasks[tid].status == expectedFrom);
					tasks[tid].status = to;
				},
				transitionTaskFrom: (int tid, TaskStatus[] expectedFrom, TaskStatus to,
					TaskNotificationChange notification) {
					tasks[tid].status = to;
				},
				emitTaskReload: (int tid) {},
				findAliveAncestor: (int tid) => -1,
				shuttingDown: () => false,
				taskTypeCatalog: catalog,
			));
			tasks[1].processQueue = new StateQueue!ProcessState(
				(ProcessState state) => resolve(state), ProcessState.Dead);

			runner.spawnTaskSession(1);
			auto configPath = buildPath(profileRoot, "mcp-configs", "cydo-1.json");
			assert(tasks[1].launch.nativeHistoryProfile.root == profileRoot);
			assert(agent.lastMcpConfigPath == configPath);
			assert(exists(configPath));
			assert(tasks[1].launch.sandbox.tempFiles.canFind(configPath));

			runner.closeTaskStdin(1);
			socketManager.loop();

			assert(runner.sessionForTask(1) is null);
			assert(!exists(configPath));
			assert(tasks[1].launch.sandbox.tempFiles.length == 0);
		});
}

unittest
{
	assertRunnerMcpConfigCleanup("cydo-task-runner-claude-mcp-cleanup", "claude",
		"CYDO_CLAUDE_BIN", new ClaudeCodeAgent());
}

unittest
{
	assertRunnerMcpConfigCleanup("cydo-task-runner-copilot-mcp-cleanup", "copilot",
		"CYDO_COPILOT_BIN", new CopilotAgent());
}

unittest
{
	import std.file : mkdirRecurse, write;

	withGitMetadataLaunchFixture("cydo-task-runner-registry-requirements",
		(GitMetadataLaunchFixture fixture) {
			auto catalog = gitMetadataTaskCatalog(fixture,
				"task_types:\n"
				~ "  writable:\n"
				~ "    model_class: large\n"
				~ "  readonly:\n"
				~ "    model_class: large\n"
				~ "    read_only: true\n");
			auto taskTypes = catalog.getTaskTypesForProject(fixture.linkedCheckout);
			auto writableDef = taskTypes.byName("writable");
			auto readonlyDef = taskTypes.byName("readonly");
			assert(writableDef !is null);
			assert(readonlyDef !is null);

			auto mcpSocket = buildPath(fixture.root, "mcp.sock");
			write(mcpSocket, "");
			TaskData[int] tasks;
			tasks[1] = TaskData(1, "local", fixture.linkedCheckout);
			tasks[1].taskType = "writable";
			tasks[1].agentName = "claude";
			auto runner = gitMetadataTestRunner(&tasks, catalog, fixture,
				unrestrictedLaunchTestSandbox(), "", fixture.linkedCheckout, mcpSocket);
			auto writable = runner.prepareTaskSessionLaunch(1,
				new LinkedWorktreeSandboxTestAgent(), writableDef);
			auto writablePaths = writable.processLaunch.sandbox.paths;
			auto profileRoot = buildPath(fixture.root, "claude-profile");
			auto configuredHome = buildPath(fixture.root, "home");
			auto taskDir = buildPath(fixture.root, "tasks", "task");
			auto taskRoot = dirName(taskDir);
			auto memory = buildPath(fixture.linkedCheckout, ".cydo", "memory");
			assert(writable.processLaunch.nativeHistoryProfile.driver == AgentDriver.claude);
			assert(writable.processLaunch.nativeHistoryProfile.root == profileRoot);
			assert(writable.processLaunch.preProfileSandbox.paths.exact(profileRoot).isNull);
			assert(writablePaths.exact(profileRoot).get.effectiveMode == PathMode.rw);
			assert(writablePaths.exact(buildPath(configuredHome, ".claude.json"))
				.get.effectiveMode == PathMode.rw);
			assert(writablePaths.exact(buildPath(configuredHome, ".local", "share", "claude"))
				.get.effectiveMode == PathMode.ro);
			assert(writablePaths.exact(fixture.linkedCheckout).get.effectiveMode == PathMode.rw);
			assert(writablePaths.exact(fixture.linkedGitDir).get.effectiveMode == PathMode.rw);
			assert(writablePaths.exact(fixture.commonGitDir).get.effectiveMode == PathMode.rw);
			assert(writablePaths.exact(taskDir).get.effectiveMode == PathMode.rw);
			assert(writablePaths.exact(taskRoot).get.effectiveMode == PathMode.ro);
			assert(writablePaths.exact(mcpSocket).get.effectiveMode == PathMode.ro);
			assert(writablePaths.exact(memory).get.effectiveMode == PathMode.always_rw);
			assert(!writablePaths.exact(taskDir).get.requirement.isNull);
			assert(!writablePaths.exact(taskRoot).get.requirement.isNull);
			assert(!writablePaths.exact(mcpSocket).get.requirement.isNull);
			assert(!writablePaths.exact(memory).get.requirement.isNull);

			auto managedCheckout = buildPath(fixture.workspaceRoot, "readonly-managed");
			assert(execute(["git", "-C", fixture.primaryRepo, "worktree", "add", "--detach",
				managedCheckout]).status == 0);
			auto managedGitDir = execute(["git", "-C", managedCheckout, "rev-parse",
				"--path-format=absolute", "--git-dir"]);
			assert(managedGitDir.status == 0, managedGitDir.output);

			TaskData[int] readonlyTasks;
			readonlyTasks[1] = TaskData(1, "local", fixture.linkedCheckout);
			readonlyTasks[1].taskType = "readonly";
			readonlyTasks[1].agentName = "claude";
			readonlyTasks[1].worktreeTid = 1;
			auto readonlyRunner = gitMetadataTestRunner(&readonlyTasks, catalog, fixture,
				unrestrictedLaunchTestSandbox(), managedCheckout, managedCheckout, mcpSocket);
			auto readonly = readonlyRunner.prepareTaskSessionLaunch(1,
				new LinkedWorktreeSandboxTestAgent(), readonlyDef);
			auto readonlyPaths = readonly.processLaunch.sandbox.paths;
			assert(readonlyPaths.exact(fixture.linkedCheckout).get.effectiveMode == PathMode.ro);
			assert(readonlyPaths.exact(fixture.linkedGitDir).get.effectiveMode == PathMode.ro);
			assert(readonlyPaths.exact(managedCheckout).get.effectiveMode == PathMode.ro);
			assert(readonlyPaths.exact(managedGitDir.output.strip).get.effectiveMode == PathMode.ro);
			assert(readonlyPaths.exact(fixture.commonGitDir).get.effectiveMode == PathMode.ro);
			assert(readonlyPaths.exact(taskDir).get.effectiveMode == PathMode.rw);
			assert(readonlyPaths.exact(taskRoot).get.effectiveMode == PathMode.ro);
			assert(readonlyPaths.exact(mcpSocket).get.effectiveMode == PathMode.ro);
			assert(readonlyPaths.exact(memory).get.effectiveMode == PathMode.always_rw);
		});
}

unittest
{
	import std.algorithm : canFind;
	import std.file : write;

	withGitMetadataLaunchFixture("cydo-task-runner-registry-conflicts",
		(GitMetadataLaunchFixture fixture) {
			auto catalog = gitMetadataTaskCatalog(fixture,
				"task_types:\n"
				~ "  writable:\n"
				~ "    model_class: large\n");
			auto typeDef = catalog.getTaskTypesForProject(fixture.linkedCheckout)
				.byName("writable");
			assert(typeDef !is null);
			auto memory = buildPath(fixture.linkedCheckout, ".cydo", "memory");

			foreach (mode; [PathMode.ro, PathMode.tmpfs])
			{
				TaskData[int] tasks;
				tasks[1] = TaskData(1, "local", fixture.linkedCheckout);
				tasks[1].taskType = "writable";
				tasks[1].agentName = "claude";
				auto workspaceSandbox = unrestrictedLaunchTestSandbox();
				workspaceSandbox.paths[memory] = mode;
				auto runner = gitMetadataTestRunner(&tasks, catalog, fixture,
					workspaceSandbox, "", fixture.linkedCheckout);
				bool thrown;
				try
					runner.prepareTaskSessionLaunch(1,
						new LinkedWorktreeSandboxTestAgent(), typeDef);
				catch (Exception e)
				{
					thrown = true;
					assert(e.msg.canFind(memory), e.msg);
					assert(e.msg.canFind("workspaceConfig"), e.msg);
					assert(e.msg.canFind("canonical memory"), e.msg);
				}
				assert(thrown);
			}

			auto mcpSocket = buildPath(fixture.root, "masked-parent-mcp.sock");
			write(mcpSocket, "");
			foreach (ancestorMode; [PathMode.rw, PathMode.tmpfs])
			{
				TaskData[int] tasks;
				tasks[1] = TaskData(1, "local", fixture.linkedCheckout);
				tasks[1].taskType = "writable";
				tasks[1].agentName = "claude";
				auto workspaceSandbox = unrestrictedLaunchTestSandbox();
				workspaceSandbox.paths[fixture.root] = ancestorMode;
				auto runner = gitMetadataTestRunner(&tasks, catalog, fixture,
					workspaceSandbox, "", fixture.linkedCheckout, mcpSocket);
				auto launch = runner.prepareTaskSessionLaunch(1,
					new LinkedWorktreeSandboxTestAgent(), typeDef);
				auto paths = launch.processLaunch.sandbox.paths;
				auto taskDir = buildPath(fixture.root, "tasks", "task");
				auto taskRoot = dirName(taskDir);
				assert(paths.exact(fixture.root).get.effectiveMode == ancestorMode);
				assert(paths.exact(fixture.linkedCheckout).get.effectiveMode == PathMode.rw);
				assert(paths.exact(fixture.linkedGitDir).get.effectiveMode == PathMode.rw);
				assert(paths.exact(fixture.commonGitDir).get.effectiveMode == PathMode.rw);
				assert(paths.exact(taskDir).get.effectiveMode == PathMode.rw);
				assert(paths.exact(taskRoot).get.effectiveMode == PathMode.ro);
				assert(paths.exact(mcpSocket).get.effectiveMode == PathMode.ro);
				assert(paths.exact(buildPath(fixture.linkedCheckout, ".cydo", "memory"))
					.get.effectiveMode == PathMode.always_rw);
			}
		});
}

unittest
{
	withGitMetadataLaunchFixture("cydo-task-runner-git-requirement-joins",
		(GitMetadataLaunchFixture fixture) {
			auto base = SandboxPathOrigin(SandboxPathOriginKind.launchRequirement,
				fixture.linkedCheckout, "base checkout");
			auto worktree = SandboxPathOrigin(SandboxPathOriginKind.launchRequirement,
				fixture.primaryRepo, "active worktree");
			auto reachability = SandboxPathOrigin(SandboxPathOriginKind.launchRequirement,
				fixture.linkedCheckout, "worktree-reachable checkout");
			SandboxPaths forward;
			launchSandbox.grantGitMetadata(forward, fixture.linkedCheckout, PathAccess.ro, base);
			launchSandbox.grantGitMetadata(forward, fixture.primaryRepo, PathAccess.rw, worktree);
			launchSandbox.grantGitMetadata(forward, fixture.linkedCheckout,
				PathAccess.alwaysRw, reachability);
			assert(forward.exact(fixture.commonGitDir).get.effectiveMode
				== PathMode.always_rw);

			SandboxPaths reverse;
			launchSandbox.grantGitMetadata(reverse, fixture.linkedCheckout,
				PathAccess.alwaysRw, reachability);
			launchSandbox.grantGitMetadata(reverse, fixture.primaryRepo, PathAccess.rw, worktree);
			launchSandbox.grantGitMetadata(reverse, fixture.linkedCheckout, PathAccess.ro, base);
			assert(reverse.exact(fixture.commonGitDir).get.effectiveMode
				== PathMode.always_rw);

			SandboxConfig configured;
			configured.paths[fixture.commonGitDir] = PathMode.always_rw;
			AgentSandboxConfig agent;
			agent.configureSandbox = (ref SandboxPaths paths, ref string[string] env) {};
			agent.agentName = "test-agent";
			agent.workspaceName = "test-workspace";
			auto configuredSandbox = launchSandbox.resolveSandbox(SandboxConfig.init,
				SandboxConfig.init, configured, agent, "", "");
			launchSandbox.grantGitMetadata(configuredSandbox.paths, fixture.linkedCheckout,
				PathAccess.ro, base);
			auto configuredView = configuredSandbox.paths.exact(fixture.commonGitDir).get;
			assert(configuredView.declaration.get.mode == PathMode.always_rw);
			assert(configuredView.effectiveMode == PathMode.always_rw);
		});
}

unittest
{
	import std.algorithm : canFind;

	withGitMetadataLaunchFixture("cydo-task-runner-git-metadata-conflicts",
		(GitMetadataLaunchFixture fixture) {
			auto modes = [PathMode.ro, PathMode.tmpfs, PathMode.empty_dir,
				PathMode.empty_file];
			auto modeClauses = ["configured ro declaration",
				"configured tmpfs declaration", "configured empty_dir declaration",
				"configured empty_file declaration"];
			auto accesses = [PathAccess.rw, PathAccess.alwaysRw];
			auto accessNames = ["rw", "alwaysRw"];

			foreach (modeIndex, mode; modes)
			foreach (accessIndex, access; accesses)
			{
				auto workspace = unrestrictedLaunchTestSandbox();
				workspace.paths[fixture.linkedGitDir] = mode;
				AgentSandboxConfig agent;
				agent.configureSandbox = (ref SandboxPaths paths, ref string[string] env) {};
				agent.agentName = "selected-agent";
				agent.workspaceName = "selected-workspace";
				auto sandbox = launchSandbox.resolveSandbox(
					unrestrictedLaunchTestSandbox(), SandboxConfig.init, workspace,
					agent, "", "");
				auto baseOrigin = SandboxPathOrigin(
					SandboxPathOriginKind.launchRequirement, fixture.linkedCheckout,
					"linked checkout Git metadata");

				bool thrown;
				try
					launchSandbox.grantGitMetadata(sandbox.paths, fixture.linkedCheckout,
						access, baseOrigin);
				catch (Exception e)
				{
					thrown = true;
					foreach (fragment; [fixture.linkedGitDir, modeClauses[modeIndex],
						"workspaceConfig", "selected-workspace",
						"sandbox.paths (" ~ fixture.linkedGitDir ~ ")",
						accessNames[accessIndex], "launchRequirement",
						fixture.linkedCheckout,
						"linked checkout Git metadata --git-dir"])
						assert(e.msg.canFind(fragment), e.msg);
					assert(!e.msg.canFind("--git-common-dir"), e.msg);
				}
				assert(thrown);
				assert(sandbox.paths.exact(fixture.commonGitDir).isNull);
			}
		});
}

unittest
{
	import configy.attributes : SetInfo;
	import std.algorithm : canFind;
	import std.file : exists, mkdirRecurse, remove, symlink, write;
	import std.process : environment;

	withGitMetadataLaunchFixture("cydo-task-runner-relocated-task-paths",
		(GitMetadataLaunchFixture fixture) {
			auto physicalTaskRoot = buildPath(fixture.root, "moved", "tasks");
			auto logicalTaskRoot = buildPath(fixture.workspaceRoot, ".cydo", "tasks");
			auto logicalTaskDir = buildPath(logicalTaskRoot, "task");
			auto physicalTaskDir = buildPath(physicalTaskRoot, "task");
			mkdirRecurse(physicalTaskRoot);
			mkdirRecurse(buildPath(fixture.workspaceRoot, ".cydo"));
			symlink(physicalTaskRoot, logicalTaskRoot);

			auto fakeBin = buildPath(fixture.root, "bin");
			mkdirRecurse(fakeBin);
			write(buildPath(fakeBin, "bwrap"), "");
			auto oldPath = environment.get("PATH", "");
			environment["PATH"] = fakeBin ~ ":" ~ oldPath;
			scope (exit) environment["PATH"] = oldPath;

			auto catalog = gitMetadataTaskCatalog(fixture,
				"task_types:\n"
				~ "  writable:\n"
				~ "    model_class: large\n");
			auto typeDef = catalog.getTaskTypesForProject(fixture.linkedCheckout)
				.byName("writable");
			assert(typeDef !is null);
			TaskData[int] tasks;
			tasks[1] = TaskData(1, "local", fixture.linkedCheckout);
			tasks[1].taskType = "writable";
			tasks[1].agentName = "claude";
			auto workspaceSandbox = unrestrictedLaunchTestSandbox();
			workspaceSandbox.isolate_filesystem = SetInfo!bool(true);
			auto runner = gitMetadataTestRunner(&tasks, catalog, fixture,
				workspaceSandbox, "", fixture.linkedCheckout, "", logicalTaskDir);
			auto launch = runner.prepareTaskSessionLaunch(1,
				new LinkedWorktreeSandboxTestAgent(), typeDef);
			scope (exit)
				foreach (tempFile; launch.processLaunch.sandbox.tempFiles)
					if (exists(tempFile))
						remove(tempFile);
			assert(launch.processLaunch.cmdPrefix.canFind([
				"--ro-bind", physicalTaskRoot, physicalTaskRoot]));
			assert(launch.processLaunch.cmdPrefix.canFind([
				"--bind", physicalTaskDir, physicalTaskDir]));
			assert(!launch.processLaunch.cmdPrefix.canFind(logicalTaskRoot));
			assert(!launch.processLaunch.cmdPrefix.canFind(logicalTaskDir));
		});
}

unittest
{
	withGitMetadataLaunchFixture("cydo-task-runner-managed-linked-worktree",
		(GitMetadataLaunchFixture fixture) {
			auto managedCheckout = buildPath(fixture.workspaceRoot, "managed");
			assert(execute(["git", "-C", fixture.primaryRepo, "worktree", "add", "--detach",
				managedCheckout]).status == 0);
			auto managedGitDir = execute(["git", "-C", managedCheckout, "rev-parse",
				"--path-format=absolute", "--git-dir"]);
			assert(managedGitDir.status == 0, managedGitDir.output);

			auto catalog = gitMetadataTaskCatalog(fixture,
				"task_types:\n"
				~ "  managed:\n"
				~ "    model_class: large\n");
			auto taskTypes = catalog.getTaskTypesForProject(fixture.linkedCheckout);
			auto typeDef = taskTypes.byName("managed");
			assert(typeDef !is null);
			auto reachesWorktree = catalog.reachesWorktreeFor(fixture.linkedCheckout);
			assert(reachesWorktree !is null && !reachesWorktree["managed"]);

			TaskData[int] tasks;
			tasks[1] = TaskData(1, "local", fixture.linkedCheckout);
			tasks[1].taskType = "managed";
			tasks[1].agentName = "claude";
			tasks[1].worktreeTid = 1;

			auto runner = gitMetadataTestRunner(&tasks, catalog, fixture,
				unrestrictedLaunchTestSandbox(), managedCheckout, managedCheckout);
			auto launch = runner.prepareTaskSessionLaunch(1,
				new LinkedWorktreeSandboxTestAgent(), typeDef);
			auto workDirMode = launch.processLaunch.sandbox.paths.exact(fixture.linkedCheckout);
			auto baseGitMode = launch.processLaunch.sandbox.paths.exact(fixture.linkedGitDir);
			auto worktreeMode = launch.processLaunch.sandbox.paths.exact(managedCheckout);
			auto managedGitMode = launch.processLaunch.sandbox.paths.exact(managedGitDir.output.strip);
			auto commonGitMode = launch.processLaunch.sandbox.paths.exact(fixture.commonGitDir);
			assert(!workDirMode.isNull);
			assert(!baseGitMode.isNull);
			assert(!worktreeMode.isNull);
			assert(!managedGitMode.isNull);
			assert(!commonGitMode.isNull);
			assert(workDirMode.get.effectiveMode == PathMode.ro);
			assert(baseGitMode.get.effectiveMode == PathMode.ro);
			assert(worktreeMode.get.effectiveMode == PathMode.rw);
			assert(managedGitMode.get.effectiveMode == PathMode.rw);
			assert(commonGitMode.get.effectiveMode == PathMode.rw);
		});
}

unittest
{
	withGitMetadataLaunchFixture("cydo-task-runner-reaches-worktree-git-metadata",
		(GitMetadataLaunchFixture fixture) {
			auto catalog = gitMetadataTaskCatalog(fixture,
				"task_types:\n"
				~ "  parent:\n"
				~ "    model_class: large\n"
				~ "    read_only: true\n"
				~ "    creatable_tasks:\n"
				~ "      child:\n"
				~ "        task_type: child\n"
				~ "        worktree: require\n"
				~ "        prompt_template: prompts/blank.md\n"
				~ "  child:\n"
				~ "    model_class: large\n");
			auto taskTypes = catalog.getTaskTypesForProject(fixture.linkedCheckout);
			auto typeDef = taskTypes.byName("parent");
			assert(typeDef !is null);
			auto reachesWorktree = catalog.reachesWorktreeFor(fixture.linkedCheckout);
			assert(reachesWorktree !is null && reachesWorktree["parent"]);

			TaskData[int] tasks;
			tasks[1] = TaskData(1, "local", fixture.linkedCheckout);
			tasks[1].taskType = "parent";
			tasks[1].agentName = "claude";

			auto runner = gitMetadataTestRunner(&tasks, catalog, fixture,
				unrestrictedLaunchTestSandbox(), "", fixture.linkedCheckout);
			auto launch = runner.prepareTaskSessionLaunch(1,
				new LinkedWorktreeSandboxTestAgent(), typeDef);
			auto workDirMode = launch.processLaunch.sandbox.paths.exact(fixture.linkedCheckout);
			auto gitDirMode = launch.processLaunch.sandbox.paths.exact(fixture.linkedGitDir);
			auto commonGitMode = launch.processLaunch.sandbox.paths.exact(fixture.commonGitDir);
			assert(!workDirMode.isNull);
			assert(!gitDirMode.isNull);
			assert(!commonGitMode.isNull);
			assert(workDirMode.get.effectiveMode == PathMode.ro);
			assert(gitDirMode.get.effectiveMode == PathMode.always_rw);
			assert(commonGitMode.get.effectiveMode == PathMode.always_rw);
		});
}

unittest
{
	withGitMetadataLaunchFixture("cydo-task-runner-non-git-managed-worktree",
		(GitMetadataLaunchFixture fixture) {
			import std.algorithm : canFind;
			import std.file : mkdirRecurse;

			auto worktreePath = buildPath(fixture.root, "plain-worktree");
			mkdirRecurse(worktreePath);

			auto catalog = gitMetadataTaskCatalog(fixture,
				"task_types:\n"
				~ "  managed:\n"
				~ "    model_class: large\n");
			auto taskTypes = catalog.getTaskTypesForProject(fixture.linkedCheckout);
			auto typeDef = taskTypes.byName("managed");
			assert(typeDef !is null);

			TaskData[int] tasks;
			tasks[1] = TaskData(1, "local", fixture.linkedCheckout);
			tasks[1].taskType = "managed";
			tasks[1].agentName = "claude";
			tasks[1].worktreeTid = 1;

			auto runner = gitMetadataTestRunner(&tasks, catalog, fixture,
				unrestrictedLaunchTestSandbox(), worktreePath, worktreePath);
			bool threw;
			try
				runner.prepareTaskSessionLaunch(1, new LinkedWorktreeSandboxTestAgent(), typeDef);
			catch (Exception e)
			{
				threw = true;
				assert(e.msg.canFind(worktreePath));
				assert(e.msg.canFind("--git-dir"));
			}
			assert(threw);
		});
}

unittest
{
	withGitMetadataLaunchFixture("cydo-task-runner-non-git-reaches-worktree",
		(GitMetadataLaunchFixture fixture) {
			import std.file : mkdirRecurse;

			auto projectPath = buildPath(fixture.workspaceRoot, "plain-project");
			mkdirRecurse(projectPath);

			auto catalog = gitMetadataTaskCatalog(fixture,
				"task_types:\n"
				~ "  parent:\n"
				~ "    model_class: large\n"
				~ "    creatable_tasks:\n"
				~ "      child:\n"
				~ "        task_type: child\n"
				~ "        worktree: require\n"
				~ "        prompt_template: prompts/blank.md\n"
				~ "  child:\n"
				~ "    model_class: large\n");
			auto taskTypes = catalog.getTaskTypesForProject(projectPath);
			auto typeDef = taskTypes.byName("parent");
			assert(typeDef !is null);
			auto reachesWorktree = catalog.reachesWorktreeFor(projectPath);
			assert(reachesWorktree !is null && reachesWorktree["parent"]);

			TaskData[int] tasks;
			tasks[1] = TaskData(1, "local", projectPath);
			tasks[1].taskType = "parent";
			tasks[1].agentName = "claude";
			assert(!tasks[1].isGitCheckout);

			auto runner = gitMetadataTestRunner(&tasks, catalog, fixture,
				unrestrictedLaunchTestSandbox(), "", projectPath);
			// A non-Git project may launch a worktree-reaching parent; only an
			// actually requested worktree child can fail. No metadata is granted.
			auto launch = runner.prepareTaskSessionLaunch(1,
				new LinkedWorktreeSandboxTestAgent(), typeDef);
			auto projectMode = launch.processLaunch.sandbox.paths.exact(projectPath);
			assert(!projectMode.isNull);
			assert(projectMode.get.effectiveMode == PathMode.rw);
			assert(launch.processLaunch.sandbox.paths.exact(fixture.commonGitDir).isNull);
		});
}
