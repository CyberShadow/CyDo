module cydo.workflow.workspace.worktree_allocator;

import std.file : exists, mkdirRecurse;
import std.format : format;
import std.logger : errorf, infof;
import std.process : execute;

import cydo.domain.task_types.definition : WorktreeMode;
import cydo.domain.tasks.model : TaskData, worktreePathForTaskDir;

package(cydo):

struct WorktreeAllocatorHost
{
	TaskData* delegate(int tid) getTask;
	void delegate(int tid, int worktreeTid) persistWorktreeTid;
	int delegate(int tid) findRootTid;
	string delegate(const TaskData* td) taskDir;
	string delegate(const TaskData* td) worktreePath;
}

class WorktreeAllocator
{
	private WorktreeAllocatorHost host_;

	this(WorktreeAllocatorHost host)
	{
		host_ = host;
	}

	void setupForEdge(int childTid, int parentTid, WorktreeMode mode)
	{
		final switch (mode)
		{
			case WorktreeMode.inherit:
				setupInherit(childTid, parentTid);
				break;
			case WorktreeMode.require:
				setupRequire(childTid, parentTid);
				break;
			case WorktreeMode.fork:
				setupFork(childTid, parentTid);
				break;
		}
	}

private:
	void setTaskWorktreeTid(int tid, int worktreeTid)
	{
		auto td = host_.getTask(tid);
		if (td is null)
			throw new Exception(format!"Task %d not found while setting worktree owner %d"(
				tid, worktreeTid));
		td.worktreeTid = worktreeTid;
		host_.persistWorktreeTid(tid, worktreeTid);
	}

	void setupInherit(int childTid, int parentTid)
	{
		auto parentTd = host_.getTask(parentTid);
		if (parentTd is null || parentTd.worktreeTid <= 0)
			return;
		setTaskWorktreeTid(childTid, parentTd.worktreeTid);
	}

	void setupRequire(int childTid, int parentTid)
	{
		int current = parentTid;
		while (current > 0)
		{
			auto ancestorTd = host_.getTask(current);
			if (ancestorTd is null)
				break;
			if (ancestorTd.worktreeTid > 0)
			{
				setTaskWorktreeTid(childTid, ancestorTd.worktreeTid);
				return;
			}
			current = ancestorTd.parentTid;
		}

		int rootTid = host_.findRootTid(childTid);
		auto rootTd = host_.getTask(rootTid);
		if (rootTd is null)
			throw new Exception(format!"Root task %d not found while creating required worktree for task %d"(
				rootTid, childTid));

		auto rootTaskDir = host_.taskDir(rootTd);
		auto wtPath = worktreePathForTaskDir(rootTaskDir);
		if (!exists(wtPath))
		{
			mkdirRecurse(rootTaskDir);
			auto workDir = rootTd.projectPath.length > 0 ? rootTd.projectPath : null;
			auto gitResult = execute(["git", "-C", workDir, "worktree", "add", "--detach", wtPath]);
			if (gitResult.status != 0)
			{
				errorf("Failed to create worktree for require at root task %d: %s",
					rootTid, gitResult.output);
				return;
			}
			infof("Created shared worktree at root task %d: %s", rootTid, wtPath);
		}
		setTaskWorktreeTid(childTid, rootTid);
	}

	void setupFork(int childTid, int parentTid)
	{
		auto td = host_.getTask(childTid);
		if (td is null)
			throw new Exception(format!"Task %d not found while creating fork worktree"(
				childTid));
		if (td.worktreeTid > 0)
			return;

		auto childTaskDir = host_.taskDir(td);
		mkdirRecurse(childTaskDir);
		auto wtPath = worktreePathForTaskDir(childTaskDir);

		auto parentTd = host_.getTask(parentTid);
		string baseFrom;
		if (parentTd !is null && parentTd.worktreeTid > 0)
			baseFrom = host_.worktreePath(parentTd);
		auto workDir = baseFrom.length > 0 ? baseFrom
			: (td.projectPath.length > 0 ? td.projectPath : null);

		auto gitResult = execute(["git", "-C", workDir, "worktree", "add", "--detach", wtPath]);
		if (gitResult.status == 0)
		{
			setTaskWorktreeTid(childTid, childTid);
			infof("Created fork worktree for task %d: %s", childTid, wtPath);
		}
		else
			errorf("Failed to create fork worktree for task %d: %s", childTid, gitResult.output);
	}
}

version(unittest)
{
	private int findRootTid(TaskData[int] tasks, int tid)
	{
		int current = tid;
		while (true)
		{
			auto td = current in tasks;
			if (td is null || td.parentTid <= 0)
				return current;
			current = td.parentTid;
		}
	}

	private string setupWorktreeAllocatorTestRepo(string name)
	{
		import std.file : exists, mkdirRecurse, rmdirRecurse, write;
		import std.path : buildPath;
		import std.process : execute;

		auto repoDir = buildPath("/tmp", name);
		if (exists(repoDir))
			rmdirRecurse(repoDir);
		mkdirRecurse(repoDir);
		execute(["git", "-C", repoDir, "init", "-q"]);
		execute(["git", "-C", repoDir, "config", "user.email", "test@test"]);
		execute(["git", "-C", repoDir, "config", "user.name", "Test"]);
		write(buildPath(repoDir, "README.md"), "initial\n");
		execute(["git", "-C", repoDir, "add", "."]);
		execute(["git", "-C", repoDir, "commit", "-qm", "init"]);
		return repoDir;
	}

	private TaskData* getTaskFromMap(TaskData[int]* tasks, int tid)
	{
		auto td = tid in *tasks;
		return td is null ? null : &(*tasks)[tid];
	}
}

unittest
{
	import std.file : exists, rmdirRecurse;
	import std.path : buildPath;

	TaskData[int] tasks;
	int[int] persisted;

	auto repoDir = setupWorktreeAllocatorTestRepo("cydo-worktree-allocator-require-root");
	scope(exit)
	{
		if (exists(repoDir))
			rmdirRecurse(repoDir);
	}

	auto scratchDir = buildPath("/tmp", "cydo-worktree-allocator-require-root-tasks");
	scope(exit)
	{
		if (exists(scratchDir))
			rmdirRecurse(scratchDir);
	}
	if (exists(scratchDir))
		rmdirRecurse(scratchDir);

	tasks[1] = TaskData(1, "ws", repoDir);
	tasks[2] = TaskData(2, "ws", repoDir);
	tasks[2].parentTid = 1;

	auto allocator = new WorktreeAllocator(WorktreeAllocatorHost(
		getTask: (int tid) => getTaskFromMap(&tasks, tid),
		persistWorktreeTid: (int tid, int worktreeTid) {
			persisted[tid] = worktreeTid;
		},
		findRootTid: (int tid) => findRootTid(tasks, tid),
		taskDir: (const TaskData* td) => buildPath(scratchDir, format!"task-%d"(td.tid)),
		worktreePath: (const TaskData* td) => buildPath(scratchDir, format!"task-%d"(td.tid), "worktree"),
	));

	allocator.setupForEdge(2, 1, WorktreeMode.require);

	assert(tasks[1].worktreeTid == 0);
	assert(tasks[2].worktreeTid == 1);
	assert(1 !in persisted);
	assert(persisted[2] == 1);
	assert(exists(buildPath(scratchDir, "task-1", "worktree")));
}
