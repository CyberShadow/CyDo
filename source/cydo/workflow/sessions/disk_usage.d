module cydo.workflow.sessions.disk_usage;

import ae.utils.promise : Promise;
import ae.utils.promise.concurrency : threadAsync;
import cydo.runtime.launch.sandbox_materialization : taskTmpAgentPath, taskTmpHostPath;
import cydo.runtime.storage.disk_usage : DiskScanInput, DiskUsageResult,
	listDirectory, measureDiskUsage;

struct DiskUsageHost
{
	string delegate(int tid) taskDir;
	string delegate(int tid) sharedTmpPath;
	bool delegate(int tid) ownsWorktree;
	string delegate(int tid) worktreePath;
	string delegate(int tid) forkBaseSha;
}

DiskScanInput buildDiskScanInput(int tid, DiskUsageHost host)
{
	DiskScanInput input;
	input.taskDir = host.taskDir(tid);
	input.temporaryDir = taskTmpHostPath(host.sharedTmpPath(tid), tid);
	if (host.ownsWorktree(tid))
	{
		input.forkWorktree = host.worktreePath(tid);
		input.forkBaseSha = host.forkBaseSha(tid);
	}
	return input;
}

Promise!DiskUsageResult measureDiskUsageAsync(DiskScanInput input)
{
	return measureDiskUsageAsync(input, (string dir) => listDirectory(dir));
}

Promise!DiskUsageResult measureDiskUsageAsync(DiskScanInput input,
	string[] delegate(string dir) list)
{
	auto workerInput = input;
	return threadAsync({ return measureDiskUsage(workerInput, list); });
}

unittest
{
	import ae.net.asockets : onNextTick, socketManager;
	import core.atomic : atomicLoad, atomicStore;
	import core.thread : Thread;
	import core.time : msecs;
	import std.algorithm : canFind;
	import std.file : dirEntries, mkdirRecurse, rmdirRecurse, tempDir, write, SpanMode;
	import std.path : buildPath;
	import std.uuid : randomUUID;

	auto root = buildPath(tempDir(), "cydo-disk-worker-" ~ randomUUID().toString());
	auto task = buildPath(root, "task");
	auto sharedRoot = buildPath(root, "shared");
	mkdirRecurse(task);
	mkdirRecurse(sharedRoot);
	scope (exit) rmdirRecurse(root);
	auto host = DiskUsageHost(
		taskDir: (int tid) => task,
		sharedTmpPath: (int tid) => sharedRoot,
		ownsWorktree: (int tid) => false,
		worktreePath: (int tid) => "",
		forkBaseSha: (int tid) => "",
	);
	auto input = buildDiskScanInput(12, host);
	assert(input.taskDir == task);
	assert(input.temporaryDir == buildPath(sharedRoot, "cydo-task-12"));
	assert(input.forkWorktree.length == 0);
	// I: inherited worktrees and the project checkout are outside scan roots.
	bool baseCalled;
	auto inheritedHost = DiskUsageHost(
		taskDir: (int tid) => task,
		sharedTmpPath: (int tid) => sharedRoot,
		ownsWorktree: (int tid) => false,
		worktreePath: (int tid) => "/elsewhere/parent-fork",
		forkBaseSha: (int tid) { baseCalled = true; return "base"; },
	);
	auto inherited = buildDiskScanInput(12, inheritedHost);
	assert(inherited.taskDir == task);
	assert(inherited.forkWorktree.length == 0);
	assert(inherited.forkBaseSha.length == 0);
	assert(!baseCalled);
	// J: both launch modes use their host TMPDIR, never the sandbox alias.
	auto otherRoot = buildPath(root, "shared-b");
	host.sharedTmpPath = (int tid) => otherRoot;
	auto other = buildDiskScanInput(12, host);
	assert(other.temporaryDir == taskTmpHostPath(otherRoot, 12));
	assert(input.temporaryDir == taskTmpHostPath(sharedRoot, 12));
	assert(input.temporaryDir != taskTmpAgentPath(sharedRoot, 12, true));
	assert(other.temporaryDir != taskTmpAgentPath(otherRoot, 12, true));
	mkdirRecurse(input.temporaryDir);
	shared bool progressed;
	bool completed;
	string[] delegate(string) blockingList = (string dir) {
		for (int wait = 0; wait < 5_000 && !atomicLoad(progressed); ++wait)
			Thread.sleep(1.msecs);
		assert(atomicLoad(progressed), "event loop did not advance during worker scan");
		string[] paths;
		foreach (child; dirEntries(dir, SpanMode.shallow)) paths ~= child.name;
		return paths;
	};
	measureDiskUsageAsync(input, blockingList).then((DiskUsageResult result) {
		assert(atomicLoad(progressed));
		assert(result.totalBytes == 0);
		completed = true;
	}).ignoreResult();
	input.taskDir = "/nonexistent-after-dispatch";
	onNextTick(socketManager, { atomicStore(progressed, true); });
	socketManager.loop();
	assert(completed);
	input.taskDir = task;

	input.forkWorktree = task;
	input.forkBaseSha = "bad-sha";
	bool rejected;
	measureDiskUsageAsync(input).then((DiskUsageResult result) {
		assert(false, "expected Git failure");
	}, (Exception e) {
		assert(e.msg.canFind(task));
		rejected = true;
	}).ignoreResult();
	socketManager.loop();
	assert(rejected);

	// K: an owned fork with no resolvable base rejects on the worker.
	auto fork = buildPath(task, "fork");
	mkdirRecurse(fork);
	auto ownedHost = DiskUsageHost(
		taskDir: (int tid) => task,
		sharedTmpPath: (int tid) => sharedRoot,
		ownsWorktree: (int tid) => true,
		worktreePath: (int tid) => fork,
		forkBaseSha: (int tid) => "",
	);
	auto missingBase = buildDiskScanInput(12, ownedHost);
	rejected = false;
	measureDiskUsageAsync(missingBase).then((DiskUsageResult result) {
		assert(false, "expected missing-base failure");
	}, (Exception e) {
		assert(e.msg.canFind(fork));
		rejected = true;
	}).ignoreResult();
	socketManager.loop();
	assert(rejected);

	import core.sys.posix.sys.stat : chmod;
	import core.sys.posix.unistd : geteuid;
	import std.string : toStringz;
	if (geteuid() != 0)
	{
		input.forkWorktree = "";
		input.forkBaseSha = "";
		auto blocked = buildPath(task, "blocked");
		mkdirRecurse(blocked);
		assert(chmod(blocked.toStringz, 0) == 0);
		scope (exit) chmod(blocked.toStringz, 448);
		rejected = false;
		measureDiskUsageAsync(input).then((DiskUsageResult result) {
			assert(false, "expected unreadable-directory failure");
		}, (Exception e) {
			assert(e.msg.canFind(blocked));
			rejected = true;
		}).ignoreResult();
		socketManager.loop();
		assert(rejected);
	}
}
