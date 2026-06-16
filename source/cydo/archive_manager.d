module cydo.archive_manager;

import std.conv : to;
import std.file : exists, isDir;
import std.format : format;
import std.logger : errorf, infof, warningf;
import std.path : buildPath;

import ae.net.http.websocket : WebSocketAdapter;
import ae.utils.promise : Promise;
import ae.utils.promise.concurrency : threadAsync;

import cydo.launch.sandbox : runtimeDir;
import cydo.task : ArchiveState;
import cydo.task : worktreePathForTaskDir;
import cydo.worktree : archiveWorktree, hasArchiveRef, unarchiveWorktree;

package(cydo):

struct ArchiveTaskSnapshot
{
	int tid;
	int parentTid;
	bool archived;
	bool archiving;
	bool alive;
	string workspace;
	string projectPath;
}

struct ArchiveManagerHost
{
	bool delegate(int tid, out ArchiveTaskSnapshot task) tryGetTask;
	ArchiveTaskSnapshot[int] delegate() snapshotTasks;
	string delegate(int tid, string workspace, string projectPath) tryTaskDir;
	bool delegate(int tid, bool archived, bool archiving) updateTaskState;
	void delegate(int tid, bool archived) persistArchived;
	void delegate(int tid) broadcastTaskUpdate;
	void delegate(WebSocketAdapter ws, int tid, string message) sendError;
	Promise!void delegate(int tid, ArchiveState goal) setArchiveGoal;
}

struct WorktreeOp
{
	int tid;
	string worktreePath;
	string projectPath;
	string workspace;
	string taskDir;
}

struct ArchiveExecutionPlan
{
	int transitionTid;
	int rootTid;
	ArchiveState goal;
	WorktreeOp[] ops;
	string cleanupTmpPath;
}

class ArchiveManager
{
	private ArchiveManagerHost host_;
	private Promise!ArchiveState delegate(ArchiveExecutionPlan) runPlan_;

	this(ArchiveManagerHost host,
		Promise!ArchiveState delegate(ArchiveExecutionPlan) runPlan = null)
	{
		host_ = host;
		runPlan_ = runPlan !is null ? runPlan : &executeTransitionPlan;
	}

	bool isTransitioning(int tid)
	{
		ArchiveTaskSnapshot task;
		return host_.tryGetTask(tid, task) && task.archiving;
	}

	void handleSetArchived(WebSocketAdapter ws, int tid, bool archived)
	{
		ArchiveTaskSnapshot task;
		if (!host_.tryGetTask(tid, task))
			return;

		infof("archive request: requestedTid=%d goal=%s archived=%s archiving=%s workspace='%s' projectPath='%s' taskDir='%s'",
			tid,
			archived ? "archived" : "unarchived",
			task.archived ? "true" : "false",
			task.archiving ? "true" : "false",
			task.workspace,
			task.projectPath,
			host_.tryTaskDir(task.tid, task.workspace, task.projectPath));
		if (task.archived == archived)
			return;

		if (task.archiving)
		{
			host_.sendError(ws, tid, "Archive operation already in progress");
			return;
		}

		if (archived)
		{
			auto aliveTid = findAliveInSubtree(host_.snapshotTasks(), tid);
			if (aliveTid >= 0)
			{
				host_.sendError(ws, tid, format!"Cannot archive: task %d is still running"(aliveTid));
				return;
			}
		}

		if (!host_.updateTaskState(tid, archived, true))
			return;
		host_.persistArchived(tid, archived);
		host_.broadcastTaskUpdate(tid);

		host_.setArchiveGoal(tid, archived ? ArchiveState.Archived : ArchiveState.Unarchived)
			.then(() {
				if (host_.updateTaskState(tid, archived, false))
				{
					infof("archive transition completed: requestedTid=%d goal=%s archived=%s archiving=false",
						tid, archived ? "archived" : "unarchived",
						archived ? "true" : "false");
					host_.broadcastTaskUpdate(tid);
				}
			})
			.except((Exception e) {
				errorf("Archive transition failed for tid=%d: %s", tid, e.msg);
				if (host_.updateTaskState(tid, !archived, false))
				{
					host_.persistArchived(tid, !archived);
					errorf("archive transition rolled back: requestedTid=%d revertedArchived=%s archiving=false",
						tid, !archived ? "true" : "false");
					host_.broadcastTaskUpdate(tid);
				}
				host_.sendError(ws, tid, format!"Archive operation failed: %s"(e.msg));
			});
	}

	Promise!ArchiveState delegate(ArchiveState) makeQueueStateFunc(int tid)
	{
		return (ArchiveState goal) => archiveTransition(tid, goal);
	}

	int findRootTid(int tid)
	{
		return findRootTid(host_.snapshotTasks(), tid);
	}

private:
	Promise!ArchiveState archiveTransition(int tid, ArchiveState goal)
	{
		auto plan = buildExecutionPlan(tid, goal);
		return runPlan_(plan);
	}

	ArchiveExecutionPlan buildExecutionPlan(int tid, ArchiveState goal)
	{
		auto tasks = host_.snapshotTasks();
		auto rootTid = findRootTid(tasks, tid);
		auto ops = goal == ArchiveState.Archived
			? collectArchiveOps(tasks, tid)
			: collectUnarchiveOps(tasks, tid);

		string cleanupTmpPath;
		if (goal == ArchiveState.Archived)
		{
			auto rootTask = rootTid in tasks;
			if (rootTask !is null && (rootTid == tid || rootTask.archived))
				cleanupTmpPath = buildPath(runtimeDir(), "tmp-" ~ rootTid.to!string);
		}

		infof("archive transition start: transitionTid=%d rootTid=%d goal=%s operationCount=%d",
			tid, rootTid, goal == ArchiveState.Archived ? "archived" : "unarchived",
			cast(int) ops.length);
		return ArchiveExecutionPlan(tid, rootTid, goal, ops, cleanupTmpPath);
	}

	Promise!ArchiveState executeTransitionPlan(ArchiveExecutionPlan plan)
	{
		return threadAsync({
			import std.file : exists, rmdirRecurse;

			try
			{
				if (plan.goal == ArchiveState.Archived)
				{
					foreach (op; plan.ops)
					{
						auto archiveRef = format!"refs/cydo/worktree-archive/%d"(op.tid);
						infof("archive transition worktree op start: op=archive opTid=%d rootTid=%d workspace='%s' projectPath='%s' taskDir='%s' worktreePath='%s' archiveRef='%s'",
							op.tid, plan.rootTid, op.workspace, op.projectPath, op.taskDir, op.worktreePath, archiveRef);
						archiveWorktree(op.worktreePath, op.projectPath, op.tid);
						infof("archive transition worktree op success: op=archive opTid=%d rootTid=%d workspace='%s' projectPath='%s' taskDir='%s' worktreePath='%s' archiveRef='%s'",
							op.tid, plan.rootTid, op.workspace, op.projectPath, op.taskDir, op.worktreePath, archiveRef);
					}
					if (plan.cleanupTmpPath.length > 0 && exists(plan.cleanupTmpPath))
					{
						try
							rmdirRecurse(plan.cleanupTmpPath);
						catch (Exception e)
							warningf("archiveTransition: cleanup failed for tid=%d rootTid=%d path='%s': %s",
								plan.transitionTid, plan.rootTid, plan.cleanupTmpPath, e.msg);
					}
				}
				else
				{
					foreach (op; plan.ops)
					{
						auto archiveRef = format!"refs/cydo/worktree-archive/%d"(op.tid);
						if (!hasArchiveRef(op.projectPath, op.tid))
						{
							infof("archive transition worktree op skipped: op=unarchive opTid=%d rootTid=%d workspace='%s' projectPath='%s' taskDir='%s' worktreePath='%s' archiveRef='%s' reason='archive ref missing'",
								op.tid, plan.rootTid, op.workspace, op.projectPath, op.taskDir, op.worktreePath, archiveRef);
							continue;
						}
						infof("archive transition worktree op start: op=unarchive opTid=%d rootTid=%d workspace='%s' projectPath='%s' taskDir='%s' worktreePath='%s' archiveRef='%s'",
							op.tid, plan.rootTid, op.workspace, op.projectPath, op.taskDir, op.worktreePath, archiveRef);
						unarchiveWorktree(op.projectPath, op.tid, op.worktreePath);
						infof("archive transition worktree op success: op=unarchive opTid=%d rootTid=%d workspace='%s' projectPath='%s' taskDir='%s' worktreePath='%s' archiveRef='%s'",
							op.tid, plan.rootTid, op.workspace, op.projectPath, op.taskDir, op.worktreePath, archiveRef);
					}
				}
				infof("archive transition finish: transitionTid=%d rootTid=%d goal=%s operationCount=%d",
					plan.transitionTid, plan.rootTid,
					plan.goal == ArchiveState.Archived ? "archived" : "unarchived",
					cast(int) plan.ops.length);
				return plan.goal;
			}
			catch (Exception e)
			{
				errorf("archive transition error: transitionTid=%d rootTid=%d goal=%s operationCount=%d error=%s",
					plan.transitionTid, plan.rootTid,
					plan.goal == ArchiveState.Archived ? "archived" : "unarchived",
					cast(int) plan.ops.length, e.msg);
				throw e;
			}
		});
	}

	int findAliveInSubtree(ArchiveTaskSnapshot[int] tasks, int tid)
	{
		auto task = tid in tasks;
		if (task is null)
			return -1;
		if (task.alive)
			return tid;
		foreach (childTid, child; tasks)
			if (child.parentTid == tid)
			{
				auto found = findAliveInSubtree(tasks, childTid);
				if (found >= 0)
					return found;
			}
		return -1;
	}

	WorktreeOp[] collectArchiveOps(ArchiveTaskSnapshot[int] tasks, int tid)
	{
		WorktreeOp[] ops;
		if (!isEffectivelyArchivedByAncestor(tasks, tid))
			collectArchiveOpsDFS(tasks, tid, false, ops);
		return ops;
	}

	void collectArchiveOpsDFS(ArchiveTaskSnapshot[int] tasks, int tid,
		bool parentEffectivelyArchived, ref WorktreeOp[] ops)
	{
		auto task = tid in tasks;
		if (task is null)
			return;
		if (parentEffectivelyArchived && task.archived)
			return;

		auto taskDir = host_.tryTaskDir(task.tid, task.workspace, task.projectPath);
		if (taskDir.length > 0)
		{
			auto wtPath = worktreePathForTaskDir(taskDir);
			if (exists(wtPath) && isDir(wtPath))
				ops ~= WorktreeOp(tid, wtPath, task.projectPath, task.workspace, taskDir);
		}

		foreach (childTid, child; tasks)
			if (child.parentTid == tid)
			{
				bool follow = !child.archived;
				infof("archive transition recurse: op=archive parentTid=%d childTid=%d followed=%s childWorkspace='%s' childProjectPath='%s' childTaskDir='%s'",
					tid, childTid, follow ? "true" : "false",
					child.workspace, child.projectPath,
					host_.tryTaskDir(child.tid, child.workspace, child.projectPath));
				if (follow)
					collectArchiveOpsDFS(tasks, childTid, true, ops);
			}
	}

	WorktreeOp[] collectUnarchiveOps(ArchiveTaskSnapshot[int] tasks, int tid)
	{
		WorktreeOp[] ops;
		if (!isEffectivelyArchivedByAncestor(tasks, tid))
			collectUnarchiveOpsDFS(tasks, tid, false, ops);
		return ops;
	}

	void collectUnarchiveOpsDFS(ArchiveTaskSnapshot[int] tasks, int tid,
		bool parentEffectivelyArchived, ref WorktreeOp[] ops)
	{
		auto task = tid in tasks;
		if (task is null)
			return;
		if (parentEffectivelyArchived && task.archived)
			return;

		auto taskDir = host_.tryTaskDir(task.tid, task.workspace, task.projectPath);
		if (taskDir.length > 0)
			ops ~= WorktreeOp(tid, worktreePathForTaskDir(taskDir),
				task.projectPath, task.workspace, taskDir);

		foreach (childTid, child; tasks)
			if (child.parentTid == tid)
			{
				bool follow = !child.archived;
				infof("archive transition recurse: op=unarchive parentTid=%d childTid=%d followed=%s childWorkspace='%s' childProjectPath='%s' childTaskDir='%s'",
					tid, childTid, follow ? "true" : "false",
					child.workspace, child.projectPath,
					host_.tryTaskDir(child.tid, child.workspace, child.projectPath));
				if (follow)
					collectUnarchiveOpsDFS(tasks, childTid, true, ops);
			}
	}

	bool isEffectivelyArchivedByAncestor(ArchiveTaskSnapshot[int] tasks, int tid)
	{
		int current = tid;
		for (;;)
		{
			auto task = current in tasks;
			if (task is null)
				return false;
			int parent = task.parentTid;
			if (parent <= 0 || parent == current)
				return false;
			auto parentTask = parent in tasks;
			if (parentTask is null)
				return false;
			if (parentTask.archived)
				return true;
			current = parent;
		}
	}

	int findRootTid(ArchiveTaskSnapshot[int] tasks, int tid)
	{
		int current = tid;
		for (;;)
		{
			auto task = current in tasks;
			if (task is null)
				return current;
			if (task.parentTid <= 0 || task.parentTid == current)
				return current;
			current = task.parentTid;
		}
	}
}

unittest
{
	import std.file : mkdirRecurse, rmdirRecurse;
	import std.path : buildPath;
	import ae.utils.promise : reject, resolve;

	ArchiveTaskSnapshot[int] tasks;
	bool runnerCalled;
	ArchiveExecutionPlan capturedPlan;
	auto scratchDir = buildPath(runtimeDir(), "archive-manager-unittest");
	scope(exit)
	{
		if (exists(scratchDir))
			rmdirRecurse(scratchDir);
	}

	auto host = ArchiveManagerHost(
		tryGetTask: (int tid, out ArchiveTaskSnapshot task) {
			auto taskPtr = tid in tasks;
			if (taskPtr is null)
				return false;
			task = *taskPtr;
			return true;
		},
		snapshotTasks: () => tasks.dup,
		tryTaskDir: (int tid, string workspace, string projectPath) {
			return buildPath(scratchDir, "task-" ~ tid.to!string);
		},
		updateTaskState: (int tid, bool archived, bool archiving) {
			auto taskPtr = tid in tasks;
			if (taskPtr is null)
				return false;
			taskPtr.archived = archived;
			taskPtr.archiving = archiving;
			return true;
		},
		persistArchived: (int tid, bool archived) {},
		broadcastTaskUpdate: (int tid) {},
		sendError: (WebSocketAdapter ws, int tid, string message) {},
		setArchiveGoal: null,
	);

	ArchiveManager manager;
	host.setArchiveGoal = (int tid, ArchiveState goal) => manager.makeQueueStateFunc(tid)(goal)
		.then((ArchiveState _) {});
	manager = new ArchiveManager(host, (ArchiveExecutionPlan plan) {
		runnerCalled = true;
		capturedPlan = plan;
		tasks = null;
		return resolve(plan.goal);
	});

	tasks[1] = ArchiveTaskSnapshot(1, 0, true, false, false, "ws", "/repo");
	tasks[2] = ArchiveTaskSnapshot(2, 1, false, false, false, "ws", "/repo");
	foreach (tid; [1, 2])
	{
		auto taskDir = host.tryTaskDir(tid, "ws", "/repo");
		mkdirRecurse(taskDir);
		mkdirRecurse(worktreePathForTaskDir(taskDir));
	}

	manager.makeQueueStateFunc(1)(ArchiveState.Archived)
		.then((ArchiveState _) {}, (Exception e) { assert(false, e.msg); });

	assert(runnerCalled);
	assert(capturedPlan.transitionTid == 1);
	assert(capturedPlan.rootTid == 1);
	assert(capturedPlan.goal == ArchiveState.Archived);
	assert(capturedPlan.ops.length == 2);
	assert(capturedPlan.ops[0].tid == 1);
	assert(capturedPlan.ops[1].tid == 2);
	assert(capturedPlan.cleanupTmpPath == buildPath(runtimeDir(), "tmp-1"));
}

version(unittest)
{
	string setupArchiveManagerTestRepo(string name)
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

	void drainPromiseNextTicks()
	{
		import ae.net.asockets : socketManager;

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
}

unittest
{
	import ae.utils.promise : reject;

	ArchiveTaskSnapshot[int] tasks;
	bool runnerCalled;
	bool[] persistedStates;
	int[] broadcasts;
	string[] errors;

	auto host = ArchiveManagerHost(
		tryGetTask: (int tid, out ArchiveTaskSnapshot task) {
			auto taskPtr = tid in tasks;
			if (taskPtr is null)
				return false;
			task = *taskPtr;
			return true;
		},
		snapshotTasks: () => tasks.dup,
		tryTaskDir: (int tid, string workspace, string projectPath) => "",
		updateTaskState: (int tid, bool archived, bool archiving) {
			auto taskPtr = tid in tasks;
			if (taskPtr is null)
				return false;
			taskPtr.archived = archived;
			taskPtr.archiving = archiving;
			return true;
		},
		persistArchived: (int tid, bool archived) {
			assert(tid == 1);
			persistedStates ~= archived;
		},
		broadcastTaskUpdate: (int tid) {
			broadcasts ~= tid;
		},
		sendError: (WebSocketAdapter ws, int tid, string message) {
			errors ~= message;
		},
		setArchiveGoal: null,
	);

	ArchiveManager manager;
	host.setArchiveGoal = (int tid, ArchiveState goal) => manager.makeQueueStateFunc(tid)(goal)
		.then((ArchiveState _) {});
	manager = new ArchiveManager(host, (ArchiveExecutionPlan plan) {
		runnerCalled = true;
		return reject!ArchiveState(new Exception("boom"));
	});

	tasks[1] = ArchiveTaskSnapshot(1, 0, false, false, false, "ws", "/repo");
	manager.handleSetArchived(null, 1, true);
	drainPromiseNextTicks();

	assert(runnerCalled);
	assert(tasks[1].archived == false);
	assert(tasks[1].archiving == false);
	assert(persistedStates == [true, false]);
	assert(broadcasts == [1, 1]);
	assert(errors.length == 1);
	assert(errors[0] == "Archive operation failed: boom");
}

unittest
{
	ArchiveTaskSnapshot[int] tasks;
	bool runnerCalled;
	int persistCalls;
	int broadcastCalls;
	string[] errors;

	auto host = ArchiveManagerHost(
		tryGetTask: (int tid, out ArchiveTaskSnapshot task) {
			auto taskPtr = tid in tasks;
			if (taskPtr is null)
				return false;
			task = *taskPtr;
			return true;
		},
		snapshotTasks: () => tasks.dup,
		tryTaskDir: (int tid, string workspace, string projectPath) => "",
		updateTaskState: (int tid, bool archived, bool archiving) {
			auto taskPtr = tid in tasks;
			if (taskPtr is null)
				return false;
			taskPtr.archived = archived;
			taskPtr.archiving = archiving;
			return true;
		},
		persistArchived: (int tid, bool archived) {
			persistCalls++;
		},
		broadcastTaskUpdate: (int tid) {
			broadcastCalls++;
		},
		sendError: (WebSocketAdapter ws, int tid, string message) {
			errors ~= message;
		},
		setArchiveGoal: null,
	);

	ArchiveManager manager;
	host.setArchiveGoal = (int tid, ArchiveState goal) {
		runnerCalled = true;
		return manager.makeQueueStateFunc(tid)(goal).then((ArchiveState _) {});
	};
	manager = new ArchiveManager(host);

	tasks[1] = ArchiveTaskSnapshot(1, 0, false, false, false, "ws", "/repo");
	tasks[2] = ArchiveTaskSnapshot(2, 1, false, false, true, "ws", "/repo");

	manager.handleSetArchived(null, 1, true);

	assert(!runnerCalled);
	assert(tasks[1].archived == false);
	assert(tasks[1].archiving == false);
	assert(persistCalls == 0);
	assert(broadcastCalls == 0);
	assert(errors.length == 1);
	assert(errors[0] == "Cannot archive: task 2 is still running");
}

unittest
{
	import std.algorithm.searching : canFind;
	import std.file : exists, mkdirRecurse, rmdirRecurse;
	import std.path : buildPath;
	import ae.utils.promise : reject, resolve;

	ArchiveTaskSnapshot[int] tasks;
	string taskDir;
	bool[] persistedStates;
	int[] broadcasts;
	string[] errors;

	auto repoDir = setupArchiveManagerTestRepo("cydo-archive-manager-rollback-worktree-failure");
	scope(exit)
	{
		if (exists(repoDir))
			rmdirRecurse(repoDir);
	}

	auto scratchDir = buildPath(runtimeDir(), "archive-manager-rollback-worktree-failure");
	scope(exit)
	{
		if (exists(scratchDir))
			rmdirRecurse(scratchDir);
	}

	taskDir = buildPath(scratchDir, "task-1");
	mkdirRecurse(worktreePathForTaskDir(taskDir));

	auto host = ArchiveManagerHost(
		tryGetTask: (int tid, out ArchiveTaskSnapshot task) {
			auto taskPtr = tid in tasks;
			if (taskPtr is null)
				return false;
			task = *taskPtr;
			return true;
		},
		snapshotTasks: () => tasks.dup,
		tryTaskDir: (int tid, string workspace, string projectPath) => taskDir,
		updateTaskState: (int tid, bool archived, bool archiving) {
			auto taskPtr = tid in tasks;
			if (taskPtr is null)
				return false;
			taskPtr.archived = archived;
			taskPtr.archiving = archiving;
			return true;
		},
		persistArchived: (int tid, bool archived) {
			persistedStates ~= archived;
		},
		broadcastTaskUpdate: (int tid) {
			broadcasts ~= tid;
		},
		sendError: (WebSocketAdapter ws, int tid, string message) {
			errors ~= message;
		},
		setArchiveGoal: null,
	);

	ArchiveManager manager;
	host.setArchiveGoal = (int tid, ArchiveState goal) => manager.makeQueueStateFunc(tid)(goal)
		.then((ArchiveState _) {});
	manager = new ArchiveManager(host, (ArchiveExecutionPlan plan) {
		try
		{
			foreach (op; plan.ops)
				archiveWorktree(op.worktreePath, op.projectPath, op.tid);
			return resolve(plan.goal);
		}
		catch (Exception e)
			return reject!ArchiveState(e);
	});

	tasks[1] = ArchiveTaskSnapshot(1, 0, false, false, false, "ws", repoDir);

	manager.handleSetArchived(null, 1, true);
	drainPromiseNextTicks();

	assert(tasks[1].archived == false);
	assert(tasks[1].archiving == false);
	assert(persistedStates == [true, false]);
	assert(broadcasts == [1, 1]);
	assert(errors.length == 1);
	assert(errors[0].canFind("Archive operation failed: archiveWorktree: rev-parse HEAD failed"));
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse;
	import std.path : buildPath;
	import std.process : execute;
	import ae.utils.promise : resolve;

	ArchiveTaskSnapshot[int] tasks;
	string[int] taskDirs;

	auto repoDir = setupArchiveManagerTestRepo("cydo-archive-manager-precomputed-worktree-ops");
	scope(exit)
	{
		if (exists(repoDir))
			rmdirRecurse(repoDir);
	}

	auto scratchDir = buildPath(runtimeDir(), "archive-manager-precomputed-worktree-ops");
	scope(exit)
	{
		if (exists(scratchDir))
			rmdirRecurse(scratchDir);
	}

	taskDirs[1] = buildPath(scratchDir, "task-1");
	mkdirRecurse(taskDirs[1]);
	auto worktreePath = worktreePathForTaskDir(taskDirs[1]);
	auto addResult = execute(["git", "-C", repoDir, "worktree", "add", "--detach", worktreePath]);
	assert(addResult.status == 0, "worktree add failed: " ~ addResult.output);

	auto host = ArchiveManagerHost(
		tryGetTask: (int tid, out ArchiveTaskSnapshot task) {
			auto taskPtr = tid in tasks;
			if (taskPtr is null)
				return false;
			task = *taskPtr;
			return true;
		},
		snapshotTasks: () => tasks.dup,
		tryTaskDir: (int tid, string workspace, string projectPath) {
			auto taskDir = tid in taskDirs;
			return taskDir is null ? "" : *taskDir;
		},
		updateTaskState: (int tid, bool archived, bool archiving) => false,
		persistArchived: (int tid, bool archived) {},
		broadcastTaskUpdate: (int tid) {},
		sendError: (WebSocketAdapter ws, int tid, string message) {
			assert(false, message);
		},
		setArchiveGoal: null,
	);

	auto manager = new ArchiveManager(host, (ArchiveExecutionPlan plan) {
		tasks = null;
		taskDirs = null;
		foreach (op; plan.ops)
			archiveWorktree(op.worktreePath, op.projectPath, op.tid);
		return resolve(plan.goal);
	});

	tasks[1] = ArchiveTaskSnapshot(1, 0, false, false, false, "ws", repoDir);

	manager.makeQueueStateFunc(1)(ArchiveState.Archived)
		.then((ArchiveState _) {}, (Exception e) { assert(false, e.msg); });
	drainPromiseNextTicks();
	assert(!exists(worktreePath));
	assert(hasArchiveRef(repoDir, 1));
}
