module cydo.workflow.tools.backend;

import core.time : Duration;
import std.datetime.systime : Clock, SysTime;
import std.exception : enforce;
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
import cydo.domain.policy.permissions : PermissionDecision, PermissionEscalation, PermissionPrompt,
	PermissionSettings, ToolCallDecision, ToolCallRuling, evaluatePermissionPolicy,
	makePermissionAllowJson, makePermissionDenyJson;
import cydo.domain.task_types.definition : ContinuationDef, CreatableTaskDef, DjinjaTemplate, TaskTypeDef,
	UserEntryPointDef, SingletonDef, WorktreeMode, byName, creatableEntryPointsOf, isInteractive, singletonsOfferedTo,
	loadProjectMemory, renderContinuationPrompt, renderPrompt, resolveAgent,
	substituteVars;
import cydo.domain.storage.persistence : PersistedBatch, QuestionRecord, QuestionState;
import cydo.domain.tasks.model;
import cydo.domain.tasks.lifecycle : TaskNotificationChange;
import cydo.foundation.platform.path : canonicalProjectPath;
import cydo.foundation.system.known_messages : KnownSystemMessageKind,
	followUpFromParentSubject, handoffSubject, modeSwitchSubject,
	questionFromTaskSubject, subTaskWaitingForAnswerSubject,
	systemMessageSubject, taskPromptSubject, wrapKnownSystemMessage;
import cydo.foundation.system.framing : prependTaskFraming;
import cydo.foundation.text.ecmascript : trimEcmaScript;
import cydo.foundation.text.title : truncateTitle;
import cydo.mcp : McpResult, ToolCallCancellation;
import cydo.mcp.payloads : CreatedTaskResult, TaskResult;
import cydo.mcp.tools : AskQuestion, LaunchedTask, ToolsBackend,
	ValidatedTask;
import cydo.protocol : AnswerResult, BatchResultEnvelope, ContentBlock, QuestionResult, decomposeToolName;
import cydo.runtime.config : UnsandboxedCommandExecution;
import cydo.workflow.batch.registry : BatchHandle, BatchRegistry;
import cydo.workflow.mailbox : Mailbox, MailboxEvent;
import cydo.workflow.questions.router : makeQuestionMessage;
import cydo.workflow.tasks.subtask_delivery : SubtaskResultDelivery,
	SubtaskResultDeliveryHost, renderBatchResults;

import cydo.workflow.workspace.worktree_allocator : WorktreePreparationFailure;

package(cydo):

final class AgentSubmissionRejected : Exception
{
	this(Exception cause)
	{
		super(cause.msg, __FILE__, __LINE__, cause);
	}
}

struct UserTaskSpec
{
	string workspace;
	string projectPath;
	string entryPoint;
	string title;
	string draft;
	int creatorTid;
}

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
	string[] delegate(string projectPath) workspacesWithProject;
	int delegate(UserTaskSpec spec) createUserTask;
	Promise!void delegate(int tid, string prompt) startUserTask;
	SingletonDef[] delegate(string projectPath) singletonsForProject;
	string delegate(const TaskData* td) effectiveCwd;
	bool delegate(int aTid, int bTid) tasksShareWorkspace;
	string delegate(int tid) taskWorkspaceLabel;
	Promise!void delegate(int tid) reactivateTask;
	Promise!void delegate(int tid, KnownSystemMessageKind kind, string body)
		sendKnownSystemMessage;
	Promise!void delegate(int tid, const(ContentBlock)[] blocks,
		string cydoMeta, string nonce) sendPreparedKnownSystemMessage;

	void delegate(int parentTid, int childTid, ulong batchId, size_t ordinal) persistAddTaskDep;
	void delegate(ulong batchId, int oldTid, int newTid) persistReplaceTaskDepChild;
	void delegate(ulong batchId) persistRemoveTaskBatch;
	PersistedBatch[] delegate() loadTaskDeps;
	QuestionRecord[] delegate() loadQuestions;
	int delegate(int askerTid, int answererTid, string text) persistInsertQuestion;
	void delegate(int qid, string answer) persistAnswerQuestion;
	void delegate(int qid) persistCancelQuestion;
	void delegate(int qid) persistDeleteQuestion;

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

	int lastQid;
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
		ensureProcessQueueAlive: (int tid) {
			if (tasks[tid].status == TaskStatus.pending)
				tasks[tid].status = TaskStatus.active;
			return tid == 2 ? reject!void(new Exception("simulated child session startup failure")) : resolve();
		},
		sendTaskMessage: (int tid, const(ContentBlock)[] content, const(ContentBlock)[] broadcastContent, string cydoMeta, string nonce) { assert(tid == 3); return resolve(); },
		emitTaskReload: (int tid, string reason, string excludedUserUuid) {},
		appendTaskDiagnostic: (int tid, string subject, string body) {},
		taskAlive: (int tid) => false, tasksShareWorkspace: (int aTid, int bTid) => true,
		taskWorkspaceLabel: (int tid) => "local",
		reactivateTask: (int tid) => resolve(),
		sendKnownSystemMessage: (int tid, KnownSystemMessageKind kind, string body) { return resolve(); },
		persistAddTaskDep: (int parentTid, int childTid, ulong batchId, size_t ordinal) {},
		persistReplaceTaskDepChild: (ulong, int, int) {},
		persistRemoveTaskBatch: (ulong) {},
		loadTaskDeps: () => cast(PersistedBatch[]) null,
		loadQuestions: () => cast(QuestionRecord[]) null,
		persistInsertQuestion: (int, int, string) => ++lastQid,
		persistAnswerQuestion: (int, string) {},
		persistCancelQuestion: (int) {},
		persistDeleteQuestion: (int) {},
		broadcastTaskUpdate: (int tid) {}, broadcastFocusHint: (int fromTid, int toTid) {},
		sendAskUserQuestionPrompt: (int tid, JSONFragment questions, string toolUseId) {},
		clearAskUserQuestionPrompt: (int tid) {},
		sendPermissionPrompt: (int tid, const PendingPermission pending) {},
		clearPermissionPrompt: (int tid) {}, appendTaskSpawnedEvent: (int parentTid, int childTid, int specIndex) {},
		broadcastTaskCreated: (TaskCreatedMessage message) {}, permissionSettings: (string agentName, string workspaceName) => PermissionSettings.init,
		onNextTick: (void delegate() cb) { onNextTick(socketManager, cb); }, generateTitle: (int tid, string prompt) {},
	));

	auto tools = new CydoToolsImpl(backend, "1", "tool-call");
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
	Promise!(McpResult)[int] pendingAskUserQuestions_;
	struct QueuedPermissionPrompt
	{
		PermissionPrompt prompt;
		Duration timeout;
		SysTime deadline;
		Promise!PermissionDecision promise;
	}
	QueuedPermissionPrompt[][int] permissionPromptQueues_;
	/// Only the visible prompt of each task can have a timer.
	TimerTask[int] permissionPromptTimeouts_;
	BatchRegistry batchRegistry_;
	Mailbox[int] mailboxes_;
	ref Mailbox mailbox(int tid)
	{
		if ((tid in mailboxes_) is null) mailboxes_[tid] = Mailbox.init;
		return mailboxes_[tid];
	}
	QuestionRecord[int] questions_;
	SubtaskResultDelivery subtaskResultDelivery_;
	TerminalProcess[] activeTerminals_;
	private ulong nextUnsandboxedCommandPromptId_;

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
				sendKnownSystemMessage: host_.sendKnownSystemMessage,
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

			host_.broadcastTaskCreated(TaskCreatedMessage("task_created",
				childTid, pd.workspace, pd.projectPath, parentTid, "subtask"));
			host_.broadcastTaskUpdate(childTid);
			host_.broadcastFocusHint(parentTid, childTid);
			host_.appendTaskSpawnedEvent(parentTid, childTid, specIndex);

			void failLaunch(TaskData* child, string message)
			{
				child.error = message;
				child.resultText = message;
				host_.persistResultText(childTid, message);
				host_.transitionTaskFrom(childTid,
					[TaskStatus.pending, TaskStatus.active], TaskStatus.failed,
					TaskNotificationChange.preserve);
			}

			string edgeTemplate;
			if (ptd !is null)
			{
				if (auto edge = ptd.creatable_tasks.byName(taskType))
				{
					edgeTemplate = edge.prompt_template;
					try
						childTd.resultNote = substituteVars(edge.result_note,
							["output_dir": host_.taskDir(pd)]);
					catch (Exception e)
					{
						failLaunch(childTd, e.msg);
						return LaunchedTask(childTid);
					}
					try
						host_.setupWorktreeForEdge(childTid, parentTid, edge.worktree);
					catch (WorktreePreparationFailure e)
					{
						failLaunch(childTd, e.msg);
						return LaunchedTask(childTid);
					}
				}
			}

			if (host_.taskProducesCommitOutput(childTd.projectPath,
				childTd.taskType) && childTd.hasWorktree)
			{
				string worktreePath;
				typeof(execute(["git"])) headResult;
				try
				{
					worktreePath = host_.worktreePath(childTd);
					headResult = execute(["git", "-C", worktreePath, "rev-parse", "HEAD"]);
				}
				catch (Exception e)
				{
					failLaunch(childTd, e.msg);
					return LaunchedTask(childTid);
				}
				auto taskStartHead = headResult.output.strip;
				if (headResult.status != 0 || taskStartHead.length == 0)
				{
					failLaunch(childTd, format!"Failed to capture task start HEAD in %s (status %d): %s"(
						worktreePath, headResult.status, taskStartHead));
					return LaunchedTask(childTid);
				}
				childTd.taskStartHead = taskStartHead;
				host_.persistTaskStartHead(childTid, childTd.taskStartHead);
			}

			string renderedPrompt;
			try
			{
				renderedPrompt = renderPrompt(*ctd, prompt,
					host_.promptSearchPath(childTd.projectPath),
					host_.outputPath(childTd), edgeTemplate);
				renderedPrompt = prependTaskFraming(renderedPrompt,
					host_.taskSystemPromptForMessage(childTid, ctd),
					loadProjectMemory(ctd, childTd.repoPath,
						host_.promptSearchPath(childTd.projectPath)));
			}
			catch (Exception e)
			{
				failLaunch(childTd, e.msg);
				return LaunchedTask(childTid);
			}
			auto parentTypeForSubject =
				(ptd !is null && ptd.creatable_tasks.length > 0)
					? pd.taskType : "";
			auto taskPromptMsgSubject = taskPromptSubject(
				parentTypeForSubject, taskType);
			auto subtaskMeta = host_.buildKnownSystemMessageMeta(
				KnownSystemMessageKind.taskPrompt,
				taskPromptMsgSubject,
				["task_description": prompt], "task_description");
			submitInitialTaskMessage(childTid, KnownSystemMessageKind.taskPrompt,
				renderedPrompt, taskPromptMsgSubject, subtaskMeta, (Exception e) {
					auto failed = requireTask(childTid,
						"Created child task must exist when launch fails");
					if (failed.status != TaskStatus.failed)
						failLaunch(failed, e.msg);
					recordChildTerminal(childTid);
				});

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

	private static string resolveCommandShell(string shell, scope string delegate() passwdShell)
	{
		import std.path : isAbsolute;
		import cydo.runtime.launch.sandbox : resolveExecutablePath;

		auto source = "SHELL";
		if (shell.length == 0)
		{
			shell = passwdShell();
			source = "the user's passwd login shell (SHELL is unset or empty)";
		}
		enforce(shell.length > 0, "No shell from " ~ source);
		enforce(isAbsolute(shell) && resolveExecutablePath(shell, null).length > 0,
			format("%s does not name an absolute executable file: %s", source, shell));
		return shell;
	}

	private static string passwdLoginShell()
	{
		import core.sys.posix.pwd : getpwuid;
		import core.sys.posix.unistd : getuid;
		import std.string : fromStringz;

		auto user = getpwuid(getuid());
		return user is null ? null : user.pw_shell.fromStringz.idup;
	}

	Promise!McpResult handleUnsandboxedCommand(string callerTid, string command,
		string cwd, int timeout, ToolCallCancellation cancellation)
	{
		return handleUnsandboxedCommand(callerTid, command, cwd, timeout, cancellation,
			() => passwdLoginShell());
	}

	private Promise!McpResult handleUnsandboxedCommand(string callerTid, string command,
		string cwd, int timeout, ToolCallCancellation cancellation,
		scope string delegate() passwdShell)
	{
		import core.time : seconds;
		import std.algorithm : canFind, remove;
		import std.conv : to;
		import std.file : exists, isDir;
		import std.path : isAbsolute;
		import std.process : environment;

		enum cancelled = "Cancelled by the agent";
		int tid;
		TaskData* td;
		string shell;
		try
		{
			tid = to!int(callerTid);
			td = host_.getTask(tid);
			enforce(td !is null, "Task not found");
			enforce(td.unsandboxedCommandExecution != UnsandboxedCommandExecution.no,
				"UnsandboxedCommand is not available to this task");
			enforce(command.strip.length > 0 && !command.canFind('\0'),
				"command must be non-empty and contain no NUL bytes");
			enforce(!cwd.canFind('\0') && isAbsolute(cwd) && exists(cwd) && isDir(cwd),
				"cwd must be an absolute path to an existing directory");
			enforce(timeout >= 1, "timeout must be at least one second");
			shell = resolveCommandShell(environment.get("SHELL"), passwdShell);
		}
		catch (Exception e)
			return resolve(McpResult("UnsandboxedCommand: " ~ e.msg, true));

		if (cancellation.cancelled)
			return resolve(McpResult(cancelled, true));

		auto settings = host_.permissionSettings(td.agentName, td.workspace);
		auto id = format("unsandboxed_command_%s_%s", tid, ++nextUnsandboxedCommandPromptId_);
		static struct Input
		{
			string command;
			string cwd;
			int timeout;
		}
		auto prompt = PermissionPrompt(id, "UnsandboxedCommand",
			JSONFragment(toJson(Input(command, cwd, timeout))),
			format("Runs on the host with %s, outside the task's sandbox, with CyDo's environment", shell));

		auto result = new Promise!McpResult;
		TerminalProcess terminal;
		TimerTask timer;
		bool settled;
		void finish(McpResult output)
		{
			settled = true;
			result.fulfill(output);
		}
		void killGroup(string reason)
		{
			terminal.forceKill();
			finish(McpResult(terminal.output() ~ format(
				"\n[UnsandboxedCommand: %s; process group killed]", reason), true));
		}

		cancellation.onCancel({
			if (settled)
				return;
			if (terminal is null)
			{
				withdraw(tid, id, cancelled);
				return;
			}
			timer.cancel();
			killGroup("cancelled by the agent");
		});
		void run()
		{
			try
				terminal = new TerminalProcess([shell, "-c", command], null, cwd,
					1024 * 1024, ownProcessGroup: true);
			catch (Exception e)
			{
				finish(McpResult("UnsandboxedCommand: " ~ e.msg, true));
				return;
			}
			activeTerminals_ ~= terminal;
			terminal.onExit = () {
				activeTerminals_ = activeTerminals_.remove!(t => t is terminal);
				if (settled)
					return;
				timer.cancel();
				finish(McpResult(terminal.output(),
					terminal.exitCode() != 0 || terminal.exitSignal() !is null));
			};
			timer = setTimeout(() => killGroup(format("timed out after %s s", timeout)),
				timeout.seconds);
		}

		final switch (td.unsandboxedCommandExecution)
		{
			case UnsandboxedCommandExecution.no:
				assert(false, "rejected above");
			case UnsandboxedCommandExecution.yes:
				run();
				break;
			case UnsandboxedCommandExecution.ask:
				promptUserForPermission(tid, prompt, settings.promptTimeout).then(
					(PermissionDecision decision) {
						if (cancellation.cancelled || !decision.allow)
						{
							finish(McpResult(cancellation.cancelled ? cancelled : decision.message, true));
							return;
						}
						run();
					});
				break;
		}
		return result;
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

		foreach (ordinal, childTid; childTids)
		{
			auto child = requireTask(childTid, "Registered child must exist");
			assert(child.status != TaskStatus.pending, "Cannot register an unstarted child");
			host_.persistAddTaskDep(parentTid, childTid, handle.batchId, ordinal);
		}

		auto parent = requireTask(parentTid, "Registered parent must exist");
		if (parent.status != TaskStatus.waiting)
			host_.transitionTaskFrom(parentTid,
				[TaskStatus.pending, TaskStatus.active], TaskStatus.waiting,
				TaskNotificationChange.preserve);

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
			int pendingQid = presentedQuestionFor(askerTid, targetTid);
			if (pendingQid > 0)
				return resolve(McpResult(
					"Sub-task has a pending question (qid=" ~ to!string(pendingQid)
					~ "). Use Answer(qid, message) instead.", true));
		}
		auto qid = host_.persistInsertQuestion(askerTid, targetTid, message);
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
		host_.persistAnswerQuestion(qid, message);
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

	Promise!McpResult handleCreateUserTask(string callerTidStr, string prompt, string title,
		string entryPoint, string project, bool start)
	{
		import std.algorithm : canFind, filter, map;
		import std.array : array, join;
		import std.conv : to;
		import std.path : isAbsolute;

		int callerTid;
		try
			callerTid = to!int(callerTidStr);
		catch (Exception)
			return resolve(McpResult("Invalid calling task ID", true));
		auto caller = host_.getTask(callerTid);
		if (caller is null)
			return resolve(McpResult("Task not found", true));
		if (trimEcmaScript(prompt).length == 0)
			return resolve(McpResult("prompt must not be empty", true));

		auto projectPath = caller.projectPath;
		auto workspace = caller.workspace;
		if (project.length > 0)
		{
			if (!project.isAbsolute)
				return resolve(McpResult("project must be an absolute path: " ~ project, true));
			try
				projectPath = canonicalProjectPath(project);
			catch (Exception)
				return resolve(McpResult("Project path must be an existing directory: " ~ project, true));

			auto names = host_.workspacesWithProject(projectPath);
			if (names.length == 0)
				return resolve(McpResult(projectPath ~ " is not a known CyDo project. "
					~ "Pass a project's main checkout path, or omit `project` for your current project", true));
			if (!names.canFind(caller.workspace))
			{
				if (names.length != 1)
					return resolve(McpResult(projectPath ~ " belongs to several workspaces ("
						~ names.join(", ") ~ "), none of them yours", true));
				workspace = names[0];
			}
		}

		auto offered = creatableEntryPointsOf(host_.taskTypesForProject(caller.projectPath),
			host_.entryPointsForProject(caller.projectPath), caller.taskType);
		auto available = offered.map!(entry => entry.edge.name);
		auto name = entryPoint;
		if (!name.length)
		{
			auto defaults = offered.filter!(entry => entry.edge.default_).map!(entry => entry.edge.name).array;
			if (defaults.length == 0)
				return resolve(McpResult("entry_point is required: this task has no default entry point. Available: "
					~ (offered.length ? available.join(", ") : "(none)"), true));
			if (defaults.length > 1)
				return resolve(McpResult("entry_point is required: this task has multiple default entry points: "
					~ defaults.join(", ") ~ ". Available: " ~ available.join(", "), true));
			name = defaults[0];
		}
		else if (!available.canFind(name))
			return resolve(McpResult("Entry point '" ~ name
				~ "' is not available to this task. Available: "
				~ (offered.length ? available.join(", ") : "(none)"), true));

		auto target = host_.entryPointsForProject(projectPath).byName(name);
		if (target is null || target.system)
			return resolve(McpResult("Entry point '" ~ name ~ "' does not exist in project " ~ projectPath, true));
		if (start && workspace != caller.workspace)
			return resolve(McpResult("Cannot start a task in workspace '" ~ workspace
				~ "': tasks can be started only in your own workspace ('" ~ caller.workspace
				~ "'). Create it as a draft instead (omit `start`).", true));

		auto tid = host_.createUserTask(UserTaskSpec(workspace, projectPath, name, title,
			start ? "" : prompt, callerTid));
		if (!start)
			return resolve(McpResult.structured(toJson(CreatedTaskResult(tid, workspace,
				projectPath, name, "draft"))));
		return host_.startUserTask(tid, prompt).then(
			() => McpResult.structured(toJson(CreatedTaskResult(tid, workspace, projectPath, name, "started"))),
			(Exception failure) => McpResult(format!"Task %d was created but could not start: %s"(
				tid, failure.msg), true));
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
		auto askUser()
		{
			return promptUserForPermission(tid, prompt, settings.promptTimeout)
				.then((PermissionDecision decision) => decision.allow
					? makePermissionAllowJson(prompt.input.json)
					: makePermissionDenyJson(decision.message));
		}
		final switch (escalation)
		{
			case PermissionEscalation.policyAsk:
				// Under `ask`, the host command asks for approval with its own
				// prompt; asking here too would ask twice. Under `yes` it does
				// not, so the policy's prompt is the only one and stays.
				string name, server, source;
				decomposeToolName(prompt.toolName, name, server, source);
				if (name == "UnsandboxedCommand" && server == "cydo" && source == "mcp"
					&& td.unsandboxedCommandExecution == UnsandboxedCommandExecution.ask)
					return resolve(makePermissionAllowJson(prompt.input.json));
				return askUser();
			case PermissionEscalation.classifier:
				return askUser();
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
				return askUser();
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
		withdraw(tid, toolUseId, "Permission request withdrawn by the agent");
	}

	private void withdraw(int tid, string toolUseId, string message)
	{
		auto queue = tid in permissionPromptQueues_;
		if (queue is null)
			return;

		foreach (index, entry; *queue)
		{
			if (entry.prompt.toolUseId != toolUseId)
				continue;

			auto decision = PermissionDecision(false, message);
			if (index == 0)
				settleHead(tid, decision);
			else
			{
				import std.algorithm.mutation : remove;
				*queue = (*queue).remove(index);
				entry.promise.fulfill(decision);
			}
			return;
		}
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

		pump(tid);
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
		enforce(json.tool_use_id.length > 0, "Permission response requires tool_use_id");
		auto tid = json.tid;
		auto queue = tid in permissionPromptQueues_;
		if (queue is null || (*queue)[0].prompt.toolUseId != json.tool_use_id)
		{
			warningf("Ignoring stale permission response for task %s, tool use %s",
				tid, json.tool_use_id);
			return;
		}

		string rawContent = json.content.json !is null
			? jsonParse!string(json.content.json)
			: "{}";
		PermissionDecision decision;
		try
		{
			import std.json : parseJSON;

			auto parsed = parseJSON(rawContent);
			if (auto behavior = "behavior" in parsed)
			{
				if (behavior.str == "allow")
					decision = PermissionDecision(true);
				else
				{
					string denyMsg = "User denied permission";
					if (auto msg = "message" in parsed)
						if (msg.str.length > 0)
							denyMsg = msg.str;
					decision = PermissionDecision(false, denyMsg);
				}
			}
			else
				decision = PermissionDecision(false, "Invalid response");
		}
		catch (Exception)
			decision = PermissionDecision(false, "Invalid response");

		settleHead(tid, decision);
	}

	private void settleHead(int tid, PermissionDecision decision)
	{
		cancelPermissionPromptTimeout(tid);
		auto queue = tid in permissionPromptQueues_;
		auto promise = (*queue)[0].promise;
		*queue = (*queue)[1 .. $];
		if ((*queue).length > 0)
			showHead(tid);
		else
		{
			permissionPromptQueues_.remove(tid);
			clearSettledPermissionPrompt(tid,
				requireTask(tid, "Settled permission prompt for a missing task"),
				true);
		}

		promise.fulfill(decision);
	}

	private void clearSettledPermissionPrompt(int tid, TaskData* task, bool isProcessing)
	{
		if (task !is null)
		{
			task.needsAttention = false;
			host_.persistNeedsAttention(tid, false);
			task.hasPendingQuestion = false;
			task.notificationBody = "";
			task.isProcessing = isProcessing;
		}
		host_.clearPermissionPrompt(tid);
		if (task !is null)
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

		if (auto queue = tid in permissionPromptQueues_)
		{
			auto head = (*queue)[0];
			send(toJson(PermissionPromptMessage.of(tid,
				PendingPermission(head.prompt, head.deadline))));
		}
	}

	bool hasLiveBatchOwner(int tid)
	{
		BatchHandle handle;
		size_t slot;
		return batchRegistry_.findOwnerOfChild(tid, handle, slot);
	}

	int pendingBatchParent(int childTid)
	{
		return batchRegistry_.parentOfChild(childTid);
	}

	bool hasBatchChild(int tid)
	{
		return batchRegistry_.hasChild(tid);
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
		if (batchRegistry_.recordChildDone(handle, slot, tid, childResult(tid)))
			deliverCompletedBatch(handle);
		return true;
	}

	void removeDeletedBatchChild(int tid)
	{
		BatchHandle handle;
		if (batchRegistry_.dropPendingChild(tid, handle))
			deliverCompletedBatch(handle);
	}

	private void deliverCompletedBatch(BatchHandle handle)
	{
		mailbox(handle.parentTid).push(MailboxEvent(
			MailboxEvent.Kind.batch, handle.batchId));
		pump(handle.parentTid);
	}

	Promise!void sendSystemRestartNudge(int tid, bool retryToolCall)
	{
		return subtaskResultDelivery_.sendSystemRestartNudge(tid, retryToolCall);
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
		if (auto pending = tid in permissionPromptQueues_)
		{
			auto queue = *pending;
			permissionPromptQueues_.remove(tid);
			cancelPermissionPromptTimeout(tid);
			clearSettledPermissionPrompt(tid, host_.getTask(tid), false);
			foreach (entry; queue)
				entry.promise.fulfill(PermissionDecision(false, "Task exited"));
		}
	}

	private enum sessionEnded = "Session ended while waiting for Ask response";

	void onTaskTerminal(int tid, bool deleting = false)
	{
		cleanUpAskedQuestions(tid);
		auto askers = failQuestionsForAnswerer(tid, sessionEnded);
		mailbox(tid).release(new Exception(sessionEnded));
		foreach (askerTid; askers)
			pump(askerTid);
		if (deleting)
			mailboxes_.remove(tid);
		else
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

	// Rebuild recorded child results from current task state. If a follow-up
	// Ask revived the child, the batch can wait for that turn or carry its
	// newer result text. The parent can Ask the child to clarify or resend.
	// A legacy pending child keeps its slot until it is started manually or
	// deleted. Startup resumes only children that had already started.
	void rebuildWaits()
	{
		auto batches = host_.loadTaskDeps();
		foreach (batch; batches)
		{
			auto handle = batchRegistry_.rebuild(batch.parentTid, batch.batchId,
				batch.childTids);
			foreach (slot, childTid; batch.childTids)
			{
				auto child = requireTask(childTid, "Persisted batch child must exist");
				if (child.status == TaskStatus.completed || child.status == TaskStatus.failed)
					batchRegistry_.recordChildDone(handle, slot, childTid, childResult(childTid));
			}
		}

		auto questions = host_.loadQuestions();
		foreach (question; questions)
			questions_[question.qid] = question;
		rebuildMailbox(questions, batches);

		// Finish interrupted terminal cleanup before any mailbox can present
		// a question or answer. Open questions for answerers remain queued.
		bool[int] terminalAskers;
		foreach (q; questions)
		{
			auto asker = requireTask(q.askerTid, "Persisted question asker must exist");
			if (asker.status == TaskStatus.completed || asker.status == TaskStatus.failed)
				terminalAskers[q.askerTid] = true;
			if (q.state == QuestionState.cancelled)
			{
				auto answerer = requireTask(q.answererTid, "Persisted question answerer must exist");
				if (answerer.status == TaskStatus.completed || answerer.status == TaskStatus.failed)
					removeQuestion(q.qid);
			}
		}
		foreach (tid; terminalAskers.keys)
			cleanUpAskedQuestions(tid);
	}

	// A lost in-memory failure notice triggers a restart nudge only when
	// it was the waiting task's sole outstanding obligation.
	bool hasRestoredWork(int tid)
	{
		auto pending = tid in mailboxes_;
		return hasOutstandingWait(tid) || (pending !is null && !pending.empty);
	}

	void pumpRestoredMailboxes()
	{
		foreach (tid; mailboxes_.keys)
			pump(tid);
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

	void submitInitialTaskMessage(int tid, KnownSystemMessageKind kind, string prompt,
		string subject, string meta, void delegate(Exception) failed,
		void delegate() accepted = null, Promise!void delegate() beforeSubmit = null)
	{
		host_.ensureProcessQueueAlive(tid).then(() {
			return beforeSubmit is null ? resolve() : beforeSubmit();
		}).then(() {
			auto message = wrapKnownSystemMessage(host_.systemKeyword(), kind, prompt, subject);
			return host_.sendTaskMessage(tid, [ContentBlock("text", message)],
				null, meta, null).then(() {
				if (accepted !is null)
					accepted();
			}, (Exception e) {
				if (auto rejection = cast(AgentSubmissionRejected) e)
					failed(rejection);
				else
					throw e;
			});
		}, (Exception e) {
			failed(e);
			return resolve();
		}).except((Exception e) {
			host_.onNextTick({ throw e; });
		}).ignoreResult();
	}

	McpResult childResult(int tid)
	{
		auto result = subtaskResultDelivery_.taskResult(tid);
		return McpResult.structured(toJson(result), result.status == "error");
	}

	void rebuildMailbox(QuestionRecord[] questions, PersistedBatch[] batches)
	{
		foreach (q; questions)
			if (q.state == QuestionState.open)
				mailbox(q.answererTid).push(MailboxEvent(MailboxEvent.Kind.question, 0, q.qid));
		foreach (q; questions)
			if (q.state == QuestionState.answered)
				mailbox(q.askerTid).push(MailboxEvent(MailboxEvent.Kind.answer, 0, q.qid));
		foreach (batch; batches)
			if (batchRegistry_.complete(BatchHandle(batch.parentTid, batch.batchId)))
				mailbox(batch.parentTid).push(MailboxEvent(MailboxEvent.Kind.batch, batch.batchId));
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
					host_.persistCancelQuestion(qid);
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
		foreach (qid; removeQids) removeQuestion(qid);
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
		host_.persistDeleteQuestion(qid);
		q.state = QuestionState.failed;
		mailbox(q.askerTid).push(MailboxEvent(MailboxEvent.Kind.failed, 0, qid, notice, q.answererTid));
		return q.askerTid;
	}

	void removeQuestion(int qid)
	{
		host_.persistDeleteQuestion(qid);
		questions_.remove(qid);
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

	int presentedQuestionFor(int tid, int askerTid = 0)
	{
		int earliest = int.max;
		foreach (qid, q; questions_)
			if (q.answererTid == tid && q.state == QuestionState.open
				&& (askerTid == 0 || q.askerTid == askerTid)
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
							host_.broadcastFocusHint(childTid, tid);
						host_.persistRemoveTaskBatch(handle.batchId);
						batchRegistry_.remove(handle);
						break;
					case MailboxEvent.Kind.answer:
						removeQuestion(event.qid);
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
		foreach (qid; removeQids) removeQuestion(qid);
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
		void failFast(Exception e) { host_.onNextTick({ throw e; }); }
		try host_.ensureProcessQueueAlive(tid).then(() {
			if (host_.shuttingDown() || mailbox(tid).empty)
			{
				releaseClaim();
				return;
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
			host_.sendPreparedKnownSystemMessage(tid, blocks,
				firstMeta, nonces.join(";"))
				.then(() { settleDelivery(true); }, &deliveryFailed)
				.except(&failFast).ignoreResult();
		}).except(&deliveryFailed).except(&failFast).ignoreResult();
		catch (Exception e)
			deliveryFailed(e);
		return true;
	}

private:
	Promise!McpResult awaitEvent(int tid)
	{
		return async({
			MailboxEvent ev;
			do
			{
				try ev = mailbox(tid).take().await;
				catch (Exception e) return McpResult(e.msg, true);
				auto task = host_.getTask(tid);
				if (task is null || task.status == TaskStatus.completed
					|| task.status == TaskStatus.failed)
				{
					if (deliverable(tid, ev))
						mailbox(tid).putBack([ev]);
					pump(tid);
					return McpResult(sessionEnded, true);
				}
			}
			while (!deliverable(tid, ev));
			McpResult result;
			final switch (ev.kind)
			{
				case MailboxEvent.Kind.batch:
					result = envelopeResult(BatchHandle(tid, ev.batchId));
					break;
				case MailboxEvent.Kind.question:
				{
					auto q = questions_[ev.qid];
					auto asker = host_.getTask(q.askerTid);
					result = McpResult.structured(toJson(QuestionResult("question",
						q.askerTid, q.qid, asker is null ? null : asker.title, q.text)));
					break;
				}
				case MailboxEvent.Kind.answer:
				{
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

	Promise!PermissionDecision promptUserForPermission(int tid, PermissionPrompt prompt,
		Duration timeout)
	{
		auto promise = new Promise!PermissionDecision;
		auto queue = permissionPromptQueues_.get(tid, null);
		foreach (entry; queue)
			assert(entry.prompt.toolUseId != prompt.toolUseId, "Duplicate permission prompt ID");
		queue ~= QueuedPermissionPrompt(prompt, timeout, SysTime.init, promise);
		permissionPromptQueues_[tid] = queue;
		if (queue.length == 1)
			showHead(tid);
		return promise;
	}

	private void showHead(int tid)
	{
		auto td = requireTask(tid, "Permission prompt target must be a live task");
		auto head = &permissionPromptQueues_[tid][0];
		auto timeout = head.timeout;
		if (timeout > Duration.zero)
		{
			head.deadline = Clock.currTime + timeout;
			permissionPromptTimeouts_[tid] = setTimeout({
				permissionPromptTimeouts_.remove(tid);
				settleHead(tid, PermissionDecision(false, format!(
					"Permission denied: nobody answered the permission prompt within %s")(timeout)));
			}, timeout);
		}
		host_.sendPermissionPrompt(tid, PendingPermission(head.prompt, head.deadline));

		td.needsAttention = true;
		host_.persistNeedsAttention(tid, true);
		td.hasPendingQuestion = true;
		td.notificationBody = "Permission requested";
		td.isProcessing = false;
		host_.touchTask(tid);
		host_.persistLastActive(tid, td.lastActive);
		host_.broadcastTaskUpdate(tid);
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

	void failContinuationSubmission(int tid, string diagnostic, Exception error)
	{
		auto failed = requireTask(tid, "Continuation task must exist when submission fails");
		if (failed.status != TaskStatus.failed)
		{
			assert(failed.status == TaskStatus.active,
				"Continuation submission failed outside an active task");
			failed.error = error.msg;
			failed.resultText = error.msg;
			host_.persistResultText(tid, failed.resultText);
			host_.transitionTask(tid, TaskStatus.active, TaskStatus.failed,
				TaskNotificationChange.preserve);
			host_.appendTaskDiagnostic(tid, diagnostic, error.msg);
		}
		recordChildTerminal(tid);
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
			Promise!void delegate() beforeSubmit;
			if (acceptedSwitchMode.length > 0)
			{
				auto projectPath = td.projectPath;
				beforeSubmit = () => host_.correctAbortedToolCall(tid, host_.readPromptFile(
					"prompts/aborted_tool_call_accepted.md", projectPath,
					["tool_name": "SwitchMode", "result": acceptedSwitchMode]));
			}
			submitInitialTaskMessage(tid, KnownSystemMessageKind.modeSwitch,
				renderedContinuationPrompt, modeSwitchMsgSubject, contMeta,
				(Exception e) { failContinuationSubmission(tid, "Continuation failed", e); },
				() { sendPendingChildAnswerReminder(tid); }, beforeSubmit);
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
			submitInitialTaskMessage(childTid, KnownSystemMessageKind.handoff,
				renderedSuccessorPrompt, handoffMsgSubject, handoffMeta,
				(Exception e) { failContinuationSubmission(childTid, "Handoff failed", e); });

			BatchHandle owner;
			size_t slot;
			if (batchRegistry_.findOwnerOfChild(tid, owner, slot))
			{
				batchRegistry_.replaceChild(tid, childTid);
				host_.persistReplaceTaskDepChild(owner.batchId, tid, childTid);
			}

			host_.transitionTaskFrom(tid,
				[TaskStatus.pending, TaskStatus.active, TaskStatus.alive,
					TaskStatus.waiting, TaskStatus.failed], TaskStatus.completed,
				TaskNotificationChange.preserve);
			host_.emitTaskReload(tid, "continuation", excludedUserUuid);
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
	import cydo.domain.storage.persistence : Persistence;
	auto persistence = Persistence(":memory:");
	string persistedTaskStartHead;
	int launchCalls;
	bool producesCommitOutput = true;
	bool assignWorktree = true;
	bool initializeWorktree;
	string expectedTaskStartHead;

	int lastQid;
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
			tasks[tid].status = TaskStatus.active;
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
		persistAddTaskDep: &persistence.addTaskDep,
		persistReplaceTaskDepChild: (ulong, int, int) {},
		persistRemoveTaskBatch: (ulong) {},
		loadTaskDeps: () => cast(PersistedBatch[]) null,
		loadQuestions: () => cast(QuestionRecord[]) null,
		persistInsertQuestion: (int, int, string) => ++lastQid,
		persistAnswerQuestion: (int, string) {},
		persistCancelQuestion: (int) {},
		persistDeleteQuestion: (int) {},
		broadcastTaskUpdate: (int tid) {},
		broadcastFocusHint: (int fromTid, int toTid) {},
		sendAskUserQuestionPrompt: (int tid, JSONFragment questions,
			string toolUseId) {},
		clearAskUserQuestionPrompt: (int tid) {},
		sendPermissionPrompt: (int tid, const PendingPermission pending) {},
		clearPermissionPrompt: (int tid) {},
		appendTaskSpawnedEvent: (int parentTid, int childTid, int specIndex) {},
		broadcastTaskCreated: (TaskCreatedMessage message) {
			foreach (batch; persistence.loadTaskDeps())
				assert(!batch.childTids.canFind(message.tid));
		},
		permissionSettings: (string agentName, string workspaceName) => PermissionSettings.init,
		onNextTick: (void delegate() cb) { onNextTick(socketManager, cb); },
		generateTitle: (int tid, string prompt) {},
	));

	auto tools = new CydoToolsImpl(backend, "1", "tool-call");
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

version (unittest)
{
	import ae.net.asockets : onNextTick, socketManager;
	import ae.utils.promise : reject;
	import ae.utils.promise.await : async;
	import cydo.domain.storage.persistence : Persistence;
	import std.algorithm.searching : canFind;

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
		Persistence persistence;
		TaskTypeDef[] taskTypes;
		SingletonDef[] singletons;
		UserEntryPointDef[][string] entryPointsByProject;
		string[][string] projectWorkspaces;
		UserTaskSpec[] createdUserTasks;
		int[] startedUserTids;
		string[] startedUserPrompts;
		Promise!void userTaskStartGate;
		size_t singletonForTaskCalls;
		int waitingToActiveTransitions;
		int activeToWaitingTransitions;
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
		int[] recoveryDiagnosticTids;
		string[] recoveryDiagnosticSubjects;
		string[] recoveryDiagnosticBodies;
		int reloadTid = -1;
		string reloadReason;
		string reloadExcludedUserUuid;
		Promise!void reactivationGate;

		this()
		{
			persistence = Persistence(":memory:");
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

		void offerUserEntryPoint(bool default_ = true)
		{
			taskTypes[0].creatable_entry_points = [CreatableEntryPointDef("review", default_: default_)];
			entryPointsByProject[tasks[1].projectPath] = [
				UserEntryPointDef("review", "child", "Review"),
				UserEntryPointDef("other", "child", "Other"),
			];
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
				entryPointsForProject: (string projectPath) => entryPointsByProject.get(projectPath, null),
				workspacesWithProject: (string projectPath) => projectWorkspaces.get(projectPath, null),
				createUserTask: (UserTaskSpec spec) {
					createdUserTasks ~= spec;
					return nextTid++;
				},
				startUserTask: (int tid, string prompt) {
					assert(userTaskStartGate !is null, "Unexpected startUserTask call");
					startedUserTids ~= tid;
					startedUserPrompts ~= prompt;
					return userTaskStartGate;
				},
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
						if (tasks[tid].status == TaskStatus.pending)
						tasks[tid].status = TaskStatus.active;
					if (failEnsure)
						return reject!void(new Exception("wake failed"));
					if (wakeGate !is null) return wakeGate;
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
					(int tid, string subject, string body) {
						recoveryDiagnosticTids ~= tid;
						recoveryDiagnosticSubjects ~= subject;
						recoveryDiagnosticBodies ~= body;
					},
				transitionTask: (int tid, TaskStatus expectedFrom,
					TaskStatus to,
					TaskNotificationChange notification) {
					assert(tasks[tid].status == expectedFrom);
					if (expectedFrom == TaskStatus.waiting
						&& to == TaskStatus.active)
						waitingToActiveTransitions++;
					if (expectedFrom == TaskStatus.active && to == TaskStatus.waiting)
						activeToWaitingTransitions++;
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
				persistAddTaskDep: &persistence.addTaskDep,
				persistReplaceTaskDepChild: &persistence.replaceTaskDepChild,
				persistRemoveTaskBatch: &persistence.removeTaskBatch,
				loadTaskDeps: &persistence.loadTaskDeps,
				loadQuestions: &persistence.loadQuestions,
				persistInsertQuestion: &persistence.insertQuestion,
				persistAnswerQuestion: &persistence.answerQuestion,
				persistCancelQuestion: &persistence.cancelQuestion,
				persistDeleteQuestion: &persistence.deleteQuestion,
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
}

version (unittest) import cydo.domain.task_types.definition : CreatableEntryPointDef;

version (unittest) private McpResult awaitCreateTaskResult(Promise!McpResult pending)
{
	McpResult[] results;
	pending.then((McpResult result) { results ~= result; }).ignoreResult();
	drainPromiseNextTicks();
	assert(results.length == 1);
	return results[0];
}

unittest
{
	import std.file : exists, tempDir;
	import std.path : buildPath;

	auto f = new BatchInvariantFixture;
	f.offerUserEntryPoint(false);
	auto backend = f.makeBackend();
	auto project = canonicalProjectPath(tempDir());
	auto missing = buildPath(project, "cydo-create-task-nonexistent-project");
	assert(!exists(missing));

	void assertRejected(string expected, string prompt = "Review this",
		string entryPoint = "", string target = "", bool start = false)
	{
		auto result = awaitCreateTaskResult(
			backend.handleCreateUserTask("1", prompt, "", entryPoint, target, start));
		assert(result.isError && result.text == expected, result.text);
		assert(f.createdUserTasks.length == 0 && f.startedUserTids.length == 0);
	}

	assertRejected("prompt must not be empty", " \t\n");
	assertRejected("prompt must not be empty", "\uFEFF");
	assertRejected("prompt must not be empty", "\u00A0");
	assertRejected("Entry point 'other' is not available to this task. Available: review",
		"Review this", "other");
	assertRejected("entry_point is required: this task has no default entry point. Available: review");
	assertRejected("project must be an absolute path: relative", "Review this", "review", "relative");
	assertRejected("Project path must be an existing directory: " ~ missing,
		"Review this", "review", missing);
	assertRejected(project ~ " is not a known CyDo project. "
		~ "Pass a project's main checkout path, or omit `project` for your current project",
		"Review this", "review", project);
	f.projectWorkspaces[project] = ["remote", "shared"];
	assertRejected(project ~ " belongs to several workspaces (remote, shared), none of them yours",
		"Review this", "review", project);
	f.projectWorkspaces[project] = ["remote"];
	auto unavailable = "Entry point 'review' does not exist in project " ~ project;
	assertRejected(unavailable, "Review this", "review", project);
	f.entryPointsByProject[project] = [UserEntryPointDef("review", "child", "Review",
		"", WorktreeMode.inherit, true)];
	assertRejected(unavailable, "Review this", "review", project);
	f.entryPointsByProject[project][0].system = false;
	assertRejected("Cannot start a task in workspace 'remote': tasks can be started only in your own workspace "
		~ "('local'). Create it as a draft instead (omit `start`).", "Review this", "review", project, true);

	f.taskTypes[0].creatable_entry_points = [
		CreatableEntryPointDef("other", default_: true),
		CreatableEntryPointDef("review", default_: true),
	];
	assertRejected("entry_point is required: this task has multiple default entry points: other, review. "
		~ "Available: other, review");
}

version (unittest) private void assertCreatedTaskResult(McpResult result, int tid,
	string workspace, string project, string status)
{
	import std.json : parseJSON;

	assert(!result.isError && result.structuredContent);
	assert(result.text == result.structuredContent.json);
	auto payload = parseJSON(result.text);
	assert(payload["tid"].integer == tid);
	assert(payload["workspace"].str == workspace);
	assert(payload["project_path"].str == project);
	assert(payload["entry_point"].str == "review");
	assert(payload["status"].str == status);
}

unittest
{
	import std.file : tempDir;
	import std.path : buildPath;

	auto f = new BatchInvariantFixture;
	f.offerUserEntryPoint();
	f.taskTypes[0].creatable_entry_points = [CreatableEntryPointDef("other")]
		~ f.taskTypes[0].creatable_entry_points;
	auto backend = f.makeBackend();
	enum prompt = "\uFEFF  Review this  \u00A0";
	enum title = "Review";
	auto project = canonicalProjectPath(tempDir());

	void assertDraft(string target, string workspace, string expectedProject)
	{
		auto tid = f.nextTid;
		auto countBefore = f.createdUserTasks.length;
		auto result = awaitCreateTaskResult(
			backend.handleCreateUserTask("1", prompt, title, "", target, false));
		assert(f.createdUserTasks.length == countBefore + 1);
		assert(f.createdUserTasks[$ - 1] == UserTaskSpec(
			workspace, expectedProject, "review", title, prompt, 1));
		assert(f.startedUserTids.length == 0);
		assertCreatedTaskResult(result, tid, workspace, expectedProject, "draft");
	}

	assertDraft("", "local", f.tasks[1].projectPath);
	f.entryPointsByProject[project] = [UserEntryPointDef("review", "child", "Review")];
	f.projectWorkspaces[project] = ["remote", "local"];
	assertDraft(buildPath(tempDir(), "."), "local", project);
	f.projectWorkspaces[project] = ["remote"];
	assertDraft(project, "remote", project);
}

unittest
{
	import std.conv : to;

	foreach (fail; [false, true])
	{
		auto f = new BatchInvariantFixture;
		f.offerUserEntryPoint();
		f.userTaskStartGate = new Promise!void;
		auto tid = f.nextTid;
		enum prompt = "Review this";
		auto pending = f.makeBackend().handleCreateUserTask("1", prompt, "", "review", "", true);
		McpResult[] results;
		pending.then((McpResult result) { results ~= result; }).ignoreResult();
		drainPromiseNextTicks();
		assert(results.length == 0);
		assert(f.createdUserTasks == [UserTaskSpec("local", f.tasks[1].projectPath,
			"review", "", "", 1)]);
		assert(f.startedUserTids == [tid] && f.startedUserPrompts == [prompt]);

		if (fail)
			f.userTaskStartGate.reject(new Exception("boom"));
		else
			f.userTaskStartGate.fulfill();
		drainPromiseNextTicks();
		assert(results.length == 1);
		if (fail)
			assert(results[0].isError && results[0].text
				== "Task " ~ tid.to!string ~ " was created but could not start: boom");
		else
			assertCreatedTaskResult(results[0], tid, "local", f.tasks[1].projectPath, "started");
		assert(f.createdUserTasks.length == 1 && f.startedUserTids == [tid]);
	}
}

// An accepted SwitchMode waits for queue preparation and history correction.
unittest
{
	foreach (rejectCorrection; [false, true])
	{
		auto f = new BatchInvariantFixture;
		f.wakeGate = new Promise!void;
		auto correctionGate = new Promise!void;
		auto b = f.makeBackend();
		auto accepted = b.handleSwitchMode("1", "keep");
		assert(!accepted.isError);

		b.host_.readPromptFile = (string path, string projectPath, string[string] vars) {
			assert(path == "prompts/aborted_tool_call_accepted.md");
			assert(projectPath == f.tasks[1].projectPath);
			assert(vars["tool_name"] == "SwitchMode");
			assert(vars["result"] == accepted.text);
			return "accepted mode switch correction";
		};
		string[] corrections;
		b.host_.correctAbortedToolCall = (int tid, string correction) {
			assert(tid == 1);
			corrections ~= correction;
			return correctionGate;
		};
		string[] prompts;
		b.host_.sendTaskMessage = (int tid, const(ContentBlock)[] content,
			const(ContentBlock)[] broadcastContent, string meta, string nonce) {
			assert(tid == 1 && content.length == 1);
			prompts ~= content[0].text;
			return resolve();
		};

		b.spawnContinuation(1);
		drainPromiseNextTicks();
		assert(f.wakeCalls == 1 && corrections.length == 0 && prompts.length == 0);

		f.wakeGate.fulfill();
		drainPromiseNextTicks();
		assert(corrections == ["accepted mode switch correction"]);
		assert(prompts.length == 0);

		if (rejectCorrection)
		{
			correctionGate.reject(new Exception("history correction rejected"));
			drainPromiseNextTicks();
			assert(f.tasks[1].status == TaskStatus.failed);
			assert(f.diagnosticSubjects == ["Continuation failed"]);
			assert(f.diagnosticBodies == ["history correction rejected"]);
			assert(prompts.length == 0);
		}
		else
		{
			correctionGate.fulfill();
			drainPromiseNextTicks();
			assert(f.tasks[1].status == TaskStatus.active);
			assert(prompts.length == 1 && prompts[0].canFind("Continue from where you left off."));
		}
	}
}

unittest
{
	import ae.utils.statequeue : StateQueue;
	import cydo.domain.tasks.model : ProcessState;
	import cydo.workflow.sessions.task_runner : TaskSessionRunner, TaskSessionRunnerHost;
	import std.exception : assertThrown;

	void assertRestart(BatchInvariantFixture f, int[] taskIds, int[] expectedNudges, int[] expectedRetries)
	{
		auto b = f.makeBackend();
		b.rebuildWaits();
		foreach (tid; taskIds)
			f.tasks[tid].processQueue = new StateQueue!ProcessState(
				(ProcessState goal) => resolve(goal), ProcessState.Dead);
		int[] nudged, retries;
		auto runner = new TaskSessionRunner(TaskSessionRunnerHost(
			getTask: (int tid) => tid in f.tasks,
			snapshotTaskIds: () => taskIds,
			isSingletonTask: (const TaskData* td) => false,
			hasRestoredWork: &b.hasRestoredWork,
			sendSystemRestartNudge: (int tid, bool retryToolCall) {
				nudged ~= tid;
				if (retryToolCall)
					retries ~= tid;
				return resolve();
			},
		));
		runner.resumeInFlightTasks();
		drainPromiseNextTicks();
		foreach (tid; taskIds)
			assert(f.tasks[tid].processQueue.goalState == ProcessState.Alive);
		assert(nudged == expectedNudges);
		assert(retries == expectedRetries);
	}

	// Restart on either side of batch registration.
	enum ParentWait { beforeRegistration, waitingBatch, activeBatch, activeAsk }
	foreach (wait; [ParentWait.beforeRegistration, ParentWait.waitingBatch,
		ParentWait.activeBatch, ParentWait.activeAsk])
	{
		auto f = new BatchInvariantFixture;
		f.tasks[1].isProcessing = true;
		auto b = f.makeBackend();
		auto first = b.handleCreateTask("1", 0, "first", "child", "first prompt").launch();
		auto second = b.handleCreateTask("1", 1, "second", "child", "second prompt").launch();
		final switch (wait)
		{
		case ParentWait.beforeRegistration:
			break;
		case ParentWait.activeBatch:
		case ParentWait.waitingBatch:
			b.registerBatchAndAwait("1", [first, second]).ignoreResult();
			if (wait == ParentWait.activeBatch)
				f.tasks[1].status = TaskStatus.active;
			break;
		case ParentWait.activeAsk:
			f.persistence.insertQuestion(1, 2, "still waiting for this answer");
			break;
		}
		f.tasks[1].isProcessing = false;
		assertRestart(f, [1, 3, 4],
			wait == ParentWait.waitingBatch ? [3, 4] : [1, 3, 4],
			wait == ParentWait.beforeRegistration ? [1, 3, 4] : [3, 4]);
	}

	enum HandoffOutcome { started, renderFailure, startFailure }
	foreach (outcome; [HandoffOutcome.started, HandoffOutcome.renderFailure, HandoffOutcome.startFailure])
	{
		auto f = new BatchInvariantFixture;
		f.tasks[1].status = TaskStatus.waiting;
		f.tasks[2].taskType = "parent";
		f.tasks[2].pendingContinuation = new PendingContinuation(
			PendingContinuation.Kind.handoff, "continue", "successor prompt");
		f.persistence.addTaskDep(1, 2, 2, 0);
		auto b = f.makeBackend();
		b.rebuildWaits();
		b.host_.persistReplaceTaskDepChild = (ulong batchId, int source, int successor) {
			assert(f.tasks[source].status == TaskStatus.active);
			assert(f.tasks[successor].status == TaskStatus.active);
			f.persistence.replaceTaskDepChild(batchId, source, successor);
		};
		if (outcome == HandoffOutcome.renderFailure)
		{
			b.host_.taskSystemPromptForMessage = (int tid, TaskTypeDef* typeDef) {
				throw new Exception("successor system prompt unavailable");
			};
			assertThrown!Exception(b.spawnContinuation(2));
			assert(f.persistence.loadTaskDeps() == [PersistedBatch(1, 2, [2])]);
			assert(f.tasks[2].status == TaskStatus.active);
			assert(f.tasks[3].status == TaskStatus.pending && !b.hasBatchChild(3));
			continue;
		}

		if (outcome == HandoffOutcome.startFailure)
			b.host_.ensureProcessQueueAlive = (int tid) {
				if (tid == 1)
					return resolve();
				f.tasks[tid].status = TaskStatus.active;
				return reject!void(new Exception("successor failed to start"));
			};

		b.spawnContinuation(2);
		assert(f.tasks[2].status == TaskStatus.completed);
		assert(f.persistence.loadTaskDeps() == [PersistedBatch(1, 2, [3])]);

		if (outcome == HandoffOutcome.started)
		{
			assertRestart(f, [1, 3], [3], [3]);
			b = f.makeBackend();
			b.rebuildWaits();
			f.tasks[3].status = TaskStatus.completed;
			f.tasks[3].resultText = "successor result";
			assert(b.recordChildTerminal(3));
		}
		drainPromiseNextTicks();

		assert(f.sentTids == [1]);
		assert(f.sentBodies[0].canFind(outcome == HandoffOutcome.started
			? "successor result" : "successor failed to start"));
		assert(f.persistence.loadTaskDeps().length == 0);
	}
}

unittest
{
	import core.exception : AssertError;
	import std.exception : assertThrown;
	import cydo.domain.task_types.definition : SingletonAudience;

	// A persisted preparation failure can be rebuilt without its paths.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[1].status = TaskStatus.waiting;
		f.tasks[2].status = TaskStatus.failed;
		f.tasks[2].resultText = "unresolvable launch path";
		f.tasks[2].worktreeTid = 2;
		f.persistence.addTaskDep(1, 2, 2, 0);
		auto b = f.makeBackend();
		b.subtaskResultDelivery_ = new SubtaskResultDelivery(SubtaskResultDeliveryHost(
			getTask: b.host_.getTask,
			outputPath: delegate string(const TaskData* task) { assert(0, "Failed launch needs no output path"); },
			worktreePath: delegate string(const TaskData* task) { assert(0, "Failed launch needs no worktree path"); },
		));
		b.rebuildWaits();
		McpResult result;
		b.awaitEvent(1).then((McpResult r) { result = r; }).ignoreResult();
		drainPromiseNextTicks();
		assert(result.isError);
		auto slot = result.text.jsonParse!BatchResultEnvelope.tasks[0].json.jsonParse!TaskResult;
		assert(slot.tid == 2 && slot.error == "unresolvable launch path");
		assert(slot.worktree.length == 0 && slot.output_file.length == 0);
	}

	// Startup delivers incoming questions, recorded answers, then completed batches.
	{
		auto f = new BatchInvariantFixture;
		foreach (tid; [3, 4])
			f.tasks[tid] = TaskData(tid, "local", f.tasks[1].projectPath);
		f.tasks[3].status = f.tasks[4].status = TaskStatus.completed;
		f.tasks[3].resultText = "first batch result";
		f.tasks[4].resultText = "second batch result";
		f.persistence.addTaskDep(1, 4, 4, 0);
		f.persistence.addTaskDep(1, 3, 3, 0);

		auto firstAnswer = f.persistence.insertQuestion(1, 2, "first outgoing Ask");
		f.persistence.insertQuestion(2, 1, "first incoming question");
		auto cancelled = f.persistence.insertQuestion(2, 1, "cancelled question");
		auto secondAnswer = f.persistence.insertQuestion(1, 2, "second outgoing Ask");
		f.persistence.insertQuestion(2, 1, "second incoming question");
		f.persistence.cancelQuestion(cancelled);
		f.persistence.answerQuestion(secondAnswer, "second restored answer");
		f.persistence.answerQuestion(firstAnswer, "first restored answer");

		auto b = f.makeBackend();
		b.rebuildWaits();
		b.pumpRestoredMailboxes();
		drainPromiseNextTicks();

		assert(f.sentTids == [1]);
		string[] messages = ["first incoming question", "second incoming question",
			"first restored answer", "second restored answer",
			"first batch result", "second batch result"];
		assert(f.sentBodies.length == messages.length);
		foreach (i, message; messages)
			assert(f.sentBodies[i].canFind(message), f.sentBodies[i]);
	}

	// A restored Handoff successor's result belongs to the batch owner.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[1].status = TaskStatus.waiting;
		f.tasks[1].resultText = "existing failed result";
		f.tasks[2].status = TaskStatus.completed;
		f.tasks[3] = TaskData(3, "local", f.tasks[1].projectPath);
		f.tasks[3].parentTid = 2;
		f.tasks[3].status = TaskStatus.completed;
		f.tasks[3].resultText = "successor result";
		f.persistence.addTaskDep(1, 2, 2, 0);
		f.persistence.replaceTaskDepChild(2, 2, 3);
		f.preparedSendGate = new Promise!void;

		auto b = f.makeBackend();
		b.host_.persistResultText = (int tid, string result) {
			assert(false, "Rejected recovery must leave the recorded failure intact");
		};
		b.host_.transitionTask = (int tid, TaskStatus from, TaskStatus to,
			TaskNotificationChange change) {
			assert(false, "Rejected recovery must not transition a failed owner");
		};
		b.rebuildWaits();
		b.pumpRestoredMailboxes();
		drainPromiseNextTicks();
		assert(f.wakeCalls == 1 && f.sentTids == [1]);
		assert(f.sentBodies[0].canFind("successor result"));
		assert(f.persistence.loadTaskDeps() == [PersistedBatch(1, 2, [3])]);

		f.tasks[1].status = TaskStatus.failed;
		f.preparedSendGate.reject(new Exception("restored batch submission rejected"));
		drainPromiseNextTicks();
		assert(f.tasks[1].status == TaskStatus.failed
			&& f.tasks[1].resultText == "existing failed result");
		assert(f.tasks[2].status == TaskStatus.completed);
		assert(f.tasks[3].status == TaskStatus.completed && f.tasks[3].parentTid == 2);
		assert(f.waitingToActiveTransitions == 0 && f.activeToWaitingTransitions == 0);
		assert(f.recoveryDiagnosticTids.length == 0 && f.diagnosticSubjects.length == 0);
		assert(b.mailbox(1).events == [MailboxEvent(MailboxEvent.Kind.batch, 2)]);
		assert(f.persistence.loadTaskDeps() == [PersistedBatch(1, 2, [3])]);
	}

	// Startup discards outgoing questions and undelivered answers for terminal askers.
	foreach (answered; [false, true])
	{
		auto f = new BatchInvariantFixture;
		f.tasks[1].status = answered ? TaskStatus.completed : TaskStatus.failed;
		auto qid = f.persistence.insertQuestion(1, 2, "question before asker ended");
		if (answered)
			f.persistence.answerQuestion(qid, "answer before asker ended");

		auto b = f.makeBackend();
		b.rebuildWaits();
		b.pumpRestoredMailboxes();
		drainPromiseNextTicks();

		auto state = answered ? "answered" : "unanswered";
		assert(f.wakeCalls == 0, state ~ " question woke a task");
		assert(f.sendCalls == 0, state ~ " question caused a delivery");
		assert(b.presentedQuestionFor(2) == 0);
		assert(f.persistence.loadQuestions().length == 0,
			state ~ " question survived startup cleanup");
	}

	// A live asker's question can still be presented to a terminal answerer.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[1].status = TaskStatus.waiting;
		f.tasks[2].status = TaskStatus.completed;
		auto qid = f.persistence.insertQuestion(1, 2, "question for terminal answerer");

		auto b = f.makeBackend();
		b.rebuildWaits();
		b.pumpRestoredMailboxes();
		drainPromiseNextTicks();

		assert(f.wakeCalls == 1 && f.sentTids == [2]);
		assert(f.sentBodies[0].canFind("question for terminal answerer"));
		assert(b.presentedQuestionFor(2) == qid);
	}

	// A completed batch can still deliver its result to a terminal parent.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[1].status = TaskStatus.failed;
		f.tasks[2].status = TaskStatus.completed;
		f.tasks[2].resultText = "late batch result";
		f.persistence.addTaskDep(1, 2, 2, 0);

		auto b = f.makeBackend();
		b.rebuildWaits();
		b.pumpRestoredMailboxes();
		drainPromiseNextTicks();

		assert(f.wakeCalls == 1 && f.sentTids == [1]);
		assert(f.sentBodies[0].canFind("late batch result"));
		assert(f.persistence.loadTaskDeps().length == 0);
	}

	// Late Answer still reports cancellation after startup.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[1].status = TaskStatus.failed;
		auto qid = f.persistence.insertQuestion(1, 2, "cancelled before restart");
		f.persistence.cancelQuestion(qid);
		auto b = f.makeBackend();
		b.rebuildWaits();

		McpResult result;
		b.handleAnswer("2", qid, "late answer").then((McpResult r) {
			result = r;
		}).ignoreResult();
		drainPromiseNextTicks();
		assert(result.isError && result.text.canFind("was cancelled"));
	}

	// Startup retires persisted cancelled questions for terminal answerers.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[1].status = TaskStatus.failed;
		f.tasks[2].status = TaskStatus.completed;
		auto qid = f.persistence.insertQuestion(1, 2, "cancelled before restart");
		f.persistence.cancelQuestion(qid);
		auto b = f.makeBackend();
		b.rebuildWaits();

		assert(f.persistence.loadQuestions().length == 0);
		McpResult result;
		b.handleAnswer("2", qid, "late answer").then((McpResult r) {
			result = r;
		}).ignoreResult();
		drainPromiseNextTicks();
		assert(result.isError && result.text.canFind("Unknown question ID"));
	}

	// Answer becomes available once startup re-presents the question.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[1].status = TaskStatus.waiting;
		auto qid = f.persistence.insertQuestion(1, 2, "unanswered before restart");
		auto b = f.makeBackend();
		b.rebuildWaits();

		McpResult early, accepted;
		b.handleAnswer("2", qid, "early answer").then((McpResult r) {
			early = r;
		}).ignoreResult();
		drainPromiseNextTicks();
		assert(early.isError && early.text.canFind("Unknown question ID"));

		b.pumpRestoredMailboxes();
		drainPromiseNextTicks();
		assert(f.sentTids == [2] && f.sentBodies[0].canFind("unanswered before restart"));
		b.handleAnswer("2", qid, "answer after restart").then((McpResult r) {
			accepted = r;
		}).ignoreResult();
		drainPromiseNextTicks();
		assert(!accepted.isError && accepted.text.jsonParse!AnswerResult.status == "delivered");
		assert(f.sentTids == [2, 1] && f.sentBodies[1].canFind("answer after restart"));
	}

	// Classify rebuilt waits at the runner's actual resume/nudge boundary.
	{
		import ae.utils.statequeue : StateQueue;
		import cydo.domain.tasks.model : ProcessState;
		import cydo.workflow.sessions.task_runner : TaskSessionRunner, TaskSessionRunnerHost;

		auto f = new BatchInvariantFixture;
		enum batchParent = 1, runningChild = 2, waitingAsker = 3,
			lostNoticeAsker = 4, failedAnswerer = 5, completeBatchParent = 6, completedChild = 7,
			cancelledAsker = 8;
		foreach (tid; [waitingAsker, lostNoticeAsker, failedAnswerer, completeBatchParent, completedChild, cancelledAsker])
			f.tasks[tid] = TaskData(tid, "local", f.tasks[batchParent].projectPath);
		int[] waitingTasks = [batchParent, waitingAsker, lostNoticeAsker, completeBatchParent, cancelledAsker];
		foreach (tid; waitingTasks)
		{
			f.tasks[tid].status = TaskStatus.waiting;
			f.tasks[tid].processQueue = new StateQueue!ProcessState(
				(ProcessState goal) => resolve(goal), ProcessState.Dead);
		}
		f.persistence.addTaskDep(batchParent, runningChild, runningChild, 0);
		f.tasks[completedChild].status = TaskStatus.completed;
		f.persistence.addTaskDep(completeBatchParent, completedChild, completedChild, 0);
		f.persistence.insertQuestion(waitingAsker, runningChild, "still unanswered");
		auto cancelledQid = f.persistence.insertQuestion(cancelledAsker, runningChild, "cancelled");
		f.persistence.cancelQuestion(cancelledQid);
		auto lostQid = f.persistence.insertQuestion(lostNoticeAsker, failedAnswerer,
			"answerer will fail");

		// Leave the failure notice queued in the old backend when it shuts down.
		auto beforeRestart = f.makeBackend();
		beforeRestart.rebuildWaits();
		f.shuttingDown = true;
		f.tasks[failedAnswerer].status = TaskStatus.failed;
		beforeRestart.onTaskTerminal(failedAnswerer);
		assert(beforeRestart.mailbox(lostNoticeAsker).events ==
			[MailboxEvent(MailboxEvent.Kind.failed, 0, lostQid,
				format!"Question %d: Session ended while waiting for Ask response"(lostQid),
				failedAnswerer)]);
		f.shuttingDown = false;

		auto b = f.makeBackend();
		b.rebuildWaits();
		int[] nudged;
		auto runner = new TaskSessionRunner(TaskSessionRunnerHost(
			getTask: (int tid) => &f.tasks[tid],
			snapshotTaskIds: () => waitingTasks,
			isSingletonTask: (const TaskData* td) => false,
			hasRestoredWork: &b.hasRestoredWork,
			sendSystemRestartNudge: (int tid, bool retryToolCall) {
				assert(retryToolCall);
				nudged ~= tid;
				return resolve();
			},
		));
		runner.resumeInFlightTasks();
		drainPromiseNextTicks();
		foreach (tid; waitingTasks)
			assert(f.tasks[tid].processQueue.goalState == ProcessState.Alive);
		assert(nudged == [lostNoticeAsker, cancelledAsker], format!"Unexpected restart nudges: %s"(nudged));
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
		assert(f.persistence.loadQuestions() == [b.questions_[question.qid]]);
		f.tasks[2].status = status;
		b.handleAnswer("2", question.qid, "landed").then((McpResult r) {
			delivered = r;
		}).ignoreResult();
		drainPromiseNextTicks();

		assert(!requested.isError && requested.text.jsonParse!AnswerResult.message == "landed");
		assert(!delivered.isError && delivered.text.jsonParse!AnswerResult.status == "delivered");
		assert(f.focusHints[$ - 1] == [2, 1]);
		assert(b.questions_[question.qid].state == QuestionState.answered);
		assert(f.persistence.loadQuestions() == [b.questions_[question.qid]]);
		b.onToolCallDelivered("1", requested);
		assert(f.persistence.loadQuestions().length == 0);
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

	// Recovered batch rows survive until submission is accepted, including during retry.
	enum RecoveredSubmission { accepted, synchronousRejection, asynchronousRejection, terminalRejection }
	foreach (outcome; [RecoveredSubmission.accepted, RecoveredSubmission.synchronousRejection,
		RecoveredSubmission.asynchronousRejection, RecoveredSubmission.terminalRejection])
	{
		const caseName = format!"Recovered batch: %s"(outcome);
		enum firstResult = "first recovered result", secondResult = "second recovered result";
		enum failureSubject = "Failed to deliver recovered sub-task results";
		const failureReason = caseName ~ " from prepared send";
		const initialStatus = outcome == RecoveredSubmission.asynchronousRejection
			? TaskStatus.active : TaskStatus.waiting;
		auto f = new BatchInvariantFixture;
		f.tasks[1].status = initialStatus;
		f.tasks[2].status = TaskStatus.completed;
		f.tasks[2].resultText = firstResult;
		f.tasks[3] = TaskData(3, "local", f.tasks[1].projectPath);
		f.tasks[3].status = TaskStatus.completed;
		f.tasks[3].resultText = secondResult;
		f.persistence.addTaskDep(1, 2, 2, 0);
		f.persistence.addTaskDep(1, 3, 2, 1);
		auto deps = [PersistedBatch(1, 2, [2, 3])];

		auto b = f.makeBackend();
		auto send = b.host_.sendPreparedKnownSystemMessage;
		auto gate = new Promise!void;
		string offeredBody;
		int[] offeredTids;
		int activations;
		b.host_.sendPreparedKnownSystemMessage =
			(int tid, const(ContentBlock)[] blocks, string meta, string nonce) {
				offeredTids ~= tid;
				assert(blocks.length == 1, caseName);
				offeredBody = blocks[0].text;
				if (outcome == RecoveredSubmission.synchronousRejection)
					throw new Exception(failureReason);
				return gate.then(() {
					assert(f.tasks[tid].status == TaskStatus.waiting, caseName);
					activations++;
					f.tasks[tid].status = TaskStatus.active;
					f.tasks[tid].isProcessing = true;
				});
			};
		b.rebuildWaits();
		assert(b.pump(1), caseName);
		drainPromiseNextTicks();
		assert(offeredTids == [1], caseName);
		assert(offeredBody.canFind(firstResult) && offeredBody.canFind(secondResult), caseName);
		assert(f.persistence.loadTaskDeps() == deps, caseName);
		assert(activations == 0, caseName);

		if (outcome != RecoveredSubmission.synchronousRejection)
		{
			assert(f.tasks[1].status == initialStatus && f.tasks[1].isProcessing, caseName);
			assert(!b.pump(1) && f.recoveryDiagnosticTids.length == 0, caseName);
		}
		if (outcome == RecoveredSubmission.accepted)
		{
			gate.fulfill();
			drainPromiseNextTicks();
			assert(f.tasks[1].status == TaskStatus.active && f.tasks[1].isProcessing, caseName);
			assert(activations == 1 && offeredTids == [1], caseName);
			assert(f.persistence.loadTaskDeps().length == 0, caseName);
			assert(f.recoveryDiagnosticTids.length == 0 && b.mailbox(1).empty, caseName);
			continue;
		}

		if (outcome == RecoveredSubmission.terminalRejection)
		{
			f.tasks[1].status = TaskStatus.failed;
			f.tasks[1].resultText = "runner-owned failure";
		}
		if (outcome != RecoveredSubmission.synchronousRejection)
		{
			gate.reject(new Exception(failureReason));
			drainPromiseNextTicks();
		}
		assert(!f.tasks[1].isProcessing && activations == 0 && offeredTids == [1], caseName);
		assert(f.persistence.loadTaskDeps() == deps, caseName);
		assert(b.mailbox(1).events == [MailboxEvent(MailboxEvent.Kind.batch, 2)], caseName);
		assert(f.activeToWaitingTransitions
			== (outcome == RecoveredSubmission.asynchronousRejection ? 1 : 0), caseName);
		if (outcome == RecoveredSubmission.terminalRejection)
		{
			assert(f.tasks[1].status == TaskStatus.failed, caseName);
			assert(f.tasks[1].resultText == "runner-owned failure", caseName);
			assert(f.recoveryDiagnosticTids.length == 0, caseName);
			continue;
		}

		assert(f.tasks[1].status == TaskStatus.waiting, caseName);
		assert(f.recoveryDiagnosticTids == [1], caseName);
		assert(f.recoveryDiagnosticSubjects == [failureSubject], caseName);
		assert(f.recoveryDiagnosticBodies == [failureReason], caseName);
		b.host_.sendPreparedKnownSystemMessage = send;
		assert(b.pump(1), caseName);
		drainPromiseNextTicks();
		assert(f.acceptedPreparedTids == [1] && f.sentBodies == [offeredBody], caseName);
		assert(f.persistence.loadTaskDeps().length == 0, caseName);
		assert(b.mailbox(1).empty && !b.pump(1), caseName);
		assert(f.recoveryDiagnosticTids == [1], caseName);
	}

	// Shutdown leaves a held live batch available for a later delivery attempt.
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

	// Shutdown also preserves held results reconstructed at startup.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[1].status = TaskStatus.waiting;
		f.tasks[2].status = TaskStatus.completed;
		f.tasks[2].resultText = "completed before shutdown";
		f.tasks[3] = TaskData(3, "local", f.tasks[1].projectPath);
		f.tasks[3].status = TaskStatus.failed;
		f.tasks[3].resultText = "failed before shutdown";
		f.persistence.addTaskDep(1, 2, 2, 0);
		f.persistence.addTaskDep(1, 3, 2, 1);
		auto deps = [PersistedBatch(1, 2, [2, 3])];
		auto handle = BatchHandle(1, 2);
		auto b = f.makeBackend();
		b.rebuildWaits();

		f.shuttingDown = true;
		assert(!b.pump(1));
		assert(f.wakeCalls == 0 && f.sendCalls == 0);
		assert(b.mailbox(1).events.length == 1 && b.batchRegistry_.exists(handle));
		assert(f.persistence.loadTaskDeps() == deps);

		f.shuttingDown = false;
		assert(b.pump(1));
		assert(f.wakeCalls == 1);
		f.shuttingDown = true;
		drainPromiseNextTicks();
		assert(!f.tasks[1].isProcessing && f.sendCalls == 0);
		assert(b.mailbox(1).events.length == 1 && b.batchRegistry_.exists(handle));
		assert(f.persistence.loadTaskDeps() == deps);

		f.shuttingDown = false;
		assert(b.pump(1));
		drainPromiseNextTicks();
		assert(f.wakeCalls == 2 && f.sendCalls == 1);
		assert(f.sentBodies[0].canFind("completed before shutdown"));
		assert(f.sentBodies[0].canFind("failed before shutdown"));
		assert(f.persistence.loadTaskDeps().length == 0);
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
		int askOutcomes, reminders;
		b.registerBatchAndAwait("1", [LaunchedTask(2)]).then((McpResult r) {
			batchResult = r;
		}).ignoreResult();
		assert(b.finalizeCompletedSubTask(2));
		drainPromiseNextTicks();
		assert(!batchResult.isError
			&& batchResult.text.jsonParse!BatchResultEnvelope.tasks.length == 1);
		b.onToolCallDelivered("1", batchResult);
		assert(!b.hasLiveBatchOwner(2) && !b.hasBatchChild(2));

		auto firstFollowUpHint = f.focusHints.length;
		b.handleAsk("1", "follow up", 2).then((McpResult r) {
			askResult = r;
			askOutcomes++;
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
			hasBatchChild: &b.hasBatchChild,
			hasPendingChildQuestion: &b.hasPendingChildQuestion,
			sendPendingChildAnswerReminder: (int tid) {
				auto hintsBeforeReminder = f.focusHints.length;
				b.sendPendingChildAnswerReminder(tid);
				assert(f.focusHints.length == hintsBeforeReminder);
				assert(askOutcomes == 0);
				reminders++;
			},
			recordChildTerminal: &b.recordChildTerminal,
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
		assert(askOutcomes == 1 && reminders == (answer ? 0 : 1));
		if (!answer)
			assert(askResult.isError
				&& askResult.text.canFind("Session ended while waiting for Ask response"));
	}

	// A batch rebuilt from storage sends its hint when the pump delivers it.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[1].status = TaskStatus.waiting;
		f.tasks[2].status = TaskStatus.completed;
		f.persistence.addTaskDep(1, 2, 2, 0);
		f.preparedSendGate = new Promise!void;
		auto b = f.makeBackend();
		b.rebuildWaits();
		b.pumpRestoredMailboxes();
		drainPromiseNextTicks();
		assert(f.sentTids == [1] && f.focusHints.length == 0);
		f.preparedSendGate.fulfill();
		drainPromiseNextTicks();
		assert(f.focusHints == [[2, 1]]);
		assert(!b.hasBatchChild(2));
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
		enum qid = 1;
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
		assert(f.persistence.loadQuestions() == [b.questions_[qid]]);
		auto sendCalls = f.sendCalls;
		f.tasks[2].status = TaskStatus.failed;
		b.onTaskTerminal(2);
		drainPromiseNextTicks();
		assert((qid in b.questions_) is null);
		assert(f.persistence.loadQuestions().length == 0);
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
		b.questions_[1] = QuestionRecord(1, 1, 2, "asked", "answered", QuestionState.answered);
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
		b.questions_[1] = QuestionRecord(1, 1, 2, "older", null, QuestionState.failed);
		b.questions_[2] = QuestionRecord(2, 1, 2, "newer", null, QuestionState.failed);
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
		b.host_.persistRemoveTaskBatch = (ulong) {
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
		assert(b.questions_.length == 1 && f.persistence.loadQuestions().length == 1);
		f.tasks[3].status = TaskStatus.active;
		f.tasks[3].isProcessing = true;
		b.handleAsk("1", "incoming", 3).ignoreResult();
		auto question = present(b, 3).text.jsonParse!QuestionResult;
		assertDelivered(b, question.qid);
	}

	// T2: The Answer after a restart wake likewise has nothing left to wait for.
	void restoredAnswer()
	{
		auto f = new BatchInvariantFixture;
		addThirdTask(f);
		f.tasks[3].status = TaskStatus.failed;
		f.tasks[3].isProcessing = false;
		f.tasks[1].status = TaskStatus.waiting;
		auto cancelled = f.persistence.insertQuestion(3, 2, "outgoing");
		f.persistence.cancelQuestion(cancelled);
		auto incoming = f.persistence.insertQuestion(1, 3, "incoming");
		auto b = f.makeBackend();
		b.rebuildWaits();
		b.pumpRestoredMailboxes();
		drainPromiseNextTicks();
		assert(f.acceptedPreparedTids == [3]);
		// The fixture's wake callback leaves terminal status unchanged.
		f.tasks[3].status = TaskStatus.active;
		assertDelivered(b, incoming);
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

	void acceptedPump()
	{
		import std.exception : collectException;
		auto f = new BatchInvariantFixture;
		auto b = f.makeBackend();
		BatchHandle handle;
		string error;
		assert(b.batchRegistry_.create(1, [2], handle, error), error);
		b.host_.persistRemoveTaskBatch = (ulong) {
			throw new Exception("dependency removal failed");
		};
		assert(b.finalizeCompletedSubTask(2));
		auto thrown = collectException!Exception(drainPromiseNextTicks());
		assert(thrown !is null && thrown.msg == "dependency removal failed");
		assert(f.acceptedPreparedTids == [1]);
		assert(f.recoveryDiagnosticBodies.length == 0 && b.mailbox(1).empty);
		auto settle = b.deliveryAttempt(1, [MailboxEvent(MailboxEvent.Kind.batch, handle.batchId)]);
		assertThrown!Exception(settle(true));
		assertThrown!AssertError(settle(false));
	}

	liveAnswer();
	restoredAnswer();
	rejectedFailure(false);
	heldFailure();
	rejectedFailure(true);
	rejectedReminder(false);
	rejectedReminder(true);
	acceptedPump();

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

unittest
{
	import cydo.mcp.tools : CydoToolsImpl, TaskSpec;
	import cydo.workflow.workspace.worktree_allocator : WorktreeAllocator, WorktreeAllocatorHost;
	import std.file : exists, mkdirRecurse, rmdirRecurse, write, tempDir;
	import std.path : buildPath;
	import std.conv : to;

	auto root = buildPath(tempDir(), "cydo-task-worktree-failure");
	assert(!exists(root));
	mkdirRecurse(root);
	scope(exit) rmdirRecurse(root);
	auto repo = buildPath(root, "repo");
	mkdirRecurse(repo);
	assert(execute(["git", "-C", repo, "init"]).status == 0);
	assert(execute(["git", "-C", repo, "-c", "user.name=Verifier",
		"-c", "user.email=verifier@example.org", "commit", "--allow-empty", "-m", "init"]).status == 0);
	string taskDir(const TaskData* td) { return buildPath(root, td.tid.to!string); }
	string worktreePath(const TaskData* td) { return buildPath(root, td.worktreeTid.to!string, "worktree"); }

	auto f = new BatchInvariantFixture;
	f.tasks[1].projectPath = repo;
	f.tasks[1].isProcessing = true;
	f.taskTypes[0].creatable_tasks[0].worktree = WorktreeMode.fork;
	mkdirRecurse(buildPath(root, "4", "worktree"));
	write(buildPath(root, "4", "worktree", "collision"), "keep");
	auto b = f.makeBackend();
	auto allocator = new WorktreeAllocator(WorktreeAllocatorHost(
		getTask: b.host_.getTask,
		taskDir: &taskDir,
		worktreePath: &worktreePath,
		persistWorktreeTid: (int, int) {},
	));
	b.host_.setupWorktreeForEdge = &allocator.setupForEdge;
	int[] sent;
	b.host_.sendTaskMessage = (int tid, const(ContentBlock)[] content,
		const(ContentBlock)[] broadcastContent, string meta, string nonce) {
			sent ~= tid;
			return resolve();
		};
	auto tools = new CydoToolsImpl(b, "1", "tool-call");
	McpResult[] results;
	async({
		return tools.createTasks([TaskSpec("one", "child", "first"),
			TaskSpec("two", "child", "second")]);
	}).then((McpResult result) { results ~= result; }).ignoreResult();
	drainPromiseNextTicks();
	assert(f.tasks[3].worktreeTid == 3 && f.tasks[3].status == TaskStatus.active);
	assert(f.tasks[4].worktreeTid == 0 && f.tasks[4].status == TaskStatus.failed);
	assert(sent == [3]);
	assert(f.persistence.loadTaskDeps() == [PersistedBatch(1, 3, [3, 4])]);
	f.tasks[3].resultText = "first agent returned";
	assert(b.finalizeCompletedSubTask(3));
	drainPromiseNextTicks();
	assert(results.length == 1 && results[0].isError);
	auto batch = results[0].text.jsonParse!BatchResultEnvelope;
	auto first = batch.tasks[0].json.jsonParse!TaskResult;
	auto second = batch.tasks[1].json.jsonParse!TaskResult;
	assert(first.status == "success" && first.summary == "first agent returned");
	assert(second.status == "error" && second.error.canFind("already exists"));

	import std.exception : collectException;
	auto ownerFailure = new Exception("worktree ownership write failed");
	auto failingAllocator = new WorktreeAllocator(WorktreeAllocatorHost(
		getTask: b.host_.getTask,
		taskDir: &taskDir,
		worktreePath: &worktreePath,
		persistWorktreeTid: (int, int) { throw ownerFailure; },
	));
	b.host_.setupWorktreeForEdge = &failingAllocator.setupForEdge;
	auto launch = b.handleCreateTask("1", 0, "write failure", "child", "prompt");
	assert(collectException(launch.launch()) is ownerFailure);
	assert(f.tasks[5].status == TaskStatus.pending && f.tasks[5].worktreeTid == 0);
}

unittest
{
	import cydo.mcp.tools : CydoToolsImpl, TaskSpec;

	enum Failure { none, prompt, outputPath, submission, commit }
	foreach (failure; [Failure.none, Failure.prompt, Failure.outputPath, Failure.submission, Failure.commit])
	{
		auto f = new BatchInvariantFixture;
		f.taskTypes[0].creatable_tasks[0].worktree = WorktreeMode.fork;
		f.tasks[1].isProcessing = true;
		auto b = f.makeBackend();
		b.host_.persistAddTaskDep = (int parent, int child, ulong batch, size_t ordinal) {
			assert(f.tasks[child].status == ((failure == Failure.prompt || failure == Failure.outputPath) && child == 4
				? TaskStatus.failed : TaskStatus.active));
			f.persistence.addTaskDep(parent, child, batch, ordinal);
		};
		if (failure == Failure.prompt)
			b.host_.taskSystemPromptForMessage = (int tid, TaskTypeDef* typeDef) {
				if (tid == 4)
				{
					assert(f.tasks[3].status == TaskStatus.active);
					throw new Exception("second child system prompt unavailable");
				}
				return "";
			};

		if (failure == Failure.outputPath)
			b.subtaskResultDelivery_ = new SubtaskResultDelivery(SubtaskResultDeliveryHost(
				getTask: b.host_.getTask,
				outputPath: b.host_.outputPath = (const TaskData* task) {
					if (task.tid == 4)
						throw new Exception("second child output path unavailable");
					return "";
				},
				taskProducesCommitOutput: b.host_.taskProducesCommitOutput,
			));
		auto commitFailure = new Exception("accepted submission publication failed");
		if (failure == Failure.submission || failure == Failure.commit)
			b.host_.sendTaskMessage = (int tid, const(ContentBlock)[] content,
				const(ContentBlock)[] broadcastContent, string meta, string nonce) {
				if (tid == 3)
					return resolve();
				return reject!void(failure == Failure.submission
					? new AgentSubmissionRejected(new Exception("second child submission rejected"))
					: commitFailure);
			};

		auto tools = new CydoToolsImpl(b, "1", "tool-call");
		McpResult[] results;
		async({
			return tools.createTasks([
				TaskSpec("first", "child", "first prompt"),
				TaskSpec("second", "child", "second prompt"),
			]);
		}).then((McpResult result) { results ~= result; }).ignoreResult();
		if (failure == Failure.commit)
		{
			import std.exception : collectException;
			assert(collectException(drainPromiseNextTicks()) is commitFailure);
			assert(f.tasks[4].status == TaskStatus.active);
			continue;
		}
		drainPromiseNextTicks();
		assert(results.length == 0, results.length ? results[0].text : null);
		assert(f.tasks[1].status == TaskStatus.waiting);
		assert(f.persistence.loadTaskDeps() == [PersistedBatch(1, 3, [3, 4])]);

		if (failure == Failure.none)
		{
			f.tasks[4].resultText = "second child result";
			assert(b.finalizeCompletedSubTask(4));
		}
		f.tasks[3].resultText = "first child result";
		assert(b.finalizeCompletedSubTask(3));
		drainPromiseNextTicks();
		assert(results.length == 1 && results[0].isError == (failure != Failure.none));
		auto batch = results[0].text.jsonParse!BatchResultEnvelope;
		assert(batch.tasks.length == 2);
		auto first = batch.tasks[0].json.jsonParse!TaskResult;
		auto second = batch.tasks[1].json.jsonParse!TaskResult;
		assert(first.tid == 3 && first.summary == "first child result");
		assert(second.tid == 4);
		final switch (failure)
		{
		case Failure.none: assert(second.summary == "second child result"); break;
		case Failure.prompt: assert(second.error == "second child system prompt unavailable"); break;
		case Failure.outputPath: assert(second.error == "second child output path unavailable"); break;
		case Failure.submission: assert(second.error == "second child submission rejected"); break;
		case Failure.commit: assert(0);
		}
		b.onToolCallDelivered("1", results[0]);
		assert(f.persistence.loadTaskDeps().length == 0);
	}

	// The launch phase leaves no dependency until registry creation succeeds.
	{
		auto f = new BatchInvariantFixture;
		auto b = f.makeBackend();
		auto first = b.handleCreateTask("1", 0, "first", "child", "first prompt").launch();
		auto second = b.handleCreateTask("1", 1, "second", "child", "second prompt").launch();
		assert(f.tasks[first.childTid].status == TaskStatus.active);
		assert(f.tasks[second.childTid].status == TaskStatus.active);
		assert(f.tasks[1].status == TaskStatus.active);
		assert(f.persistence.loadTaskDeps().length == 0);

		McpResult result;
		b.registerBatchAndAwait("1", [first, first]).then((McpResult r) {
			result = r;
		}).ignoreResult();
		drainPromiseNextTicks();
		assert(result.isError && result.text.canFind("duplicate child"));
		assert(f.tasks[1].status == TaskStatus.active);
		assert(f.persistence.loadTaskDeps().length == 0);
	}
}

// A question handed to an answerer whose session ends fails the Ask once.
unittest
{
	auto f = new BatchInvariantFixture;
	f.tasks[2].isProcessing = true;
	auto b = f.makeBackend();
	McpResult[] carrier, asker;
	b.awaitEvent(2).then((McpResult r) { carrier ~= r; }).ignoreResult();
	drainPromiseNextTicks();
	assert(b.mailbox(2).hasWaiter);

	b.handleAsk("1", "handed-off question", 2)
		.then((McpResult r) { asker ~= r; }).ignoreResult();
	assert(!b.mailbox(2).hasWaiter && b.mailbox(2).empty);
	assert(carrier.length == 0);

	f.shuttingDown = true;
	f.tasks[2].status = TaskStatus.failed;
	b.onTaskTerminal(2);
	drainPromiseNextTicks();

	assert(carrier.length == 1 && carrier[0].isError
		&& carrier[0].text == "Session ended while waiting for Ask response");
	assert(asker.length == 1 && asker[0].isError
		&& asker[0].text.canFind("Session ended while waiting for Ask response"));
	b.onToolCallDelivered("1", asker[0]);
	assert(b.mailbox(1).empty && b.questions_.length == 0);
	assert(f.sendCalls == 0);
}

// An answer handed to an asker whose session ends loses its owning record.
unittest
{
	auto f = new BatchInvariantFixture;
	f.tasks[1].isProcessing = f.tasks[2].isProcessing = true;
	auto b = f.makeBackend();
	McpResult question;
	McpResult[] carrier;
	b.handleAsk("1", "question to answer", 2)
		.then((McpResult r) { carrier ~= r; }).ignoreResult();
	b.awaitEvent(2).then((McpResult r) { question = r; }).ignoreResult();
	drainPromiseNextTicks();
	auto qid = question.text.jsonParse!QuestionResult.qid;
	b.onToolCallDelivered("2", question);
	assert(b.mailbox(1).hasWaiter);

	b.handleAnswer("2", qid, "handed-off answer").ignoreResult();
	assert(!b.mailbox(1).hasWaiter && b.mailbox(1).empty);
	assert(carrier.length == 0);

	f.shuttingDown = true;
	f.tasks[1].status = TaskStatus.failed;
	b.onTaskTerminal(1);
	drainPromiseNextTicks();

	assert(carrier.length == 1 && carrier[0].isError
		&& carrier[0].text == "Session ended while waiting for Ask response");
	assert((qid in b.questions_) is null && b.mailbox(1).empty);
}

// A completed batch survives the end of the carrier's session.
unittest
{
	auto f = new BatchInvariantFixture;
	f.tasks[1].isProcessing = true;
	auto b = f.makeBackend();
	BatchHandle handle;
	string error;
	assert(b.batchRegistry_.create(1, [2], handle, error), error);
	McpResult[] carrier, nextCarrier;
	b.awaitEvent(1).then((McpResult r) { carrier ~= r; }).ignoreResult();
	drainPromiseNextTicks();
	assert(b.mailbox(1).hasWaiter);

	f.tasks[2].resultText = "handed-off batch result";
	assert(b.finalizeCompletedSubTask(2));
	assert(!b.mailbox(1).hasWaiter && b.mailbox(1).empty);
	assert(carrier.length == 0);

	f.shuttingDown = true;
	f.tasks[1].status = TaskStatus.failed;
	b.onTaskTerminal(1);
	drainPromiseNextTicks();

	assert(carrier.length == 1 && carrier[0].isError
		&& carrier[0].text == "Session ended while waiting for Ask response");
	assert(b.batchRegistry_.exists(handle));

	f.shuttingDown = false;
	f.tasks[1].status = TaskStatus.active;
	b.awaitEvent(1).then((McpResult r) { nextCarrier ~= r; }).ignoreResult();
	drainPromiseNextTicks();
	assert(nextCarrier.length == 1 && !nextCarrier[0].isError
		&& nextCarrier[0].text.canFind("handed-off batch result"));
	b.onToolCallDelivered("1", nextCarrier[0]);
	assert(!b.batchRegistry_.exists(handle) && b.mailbox(1).empty);
	assert(f.sendCalls == 0);
}

// A live carrier skips a cancelled handoff and returns the next question.
unittest
{
	auto f = new BatchInvariantFixture;
	f.tasks[2].isProcessing = true;
	f.tasks[3] = TaskData(3, "local", f.tasks[1].projectPath);
	f.tasks[3].status = TaskStatus.active;
	auto b = f.makeBackend();
	McpResult[] results;
	b.awaitEvent(2).then((McpResult r) { results ~= r; }).ignoreResult();
	drainPromiseNextTicks();
	assert(b.mailbox(2).hasWaiter);
	b.handleAsk("1", "cancel this handoff", 2).ignoreResult();
	assert(!b.mailbox(2).hasWaiter && b.mailbox(2).empty);
	f.tasks[1].status = TaskStatus.failed;
	b.onTaskTerminal(1);
	assert(f.tasks[2].status == TaskStatus.active);
	b.handleAsk("3", "deliver this live question", 2).ignoreResult();
	drainPromiseNextTicks();
	assert(results.length == 1 && !results[0].isError
		&& results[0].text.canFind("deliver this live question"),
		"live carrier must skip cancelled question and take the next event");
}

// Archive remains blocked until the parent receives the batch results.
unittest
{
	import ae.net.http.websocket : WebSocketAdapter;
	import cydo.workflow.workspace.archive_manager :
		ArchiveManager, ArchiveManagerHost, ArchiveTaskSnapshot;

	// Exercise the child directly and through its enclosing subtree.
	foreach (requestedTid; [2, 1])
	{
		auto f = new BatchInvariantFixture;
		f.tasks[1].isProcessing = true;
		f.tasks[3] = TaskData(3, "local", f.tasks[1].projectPath);
		f.tasks[3].parentTid = 1;
		f.tasks[3].status = TaskStatus.active;
		auto b = f.makeBackend();
		BatchHandle handle;
		string error;
		assert(b.batchRegistry_.create(1, [2, 3], handle, error), error);

		// Keep the live-task guard out of the way while the sibling slot is pending.
		ArchiveTaskSnapshot[int] tasks;
		tasks[1] = ArchiveTaskSnapshot(1, 0, false, false, false, "ws", "/repo");
		tasks[2] = ArchiveTaskSnapshot(2, 1, false, false, false, "ws", "/repo");
		tasks[3] = ArchiveTaskSnapshot(3, 1, false, false, false, "ws", "/repo");
		int[] archiveGoals;
		int[] persistedTasks;
		string[] errors;

		auto host = ArchiveManagerHost(
			tryGetTask: (int tid, out ArchiveTaskSnapshot task) {
				task = tasks[tid];
				return true;
			},
			snapshotTasks: () => tasks.dup,
			tryTaskDir: (int tid, string workspace, string projectPath) => "",
			updateTaskState: (int tid, bool archived, bool archiving) {
				tasks[tid].archived = archived;
				tasks[tid].archiving = archiving;
				return true;
			},
			persistArchived: (int tid, bool archived) {
				assert(archived);
				persistedTasks ~= tid;
			},
			broadcastTaskUpdate: (int tid) {},
			sendError: (WebSocketAdapter ws, int tid, string message) {
				assert(tid == requestedTid);
				errors ~= message;
			},
			setArchiveGoal: (int tid, ArchiveState goal) {
				assert(goal == ArchiveState.Archived);
				archiveGoals ~= tid;
				return resolve();
			},
			pendingBatchParent: &b.pendingBatchParent,
		);
		auto manager = new ArchiveManager(host);

		void assertArchiveRefused()
		{
			errors = null;
			manager.handleSetArchived(null, requestedTid, true);
			drainPromiseNextTicks();

			assert(errors.length == 1);
			assert(errors[0] == "Task 2 cannot be archived yet: its parent task 1 has not received its result."
				|| (requestedTid == 1
					&& errors[0] == "Task 3 cannot be archived yet: its parent task 1 has not received its result."));
			assert(!tasks[requestedTid].archived);
			assert(!tasks[requestedTid].archiving);
			assert(persistedTasks.length == 0);
			assert(archiveGoals.length == 0);
		}

		McpResult[] carriers;
		b.awaitEvent(1).then((McpResult r) { carriers ~= r; }).ignoreResult();
		drainPromiseNextTicks();

		f.tasks[2].resultText = "first child result";
		assert(b.finalizeCompletedSubTask(2));
		assertArchiveRefused();
		assert(carriers.length == 0);

		f.tasks[3].resultText = "second child result";
		assert(b.finalizeCompletedSubTask(3));
		drainPromiseNextTicks();
		assert(carriers.length == 1 && !carriers[0].isError && carriers[0].structuredContent);
		assertArchiveRefused();

		b.onToolCallDelivered("1", carriers[0]);
		errors = null;
		manager.handleSetArchived(null, requestedTid, true);
		drainPromiseNextTicks();

		assert(errors.length == 0);
		assert(tasks[requestedTid].archived);
		assert(!tasks[requestedTid].archiving);
		assert(persistedTasks == [requestedTid]);
		assert(archiveGoals == [requestedTid]);
	}
}

unittest
{
	// An earlier parent-to-child question does not prevent a second Ask.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[2].isProcessing = true;
		auto b = f.makeBackend();
		QuestionResult[] presented;
		foreach (message; ["first question", "second question"])
		{
			b.handleAsk("1", message, 2).ignoreResult();
			b.awaitEvent(2).then((McpResult r) {
				presented ~= r.text.jsonParse!QuestionResult;
				b.onToolCallDelivered("2", r);
			}).ignoreResult();
			drainPromiseNextTicks();
		}
		assert(presented.length == 2);
		assert(presented[0].message == "first question");
		assert(presented[1].message == "second question");
		assert(presented[0].qid != presented[1].qid);
	}

	// The refusal names the target child's question, even if the parent
	// received another task's question first.
	{
		auto f = new BatchInvariantFixture;
		f.tasks[1].isProcessing = true;
		f.tasks[2].isProcessing = true;
		f.tasks[3] = TaskData(3, "local", f.tasks[1].projectPath);
		f.tasks[3].status = TaskStatus.active;
		auto b = f.makeBackend();
		QuestionResult[] presented;
		McpResult childAnswer;
		foreach (caller; ["3", "2"])
		{
			b.handleAsk(caller, "question for parent", 1).then((McpResult r) {
				childAnswer = r;
			}).ignoreResult();
			b.awaitEvent(1).then((McpResult r) {
				presented ~= r.text.jsonParse!QuestionResult;
				b.onToolCallDelivered("1", r);
			}).ignoreResult();
			drainPromiseNextTicks();
		}
		assert(presented.length == 2 && presented[1].tid == 2);
		auto qid = presented[1].qid;
		McpResult refused, answered;
		b.handleAsk("1", "parent follow-up", 2).then((McpResult r) {
			refused = r;
		}).ignoreResult();
		drainPromiseNextTicks();
		assert(refused.isError && refused.text.canFind(format!"qid=%d"(qid)));
		b.handleAnswer("1", qid, "parent answer").then((McpResult r) {
			answered = r;
		}).ignoreResult();
		drainPromiseNextTicks();
		assert(!answered.isError && answered.text.jsonParse!AnswerResult.status == "delivered");
		assert(!childAnswer.isError && childAnswer.text.jsonParse!AnswerResult.message == "parent answer");
	}
}

version (unittest)
private final class PermissionQueueTest
{
	enum tid = 1;

	TaskData task;
	WorkflowToolsBackend backend;
	string[] shown;
	const(PermissionPrompt)[] prompts;
	string policy = "ask";
	SysTime[] deadlines;
	int clears;
	string[string] decisions;

	this(Duration timeout = Duration.zero, bool enqueueExamples = true)
	{
		task = TaskData(tid, "local", "/tmp/project");
		task.agentName = "claude";
		WorkflowToolsHost host;
		host.getTask = (int id) {
			assert(id == tid);
			return &task;
		};
		host.permissionSettings = (string agentName, string workspaceName) =>
			PermissionSettings(policy, false, timeout);
		host.taskTypesForProject = (string projectPath) => TaskTypeDef[].init;
		host.entryPointsForProject = (string projectPath) => UserEntryPointDef[].init;
		host.sendPermissionPrompt = (int id, const PendingPermission pending) {
			assert(id == tid);
			shown ~= pending.prompt.toolUseId;
			prompts ~= pending.prompt;
			deadlines ~= pending.deadline;
		};
		host.clearPermissionPrompt = (int id) {
			assert(id == tid);
			clears++;
		};
		host.persistNeedsAttention = (int id, bool needsAttention) {};
		host.touchTask = (int id) {};
		host.persistLastActive = (int id, long lastActive) {};
		host.broadcastTaskUpdate = (int id) {};
		backend = new WorkflowToolsBackend(host);

		if (enqueueExamples)
			foreach (id; ["first", "second"])
				request(id);
	}

	private void request(string id)
	{
		auto prompt = PermissionPrompt(id, "Bash", JSONFragment(toJson([
			"command": "echo " ~ id,
		])), "");
		backend.decideToolPermission(tid, prompt, PermissionEscalation.policyAsk)
			.then((string decision) { decisions[id] = decision; });
	}

	void respond(string id, string content = `{"behavior":"allow"}`)
	{
		WsMessage response;
		response.type = "permission_prompt_response";
		response.tid = tid;
		response.tool_use_id = id;
		response.content = JSONFragment(toJson(content));
		backend.handlePermissionPromptResponse(response);
	}

	string[] replay()
	{
		string[] ids;
		backend.replayPendingClientPrompts(tid, (string payload) {
			ids ~= jsonParse!PermissionPromptMessage(payload).tool_use_id;
		});
		return ids;
	}
}

unittest // Answering permission prompts advances the queue in FIFO order.
{
	import ae.net.asockets : socketManager;

	auto t = new PermissionQueueTest;
	socketManager.loop();
	assert(t.shown == ["first"]);
	assert(t.decisions.length == 0);

	t.respond("first");
	socketManager.loop();
	assert(t.shown == ["first", "second"]);
	assert(t.clears == 0);
	assert(t.decisions["first"] == makePermissionAllowJson(`{"command":"echo first"}`));
	assert(("second" in t.decisions) is null);

	t.respond("second", `{"behavior":"deny","message":"Second call denied"}`);
	socketManager.loop();
	assert(t.decisions["second"] == makePermissionDenyJson("Second call denied"));
	assert(t.clears == 1);
}

unittest // An answer for a queued prompt cannot settle either request.
{
	import ae.net.asockets : socketManager;

	auto t = new PermissionQueueTest;
	t.respond("second");
	socketManager.loop();
	assert(t.shown == ["first"]);
	assert(t.clears == 0);
	assert(t.decisions.length == 0);
}

unittest // Every permission response must identify the prompt it answers.
{
	import std.exception : assertThrown;

	auto t = new PermissionQueueTest;
	assertThrown(t.respond(""));
}

unittest // Withdrawing the queued request leaves the visible prompt in place.
{
	import ae.net.asockets : socketManager;

	auto t = new PermissionQueueTest;
	t.backend.withdrawToolPermissionPrompt(t.tid, "second");
	socketManager.loop();
	assert(t.shown == ["first"]);
	assert(t.clears == 0);
	assert(("first" in t.decisions) is null);
	assert(t.decisions["second"] == makePermissionDenyJson("Permission request withdrawn by the agent"));

	t.respond("first");
	assert(t.shown == ["first"]);
	assert(t.clears == 1);
}

unittest // Withdrawing the visible request shows the next prompt.
{
	import ae.net.asockets : socketManager;

	auto t = new PermissionQueueTest;
	t.backend.withdrawToolPermissionPrompt(t.tid, "first");
	socketManager.loop();
	assert(t.shown == ["first", "second"]);
	assert(t.clears == 0);
	assert(t.decisions["first"] == makePermissionDenyJson("Permission request withdrawn by the agent"));
	assert(("second" in t.decisions) is null);
}

unittest // Each prompt gets its full timeout once visible.
{
	import ae.net.asockets : socketManager;
	import core.time : MonoTime, msecs;
	import std.algorithm.searching : canFind;

	enum timeout = 50.msecs;
	auto started = MonoTime.currTime;
	auto t = new PermissionQueueTest(timeout);
	assert(t.shown == ["first"]);
	socketManager.loop();

	assert(t.shown == ["first", "second"]);
	assert(t.clears == 1);
	assert(t.deadlines[0] != SysTime.init);
	assert(t.deadlines[1] >= t.deadlines[0] + timeout);
	assert(MonoTime.currTime - started >= timeout * 2);
	foreach (id; t.shown)
	{
		assert(t.decisions[id].canFind(`"behavior":"deny"`));
		assert(t.decisions[id].canFind("nobody answered the permission prompt"));
	}
}

unittest // Reconnecting clients see only the current prompt.
{
	auto t = new PermissionQueueTest;
	assert(t.replay() == ["first"]);
	t.respond("first");
	assert(t.replay() == ["second"]);
}

unittest // Exit denies every queued request without showing another prompt.
{
	import ae.net.asockets : socketManager;

	auto t = new PermissionQueueTest;
	t.backend.failPendingPermissionPromptOnExit(t.tid);
	socketManager.loop();
	assert(t.shown == ["first"]);
	assert(t.replay().length == 0);
	assert(t.decisions["first"] == makePermissionDenyJson("Task exited"));
	assert(t.decisions["second"] == makePermissionDenyJson("Task exited"));
}

version (unittest)
private final class UnsandboxedCommandTest
{
	import std.file : mkdir, rmdirRecurse, tempDir;
	import std.path : buildPath;
	import std.process : environment;
	import std.uuid : randomUUID;

	PermissionQueueTest queue;
	string cwd;
	string previousShell;
	McpResult[string] results;

	this(Duration promptTimeout = Duration.zero)
	{
		queue = new PermissionQueueTest(promptTimeout, false);
		queue.task.unsandboxedCommandExecution = UnsandboxedCommandExecution.ask;
		cwd = buildPath(tempDir(), "cydo-unsandboxed-" ~ randomUUID().toString());
		mkdir(cwd);
		previousShell = environment.get("SHELL");
		environment["SHELL"] = "/bin/sh";
	}

	void cleanup()
	{
		if (previousShell is null)
			environment.remove("SHELL");
		else
			environment["SHELL"] = previousShell;
		rmdirRecurse(cwd);
	}

	void call(string id, string command = "printf ran > marker", int timeout = 5,
		ToolCallCancellation cancellation = null)
	{
		queue.backend.handleUnsandboxedCommand("1", command, cwd, timeout,
			cancellation is null ? new ToolCallCancellation : cancellation)
			.then((McpResult result) { results[id] = result; });
	}

	void assertDidNotRun()
	{
		import std.file : exists;

		assert(!exists(buildPath(cwd, "marker")));
	}
}

unittest // A task without access cannot prompt or execute.
{
	import ae.net.asockets : socketManager;
	import std.algorithm.searching : canFind;

	auto t = new UnsandboxedCommandTest;
	scope (exit) t.cleanup();
	t.queue.task.unsandboxedCommandExecution = UnsandboxedCommandExecution.no;
	t.call("disabled");
	socketManager.loop();
	assert(t.results["disabled"].isError);
	assert(t.results["disabled"].text.canFind("not available"));
	assert(t.queue.shown.length == 0);
	t.assertDidNotRun();
}

unittest // `yes` runs the command without a prompt.
{
	import ae.net.asockets : socketManager;
	import std.file : exists, readText;
	import std.path : buildPath;

	auto t = new UnsandboxedCommandTest;
	scope (exit) t.cleanup();
	t.queue.task.unsandboxedCommandExecution = UnsandboxedCommandExecution.yes;
	t.call("trusted");
	socketManager.loop();
	assert(t.queue.shown.length == 0);
	assert(!t.results["trusted"].isError, t.results["trusted"].text);
	assert(readText(buildPath(t.cwd, "marker")) == "ran");

	t.call("trusted-timeout", "printf partial; sleep 30", 1);
	socketManager.loop();
	assert(t.queue.shown.length == 0);
	assert(t.results["trusted-timeout"].isError);
}

unittest // Approval runs the exact command with the host environment, cwd and shell.
{
	import ae.net.asockets : socketManager;
	import std.file : chdir, getcwd;
	import std.json : parseJSON;
	import std.process : environment;

	auto t = new UnsandboxedCommandTest;
	scope (exit) t.cleanup();
	enum variable = "CYDO_UT_UNSANDBOXED_MARKER";
	auto previous = environment.get(variable);
	scope (exit)
	{
		if (previous is null)
			environment.remove(variable);
		else
			environment[variable] = previous;
	}
	environment[variable] = "host-marker";

	enum command = `printf '%s:%s:' "$CYDO_UT_UNSANDBOXED_MARKER" "$0"; pwd -P`;
	t.call("approved", command, 10);
	socketManager.loop();
	assert(t.results.length == 0);
	assert(t.queue.prompts.length == 1);
	auto prompt = t.queue.prompts[0];
	assert(prompt.toolName == "UnsandboxedCommand");
	assert(prompt.reason.length > 0);
	assert(parseJSON(prompt.input.json) == parseJSON(format(
		`{"command":%s,"cwd":%s,"timeout":10}`, toJson(command), toJson(t.cwd))));

	t.queue.respond(prompt.toolUseId);
	socketManager.loop();
	assert(!t.results["approved"].isError, t.results["approved"].text);
	auto originalCwd = getcwd();
	chdir(t.cwd);
	auto physicalCwd = getcwd();
	chdir(originalCwd);
	assert(t.results["approved"].text.strip == "host-marker:/bin/sh:" ~ physicalCwd);
}

unittest // An approved command can fail and still return its output.
{
	import ae.net.asockets : socketManager;

	auto t = new UnsandboxedCommandTest;
	scope (exit) t.cleanup();
	t.call("failed", "printf failure; exit 7");
	t.queue.respond(t.queue.shown[0]);
	socketManager.loop();
	assert(t.results["failed"].isError);
	assert(t.results["failed"].text == "failure");
}

unittest // Concurrent calls prompt in order and a denied call never runs.
{
	import ae.net.asockets : socketManager;
	import std.file : exists;
	import std.path : buildPath;

	auto t = new UnsandboxedCommandTest;
	scope (exit) t.cleanup();
	t.call("first");
	t.call("second", "printf ran > second-marker");
	socketManager.loop();
	assert(t.queue.shown.length == 1);
	assert(t.results.length == 0);

	auto first = t.queue.shown[0];
	t.queue.respond(first, `{"behavior":"deny","message":"Keep this on the sandbox"}`);
	socketManager.loop();
	assert(t.results["first"].isError);
	assert(t.results["first"].text == "Keep this on the sandbox");
	t.assertDidNotRun();
	assert(t.queue.shown.length == 2);
	assert(t.queue.shown[1] != first);
	assert(("second" in t.results) is null);
	assert(!exists(buildPath(t.cwd, "second-marker")));

	t.queue.respond(t.queue.shown[1]);
	socketManager.loop();
	assert(!t.results["second"].isError);
	assert(exists(buildPath(t.cwd, "second-marker")));
}

unittest // An unanswered prompt times out without running the command.
{
	import ae.net.asockets : socketManager;
	import core.time : msecs;
	import std.algorithm.searching : canFind;

	auto t = new UnsandboxedCommandTest(50.msecs);
	scope (exit) t.cleanup();
	t.call("expired");
	socketManager.loop();
	assert(t.queue.shown.length == 1);
	assert(t.queue.clears == 1);
	assert(t.results["expired"].isError);
	assert(t.results["expired"].text.canFind("nobody answered the permission prompt"));
	t.assertDidNotRun();
}

unittest // Invalid arguments and an invalid configured shell fail before prompting.
{
	import ae.net.asockets : socketManager;
	import std.algorithm.searching : canFind;
	import std.file : write;
	import std.path : buildPath;
	import std.process : environment;

	auto t = new UnsandboxedCommandTest;
	scope (exit) t.cleanup();
	auto file = buildPath(t.cwd, "file");
	write(file, "");
	void check(string command, string cwd, int timeout, string error)
	{
		McpResult[] results;
		t.queue.backend.handleUnsandboxedCommand("1", command, cwd, timeout,
			new ToolCallCancellation).then((McpResult result) { results ~= result; });
		socketManager.loop();
		assert(results.length == 1);
		assert(results[0].isError && results[0].text.canFind(error), results[0].text);
		assert(t.queue.shown.length == 0);
		t.assertDidNotRun();
	}
	foreach (cwd; ["relative", buildPath(t.cwd, "missing"), file, t.cwd ~ "\0ignored"])
		check("printf ran > marker", cwd, 5, "cwd");
	foreach (command; ["  ", "printf ran > marker\0ignored"])
		check(command, t.cwd, 5, "command");
	check("printf ran > marker", t.cwd, 0, "timeout");
	environment["SHELL"] = file;
	check("printf ran > marker", t.cwd, 5, "SHELL");
}

unittest // Shell resolution precedes prompting, and the approved call uses that shell.
{
	import ae.net.asockets : socketManager;
	import std.algorithm.searching : canFind;
	import std.process : environment;

	foreach (configured; [true, false])
	{
		auto t = new UnsandboxedCommandTest;
		scope (exit) t.cleanup();
		if (!configured)
			environment.remove("SHELL");
		bool lookedUpPasswd;
		McpResult[] results;
		enum command = `printf '%s' "$0"; printf ran > marker`;
		t.queue.backend.handleUnsandboxedCommand("1", command, t.cwd, 5,
			new ToolCallCancellation, () {
				lookedUpPasswd = true;
				return configured ? null : "/bin/sh";
			}).then((McpResult result) { results ~= result; });

		assert(lookedUpPasswd == !configured);
		assert(t.queue.shown.length == 1);
		assert(t.queue.prompts[$ - 1].reason.canFind("/bin/sh"));
		assert(results.length == 0);
		t.assertDidNotRun();
		t.queue.respond(t.queue.shown[$ - 1]);
		socketManager.loop();

		assert(results.length == 1);
		assert(!results[0].isError, results[0].text);
		assert(results[0].text == "/bin/sh");
	}
}

unittest // An absent SHELL and passwd login shell fail before prompting.
{
	import ae.net.asockets : socketManager;
	import std.algorithm.searching : canFind;
	import std.process : environment;

	auto t = new UnsandboxedCommandTest;
	scope (exit) t.cleanup();
	environment.remove("SHELL");

	bool lookedUpPasswd;
	McpResult[] results;
	t.queue.backend.handleUnsandboxedCommand("1", "printf ran > marker", t.cwd, 5,
		new ToolCallCancellation, () {
			lookedUpPasswd = true;
			return "";
		}).then((McpResult result) { results ~= result; });
	socketManager.loop();

	assert(lookedUpPasswd);
	assert(results.length == 1 && results[0].isError);
	assert(results[0].text.canFind("No shell from the user's passwd login shell"));
	assert(results[0].text.canFind("SHELL is unset or empty"));
	assert(t.queue.shown.length == 0);
	assert(t.queue.replay().length == 0);
	t.assertDidNotRun();
}

unittest // Cancelling the visible call clears its prompt without executing.
{
	import ae.net.asockets : socketManager;

	auto t = new UnsandboxedCommandTest;
	scope (exit) t.cleanup();
	auto token = new ToolCallCancellation;
	t.call("visible", "printf ran > marker", 5, token);
	assert(t.queue.shown.length == 1);
	token.cancel();
	socketManager.loop();
	assert(t.queue.clears == 1);
	assert(t.queue.replay().length == 0);
	assert(t.results["visible"].isError);
	assert(t.results["visible"].text == "Cancelled by the agent");
	t.assertDidNotRun();
}

unittest // Cancelling a queued call leaves the visible request in place.
{
	import ae.net.asockets : socketManager;

	auto t = new UnsandboxedCommandTest;
	scope (exit) t.cleanup();
	t.call("visible");
	auto token = new ToolCallCancellation;
	t.call("queued", "printf ran > marker", 5, token);
	token.cancel();
	socketManager.loop();
	assert(t.queue.shown.length == 1);
	assert(t.queue.replay() == t.queue.shown);
	assert(t.queue.clears == 0);
	assert(("visible" in t.results) is null);
	assert(t.results["queued"].isError);
	assert(t.results["queued"].text == "Cancelled by the agent");

	t.queue.respond(t.queue.shown[0], `{"behavior":"deny","message":"Denied"}`);
	socketManager.loop();
	assert(t.queue.shown.length == 1);
	assert(t.queue.clears == 1);
	t.assertDidNotRun();
}

unittest // A call that arrives already cancelled never prompts or executes.
{
	import ae.net.asockets : socketManager;

	auto t = new UnsandboxedCommandTest;
	scope (exit) t.cleanup();
	auto token = new ToolCallCancellation;
	token.cancel();
	t.call("cancelled", "printf ran > marker", 5, token);
	socketManager.loop();
	assert(t.queue.shown.length == 0);
	assert(t.results["cancelled"].isError);
	assert(t.results["cancelled"].text == "Cancelled by the agent");
	t.assertDidNotRun();
}

unittest // Cancellation after approval is dequeued prevents the deferred spawn.
{
	import ae.net.asockets : socketManager;

	auto t = new UnsandboxedCommandTest;
	scope (exit) t.cleanup();
	auto token = new ToolCallCancellation;
	t.call("approved", "printf ran > marker", 5, token);
	t.queue.respond(t.queue.shown[0]);
	assert(t.queue.clears == 1);
	assert(t.queue.replay().length == 0);
	assert(t.results.length == 0);

	token.cancel();
	socketManager.loop();

	t.assertDidNotRun();
	assert(t.results["approved"].isError);
	assert(t.results["approved"].text == "Cancelled by the agent");
	assert(t.queue.backend.activeTerminals_.length == 0);
}

version (unittest)
private void checkUnsandboxedProcessGroup(void delegate(ToolCallCancellation) cancel = null)
{
	import ae.net.asockets : socketManager;
	import ae.sys.timing : setInterval;
	import core.stdc.errno : ENOENT, ESRCH;
	import core.sys.posix.signal : kill, SIGKILL;
	import core.thread : Thread;
	import core.time : MonoTime, msecs, seconds;
	import std.algorithm.searching : canFind;
	import std.conv : to;
	import std.file : exists, FileException, readText;
	import std.path : buildPath;
	import std.string : lastIndexOf;

	auto t = new UnsandboxedCommandTest;
	scope (exit) t.cleanup();
	auto token = new ToolCallCancellation;
	auto pidFile = buildPath(t.cwd, "child.pid");
	enum command = `
		printf 'partial\n'
		sleep 30 >/dev/null 2>&1 &
		printf '%s\n' "$!" > child.tmp
		mv child.tmp child.pid
		wait
	`;
	t.call("running", command, cancel ? 10 : 1, token);
	auto started = MonoTime.currTime;
	t.queue.respond(t.queue.shown[0]);

	TimerTask readiness;
	if (cancel)
	{
		readiness = setInterval({
			if (exists(pidFile))
			{
				readiness.cancel();
				cancel(token);
			}
			else if ("running" in t.results || MonoTime.currTime - started > 5.seconds)
				readiness.cancel();
		}, 10.msecs);
	}
	scope (exit) if (readiness !is null && readiness.isWaiting()) readiness.cancel();

	socketManager.loop();
	auto elapsed = MonoTime.currTime - started;

	auto settled = "running" in t.results;
	assert(exists(pidFile), "command never reported a child process: "
		~ (settled is null ? "no result within 5 s" : settled.text));
	auto pid = readText(pidFile).strip.to!int;
	assert(pid > 0);
	bool stopped()
	{
		try
		{
			auto stat = readText(format("/proc/%s/stat", pid));
			return stat[stat.lastIndexOf(") ") + 2] == 'Z';
		}
		catch (FileException e)
		{
			if (e.errno == ENOENT || e.errno == ESRCH)
				return true;
			throw e;
		}
	}
	scope (failure) if (!stopped()) kill(pid, SIGKILL);

	auto result = t.results["running"];
	assert(result.isError);
	assert(result.text.canFind("partial"), result.text);
	assert(result.text.canFind(cancel ? "cancelled by the agent" : "timed out after 1 s"), result.text);
	assert(result.text.canFind("process group killed"), result.text);
	assert(elapsed < 5.seconds);
	if (!cancel)
		assert(elapsed >= 1.seconds);

	auto deadline = MonoTime.currTime + 2.seconds;
	while (!stopped())
	{
		assert(MonoTime.currTime < deadline, "command's child is still running");
		Thread.sleep(10.msecs);
	}
}

unittest // Execution timeout returns partial output and kills the process group.
{
	checkUnsandboxedProcessGroup();
}

unittest // Cancellation during execution returns partial output and kills the process group.
{
	checkUnsandboxedProcessGroup((ToolCallCancellation token) { token.cancel(); });
}

unittest // A Claude policy denial happens before any permission prompt.
{
	auto t = new PermissionQueueTest(Duration.zero, false);
	t.policy = "deny";
	auto ruling = t.backend.decidePreToolUse(t.tid, "mcp__cydo__UnsandboxedCommand",
		JSONFragment(`{"command":"pwd","cwd":"/tmp","timeout":1}`));
	assert(ruling.decision == ToolCallDecision.deny);
	assert(t.shown.length == 0);
}

unittest // Only CyDo's exact MCP tool skips Claude's policy-ask control prompt.
{
	import ae.net.asockets : socketManager;

	auto t = new PermissionQueueTest(Duration.zero, false);
	t.task.unsandboxedCommandExecution = UnsandboxedCommandExecution.ask;
	enum tool = "mcp__cydo__UnsandboxedCommand";
	auto input = JSONFragment(`{"command":"pwd","cwd":"/tmp","timeout":1}`);
	assert(t.backend.decidePreToolUse(t.tid, tool, input).decision == ToolCallDecision.ask);

	string decision;
	t.backend.decideToolPermission(t.tid, PermissionPrompt("exact", tool, input, ""),
		PermissionEscalation.policyAsk).then((string answer) { decision = answer; });
	socketManager.loop();
	assert(decision == makePermissionAllowJson(input.json));
	assert(t.shown.length == 0);

	foreach (name; ["UnsandboxedCommand", "mcp__other__UnsandboxedCommand",
		"mcp__cydo__UnsandboxedCommandExtra"])
	{
		decision = null;
		t.backend.decideToolPermission(t.tid, PermissionPrompt(name, name, input, ""),
			PermissionEscalation.policyAsk).then((string answer) { decision = answer; });
		socketManager.loop();
		assert(decision is null);
		assert(t.shown[$ - 1] == name);
		t.respond(name, `{"behavior":"deny","message":"Denied"}`);
		socketManager.loop();
		assert(decision == makePermissionDenyJson("Denied"));
	}
}

unittest // Under `yes`, CyDo does not prompt, so Claude's policy-ask prompt stays.
{
	import ae.net.asockets : socketManager;

	auto t = new PermissionQueueTest(Duration.zero, false);
	t.task.unsandboxedCommandExecution = UnsandboxedCommandExecution.yes;
	enum tool = "mcp__cydo__UnsandboxedCommand";
	auto input = JSONFragment(`{"command":"pwd","cwd":"/tmp","timeout":1}`);
	string decision;
	t.backend.decideToolPermission(t.tid, PermissionPrompt("trusted", tool, input, ""),
		PermissionEscalation.policyAsk).then((string answer) { decision = answer; });
	socketManager.loop();
	assert(decision is null);
	assert(t.shown[$ - 1] == "trusted");
	t.respond("trusted", `{"behavior":"allow"}`);
	socketManager.loop();
	assert(decision == makePermissionAllowJson(input.json));
}

unittest // A Claude classifier referral for the CyDo tool still prompts.
{
	import ae.net.asockets : socketManager;

	auto t = new PermissionQueueTest(Duration.zero, false);
	string decision;
	auto prompt = PermissionPrompt("classifier", "mcp__cydo__UnsandboxedCommand",
		JSONFragment(`{"command":"pwd","cwd":"/tmp","timeout":1}`), "");
	t.backend.decideToolPermission(t.tid, prompt, PermissionEscalation.classifier)
		.then((string answer) { decision = answer; });
	socketManager.loop();
	assert(t.shown == ["classifier"]);
	assert(decision is null);
	t.respond("classifier", `{"behavior":"deny","message":"Denied"}`);
	socketManager.loop();
	assert(decision == makePermissionDenyJson("Denied"));
}
