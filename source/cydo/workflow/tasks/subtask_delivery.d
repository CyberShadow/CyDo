module cydo.workflow.tasks.subtask_delivery;

import std.array : join;
import std.conv : to;
import std.file : exists;
import std.logger : errorf, infof, tracef, warningf;
import std.process : execute;
import std.range : retro;
import std.string : splitLines, strip;

import ae.utils.json : toJson;
import ae.utils.promise : Promise, reject, resolve;

import cydo.domain.tasks.model : TaskData, TaskStatus;
import cydo.domain.tasks.lifecycle : TaskNotificationChange;
import cydo.foundation.system.known_messages : KnownSystemMessageKind;
import cydo.mcp : McpResult;
import cydo.mcp.payloads : TaskResult;

package(cydo):

struct SubtaskResultDeliveryHost
{
	TaskData* delegate(int tid) getTask;
	string delegate(const TaskData* td) outputPath;
	string delegate(const TaskData* td) worktreePath;
	bool delegate(string projectPath, string taskTypeName) taskProducesCommitOutput;
	void delegate(int tid, TaskStatus expectedFrom, TaskStatus to,
		TaskNotificationChange notification) transitionTask;
	void delegate(int tid, TaskStatus[] expectedFrom, TaskStatus to,
		TaskNotificationChange notification) transitionTaskFrom;
	void delegate(int tid, string resultText) persistResultText;
	bool delegate(int tid, out Promise!(McpResult) pending) readPendingSubTask;
	void delegate(int tid) clearPendingSubTask;
	int delegate(int childTid) parentTaskForChild;
	int[] delegate(int parentTid) childTaskIds;
	bool delegate(int childTid) wasLiveDelivered;
	void delegate(int childTid) markLiveDelivered;
	Promise!void delegate(int tid) ensureProcessQueueAlive;
	bool delegate(int tid, out string sessionState) canSendSystemMessage;
	Promise!void delegate(int tid, KnownSystemMessageKind kind, string body) sendKnownSystemMessage;
	void delegate(int parentTid, int childTid) removeTaskDependency;
	bool delegate(int tid) taskAlive;
	void delegate(void delegate() cb) onNextTick;
	void delegate(int tid, string subject, string body)
		appendAndBroadcastRecoveryDeliveryDiagnostic;
}

class SubtaskResultDelivery
{
private:
	SubtaskResultDeliveryHost host_;

public:
	this(SubtaskResultDeliveryHost host)
	{
		host_ = host;
	}

	bool finalizeCompletedSubTask(int childTid, bool eagerDepCleanup = false)
	{
		import ae.utils.json : toJson;

		auto td = host_.getTask(childTid);
		if (td is null)
			return false;

		host_.persistResultText(childTid, td.resultText);
		host_.transitionTaskFrom(childTid,
			[TaskStatus.active, TaskStatus.alive, TaskStatus.waiting],
			TaskStatus.completed, TaskNotificationChange.preserve);

		Promise!(McpResult) pending;
		if (!host_.readPendingSubTask(childTid, pending))
			return false;

		auto taskResult = buildTaskResult(childTid);
		auto resultJson = toJson(taskResult);
		pending.fulfill(McpResult.structured(resultJson));
		host_.clearPendingSubTask(childTid);

		// Early result delivery can race onExit for agents with synchronous stdin
		// close. Record this child so onExit does not trigger duplicate fallback.
		if (eagerDepCleanup)
			host_.markLiveDelivered(childTid);

		return true;
	}

	bool deliverFailedPendingSubTaskResult(int tid)
	{
		import ae.utils.json : toJson;

		Promise!(McpResult) pending;
		if (!host_.readPendingSubTask(tid, pending))
			return false;

		auto taskResult = buildTaskResult(tid);
		auto resultJson = toJson(taskResult);
		pending.fulfill(McpResult.structured(resultJson, true));
		host_.clearPendingSubTask(tid);
		return true;
	}

	Promise!void deliverWaitingParentResultsIfReady(int tid)
	{
		auto parentTid = host_.parentTaskForChild(tid);
		if (parentTid <= 0)
			return resolve();

		if (host_.wasLiveDelivered(tid))
		{
			tracef("onExit Branch B: child tid=%d already delivered to live batch, skipping fallback",
				tid);
			return resolve();
		}

		auto td = requireTask(tid, "Completed child task must exist while delivering parent fallback results");
		tracef("onExit Branch B: child tid=%d (status=%s) finished, parent tid=%d",
			tid, td.status, parentTid);

		if (host_.getTask(parentTid) is null)
		{
			tracef("onExit Branch B: parent tid=%d not in tasks", parentTid);
			return resolve();
		}

		foreach (childTid; host_.childTaskIds(parentTid))
		{
			auto child = host_.getTask(childTid);
			if (child !is null
				&& child.status != "completed"
				&& child.status != "failed")
			{
				tracef("onExit Branch B: sibling tid=%d still %s, deferring batch delivery",
					childTid, child.status);
				return resolve();
			}
		}

		return deliverBatchResults(parentTid);
	}

	Promise!void deliverBatchFallbackIfReady(int parentTid)
	{
		if (host_.getTask(parentTid) is null)
			return resolve();

		auto children = host_.childTaskIds(parentTid);
		if (children.length == 0)
			return resolve();

		foreach (childTid; children)
		{
			auto child = host_.getTask(childTid);
			if (child !is null
				&& child.status != "completed"
				&& child.status != "failed")
				return resolve();
		}

		return deliverBatchResults(parentTid);
	}

	Promise!void deliverBatchResults(int parentTid)
	{
		if (host_.getTask(parentTid) is null)
			return resolve();

		try
			return host_.ensureProcessQueueAlive(parentTid).then(() {
				return actuallyDeliverBatchResults(parentTid);
			});
		catch (Exception e)
			return reject!void(e);
	}

	Promise!void sendSystemRestartNudge(int tid)
	{
		if (host_.getTask(tid) is null)
			return resolve();

		auto attempt = new Promise!void;
		host_.onNextTick(() {
			if (host_.getTask(tid) is null)
			{
				attempt.fulfill();
				return;
			}
			if (!host_.taskAlive(tid))
			{
				attempt.fulfill();
				return;
			}

			enum nudgeBody = "Your session was interrupted by a harness restart. "
				~ "Continue from where you left off. If you had a tool call in progress "
				~ "(Task, Handoff, SwitchMode, or any other tool), retry it. "
				~ "Background work (shells, subagents, watchers) did not survive the "
				~ "restart: check on anything you had running and relaunch what is "
				~ "still needed before ending your turn.";
			try
			{
				host_.sendKnownSystemMessage(tid, KnownSystemMessageKind.restartNudge,
					nudgeBody).then(() {
					attempt.fulfill();
				}, (Exception e) {
					handleRecoveryDeliveryFailure(tid, e);
					attempt.fulfill();
				}).ignoreResult();
			}
			catch (Exception e)
			{
				handleRecoveryDeliveryFailure(tid, e);
				attempt.fulfill();
			}
		});
		return attempt;
	}

private:
	TaskResult buildTaskResult(int tid)
	{
		auto td = requireTask(tid, "Task must exist when building sub-task result");
		auto tdOut = host_.outputPath(td);
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
			worktree: hasWorktree ? host_.worktreePath(td) : null,
			note: note.length > 0 ? note : td.resultNote,
			error: isFailed ? summary : null,
			status: isFailed ? "error" : "success",
		);
		result.tid = tid;

		if (host_.taskProducesCommitOutput(td.projectPath, td.taskType) && td.hasWorktree)
		{
			if (td.taskStartHead.length == 0)
			{
				warningf("Task %d has no task start HEAD; commit list is unavailable for pre-upgrade task", tid);
				result.commits = ["(not available - check git log)"];
				note = "The commit list is unavailable for this pre-upgrade task. Check git log in the worktree." ~ talkNote;
			}
			else
			{
				auto logResult = execute(["git", "-C", host_.worktreePath(td),
					"log", "--format=%H", td.taskStartHead ~ "..HEAD"]);
				assert(logResult.status == 0,
					"Failed to collect commits for task " ~ to!string(tid)
					~ " (git status " ~ to!string(logResult.status) ~ "): "
					~ logResult.output.strip);
				if (logResult.output.strip.length > 0)
					result.commits = logResult.output.strip.splitLines;
				if (result.commits.length > 0)
					note = "Cherry-pick commits from the worktree: git cherry-pick "
						~ result.commits.retro.join(" ") ~ talkNote;
			}
			result.note = note.length > 0 ? note : td.resultNote;
		}

		return result;
	}

	Promise!void actuallyDeliverBatchResults(int parentTid)
	{
		import ae.utils.json : toJson;

		if (host_.getTask(parentTid) is null)
		{
			tracef("deliverBatchResults: parent tid=%d not in tasks, skipping", parentTid);
			return resolve();
		}

		string sessionState;
		if (!host_.canSendSystemMessage(parentTid, sessionState))
		{
			warningf("actuallyDeliverBatchResults: parent tid=%d session %s, retrying via deliverBatchResults",
				parentTid, sessionState);
			return deliverBatchResults(parentTid);
		}

		auto children = host_.childTaskIds(parentTid);
		if (children.length == 0)
		{
			tracef("deliverBatchResults: parent tid=%d has no children in taskDeps", parentTid);
			return resolve();
		}

		string[] resultJsons;
		foreach (childTid; children)
		{
			if (host_.getTask(childTid) is null)
				continue;
			resultJsons ~= toJson(buildTaskResult(childTid));
		}

		if (resultJsons.length == 0)
			return resolve();

		infof("deliverBatchResults: delivering %d result(s) to parent tid=%d",
			resultJsons.length, parentTid);

		auto resultsArray = "[" ~ resultJsons.join(",") ~ "]";
		auto body = "The following sub-task(s) completed while your session was interrupted. "
			~ "Their results are provided below exactly as they would have been "
			~ "returned by the Task tool.\n\n"
			~ "<task_results>\n" ~ resultsArray ~ "\n</task_results>\n\n"
			~ "Continue from where you left off. Process these results as if they "
			~ "were returned normally by the Task tool.";
		try
		{
			return host_.sendKnownSystemMessage(parentTid,
				KnownSystemMessageKind.subTaskResults, body).then(() {
				foreach (childTid; children)
					host_.removeTaskDependency(parentTid, childTid);
			}, (Exception e) {
				handleRecoveryDeliveryFailure(parentTid, e);
			});
		}
		catch (Exception e)
		{
			handleRecoveryDeliveryFailure(parentTid, e);
			return resolve();
		}
	}

	void handleRecoveryDeliveryFailure(int parentTid, Exception error)
	{
		auto parent = requireTask(parentTid,
			"Recovered delivery parent must exist when handling submission failure");
		if (parent.status == TaskStatus.failed)
			return;
		assert(parent.status == TaskStatus.waiting || parent.status == TaskStatus.active
			|| parent.status == TaskStatus.alive,
			"Recovered delivery failed outside waiting, active, or alive parent state");
		if (parent.status == TaskStatus.active)
			host_.transitionTask(parentTid, TaskStatus.active, TaskStatus.waiting,
				TaskNotificationChange.preserve);
		else if (parent.status == TaskStatus.alive)
			host_.transitionTask(parentTid, TaskStatus.alive, TaskStatus.waiting,
				TaskNotificationChange.preserve);
		parent.isProcessing = false;
		host_.appendAndBroadcastRecoveryDeliveryDiagnostic(parentTid,
			"Failed to deliver recovered sub-task results", error.msg);
	}

	TaskData* requireTask(int tid, string message)
	{
		auto td = host_.getTask(tid);
		assert(td !is null, message);
		return td;
	}
}

unittest
{
	import ae.net.asockets : socketManager;

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

	enum SubmissionFailure
	{
		none,
		synchronous,
		asynchronous,
	}

	struct DeliveryCase
	{
		string name;
		SubmissionFailure failure;
		TaskStatus initialParentStatus;
		bool initialParentProcessing;
		string failureMessage;
		bool ownerFailsBeforeRejection;
	}

	auto cases = [
		DeliveryCase(
			"gated submission commits recovered results after acceptance",
			SubmissionFailure.none,
			TaskStatus.waiting,
			false,
			"",
			false,
		),
		DeliveryCase(
			"synchronous submission rejection leaves the parent retryable",
			SubmissionFailure.synchronous,
			TaskStatus.waiting,
			true,
			"simulated synchronous submission rejection",
			false,
		),
		DeliveryCase(
			"asynchronous submission rejection restores the parent for retry",
			SubmissionFailure.asynchronous,
			TaskStatus.active,
			true,
			"simulated asynchronous submission rejection",
			false,
		),
		DeliveryCase(
			"already-failed parent receives no recovery duplicate",
			SubmissionFailure.asynchronous,
			TaskStatus.waiting,
			false,
			"simulated asynchronous submission rejection",
			true,
		),
	];

	foreach (test; cases)
	{
		TaskData[int] tasks;
		tasks[1] = TaskData(1, "local", "/tmp/cydo-recovery-delivery");
		tasks[1].status = test.initialParentStatus;
		tasks[1].isProcessing = test.initialParentProcessing;
		tasks[2] = TaskData(2, "local", "/tmp/cydo-recovery-delivery");
		tasks[2].status = TaskStatus.completed;
		tasks[2].resultText = "first recovered result";
		tasks[3] = TaskData(3, "local", "/tmp/cydo-recovery-delivery");
		tasks[3].status = TaskStatus.completed;
		tasks[3].resultText = "second recovered result";

		int[] dependencies = [2, 3];
		int[] removedChildren;
		size_t sendCalls;
		size_t activationCalls;
		size_t restoreWaitingCalls;
		size_t recoveryDiagnosticCalls;
		string[] diagnosticSubjects;
		string[] diagnosticBodies;
		auto submissionGate = new Promise!void;

		auto delivery = new SubtaskResultDelivery(SubtaskResultDeliveryHost(
			getTask: (int tid) {
				auto task = tid in tasks;
				return task is null ? null : task;
			},
			outputPath: (const TaskData* task) => "",
			worktreePath: (const TaskData* task) => "",
			taskProducesCommitOutput: (string projectPath, string taskType) => false,
			transitionTask: (int tid, TaskStatus expectedFrom, TaskStatus to,
				TaskNotificationChange notification) {
				assert(tid == 1, test.name);
				assert(tasks[tid].status == expectedFrom, test.name);
				if (expectedFrom == TaskStatus.active && to == TaskStatus.waiting)
					restoreWaitingCalls++;
				tasks[tid].status = to;
			},
			childTaskIds: (int parentTid) {
				assert(parentTid == 1, test.name);
				return dependencies;
			},
			ensureProcessQueueAlive: (int tid) {
				assert(tid == 1, test.name);
				return resolve();
			},
			canSendSystemMessage: (int tid, out string sessionState) {
				assert(tid == 1, test.name);
				sessionState = "";
				return true;
			},
			sendKnownSystemMessage: (int tid, KnownSystemMessageKind kind,
				string body) {
				assert(tid == 1, test.name);
				assert(kind == KnownSystemMessageKind.subTaskResults, test.name);
				sendCalls++;
				if (test.failure == SubmissionFailure.synchronous)
					throw new Exception(test.failureMessage);
				return submissionGate.then(() {
					assert(tasks[tid].status == TaskStatus.waiting, test.name);
					activationCalls++;
					tasks[tid].status = TaskStatus.active;
					tasks[tid].isProcessing = true;
				});
			},
			removeTaskDependency: (int parentTid, int childTid) {
				assert(parentTid == 1, test.name);
				removedChildren ~= childTid;
				foreach (i, dependency; dependencies)
					if (dependency == childTid)
					{
						dependencies = dependencies[0 .. i]
							~ dependencies[i + 1 .. $];
						return;
					}
				assert(false, test.name);
			},
			appendAndBroadcastRecoveryDeliveryDiagnostic:
				(int tid, string subject, string body) {
					assert(tid == 1, test.name);
					recoveryDiagnosticCalls++;
					diagnosticSubjects ~= subject;
					diagnosticBodies ~= body;
				},
		));

		bool deliverySettled;
		bool deliveryRejected;
		delivery.deliverBatchResults(1).then(() {
			deliverySettled = true;
		}, (Exception e) {
			deliveryRejected = true;
		}).ignoreResult();
		drainPromiseNextTicks();

		assert(sendCalls == 1, test.name);
		assert(deliverySettled
			== (test.failure == SubmissionFailure.synchronous), test.name);
		assert(!deliveryRejected, test.name);

		if (test.failure == SubmissionFailure.none)
		{
			assert(tasks[1].status == TaskStatus.waiting, test.name);
			assert(!tasks[1].isProcessing, test.name);
			assert(activationCalls == 0, test.name);
			assert(removedChildren.length == 0, test.name);
			assert(dependencies == [2, 3], test.name);

			submissionGate.fulfill();
			drainPromiseNextTicks();

			assert(tasks[1].status == TaskStatus.active, test.name);
			assert(tasks[1].isProcessing, test.name);
			assert(activationCalls == 1, test.name);
			assert(removedChildren == [2, 3], test.name);
			assert(dependencies.length == 0, test.name);
			assert(recoveryDiagnosticCalls == 0, test.name);
		}
		else
		{
			if (test.ownerFailsBeforeRejection)
			{
				tasks[1].status = TaskStatus.failed;
				tasks[1].resultText = "runner-owned failure";
			}
			if (test.failure == SubmissionFailure.asynchronous)
				submissionGate.reject(new Exception(test.failureMessage));
			drainPromiseNextTicks();

			assert(tasks[1].status == (test.ownerFailsBeforeRejection
				? TaskStatus.failed : TaskStatus.waiting), test.name);
			assert(!tasks[1].isProcessing, test.name);
			assert(activationCalls == 0, test.name);
			assert(removedChildren.length == 0, test.name);
			assert(dependencies == [2, 3], test.name);
			assert(recoveryDiagnosticCalls == (test.ownerFailsBeforeRejection ? 0 : 1),
				test.name);
			if (!test.ownerFailsBeforeRejection)
			{
				assert(diagnosticSubjects == ["Failed to deliver recovered sub-task results"],
					test.name);
				assert(diagnosticBodies == [test.failureMessage], test.name);
			}
			assert(restoreWaitingCalls
				== (test.failure == SubmissionFailure.asynchronous
					&& !test.ownerFailsBeforeRejection ? 1 : 0),
				test.name);
		}

		assert(deliverySettled && !deliveryRejected, test.name);
	}
}

unittest
{
	import std.algorithm.searching : canFind;
	import std.file : exists, mkdirRecurse, remove, rmdirRecurse, tempDir, write;
	import std.path : buildPath;
	import std.process : execute;
	import cydo.domain.storage.persistence : Persistence;

	auto repo = buildPath(tempDir(), "cydo-subtask-delivery-commit-range");
	if (exists(repo))
		rmdirRecurse(repo);
	mkdirRecurse(repo);
	scope(exit) rmdirRecurse(repo);

	execute(["git", "-C", repo, "init", "-q"]);
	execute(["git", "-C", repo, "config", "user.email", "test@test"]);
	execute(["git", "-C", repo, "config", "user.name", "Test"]);
	write(buildPath(repo, "work.txt"), "base\n");
	execute(["git", "-C", repo, "add", "work.txt"]);
	execute(["git", "-C", repo, "commit", "-qm", "base"]);
	auto taskStartHead = execute(["git", "-C", repo, "rev-parse", "HEAD"]).output.strip;
	auto dbPath = buildPath(tempDir(), "cydo-subtask-delivery-reload.sqlite");
	if (exists(dbPath)) remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);
	auto persistence = Persistence(dbPath);
	auto persistedTid = persistence.createTask();
	persistence.setTaskStartHead(persistedTid, taskStartHead);
	auto reloadedTaskStartHead = persistence.loadTasks()[0].taskStartHead;
	write(buildPath(repo, "work.txt"), "first\n");
	execute(["git", "-C", repo, "commit", "-am", "first", "-q"]);
	auto firstCommit = execute(["git", "-C", repo, "rev-parse", "HEAD"]).output.strip;
	write(buildPath(repo, "work.txt"), "second\n");
	execute(["git", "-C", repo, "commit", "-am", "second", "-q"]);
	auto secondCommit = execute(["git", "-C", repo, "rev-parse", "HEAD"]).output.strip;

	TaskData[int] tasks;
	tasks[2] = TaskData(2, "local", repo);
	tasks[2].taskType = "implementation";
	tasks[2].worktreeTid = 2;
	tasks[2].taskStartHead = reloadedTaskStartHead;

	auto delivery = new SubtaskResultDelivery(SubtaskResultDeliveryHost(
		getTask: (int tid) {
			auto td = tid in tasks;
			return td is null ? null : td;
		},
		outputPath: (const TaskData* td) => "",
		worktreePath: (const TaskData* td) => repo,
		taskProducesCommitOutput: (string projectPath, string taskType) => true,
	));

	auto result = delivery.buildTaskResult(2);
	assert(result.commits == [secondCommit, firstCommit]);
	assert(result.note.canFind("git cherry-pick " ~ firstCommit ~ " " ~ secondCommit));
}

unittest
{
	import std.algorithm.searching : canFind;
	import std.file : remove, write;
	import std.path : buildPath;

	auto output = buildPath("/tmp", "cydo-legacy-subtask-output.md");
	write(output, "legacy output");
	scope(exit) remove(output);
	TaskData[int] tasks;
	tasks[2] = TaskData(2, "local", "/tmp/cydo-legacy-subtask");
	tasks[2].taskType = "implementation";
	tasks[2].worktreeTid = 2;
	tasks[2].resultText = "legacy summary";

	auto delivery = new SubtaskResultDelivery(SubtaskResultDeliveryHost(
		getTask: (int tid) {
			auto td = tid in tasks;
			return td is null ? null : td;
		},
		outputPath: (const TaskData* td) => output,
		worktreePath: (const TaskData* td) => "/tmp/cydo-legacy-subtask",
		taskProducesCommitOutput: (string projectPath, string taskType) => true,
	));

	auto result = delivery.buildTaskResult(2);
	assert(result.commits == ["(not available - check git log)"]);
	assert(result.note.canFind("pre-upgrade task"));
	assert(!result.note.canFind("git cherry-pick"));
	assert(result.summary == "legacy summary");
	assert(result.output_file == output);
	assert(result.worktree == "/tmp/cydo-legacy-subtask");
}
