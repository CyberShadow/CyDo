module cydo.workflow.tools.backend;

import core.time : Duration;
import std.datetime.systime : Clock, SysTime;
import std.format : format;
import std.logger : errorf, infof, tracef, warningf;
import std.process : execute;
import std.string : strip;

import ae.sys.timing : TimerTask, setTimeout;
import ae.utils.json : JSONFragment, jsonParse, toJson;
import ae.utils.promise : Promise, resolve;
import ae.utils.promise.await : async, await;

import cydo.agent.contract : Agent;
import cydo.agent.terminal : TerminalProcess;
import cydo.domain.policy.permissions : PermissionEscalation, PermissionPrompt,
	PermissionSettings, ToolCallDecision, ToolCallRuling, evaluatePermissionPolicy,
	makePermissionAllowJson, makePermissionDenyJson;
import cydo.domain.task_types.definition : ContinuationDef, CreatableTaskDef, DjinjaTemplate, TaskTypeDef,
	UserEntryPointDef, SingletonDef, WorktreeMode, byName, isInteractive, singletonsOfferedTo,
	loadProjectMemory, renderContinuationPrompt, renderPrompt, resolveAgent,
	substituteVars;
import cydo.domain.tasks.model;
import cydo.domain.tasks.lifecycle : TaskNotificationChange;
import cydo.foundation.system.known_messages : KnownSystemMessageKind,
	followUpFromParentSubject, handoffSubject, modeSwitchSubject,
	questionFromTaskSubject, subTaskWaitingForAnswerSubject,
	systemMessageSubject, taskPromptSubject, wrapKnownSystemMessage;
import cydo.foundation.system.framing : prependTaskFraming;
import cydo.foundation.text.title : truncateTitle;
import cydo.mcp : McpResult;
import cydo.mcp.payloads : TaskResult;
import cydo.mcp.tools : AskQuestion, LaunchedTask, ToolsBackend,
	ValidatedTask;
import cydo.protocol : AnswerResult, BatchResultEnvelope, ContentBlock, QuestionResult;
import cydo.workflow.batch.registry : BatchHandle, BatchRegistry;
import cydo.workflow.mailbox : Mailbox, MailboxEvent;
import cydo.workflow.questions.router : makeQuestionMessage;
import cydo.workflow.tasks.subtask_delivery : SubtaskResultDelivery,
	SubtaskResultDeliveryHost, renderBatchResults;

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
	bool delegate() shuttingDown;
	/// Tell the task's agent, if it keeps its own history, that the tool call
	/// it recorded as aborted was accepted. Fulfilled at once for the others.
	Promise!void delegate(int tid, string correction) correctAbortedToolCall;
	Promise!void delegate(int tid, const(ContentBlock)[] content,
		const(ContentBlock)[] broadcastContent, string cydoMeta,
		string nonce) sendTaskMessage;
	void delegate(int tid, string reason, string excludedUserUuid) emitTaskReload;
	void delegate(int tid, string subject,
		string body) appendTaskDiagnostic;
	void delegate(int tid, string subject,
		string body) appendAndBroadcastRecoveryDeliveryDiagnostic;

	bool delegate(int tid) taskAlive;
	/// Find or start the named singleton.
	Promise!int delegate(int callerTid, string name) singletonForTask;
	SingletonDef[] delegate(string projectPath) singletonsForProject;
	string delegate(const TaskData* td) effectiveCwd;
	bool delegate(int aTid, int bTid) tasksShareWorkspace;
	string delegate(int tid) taskWorkspaceLabel;
	Promise!void delegate(int tid) reactivateTask;
	Promise!void delegate(int tid, KnownSystemMessageKind kind, string body)
		sendKnownSystemMessage;
	Promise!void delegate(int tid, const(ContentBlock)[] blocks,
		string cydoMeta, string nonce) sendPreparedKnownSystemMessage;

	void delegate(int parentTid, int childTid) persistAddTaskDep;
	void delegate(int parentTid, int childTid) persistRemoveTaskDep;
	void delegate(int childTid) persistRemoveAllChildDeps;
	int[][int] delegate() loadTaskDeps;

	void delegate(int tid) broadcastTaskUpdate;
	void delegate(int fromTid, int toTid) broadcastFocusHint;
	void delegate(int tid, JSONFragment questions, string toolUseId)
		sendAskUserQuestionPrompt;
	void delegate(int tid) clearAskUserQuestionPrompt;
	void delegate(int tid, const PendingPermission pending) sendPermissionPrompt;
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
		shuttingDown: () => false,
		ensureProcessQueueAlive: (int tid) => tid == 2 ? reject!void(new Exception("simulated child session startup failure")) : resolve(),
		sendTaskMessage: (int tid, const(ContentBlock)[] content, const(ContentBlock)[] broadcastContent, string cydoMeta, string nonce) { assert(tid == 3); return resolve(); },
		emitTaskReload: (int tid, string reason, string excludedUserUuid) {},
		appendTaskDiagnostic: (int tid, string subject, string body) {},
		taskAlive: (int tid) => false, tasksShareWorkspace: (int aTid, int bTid) => true,
		taskWorkspaceLabel: (int tid) => "local",
		reactivateTask: (int tid) => resolve(),
		sendKnownSystemMessage: (int tid, KnownSystemMessageKind kind, string body) { return resolve(); },
		persistAddTaskDep: (int parentTid, int childTid) {}, persistRemoveTaskDep: (int parentTid, int childTid) {},
		persistRemoveAllChildDeps: (int childTid) {}, loadTaskDeps: () => cast(int[][int]) null,
		broadcastTaskUpdate: (int tid) {}, broadcastFocusHint: (int fromTid, int toTid) {},
		sendAskUserQuestionPrompt: (int tid, JSONFragment questions, string toolUseId) {},
		clearAskUserQuestionPrompt: (int tid) {},
		sendPermissionPrompt: (int tid, const PendingPermission pending) {},
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
	int[int] taskDeps_;
	Promise!(McpResult)[int] pendingAskUserQuestions_;
	/// Fulfilled with the decision payload sent back to the agent.
	Promise!string[int] pendingPermissionPrompts_;
	string[int] pendingPermissionInputs_;
	/// Deny a pending permission prompt nobody answers in time.
	TimerTask[int] permissionPromptTimeouts_;
	BatchRegistry batchRegistry_;
	Mailbox[int] mailboxes_;
	ref Mailbox mailbox(int tid)
	{
		if ((tid in mailboxes_) is null) mailboxes_[tid] = Mailbox.init;
		return mailboxes_[tid];
	}
	enum QuestionState { open, answered, failed, cancelled }

	struct QuestionRecord
	{
		int qid, askerTid, answererTid;
		string text, answer;
		QuestionState state;
	}
	QuestionRecord[int] questions_;
	int nextQid_ = 1;
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
				parentTaskForChild: &parentTaskForChild,
				childTaskIds: &childrenOf,
				broadcastFocusHint: host_.broadcastFocusHint,
				ensureProcessQueueAlive: host_.ensureProcessQueueAlive,
				shuttingDown: host_.shuttingDown,
				sendKnownSystemMessage: host_.sendKnownSystemMessage,
				removeTaskDependency: &removeTaskDependency,
				taskAlive: host_.taskAlive,
				onNextTick: host_.onNextTick,
				appendAndBroadcastRecoveryDeliveryDiagnostic:
					host_.appendAndBroadcastRecoveryDeliveryDiagnostic,
			));

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
					return LaunchedTask(childTid);
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
				recordChildTerminal(childTid);
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

			return LaunchedTask(childTid);
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

		if (host_.taskTypesForProject(td.projectPath).byName(td.taskType) is null
			|| !isInteractiveTask(td))
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
			childTids[i] = launchedTask.childTid;

		BatchHandle handle;
		string batchError;
		if (!batchRegistry_.create(parentTid, childTids, handle, batchError))
			return resolve(makeInternalBatchError(batchError));

		foreach (childTid; childTids)
		{
			auto child = requireTask(childTid, "Registered child must exist");
			if (child.status == TaskStatus.completed || child.status == TaskStatus.failed)
				recordChildTerminal(childTid);
		}

		return awaitEvent(parentTid);
	}

	Promise!McpResult handleAsk(string callerTidStr, string message,
		int targetTid)
	{
		import std.conv : to;
		int askerTid;
		try askerTid = to!int(callerTidStr);
		catch (Exception) return resolve(McpResult("Invalid calling task ID", true));
		auto asker = host_.getTask(askerTid);
		if (asker is null) return resolve(McpResult("Task not found", true));
		bool explicitTarget = targetTid != -1;
		if (!explicitTarget)
		{
			if (asker.parentTid <= 0)
				return resolve(McpResult("No parent task — tid is required", true));
			targetTid = asker.parentTid;
		}
		auto answerer = host_.getTask(targetTid);
		if (answerer is null)
			return resolve(McpResult("Target task not found: " ~ to!string(targetTid), true));
		if (targetTid == askerTid)
			return resolve(McpResult("Ask target must be a different task", true));
		if (explicitTarget && answerer.status == "importable")
			return resolve(McpResult("Cannot Ask importable task " ~ to!string(targetTid)
				~ "; import or resume it first", true));
		if (!host_.tasksShareWorkspace(askerTid, targetTid))
			return resolve(McpResult("Ask target must be in the same workspace (caller="
				~ host_.taskWorkspaceLabel(askerTid) ~ ", target="
				~ host_.taskWorkspaceLabel(targetTid) ~ ")", true));
		if (answerer.parentTid == askerTid)
		{
			int pendingQid = presentedQuestionFor(targetTid);
			if (pendingQid > 0)
				return resolve(McpResult(
					"Sub-task has a pending question (qid=" ~ to!string(pendingQid)
					~ "). Use Answer(qid, message) instead.", true));
		}
		auto qid = nextQid_++;
		questions_[qid] = QuestionRecord(qid, askerTid, targetTid, message);
		mailbox(targetTid).push(MailboxEvent(MailboxEvent.Kind.question, 0, qid));
		pump(targetTid);
		if (asker.status != TaskStatus.waiting)
			host_.transitionTaskFrom(askerTid,
				[TaskStatus.active, TaskStatus.alive], TaskStatus.waiting,
				TaskNotificationChange.preserve);
		host_.broadcastFocusHint(askerTid, targetTid);
		return awaitEvent(askerTid);
	}

	Promise!McpResult handleAnswer(string callerTidStr, int qid,
		string message)
	{
		import std.conv : to;
		int answererTid;
		try answererTid = to!int(callerTidStr);
		catch (Exception) return resolve(McpResult("Invalid calling task ID", true));
		auto answerer = host_.getTask(answererTid);
		if (answerer is null) return resolve(McpResult("Task not found", true));
		auto q = qid in questions_;
		auto unknown = McpResult("Unknown question ID: " ~ to!string(qid), true);
		if (q is null || q.answererTid != answererTid)
			return resolve(unknown);
		final switch (q.state)
		{
		case QuestionState.open:
			if (hasEvent(answererTid, MailboxEvent.Kind.question, qid))
				return resolve(unknown);
			break;
		case QuestionState.answered:
		case QuestionState.failed:
			return resolve(unknown);
		case QuestionState.cancelled:
			return resolve(McpResult(format!"Question %s was cancelled: the asking task has ended"(qid), true));
		}
		q.state = QuestionState.answered;
		q.answer = message;
		mailbox(q.askerTid).push(MailboxEvent(MailboxEvent.Kind.answer, 0, qid));
		pump(q.askerTid);
		host_.broadcastFocusHint(answererTid, q.askerTid);
		if (hasOutstandingWait(answererTid) && presentedQuestionFor(answererTid) == 0)
		{
			if (answerer.status != TaskStatus.waiting)
				host_.transitionTaskFrom(answererTid,
					[TaskStatus.active, TaskStatus.alive], TaskStatus.waiting,
					TaskNotificationChange.preserve);
			return awaitEvent(answererTid);
		}
		return resolve(McpResult.structured(toJson(AnswerResult("delivered",
			q.askerTid, qid, null, null, null))));
	}

	Promise!McpResult handleRequest(string callerTidStr, string target, string message)
	{
		import std.algorithm : map;
		import std.array : join;
		import std.conv : to;

		int callerTid;
		try
			callerTid = to!int(callerTidStr);
		catch (Exception)
			return resolve(McpResult("Invalid calling task ID", true));
		auto callerTd = host_.getTask(callerTid);
		if (callerTd is null)
			return resolve(McpResult("Task not found", true));

		auto projectPath = callerTd.projectPath;
		auto offered = singletonsOfferedTo(host_.taskTypesForProject(projectPath),
			host_.entryPointsForProject(projectPath), host_.singletonsForProject(projectPath),
			callerTd.taskType);
		if (offered.byName(target) is null)
		{
			auto valid = offered.map!(s => s.name).join(", ");
			return resolve(McpResult("Singleton '" ~ target
				~ "' is unavailable. Valid targets: " ~ (valid.length ? valid : "(none)"), true));
		}

		auto request = host_.readPromptFile("prompts/singleton_request.md", projectPath, [
			"message": message,
			"singleton": target,
			"directory": host_.effectiveCwd(callerTd),
		]);
		return host_.singletonForTask(callerTid, target).then(
			(int targetTid) => handleAsk(callerTidStr, request, targetTid),
			(Exception e) => resolve(McpResult(e.msg, true)));
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
				return resolve(makePermissionDenyJson(host_.readPromptFile(
					"prompts/dangerous_call_denied.md", td.projectPath, [
						"denial": ruling.denyReason,
						"reason": prompt.reason,
					])));
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
			toolName, input.json, dangerous, isInteractiveTask(td)))
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

	/// Whether `td` is of an interactive task type, one a person works in.
	private bool isInteractiveTask(const TaskData* td)
	{
		return host_.taskTypesForProject(td.projectPath).isInteractive(
			host_.entryPointsForProject(td.projectPath), td.taskType);
	}

	/// The agent no longer awaits the decision for `toolUseId` (e.g. its turn
	/// was interrupted): take the prompt down.
	void withdrawToolPermissionPrompt(int tid, string toolUseId)
	{
		auto td = requireTask(tid, "Withdrawn tool permission request for a missing task");
		// A concurrent request refused with "Another permission prompt is
		// already pending" never had a prompt of its own.
		if ((tid in pendingPermissionPrompts_) is null
			|| td.pendingPermission.prompt.toolUseId != toolUseId)
			return;
		settlePermissionPrompt(tid,
			makePermissionDenyJson("Permission request withdrawn by the agent"));
	}

	void onToolCallDelivered(string callerTidStr, McpResult result)
	{
		if (result.settleDelivery !is null)
			result.settleDelivery(true);

		import std.conv : to;

		int tid;
		try
			tid = to!int(callerTidStr);
		catch (Exception)
			return;

		auto td = host_.getTask(tid);
		if (td is null)
			return;

		if (td.status == TaskStatus.waiting)
			host_.transitionTask(tid, TaskStatus.waiting, TaskStatus.active,
				TaskNotificationChange.preserve);
	}

	void onMcpDeliveryFailed(string callerTidStr, McpResult result)
	{
		if (result.settleDelivery !is null)
			result.settleDelivery(false);

		import std.conv : to;

		int tid;
		try
			tid = to!int(callerTidStr);
		catch (Exception)
			return;

		if (host_.getTask(tid) is null)
			return;
		if (host_.shuttingDown() || pump(tid) || batchRegistry_.hasBatches(tid))
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

		td.pendingPermission = PendingPermission.init;
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
			&& td.pendingPermission.prompt.toolUseId.length > 0)
		{
			send(toJson(PermissionPromptMessage.of(tid, td.pendingPermission)));
		}
	}

	bool hasLiveBatchOwner(int tid)
	{
		BatchHandle handle;
		size_t slot;
		return batchRegistry_.findOwnerOfChild(tid, handle, slot);
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
			"Pending question must belong to a live asker task");
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
			auto pending = qid in questions_;
			if (pending !is null && pending.state == QuestionState.open)
				pump(failQuestion(qid, "Failed to submit sub-task answer reminder: " ~ e.msg));
		}).ignoreResult();
	}

	bool finalizeCompletedSubTask(int tid)
	{
		auto td = requireTask(tid, "Completed sub-task must exist");
		host_.persistResultText(tid, td.resultText);
		host_.transitionTaskFrom(tid,
			[TaskStatus.active, TaskStatus.alive, TaskStatus.waiting],
			TaskStatus.completed, TaskNotificationChange.preserve);
		return recordChildTerminal(tid);
	}

	bool recordChildTerminal(int tid)
	{
		BatchHandle handle;
		size_t slot;
		if (!batchRegistry_.findOwnerOfChild(tid, handle, slot))
			return batchRegistry_.isRecorded(tid);
		auto result = subtaskResultDelivery_.taskResult(tid);
		if (batchRegistry_.recordChildDone(handle, slot, tid,
			McpResult.structured(toJson(result), result.status == "error")))
		{
			mailbox(handle.parentTid).push(MailboxEvent(
				MailboxEvent.Kind.batch, handle.batchId));
			pump(handle.parentTid);
		}
		return true;
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
			td.pendingPermission = PendingPermission.init;
		}
	}

	void onTaskTerminal(int tid)
	{
		cleanUpAskedQuestions(tid);
		auto askers = failQuestionsForAnswerer(tid, "Session ended while waiting for Ask response");
		mailbox(tid).release(new Exception(
			"Session ended while waiting for Ask response"));
		foreach (askerTid; askers)
			pump(askerTid);
		pump(tid);
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
		// The session that made the SwitchMode call ended before the call's
		// result reached its agent.
		auto acceptedSwitchMode = td.pendingContinuation.kind == PendingContinuation.Kind.switchMode
			? td.pendingContinuation.resultText : null;
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
			repairedInterruptionUuid, acceptedSwitchMode);
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
	}

	void cleanUpAskedQuestions(int tid)
	{
		int[] removeQids, failedQids;
		foreach (qid, ref q; questions_)
		{
			if (q.askerTid != tid)
				continue;
			final switch (q.state)
			{
			case QuestionState.open:
				if (removeQuestionEvent(q.answererTid, MailboxEvent.Kind.question, qid))
					removeQids ~= qid;
				else
				{
					q.state = QuestionState.cancelled;
				}
				break;
			case QuestionState.answered:
				removeQuestionEvent(tid, MailboxEvent.Kind.answer, qid);
				removeQids ~= qid;
				break;
			case QuestionState.failed:
				removeQuestionEvent(tid, MailboxEvent.Kind.failed, qid);
				failedQids ~= qid;
				break;
			case QuestionState.cancelled:
				break;
			}
		}
		foreach (qid; removeQids) questions_.remove(qid);
		foreach (qid; failedQids) questions_.remove(qid);
	}

	bool removeQuestionEvent(int tid, MailboxEvent.Kind kind, int qid)
	{
		return mailbox(tid).remove((in MailboxEvent e) => e.kind == kind && e.qid == qid);
	}

	int failQuestion(int qid, string notice)
	{
		auto q = qid in questions_;
		assert(q !is null && q.state == QuestionState.open);
		removeQuestionEvent(q.answererTid, MailboxEvent.Kind.question, qid);
		q.state = QuestionState.failed;
		mailbox(q.askerTid).push(MailboxEvent(MailboxEvent.Kind.failed, 0, qid, notice, q.answererTid));
		return q.askerTid;
	}

	McpResult makeInternalBatchError(string message)
	{
		errorf("batch router error: %s", message);
		return McpResult("Internal batch routing error: " ~ message, true);
	}

	McpResult envelopeResult(BatchHandle handle)
	{
		bool anyError;
		JSONFragment[] items;
		foreach (ref childResult; batchRegistry_.envelope(handle))
		{
			items ~= childResult.structuredContent
				? childResult.structuredContent
				: JSONFragment(toJson(childResult.text));
			anyError = anyError || childResult.isError;
		}
		return McpResult.structured(toJson(BatchResultEnvelope(items)), anyError);
	}

	bool hasEvent(int tid, MailboxEvent.Kind kind, int qid = 0,
		ulong batchId = 0)
	{
		foreach (event; mailbox(tid).events)
			if (event.kind == kind && event.qid == qid
				&& event.batchId == batchId)
				return true;
		return false;
	}

	int presentedQuestionFor(int tid)
	{
		int earliest = int.max;
		foreach (qid, q; questions_)
			if (q.answererTid == tid && q.state == QuestionState.open
				&& !hasEvent(tid, MailboxEvent.Kind.question, qid)
				&& qid < earliest)
				earliest = qid;
		return earliest == int.max ? 0 : earliest;
	}

	bool hasOutstandingWait(int tid)
	{
		if (batchRegistry_.hasBatches(tid))
			return true;
		foreach (q; questions_)
			if (q.askerTid == tid && q.state != QuestionState.cancelled)
				return true;
		return false;
	}

	bool deliverable(int tid, in MailboxEvent event)
	{
		auto q = event.qid in questions_;
		final switch (event.kind)
		{
		case MailboxEvent.Kind.batch:
			return batchRegistry_.exists(BatchHandle(tid, event.batchId));
		case MailboxEvent.Kind.question:
			return q !is null && q.state == QuestionState.open;
		case MailboxEvent.Kind.answer:
			return q !is null && q.state == QuestionState.answered;
		case MailboxEvent.Kind.failed:
			return q !is null && q.state == QuestionState.failed;
		}
	}

	void delegate(bool) deliveryAttempt(int tid, MailboxEvent[] taken)
	{
		int[][ulong] batchChildren;
		foreach (event; taken)
			if (event.kind == MailboxEvent.Kind.batch)
				batchChildren[event.batchId] = batchRegistry_.children(BatchHandle(tid, event.batchId));

		return (bool delivered) {
			assert(taken.length, "Mailbox delivery attempt already settled");
			auto events = taken;
			taken = null;
			if (delivered)
			{
				foreach (event; events)
				{
					final switch (event.kind)
					{
					case MailboxEvent.Kind.batch:
						auto handle = BatchHandle(tid, event.batchId);
						foreach (childTid; batchChildren[event.batchId])
						{
							host_.broadcastFocusHint(childTid, tid);
							removeTaskDependency(tid, childTid);
						}
						string error;
						auto removed = batchRegistry_.remove(handle, error);
						assert(removed, error);
						break;
					case MailboxEvent.Kind.answer:
						questions_.remove(event.qid);
						break;
					case MailboxEvent.Kind.failed:
						host_.broadcastFocusHint(event.answererTid, tid);
						questions_.remove(event.qid);
						break;
					case MailboxEvent.Kind.question:
						break;
					}
				}
			}
			else
			{
				import std.algorithm : filter;
				import std.array : array;
				auto pending = events.filter!(e => deliverable(tid, e)).array;
				if (pending.length)
					mailbox(tid).putBack(pending);
			}
		};
	}

	int[] failQuestionsForAnswerer(int tid, string reason)
	{
		int[] askers, removeQids;
		foreach (qid, ref q; questions_)
		{
			if (q.answererTid != tid)
				continue;
			final switch (q.state)
			{
			case QuestionState.open:
				askers ~= failQuestion(qid, format!"Question %d: %s"(qid, reason));
				break;
			case QuestionState.cancelled:
				removeQids ~= qid;
				break;
			case QuestionState.answered:
			case QuestionState.failed:
				break;
			}
		}
		foreach (qid; removeQids) questions_.remove(qid);
		return askers;
	}

public:
	bool pump(int tid)
	{
		import std.array : join;
		import std.conv : to;
		if (host_.shuttingDown())
			return false;
		auto td = host_.getTask(tid);
		if (td is null || td.isProcessing || td.hasPendingQuestion
			|| mailbox(tid).empty)
			return false;
		if (td.status != TaskStatus.active && td.status != TaskStatus.alive
			&& td.status != TaskStatus.waiting
			&& td.status != TaskStatus.completed && td.status != TaskStatus.failed)
			return false;
		bool wasTerminal = td.status == TaskStatus.completed
			|| td.status == TaskStatus.failed;
		// Keep events held while the asynchronous wake is in flight.
		td.isProcessing = true;
		void releaseClaim()
		{
			td.isProcessing = false;
			host_.broadcastTaskUpdate(tid);
		}
		void delegate(bool) settleDelivery;
		void deliveryFailed(Exception e)
		{
			bool shuttingDown = host_.shuttingDown();
			bool terminal = td.status == TaskStatus.completed || td.status == TaskStatus.failed;
			int[] askers;
			if (!shuttingDown && terminal)
				askers = failQuestionsForAnswerer(tid, e.msg);
			if (settleDelivery !is null)
				settleDelivery(false);
			releaseClaim();
			if (shuttingDown)
				return;
			if (terminal)
			{
				foreach (askerTid; askers)
					pump(askerTid);
				warningf("Cannot wake terminal task %s for mailbox delivery: %s",
					tid, e.msg);
			}
			else
				subtaskResultDelivery_.recoveryDeliveryFailed(tid, e);
		}
		try host_.ensureProcessQueueAlive(tid).then(() {
			if (host_.shuttingDown() || mailbox(tid).empty)
			{
				releaseClaim();
				return resolve();
			}
			auto drained = mailbox(tid).events;
			mailbox(tid).events = null;
			settleDelivery = deliveryAttempt(tid, drained);
			ContentBlock[] blocks;
			string[] nonces;
			string firstMeta;
			foreach (event; drained)
			{
				assert(deliverable(tid, event));
				KnownSystemMessageKind kind;
				string body, subject, meta, nonce;
				final switch (event.kind)
				{
				case MailboxEvent.Kind.batch:
					kind = KnownSystemMessageKind.subTaskResults;
					subject = systemMessageSubject(kind);
					string[] resultJsons;
					foreach (result; batchRegistry_.envelope(BatchHandle(tid, event.batchId)))
						resultJsons ~= result.structuredContent
							? result.structuredContent.json : toJson(result.text);
					body = renderBatchResults(resultJsons);
					meta = host_.buildKnownSystemMessageMeta(kind, subject, null, null);
					nonce = "batch:" ~ event.batchId.to!string;
					break;
				case MailboxEvent.Kind.question:
					auto q = questions_[event.qid];
					bool followUp = wasTerminal && td.parentTid == q.askerTid;
					kind = followUp ? KnownSystemMessageKind.followUpFromParent
						: KnownSystemMessageKind.questionFromTask;
					subject = followUp ? followUpFromParentSubject(q.qid)
						: questionFromTaskSubject(q.askerTid, q.qid);
					body = host_.readPromptFile(followUp
						? "prompts/follow_up_from_parent.md"
						: "prompts/question_from_task.md", td.projectPath,
						["message": q.text, "qid": q.qid.to!string]);
					meta = host_.buildKnownSystemMessageMeta(kind, subject,
						["message": q.text], "message");
					nonce = (followUp ? "follow-up:" : "question:")
						~ q.qid.to!string;
					host_.broadcastFocusHint(q.askerTid, tid);
					break;
				case MailboxEvent.Kind.answer:
					auto q = questions_[event.qid];
					kind = KnownSystemMessageKind.subTaskResults;
					subject = "Answer to your question " ~ q.qid.to!string;
					body = subject ~ "\n" ~ toJson(AnswerResult("answered",
						q.answererTid, q.qid, null, q.answer, null));
					meta = host_.buildKnownSystemMessageMeta(kind, subject, null, null);
					nonce = "answer:" ~ q.qid.to!string;
					break;
				case MailboxEvent.Kind.failed:
					kind = KnownSystemMessageKind.subTaskResults;
					subject = systemMessageSubject(kind);
					body = event.error;
					meta = host_.buildKnownSystemMessageMeta(kind, subject, null, null);
					nonce = "failed:" ~ event.qid.to!string;
					break;
				}
				auto wrapped = kind == KnownSystemMessageKind.questionFromTask
					? makeQuestionMessage(host_.systemKeyword(),
						questions_[event.qid].askerTid, event.qid, body)
					: wrapKnownSystemMessage(host_.systemKeyword(), kind, body, subject);
				blocks ~= ContentBlock("text", wrapped);
				if (firstMeta.length == 0) firstMeta = meta;
				nonces ~= nonce;
			}
			return host_.sendPreparedKnownSystemMessage(tid, blocks,
				firstMeta, nonces.join(";")).then(() {
				settleDelivery(true);
			});
		}).except(&deliveryFailed).ignoreResult();
		catch (Exception e)
			deliveryFailed(e);
		return true;
	}

private:
	Promise!McpResult awaitEvent(int tid)
	{
		return async({
			MailboxEvent ev;
			try ev = mailbox(tid).take().await;
			catch (Exception e) return McpResult(e.msg, true);
			McpResult result;
			final switch (ev.kind)
			{
				case MailboxEvent.Kind.batch:
					result = envelopeResult(BatchHandle(tid, ev.batchId));
					break;
				case MailboxEvent.Kind.question:
				{
					auto q = ev.qid in questions_;
					assert(q !is null && q.state != QuestionState.failed);
					auto asker = host_.getTask(q.askerTid);
					result = McpResult.structured(toJson(QuestionResult("question",
						q.askerTid, q.qid, asker is null ? null : asker.title, q.text)));
					break;
				}
				case MailboxEvent.Kind.answer:
				{
					assert(deliverable(tid, ev));
					auto q = questions_[ev.qid];
					auto answerer = host_.getTask(q.answererTid);
					result = McpResult.structured(toJson(AnswerResult("answered",
						q.answererTid, q.qid, answerer is null ? null : answerer.title,
						q.answer, null)));
					break;
				}
				case MailboxEvent.Kind.failed:
					result = McpResult(ev.error, true);
					break;
			}
			result.settleDelivery = deliveryAttempt(tid, [ev]);
			return result;
		});
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
		// A zero timeout waits indefinitely.
		td.pendingPermission = PendingPermission(prompt,
			timeout > Duration.zero ? Clock.currTime + timeout : SysTime.init);

		host_.sendPermissionPrompt(tid, td.pendingPermission);
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
		qid = presentedQuestionFor(tid);
		if (qid == 0) return false;
		auto q = questions_[qid];
		childTid = q.askerTid;
		question = q.text;
		return true;
	}

	/// `acceptedSwitchMode`: the result of the SwitchMode call that asked for
	/// this continuation, when the agent's session ended without receiving it.
	void executeContinuation(int tid, ContinuationDef contDef,
		string handoffPrompt, string edgeName, string excludedUserUuid = null,
		string acceptedSwitchMode = null)
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
			auto projectPath = td.projectPath;
			host_.ensureProcessQueueAlive(tid).then(() {
				if (acceptedSwitchMode.length == 0)
					return resolve();
				return host_.correctAbortedToolCall(tid, host_.readPromptFile(
					"prompts/aborted_tool_call_accepted.md", projectPath,
					["tool_name": "SwitchMode", "result": acceptedSwitchMode]));
			}).then(() {
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
				recordChildTerminal(tid);
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

			BatchHandle owner;
			size_t slot;
			if (batchRegistry_.findOwnerOfChild(tid, owner, slot))
			{
				batchRegistry_.replaceChild(tid, childTid);
				host_.persistRemoveAllChildDeps(tid);
				host_.persistAddTaskDep(owner.parentTid, childTid);
				taskDeps_.remove(tid);
				taskDeps_[childTid] = owner.parentTid;
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
				recordChildTerminal(childTid);
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
		shuttingDown: () => false,
		ensureProcessQueueAlive: (int tid) {
			if (tid == 1)
				return resolve();
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
		appendAndBroadcastRecoveryDeliveryDiagnostic: (int tid, string subject, string body) {
			assert(0, "recovery delivery must not fail in this test: " ~ subject ~ ": " ~ body);
		},
		taskAlive: (int tid) => false,
		tasksShareWorkspace: (int aTid, int bTid) => true,
		taskWorkspaceLabel: (int tid) => "local",
		reactivateTask: (int tid) => resolve(),
		sendKnownSystemMessage: (int tid, KnownSystemMessageKind kind,
			string body) { return resolve(); },
		sendPreparedKnownSystemMessage: (int tid, const(ContentBlock)[] blocks,
			string cydoMeta, string nonce) {
			assert(0, "results must reach the parent through its awaiting Task call, not a system message");
			return resolve();
		},
		persistAddTaskDep: (int parentTid, int childTid) {},
		persistRemoveTaskDep: (int parentTid, int childTid) {},
		persistRemoveAllChildDeps: (int childTid) {},
		loadTaskDeps: () => cast(int[][int]) null,
		broadcastTaskUpdate: (int tid) {},
		broadcastFocusHint: (int fromTid, int toTid) {},
		sendAskUserQuestionPrompt: (int tid, JSONFragment questions,
			string toolUseId) {},
		clearAskUserQuestionPrompt: (int tid) {},
		sendPermissionPrompt: (int tid, const PendingPermission pending) {},
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
	import std.algorithm.searching : canFind;
	import std.exception : assertThrown;
	import cydo.domain.task_types.definition : SingletonAudience;

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

	alias QuestionState = WorkflowToolsBackend.QuestionState;

	final class BatchInvariantFixture
	{
		TaskData[int] tasks;
		TaskTypeDef[] taskTypes;
		SingletonDef[] singletons;
		size_t singletonForTaskCalls;
		int persistAddDependencyCalls;
		int persistRemoveDependencyCalls;
		int[] removedChildren;
		int waitingToActiveTransitions;
		int nextTid = 3;
		size_t sendCalls;
		int[] sentTids;
		int[] acceptedPreparedTids;
		int[] releasedTids;
		bool failEnsure;
		bool shuttingDown;
		int integratorTid;
		size_t wakeCalls;
		int[2][] focusHints;
		Promise!void wakeGate;
		Promise!void preparedSendGate;
		string[] sentBodies;
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
				singletonsForProject: (string projectPath) => singletons,
				promptSearchPath: (string projectPath) => cast(string[]) null,
				treeReadOnlyForProject: (string projectPath) => cast(bool[string]) null,
				resolveTaskAgent: (DjinjaTemplate requestedAgent, string parentAgent, string workspace) => "fake",
				isConfiguredAgentName: (string agentName) => agentName == "fake",
				taskSystemPromptForMessage: (int tid, TaskTypeDef* typeDef) => "",
				tasksShareWorkspace: (int aTid, int bTid) => true,
				taskWorkspaceLabel: (int tid) => "local",
				systemKeyword: () => "SYSTEM",
				readPromptFile: (string relativePath, string projectPath,
					string[string] vars) => vars[relativePath == "prompts/sub_task_waiting_for_answer.md"
						? "question" : "message"],
				buildKnownSystemMessageMeta: (KnownSystemMessageKind kind,
					string subject, string[string] vars,
					string bodyVar) => "{}",
				taskDir: (const TaskData* task) => "",
				outputPath: (const TaskData* task) => "",
				worktreePath: (const TaskData* task) => "",
				taskProducesCommitOutput: (string projectPath, string taskType) => false,
				setupWorktreeForEdge: (int childTid, int parentTid,
					WorktreeMode mode) {},
				shuttingDown: () => shuttingDown,
				effectiveCwd: (const TaskData* task) => task.projectPath,
				singletonForTask: (int tid, string name) {
					singletonForTaskCalls++;
					assert(tid == 1 && name == "integrator");
					return resolve(integratorTid);
				},
				ensureProcessQueueAlive: (int tid) {
					wakeCalls++;
					if (failEnsure)
						return reject!void(new Exception("wake failed"));
					if (wakeGate !is null) return wakeGate;
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
				broadcastFocusHint: (int fromTid, int toTid) {
					focusHints ~= [fromTid, toTid];
				},

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
				broadcastTaskUpdate: (int tid) {
					if (!tasks[tid].isProcessing)
						releasedTids ~= tid;
				},
				broadcastTaskCreated: (TaskCreatedMessage message) {},
				sendKnownSystemMessage: (int tid, KnownSystemMessageKind kind,
					string body) { return resolve(); },
				sendPreparedKnownSystemMessage: (int tid,
					const(ContentBlock)[] blocks, string cydoMeta, string nonce) {
					sendCalls++;
					sentTids ~= tid;
					foreach (block; blocks) sentBodies ~= block.text;
					return (preparedSendGate is null ? resolve() : preparedSendGate).then(() {
						acceptedPreparedTids ~= tid;
					});
				},
				sendAskUserQuestionPrompt: (int tid, JSONFragment questions,
					string toolUseId) {},
				clearAskUserQuestionPrompt: (int tid) {},
				sendPermissionPrompt: (int tid, const PendingPermission pending) {},
				clearPermissionPrompt: (int tid) {},
				appendTaskSpawnedEvent: (int parentTid, int childTid,
					int specIndex) {},
				permissionSettings: (string agentName, string workspaceName) => PermissionSettings.init,
				onNextTick: (void delegate() cb) { onNextTick(socketManager, cb); },
				generateTitle: (int tid, string prompt) {},
			));
		}
	}

	// Request releases the asker at Answer while the integrator's turn continues.
	foreach (status; [TaskStatus.active, TaskStatus.waiting])
	{
		auto f = new BatchInvariantFixture;
		f.singletons = [SingletonDef("integrator", "child", "", "", SingletonAudience.all)];
		f.integratorTid = 2;
		f.tasks[2].parentTid = 0;
		f.tasks[2].isProcessing = true;
		auto b = f.makeBackend();
		McpResult requested, presented, delivered;
		b.handleRequest("1", "integrator", "land this").then((McpResult r) {
			requested = r;
		}).ignoreResult();
		drainPromiseNextTicks();
		assert(f.singletonForTaskCalls == 1);
		assert(f.tasks[1].status == TaskStatus.waiting && requested.text.length == 0);
		b.awaitEvent(2).then((McpResult r) { presented = r; }).ignoreResult();
		drainPromiseNextTicks();
		auto question = presented.text.jsonParse!QuestionResult;
		assert(question.message == "land this");
		f.tasks[2].status = status;
		b.handleAnswer("2", question.qid, "landed").then((McpResult r) {
			delivered = r;
		}).ignoreResult();
		drainPromiseNextTicks();

		assert(!requested.isError && requested.text.jsonParse!AnswerResult.message == "landed");
		assert(!delivered.isError && delivered.text.jsonParse!AnswerResult.status == "delivered");
		assert(f.focusHints[$ - 1] == [2, 1]);
		b.onToolCallDelivered("1", requested);
		assert(f.tasks[1].status == TaskStatus.active && b.questions_.length == 0);
		assert(f.tasks[2].status == status && f.tasks[2].isProcessing);
	}

	// Unknown and unoffered targets are rejected before starting a singleton.
	foreach (target; ["unknown", "reviewer"])
	{
		auto f = new BatchInvariantFixture;
		f.singletons = [
			SingletonDef("integrator", "child", "", "", SingletonAudience.all),
			SingletonDef("reviewer", "child"),
		];
		auto b = f.makeBackend();
		McpResult result;
		b.handleRequest("1", target, "review this").then((McpResult r) {
			result = r;
		}).ignoreResult();
		drainPromiseNextTicks();

		assert(result.isError);
		assert(result.text == "Singleton '" ~ target
			~ "' is unavailable. Valid targets: integrator");
		assert(f.singletonForTaskCalls == 0);
	}

	// Shutdown leaves held results available for a later delivery attempt.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[1].isProcessing = true;
		auto b = f.makeBackend();
		BatchHandle handle;
		string error;
		assert(b.batchRegistry_.create(1, [2], handle, error), error);
		f.tasks[2].resultText = "completed before shutdown";
		assert(b.finalizeCompletedSubTask(2));
		f.tasks[1].isProcessing = false;

		f.shuttingDown = true;
		assert(!b.pump(1));
		assert(f.wakeCalls == 0 && f.sendCalls == 0);
		assert(b.mailbox(1).events.length == 1 && b.batchRegistry_.exists(handle));

		f.shuttingDown = false;
		assert(b.pump(1));
		assert(f.wakeCalls == 1);
		f.shuttingDown = true;
		drainPromiseNextTicks();
		assert(!f.tasks[1].isProcessing && f.sendCalls == 0);
		assert(b.mailbox(1).events.length == 1 && b.batchRegistry_.exists(handle));

		f.shuttingDown = false;
		assert(b.pump(1));
		drainPromiseNextTicks();
		assert(f.wakeCalls == 2 && f.sendCalls == 1);
		assert(f.sentBodies[0].canFind("completed before shutdown"));
		assert(b.mailbox(1).empty && !b.batchRegistry_.exists(handle));
	}

	// Shutdown after submission starts preserves the drained FIFO on rejection.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[2].status = TaskStatus.completed;
		f.tasks[2].isProcessing = true;
		f.tasks[3] = TaskData(3, "local", "/tmp/cydo-batch-invariants");
		f.tasks[3].status = TaskStatus.active;
		f.tasks[4] = TaskData(4, "local", "/tmp/cydo-batch-invariants");
		f.tasks[4].status = TaskStatus.active;
		f.preparedSendGate = new Promise!void;
		auto b = f.makeBackend();
		BatchHandle handle;
		string error;
		bool firstResolved, secondResolved;
		b.handleAsk("1", "first held question", 2).then((McpResult r) {
			firstResolved = true;
		}).ignoreResult();
		assert(b.batchRegistry_.create(2, [4], handle, error), error);
		f.tasks[4].resultText = "held batch result";
		assert(b.finalizeCompletedSubTask(4));
		b.handleAsk("3", "second held question", 2).then((McpResult r) {
			secondResolved = true;
		}).ignoreResult();
		auto held = b.mailbox(2).events.dup;
		assert(held.length == 3);
		f.tasks[2].isProcessing = false;
		assert(b.pump(2));
		drainPromiseNextTicks();
		assert(b.mailbox(2).empty && f.sentTids == [2]);

		f.shuttingDown = true;
		f.preparedSendGate.reject(new Exception("shutdown during submission"));
		drainPromiseNextTicks();
		assert(f.acceptedPreparedTids.length == 0);
		assert(!f.tasks[2].isProcessing && f.tasks[2].status == TaskStatus.completed);
		assert(!firstResolved && !secondResolved);
		assert(b.questions_.length == 2 && b.batchRegistry_.exists(handle));
		assert(b.mailbox(2).events == held);

		f.shuttingDown = false;
		f.preparedSendGate = null;
		assert(b.pump(2));
		drainPromiseNextTicks();
		assert(f.acceptedPreparedTids == [2] && f.sentBodies.length == 6);
		assert(f.sentBodies[3 .. $] == f.sentBodies[0 .. 3]);
		assert(f.sentBodies[3].canFind("first held question"));
		assert(f.sentBodies[4].canFind("held batch result"));
		assert(f.sentBodies[5].canFind("second held question"));
		assert(!firstResolved && !secondResolved);
		assert(b.mailbox(2).empty && !b.batchRegistry_.exists(handle));
		assert(!b.pump(2));
	}

	// A partial mixed batch emits no hint. Reject the first delivery
	// attempt and verify the retry emits exactly one hint per child.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[3] = TaskData(3, "local", "/tmp/cydo-batch-invariants");
		f.tasks[3].status = TaskStatus.active;
		f.tasks[1].isProcessing = true;
		auto b = f.makeBackend();
		McpResult outcome, retry;
		b.registerBatchAndAwait("1", [LaunchedTask(2), LaunchedTask(3)]).then((McpResult r) {
			outcome = r;
		}).ignoreResult();
		assert(b.finalizeCompletedSubTask(2));
		drainPromiseNextTicks();
		assert(f.focusHints.length == 0 && outcome.settleDelivery is null);
		f.tasks[3].status = TaskStatus.failed;
		assert(b.recordChildTerminal(3));
		drainPromiseNextTicks();
		assert(outcome.isError && f.focusHints.length == 0);
		b.onMcpDeliveryFailed("1", outcome);
		assert(f.focusHints.length == 0);
		b.awaitEvent(1).then((McpResult r) { retry = r; }).ignoreResult();
		drainPromiseNextTicks();
		assert(outcome.text == retry.text);
		b.onToolCallDelivered("1", retry);
		assert(f.focusHints == [[2, 1], [3, 1]]);
	}

	// The parent can become terminal between sending the failure result
	// and running the deferred delivery callback.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[2].isProcessing = true;
		auto b = f.makeBackend();
		McpResult outcome;
		b.handleAsk("1", "question", 2).then((McpResult r) {
			outcome = r;
		}).ignoreResult();
		drainPromiseNextTicks();
		f.tasks[2].status = TaskStatus.failed;
		b.onTaskTerminal(2);
		drainPromiseNextTicks();
		assert(outcome.isError && outcome.settleDelivery !is null);
		f.tasks[1].status = TaskStatus.completed;
		b.onTaskTerminal(1);
		b.onToolCallDelivered("1", outcome);
		assert(f.focusHints == [[1, 2], [2, 1]],
			"Accepted failed Ask loses return hint if its asker ends before settlement");
	}

	// Settling a completed or failed batch emits one hint, even if the
	// runner tries to record the same terminal child before delivery.
	foreach (failed; [false, true])
	{
		auto f = new BatchInvariantFixture;
		auto b = f.makeBackend();
		McpResult outcome;
		b.registerBatchAndAwait("1", [LaunchedTask(2)]).then((McpResult r) {
			outcome = r;
		}).ignoreResult();
		if (failed)
		{
			f.tasks[2].status = TaskStatus.failed;
			assert(b.recordChildTerminal(2));
		}
		else
			assert(b.finalizeCompletedSubTask(2));
		assert(b.recordChildTerminal(2));
		drainPromiseNextTicks();
		assert(f.focusHints.length == 0 && outcome.isError == failed);
		b.onToolCallDelivered("1", outcome);
		assert(f.focusHints == [[2, 1]]);
	}

	// Both outcomes return focus exactly once across turn end and the
	// production session-exit callback, after the original batch is gone.
	foreach (answer; [true, false])
	{
		import std.algorithm : filter;
		import std.range : array;
		import cydo.workflow.sessions.task_runner : TaskSessionRunnerHost, finishFollowUpSession;

		auto f = new BatchInvariantFixture;
		f.tasks[2].relationType = "subtask";
		auto b = f.makeBackend();
		McpResult batchResult, askResult, answerResult;
		b.registerBatchAndAwait("1", [LaunchedTask(2)]).then((McpResult r) {
			batchResult = r;
		}).ignoreResult();
		assert(b.finalizeCompletedSubTask(2));
		drainPromiseNextTicks();
		assert(!batchResult.isError
			&& batchResult.text.jsonParse!BatchResultEnvelope.tasks.length == 1);
		b.onToolCallDelivered("1", batchResult);
		assert(!b.hasLiveBatchOwner(2) && !b.hasTaskDependency(2));

		auto firstFollowUpHint = f.focusHints.length;
		b.handleAsk("1", "follow up", 2).then((McpResult r) {
			askResult = r;
		}).ignoreResult();
		drainPromiseNextTicks();
		auto qid = b.presentedQuestionFor(2);
		assert(qid > 0);
		assert(f.sentBodies.length == 1 && f.sentBodies[0].canFind(followUpFromParentSubject(qid)));
		assert(f.tasks[2].isProcessing && askResult.text.length == 0);
		f.tasks[2].status = TaskStatus.active;
		if (answer)
		{
			b.handleAnswer("2", qid, "follow-up answer").then((McpResult r) {
				answerResult = r;
			}).ignoreResult();
			drainPromiseNextTicks();
			assert(!askResult.isError && askResult.text.jsonParse!AnswerResult.message == "follow-up answer");
			assert(!answerResult.isError && answerResult.text.jsonParse!AnswerResult.status == "delivered");
			assert(f.focusHints[firstFollowUpHint .. $].filter!(hint => hint == [2, 1]).array == [[2, 1]]);
		}
		assert(f.tasks[2].status == TaskStatus.active && f.tasks[2].isProcessing);

		finishFollowUpSession((2 in f.tasks), TaskSessionRunnerHost(
			getTask: (int tid) => tid in f.tasks,
			hasLiveBatchOwner: &b.hasLiveBatchOwner,
			hasTaskDependency: &b.hasTaskDependency,
			hasPendingChildQuestion: &b.hasPendingChildQuestion,
			parentTaskForChild: &b.parentTaskForChild,
			recordChildTerminal: &b.recordChildTerminal,
			deliverWaitingParentResultsIfReady: &b.deliverWaitingParentResultsIfReady,
			transitionTaskFrom: (int tid, TaskStatus[] from, TaskStatus to,
				TaskNotificationChange notification) {
				b.host_.transitionTaskFrom(tid, from, to, notification);
				b.onTaskTerminal(tid);
			},
		));
		drainPromiseNextTicks();
		if (!answer)
			b.onToolCallDelivered("1", askResult);
		assert(f.focusHints[firstFollowUpHint .. $].filter!(hint => hint == [2, 1]).array == [[2, 1]]);
		if (!answer)
			assert(askResult.isError
				&& askResult.text.canFind("Session ended while waiting for Ask response"));
	}

	// Restart recovery finds a persisted dependency without a live batch.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[1].status = TaskStatus.waiting;
		f.tasks[2].status = TaskStatus.completed;
		auto b = f.makeBackend();
		b.taskDeps_[2] = 1;
		b.deliverWaitingParentResultsIfReady(2).ignoreResult();
		drainPromiseNextTicks();
		assert(f.focusHints == [[2, 1]]);
		assert(!b.hasTaskDependency(2));
	}

	// A grandchild question reaches the grandparent's Task carrier.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[3] = TaskData(3, "local", "/tmp/cydo-batch-invariants");
		f.tasks[3].parentTid = 2;
		f.tasks[3].status = TaskStatus.active;
		auto b = f.makeBackend();
		bool grandparentDone, parentDone, askDone, answerDone;
		McpResult grandparentResult, parentResult, askResult, answerResult;
		b.registerBatchAndAwait("1", [LaunchedTask(2)]).then((McpResult r) {
			grandparentDone = true; grandparentResult = r;
		}).ignoreResult();
		b.registerBatchAndAwait("2", [LaunchedTask(3)]).then((McpResult r) {
			parentDone = true; parentResult = r;
		}).ignoreResult();
		b.handleAsk("3", "skip-level question", 1).then((McpResult r) {
			askDone = true; askResult = r;
		}).ignoreResult();
		drainPromiseNextTicks();
		assert(grandparentDone && !parentDone && !askDone);
		auto q = grandparentResult.text.jsonParse!QuestionResult;
		assert(q.tid == 3 && q.qid > 0);
		b.handleAnswer("1", q.qid, "reply").then((McpResult r) {
			answerDone = true; answerResult = r;
		}).ignoreResult();
		drainPromiseNextTicks();
		assert(askDone && !answerDone);
		assert(askResult.text.jsonParse!AnswerResult.qid == q.qid);
		f.tasks[3].resultText = "grandchild done";
		assert(b.finalizeCompletedSubTask(3));
		drainPromiseNextTicks();
		assert(parentDone && !answerDone);
		assert(parentResult.text.jsonParse!BatchResultEnvelope.tasks[0]
			.json.jsonParse!TaskResult.tid == 3);
		f.tasks[2].resultText = "child done";
		assert(b.finalizeCompletedSubTask(2));
		drainPromiseNextTicks();
		assert(answerDone);
		assert(answerResult.text.jsonParse!BatchResultEnvelope.tasks[0]
			.json.jsonParse!TaskResult.tid == 2);
	}

	// A presented question is cancelled when its asker ends.
	{
		auto f = new BatchInvariantFixture;
		auto b = f.makeBackend();
		McpResult askResult, presented, late;
		b.awaitEvent(2).then((McpResult r) { presented = r; }).ignoreResult();
		b.handleAsk("1", "question", 2).then((McpResult r) {
			askResult = r;
		}).ignoreResult();
		drainPromiseNextTicks();
		assert(presented.text.length > 0);
		b.onTaskTerminal(1);
		drainPromiseNextTicks();
		assert(askResult.isError);
		b.handleAnswer("2", presented.text.jsonParse!QuestionResult.qid,
			"late").then((McpResult r) { late = r; }).ignoreResult();
		drainPromiseNextTicks();
		assert(late.isError && late.text.canFind("cancelled"));
	}

	// Held question and batch events remain FIFO across carrier calls.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[3] = TaskData(3, "local", "/tmp/cydo-batch-invariants");
		f.tasks[3].status = TaskStatus.active;
		f.tasks[1].isProcessing = true;
		auto b = f.makeBackend();
		b.handleAsk("3", "first", 1).ignoreResult();
		BatchHandle handle;
		string error;
		assert(b.batchRegistry_.create(1, [2], handle, error));
		f.tasks[2].resultText = "done";
		assert(b.finalizeCompletedSubTask(2));
		McpResult first, second;
		b.awaitEvent(1).then((McpResult r) { first = r; }).ignoreResult();
		b.awaitEvent(1).then((McpResult r) { second = r; }).ignoreResult();
		drainPromiseNextTicks();
		assert(first.text.jsonParse!QuestionResult.status == "question");
		assert(second.text.jsonParse!BatchResultEnvelope.tasks.length == 1);
	}

	// Answer acknowledges immediately without an obligation and carries while
	// the answerer still owns a batch.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[1].isProcessing = true;
		f.tasks[2].isProcessing = true;
		auto b = f.makeBackend();
		b.handleAsk("1", "direct", 2).ignoreResult();
		McpResult presented, delivered;
		b.awaitEvent(2).then((McpResult r) { presented = r; }).ignoreResult();
		drainPromiseNextTicks();
		auto qid = presented.text.jsonParse!QuestionResult.qid;
		b.handleAnswer("2", qid, "reply").then((McpResult r) {
			delivered = r;
		}).ignoreResult();
		drainPromiseNextTicks();
		assert(delivered.text.jsonParse!AnswerResult.status == "delivered");
		assert(delivered.text.jsonParse!AnswerResult.qid == qid);
	}
	{
		auto f = new BatchInvariantFixture;
		f.tasks[3] = TaskData(3, "local", "/tmp/cydo-batch-invariants");
		f.tasks[3].status = TaskStatus.active;
		f.tasks[1].isProcessing = true;
		f.tasks[2].isProcessing = true;
		auto b = f.makeBackend();
		BatchHandle handle;
		string error;
		assert(b.batchRegistry_.create(2, [3], handle, error));
		b.handleAsk("1", "blocked", 2).ignoreResult();
		McpResult presented, answerResult;
		bool answerDone;
		b.awaitEvent(2).then((McpResult r) { presented = r; }).ignoreResult();
		drainPromiseNextTicks();
		b.handleAnswer("2", presented.text.jsonParse!QuestionResult.qid,
			"reply").then((McpResult r) {
			answerDone = true; answerResult = r;
		}).ignoreResult();
		drainPromiseNextTicks();
		assert(!answerDone);
		f.tasks[3].resultText = "done";
		assert(b.finalizeCompletedSubTask(3));
		drainPromiseNextTicks();
		assert(answerDone && answerResult.text.jsonParse!BatchResultEnvelope.tasks.length == 1);
	}

	// A busy answerer can answer only after the idle pump delivers the question.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[1].isProcessing = true;
		f.tasks[2].isProcessing = true;
		auto b = f.makeBackend();
		auto qid = b.nextQid_;
		McpResult askResult, earlyAnswer, answerResult;
		b.handleAsk("1", "held question", 2).then((McpResult r) {
			askResult = r;
		}).ignoreResult();
		b.handleAnswer("2", qid, "early").then((McpResult r) {
			earlyAnswer = r;
		}).ignoreResult();
		drainPromiseNextTicks();
		assert(earlyAnswer.isError && earlyAnswer.text.canFind("Unknown question ID"));
		assert(askResult.text.length == 0 && f.sendCalls == 0);

		f.tasks[2].isProcessing = false;
		assert(b.pump(2));
		drainPromiseNextTicks();
		f.tasks[2].isProcessing = false;
		assert(!b.pump(2));
		drainPromiseNextTicks();
		assert(f.sentTids == [2] && f.sentBodies.length == 1);
		assert(f.sentBodies[0].canFind("held question"));

		b.handleAnswer("2", qid, "reply").then((McpResult r) {
			answerResult = r;
		}).ignoreResult();
		drainPromiseNextTicks();
		assert(!answerResult.isError);
		assert(answerResult.text.jsonParse!AnswerResult.status == "delivered");
		assert(askResult.text.jsonParse!AnswerResult.qid == qid);
	}

	// Idle pump sends held question and batch in one accepted message.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[3] = TaskData(3, "local", "/tmp/cydo-batch-invariants");
		f.tasks[3].status = TaskStatus.active;
		f.tasks[1].isProcessing = true;
		auto b = f.makeBackend();
		b.handleAsk("3", "held question", 1).ignoreResult();
		BatchHandle handle;
		string error;
		assert(b.batchRegistry_.create(1, [2], handle, error));
		f.tasks[2].resultText = "held result";
		assert(b.finalizeCompletedSubTask(2));
		assert(f.sendCalls == 0);
		f.tasks[1].isProcessing = false;
		f.tasks[1].hasPendingQuestion = true;
		assert(!b.pump(1));
		f.tasks[1].hasPendingQuestion = false;
		assert(b.pump(1));
		drainPromiseNextTicks();
		assert(f.sendCalls == 1 && f.sentBodies.length == 2);
		assert(f.sentBodies[0].canFind("held question"));
		assert(f.sentBodies[1].canFind("held result"));
	}

	// A question from the parent counts once presented, while a held
	// question does not become an idle reminder.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[3] = TaskData(3, "local", "/tmp/cydo-batch-invariants");
		f.tasks[3].status = TaskStatus.active;
		f.tasks[2].isProcessing = true;
		auto b = f.makeBackend();
		McpResult presented;
		b.handleAsk("1", "parent asks child", 2).ignoreResult();
		b.awaitEvent(2).then((McpResult r) { presented = r; }).ignoreResult();
		drainPromiseNextTicks();
		assert(presented.text.jsonParse!QuestionResult.status == "question");
		assert(b.hasPendingChildQuestion(2));
		b.handleAsk("3", "held question", 2).ignoreResult();
		drainPromiseNextTicks();
		assert(b.hasPendingChildQuestion(2));
		b.onTaskTerminal(1);
		assert(!b.hasPendingChildQuestion(2));
	}

	// The answerer's exit deletes a cancelled question without waking the
	// asker that already terminated.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[2].isProcessing = true;
		auto b = f.makeBackend();
		McpResult presented;
		b.awaitEvent(2).then((McpResult r) { presented = r; }).ignoreResult();
		b.handleAsk("1", "question", 2).ignoreResult();
		drainPromiseNextTicks();
		auto qid = presented.text.jsonParse!QuestionResult.qid;
		f.tasks[1].status = TaskStatus.failed;
		b.onTaskTerminal(1);
		assert((qid in b.questions_) !is null);
		assert(b.questions_[qid].state == QuestionState.cancelled);
		auto sendCalls = f.sendCalls;
		f.tasks[2].status = TaskStatus.failed;
		b.onTaskTerminal(2);
		drainPromiseNextTicks();
		assert((qid in b.questions_) is null);
		assert(b.mailbox(1).empty && !b.mailbox(1).hasWaiter);
		assert(f.sendCalls == sendCalls);
		assert(f.tasks[1].status == TaskStatus.failed);
	}

	// A question stays held during a terminal target's wake. If the asker
	// ends first, neither a successful nor a failed wake presents it.
	foreach (rejectWake; [false, true])
	{
		auto f = new BatchInvariantFixture;
		f.tasks[2].status = TaskStatus.completed;
		f.wakeGate = new Promise!void;
		auto b = f.makeBackend();
		b.handleAsk("1", "question during wake", 2).ignoreResult();
		assert(b.mailbox(2).events.length == 1);
		assert(f.tasks[2].isProcessing);
		assert(!b.pump(2));
		f.tasks[1].status = TaskStatus.failed;
		b.onTaskTerminal(1);
		assert(b.questions_.length == 0 && b.mailbox(2).empty);
		if (rejectWake)
			f.wakeGate.reject(new Exception("wake failed"));
		else
			f.wakeGate.fulfill();
		drainPromiseNextTicks();
		assert(!f.tasks[2].isProcessing);
		assert(f.sendCalls == 0 && b.mailbox(1).empty);
	}

	// A question cancelled after the wake but before send confirmation is
	// discarded when delivery fails, without failing it back to its asker.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[2].status = TaskStatus.completed;
		f.wakeGate = new Promise!void;
		f.preparedSendGate = new Promise!void;
		auto b = f.makeBackend();
		b.handleAsk("1", "question during send", 2).ignoreResult();
		f.wakeGate.fulfill();
		drainPromiseNextTicks();
		assert(f.sendCalls == 1 && b.mailbox(2).empty);
		f.tasks[1].status = TaskStatus.failed;
		b.onTaskTerminal(1);
		assert(b.questions_[1].state == QuestionState.cancelled);
		f.preparedSendGate.reject(new Exception("send failed"));
		drainPromiseNextTicks();
		assert(b.questions_.length == 0);
		assert(b.mailbox(1).empty && !b.mailbox(1).hasWaiter);
		assert(f.sentTids == [2]);
		assert(!f.tasks[2].isProcessing);
	}

	// A presented Ask can fail when the answerer's reminder is rejected.
	{
		import std.format : format;

		auto f = new BatchInvariantFixture;
		auto b = f.makeBackend();
		McpResult presented, failure;
		b.awaitEvent(1).then((McpResult r) { presented = r; }).ignoreResult();
		b.handleAsk("2", "question awaiting an answer", 1).then((McpResult r) {
			failure = r;
		}).ignoreResult();
		drainPromiseNextTicks();
		assert(!presented.isError && presented.text.jsonParse!QuestionResult.qid > 0);
		assert(b.hasPendingChildQuestion(1));
		assert(f.focusHints == [[2, 1]]);
		f.sendFailure = "injected answer-reminder rejection";
		b.sendPendingChildAnswerReminder(1);
		drainPromiseNextTicks();
		assert(failure.isError && failure.text.canFind("injected answer-reminder rejection"));
		assert(!b.hasPendingChildQuestion(1));
		b.onToolCallDelivered("2", failure);
		assert(f.focusHints == [[2, 1], [1, 2]],
			format!"reminder failure delivered to asker, focus hints were %s"(f.focusHints));
	}

	// A failed wake still returns one error to a live asker.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[2].status = TaskStatus.completed;
		f.wakeGate = new Promise!void;
		auto b = f.makeBackend();
		McpResult failed;
		b.handleAsk("1", "live question", 2).then((McpResult r) {
			failed = r;
		}).ignoreResult();
		f.wakeGate.reject(new Exception("wake failed"));
		drainPromiseNextTicks();
		assert(failed.isError && failed.text.canFind("wake failed"));
		b.onToolCallDelivered("1", failed);
		assert(b.questions_.length == 0 && b.mailbox(1).empty);
	}

	// A task that ends during startup releases its wake once and keeps its batch.
	foreach (terminalStatus; [TaskStatus.failed, TaskStatus.completed])
	{
		auto f = new BatchInvariantFixture;
		f.tasks[3] = TaskData(3, "local", "/tmp/cydo-batch-invariants");
		f.tasks[3].status = TaskStatus.active;
		f.tasks[4] = TaskData(4, "local", "/tmp/cydo-batch-invariants");
		f.tasks[4].status = TaskStatus.active;
		f.tasks[2].isProcessing = true;
		f.wakeGate = new Promise!void;
		auto b = f.makeBackend();
		BatchHandle handle;
		string error;
		assert(b.batchRegistry_.create(2, [4], handle, error));
		f.tasks[4].resultText = "batch result";
		assert(b.finalizeCompletedSubTask(4));
		f.tasks[2].isProcessing = false;

		McpResult[] first, second;
		b.handleAsk("1", "question during startup", 2).then((McpResult r) {
			first ~= r;
		}).ignoreResult();
		drainPromiseNextTicks();
		assert(f.tasks[2].isProcessing && f.sendCalls == 0);

		f.tasks[2].status = terminalStatus;
		b.onTaskTerminal(2);
		f.wakeGate.reject(new Exception("startup failed"));
		drainPromiseNextTicks();
		assert(first.length == 1 && first[0].isError
			&& first[0].text.canFind("Session ended"));
		assert(!f.tasks[2].isProcessing, "Failed wake left the answerer processing");
		assert(f.releasedTids == [2], "Failed wake must publish the release once");
		assert(b.mailbox(2).events.length == 1);
		assert(b.mailbox(2).events[0].kind == MailboxEvent.Kind.batch);
		assert(b.mailbox(2).events[0].batchId == handle.batchId);

		f.failEnsure = true;
		b.handleAsk("3", "question after startup failure", 2).then((McpResult r) {
			second ~= r;
		}).ignoreResult();
		drainPromiseNextTicks();
		assert(second.length == 1 && second[0].isError
			&& second[0].text.canFind("wake failed"));
		assert(f.sendCalls == 0);
		b.onToolCallDelivered("1", first[0]);
		b.onToolCallDelivered("3", second[0]);
		assert(b.questions_.length == 0);
		assert(b.mailbox(1).empty && !b.mailbox(1).hasWaiter);
		assert(b.mailbox(3).empty && !b.mailbox(3).hasWaiter);
		assert(b.mailbox(2).events.length == 1 && !b.mailbox(2).hasWaiter);
		assert(b.mailbox(2).events[0].kind == MailboxEvent.Kind.batch);
		assert(b.mailbox(2).events[0].batchId == handle.batchId);
	}

	// A target ending during send fails the drained asks and puts back the batch once.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[3] = TaskData(3, "local", "/tmp/cydo-batch-invariants");
		f.tasks[3].status = TaskStatus.active;
		f.tasks[4] = TaskData(4, "local", "/tmp/cydo-batch-invariants");
		f.tasks[4].status = TaskStatus.active;
		f.tasks[2].status = TaskStatus.completed;
		f.tasks[2].isProcessing = true;
		f.wakeGate = new Promise!void;
		f.preparedSendGate = new Promise!void;
		auto b = f.makeBackend();
		BatchHandle handle;
		string error;
		assert(b.batchRegistry_.create(2, [4], handle, error));
		f.tasks[4].resultText = "batch result";
		assert(b.finalizeCompletedSubTask(4));
		f.tasks[2].isProcessing = false;

		McpResult[] first, second;
		b.handleAsk("1", "first drained question", 2).then((McpResult r) {
			first ~= r;
		}).ignoreResult();
		b.handleAsk("3", "second drained question", 2).then((McpResult r) {
			second ~= r;
		}).ignoreResult();
		f.tasks[2].status = TaskStatus.active;
		f.wakeGate.fulfill();
		drainPromiseNextTicks();
		assert(f.sentTids == [2] && f.sentBodies.length == 3);
		assert(b.mailbox(2).empty);
		assert(first.length == 0 && second.length == 0);

		f.tasks[2].status = TaskStatus.failed;
		b.onTaskTerminal(2);
		f.preparedSendGate.reject(new Exception("send failed"));
		drainPromiseNextTicks();
		assert(first.length == 1 && first[0].isError
			&& first[0].text.canFind("Session ended"));
		assert(second.length == 1 && second[0].isError
			&& second[0].text.canFind("Session ended"));
		b.onToolCallDelivered("1", first[0]);
		b.onToolCallDelivered("3", second[0]);
		assert(b.questions_.length == 0);
		assert(b.mailbox(1).empty && !b.mailbox(1).hasWaiter);
		assert(b.mailbox(3).empty && !b.mailbox(3).hasWaiter);
		assert(b.mailbox(2).events.length == 1);
		assert(b.mailbox(2).events[0].kind == MailboxEvent.Kind.batch);
		assert(b.mailbox(2).events[0].batchId == handle.batchId);
	}

	// Terminal answerer fails both presented and still-held questions.
	{
		auto f = new BatchInvariantFixture;
		foreach (tid; [3, 4])
		{
			f.tasks[tid] = TaskData(tid, "local", "/tmp/cydo-batch-invariants");
			f.tasks[tid].status = TaskStatus.active;
			f.tasks[tid].isProcessing = true;
		}
		f.tasks[2].isProcessing = true;
		auto b = f.makeBackend();
		McpResult first, second, presented;
		b.handleAsk("3", "first", 2).then((McpResult r) { first = r; }).ignoreResult();
		b.awaitEvent(2).then((McpResult r) { presented = r; }).ignoreResult();
		b.handleAsk("4", "second", 2).then((McpResult r) { second = r; }).ignoreResult();
		drainPromiseNextTicks();
		assert(presented.text.jsonParse!QuestionResult.message == "first");
		b.onTaskTerminal(2);
		drainPromiseNextTicks();
		assert(first.isError && second.isError);
		assert(first.text.canFind("Question 1") && second.text.canFind("Question 2"));
		b.onToolCallDelivered("3", first);
		b.onToolCallDelivered("4", second);
		assert(b.questions_.length == 0);
	}

	// A rejected MCP result remains first when a later question arrives.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[1].isProcessing = true;
		f.tasks[3] = TaskData(3, "local", "/tmp/cydo-batch-invariants");
		f.tasks[3].status = TaskStatus.active;
		auto b = f.makeBackend();
		BatchHandle handle;
		string error;
		assert(b.batchRegistry_.create(1, [2], handle, error), error);
		f.tasks[2].resultText = "older batch";
		assert(b.finalizeCompletedSubTask(2));
		auto older = b.mailbox(1).events[0];
		McpResult first;
		b.awaitEvent(1).then((McpResult r) { first = r; }).ignoreResult();
		drainPromiseNextTicks();
		assert(first.text.canFind("older batch") && b.mailbox(1).empty);
		b.handleAsk("3", "newer question", 1).ignoreResult();
		auto newer = b.mailbox(1).events[0];
		assert(newer.kind == MailboxEvent.Kind.question);
		f.shuttingDown = true;
		b.onMcpDeliveryFailed("1", first);
		assert(b.mailbox(1).events == [older, newer],
			"Rejected MCP delivery reordered FIFO: " ~
			format!"expected %s then %s, got %s"(older, newer, b.mailbox(1).events));
	}

	// A transport failure must not requeue an already confirmed question.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[2].isProcessing = true;
		f.tasks[3] = TaskData(3, "local", "/tmp/cydo-batch-invariants");
		f.tasks[3].status = TaskStatus.active;
		auto b = f.makeBackend();
		b.handleAsk("1", "already presented", 2).ignoreResult();
		McpResult result;
		auto first = b.mailbox(2).events[0];
		b.awaitEvent(2).then((McpResult r) { result = r; }).ignoreResult();
		drainPromiseNextTicks();
		b.onToolCallDelivered("2", result);
		assert(b.presentedQuestionFor(2) == first.qid);
		b.handleAsk("3", "current carrier", 2).ignoreResult();
		auto second = b.mailbox(2).events[0];
		b.awaitEvent(2).then((McpResult r) { result = r; }).ignoreResult();
		drainPromiseNextTicks();
		f.shuttingDown = true;
		b.onMcpDeliveryFailed("2", result);
		assert(b.mailbox(2).events == [second],
			format!"MCP rejection replayed a confirmed question: %s"(b.mailbox(2).events));
	}

	// A rejected prepared delivery must not replay an accepted question.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[3] = TaskData(3, "local", "/tmp/cydo-batch-invariants");
		f.tasks[3].status = TaskStatus.active;
		auto b = f.makeBackend();
		b.handleAsk("1", "accepted question", 2).ignoreResult();
		drainPromiseNextTicks();
		assert(f.acceptedPreparedTids == [2] && b.mailbox(2).empty);
		auto acceptedQid = b.presentedQuestionFor(2);
		assert(acceptedQid > 0);
		f.tasks[2].isProcessing = false;
		f.preparedSendGate = new Promise!void;
		b.handleAsk("3", "rejected question", 2).ignoreResult();
		auto expected = b.mailbox(2).events.dup;
		assert(expected.length == 1 && expected[0].qid != acceptedQid);
		drainPromiseNextTicks();
		assert(b.mailbox(2).empty && f.sentTids == [2, 2]);
		f.shuttingDown = true;
		f.preparedSendGate.reject(new Exception("shutdown during submission"));
		drainPromiseNextTicks();
		assert(b.mailbox(2).events == expected,
			format!"Prepared rejection replayed a confirmed question: %s"(b.mailbox(2).events));
	}

	// An unconfirmed batch is put back after MCP transport failure.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[1].isProcessing = true;
		auto b = f.makeBackend();
		BatchHandle handle;
		string error;
		assert(b.batchRegistry_.create(1, [2], handle, error));
		f.tasks[2].resultText = "result";
		assert(b.finalizeCompletedSubTask(2));
		McpResult first, second;
		b.awaitEvent(1).then((McpResult r) { first = r; }).ignoreResult();
		drainPromiseNextTicks();
		f.shuttingDown = true;
		b.onMcpDeliveryFailed("1", first);
		assert(b.mailbox(1).events.length == 1 && f.wakeCalls == 0);
		f.shuttingDown = false;
		b.awaitEvent(1).then((McpResult r) { second = r; }).ignoreResult();
		drainPromiseNextTicks();
		assert(first.text == second.text && b.mailbox(1).empty);
		b.onToolCallDelivered("1", second);
		assert(!b.batchRegistry_.hasBatches(1));
	}

	// Each in-flight carrier settles only the batch it returned.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[1].isProcessing = true;
		f.tasks[3] = TaskData(3, "local", "/tmp/cydo-batch-invariants");
		f.tasks[3].status = TaskStatus.active;
		auto b = f.makeBackend();
		BatchHandle firstBatch, secondBatch;
		string error;
		assert(b.batchRegistry_.create(1, [2], firstBatch, error), error);
		assert(b.batchRegistry_.create(1, [3], secondBatch, error), error);
		f.tasks[2].resultText = "first batch result";
		f.tasks[3].resultText = "second batch result";
		assert(b.finalizeCompletedSubTask(2));
		assert(b.finalizeCompletedSubTask(3));

		McpResult first, second, retry;
		b.awaitEvent(1).then((McpResult r) { first = r; }).ignoreResult();
		b.awaitEvent(1).then((McpResult r) { second = r; }).ignoreResult();
		drainPromiseNextTicks();
		assert(first.text.canFind("first batch result"));
		assert(second.text.canFind("second batch result"));
		assert(b.mailbox(1).empty);

		b.onToolCallDelivered("1", first);
		assert(!b.batchRegistry_.exists(firstBatch));
		assert(b.batchRegistry_.exists(secondBatch));
		f.shuttingDown = true;
		b.onMcpDeliveryFailed("1", second);
		f.shuttingDown = false;
		b.awaitEvent(1).then((McpResult r) { retry = r; }).ignoreResult();
		drainPromiseNextTicks();
		assert(retry.text == second.text);
		b.onToolCallDelivered("1", retry);
		assert(b.mailbox(1).empty && !b.batchRegistry_.exists(secondBatch));
	}

	// An error notice survives a rejected carrier result.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[2].isProcessing = true;
		auto b = f.makeBackend();
		McpResult first, retry;
		b.handleAsk("1", "question", 2).then((McpResult r) {
			first = r;
		}).ignoreResult();
		drainPromiseNextTicks();
		f.tasks[2].status = TaskStatus.failed;
		b.onTaskTerminal(2);
		drainPromiseNextTicks();
		assert(first.isError && first.text.canFind("Session ended"));

		f.shuttingDown = true;
		b.onMcpDeliveryFailed("1", first);
		f.shuttingDown = false;
		b.awaitEvent(1).then((McpResult r) { retry = r; }).ignoreResult();
		drainPromiseNextTicks();
		assert(retry.isError && retry.text == first.text);
		b.onToolCallDelivered("1", retry);
		assert(b.mailbox(1).empty);
	}

	// A rejected carrier does not requeue a question cancelled in flight.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[2].isProcessing = true;
		auto b = f.makeBackend();
		b.handleAsk("1", "question", 2).ignoreResult();
		McpResult question;
		b.awaitEvent(2).then((McpResult r) { question = r; }).ignoreResult();
		drainPromiseNextTicks();
		assert(question.text.jsonParse!QuestionResult.message == "question");
		assert(b.mailbox(2).empty);

		f.tasks[1].status = TaskStatus.failed;
		b.onTaskTerminal(1);
		f.shuttingDown = true;
		b.onMcpDeliveryFailed("2", question);
		assert(b.mailbox(2).empty);
	}

	// An answer held by a failing carrier is obsolete after its asker ends.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[1].isProcessing = true;
		auto b = f.makeBackend();
		b.questions_[1] = WorkflowToolsBackend.QuestionRecord(1, 1, 2, "asked", "answered", QuestionState.answered);
		b.mailbox(1).push(MailboxEvent(MailboxEvent.Kind.answer, 0, 1));
		McpResult result;
		b.awaitEvent(1).then((McpResult r) { result = r; }).ignoreResult();
		drainPromiseNextTicks();
		assert(result.text.canFind("answered") && b.mailbox(1).empty);
		f.shuttingDown = true;
		f.tasks[1].status = TaskStatus.failed;
		b.onTaskTerminal(1);
		assert(b.questions_.length == 0);
		b.onMcpDeliveryFailed("1", result);
		assert(b.mailbox(1).empty, "Put-back restored an answer with no owning record");
	}

	// An existing waiter receives an older event directly on put-back.
	{
		auto f = new BatchInvariantFixture;
		auto b = f.makeBackend();
		f.shuttingDown = true;
		b.questions_[1] = WorkflowToolsBackend.QuestionRecord(1, 1, 2, "older", null, QuestionState.failed);
		b.questions_[2] = WorkflowToolsBackend.QuestionRecord(2, 1, 2, "newer", null, QuestionState.failed);
		auto front = MailboxEvent(MailboxEvent.Kind.failed, 0, 1, "older");
		auto back = MailboxEvent(MailboxEvent.Kind.failed, 0, 2, "newer");
		McpResult result;
		b.awaitEvent(1).then((McpResult r) { result = r; }).ignoreResult();
		drainPromiseNextTicks();
		assert(b.mailbox(1).hasWaiter);
		b.deliveryAttempt(1, [front, back])(false);
		drainPromiseNextTicks();
		assert(result.text == "older", "Put-back did not wake an existing carrier");
		assert(!b.mailbox(1).hasWaiter && b.mailbox(1).events == [back]);
		b.onToolCallDelivered("1", result);
	}

	// A carrier result can be settled only once.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[2].isProcessing = true;
		auto b = f.makeBackend();
		b.handleAsk("1", "question", 2).ignoreResult();
		McpResult question;
		b.awaitEvent(2).then((McpResult r) { question = r; }).ignoreResult();
		drainPromiseNextTicks();
		assert(question.text.jsonParse!QuestionResult.message == "question");
		b.onToolCallDelivered("2", question);
		f.shuttingDown = true;
		assertThrown!AssertError(b.onMcpDeliveryFailed("2", question));
		assert(b.mailbox(2).empty);
	}

	// An exception during settlement still consumes the attempt.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[1].isProcessing = true;
		auto b = f.makeBackend();
		BatchHandle handle;
		string error;
		assert(b.batchRegistry_.create(1, [2], handle, error), error);
		f.tasks[2].resultText = "accepted batch";
		assert(b.finalizeCompletedSubTask(2));
		McpResult result;
		b.awaitEvent(1).then((McpResult r) { result = r; }).ignoreResult();
		drainPromiseNextTicks();
		b.host_.persistRemoveTaskDep = (int, int) {
			throw new Exception("dependency removal failed");
		};
		assertThrown!Exception(b.onToolCallDelivered("1", result));
		assertThrown!AssertError(b.onMcpDeliveryFailed("1", result));
		assert(b.mailbox(1).empty);
	}

	// A terminal target that cannot be re-woken fails the question back to
	// its asker while retaining other mailbox work.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[3] = TaskData(3, "local", "/tmp/cydo-batch-invariants");
		f.tasks[3].status = TaskStatus.active;
		f.tasks[3].isProcessing = true;
		f.tasks[1].status = TaskStatus.completed;
		f.tasks[1].isProcessing = true;
		f.failEnsure = true;
		auto b = f.makeBackend();
		McpResult askResult;
		b.handleAsk("3", "wake question", 1).then((McpResult r) {
			askResult = r;
		}).ignoreResult();
		BatchHandle handle;
		string error;
		assert(b.batchRegistry_.create(1, [2], handle, error));
		f.tasks[2].resultText = "batch result";
		assert(b.finalizeCompletedSubTask(2));
		f.tasks[1].isProcessing = false;
		assert(b.pump(1));
		drainPromiseNextTicks();
		assert(askResult.isError && askResult.text.canFind("wake failed"));
		b.onToolCallDelivered("3", askResult);
		assert(b.questions_.length == 0);
		assert(b.mailbox(1).events.length == 1);
		assert(b.mailbox(1).events[0].kind == MailboxEvent.Kind.batch);
		assert(!f.tasks[1].isProcessing);
	}
	void addThirdTask(BatchInvariantFixture f)
	{
		f.tasks[3] = TaskData(3, "local", f.tasks[1].projectPath);
		f.tasks[3].status = TaskStatus.active;
		f.tasks[3].isProcessing = true;
	}

	McpResult present(WorkflowToolsBackend b, int tid)
	{
		import std.conv : to;
		McpResult result;
		b.awaitEvent(tid).then((McpResult r) { result = r; }).ignoreResult();
		drainPromiseNextTicks();
		assert(!result.isError && result.text.length, "Expected a presented question");
		b.onToolCallDelivered(tid.to!string, result);
		return result;
	}

	void assertDelivered(WorkflowToolsBackend b, int qid)
	{
		McpResult result;
		b.handleAnswer("3", qid, "x").then((McpResult r) { result = r; }).ignoreResult();
		drainPromiseNextTicks();
		assert(!result.isError && result.text.length, "Answer remained blocked or returned an error");
		assert(result.text.jsonParse!AnswerResult.status == "delivered");
		assert(!b.mailbox(3).hasWaiter);
	}

	void liveAnswer()
	{
		auto f = new BatchInvariantFixture;
		addThirdTask(f);
		f.tasks[2].isProcessing = true;
		auto b = f.makeBackend();
		b.handleAsk("3", "outgoing", 2).ignoreResult();
		present(b, 2);
		f.tasks[3].status = TaskStatus.failed;
		b.onTaskTerminal(3);
		assert(b.questions_.length == 1 && b.questions_[1].state == QuestionState.cancelled);
		f.tasks[3].status = TaskStatus.active;
		f.tasks[3].isProcessing = true;
		b.handleAsk("1", "incoming", 3).ignoreResult();
		auto question = present(b, 3).text.jsonParse!QuestionResult;
		assertDelivered(b, question.qid);
	}

	void rejectedFailure(bool revive)
	{
		auto f = new BatchInvariantFixture;
		f.tasks[2].isProcessing = true;
		auto b = f.makeBackend();
		McpResult failure;
		b.handleAsk("1", "question", 2).then((McpResult r) { failure = r; }).ignoreResult();
		f.tasks[2].status = TaskStatus.failed;
		b.onTaskTerminal(2);
		drainPromiseNextTicks();
		assert(failure.isError && failure.text.canFind("Session ended"));
		f.tasks[1].status = TaskStatus.failed;
		b.onTaskTerminal(1);
		if (revive)
		{
			f.tasks[1].status = TaskStatus.active;
			f.tasks[1].isProcessing = true;
		}
		b.onMcpDeliveryFailed("1", failure);
		assert(b.mailbox(1).empty, "Rejected carrier restored the retired failure");
		drainPromiseNextTicks();
		assert(f.wakeCalls == 0 && f.sentTids.length == 0);
		assert(b.questions_.length == 0);
	}

	void heldFailure()
	{
		auto f = new BatchInvariantFixture;
		addThirdTask(f);
		f.tasks[1].isProcessing = true;
		auto b = f.makeBackend();
		BatchHandle handle;
		string error;
		assert(b.batchRegistry_.create(1, [2], handle, error), error);
		McpResult batch;
		b.handleAsk("1", "question", 3).then((McpResult r) { batch = r; }).ignoreResult();
		assert(b.finalizeCompletedSubTask(2));
		drainPromiseNextTicks();
		assert(batch.structuredContent && !batch.isError);
		b.onToolCallDelivered("1", batch);
		f.tasks[3].status = TaskStatus.failed;
		b.onTaskTerminal(3);
		assert(!b.mailbox(1).hasWaiter && b.mailbox(1).events.length == 1);
		assert(b.mailbox(1).events[0].kind == MailboxEvent.Kind.failed);
		f.tasks[1].status = TaskStatus.failed;
		f.tasks[1].isProcessing = false;
		b.onTaskTerminal(1);
		drainPromiseNextTicks();
		assert(b.mailbox(1).empty);
		assert(f.wakeCalls == 0 && f.sentTids.length == 0, "Failure woke the terminal asker");
		assert(b.questions_.length == 0);
	}

	void rejectedReminder(bool answered)
	{
		auto f = new BatchInvariantFixture;
		f.tasks[1].isProcessing = true;
		f.tasks[2].isProcessing = true;
		auto b = f.makeBackend();
		McpResult response;
		b.handleAsk("2", "question", -1).then((McpResult r) { response = r; }).ignoreResult();
		auto question = present(b, 1).text.jsonParse!QuestionResult;
		f.sendFailure = "reminder rejected";
		b.sendPendingChildAnswerReminder(1);
		assert(f.sendCalls == 1);
		if (answered)
			b.handleAnswer("1", question.qid, "actual answer").ignoreResult();
		else
		{
			f.tasks[2].status = TaskStatus.failed;
			f.tasks[2].isProcessing = false;
			b.onTaskTerminal(2);
		}
		drainPromiseNextTicks();
		if (answered)
		{
			assert(!response.isError && response.text.length);
			assert(response.text.jsonParse!AnswerResult.message == "actual answer");
			assert(b.mailbox(2).empty, "Reminder failure followed the answer");
			b.onToolCallDelivered("2", response);
		}
		else
		{
			assert(b.mailbox(2).empty);
			assert(f.wakeCalls == 0, "Reminder failure woke the terminal asker");
			McpResult late;
			b.handleAnswer("1", question.qid, "late").then((McpResult r) { late = r; }).ignoreResult();
			drainPromiseNextTicks();
			assert(late.isError && late.text.canFind("was cancelled"));
		}
	}

	liveAnswer();
	rejectedFailure(false);
	heldFailure();
	rejectedFailure(true);
	rejectedReminder(false);
	rejectedReminder(true);

}

// The CLI's safety checks flag a call: under the default policy a person
// confirms it in an interactive task, while one nobody watches is denied at
// once, saying why, instead of waiting out a prompt.
unittest
{
	import ae.net.asockets : socketManager;
	import std.algorithm.searching : canFind;

	TaskData[int] tasks;
	tasks[1] = TaskData(1, "local", "/tmp/project");
	tasks[1].taskType = "conversation";
	tasks[2] = TaskData(2, "local", "/tmp/project");
	tasks[2].taskType = "worker";

	TaskTypeDef conversation;
	conversation.name = "conversation";
	TaskTypeDef worker;
	worker.name = "worker";
	UserEntryPointDef entryPoint;
	entryPoint.name = "conversation";

	int[] prompted;
	string[string] promptVars;
	WorkflowToolsHost host;
	host.getTask = (int tid) => &tasks[tid];
	host.taskTypesForProject = (string projectPath) => [conversation, worker];
	host.entryPointsForProject = (string projectPath) => [entryPoint];
	host.permissionSettings = (string agentName, string workspaceName) => PermissionSettings.init;
	host.sendPermissionPrompt = (int tid, const PendingPermission pending) { prompted ~= tid; };
	host.persistNeedsAttention = (int tid, bool needsAttention) {};
	host.touchTask = (int tid) {};
	host.persistLastActive = (int tid, long lastActive) {};
	host.broadcastTaskUpdate = (int tid) {};
	host.readPromptFile = (string relativePath, string projectPath, string[string] vars) {
		assert(relativePath == "prompts/dangerous_call_denied.md");
		promptVars = vars;
		return "denied: " ~ vars["reason"];
	};
	auto backend = new WorkflowToolsBackend(host);

	auto prompt = PermissionPrompt("toolu_1", "Bash",
		JSONFragment(`{"command":"rm -rf /"}`), "Dangerous rm operation");
	string[int] decisions;
	foreach (tid; [1, 2])
		backend.decideToolPermission(tid, prompt, PermissionEscalation.safetyCheck)
			.then((string decision) { decisions[tid] = decision; });
	socketManager.loop();

	assert(prompted == [1]);
	assert((1 in decisions) is null);
	assert(decisions[2].canFind(`"behavior":"deny"`));
	assert(decisions[2].canFind("denied: Dangerous rm operation"));
	assert(promptVars["denial"] == "Permission denied by policy");
}
