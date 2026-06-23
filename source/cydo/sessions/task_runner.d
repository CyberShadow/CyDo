module cydo.sessions.task_runner;

import core.time : seconds;

import std.file : mkdirRecurse;
import std.path : absolutePath, buildPath;
import std.process : execute;
import std.string : strip;
import std.logger : infof, tracef, warningf;

import ae.utils.json : toJson;
import ae.utils.promise : Promise, reject, resolve;

import cydo.agent.contract : Agent, SessionConfig;
import cydo.agent.protocol : ProcessExitEvent, ProcessStderrEvent, TranslatedEvent;
import cydo.runtime.config : AgentDriver, PathMode, SandboxConfig;
import cydo.runtime.launch.types : AgentSandboxConfig, ProcessLaunch;
import launchSandbox = cydo.runtime.launch.sandbox;
import cydo.tasks.model : ProcessState, TaskData;
import cydo.task_types.catalog : TaskTypeCatalog;
import cydo.task_types.definition : TaskTypeDef, formatCreatableTaskTypes, formatHandoffs,
	isInteractive, formatSwitchModes, loadSystemPrompt, byName;

package(cydo):

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
	SandboxConfig delegate() globalSandbox;
	SandboxConfig delegate(string workspaceName) findWorkspaceSandbox;
	string delegate(string workspaceName) findWorkspaceRoot;
	string delegate(string workspaceName) findWorkspacePermissionPolicy;
	SandboxConfig delegate(string agentName) findAgentSandbox;
	string delegate(int tid) resolveSharedTmpPath;
	string delegate() mcpSocketPath;
	Agent delegate(int tid) agentForTask;
	Agent delegate(int tid) tryAgentForTask;
	void delegate(int tid) clearLastActive;
	void delegate(int tid, TranslatedEvent ev) broadcastTask;
	string delegate(int tid, string subject, string body) appendSynthesizedHistoryError;
	void delegate(int tid, string translated) broadcastAppendedTaskEvent;
	void delegate(int tid, string nonce) sendAgentAck;
	void delegate(int tid) broadcastTaskUpdate;
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
	void delegate(int tid) deliverWaitingParentResultsIfReady;
	void delegate(int parentTid) deliverBatchResults;
	void delegate(int tid) failPendingAskUserQuestionOnExit;
	void delegate(int tid) failPendingPermissionPromptOnExit;
	void delegate(int tid) failPendingAskRouteOnExit;
	void delegate(int tid) cancelExitBackgroundWork;
	void delegate(int tid) resetHistoryWatermarkOnly;
	void delegate(int tid) resetHistoryWatermarkAfterExit;
	void delegate(int tid) unsubscribeTaskHistorySubscribers;
	void delegate(int tid) touchAndPersistLastActive;
	int delegate(int tid) findAliveAncestor;
	void delegate(int fromTid, int toTid) broadcastFocusHint;
	void delegate(int tid, string status) persistStatus;
	void delegate(int tid, string resultText) persistResultText;
	void delegate(int tid, string missingOutputs) requestMissingOutputs;
	void delegate(int tid) spawnContinuation;
	void delegate(int tid) spawnOnYieldContinuation;
	void delegate(int tid) emitTaskReload;
	void delegate(int tid) startJsonlWatch;
	void delegate(int tid) stopJsonlWatch;
	void delegate(int tid) broadcastForkableUuidsFromFile;
	void delegate(int tid) sendSystemRestartNudge;
	void delegate() loadPersistedTaskDeps;
	int[] delegate() snapshotTaskIds;
	bool delegate(int parentTid) waitingTaskChildrenAllDone;
	bool delegate() shuttingDown;
	TaskTypeCatalog taskTypeCatalog;
}

class TaskSessionRunner
{
	private TaskSessionRunnerHost host_;

	this(TaskSessionRunnerHost host)
	{
		host_ = host;
	}

	TaskSessionLaunch prepareTaskSessionLaunch(int tid, Agent taskAgent,
		TaskTypeDef* typeDef)
	{
		auto td = requireTask(tid,
			"Task must exist before preparing session launch");

		SessionConfig sessionConfig;
		if (typeDef !is null)
		{
			sessionConfig.model = taskAgent.resolveModelAlias(typeDef.model_class);
			if (taskAgent.supportsDeveloperPrompt)
				sessionConfig.appendSystemPrompt = loadSystemPrompt(*typeDef,
					host_.taskTypeCatalog.promptSearchPath(td.projectPath),
					host_.outputPath(td));
		}
		auto taskTypes = host_.taskTypeCatalog.getTaskTypesForProject(td.projectPath);
		sessionConfig.creatableTaskTypes = formatCreatableTaskTypes(taskTypes, td.taskType);
		sessionConfig.switchModes = formatSwitchModes(taskTypes, td.taskType);
		sessionConfig.handoffs = formatHandoffs(taskTypes, td.taskType);
		sessionConfig.mcpSocketPath = host_.mcpSocketPath();

		auto workDir = td.repoPath.length > 0 ? td.repoPath : null;

		auto tdDir = host_.taskDir(td);
		mkdirRecurse(tdDir);

		auto taskCwd = host_.effectiveCwd(td);
		auto chdir = taskCwd.length > 0 ? taskCwd : workDir;

		auto wsSandbox = host_.findWorkspaceSandbox(td.workspace);
		auto wsRoot = host_.findWorkspaceRoot(td.workspace);
		auto agentTypeSandbox = host_.findAgentSandbox(td.agentType);
		bool readOnly = typeDef !is null && typeDef.read_only;
		AgentSandboxConfig agentSandbox;
		agentSandbox.configureSandbox = (ref PathMode[string] paths, ref string[string] env) {
			taskAgent.configureSandbox(paths, env);
		};
		agentSandbox.gitName = taskAgent.gitName;
		agentSandbox.gitEmail = taskAgent.gitEmail;
		auto sandbox = launchSandbox.resolveSandbox(host_.globalSandbox(), agentTypeSandbox, wsSandbox,
			agentSandbox, workDir, wsRoot, readOnly);

		sandbox.paths[tdDir] = PathMode.rw;

		if (td.worktreeTid > 0 && !readOnly && workDir.length > 0)
		{
			sandbox.paths[workDir] = PathMode.ro;

			auto wtPath = host_.worktreePath(td);
			sandbox.paths[wtPath] = PathMode.rw;

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

		auto reachesWorktree = host_.taskTypeCatalog.reachesWorktreeFor(td.projectPath);
		if (workDir.length > 0 && td.taskType in reachesWorktree
			&& reachesWorktree[td.taskType])
		{
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

		auto mcpSocketPath = host_.mcpSocketPath();
		if (mcpSocketPath.length > 0)
			sandbox.paths[mcpSocketPath] = PathMode.ro;

		if (workDir.length > 0)
		{
			auto memoryDir = buildPath(workDir, ".cydo", "memory");
			mkdirRecurse(memoryDir);
			sandbox.paths[memoryDir] = PathMode.always_rw;
		}

		sandbox.sharedTmpPath = host_.resolveSharedTmpPath(tid);
		td.launch = launchSandbox.prepareProcessLaunch(sandbox, chdir,
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
		if (taskTypes.isInteractive(host_.taskTypeCatalog.getEntryPointsForProject(td.projectPath),
			td.taskType))
			sessionConfig.includeTools ~= "AskUserQuestion";
		sessionConfig.includeTools ~= "Ask";
		sessionConfig.includeTools ~= "Answer";
		if (typeDef !is null && typeDef.allow_native_subagents)
			sessionConfig.allowNativeSubagents = true;

		sessionConfig.permissionPolicy = host_.findWorkspacePermissionPolicy(td.workspace);
		sessionConfig.agentName = td.agentType;

		return TaskSessionLaunch(td.launch, sessionConfig);
	}

	void spawnTaskSession(int tid)
	{
		auto td = requireTask(tid, "Task must exist before spawning session");
		assert(td.taskType.length > 0,
			"Task must have a task_type before spawning session");
		td.wasKilledByUser = false;
		td.hadTurnResult = false;
		td.stdinClosed = false;
		td.clearLastSessionStatus();
		td.compactionReminderInFlight = false;

		auto taskAgent = host_.agentForTask(tid);
		auto typeDef = currentTaskTypeDef(td);
		auto launch = prepareTaskSessionLaunch(tid, taskAgent, typeDef);
		td = requireTask(tid, "Task disappeared before session creation");
		td.session = taskAgent.createSession(tid, td.agentSessionId,
			launch.processLaunch, launch.sessionConfig);
		host_.clearLastActive(tid);

		if (taskAgent.lastMcpConfigPath.length > 0)
			td.launch.sandbox.tempFiles ~= taskAgent.lastMcpConfigPath;

		if (td.agentSessionId.length > 0)
			host_.startJsonlWatch(tid);

		td.session.onOutput = (TranslatedEvent ev) {
			host_.broadcastTask(tid, ev);

			auto current = host_.getTask(tid);
			if (current is null)
				return;

			if (!current.isProcessing && current.hadTurnResult)
			{
				current.isProcessing = true;
				host_.broadcastTaskUpdate(tid);
			}

			if (!taskAgent.isTurnResult(ev.translated))
				return;

			current = host_.getTask(tid);
			if (current is null)
				return;

			current.isProcessing = false;
			current.hadTurnResult = true;
			current.compactionReminderInFlight = false;

			if (!host_.shuttingDown())
				host_.startJsonlWatch(tid);
			if (!host_.shuttingDown())
				host_.broadcastForkableUuidsFromFile(tid);

			current = host_.getTask(tid);
			if (current is null)
				return;

			current.resultText = taskAgent.extractResultText(ev.translated);

			bool hasOnYield = taskHasOnYield(current);
			if (host_.hasPendingSubTask(tid) || current.pendingContinuation !is null
				|| host_.hasTaskDependency(tid) || hasOnYield
				|| current.onIdleCallbacks.length > 0)
			{
				if (current.onIdleCallbacks.length > 0)
				{
					if (host_.drainIdleCallbacksForTurnResult(tid))
					{
						host_.broadcastTaskUpdate(tid);
						return;
					}
				}
				else if (host_.hasPendingSubTask(tid))
				{
					if (current.pendingContinuation is null && !hasOnYield)
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

				bool hasPendingChildQuestion =
					current.pendingContinuation is null
					&& host_.hasPendingChildQuestion(tid);

				if (hasPendingChildQuestion)
				{
					host_.sendPendingChildAnswerReminder(tid);
				}
				else
				{
					current.processQueue.setGoal(ProcessState.Dead).ignoreResult();
					current.session.closeStdin();
					current.session.killAfterTimeout(5.seconds);
				}
			}
			else
			{
				if (current.onIdleCallbacks.length > 0)
					host_.drainIdleCallbacksOnExit(tid);
				else
					host_.onTaskTurnCompletedAlive(tid);
			}

			host_.broadcastTaskUpdate(tid);
		};

		td.session.onAgentAck = (string nonce) {
			if (nonce.length == 0)
				return;
			host_.sendAgentAck(tid, nonce);
		};

		string lastStderr;

		td.session.onStderr = (string line) {
			ProcessStderrEvent ev;
			ev.text = line;
			host_.broadcastTask(tid, TranslatedEvent(toJson(ev), null));
			lastStderr = line;
		};

		td.session.onExit = (int exitCode) {
			if (host_.shuttingDown())
				return;

			host_.touchAndPersistLastActive(tid);

			tracef("onExit: tid=%d exitCode=%d status=%s",
				tid, exitCode, currentStatusForLog(tid));

			auto current = host_.getTask(tid);
			if (current is null)
				return;

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
				return;

			current.isProcessing = false;
			current.stdinClosed = false;
			if (exitCode != 0)
				current.error = lastStderr;
			cleanupTaskLaunch(current);
			host_.stopJsonlWatch(tid);

			host_.failPendingAskUserQuestionOnExit(tid);
			host_.failPendingPermissionPromptOnExit(tid);
			host_.failPendingAskRouteOnExit(tid);
			host_.drainIdleCallbacksOnExit(tid);
			host_.cancelExitBackgroundWork(tid);

			bool missingExecutableLaunchFailure = exitCode != 0
				&& !current.hadTurnResult
				&& isMissingExecutableMessage(current.error);
			if (missingExecutableLaunchFailure)
			{
				host_.resetHistoryWatermarkOnly(tid);
				auto translated = host_.appendSynthesizedHistoryError(
					tid, "Failed to resume session",
					buildLaunchFailureBody(tid, current.error));
				host_.broadcastAppendedTaskEvent(tid, translated);
				host_.unsubscribeTaskHistorySubscribers(tid);
			}
			else
				host_.resetHistoryWatermarkAfterExit(tid);

			current = host_.getTask(tid);
			if (current is null)
				return;

			current.recentNonces = null;

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

			if (!intentionalExit)
			{
				current.status = "failed";
				if (current.error.length == 0)
					current.error = "Process exited unexpectedly";
				host_.persistStatus(tid, "failed");
				if (current.relationType != "fork")
				{
					auto ancestor = host_.findAliveAncestor(tid);
					if (ancestor >= 0)
						host_.broadcastFocusHint(tid, ancestor);
				}
				host_.broadcastTaskUpdate(tid);
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
			if (cleanExit && consumerWaiting)
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

			if (current.status != "completed")
				current.status = exitCode == 0 ? "completed" : "failed";
			host_.persistStatus(tid, current.status);
			host_.persistResultText(tid, current.resultText);

			bool deliveredPendingSubTask = false;
			if (current.status == "completed")
				deliveredPendingSubTask = host_.finalizeCompletedSubTask(tid, false);
			else
				deliveredPendingSubTask = host_.deliverFailedPendingSubTaskResult(tid);

			if (!deliveredPendingSubTask)
				host_.deliverWaitingParentResultsIfReady(tid);

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
			host_.broadcastTaskUpdate(tid);
		};

		td.status = "active";
		host_.persistStatus(tid, "active");
		td.error = null;
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
			try
				spawnTaskSession(tid);
			catch (Exception e)
			{
				td = requireTask(tid, "Task must exist when spawn fails");
				td.status = "failed";
				td.error = e.msg;
				host_.persistStatus(tid, "failed");
				auto translated = host_.appendSynthesizedHistoryError(
					tid, "Failed to resume session", buildLaunchFailureBody(tid, e));
				host_.broadcastAppendedTaskEvent(tid, translated);
				host_.broadcastTaskUpdate(tid);
				return reject!ProcessState(e);
			}
			host_.broadcastTaskUpdate(tid);
			return resolve(ProcessState.Alive);
		}

		if (td.session is null || !td.session.alive)
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
				i + 1, toResume.length, tid, td.agentType, status);

			if (status == "waiting")
			{
				if (host_.waitingTaskChildrenAllDone(tid))
				{
					tracef("resumeInFlightTasks: tid=%d waiting, all children done — resuming with batch delivery",
						tid);
					resumeAndDeliverResults(tid);
				}
				else
				{
					tracef("resumeInFlightTasks: tid=%d waiting, children still running — resuming without message",
						tid);
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

	Promise!void resumeTask(int tid)
	{
		auto td = host_.getTask(tid);
		if (td is null)
			return resolve();

		auto savedStatus = td.status;
		return td.processQueue.setGoal(ProcessState.Alive).then(() {
			auto current = host_.getTask(tid);
			if (current is null)
				return;
			if (savedStatus != "active")
			{
				current.status = savedStatus;
				host_.persistStatus(tid, savedStatus);
			}
			host_.broadcastTaskUpdate(tid);
		});
	}

	void resumeAndDeliverResults(int tid)
	{
		resumeTask(tid).then(() {
			host_.deliverBatchResults(tid);
		}).ignoreResult();
	}

	void resumeWaitingTask(int tid)
	{
		resumeTask(tid).ignoreResult();
	}

	void resumeActiveTask(int tid)
	{
		resumeTask(tid).then(() {
			host_.sendSystemRestartNudge(tid);
		}).ignoreResult();
	}

private:
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
				binEnvVar = "CYDO_" ~ td.agentType.toUpper ~ "_BIN";
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
			return "The **`" ~ td.agentType ~ "`** CLI was not found on `PATH`.\n\n"
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
