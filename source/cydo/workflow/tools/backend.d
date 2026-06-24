module cydo.workflow.tools.backend;

import std.format : format;
import std.logger : errorf, infof, tracef, warningf;

import ae.utils.json : JSONFragment, jsonParse, toJson;
import ae.utils.promise : Promise, resolve;
import ae.utils.promise.await : await;

import cydo.agent.contract : Agent;
import cydo.agent.terminal : TerminalProcess;
import cydo.domain.policy.permissions : evaluatePermissionPolicy,
	makePermissionAllowJson, makePermissionDenyJson;
import cydo.domain.task_types.definition : ContinuationDef, TaskTypeDef,
	UserEntryPointDef, WorktreeMode, byName, isInteractive,
	loadProjectMemory, renderContinuationPrompt, renderPrompt,
	substituteVars;
import cydo.domain.tasks.model;
import cydo.foundation.system.known_messages : KnownSystemMessageKind,
	handoffSubject, modeSwitchSubject, subTaskWaitingForAnswerSubject,
	taskPromptSubject, wrapKnownSystemMessage;
import cydo.foundation.system.framing : prependTaskFraming;
import cydo.foundation.text.title : truncateTitle;
import cydo.mcp : McpResult;
import cydo.mcp.payloads : TaskResult;
import cydo.mcp.tools : AskQuestion, LaunchedTask, ToolsBackend,
	ValidatedTask;
import cydo.protocol : BatchResultEnvelope, ContentBlock;
import cydo.workflow.batch.registry : BatchHandle, BatchRegistry;
import cydo.workflow.batch.router : BatchConsumeKind;
import cydo.workflow.questions.router : QuestionRouter,
	QuestionRouterHost;
import cydo.workflow.tasks.subtask_delivery : SubtaskResultDelivery,
	SubtaskResultDeliveryHost;

package(cydo):

struct WorkflowToolsHost
{
	TaskData* delegate(int tid) getTask;
	int delegate(string workspace, string projectPath, string agentName) createTask;
	void delegate(int tid, string taskType) persistTaskType;
	void delegate(int tid, string description) persistDescription;
	void delegate(int tid, int parentTid) persistParentTid;
	void delegate(int tid, string relationType) persistRelationType;
	void delegate(int tid, string title) persistTitle;
	void delegate(int tid, string status) persistStatus;
	void delegate(int tid, bool needsAttention) persistNeedsAttention;
	void delegate(int tid, long lastActive) persistLastActive;
	void delegate(int tid, string resultText) persistResultText;
	void delegate(int tid) touchTask;

	TaskTypeDef[] delegate(string projectPath) taskTypesForProject;
	UserEntryPointDef[] delegate(string projectPath) entryPointsForProject;
	string[] delegate(string projectPath) promptSearchPath;
	bool[string] delegate(string projectPath) treeReadOnlyForProject;
	string delegate(string requestedAgent, string parentAgent) resolveTaskAgent;
	bool delegate(string agentName) isRegisteredAgent;
	Agent delegate(int tid) agentForTask;
	string delegate(int tid, TaskTypeDef* typeDef) taskSystemPromptForMessage;
	string delegate(string relativePath, string projectPath,
		string[string] vars) readPromptFile;
	string delegate(KnownSystemMessageKind kind, string subject,
		string[string] vars, string bodyVar) buildKnownSystemMessageMeta;
	string delegate() systemKeyword;

	string delegate(const TaskData* td) taskDir;
	string delegate(const TaskData* td) outputPath;
	string delegate(const TaskData* td) worktreePath;
	string delegate(int tid) worktreeForkBaseHead;
	bool delegate(string projectPath, string taskTypeName) taskProducesCommitOutput;
	void delegate(int childTid, int parentTid, WorktreeMode mode) setupWorktreeForEdge;
	Promise!void delegate(int tid) ensureProcessQueueAlive;
	void delegate(int tid, const(ContentBlock)[] content,
		const(ContentBlock)[] broadcastContent, string cydoMeta,
		string nonce) sendTaskMessage;
	void delegate(int tid, string reason) emitTaskReload;
	void delegate(int tid, string subject,
		string body) appendSynthesizedHistoryError;

	bool delegate(int tid) taskAlive;
	bool delegate(int aTid, int bTid) tasksShareWorkspace;
	string delegate(int tid) taskWorkspaceLabel;
	void delegate(int tid, void delegate() cb) addIdleCallback;
	void delegate(int tid, void delegate() onReady) reactivateTask;
	bool delegate(int tid, out string sessionState) canSendSystemMessage;
	void delegate(int tid, KnownSystemMessageKind kind, string body)
		sendKnownSystemMessage;

	void delegate(int parentTid, int childTid) persistAddTaskDep;
	void delegate(int parentTid, int childTid) persistRemoveTaskDep;
	void delegate(int childTid) persistRemoveAllChildDeps;
	int[][int] delegate() loadTaskDeps;

	void delegate(int tid) broadcastTaskUpdate;
	void delegate(int fromTid, int toTid) broadcastFocusHint;
	void delegate(int tid, JSONFragment questions, string toolUseId)
		sendAskUserQuestionPrompt;
	void delegate(int tid) clearAskUserQuestionPrompt;
	void delegate(int tid, string toolUseId, string toolName,
		JSONFragment input) sendPermissionPrompt;
	void delegate(int tid) clearPermissionPrompt;
	void delegate(int parentTid, int childTid, int specIndex)
		appendTaskSpawnedEvent;
	void delegate(TaskCreatedMessage message) broadcastTaskCreated;

	string delegate(string workspaceName) workspacePermissionPolicy;
	void delegate(void delegate() cb) onNextTick;
	void delegate(int tid, string prompt) generateTitle;
}

final class WorkflowToolsBackend : ToolsBackend
{
private:
	WorkflowToolsHost host_;
	Promise!(McpResult)[int] pendingSubTasks_;
	int[int] taskDeps_;
	bool[int] liveDeliveredSubTasks_;
	Promise!(McpResult)[int] pendingAskUserQuestions_;
	Promise!(McpResult)[int] pendingPermissionPrompts_;
	string[int] pendingPermissionInputs_;
	BatchRegistry batchRegistry_;
	QuestionRouter questionRouter_;
	SubtaskResultDelivery subtaskResultDelivery_;
	TerminalProcess[] activeTerminals_;

public:
	this(WorkflowToolsHost host)
	{
		host_ = host;
		subtaskResultDelivery_ = new SubtaskResultDelivery(
			SubtaskResultDeliveryHost(
				getTask: host_.getTask,
				outputPath: host_.outputPath,
				worktreePath: host_.worktreePath,
				worktreeForkBaseHead: host_.worktreeForkBaseHead,
				taskProducesCommitOutput: host_.taskProducesCommitOutput,
				persistStatus: host_.persistStatus,
				persistResultText: host_.persistResultText,
				readPendingSubTask: (int tid,
					out Promise!(McpResult) pending) {
					auto entry = tid in pendingSubTasks_;
					if (entry is null)
						return false;
					pending = *entry;
					return true;
				},
				clearPendingSubTask: (int tid) {
					pendingSubTasks_.remove(tid);
				},
				parentTaskForChild: (int childTid) {
					auto parentTid = childTid in taskDeps_;
					return parentTid is null ? 0 : *parentTid;
				},
				childTaskIds: &childrenOf,
				wasLiveDelivered: (int childTid) {
					return (childTid in liveDeliveredSubTasks_) !is null;
				},
				markLiveDelivered: (int childTid) {
					liveDeliveredSubTasks_[childTid] = true;
				},
				ensureProcessQueueAlive: host_.ensureProcessQueueAlive,
				canSendSystemMessage: host_.canSendSystemMessage,
				sendKnownSystemMessage: host_.sendKnownSystemMessage,
				removeTaskDependency: &removeTaskDependency,
				broadcastTaskUpdate: host_.broadcastTaskUpdate,
				taskAlive: host_.taskAlive,
				onNextTick: host_.onNextTick,
			));
		questionRouter_ = new QuestionRouter(QuestionRouterHost(
			getTask: host_.getTask,
			isTaskAlive: host_.taskAlive,
			tasksShareWorkspace: host_.tasksShareWorkspace,
			taskWorkspaceLabel: host_.taskWorkspaceLabel,
			systemKeyword: host_.systemKeyword,
			readPromptFile: host_.readPromptFile,
			buildKnownSystemMessageMeta: host_.buildKnownSystemMessageMeta,
			sendTaskMessage: (int tid, const(ContentBlock)[] content,
				string cydoMeta, string nonce) {
				host_.sendTaskMessage(tid, content, null, cydoMeta, nonce);
			},
			persistStatus: host_.persistStatus,
			persistResultText: host_.persistResultText,
			broadcastTaskUpdate: host_.broadcastTaskUpdate,
			broadcastFocusHint: host_.broadcastFocusHint,
			addIdleCallback: host_.addIdleCallback,
			reactivateTask: host_.reactivateTask,
			hasPendingSubTask: &hasPendingSubTask,
			registerFollowUpBatchChild: (int parentTid, int childTid,
				BatchHandle handle) {
				auto subTaskPromise = new Promise!McpResult;
				pendingSubTasks_[childTid] = subTaskPromise;
				taskDeps_[childTid] = parentTid;
				host_.persistAddTaskDep(parentTid, childTid);
				subTaskPromise.then((McpResult r) {
					string error;
					if (!batchRegistry_.enqueueChildDone(handle, 0, childTid, r, error))
						errorf("batch router error: %s", error);
				});
			},
			cleanupAfterFollowUpAnswerDelivery: (int childTid) {
				if (childTid in pendingSubTasks_)
					pendingSubTasks_.remove(childTid);
				if (auto parentTidPtr = childTid in taskDeps_)
					removeTaskDependency(*parentTidPtr, childTid);
			},
			awaitBatchLoop: &awaitBatchLoop,
			makeInternalBatchError: &makeInternalBatchError,
		), &batchRegistry_);
	}

	ValidatedTask handleCreateTask(string callerTid, int specIndex,
		string description, string taskType, string prompt)
	{
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

		int parentTid;
		try
			parentTid = to!int(callerTid);
		catch (Exception)
			return ValidatedTask(structuredTaskError("Invalid calling task ID"));

		auto parentTd = host_.getTask(parentTid);
		if (parentTd is null)
			return ValidatedTask(structuredTaskError("Calling task not found"));

		auto parentTypeDef = host_.taskTypesForProject(parentTd.projectPath)
			.byName(parentTd.taskType);
		string resolvedTaskType = taskType;
		if (parentTypeDef !is null
			&& parentTypeDef.creatable_tasks.length > 0)
		{
			auto edge = parentTypeDef.creatable_tasks.byName(taskType);
			if (edge is null)
			{
				return ValidatedTask(structuredTaskError(
					"Task type '" ~ taskType
					~ "' is not in creatable_tasks for '"
					~ parentTd.taskType ~ "'. Allowed: "
					~ parentTypeDef.creatable_tasks
						.map!(c => c.name).join(", ")));
			}
			resolvedTaskType = edge.resolvedType;
		}

		auto childTypeDef = host_.taskTypesForProject(parentTd.projectPath)
			.byName(resolvedTaskType);
		if (childTypeDef is null)
			return ValidatedTask(structuredTaskError(
				"Unknown task type: " ~ resolvedTaskType));

		auto childAgent = host_.resolveTaskAgent(childTypeDef.agent,
			parentTd.agentType);
		if (childAgent.length == 0 || !host_.isRegisteredAgent(childAgent))
		{
			return ValidatedTask(structuredTaskError(format(
				"task type '%s' resolves agent to '%s' (parent='%s') — not a registered agent",
				resolvedTaskType, childAgent, parentTd.agentType)));
		}

		return ValidatedTask(McpResult.init, () {
			auto pd = requireTask(parentTid,
				"Parent task must exist before launching sub-task");
			auto ptd = host_.taskTypesForProject(pd.projectPath)
				.byName(pd.taskType);
			auto ctd = host_.taskTypesForProject(pd.projectPath)
				.byName(resolvedTaskType);
			assert(ctd !is null,
				format!"Validated child task type disappeared before launch: %s"
					(resolvedTaskType));

			auto childTid = host_.createTask(pd.workspace, pd.projectPath,
				childAgent);
			auto childTd = requireTask(childTid,
				"Created child task must exist");
			childTd.taskType = resolvedTaskType;
			childTd.description = prompt;
			childTd.parentTid = parentTid;
			childTd.relationType = "subtask";
			childTd.title = description.length > 0
				? description
				: truncateTitle(prompt, 80);

			host_.persistTaskType(childTid, resolvedTaskType);
			host_.persistDescription(childTid, prompt);
			host_.persistParentTid(childTid, parentTid);
			host_.persistRelationType(childTid, "subtask");
			host_.persistTitle(childTid, childTd.title);

			auto promise = new Promise!McpResult;
			pendingSubTasks_[childTid] = promise;
			host_.persistAddTaskDep(parentTid, childTid);
			taskDeps_[childTid] = parentTid;
			pd.status = "waiting";
			host_.persistStatus(parentTid, "waiting");
			host_.broadcastTaskUpdate(parentTid);

			host_.broadcastTaskCreated(TaskCreatedMessage("task_created",
				childTid, pd.workspace, pd.projectPath, parentTid, "subtask"));
			host_.broadcastTaskUpdate(childTid);
			host_.broadcastFocusHint(parentTid, childTid);
			host_.appendTaskSpawnedEvent(parentTid, childTid, specIndex);

			string edgeTemplate;
			if (ptd !is null)
			{
				if (auto edge = ptd.creatable_tasks.byName(taskType))
				{
					edgeTemplate = edge.prompt_template;
					childTd.resultNote = substituteVars(edge.result_note,
						["output_dir": host_.taskDir(pd)]);
					host_.setupWorktreeForEdge(childTid, parentTid,
						edge.worktree);
				}
			}

			auto renderedPrompt = renderPrompt(*ctd, prompt,
				host_.promptSearchPath(childTd.projectPath),
				host_.outputPath(childTd), edgeTemplate);
			renderedPrompt = prependTaskFraming(renderedPrompt,
				host_.taskSystemPromptForMessage(childTid, ctd),
				loadProjectMemory(ctd, childTd.repoPath,
					host_.promptSearchPath(childTd.projectPath)));
			auto parentTypeForSubject =
				(ptd !is null && ptd.creatable_tasks.length > 0)
					? pd.taskType : "";
			auto taskPromptMsgSubject = taskPromptSubject(
				parentTypeForSubject, taskType);
			auto subtaskMeta = host_.buildKnownSystemMessageMeta(
				KnownSystemMessageKind.taskPrompt,
				taskPromptMsgSubject,
				["task_description": prompt], "task_description");
			host_.ensureProcessQueueAlive(childTid).then(() {
				host_.sendTaskMessage(childTid,
					[ContentBlock("text", wrapKnownSystemMessage(
						host_.systemKeyword(),
						KnownSystemMessageKind.taskPrompt,
						renderedPrompt,
						taskPromptMsgSubject))],
					null, subtaskMeta, null);
			}).ignoreResult();

			if (description.length == 0)
			{
				auto promptForTitle = prompt;
				host_.ensureProcessQueueAlive(childTid).then(() {
					host_.generateTitle(childTid, promptForTitle);
				}).ignoreResult();
			}
			infof("Task: tid=%d type=%s parent=%d", childTid,
				resolvedTaskType, parentTid);

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

		auto parentTd = host_.getTask(parentTid);
		if (parentTd is null)
			return false;

		auto parentTypeDef = host_.taskTypesForProject(parentTd.projectPath)
			.byName(parentTd.taskType);
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

		auto treeReadOnly = host_.treeReadOnlyForProject(parentTd.projectPath);
		auto childRO = resolvedType in treeReadOnly;
		return childRO is null || !(*childRO);
	}

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

		auto td = host_.getTask(tid);
		if (td is null)
			return McpResult("Calling task not found", true);

		auto typeDef = host_.taskTypesForProject(td.projectPath)
			.byName(td.taskType);
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
				"Unknown SwitchMode continuation '" ~ continuation
				~ "' for task type '" ~ td.taskType
				~ "'. Available modes: "
				~ (validModes.length > 0 ? validModes : "(none)") ~ ".",
				true);
		}

		td.pendingContinuation = new PendingContinuation(
			PendingContinuation.Kind.switchMode, continuation);
		infof("SwitchMode: tid=%d continuation=%s (type %s → %s)",
			tid, continuation, td.taskType, contDef.task_type);

		return McpResult(
			"Mode switch to '" ~ contDef.task_type
			~ "' accepted. Yield your turn IMMEDIATELY — do not call any more tools or generate output. "
			~ "You will receive new instructions when your session resumes.");
	}

	McpResult handleHandoff(string callerTid, string continuation, string prompt)
	{
		import std.conv : to;

		int tid;
		try
			tid = to!int(callerTid);
		catch (Exception)
			return McpResult("Invalid calling task ID", true);

		auto td = host_.getTask(tid);
		if (td is null)
			return McpResult("Calling task not found", true);

		auto typeDef = host_.taskTypesForProject(td.projectPath)
			.byName(td.taskType);
		if (typeDef is null)
			return McpResult("Unknown task type: " ~ td.taskType, true);

		auto contDef = continuation in typeDef.continuations;
		if (contDef is null || contDef.keep_context)
		{
			return McpResult(
				"Unknown Handoff continuation '" ~ continuation
				~ "' for task type '" ~ td.taskType
				~ "'. Check the available handoffs in the tool description.",
				true);
		}

		if (prompt.length == 0)
		{
			return McpResult(
				"Handoff requires a non-empty prompt for the successor task.",
				true);
		}

		int pendingChildTid;
		string pendingQuestion;
		int pendingQid;
		if (findPendingChildQuestion(tid, pendingChildTid, pendingQuestion,
			pendingQid))
		{
			return McpResult(
				"Handoff cannot continue while sub-task question qid="
				~ to!string(pendingQid)
				~ " is waiting for your answer. "
				~ "Use mcp__cydo__Answer(...) first, or mcp__cydo__SwitchMode if you need a different mode before answering.",
				true);
		}

		td.pendingContinuation = new PendingContinuation(
			PendingContinuation.Kind.handoff, continuation, prompt);
		infof("Handoff: tid=%d continuation=%s (type %s → %s)",
			tid, continuation, td.taskType, contDef.task_type);

		return McpResult(
			"Handoff to '" ~ contDef.task_type
			~ "' accepted. Yield your turn IMMEDIATELY — do not call any more tools or generate output. "
			~ "A new task will be created with your prompt. Your session is ending.");
	}

	Promise!McpResult handleAskUserQuestion(string callerTid,
		AskQuestion[] questions)
	{
		import std.conv : to;

		int tid;
		try
			tid = to!int(callerTid);
		catch (Exception)
			return resolve(McpResult("Invalid calling task ID", true));

		auto td = host_.getTask(tid);
		if (td is null)
			return resolve(McpResult("Task not found", true));

		auto taskTypes = host_.taskTypesForProject(td.projectPath);
		auto typeDef = taskTypes.byName(td.taskType);
		if (typeDef is null
			|| !taskTypes.isInteractive(
				host_.entryPointsForProject(td.projectPath),
				td.taskType))
		{
			return resolve(McpResult(
				"AskUserQuestion is only available for interactive tasks. "
				~ "This task type (" ~ td.taskType
				~ ") is not interactive.",
				true));
		}

		if (tid in pendingAskUserQuestions_)
		{
			return resolve(McpResult(
				"Another AskUserQuestion is already pending for this task",
				true));
		}

		auto promise = new Promise!McpResult;
		pendingAskUserQuestions_[tid] = promise;

		auto toolUseId = format!"ask_%d"(tid);
		auto questionsJson = toJson(questions);
		td.pendingAskToolUseId = toolUseId;
		td.pendingAskQuestions = JSONFragment(questionsJson);

		host_.sendAskUserQuestionPrompt(tid,
			JSONFragment(questionsJson), toolUseId);

		td.needsAttention = true;
		host_.persistNeedsAttention(tid, true);
		td.hasPendingQuestion = true;
		td.notificationBody = "Waiting for your answer";
		td.isProcessing = false;
		host_.touchTask(tid);
		host_.persistLastActive(tid, td.lastActive);
		host_.broadcastTaskUpdate(tid);

		return promise;
	}

	Promise!McpResult handleBash(string callerTid, string command)
	{
		import std.conv : to;
		import std.algorithm : remove;

		int tid;
		try
			tid = to!int(callerTid);
		catch (Exception)
			return resolve(McpResult("Invalid calling task ID", true));

		auto td = host_.getTask(tid);
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
			null,
			workDir,
			1024 * 1024,
		);

		activeTerminals_ ~= terminal;

		auto promise = new Promise!McpResult;
		terminal.onExit = () {
			activeTerminals_ = activeTerminals_.remove!(t => t is terminal);
			auto output = terminal.output();
			promise.fulfill(McpResult(output, terminal.exitCode() != 0));
		};
		return promise;
	}

	Promise!McpResult registerBatchAndAwait(string callerTidStr,
		LaunchedTask[] launchedTasks)
	{
		import std.conv : to;

		int parentTid;
		try
			parentTid = to!int(callerTidStr);
		catch (Exception)
			return resolve(makeInternalBatchError(
				"invalid calling task ID for Task batch"));

		int[] childTids = new int[launchedTasks.length];
		foreach (i, ref launchedTask; launchedTasks)
		{
			if (launchedTask.promise is null)
			{
				return resolve(makeInternalBatchError(
					format!"missing child promise for slot %s"(i)));
			}
			childTids[i] = launchedTask.childTid;
		}

		BatchHandle handle;
		string batchError;
		if (!batchRegistry_.create(parentTid, childTids, handle, batchError))
			return resolve(makeInternalBatchError(batchError));

		foreach (i, ref launchedTask; launchedTasks)
		{
			(BatchHandle h, size_t slot, int cTid, Promise!McpResult promise) {
				promise.then((McpResult r) {
					string error;
					if (!batchRegistry_.enqueueChildDone(h, slot, cTid, r, error))
						errorf("batch router error: %s", error);
				});
			}(handle, i, launchedTask.childTid, launchedTask.promise);
		}

		return awaitBatchLoop(parentTid, handle.batchId);
	}

	Promise!McpResult handleAsk(string callerTidStr, string message,
		int targetTid)
	{
		return questionRouter_.handleAsk(callerTidStr, message, targetTid);
	}

	Promise!McpResult handleAnswer(string callerTidStr, int qid,
		string message)
	{
		return questionRouter_.handleAnswer(callerTidStr, qid, message);
	}

	Promise!McpResult handlePermissionPrompt(string callerTidStr,
		string toolUseId, string toolName, JSONFragment input)
	{
		import std.conv : to;

		int callerTidInt;
		try
			callerTidInt = to!int(callerTidStr);
		catch (Exception)
			return resolve(McpResult("Invalid calling task ID", true));

		auto callerTd = host_.getTask(callerTidInt);
		if (callerTd is null)
			return resolve(McpResult("Task not found", true));

		string policy = host_.workspacePermissionPolicy(callerTd.workspace);
		string resolved = evaluatePermissionPolicy(policy, toolName, input.json);

		if (resolved == "deny")
		{
			return resolve(McpResult(
				makePermissionDenyJson("Permission denied by policy"),
				false));
		}
		if (resolved == "allow")
			return resolve(McpResult(makePermissionAllowJson(input.json), false));

		return promptUserForPermission(callerTidInt, toolUseId, toolName,
			input);
	}

	void onToolCallDelivered(string callerTidStr)
	{
		import std.conv : to;

		int tid;
		try
			tid = to!int(callerTidStr);
		catch (Exception)
			return;

		auto td = host_.getTask(tid);
		if (td is null)
			return;

		bool hasLiveBatches;
		string batchError;
		if (!batchRegistry_.parentHasLiveBatches(tid, hasLiveBatches,
			batchError))
		{
			errorf("batch router invariant violated: %s", batchError);
			return;
		}
		if (hasLiveBatches)
			return;

		auto children = childrenOf(tid);
		if (children.length == 0)
			return;

		foreach (childTid; children)
			removeTaskDependency(tid, childTid);

		if (td.status == "waiting")
		{
			td.status = "active";
			host_.persistStatus(tid, "active");
			host_.broadcastTaskUpdate(tid);
		}
	}

	void onMcpDeliveryFailed(string callerTidStr)
	{
		import std.conv : to;

		int tid;
		try
			tid = to!int(callerTidStr);
		catch (Exception)
			return;

		if (host_.getTask(tid) is null)
			return;

		deliverBatchFallbackIfReady(tid);
	}

	void handleAskUserResponse(WsMessage json)
	{
		auto tid = json.tid;
		auto td = host_.getTask(tid);
		if (tid < 0 || td is null)
			return;

		auto pending = tid in pendingAskUserQuestions_;
		if (pending is null)
			return;

		td.pendingAskToolUseId = null;
		td.pendingAskQuestions = JSONFragment.init;
		td.needsAttention = false;
		host_.persistNeedsAttention(tid, false);
		td.hasPendingQuestion = false;
		td.notificationBody = "";
		td.isProcessing = true;

		string rawContent = json.content.json !is null
			? jsonParse!string(json.content.json)
			: "{}";
		string resultText = rawContent;
		bool isError = false;
		try
		{
			import std.array : join;
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
				resultText = "User has answered your questions: "
					~ parts.join(". ") ~ ".";
			}
		}
		catch (Exception e)
		{
			warningf("AskUserQuestion response parse error: %s", e.msg);
		}

		pending.fulfill(McpResult(resultText, isError));
		pendingAskUserQuestions_.remove(tid);
		host_.clearAskUserQuestionPrompt(tid);
		host_.broadcastTaskUpdate(tid);
	}

	void handlePermissionPromptResponse(WsMessage json)
	{
		auto tid = json.tid;
		auto td = host_.getTask(tid);
		if (tid < 0 || td is null)
			return;

		auto pending = tid in pendingPermissionPrompts_;
		if (pending is null)
			return;

		td.pendingPermissionToolUseId = null;
		td.pendingPermissionToolName = null;
		td.pendingPermissionInput = JSONFragment.init;
		td.needsAttention = false;
		host_.persistNeedsAttention(tid, false);
		td.hasPendingQuestion = false;
		td.notificationBody = "";
		td.isProcessing = true;

		string rawContent = json.content.json !is null
			? jsonParse!string(json.content.json)
			: "{}";
		string resultText;
		try
		{
			import std.json : parseJSON;

			auto parsed = parseJSON(rawContent);
			if (auto behavior = "behavior" in parsed)
			{
				if (behavior.str == "allow")
					resultText = makePermissionAllowJson(
						pendingPermissionInputs_[tid]);
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
		pendingPermissionPrompts_.remove(tid);
		pendingPermissionInputs_.remove(tid);
		host_.clearPermissionPrompt(tid);
		host_.broadcastTaskUpdate(tid);
	}

	void replayPendingClientPrompts(int tid,
		scope void delegate(string payload) send)
	{
		auto td = requireTask(tid,
			"Pending client prompt replay requires live task");

		if ((tid in pendingAskUserQuestions_) !is null
			&& td.pendingAskToolUseId.length > 0)
		{
			send(toJson(AskUserQuestionMessage("ask_user_question", tid,
				td.pendingAskToolUseId, td.pendingAskQuestions)));
		}

		if ((tid in pendingPermissionPrompts_) !is null
			&& td.pendingPermissionToolUseId.length > 0)
		{
			send(toJson(PermissionPromptMessage("permission_prompt", tid,
				td.pendingPermissionToolUseId, td.pendingPermissionToolName,
				td.pendingPermissionInput)));
		}
	}

	bool hasPendingSubTask(int tid)
	{
		return (tid in pendingSubTasks_) !is null;
	}

	bool hasTaskDependency(int tid)
	{
		return (tid in taskDeps_) !is null;
	}

	bool hasPendingChildQuestion(int tid)
	{
		int childTid;
		string question;
		int qid;
		return findPendingChildQuestion(tid, childTid, question, qid);
	}

	void sendPendingChildAnswerReminder(int tid)
	{
		import std.conv : to;

		int childTid;
		string question;
		int qid;
		if (!findPendingChildQuestion(tid, childTid, question, qid))
			return;

		auto childTd = requireTask(childTid,
			"Pending child question must belong to a live child task");
		auto parentTd = requireTask(tid,
			"Reminder target must be a live parent task");
		auto reminderSubject = subTaskWaitingForAnswerSubject(
			childTd.title, childTid, qid);
		auto reminderBody = host_.readPromptFile(
			"prompts/sub_task_waiting_for_answer.md",
			parentTd.projectPath,
			["question": question, "qid": to!string(qid)]);
		if (reminderBody.length == 0)
		{
			reminderBody = "Question: " ~ question ~ "\n\n"
				~ "Use mcp__cydo__Answer(" ~ to!string(qid)
				~ ", \"your answer\") to respond. You must answer before you can complete your turn.";
		}
		auto reminder = wrapKnownSystemMessage(
			host_.systemKeyword(),
			KnownSystemMessageKind.subTaskWaitingForAnswer,
			reminderBody,
			reminderSubject);
		auto askReminderMeta = host_.buildKnownSystemMessageMeta(
			KnownSystemMessageKind.subTaskWaitingForAnswer,
			reminderSubject,
			["question": question], "question");
		host_.sendTaskMessage(tid, [ContentBlock("text", reminder)],
			null, askReminderMeta, null);
	}

	bool finalizeCompletedSubTask(int tid, bool eagerDepCleanup = false)
	{
		return subtaskResultDelivery_.finalizeCompletedSubTask(tid,
			eagerDepCleanup);
	}

	bool deliverFailedPendingSubTaskResult(int tid)
	{
		return subtaskResultDelivery_.deliverFailedPendingSubTaskResult(tid);
	}

	void deliverWaitingParentResultsIfReady(int tid)
	{
		subtaskResultDelivery_.deliverWaitingParentResultsIfReady(tid);
	}

	void deliverBatchResults(int parentTid)
	{
		subtaskResultDelivery_.deliverBatchResults(parentTid);
	}

	void deliverBatchFallbackIfReady(int parentTid)
	{
		subtaskResultDelivery_.deliverBatchFallbackIfReady(parentTid);
	}

	void sendSystemRestartNudge(int tid)
	{
		subtaskResultDelivery_.sendSystemRestartNudge(tid);
	}

	void failPendingAskUserQuestionOnExit(int tid)
	{
		auto td = host_.getTask(tid);
		if (td is null)
			return;
		if (auto askPending = tid in pendingAskUserQuestions_)
		{
			askPending.fulfill(McpResult(
				"Session ended while waiting for user response", true));
			pendingAskUserQuestions_.remove(tid);
			td.pendingAskToolUseId = null;
			td.pendingAskQuestions = JSONFragment.init;
			td.needsAttention = false;
			host_.persistNeedsAttention(tid, false);
			td.hasPendingQuestion = false;
			td.notificationBody = "";
		}
	}

	void failPendingPermissionPromptOnExit(int tid)
	{
		auto td = host_.getTask(tid);
		if (td is null)
			return;
		if (auto permPending = tid in pendingPermissionPrompts_)
		{
			permPending.fulfill(McpResult(makePermissionDenyJson(
				"Task exited"), false));
			pendingPermissionPrompts_.remove(tid);
			pendingPermissionInputs_.remove(tid);
			td.pendingPermissionToolUseId = null;
			td.pendingPermissionToolName = null;
			td.pendingPermissionInput = JSONFragment.init;
		}
	}

	void failPendingAskRouteOnExit(int tid)
	{
		auto td = host_.getTask(tid);
		if (td is null)
			return;
		if (td.wasKilledByUser
			|| (td.pendingContinuation is null
				&& !hasPendingChildQuestion(tid)))
		{
			questionRouter_.failQuestionRoutesForAnswerer(tid,
				"Session ended while waiting for Ask response");
		}
		if (td.pendingAskPromise !is null && td.pendingAskQid > 0)
		{
			questionRouter_.failQuestionRoute(td.pendingAskQid,
				"Session ended while waiting for Ask response");
		}
	}

	void spawnContinuation(int tid)
	{
		auto td = requireTask(tid,
			"Continuation spawn requires a live task");
		auto typeDef = host_.taskTypesForProject(td.projectPath)
			.byName(td.taskType);
		auto contKey = td.pendingContinuation.key;
		auto hPrompt = td.pendingContinuation.handoffPrompt;
		td.pendingContinuation = null;

		if (typeDef is null)
		{
			errorf("spawnContinuation: unknown task type '%s' for tid=%d",
				td.taskType, tid);
			td.status = "failed";
			host_.persistStatus(tid, "failed");
			host_.broadcastTaskUpdate(tid);
			return;
		}

		auto contDefP = contKey in typeDef.continuations;
		if (contDefP is null)
		{
			errorf("spawnContinuation: unknown continuation '%s' for type '%s' tid=%d",
				contKey, td.taskType, tid);
			td.status = "failed";
			host_.persistStatus(tid, "failed");
			host_.broadcastTaskUpdate(tid);
			return;
		}

		executeContinuation(tid, *contDefP, hPrompt, contKey);
	}

	void spawnOnYieldContinuation(int tid)
	{
		auto td = requireTask(tid,
			"Task must exist for on_yield continuation");
		auto onYieldDef = host_.taskTypesForProject(td.projectPath)
			.byName(td.taskType);
		assert(onYieldDef !is null
			&& onYieldDef.on_yield.task_type.length > 0,
			format!"Task %d has no on_yield continuation"(tid));

		executeContinuation(tid, onYieldDef.on_yield, td.resultText,
			"on_yield");
	}

	void loadPersistedTaskDeps()
	{
		foreach (parentTid, children; host_.loadTaskDeps())
			foreach (childTid; children)
				taskDeps_[childTid] = parentTid;
	}

	bool waitingTaskChildrenAllDone(int parentTid)
	{
		foreach (childTid, depParent; taskDeps_)
		{
			if (depParent != parentTid)
				continue;
			auto child = host_.getTask(childTid);
			if (child is null)
				continue;
			if (child.status != "completed"
				&& child.status != "failed"
				&& child.status != "importable")
			{
				tracef("resumeInFlightTasks: tid=%d waiting, child tid=%d still %s",
					parentTid, childTid, child.status);
				return false;
			}
		}
		return true;
	}

	void killActiveTerminals()
	{
		foreach (t; activeTerminals_)
			t.forceKill();
		activeTerminals_ = null;
	}

private:
	TaskData* requireTask(int tid, string message)
	{
		auto td = host_.getTask(tid);
		assert(td !is null, format!"%s (tid=%d)"(message, tid));
		return td;
	}

	int[] childrenOf(int parentTid)
	{
		int[] children;
		foreach (childTid, depParent; taskDeps_)
			if (depParent == parentTid)
				children ~= childTid;
		return children;
	}

	void removeTaskDependency(int parentTid, int childTid)
	{
		host_.persistRemoveTaskDep(parentTid, childTid);
		taskDeps_.remove(childTid);
		liveDeliveredSubTasks_.remove(childTid);
	}

	McpResult makeInternalBatchError(string message)
	{
		errorf("batch router error: %s", message);
		return McpResult("Internal batch routing error: " ~ message, true);
	}

	Promise!McpResult awaitBatchLoop(int parentTid, ulong batchId)
	{
		auto handle = BatchHandle(parentTid, batchId);
		if (!batchRegistry_.exists(handle))
		{
			return resolve(makeInternalBatchError(
				format!"no active batch for parent tid=%d batch=%s"(
					parentTid, batchId)));
		}

		while (true)
		{
			Promise!BatchSignal event;
			string batchError;
			if (!batchRegistry_.waitOne(handle, event, batchError))
			{
				if (batchError.length > 0)
					return resolve(makeInternalBatchError(batchError));
				break;
			}

			auto sig = event.await();
			auto consumed = batchRegistry_.consume(handle, sig,
				(int childTid, int qid) => questionRouter_
					.childHasPendingQuestion(childTid, qid),
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
					return resolve(questionRouter_.buildQuestionResult(
						consumed.childTid, consumed.qid,
						consumed.questionText));
				case BatchConsumeKind.invalid:
					errorf("ignoring invalid batch signal for parent=%d batch=%s: %s",
						parentTid, batchId, consumed.error);
					break;
			}
		}

		McpResult[] results;
		string batchError;
		if (!batchRegistry_.finalize(handle, results, batchError))
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

	Promise!McpResult promptUserForPermission(int tid, string toolUseId,
		string toolName, JSONFragment input)
	{
		if (tid in pendingPermissionPrompts_)
		{
			return resolve(McpResult(makePermissionDenyJson(
				"Another permission prompt is already pending"),
				false));
		}

		auto promise = new Promise!McpResult;
		pendingPermissionPrompts_[tid] = promise;
		pendingPermissionInputs_[tid] = input.json;

		auto td = requireTask(tid,
			"Permission prompt target must be a live task");
		td.pendingPermissionToolUseId = toolUseId;
		td.pendingPermissionToolName = toolName;
		td.pendingPermissionInput = input;

		host_.sendPermissionPrompt(tid, toolUseId, toolName, input);

		td.needsAttention = true;
		host_.persistNeedsAttention(tid, true);
		td.hasPendingQuestion = true;
		td.notificationBody = "Permission requested";
		td.isProcessing = false;
		host_.touchTask(tid);
		host_.persistLastActive(tid, td.lastActive);
		host_.broadcastTaskUpdate(tid);

		return promise;
	}

	bool findPendingChildQuestion(int tid, out int childTid,
		out string question, out int qid)
	{
		string batchError;
		if (!batchRegistry_.findFirstLiveChild(tid, (int cTid) {
			auto child = host_.getTask(cTid);
			return child !is null && child.pendingAskPromise !is null;
		}, childTid, batchError))
		{
			if (batchError.length > 0)
				errorf("batch router invariant violated: %s", batchError);
			return false;
		}

		auto child = requireTask(childTid,
			"Pending child question must belong to a live child task");
		question = child.pendingAskQuestion;
		qid = child.pendingAskQid;
		return true;
	}

	void executeContinuation(int tid, ContinuationDef contDef,
		string handoffPrompt, string edgeName)
	{
		auto td = requireTask(tid,
			"Continuation execution requires a live task");
		auto newTypeDef = host_.taskTypesForProject(td.projectPath)
			.byName(contDef.task_type);
		if (newTypeDef is null)
		{
			errorf("executeContinuation: unknown successor type '%s' for tid=%d",
				contDef.task_type, tid);
			td.status = "failed";
			host_.persistStatus(tid, "failed");
			host_.broadcastTaskUpdate(tid);
			return;
		}

		infof("Continuation: tid=%d %s → %s (keep_context=%s)",
			tid, td.taskType, contDef.task_type, contDef.keep_context);

		auto resultText = td.resultText;

		if (contDef.keep_context)
		{
			auto sourceTaskType = td.taskType;
			td.taskType = contDef.task_type;
			host_.persistTaskType(tid, contDef.task_type);

			host_.emitTaskReload(tid, "continuation");

			td.status = "active";
			host_.persistStatus(tid, "active");

			auto renderedContinuationPrompt = renderContinuationPrompt(contDef,
				"Continue from where you left off.",
				host_.promptSearchPath(td.projectPath),
				["result_text": resultText,
					"output_dir": host_.taskDir(td)]);
			renderedContinuationPrompt = "`SwitchMode` to `" ~ edgeName
				~ "` successful.\n\n" ~ renderedContinuationPrompt;
			renderedContinuationPrompt = prependTaskFraming(
				renderedContinuationPrompt,
				host_.taskSystemPromptForMessage(tid, newTypeDef),
				loadProjectMemory(newTypeDef, td.repoPath,
					host_.promptSearchPath(td.projectPath)));
			auto modeSwitchMsgSubject = modeSwitchSubject(
				sourceTaskType, edgeName);
			auto contMeta = host_.buildKnownSystemMessageMeta(
				KnownSystemMessageKind.modeSwitch,
				modeSwitchMsgSubject, null, null);
			host_.ensureProcessQueueAlive(tid).then(() {
				host_.sendTaskMessage(tid,
					[ContentBlock("text", wrapKnownSystemMessage(
						host_.systemKeyword(),
						KnownSystemMessageKind.modeSwitch,
						renderedContinuationPrompt,
						modeSwitchMsgSubject))],
					null, contMeta, null);
				sendPendingChildAnswerReminder(tid);
			}).ignoreResult();
		}
		else
		{
			auto contAgent = host_.resolveTaskAgent(newTypeDef.agent,
				td.agentType);
			if (contAgent.length == 0
				|| !host_.isRegisteredAgent(contAgent))
			{
				td.status = "failed";
				td.error = format(
					"Successor type '%s' resolved agent to '%s' (parent='%s') — not a registered agent",
					contDef.task_type, contAgent, td.agentType);
				host_.persistStatus(tid, "failed");
				host_.appendSynthesizedHistoryError(tid,
					"Continuation failed", td.error);
				host_.broadcastTaskUpdate(tid);
				return;
			}

			td.status = "completed";
			host_.persistStatus(tid, "completed");
			host_.emitTaskReload(tid, "continuation");

			auto successorPrompt = handoffPrompt.length > 0
				? handoffPrompt
				: td.description;
			auto childTid = host_.createTask(td.workspace, td.projectPath,
				contAgent);
			auto childTd = requireTask(childTid,
				"Created continuation task must exist");
			childTd.taskType = contDef.task_type;
			childTd.description = successorPrompt;
			childTd.parentTid = tid;
			childTd.relationType = "continuation";
			childTd.title = td.title;

			host_.persistTaskType(childTid, contDef.task_type);
			host_.persistDescription(childTid, successorPrompt);
			host_.persistParentTid(childTid, tid);
			host_.persistRelationType(childTid, "continuation");
			host_.persistTitle(childTid, childTd.title);

			host_.broadcastTaskCreated(TaskCreatedMessage("task_created",
				childTid, td.workspace, td.projectPath, tid, "continuation"));
			host_.broadcastTaskUpdate(childTid);
			host_.broadcastFocusHint(tid, childTid);

			if (auto pending = tid in pendingSubTasks_)
			{
				pendingSubTasks_[childTid] = *pending;
				pendingSubTasks_.remove(tid);
				host_.persistRemoveAllChildDeps(tid);
				host_.persistAddTaskDep(td.parentTid, childTid);
				taskDeps_.remove(tid);
				liveDeliveredSubTasks_.remove(tid);
				taskDeps_[childTid] = td.parentTid;
			}

			host_.setupWorktreeForEdge(childTid, tid, contDef.worktree);

			auto renderedSuccessorPrompt = renderPrompt(*newTypeDef,
				successorPrompt,
				host_.promptSearchPath(childTd.projectPath),
				host_.outputPath(childTd),
				contDef.prompt_template,
				["result_text": resultText]);
			renderedSuccessorPrompt = prependTaskFraming(
				renderedSuccessorPrompt,
				host_.taskSystemPromptForMessage(childTid, newTypeDef),
				loadProjectMemory(newTypeDef, childTd.repoPath,
					host_.promptSearchPath(childTd.projectPath)));
			auto handoffMsgSubject = handoffSubject(td.taskType, edgeName);
			auto handoffMeta = host_.buildKnownSystemMessageMeta(
				KnownSystemMessageKind.handoff,
				handoffMsgSubject,
				["task_description": successorPrompt],
				"task_description");
			host_.ensureProcessQueueAlive(childTid).then(() {
				host_.sendTaskMessage(childTid,
					[ContentBlock("text", wrapKnownSystemMessage(
						host_.systemKeyword(),
						KnownSystemMessageKind.handoff,
						renderedSuccessorPrompt,
						handoffMsgSubject))],
					null, handoffMeta, null);
			}).ignoreResult();

			host_.broadcastTaskUpdate(tid);
		}
	}
}
