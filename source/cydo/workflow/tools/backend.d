module cydo.workflow.tools.backend;

import core.time : Duration;
import std.format : format;
import std.logger : errorf, infof, tracef, warningf;
import std.process : execute;
import std.string : strip;

import ae.sys.timing : TimerTask, setTimeout;
import ae.utils.json : JSONFragment, jsonParse, toJson;
import ae.utils.promise : Promise, resolve;
import ae.utils.promise.await : await;

import cydo.agent.contract : Agent;
import cydo.agent.terminal : TerminalProcess;
import cydo.domain.policy.permissions : PermissionEscalation, PermissionPrompt,
	PermissionSettings, ToolCallDecision, ToolCallRuling, evaluatePermissionPolicy,
	makePermissionAllowJson, makePermissionDenyJson;
import cydo.domain.task_types.definition : ContinuationDef, CreatableTaskDef, DjinjaTemplate, TaskTypeDef,
	UserEntryPointDef, WorktreeMode, byName, isInteractive,
	loadProjectMemory, renderContinuationPrompt, renderPrompt, resolveAgent,
	substituteVars;
import cydo.domain.tasks.model;
import cydo.domain.tasks.lifecycle : TaskNotificationChange;
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
	void delegate(int tid, TaskStatus expectedFrom, TaskStatus to,
		TaskNotificationChange notification) transitionTask;
	void delegate(int tid, TaskStatus[] expectedFrom, TaskStatus to,
		TaskNotificationChange notification) transitionTaskFrom;
	void delegate(int tid, bool needsAttention) persistNeedsAttention;
	void delegate(int tid, long lastActive) persistLastActive;
	void delegate(int tid, string resultText) persistResultText;
	void delegate(int tid, string taskStartHead) persistTaskStartHead;
	void delegate(int tid) touchTask;

	TaskTypeDef[] delegate(string projectPath) taskTypesForProject;
	UserEntryPointDef[] delegate(string projectPath) entryPointsForProject;
	string[] delegate(string projectPath) promptSearchPath;
	bool[string] delegate(string projectPath) treeReadOnlyForProject;
	string delegate(DjinjaTemplate requestedAgent, string parentAgent, string workspace) resolveTaskAgent;
	bool delegate(string agentName) isConfiguredAgentName;
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
	bool delegate(string projectPath, string taskTypeName) taskProducesCommitOutput;
	void delegate(int childTid, int parentTid, WorktreeMode mode) setupWorktreeForEdge;
	Promise!void delegate(int tid) ensureProcessQueueAlive;
	Promise!void delegate(int tid, const(ContentBlock)[] content,
		const(ContentBlock)[] broadcastContent, string cydoMeta,
		string nonce) sendTaskMessage;
	void delegate(int tid, string reason, string excludedUserUuid) emitTaskReload;
	void delegate(int tid, string subject,
		string body) appendTaskDiagnostic;
	void delegate(int tid, string subject,
		string body) appendAndBroadcastRecoveryDeliveryDiagnostic;

	bool delegate(int tid) taskAlive;
	/// The task that lands work for the project of `callerTid`, started if
	/// the project has none and then ready to be asked; 0 if the project
	/// has no integrator.
	Promise!int delegate(int callerTid) integratorForTask;
	string delegate(const TaskData* td) effectiveCwd;
	bool delegate(int aTid, int bTid) tasksShareWorkspace;
	string delegate(int tid) taskWorkspaceLabel;
	void delegate(int tid, void delegate() cb) addIdleCallback;
	Promise!void delegate(int tid) reactivateTask;
	Promise!void delegate(int tid, KnownSystemMessageKind kind, string body)
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
	void delegate(int tid, PermissionPrompt prompt) sendPermissionPrompt;
	void delegate(int tid) clearPermissionPrompt;
	void delegate(int parentTid, int childTid, int specIndex)
		appendTaskSpawnedEvent;
	void delegate(TaskCreatedMessage message) broadcastTaskCreated;

	PermissionSettings delegate(string agentName, string workspaceName) permissionSettings;
	void delegate(void delegate() cb) onNextTick;
	void delegate(int tid, string prompt) generateTitle;
}

unittest
{
	import ae.net.asockets : onNextTick, socketManager;
	import ae.utils.promise : reject;
	import ae.utils.promise.await : async;
	import cydo.domain.task_types.definition : CreatableTaskDef;
	import cydo.protocol : BatchResultEnvelope;
	import cydo.mcp.tools : CydoToolsImpl, TaskSpec;
	import cydo.runtime.config : SandboxConfig;
	import std.conv : to;
	import std.path : buildPath;

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

	TaskTypeDef parentType;
	parentType.name = "parent";
	parentType.agent = "fake";
	CreatableTaskDef edge;
	edge.name = "child";
	edge.worktree = WorktreeMode.fork;
	parentType.creatable_tasks = [edge];
	TaskTypeDef childType;
	childType.name = "child";
	childType.agent = "fake";
	ContinuationDef continuation;
	continuation.task_type = "child";
	parentType.continuations["continue"] = continuation;
	auto taskTypes = [parentType, childType];

	TaskData[int] tasks;
	tasks[1] = TaskData(1, "local", "/tmp/cydo-task-startup-failure");
	tasks[1].taskType = "parent";
	tasks[1].agentName = "fake";
	int nextTid = 2;

	auto backend = new WorkflowToolsBackend(WorkflowToolsHost(
		getTask: (int tid) { auto td = tid in tasks; return td is null ? null : td; },
		createTask: (string workspace, string projectPath, string agentName) {
			auto tid = nextTid++; tasks[tid] = TaskData(tid, workspace, projectPath);
			tasks[tid].agentName = agentName; return tid;
		},
		persistTaskType: (int tid, string taskType) {},
		persistDescription: (int tid, string description) {},
		persistParentTid: (int tid, int parentTid) {},
		persistRelationType: (int tid, string relationType) {},
		persistTitle: (int tid, string title) {},
		transitionTask: (int tid, TaskStatus expectedFrom, TaskStatus to, TaskNotificationChange notification) {
			assert(tasks[tid].status == expectedFrom); tasks[tid].status = to;
		},
		transitionTaskFrom: (int tid, TaskStatus[] expectedFrom, TaskStatus to, TaskNotificationChange notification) {
			bool expected; foreach (from; expectedFrom) expected = expected || tasks[tid].status == from;
			assert(expected); tasks[tid].status = to;
		},
		persistNeedsAttention: (int tid, bool needsAttention) {},
		persistLastActive: (int tid, long lastActive) {},
		persistResultText: (int tid, string resultText) {},
		touchTask: (int tid) {},
		taskTypesForProject: (string projectPath) => taskTypes,
		entryPointsForProject: (string projectPath) => cast(UserEntryPointDef[]) null,
		promptSearchPath: (string projectPath) => cast(string[]) null,
		treeReadOnlyForProject: (string projectPath) => cast(bool[string]) null,
		resolveTaskAgent: (DjinjaTemplate requestedAgent, string parentAgent, string workspace) => "fake",
		isConfiguredAgentName: (string agentName) => agentName == "fake",
		agentForTask: (int tid) { assert(0); return cast(Agent) null; },
		taskSystemPromptForMessage: (int tid, TaskTypeDef* typeDef) => "",
		readPromptFile: (string relativePath, string projectPath, string[string] vars) => "",
		buildKnownSystemMessageMeta: (KnownSystemMessageKind kind, string subject, string[string] vars, string bodyVar) => "{}",
		systemKeyword: () => "SYSTEM",
		taskDir: (const TaskData* td) => buildPath("/tmp", "cydo-task-startup-failure", "tasks", td.tid.to!string),
		outputPath: (const TaskData* td) => buildPath("/tmp", "cydo-task-startup-failure", "tasks", td.tid.to!string, "output.md"),
		worktreePath: (const TaskData* td) => buildPath("/tmp", "cydo-task-startup-failure", "tasks", td.tid.to!string, "worktree"),
		taskProducesCommitOutput: (string projectPath, string taskTypeName) => false,
		setupWorktreeForEdge: (int childTid, int parentTid, WorktreeMode mode) {},
		ensureProcessQueueAlive: (int tid) => tid == 2 ? reject!void(new Exception("simulated child session startup failure")) : resolve(),
		sendTaskMessage: (int tid, const(ContentBlock)[] content, const(ContentBlock)[] broadcastContent, string cydoMeta, string nonce) { assert(tid == 3); return resolve(); },
		emitTaskReload: (int tid, string reason, string excludedUserUuid) {},
		appendTaskDiagnostic: (int tid, string subject, string body) {},
		taskAlive: (int tid) => false, tasksShareWorkspace: (int aTid, int bTid) => true,
		taskWorkspaceLabel: (int tid) => "local", addIdleCallback: (int tid, void delegate() cb) {},
		reactivateTask: (int tid) => resolve(),
		sendKnownSystemMessage: (int tid, KnownSystemMessageKind kind, string body) { return resolve(); },
		persistAddTaskDep: (int parentTid, int childTid) {}, persistRemoveTaskDep: (int parentTid, int childTid) {},
		persistRemoveAllChildDeps: (int childTid) {}, loadTaskDeps: () => cast(int[][int]) null,
		broadcastTaskUpdate: (int tid) {}, broadcastFocusHint: (int fromTid, int toTid) {},
		sendAskUserQuestionPrompt: (int tid, JSONFragment questions, string toolUseId) {},
		clearAskUserQuestionPrompt: (int tid) {},
		sendPermissionPrompt: (int tid, PermissionPrompt prompt) {},
		clearPermissionPrompt: (int tid) {}, appendTaskSpawnedEvent: (int parentTid, int childTid, int specIndex) {},
		broadcastTaskCreated: (TaskCreatedMessage message) {}, permissionSettings: (string agentName, string workspaceName) => PermissionSettings.init,
		onNextTick: (void delegate() cb) { onNextTick(socketManager, cb); }, generateTitle: (int tid, string prompt) {},
	));

	auto tools = new CydoToolsImpl(backend, "1");
	bool resolved;
	McpResult result;
	async({ return tools.createTasks([TaskSpec("child startup", "child", "trigger child startup failure")]); }).then((McpResult r) { resolved = true; result = r; });
	drainPromiseNextTicks();
	assert(resolved);
	assert(result.isError);
	auto batch = jsonParse!BatchResultEnvelope(result.text);
	auto taskResult = jsonParse!TaskResult(batch.tasks[0].json);
	assert(taskResult.status == "error");
	assert(taskResult.summary == "simulated child session startup failure");
	assert(taskResult.error == "simulated child session startup failure");
	assert(tasks[2].projectPath == "/tmp/cydo-task-startup-failure");
	tasks[1].pendingContinuation = new PendingContinuation(PendingContinuation.Kind.handoff, "continue", "follow-up");
	backend.spawnContinuation(1);
	assert(tasks[3].projectPath == "/tmp/cydo-task-startup-failure");
}

final class WorkflowToolsBackend : ToolsBackend
{
private:
	WorkflowToolsHost host_;
	Promise!(McpResult)[int] pendingSubTasks_;
	int[int] taskDeps_;
	bool[int] liveDeliveredSubTasks_;
	Promise!(McpResult)[int] pendingAskUserQuestions_;
	/// Fulfilled with the decision payload sent back to the agent.
	Promise!string[int] pendingPermissionPrompts_;
	string[int] pendingPermissionInputs_;
	/// Deny a pending permission prompt nobody answers in time.
	TimerTask[int] permissionPromptTimeouts_;
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
				taskProducesCommitOutput: host_.taskProducesCommitOutput,
				transitionTask: host_.transitionTask,
				transitionTaskFrom: host_.transitionTaskFrom,
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
				parentTaskForChild: &parentTaskForChild,
				childTaskIds: &childrenOf,
				wasLiveDelivered: (int childTid) {
					return (childTid in liveDeliveredSubTasks_) !is null;
				},
				markLiveDelivered: (int childTid) {
					liveDeliveredSubTasks_[childTid] = true;
				},
				ensureProcessQueueAlive: host_.ensureProcessQueueAlive,
				sendKnownSystemMessage: host_.sendKnownSystemMessage,
				removeTaskDependency: &removeTaskDependency,
				taskAlive: host_.taskAlive,
				onNextTick: host_.onNextTick,
				appendAndBroadcastRecoveryDeliveryDiagnostic:
					host_.appendAndBroadcastRecoveryDeliveryDiagnostic,
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
				return host_.sendTaskMessage(tid, content, null, cydoMeta, nonce);
			},
			transitionTask: host_.transitionTask,
			transitionTaskFrom: host_.transitionTaskFrom,
			persistResultText: host_.persistResultText,
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
					batchRegistry_.enqueueChildDone(handle, 0, childTid, r);
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
			parentTd.agentName, parentTd.workspace);
		if (childAgent.length == 0 || !host_.isConfiguredAgentName(childAgent))
		{
			return ValidatedTask(structuredTaskError(format(
				"task type '%s' resolves agent to '%s' (parent='%s') — not a configured agent",
				resolvedTaskType, childAgent, parentTd.agentName)));
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
			if (pd.status != TaskStatus.waiting)
				host_.transitionTaskFrom(parentTid,
					[TaskStatus.pending, TaskStatus.active], TaskStatus.waiting,
					TaskNotificationChange.preserve);

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

			if (host_.taskProducesCommitOutput(childTd.projectPath,
				childTd.taskType) && childTd.hasWorktree)
			{
				auto headResult = execute(["git", "-C", host_.worktreePath(childTd),
					"rev-parse", "HEAD"]);
				auto taskStartHead = headResult.output.strip;
				if (headResult.status != 0 || taskStartHead.length == 0)
				{
					childTd.error = "Failed to capture task start HEAD in "
						~ host_.worktreePath(childTd) ~ " (status "
						~ format!"%d"(headResult.status) ~ "): "
						~ headResult.output.strip;
					childTd.resultText = childTd.error;
					host_.persistResultText(childTid, childTd.resultText);
					host_.transitionTaskFrom(childTid,
						[TaskStatus.pending, TaskStatus.active], TaskStatus.failed,
						TaskNotificationChange.preserve);
					if (hasPendingSubTask(childTid))
						deliverFailedPendingSubTaskResult(childTid);
					return LaunchedTask(childTid, promise);
				}
				childTd.taskStartHead = taskStartHead;
				host_.persistTaskStartHead(childTid, childTd.taskStartHead);
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
				return host_.sendTaskMessage(childTid,
					[ContentBlock("text", wrapKnownSystemMessage(
						host_.systemKeyword(),
						KnownSystemMessageKind.taskPrompt,
						renderedPrompt,
						taskPromptMsgSubject))],
					null, subtaskMeta, null);
			}).except((Exception e) {
				auto failedChild = requireTask(childTid,
					"Created child task must exist when launch fails");
				if (failedChild.status != TaskStatus.failed)
				{
					failedChild.error = e.msg;
					failedChild.resultText = e.msg;
					host_.persistResultText(childTid, failedChild.resultText);
					host_.transitionTaskFrom(childTid,
						[TaskStatus.pending, TaskStatus.active], TaskStatus.failed,
						TaskNotificationChange.preserve);
				}
				if (hasPendingSubTask(childTid))
					deliverFailedPendingSubTaskResult(childTid);
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

		auto result = McpResult(
			"Mode switch to '" ~ contDef.task_type
			~ "' accepted. Yield your turn IMMEDIATELY — do not call any more tools or generate output. "
			~ "You will receive new instructions when your session resumes.");
		td.pendingContinuation = new PendingContinuation(
			PendingContinuation.Kind.switchMode, continuation, null, result.text);
		infof("SwitchMode: tid=%d continuation=%s (type %s → %s)",
			tid, continuation, td.taskType, contDef.task_type);

		return result;
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

		auto result = McpResult(
			"Handoff to '" ~ contDef.task_type
			~ "' accepted. Yield your turn IMMEDIATELY — do not call any more tools or generate output. "
			~ "A new task will be created with your prompt. Your session is ending.");
		td.pendingContinuation = new PendingContinuation(
			PendingContinuation.Kind.handoff, continuation, prompt, result.text);
		infof("Handoff: tid=%d continuation=%s (type %s → %s)",
			tid, continuation, td.taskType, contDef.task_type);

		return result;
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
					batchRegistry_.enqueueChildDone(h, slot, cTid, r);
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

	/// Land: a question to the project's integrator, which answers once the
	/// work has landed or needs more work.
	Promise!McpResult handleLand(string callerTidStr, string message)
	{
		import std.conv : to;

		int callerTid;
		try
			callerTid = to!int(callerTidStr);
		catch (Exception)
			return resolve(McpResult("Invalid calling task ID", true));
		auto callerTd = host_.getTask(callerTid);
		if (callerTd is null)
			return resolve(McpResult("Task not found", true));

		auto request = host_.readPromptFile("prompts/land_request.md",
			callerTd.projectPath, [
				"message": message,
				"directory": host_.effectiveCwd(callerTd),
			]);
		return host_.integratorForTask(callerTid).then((int integratorTid) {
			if (integratorTid == 0)
				return resolve(McpResult("This project has no integrator", true));
			return questionRouter_.handleAsk(callerTidStr, request, integratorTid);
		}, (Exception e) => resolve(McpResult(e.msg, true)));
	}

	/// Decide a tool call the agent of `tid` asks about after the policy's
	/// first ruling (`decidePreToolUse`): by asking the user, or, for a call
	/// the agent's safety checks flag, by the policy again (as dangerous).
	/// Fulfils with the decision payload (`{"behavior":"allow",…}` /
	/// `{"behavior":"deny",…}`).
	Promise!string decideToolPermission(int tid, PermissionPrompt prompt,
		PermissionEscalation escalation)
	{
		auto td = requireTask(tid, "Tool permission request for a missing task");
		auto settings = host_.permissionSettings(td.agentName, td.workspace);
		final switch (escalation)
		{
			case PermissionEscalation.policyAsk:
			case PermissionEscalation.classifier:
				return promptUserForPermission(tid, prompt, settings.promptTimeout);
			case PermissionEscalation.safetyCheck:
				break;
		}
		auto ruling = rulePolicy(td, prompt.toolName, prompt.input, true);
		final switch (ruling.decision)
		{
			case ToolCallDecision.deny:
				return resolve(makePermissionDenyJson(ruling.denyReason));
			case ToolCallDecision.allow:
				return resolve(makePermissionAllowJson(prompt.input.json));
			case ToolCallDecision.ask:
			// The classifier has had its say already.
			case ToolCallDecision.classifier:
				return promptUserForPermission(tid, prompt, settings.promptTimeout);
		}
	}

	/// The workspace policy's ruling on a tool call of `tid`, which stands
	/// before the agent's own permission checks (and its auto mode
	/// classifier) run.
	ToolCallRuling decidePreToolUse(int tid, string toolName, JSONFragment input)
	{
		auto td = requireTask(tid, "Tool call decision for a missing task");
		return rulePolicy(td, toolName, input, false);
	}

	private ToolCallRuling rulePolicy(TaskData* td, string toolName,
		JSONFragment input, bool dangerous)
	{
		auto settings = host_.permissionSettings(td.agentName, td.workspace);
		final switch (evaluatePermissionPolicy(settings.policy, settings.autoMode,
			toolName, input.json, dangerous))
		{
			case "allow":
				return ToolCallRuling(ToolCallDecision.allow);
			case "deny":
				return ToolCallRuling(ToolCallDecision.deny, "Permission denied by policy");
			case "ask":
				return ToolCallRuling(ToolCallDecision.ask);
			case "auto":
				if (!settings.autoMode)
					return ToolCallRuling(ToolCallDecision.deny,
						"Permission denied: the policy leaves this call to auto mode, which is not enabled for this workspace");
				return ToolCallRuling(ToolCallDecision.classifier);
		}
	}

	/// The agent no longer awaits the decision for `toolUseId` (e.g. its turn
	/// was interrupted): take the prompt down.
	void withdrawToolPermissionPrompt(int tid, string toolUseId)
	{
		auto td = requireTask(tid, "Withdrawn tool permission request for a missing task");
		// A concurrent request refused with "Another permission prompt is
		// already pending" never had a prompt of its own.
		if ((tid in pendingPermissionPrompts_) is null
			|| td.pendingPermission.toolUseId != toolUseId)
			return;
		settlePermissionPrompt(tid,
			makePermissionDenyJson("Permission request withdrawn by the agent"));
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

		if (batchRegistry_.parentHasLiveBatches(tid))
			return;

		auto children = childrenOf(tid);
		if (children.length == 0)
			return;

		foreach (childTid; children)
			removeTaskDependency(tid, childTid);

		if (td.status == TaskStatus.waiting)
			host_.transitionTask(tid, TaskStatus.waiting, TaskStatus.active,
				TaskNotificationChange.preserve);
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

		deliverBatchFallbackIfReady(tid).except((Exception e) {
			auto current = requireTask(tid,
				"Recovered MCP fallback parent must exist when delivery rejects");
			if (current.status == TaskStatus.active || current.status == TaskStatus.alive)
				host_.transitionTaskFrom(tid,
					[TaskStatus.active, TaskStatus.alive], TaskStatus.waiting,
					TaskNotificationChange.preserve);
			assert(current.status == TaskStatus.waiting
				|| current.status == TaskStatus.failed,
				"Recovered MCP fallback rejection escaped its process owner state");
		}).ignoreResult();
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

		if ((tid in pendingPermissionPrompts_) is null)
			return;

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

		settlePermissionPrompt(tid, resultText);
	}

	/// Answer the pending permission prompt of `tid` and take it down.
	private void settlePermissionPrompt(int tid, string decision)
	{
		auto td = requireTask(tid, "Settled permission prompt for a missing task");
		auto pending = pendingPermissionPrompts_[tid];
		pendingPermissionPrompts_.remove(tid);
		pendingPermissionInputs_.remove(tid);
		cancelPermissionPromptTimeout(tid);

		td.pendingPermission = PermissionPrompt.init;
		td.needsAttention = false;
		host_.persistNeedsAttention(tid, false);
		td.hasPendingQuestion = false;
		td.notificationBody = "";
		td.isProcessing = true;

		pending.fulfill(decision);
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
			&& td.pendingPermission.toolUseId.length > 0)
		{
			send(toJson(PermissionPromptMessage.of(tid, td.pendingPermission)));
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

	int parentTaskForChild(int childTid)
	{
		auto parentTid = childTid in taskDeps_;
		return parentTid is null ? 0 : *parentTid;
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
			null, askReminderMeta, null).except((Exception e) {
			questionRouter_.failQuestionRoute(qid,
				"Failed to submit sub-task answer reminder: " ~ e.msg);
		}).ignoreResult();
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

	Promise!void deliverWaitingParentResultsIfReady(int tid)
	{
		return subtaskResultDelivery_.deliverWaitingParentResultsIfReady(tid);
	}

	Promise!void deliverBatchResults(int parentTid)
	{
		return subtaskResultDelivery_.deliverBatchResults(parentTid);
	}

	Promise!void deliverBatchFallbackIfReady(int parentTid)
	{
		return subtaskResultDelivery_.deliverBatchFallbackIfReady(parentTid);
	}

	Promise!void sendSystemRestartNudge(int tid)
	{
		return subtaskResultDelivery_.sendSystemRestartNudge(tid);
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

	private void cancelPermissionPromptTimeout(int tid)
	{
		if (auto timer = tid in permissionPromptTimeouts_)
		{
			timer.cancel();
			permissionPromptTimeouts_.remove(tid);
		}
	}

	void failPendingPermissionPromptOnExit(int tid)
	{
		auto td = host_.getTask(tid);
		if (td is null)
			return;
		if (auto permPending = tid in pendingPermissionPrompts_)
		{
			permPending.fulfill(makePermissionDenyJson("Task exited"));
			pendingPermissionPrompts_.remove(tid);
			pendingPermissionInputs_.remove(tid);
			cancelPermissionPromptTimeout(tid);
			td.pendingPermission = PermissionPrompt.init;
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
		auto repairedInterruptionUuid = td.pendingContinuation.repairedInterruptionUuid;
		td.pendingContinuation = null;

		if (typeDef is null)
		{
			errorf("spawnContinuation: unknown task type '%s' for tid=%d",
				td.taskType, tid);
			host_.transitionTaskFrom(tid,
				[TaskStatus.pending, TaskStatus.active, TaskStatus.alive,
					TaskStatus.waiting, TaskStatus.completed], TaskStatus.failed,
				TaskNotificationChange.preserve);
			return;
		}

		auto contDefP = contKey in typeDef.continuations;
		if (contDefP is null)
		{
			errorf("spawnContinuation: unknown continuation '%s' for type '%s' tid=%d",
				contKey, td.taskType, tid);
			host_.transitionTaskFrom(tid,
				[TaskStatus.pending, TaskStatus.active, TaskStatus.alive,
					TaskStatus.waiting, TaskStatus.completed], TaskStatus.failed,
				TaskNotificationChange.preserve);
			return;
		}

		executeContinuation(tid, *contDefP, hPrompt, contKey,
			repairedInterruptionUuid);
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

	WaitingTaskDependencyState waitingTaskDependencyState(int parentTid)
	{
		bool hasChildren;
		foreach (childTid, depParent; taskDeps_)
		{
			if (depParent != parentTid)
				continue;
			hasChildren = true;
			auto child = host_.getTask(childTid);
			if (child is null)
				continue;
			if (child.status != TaskStatus.completed
				&& child.status != TaskStatus.failed
				&& child.status != TaskStatus.importable)
			{
				tracef("resumeInFlightTasks: tid=%d waiting, child tid=%d still %s",
					parentTid, childTid, child.status);
				return WaitingTaskDependencyState.hasNonTerminalChildren;
			}
		}
		return hasChildren
			? WaitingTaskDependencyState.allChildrenTerminal
			: WaitingTaskDependencyState.noChildren;
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

	Promise!string promptUserForPermission(int tid, PermissionPrompt prompt,
		Duration timeout)
	{
		if (tid in pendingPermissionPrompts_)
			return resolve(makePermissionDenyJson(
				"Another permission prompt is already pending"));

		auto promise = new Promise!string;
		pendingPermissionPrompts_[tid] = promise;
		pendingPermissionInputs_[tid] = prompt.input.json;

		auto td = requireTask(tid,
			"Permission prompt target must be a live task");
		td.pendingPermission = prompt;

		host_.sendPermissionPrompt(tid, prompt);
		if (timeout > Duration.zero)
			permissionPromptTimeouts_[tid] = setTimeout({
				permissionPromptTimeouts_.remove(tid);
				settlePermissionPrompt(tid, makePermissionDenyJson(format!(
					"Permission denied: nobody answered the permission prompt within %s")(timeout)));
			}, timeout);

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
		if (!batchRegistry_.findFirstLiveChild(tid, (int cTid) {
			auto child = host_.getTask(cTid);
			return child !is null && child.pendingAskPromise !is null;
		}, childTid))
			return false;

		auto child = requireTask(childTid,
			"Pending child question must belong to a live child task");
		question = child.pendingAskQuestion;
		qid = child.pendingAskQid;
		return true;
	}

	void executeContinuation(int tid, ContinuationDef contDef,
		string handoffPrompt, string edgeName, string excludedUserUuid = null)
	{
		auto td = requireTask(tid,
			"Continuation execution requires a live task");
		auto newTypeDef = host_.taskTypesForProject(td.projectPath)
			.byName(contDef.task_type);
		if (newTypeDef is null)
		{
			errorf("executeContinuation: unknown successor type '%s' for tid=%d",
				contDef.task_type, tid);
			host_.transitionTaskFrom(tid,
				[TaskStatus.pending, TaskStatus.active, TaskStatus.alive,
					TaskStatus.waiting, TaskStatus.completed], TaskStatus.failed,
				TaskNotificationChange.preserve);
			return;
		}

		infof("Continuation: tid=%d %s → %s (keep_context=%s)",
			tid, td.taskType, contDef.task_type, contDef.keep_context);

		auto resultText = td.resultText;

		if (contDef.keep_context)
		{
			auto sourceTaskType = td.taskType;
			auto wasActive = td.status == TaskStatus.active;
			td.taskType = contDef.task_type;
			host_.persistTaskType(tid, contDef.task_type);

			if (!wasActive)
				host_.transitionTaskFrom(tid,
					[TaskStatus.pending, TaskStatus.alive, TaskStatus.waiting,
						TaskStatus.completed, TaskStatus.failed], TaskStatus.active,
					TaskNotificationChange.preserve);
			host_.emitTaskReload(tid, "continuation", excludedUserUuid);

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
				return host_.sendTaskMessage(tid,
					[ContentBlock("text", wrapKnownSystemMessage(
						host_.systemKeyword(),
						KnownSystemMessageKind.modeSwitch,
						renderedContinuationPrompt,
						modeSwitchMsgSubject))],
					null, contMeta, null);
			}).then(() {
				sendPendingChildAnswerReminder(tid);
			}, (Exception e) {
				auto failed = requireTask(tid,
					"Continuation task must exist when message submission fails");
				if (failed.status != TaskStatus.failed)
				{
					assert(failed.status == TaskStatus.active,
						"Continuation submission failed outside an active task");
					failed.error = e.msg;
					failed.resultText = e.msg;
					host_.persistResultText(tid, failed.resultText);
					host_.transitionTask(tid, TaskStatus.active, TaskStatus.failed,
						TaskNotificationChange.preserve);
					host_.appendTaskDiagnostic(tid, "Continuation failed", e.msg);
				}
				if (hasPendingSubTask(tid))
					deliverFailedPendingSubTaskResult(tid);
				questionRouter_.failQuestionRoutesForAnswerer(tid,
					"Continuation message submission failed: " ~ e.msg);
				if (failed.pendingAskPromise !is null && failed.pendingAskQid > 0)
					questionRouter_.failQuestionRoute(failed.pendingAskQid,
						"Continuation message submission failed: " ~ e.msg);
			}).ignoreResult();
			if (wasActive)
				host_.broadcastTaskUpdate(tid);
		}
		else
		{
			auto contAgent = host_.resolveTaskAgent(newTypeDef.agent,
				td.agentName, td.workspace);
			if (contAgent.length == 0
				|| !host_.isConfiguredAgentName(contAgent))
			{
				td.error = format(
					"Successor type '%s' resolved agent to '%s' (parent='%s') — not a configured agent",
					contDef.task_type, contAgent, td.agentName);
				host_.transitionTaskFrom(tid,
					[TaskStatus.pending, TaskStatus.active, TaskStatus.alive,
						TaskStatus.waiting, TaskStatus.completed], TaskStatus.failed,
					TaskNotificationChange.preserve);
				host_.appendTaskDiagnostic(tid,
					"Continuation failed", td.error);
				return;
			}

			host_.transitionTaskFrom(tid,
				[TaskStatus.pending, TaskStatus.active, TaskStatus.alive,
					TaskStatus.waiting, TaskStatus.failed], TaskStatus.completed,
				TaskNotificationChange.preserve);
			host_.emitTaskReload(tid, "continuation", excludedUserUuid);

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
				return host_.sendTaskMessage(childTid,
					[ContentBlock("text", wrapKnownSystemMessage(
						host_.systemKeyword(),
						KnownSystemMessageKind.handoff,
						renderedSuccessorPrompt,
						handoffMsgSubject))],
					null, handoffMeta, null);
			}).except((Exception e) {
				auto failed = requireTask(childTid,
					"Handoff successor must exist when message submission fails");
				if (failed.status != TaskStatus.failed)
				{
					assert(failed.status == TaskStatus.active,
						"Handoff successor submission failed outside an active task");
					failed.error = e.msg;
					failed.resultText = e.msg;
					host_.persistResultText(childTid, failed.resultText);
					host_.transitionTask(childTid, TaskStatus.active, TaskStatus.failed,
						TaskNotificationChange.preserve);
					host_.appendTaskDiagnostic(childTid, "Handoff failed", e.msg);
				}
				if (hasPendingSubTask(childTid))
					deliverFailedPendingSubTaskResult(childTid);
			}).ignoreResult();
		}
	}
}

unittest
{
	import ae.net.asockets : onNextTick, socketManager;
	import ae.utils.promise : reject;
	import ae.utils.promise.await : async;
	import cydo.domain.task_types.definition : CreatableTaskDef;
	import cydo.protocol : BatchResultEnvelope;
	import cydo.mcp.tools : CydoToolsImpl, TaskSpec;
	import cydo.runtime.config : SandboxConfig;
	import std.conv : to;
	import std.algorithm.searching : canFind;
	import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
	import std.path : buildPath;
	import std.process : execute;
	import std.string : strip;

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

	TaskTypeDef parentType;
	parentType.name = "parent";
	parentType.agent = "fake";
	CreatableTaskDef edge;
	edge.name = "child";
	edge.worktree = WorktreeMode.fork;
	parentType.creatable_tasks = [edge];

	TaskTypeDef childType;
	childType.name = "child";
	childType.agent = "fake";
	ContinuationDef continuation;
	continuation.task_type = "child";
	parentType.continuations["continue"] = continuation;
	auto taskTypes = [parentType, childType];

	auto taskRoot = buildPath(tempDir(), "cydo-task-start-head-capture");
	if (exists(taskRoot))
		rmdirRecurse(taskRoot);
	mkdirRecurse(taskRoot);
	scope(exit) rmdirRecurse(taskRoot);

	TaskData[int] tasks;
	tasks[1] = TaskData(1, "local", taskRoot);
	tasks[1].taskType = "parent";
	tasks[1].agentName = "fake";
	int nextTid = 2;
	string persistedTaskStartHead;
	int launchCalls;
	bool producesCommitOutput = true;
	bool assignWorktree = true;
	bool initializeWorktree;
	string expectedTaskStartHead;

	auto backend = new WorkflowToolsBackend(WorkflowToolsHost(
		getTask: (int tid) {
			auto td = tid in tasks;
			return td is null ? null : td;
		},
		createTask: (string workspace, string projectPath, string agentName) {
			auto tid = nextTid++;
			tasks[tid] = TaskData(tid, workspace, projectPath);
			tasks[tid].agentName = agentName;
			return tid;
		},
		persistTaskType: (int tid, string taskType) {},
		persistDescription: (int tid, string description) {},
		persistParentTid: (int tid, int parentTid) {},
		persistRelationType: (int tid, string relationType) {},
		persistTitle: (int tid, string title) {},
		transitionTask: (int tid, TaskStatus expectedFrom, TaskStatus to,
			TaskNotificationChange notification) {
			assert(tasks[tid].status == expectedFrom);
			tasks[tid].status = to;
		},
		transitionTaskFrom: (int tid, TaskStatus[] expectedFrom, TaskStatus to,
			TaskNotificationChange notification) {
			bool expected;
			foreach (from; expectedFrom)
				expected = expected || tasks[tid].status == from;
			assert(expected);
			tasks[tid].status = to;
		},
		persistNeedsAttention: (int tid, bool needsAttention) {},
		persistLastActive: (int tid, long lastActive) {},
		persistResultText: (int tid, string resultText) {},
		persistTaskStartHead: (int tid, string taskStartHead) {
			persistedTaskStartHead = taskStartHead;
		},
		touchTask: (int tid) {},
		taskTypesForProject: (string projectPath) => taskTypes,
		entryPointsForProject: (string projectPath) => cast(UserEntryPointDef[]) null,
		promptSearchPath: (string projectPath) => cast(string[]) null,
		treeReadOnlyForProject: (string projectPath) => cast(bool[string]) null,
		resolveTaskAgent: (DjinjaTemplate requestedAgent, string parentAgent, string workspace) => "fake",
		isConfiguredAgentName: (string agentName) => agentName == "fake",
		agentForTask: (int tid) {
			assert(0, "agentForTask should not be needed for this test");
			return cast(Agent) null;
		},
		taskSystemPromptForMessage: (int tid, TaskTypeDef* typeDef) => "",
		readPromptFile: (string relativePath, string projectPath,
			string[string] vars) => "",
		buildKnownSystemMessageMeta: (KnownSystemMessageKind kind,
			string subject, string[string] vars, string bodyVar) => "{}",
		systemKeyword: () => "SYSTEM",
		taskDir: (const TaskData* td) => buildPath(taskRoot,
			"tasks", td.tid.to!string),
		outputPath: (const TaskData* td) => buildPath(taskRoot,
			"tasks", td.tid.to!string, "output.md"),
		worktreePath: (const TaskData* td) => buildPath(taskRoot,
			"tasks", td.tid.to!string, "worktree"),
		taskProducesCommitOutput: (string projectPath, string taskTypeName) => producesCommitOutput,
		setupWorktreeForEdge: (int childTid, int parentTid, WorktreeMode mode) {
			auto worktree = buildPath(taskRoot, "tasks", childTid.to!string, "worktree");
			mkdirRecurse(worktree);
			if (assignWorktree)
				tasks[childTid].worktreeTid = childTid;
			if (initializeWorktree)
			{
				execute(["git", "-C", worktree, "init", "-q"]);
				execute(["git", "-C", worktree, "config", "user.email", "test@test"]);
				execute(["git", "-C", worktree, "config", "user.name", "Test"]);
				execute(["git", "-C", worktree, "commit", "--allow-empty", "-qm", "base"]);
				expectedTaskStartHead = execute(["git", "-C", worktree, "rev-parse", "HEAD"]).output.strip;
			}
		},
		ensureProcessQueueAlive: (int tid) {
			launchCalls++;
			if (tid == 4)
			{
				assert(tasks[tid].taskStartHead == expectedTaskStartHead);
				assert(persistedTaskStartHead == expectedTaskStartHead);
			}
			return reject!void(new Exception("process launch should not run"));
		},
		sendTaskMessage: (int tid, const(ContentBlock)[] content,
			const(ContentBlock)[] broadcastContent, string cydoMeta, string nonce) {
			assert(tid == 3,
				"startup failure should prevent sending the subtask prompt");
			return resolve();
		},
		emitTaskReload: (int tid, string reason, string excludedUserUuid) {},
		appendTaskDiagnostic: (int tid, string subject, string body) {},
		taskAlive: (int tid) => false,
		tasksShareWorkspace: (int aTid, int bTid) => true,
		taskWorkspaceLabel: (int tid) => "local",
		addIdleCallback: (int tid, void delegate() cb) {},
		reactivateTask: (int tid) => resolve(),
		sendKnownSystemMessage: (int tid, KnownSystemMessageKind kind,
			string body) { return resolve(); },
		persistAddTaskDep: (int parentTid, int childTid) {},
		persistRemoveTaskDep: (int parentTid, int childTid) {},
		persistRemoveAllChildDeps: (int childTid) {},
		loadTaskDeps: () => cast(int[][int]) null,
		broadcastTaskUpdate: (int tid) {},
		broadcastFocusHint: (int fromTid, int toTid) {},
		sendAskUserQuestionPrompt: (int tid, JSONFragment questions,
			string toolUseId) {},
		clearAskUserQuestionPrompt: (int tid) {},
		sendPermissionPrompt: (int tid, PermissionPrompt prompt) {},
		clearPermissionPrompt: (int tid) {},
		appendTaskSpawnedEvent: (int parentTid, int childTid, int specIndex) {},
		broadcastTaskCreated: (TaskCreatedMessage message) {},
		permissionSettings: (string agentName, string workspaceName) => PermissionSettings.init,
		onNextTick: (void delegate() cb) { onNextTick(socketManager, cb); },
		generateTitle: (int tid, string prompt) {},
	));

	auto tools = new CydoToolsImpl(backend, "1");
	bool resolved;
	McpResult result;
	async({
		return tools.createTasks([
			TaskSpec("child startup", "child", "trigger child startup failure"),
		]);
	}).then((McpResult r) {
		resolved = true;
		result = r;
	});

	drainPromiseNextTicks();

	assert(resolved,
		"Task MCP call stayed pending after child session startup failure");
	assert(result.isError);
	auto batch = jsonParse!BatchResultEnvelope(result.text);
	assert(batch.tasks.length == 1);
	auto taskResult = jsonParse!TaskResult(batch.tasks[0].json);
	assert(taskResult.status == "error");
	assert(taskResult.summary.canFind("Failed to capture task start HEAD"));
	assert(taskResult.error.canFind("Failed to capture task start HEAD"));
	assert(tasks[2].status == "failed");
	assert(tasks[2].error.canFind("status"));
	assert(launchCalls == 0);
	assert(persistedTaskStartHead.length == 0);

	producesCommitOutput = false;
	assignWorktree = false;
	resolved = false;
	async({
		return tools.createTasks([
			TaskSpec("no worktree", "child", "launch without worktree"),
		]);
	}).then((McpResult r) {
		resolved = true;
		result = r;
	});
	drainPromiseNextTicks();
	assert(resolved);
	assert(launchCalls == 1);
	assert(tasks[3].taskStartHead.length == 0);
	assert(persistedTaskStartHead.length == 0);

	producesCommitOutput = true;
	assignWorktree = true;
	initializeWorktree = true;
	resolved = false;
	async({
		return tools.createTasks([
			TaskSpec("successful capture", "child", "launch with worktree"),
		]);
	}).then((McpResult r) {
		resolved = true;
		result = r;
	});
	drainPromiseNextTicks();
	assert(resolved);
	assert(tasks[4].taskStartHead == expectedTaskStartHead);
}

unittest
{
	TaskData[int] tasks;
	tasks[1] = TaskData(1, "local", "/tmp/project");
	tasks[1].taskType = "parent";
	tasks[1].agentName = "work-claude";

	TaskTypeDef parent;
	parent.name = "parent";
	parent.model_class = "large";
	parent.creatable_tasks = [CreatableTaskDef("child", "child",
		WorktreeMode.inherit, "", "", "")];

	TaskTypeDef child;
	child.name = "child";
	child.model_class = "large";
	child.agent = "{{ parent_agent_type }}";

	WorkflowToolsHost host;
	host.getTask = (int tid) {
		auto task = tid in tasks;
		return task is null ? null : &tasks[tid];
	};
	host.taskTypesForProject = (string projectPath) => [parent, child];
	host.resolveTaskAgent = (DjinjaTemplate requestedAgent, string parentAgent, string workspace) {
		return resolveAgent(requestedAgent, parentAgent, workspace);
	};
	host.isConfiguredAgentName = (string agentName) => agentName == "work-claude";

	auto backend = new WorkflowToolsBackend(host);
	auto validated = backend.handleCreateTask("1", 0, "Child task", "child",
		"Implement it");
	assert(validated.launch !is null);
	assert(!validated.error.isError);
}

unittest
{
	import ae.net.asockets : onNextTick, socketManager;
	import ae.utils.promise : reject;
	import ae.utils.promise.await : async;
	import core.exception : AssertError;
	import cydo.workflow.batch.registry : ActiveBatchKey;
	import std.algorithm.searching : canFind;
	import std.exception : assertThrown;

	void drainPromiseNextTicks()
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

	final class BatchInvariantFixture
	{
		TaskData[int] tasks;
		TaskTypeDef[] taskTypes;
		int persistAddDependencyCalls;
		int persistRemoveDependencyCalls;
		int[] removedChildren;
		int waitingToActiveTransitions;
		int nextTid = 3;
		size_t sendCalls;
		string sendFailure;
		string[] diagnosticSubjects;
		string[] diagnosticBodies;
		int reloadTid = -1;
		string reloadReason;
		string reloadExcludedUserUuid;
		Promise!void reactivationGate;

		this()
		{
			TaskTypeDef parentType;
			parentType.name = "parent";
			parentType.agent = "fake";
			CreatableTaskDef childEdge;
			childEdge.name = "child";
			parentType.creatable_tasks = [childEdge];
			ContinuationDef handoff;
			handoff.task_type = "child";
			parentType.continuations["continue"] = handoff;
			ContinuationDef keepContext;
			keepContext.task_type = "child";
			keepContext.keep_context = true;
			parentType.continuations["keep"] = keepContext;
			TaskTypeDef childType;
			childType.name = "child";
			childType.agent = "fake";
			taskTypes = [parentType, childType];

			tasks[1] = TaskData(1, "local", "/tmp/cydo-batch-invariants");
			tasks[1].taskType = "parent";
			tasks[1].agentName = "fake";
			tasks[1].status = TaskStatus.active;
			tasks[2] = TaskData(2, "local", "/tmp/cydo-batch-invariants");
			tasks[2].taskType = "child";
			tasks[2].agentName = "fake";
			tasks[2].parentTid = 1;
			tasks[2].status = TaskStatus.active;

			reactivationGate = new Promise!void;
		}

		WorkflowToolsBackend makeBackend()
		{
			return new WorkflowToolsBackend(WorkflowToolsHost(
				getTask: (int tid) {
					auto task = tid in tasks;
					return task is null ? null : task;
				},
				createTask: (string workspace, string projectPath, string agentName) {
					auto tid = nextTid++;
					tasks[tid] = TaskData(tid, workspace, projectPath);
					tasks[tid].agentName = agentName;
					return tid;
				},
				persistTaskType: (int tid, string taskType) {},
				persistDescription: (int tid, string description) {},
				persistParentTid: (int tid, int parentTid) {},
				persistRelationType: (int tid, string relationType) {},
				persistTitle: (int tid, string title) {},
				persistNeedsAttention: (int tid, bool needsAttention) {},
				persistLastActive: (int tid, long lastActive) {},
				taskTypesForProject: (string projectPath) => taskTypes,
				entryPointsForProject: (string projectPath) => cast(UserEntryPointDef[]) null,
				promptSearchPath: (string projectPath) => cast(string[]) null,
				treeReadOnlyForProject: (string projectPath) => cast(bool[string]) null,
				resolveTaskAgent: (DjinjaTemplate requestedAgent, string parentAgent, string workspace) => "fake",
				isConfiguredAgentName: (string agentName) => agentName == "fake",
				taskSystemPromptForMessage: (int tid, TaskTypeDef* typeDef) => "",
				tasksShareWorkspace: (int aTid, int bTid) => true,
				taskWorkspaceLabel: (int tid) => "local",
				systemKeyword: () => "SYSTEM",
				readPromptFile: (string relativePath, string projectPath,
					string[string] vars) => "",
				buildKnownSystemMessageMeta: (KnownSystemMessageKind kind,
					string subject, string[string] vars,
					string bodyVar) => "{}",
				taskDir: (const TaskData* task) => "",
				outputPath: (const TaskData* task) => "",
				worktreePath: (const TaskData* task) => "",
				taskProducesCommitOutput: (string projectPath, string taskType) => false,
				setupWorktreeForEdge: (int childTid, int parentTid,
					WorktreeMode mode) {},
				ensureProcessQueueAlive: (int tid) {
					if (tasks[tid].status == TaskStatus.pending)
						tasks[tid].status = TaskStatus.active;
					return resolve();
				},
				sendTaskMessage: (int tid, const(ContentBlock)[] content,
					const(ContentBlock)[] broadcastContent,
					string cydoMeta, string nonce) {
					sendCalls++;
					if (sendFailure.length > 0)
						return reject!void(new Exception(sendFailure));
					return resolve();
				},
				emitTaskReload: (int tid, string reason, string excludedUserUuid) {
					reloadTid = tid;
					reloadReason = reason;
					reloadExcludedUserUuid = excludedUserUuid;
				},
				appendTaskDiagnostic: (int tid, string subject, string body) {
					diagnosticSubjects ~= subject;
					diagnosticBodies ~= body;
				},
				appendAndBroadcastRecoveryDeliveryDiagnostic:
					(int tid, string subject, string body) {},
				transitionTask: (int tid, TaskStatus expectedFrom,
					TaskStatus to,
					TaskNotificationChange notification) {
					assert(tasks[tid].status == expectedFrom);
					if (expectedFrom == TaskStatus.waiting
						&& to == TaskStatus.active)
						waitingToActiveTransitions++;
					tasks[tid].status = to;
				},
				transitionTaskFrom: (int tid, TaskStatus[] expectedFrom,
					TaskStatus to,
					TaskNotificationChange notification) {
					bool allowed;
					foreach (from; expectedFrom)
						allowed = allowed || tasks[tid].status == from;
					assert(allowed);
					tasks[tid].status = to;
				},
				persistResultText: (int tid, string resultText) {},
				persistTaskStartHead: (int tid, string taskStartHead) {},
				touchTask: (int tid) {},
				taskAlive: (int tid) => (tid in tasks) !is null,
				broadcastFocusHint: (int fromTid, int toTid) {},
				addIdleCallback: (int tid, void delegate() cb) {},
				reactivateTask: (int tid) {
					assert(tid == 2);
					return reactivationGate;
				},
				persistAddTaskDep: (int parentTid, int childTid) {
					persistAddDependencyCalls++;
				},
				persistRemoveTaskDep: (int parentTid, int childTid) {
					persistRemoveDependencyCalls++;
					removedChildren ~= childTid;
				},
				persistRemoveAllChildDeps: (int childTid) {},
				loadTaskDeps: () => cast(int[][int]) null,
				broadcastTaskUpdate: (int tid) {},
				broadcastTaskCreated: (TaskCreatedMessage message) {},
				sendKnownSystemMessage: (int tid, KnownSystemMessageKind kind,
					string body) { return resolve(); },
				sendAskUserQuestionPrompt: (int tid, JSONFragment questions,
					string toolUseId) {},
				clearAskUserQuestionPrompt: (int tid) {},
				sendPermissionPrompt: (int tid, PermissionPrompt prompt) {},
				clearPermissionPrompt: (int tid) {},
				appendTaskSpawnedEvent: (int parentTid, int childTid,
					int specIndex) {},
				permissionSettings: (string agentName, string workspaceName) => PermissionSettings.init,
				onNextTick: (void delegate() cb) { onNextTick(socketManager, cb); },
				generateTitle: (int tid, string prompt) {},
			));
		}
	}

	BatchRegistry* batchRegistryOf(WorkflowToolsBackend backend)
	{
		return &__traits(getMember, backend, "batchRegistry_");
	}

	BatchHandle liveHandle(BatchRegistry* registry, int childTid)
	{
		BatchHandle handle;
		size_t slot;
		assert(registry.findOwnerOfChild(childTid, handle, slot));
		assert(slot == 0);
		return handle;
	}

	void corruptOrderedChild(BatchRegistry* registry, BatchHandle handle)
	{
		auto key = ActiveBatchKey(handle.parentTid, handle.batchId);
		__traits(getMember, *registry,
			"activeBatches")[key].childTids[0] = 99;
	}

	void removeReverseOwner(BatchRegistry* registry, int childTid)
	{
		__traits(getMember, *registry,
			"batchKeyByChildTid").remove(childTid);
	}

	void assertChildAskPreflightUntouched(BatchInvariantFixture fixture,
		WorkflowToolsBackend backend, BatchRegistry* registry,
		BatchHandle handle)
	{
		auto router = __traits(getMember, backend, "questionRouter_");
		assert(__traits(getMember, router, "questionRoutes_").length == 0);
		assert(__traits(getMember, router, "pendingQuestions_").length == 0);
		assert(fixture.tasks[1].status == TaskStatus.active);
		assert(fixture.tasks[1].pendingContinuation is null);
		assert(fixture.tasks[2].status == TaskStatus.active);
		assert(fixture.tasks[2].pendingAskPromise is null);
		assert(fixture.tasks[2].pendingAskQuestion.length == 0);
		assert(fixture.tasks[2].pendingAskQid == 0);
		assert(!backend.hasTaskDependency(2));
		assert(fixture.persistAddDependencyCalls == 0);
		assert(fixture.persistRemoveDependencyCalls == 0);
		assert(registry.exists(handle));
	}

	// The on-exit repair must persist exactly the result transport intended to
	// deliver before it interrupted the continuation tool call.
	{
		auto fixture = new BatchInvariantFixture;
		auto backend = fixture.makeBackend();
		auto switchResult = backend.handleSwitchMode("1", "keep");
		assert(!switchResult.isError);
		assert(fixture.tasks[1].pendingContinuation !is null);
		assert(fixture.tasks[1].pendingContinuation.resultText == switchResult.text);

		fixture = new BatchInvariantFixture;
		backend = fixture.makeBackend();
		auto handoffResult = backend.handleHandoff("1", "continue", "prompt");
		assert(!handoffResult.isError);
		assert(fixture.tasks[1].pendingContinuation !is null);
		assert(fixture.tasks[1].pendingContinuation.resultText == handoffResult.text);

		fixture = new BatchInvariantFixture;
		backend = fixture.makeBackend();
		auto pending = new PendingContinuation(
			PendingContinuation.Kind.switchMode, "keep");
		pending.repairedInterruptionUuid = "u2";
		fixture.tasks[1].pendingContinuation = pending;
		backend.spawnContinuation(1);
		assert(fixture.reloadTid == 1
			&& fixture.reloadReason == "continuation"
			&& fixture.reloadExcludedUserUuid == "u2");
	}

	// Initial child prompt failure is observed through the real send Promise,
	// then settles the direct Task result exactly once for its parent.
	{
		auto fixture = new BatchInvariantFixture;
		fixture.sendFailure = "initial child prompt rejected";
		auto backend = fixture.makeBackend();
		auto validated = backend.handleCreateTask("1", 0, "child title",
			"child", "child prompt");
		assert(validated.launch !is null && !validated.error.isError);
		auto launched = validated.launch();
		bool settled;
		McpResult result;
		launched.promise.then((McpResult value) {
			settled = true;
			result = value;
		}).ignoreResult();
		drainPromiseNextTicks();

		assert(fixture.sendCalls == 1 && settled && result.isError);
		assert(fixture.tasks[launched.childTid].status == TaskStatus.failed);
		assert(fixture.tasks[launched.childTid].resultText
			== "initial child prompt rejected");
		assert(!backend.hasPendingSubTask(launched.childTid));
	}

	// An answer reminder must settle its existing Ask route when its actual
	// submission Promise rejects; it cannot leave the child waiting forever.
	{
		auto fixture = new BatchInvariantFixture;
		fixture.sendFailure = "answer reminder rejected";
		auto backend = fixture.makeBackend();
		auto registry = batchRegistryOf(backend);
		BatchHandle handle;
		string error;
		assert(registry.create(1, [2], handle, error), error);
		bool settled;
		McpResult result;
		backend.handleAsk("2", "need an answer", -1).then((McpResult value) {
			settled = true;
			result = value;
		}).ignoreResult();
		assert(fixture.tasks[2].pendingAskQid > 0);
		Promise!BatchSignal questionEvent;
		assert(registry.waitOne(handle, questionEvent, error), error);
		questionEvent.then((BatchSignal signal) {}).ignoreResult();
		drainPromiseNextTicks();
		backend.sendPendingChildAnswerReminder(1);
		drainPromiseNextTicks();

		assert(fixture.sendCalls == 1 && settled && result.isError);
		assert(result.text.canFind("Failed to submit sub-task answer reminder"));
		assert(fixture.tasks[2].pendingAskPromise is null
			&& fixture.tasks[2].pendingAskQid == 0);
		auto router = __traits(getMember, backend, "questionRouter_");
		assert(__traits(getMember, router, "questionRoutes_").length == 0
			&& __traits(getMember, router, "pendingQuestions_").length == 0);
	}

	// A keep-context continuation owns only its own failed task and diagnostic
	// when the actual mode-switch send is rejected.
	{
		auto fixture = new BatchInvariantFixture;
		fixture.sendFailure = "keep-context submission rejected";
		auto backend = fixture.makeBackend();
		fixture.tasks[1].pendingContinuation = new PendingContinuation(
			PendingContinuation.Kind.switchMode, "keep");
		backend.spawnContinuation(1);
		drainPromiseNextTicks();

		assert(fixture.sendCalls == 1);
		assert(fixture.tasks[1].status == TaskStatus.failed
			&& fixture.tasks[1].resultText == "keep-context submission rejected");
		assert(fixture.diagnosticSubjects == ["Continuation failed"]
			&& fixture.diagnosticBodies == ["keep-context submission rejected"]);
	}

	// Handoff moves its pending Task topology before submission. A rejected
	// successor send fails and settles that moved owner without rolling it back.
	{
		auto fixture = new BatchInvariantFixture;
		fixture.sendFailure = "handoff submission rejected";
		auto backend = fixture.makeBackend();
		auto pending = new Promise!McpResult;
		bool settled;
		McpResult result;
		pending.then((McpResult value) {
			settled = true;
			result = value;
		}).ignoreResult();
		__traits(getMember, backend, "pendingSubTasks_")[1] = pending;
		__traits(getMember, backend, "taskDeps_")[1] = 0;
		auto accepted = backend.handleHandoff("1", "continue", "handoff prompt");
		assert(!accepted.isError);
		backend.spawnContinuation(1);
		drainPromiseNextTicks();

		assert(fixture.sendCalls == 1 && settled && result.isError);
		assert(fixture.tasks[1].status == TaskStatus.completed);
		assert(fixture.tasks[3].status == TaskStatus.failed
			&& fixture.tasks[3].resultText == "handoff submission rejected");
		assert(!backend.hasPendingSubTask(1)
			&& !backend.hasPendingSubTask(3));
		assert(!backend.hasTaskDependency(1) && backend.hasTaskDependency(3));
		assert(fixture.diagnosticSubjects == ["Handoff failed"]
			&& fixture.diagnosticBodies == ["handoff submission rejected"]);
	}

	// A missing unfinished batchKeyByChildTid entry aborts the ordinary Task
	// callback before enqueue/consume can change its result state.
	{
		auto fixture = new BatchInvariantFixture;
		auto backend = fixture.makeBackend();
		auto childResult = new Promise!McpResult;
		auto batchResult = async({
			return backend.registerBatchAndAwait("1",
				[LaunchedTask(2, childResult)]).await;
		});
		batchResult.ignoreResult();

		auto registry = batchRegistryOf(backend);
		auto handle = liveHandle(registry, 2);
		auto key = ActiveBatchKey(handle.parentTid, handle.batchId);
		removeReverseOwner(registry, 2);

		childResult.fulfill(McpResult("done", false));
		assertThrown!AssertError(drainPromiseNextTicks());
		auto batch = key in __traits(getMember, *registry, "activeBatches");
		assert(batch !is null);
		assert((*batch).results[0].text.length == 0);
		assert(!(*batch).done[0]);
		assert((*batch).completed == 0);
		assert(__traits(getMember, *registry, "activeBatches").length == 1);
		auto ids = 1 in __traits(getMember, *registry,
			"batchIdsByParentTid");
		assert(ids !is null && ids.length == 1 && (*ids)[0] == handle.batchId);
		assert((2 in __traits(getMember, *registry,
			"batchKeyByChildTid")) is null);
	}

	// A local ordered-child/captured-slot mismatch still aborts the real
	// follow-up pending-subtask completion callback.
	{
		auto fixture = new BatchInvariantFixture;
		fixture.tasks[2].status = TaskStatus.completed;
		auto backend = fixture.makeBackend();
		backend.handleAsk("1", "follow up", 2).ignoreResult();
		assert(fixture.persistAddDependencyCalls == 1);

		auto registry = batchRegistryOf(backend);
		auto handle = liveHandle(registry, 2);
		corruptOrderedChild(registry, handle);

		auto pending = 2 in __traits(getMember, backend,
			"pendingSubTasks_");
		assert(pending !is null);
		(*pending).fulfill(McpResult("follow-up result", false));
		assertThrown!AssertError(drainPromiseNextTicks());
	}

	// Child Ask treats a missing unfinished batchKeyByChildTid entry as an
	// assertion before it creates a route or changes task state.
	{
		auto fixture = new BatchInvariantFixture;
		auto backend = fixture.makeBackend();
		auto registry = batchRegistryOf(backend);
		BatchHandle handle;
		string error;
		assert(registry.create(1, [2], handle, error), error);
		removeReverseOwner(registry, 2);

		assertThrown!AssertError(backend.handleAsk("2", "need an answer", -1));
		assertChildAskPreflightUntouched(fixture, backend, registry, handle);
	}

	// A dangling batchKeyByChildTid target also asserts before child-to-parent
	// Ask can return an internal MCP result or start a route.
	{
		auto fixture = new BatchInvariantFixture;
		auto backend = fixture.makeBackend();
		auto registry = batchRegistryOf(backend);
		BatchHandle handle;
		string error;
		assert(registry.create(1, [2], handle, error), error);
		__traits(getMember, *registry, "batchKeyByChildTid")[2] =
			ActiveBatchKey(999, 999);

		assertThrown!AssertError(backend.handleAsk("2", "need an answer", -1));
		assertChildAskPreflightUntouched(fixture, backend, registry, handle);
	}

	// A live batch that does not contain the child is not a foreign Ask owner;
	// it is a globally corrupt batchKeyByChildTid entry.
	{
		auto fixture = new BatchInvariantFixture;
		auto backend = fixture.makeBackend();
		auto registry = batchRegistryOf(backend);
		BatchHandle handle;
		BatchHandle wrong;
		string error;
		assert(registry.create(1, [2], handle, error), error);
		assert(registry.create(1, [3], wrong, error), error);
		__traits(getMember, *registry, "batchKeyByChildTid")[2] =
			ActiveBatchKey(wrong.parentTid, wrong.batchId);

		assertThrown!AssertError(backend.handleAsk("2", "need an answer", -1));
		assertChildAskPreflightUntouched(fixture, backend, registry, handle);
		assert(registry.exists(wrong));
	}

	// A reverse owner cannot point at a completed historical slot. It must
	// assert before child-to-parent Ask starts its route.
	{
		auto fixture = new BatchInvariantFixture;
		auto backend = fixture.makeBackend();
		auto registry = batchRegistryOf(backend);
		BatchHandle completed;
		string error;
		assert(registry.create(1, [2], completed, error), error);
		auto consumed = registry.consume(completed,
			BatchSignal.childDone(completed.batchId, 0, 2,
				McpResult("completed", false)),
			(int childTid, int qid) => false, error);
		assert(consumed.kind == BatchConsumeKind.childDone);
		assert(error.length == 0);
		auto completedBatch = ActiveBatchKey(completed.parentTid,
			completed.batchId) in __traits(getMember, *registry,
				"activeBatches");
		assert(completedBatch !is null && (*completedBatch).done[0]);
		__traits(getMember, *registry, "batchKeyByChildTid")[2] =
			ActiveBatchKey(completed.parentTid, completed.batchId);

		assertThrown!AssertError(backend.handleAsk("2", "need an answer", -1));
		assertChildAskPreflightUntouched(fixture, backend, registry, completed);
	}

	// A missing parent index asserts before post-response cleanup.
	{
		auto fixture = new BatchInvariantFixture;
		fixture.tasks[1].status = TaskStatus.waiting;
		auto backend = fixture.makeBackend();
		__traits(getMember, backend, "taskDeps_")[2] = 1;
		auto registry = batchRegistryOf(backend);
		BatchHandle handle;
		string error;
		assert(registry.create(1, [2], handle, error), error);
		__traits(getMember, *registry, "batchIdsByParentTid").remove(1);

		assertThrown!AssertError(backend.onToolCallDelivered("1"));
		assert(fixture.persistRemoveDependencyCalls == 0);
		assert(backend.hasTaskDependency(2));
		assert(fixture.tasks[1].status == TaskStatus.waiting);
		assert(fixture.waitingToActiveTransitions == 0);
		assert(registry.exists(handle));
	}

	// A missing batchKeyByChildTid entry asserts in parentHasLiveBatches before
	// post-response cleanup can remove a dependency or reactivate the parent.
	{
		auto fixture = new BatchInvariantFixture;
		fixture.tasks[1].status = TaskStatus.waiting;
		auto backend = fixture.makeBackend();
		__traits(getMember, backend, "taskDeps_")[2] = 1;
		auto registry = batchRegistryOf(backend);
		BatchHandle handle;
		string error;
		assert(registry.create(1, [2], handle, error), error);
		removeReverseOwner(registry, 2);

		assertThrown!AssertError(backend.onToolCallDelivered("1"));
		assert(fixture.persistRemoveDependencyCalls == 0);
		assert(backend.hasTaskDependency(2));
		assert(fixture.tasks[1].status == TaskStatus.waiting);
		assert(fixture.waitingToActiveTransitions == 0);
		assert(registry.exists(handle));
	}

	// A partial parent index asserts before post-response cleanup.
	{
		auto fixture = new BatchInvariantFixture;
		fixture.tasks[1].status = TaskStatus.waiting;
		auto backend = fixture.makeBackend();
		__traits(getMember, backend, "taskDeps_")[2] = 1;
		__traits(getMember, backend, "taskDeps_")[3] = 1;
		auto registry = batchRegistryOf(backend);
		BatchHandle visible;
		BatchHandle omitted;
		string error;
		assert(registry.create(1, [2], visible, error), error);
		assert(registry.create(1, [3], omitted, error), error);
		__traits(getMember, *registry, "batchIdsByParentTid")[1] =
			[visible.batchId];

		assertThrown!AssertError(backend.onToolCallDelivered("1"));
		assert(fixture.persistRemoveDependencyCalls == 0);
		assert(backend.hasTaskDependency(2));
		assert(backend.hasTaskDependency(3));
		assert(fixture.tasks[1].status == TaskStatus.waiting);
		assert(fixture.waitingToActiveTransitions == 0);
		assert(registry.exists(visible));
		assert(registry.exists(omitted));
	}

	// Normal delivery removes every dependency once and reactivates the parent.
	{
		auto fixture = new BatchInvariantFixture;
		fixture.tasks[1].status = TaskStatus.waiting;
		auto backend = fixture.makeBackend();
		__traits(getMember, backend, "taskDeps_")[2] = 1;
		__traits(getMember, backend, "taskDeps_")[3] = 1;

		backend.onToolCallDelivered("1");
		assert(fixture.persistRemoveDependencyCalls == 2);
		assert(fixture.removedChildren.canFind(2));
		assert(fixture.removedChildren.canFind(3));
		assert(!backend.hasTaskDependency(2));
		assert(!backend.hasTaskDependency(3));
		assert(fixture.tasks[1].status == TaskStatus.active);
		assert(fixture.waitingToActiveTransitions == 1);

		backend.onToolCallDelivered("1");
		assert(fixture.persistRemoveDependencyCalls == 2);
		assert(fixture.waitingToActiveTransitions == 1);
	}

	// A real live batch continues to defer dependency cleanup.
	{
		auto fixture = new BatchInvariantFixture;
		fixture.tasks[1].status = TaskStatus.waiting;
		auto backend = fixture.makeBackend();
		__traits(getMember, backend, "taskDeps_")[2] = 1;
		auto registry = batchRegistryOf(backend);
		BatchHandle handle;
		string error;
		assert(registry.create(1, [2], handle, error), error);

		backend.onToolCallDelivered("1");
		assert(fixture.persistRemoveDependencyCalls == 0);
		assert(backend.hasTaskDependency(2));
		assert(fixture.tasks[1].status == TaskStatus.waiting);
	}

	// Handoff distinguishes absence, a real pending question, and corruption.
	{
		auto fixture = new BatchInvariantFixture;
		auto backend = fixture.makeBackend();
		auto registry = batchRegistryOf(backend);
		assert(!backend.hasPendingChildQuestion(1));

		BatchHandle handle;
		string error;
		assert(registry.create(1, [2], handle, error), error);
		backend.handleAsk("2", "need an answer", -1).ignoreResult();
		assert(backend.hasPendingChildQuestion(1));
		auto handoff = backend.handleHandoff(
			"1", "continue", "handoff prompt");
		assert(handoff.isError);
		assert(handoff.text.canFind("Handoff cannot continue"));

		Promise!BatchSignal questionEvent;
		assert(registry.waitOne(handle, questionEvent, error), error);
		questionEvent.then((BatchSignal signal) {}).ignoreResult();
		drainPromiseNextTicks();

		__traits(getMember, *registry, "batchIdsByParentTid").remove(1);
		assertThrown!AssertError(backend.hasPendingChildQuestion(1));
		assertThrown!AssertError(backend.handleHandoff(
			"1", "continue", "handoff prompt"));
		assert(registry.exists(handle));
	}

	// A completed old slot cannot smuggle a dangling alleged later owner
	// through the parent-wide Handoff scan.
	{
		auto fixture = new BatchInvariantFixture;
		auto backend = fixture.makeBackend();
		auto registry = batchRegistryOf(backend);
		BatchHandle oldHandle;
		string error;
		assert(registry.create(1, [2, 3], oldHandle, error), error);
		auto consumed = registry.consume(oldHandle,
			BatchSignal.childDone(oldHandle.batchId, 0, 2,
				McpResult("first", false)),
			(int childTid, int qid) => false, error);
		assert(consumed.kind == BatchConsumeKind.childDone);
		assert(error.length == 0);
		auto oldBatch = ActiveBatchKey(oldHandle.parentTid, oldHandle.batchId)
			in __traits(getMember, *registry, "activeBatches");
		assert(oldBatch !is null);
		assert((*oldBatch).done[0] && !(*oldBatch).done[1]);
		__traits(getMember, *registry, "batchKeyByChildTid")[2] =
			ActiveBatchKey(999, 999);

		assert(fixture.tasks[1].pendingContinuation is null);
		assert(fixture.tasks[1].status == TaskStatus.active);
		assertThrown!AssertError(backend.handleHandoff(
			"1", "continue", "handoff prompt"));
		assert(fixture.tasks[1].pendingContinuation is null);
		assert(fixture.tasks[1].status == TaskStatus.active);
		assert(registry.exists(oldHandle));
	}

	// Handoff validates live child ownership before treating a question as absent.
	{
		auto fixture = new BatchInvariantFixture;
		auto backend = fixture.makeBackend();
		auto registry = batchRegistryOf(backend);
		BatchHandle handle;
		string error;
		assert(registry.create(1, [2], handle, error), error);
		backend.handleAsk("2", "need an answer", -1).ignoreResult();
		assert(backend.hasPendingChildQuestion(1));
		auto router = __traits(getMember, backend, "questionRouter_");
		assert(__traits(getMember, router, "questionRoutes_").length == 1);
		assert(__traits(getMember, router, "pendingQuestions_").length == 1);
		Promise!BatchSignal questionEvent;
		assert(registry.waitOne(handle, questionEvent, error), error);
		questionEvent.then((BatchSignal signal) {}).ignoreResult();
		drainPromiseNextTicks();

		corruptOrderedChild(registry, handle);
		assert(fixture.tasks[1].pendingContinuation is null);
		assertThrown!AssertError(backend.handleHandoff(
			"1", "continue", "handoff prompt"));
		assert(fixture.tasks[1].pendingContinuation is null);
		assert(fixture.tasks[2].status == TaskStatus.waiting);
		assert(fixture.tasks[2].pendingAskPromise !is null);
		assert(fixture.tasks[2].pendingAskQuestion == "need an answer");
		assert(fixture.tasks[2].pendingAskQid > 0);
		assert(__traits(getMember, router, "questionRoutes_").length == 1);
		assert(__traits(getMember, router, "pendingQuestions_").length == 1);
		assert(registry.exists(handle));
	}

	// A partial parent index cannot hide a pending question during Handoff.
	{
		auto fixture = new BatchInvariantFixture;
		fixture.tasks[3] = TaskData(3, "local", "/tmp/cydo-batch-invariants");
		fixture.tasks[3].taskType = "child";
		fixture.tasks[3].agentName = "fake";
		fixture.tasks[3].parentTid = 1;
		fixture.tasks[3].status = TaskStatus.active;
		auto backend = fixture.makeBackend();
		auto registry = batchRegistryOf(backend);
		BatchHandle visible;
		BatchHandle omitted;
		string error;
		assert(registry.create(1, [2], visible, error), error);
		assert(registry.create(1, [3], omitted, error), error);
		backend.handleAsk("3", "need an answer", -1).ignoreResult();
		assert(backend.hasPendingChildQuestion(1));

		Promise!BatchSignal questionEvent;
		assert(registry.waitOne(omitted, questionEvent, error), error);
		questionEvent.then((BatchSignal signal) {}).ignoreResult();
		drainPromiseNextTicks();

		__traits(getMember, *registry, "batchIdsByParentTid")[1] =
			[visible.batchId];
		assert(fixture.tasks[1].pendingContinuation is null);
		assertThrown!AssertError(backend.hasPendingChildQuestion(1));
		assertThrown!AssertError(backend.handleHandoff(
			"1", "continue", "handoff prompt"));
		assert(fixture.tasks[1].pendingContinuation is null);
		assert(registry.exists(visible));
		assert(registry.exists(omitted));
	}

	// Local slotByChildTid corruption must still escape through the real Promise
	// scheduler.
	{
		auto fixture = new BatchInvariantFixture;
		auto backend = fixture.makeBackend();
		auto childResult = new Promise!McpResult;
		auto batchResult = async({
			return backend.registerBatchAndAwait("1",
				[LaunchedTask(2, childResult)]).await;
		});
		batchResult.ignoreResult();

		auto registry = batchRegistryOf(backend);
		auto handle = liveHandle(registry, 2);
		auto key = ActiveBatchKey(handle.parentTid, handle.batchId);
		__traits(getMember, *registry,
			"activeBatches")[key].slotByChildTid.remove(2);

		childResult.fulfill(McpResult("done", false));
		assertThrown!AssertError(drainPromiseNextTicks());
	}
}
