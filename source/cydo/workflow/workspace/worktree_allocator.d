module cydo.workflow.workspace.worktree_allocator;

import std.file : exists, mkdirRecurse;
import std.format : format;
import std.logger : infof;

import cydo.domain.task_types.definition : TaskTypeDef, WorktreeMode, computeReachesRequiredWorktree;
import cydo.domain.tasks.model : TaskData, worktreePathForTaskDir;
import cydo.workflow.workspace.worktree : addWorktree;
import cydo.workflow.workspace.worktree_dedup : dedupWorktreeInBackground;

package(cydo):

string createWorktreeUnavailableReason(const TaskData* td, TaskTypeDef[] types)
{
	if (td.parentTid > 0)
		return "CreateWorktree is only available to top-level tasks";
	if (td.worktreeTid != 0)
		return "This task already has a worktree";
	if (!td.isGitCheckout)
		return "This task's project is not a Git checkout";
	if (!computeReachesRequiredWorktree(types).get(td.taskType, false))
		return "Task type '" ~ td.taskType ~ "' has no workflow that uses a worktree";
	return null;
}

struct WorktreeAllocatorHost
{
	TaskData* delegate(int tid) getTask;
	void delegate(int tid, int worktreeTid) persistWorktreeTid;
	int delegate(int tid) findRootTid;
	string delegate(const TaskData* td) taskDir;
	string delegate(const TaskData* td) worktreePath;
}

final class WorktreePreparationFailure : Exception
{
	this(Exception cause)
	{
		super(cause.msg, __FILE__, __LINE__, cause);
	}
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
		int ownerTid;
		try
		{
			final switch (mode)
			{
			case WorktreeMode.inherit:
				auto parent = host_.getTask(parentTid);
				ownerTid = parent is null ? 0 : parent.worktreeTid;
				break;
			case WorktreeMode.require:
				ownerTid = prepareRequiredWorktree(childTid, parentTid);
				break;
			case WorktreeMode.fork:
				ownerTid = prepareForkWorktree(childTid, parentTid);
				break;
			}
		}
		catch (Exception e)
			throw new WorktreePreparationFailure(e);

		if (ownerTid > 0)
		{
			auto child = host_.getTask(childTid);
			assert(child !is null, "Worktree assignment requires an existing child");
			host_.persistWorktreeTid(childTid, ownerTid);
			child.worktreeTid = ownerTid;
		}
	}

private:

	int prepareRequiredWorktree(int childTid, int parentTid)
	{
		int current = parentTid;
		while (current > 0)
		{
			auto ancestorTd = host_.getTask(current);
			if (ancestorTd is null)
				break;
			if (ancestorTd.worktreeTid > 0)
				return ancestorTd.worktreeTid;
			current = ancestorTd.parentTid;
		}

		int rootTid = host_.findRootTid(childTid);
		auto rootTd = host_.getTask(rootTid);
		assert(rootTd !is null, "Required worktree needs an existing root task");

		auto rootTaskDir = host_.taskDir(rootTd);
		auto wtPath = worktreePathForTaskDir(rootTaskDir);
		if (!exists(wtPath))
		{
			mkdirRecurse(rootTaskDir);
			auto workDir = rootTd.projectPath.length > 0 ? rootTd.projectPath : null;
			try
				addWorktree(workDir, rootTid, wtPath);
			catch (Exception e)
				throw new Exception(format!"Failed to create required worktree for root task %d: %s"(
					rootTid, e.msg), __FILE__, __LINE__, e);
			infof("Created shared worktree at root task %d: %s", rootTid, wtPath);
			dedupWorktreeInBackground(workDir, wtPath);
		}
		return rootTid;
	}

	int prepareForkWorktree(int childTid, int parentTid)
	{
		auto td = host_.getTask(childTid);
		assert(td !is null, "Fork worktree needs an existing child");
		if (td.worktreeTid > 0)
			return 0;

		auto childTaskDir = host_.taskDir(td);
		mkdirRecurse(childTaskDir);
		auto wtPath = worktreePathForTaskDir(childTaskDir);

		auto parentTd = host_.getTask(parentTid);
		string baseFrom;
		if (parentTd !is null && parentTd.worktreeTid > 0)
			baseFrom = host_.worktreePath(parentTd);
		auto workDir = baseFrom.length > 0 ? baseFrom
			: (td.projectPath.length > 0 ? td.projectPath : null);

		try
			addWorktree(workDir, childTid, wtPath);
		catch (Exception e)
			throw new Exception(format!"Failed to create fork worktree for task %d: %s"(
				childTid, e.msg), __FILE__, __LINE__, e);
		infof("Created fork worktree for task %d: %s", childTid, wtPath);
		dedupWorktreeInBackground(workDir, wtPath);
		return childTid;
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

version (unittest) private void testRequiredRootWorktree(bool adopt)
{
	import std.file : exists, rmdirRecurse;
	import std.process : execute;
	import std.string : strip;
	import std.path : buildPath;

	TaskData[int] tasks;
	int[int] persisted;

	auto name = adopt ? "cydo-worktree-allocator-adopt-root" : "cydo-worktree-allocator-create-root";
	auto repoDir = setupWorktreeAllocatorTestRepo(name);
	scope(exit)
	{
		if (exists(repoDir))
			rmdirRecurse(repoDir);
	}

	auto scratchDir = buildPath("/tmp", name ~ "-tasks");
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

	auto worktree = buildPath(scratchDir, "task-1", "worktree");
	if (adopt)
	{
		allocator.setupForEdge(2, 1, WorktreeMode.require);
		assert(tasks[1].worktreeTid == 0);
		assert(tasks[2].worktreeTid == 1);
		assert(1 !in persisted);
		assert(persisted[2] == 1);
		assert(exists(worktree));
	}

	allocator.setupForEdge(1, 0, WorktreeMode.require);
	assert(tasks[1].worktreeTid == 1);
	assert(persisted[1] == 1);
	assert(exists(worktree));
	auto branch = execute(["git", "-C", worktree, "rev-parse", "--abbrev-ref", "HEAD"]);
	assert(branch.status == 0, branch.output);
	assert(branch.output.strip == "cydo/1");
}

unittest
{
	testRequiredRootWorktree(true);
}

unittest
{
	testRequiredRootWorktree(false);
}

unittest
{
	import cydo.domain.task_types.definition : CreatableTaskDef;
	import std.file : mkdir, rmdirRecurse;

	auto repo = setupWorktreeAllocatorTestRepo("cydo-worktree-allocator-eligibility");
	scope(exit) rmdirRecurse(repo);
	auto nonGit = repo ~ "-non-git";
	mkdir(nonGit);
	scope(exit) rmdirRecurse(nonGit);

	auto types = [
		TaskTypeDef(name: "root", creatable_tasks: [
			CreatableTaskDef("child", "child", WorktreeMode.require),
		]),
		TaskTypeDef(name: "child"),
	];
	auto task = TaskData(1, "local", repo);
	task.taskType = "root";
	assert(createWorktreeUnavailableReason(&task, types) is null);
	task.parentTid = 2;
	assert(createWorktreeUnavailableReason(&task, types)
		== "CreateWorktree is only available to top-level tasks");
	task.parentTid = 0;
	task.worktreeTid = 1;
	assert(createWorktreeUnavailableReason(&task, types) == "This task already has a worktree");
	task.worktreeTid = 0;
	task.projectPath = nonGit;
	assert(createWorktreeUnavailableReason(&task, types) == "This task's project is not a Git checkout");
	task.projectPath = repo;
	task.taskType = "child";
	assert(createWorktreeUnavailableReason(&task, types)
		== "Task type 'child' has no workflow that uses a worktree");
}
