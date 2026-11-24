module cydo.workflow.tasks.subtask_delivery;

import std.array : join;
import std.conv : to;
import std.file : exists;
import std.logger : warningf;
import std.process : execute;
import std.range : retro;
import std.string : splitLines, strip;

import ae.utils.promise : Promise, resolve;

import cydo.domain.tasks.model : TaskData, TaskStatus;
import cydo.domain.tasks.lifecycle : TaskNotificationChange;
import cydo.foundation.system.known_messages : KnownSystemMessageKind;
import cydo.mcp.payloads : TaskResult;

package(cydo):

string renderBatchResults(string[] resultJsons)
{
	auto resultsArray = "[" ~ resultJsons.join(",") ~ "]";
	return "A Task batch completed. Its results are below.\n\n"
		~ "<task_results>\n" ~ resultsArray ~ "\n</task_results>\n\n"
		~ "Continue your work using these results, as you would with a Task tool result.";
}

struct SubtaskResultDeliveryHost
{
	TaskData* delegate(int tid) getTask;
	string delegate(const TaskData* td) outputPath;
	string delegate(const TaskData* td) worktreePath;
	bool delegate(string projectPath, string taskTypeName) taskProducesCommitOutput;
	void delegate(int tid, TaskStatus expectedFrom, TaskStatus to,
		TaskNotificationChange notification) transitionTask;
	Promise!void delegate(int tid, KnownSystemMessageKind kind, string body) sendKnownSystemMessage;
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

	Promise!void sendSystemRestartNudge(int tid, bool retryToolCall)
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

			auto nudgeBody = "Your session was interrupted by a harness restart. "
				~ "Continue from where you left off. "
				~ (retryToolCall
					? "If you had a tool call in progress (Task, Handoff, SwitchMode, or any other tool), retry it. "
					: "Your recorded CyDo work is still in progress or awaiting delivery. ")
				~ "Background commands and monitors you had started are gone and will not report: "
				~ "start again the ones you still need.";
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

	TaskResult taskResult(int tid)
	{
		return buildTaskResult(tid);
	}

	void recoveryDeliveryFailed(int tid, Exception error)
	{
		handleRecoveryDeliveryFailure(tid, error);
	}

private:
	// A failed child can only have produced artifacts after native session
	// initialization. A process that exits before init has no session ID.
	bool hasArtifactPaths(const TaskData* task)
	{
		return task.status != TaskStatus.failed || task.agentSessionId.length > 0;
	}

	TaskResult buildTaskResult(int tid)
	{
		auto td = requireTask(tid, "Task must exist when building sub-task result");
		if (!hasArtifactPaths(td))
			return TaskResult(tid: tid, summary: td.resultText, error: td.resultText,
				status: "error");

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
	tasks[2].status = TaskStatus.failed;
	tasks[2].agentSessionId = "initialized-session";

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
