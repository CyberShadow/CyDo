module cydo.workflow.tasks.subtask_delivery;

import std.array : join;
import std.conv : to;
import std.exception : enforce;
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
import cydo.workflow.workspace.worktree : worktreeBranchName, worktreeBranchTip;

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
		auto worktree = hasWorktree ? host_.worktreePath(td) : null;
		string branch;
		if (hasWorktree)
		{
			auto branchTip = worktreeBranchTip(td.repoPath, td.worktreeTid);
			if (branchTip !is null)
			{
				branch = worktreeBranchName(td.worktreeTid);
				if (exists(worktree))
				{
					auto head = execute(["git", "-C", worktree, "rev-parse", "--verify", "--quiet", "HEAD"]);
					enforce(head.status == 0 || head.status == 1,
						"Failed to resolve worktree HEAD for task " ~ to!string(tid) ~ ": " ~ head.output.strip);
					if (head.status != 0 || head.output.strip != branchTip)
						branch = null;
				}
			}
		}
		bool isFailed = td.status == "failed";
		auto summary = td.resultText;
		auto talkNote = " Use mcp__cydo__Ask(question, " ~ to!string(tid) ~ ") to ask follow-up questions.";
		string note;
		if (hasOutput && hasWorktree)
			note = "Read the output file for full findings. The worktree path is included for adopting changes"
				~ (branch is null ? "." : "; its work is on branch `" ~ branch ~ "`.")
				~ talkNote;
		else if (hasOutput)
			note = "Read the output file for full findings." ~ talkNote;
		else if (hasWorktree)
			note = "The worktree contains the implementation"
				~ (branch is null ? "." : ", on branch `" ~ branch ~ "`.")
				~ talkNote;

		auto result = TaskResult(
			summary: summary,
			output_file: hasOutput ? tdOut : null,
			worktree: worktree,
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
				auto logResult = execute(["git", "-C", worktree,
					"log", "--format=%H", td.taskStartHead ~ "..HEAD"]);
				assert(logResult.status == 0,
					"Failed to collect commits for task " ~ to!string(tid)
					~ " (git status " ~ to!string(logResult.status) ~ "): "
					~ logResult.output.strip);
				if (logResult.output.strip.length > 0)
					result.commits = logResult.output.strip.splitLines;
				if (result.commits.length > 0)
					note = (branch is null ? "Cherry-pick commits from the worktree: git cherry-pick "
						: "The commits are on branch `" ~ branch ~ "` in the worktree. To cherry-pick them: git cherry-pick ")
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
	auto cherryPick = "git cherry-pick " ~ firstCommit ~ " " ~ secondCommit;
	auto talkNote = " Use mcp__cydo__Ask(question, 2) to ask follow-up questions.";
	assert(result.commits == [secondCommit, firstCommit]);
	assert(result.note == "Cherry-pick commits from the worktree: " ~ cherryPick ~ talkNote);

	auto branch = execute(["git", "-C", repo, "branch", "cydo/2"]);
	assert(branch.status == 0, branch.output);
	result = delivery.buildTaskResult(2);
	assert(result.commits == [secondCommit, firstCommit]);
	assert(result.note == "The commits are on branch `cydo/2` in the worktree. To cherry-pick them: "
		~ cherryPick ~ talkNote);

	auto detach = execute(["git", "-C", repo, "switch", "--detach"]);
	assert(detach.status == 0, detach.output);
	auto commit = execute(["git", "-C", repo, "commit", "--allow-empty", "-qm", "detached work"]);
	assert(commit.status == 0, commit.output);
	auto detachedCommit = execute(["git", "-C", repo, "rev-parse", "HEAD"]).output.strip;

	result = delivery.buildTaskResult(2);
	assert(result.commits == [detachedCommit, secondCommit, firstCommit]);
	assert(result.note == "Cherry-pick commits from the worktree: "
		~ cherryPick ~ " " ~ detachedCommit ~ talkNote);
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
	import std.path : buildPath;

	auto repo = buildPath(tempDir(), "cydo-subtask-delivery-report");
	if (exists(repo))
		rmdirRecurse(repo);
	mkdirRecurse(repo);
	scope(exit) rmdirRecurse(repo);

	auto init = execute(["git", "-C", repo, "init", "-q"]);
	assert(init.status == 0, init.output);
	auto commit = execute(["git", "-C", repo, "-c", "user.name=Test",
		"-c", "user.email=test@test", "commit", "--allow-empty", "-qm", "base"]);
	assert(commit.status == 0, commit.output);
	auto output = buildPath(repo, "report.md");
	write(output, "findings");

	auto task = TaskData(2, "local", repo);
	task.taskType = "report";
	task.worktreeTid = 2;
	auto delivery = new SubtaskResultDelivery(SubtaskResultDeliveryHost(
		getTask: (int tid) => tid == task.tid ? &task : null,
		outputPath: (const TaskData* td) => output,
		worktreePath: (const TaskData* td) => repo,
		taskProducesCommitOutput: (string projectPath, string taskType) => false,
	));

	auto note = "Read the output file for full findings. The worktree path is included for adopting changes";
	auto talkNote = " Use mcp__cydo__Ask(question, 2) to ask follow-up questions.";
	assert(delivery.buildTaskResult(2).note == note ~ "." ~ talkNote);

	auto branch = execute(["git", "-C", repo, "branch", "cydo/2"]);
	assert(branch.status == 0, branch.output);
	assert(delivery.buildTaskResult(2).note == note ~ "; its work is on branch `cydo/2`." ~ talkNote);
}

unittest
{
	import std.algorithm.searching : canFind;
	import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
	import std.path : buildPath;

	auto repo = buildPath(tempDir(), "cydo-legacy-subtask");
	if (exists(repo))
		rmdirRecurse(repo);
	mkdirRecurse(repo);
	scope(exit) rmdirRecurse(repo);
	auto init = execute(["git", "-C", repo, "init", "-q"]);
	assert(init.status == 0, init.output);

	auto output = buildPath(repo, "output.md");
	write(output, "legacy output");
	TaskData[int] tasks;
	tasks[2] = TaskData(2, "local", repo);
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
		worktreePath: (const TaskData* td) => repo,
		taskProducesCommitOutput: (string projectPath, string taskType) => true,
	));

	auto result = delivery.buildTaskResult(2);
	assert(result.commits == ["(not available - check git log)"]);
	assert(result.note.canFind("pre-upgrade task"));
	assert(!result.note.canFind("git cherry-pick"));
	assert(result.summary == "legacy summary");
	assert(result.output_file == output);
	assert(result.worktree == repo);
}
