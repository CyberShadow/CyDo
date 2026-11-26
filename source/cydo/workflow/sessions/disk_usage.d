module cydo.workflow.sessions.disk_usage;

import std.datetime : Clock, SysTime;

import ae.utils.promise : Promise;
import ae.utils.promise.concurrency : threadAsync;
import cydo.runtime.launch.sandbox_materialization : taskTmpAgentPath, taskTmpHostPath;
import cydo.runtime.storage.nix_roots : NixClosureReport, reportNixClosures;
import cydo.runtime.storage.disk_usage : DiskScanInput, DiskUsageResult, DiskSymlink,
	listDirectory, measureDiskUsage;

struct DiskEvaluation
{
	DiskUsageResult usage;
	NixClosureReport nix;
}

struct DiskUsageHost
{
	string delegate(int tid) taskDir;
	string delegate(int tid) sharedTmpPath;
	SysTime delegate(int tid) runStart;
	bool delegate(int tid) ownsWorktree;
	string delegate(int tid) worktreePath;
	string delegate(int tid) forkBaseSha;
	string delegate(int tid) forkRepository;
}

DiskScanInput buildDiskScanInput(int tid, DiskUsageHost host)
{
	DiskScanInput input;
	input.taskDir = host.taskDir(tid);
	input.sharedTmpDir = host.sharedTmpPath(tid);
	input.sharedSince = host.runStart(tid);
	input.temporaryDir = taskTmpHostPath(input.sharedTmpDir, tid);
	if (host.ownsWorktree(tid))
	{
		input.forkWorktree = host.worktreePath(tid);
		input.forkBaseSha = host.forkBaseSha(tid);
		input.forkRepository = host.forkRepository(tid);
	}
	return input;
}

Promise!DiskEvaluation measureDiskUsageAsync(DiskScanInput input)
{
	return measureDiskUsageAsync(input, (string dir) => listDirectory(dir),
		(links) => reportNixClosures(links));
}

Promise!DiskEvaluation measureDiskUsageAsync(DiskScanInput input,
	string[] delegate(string dir) list,
	NixClosureReport delegate(DiskSymlink[]) reporter)
{
	auto workerInput = input;
	return threadAsync({
		DiskEvaluation result;
		result.usage = measureDiskUsage(workerInput, list);
		result.nix = reporter(result.usage.symlinks);
		return result;
	});
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
	import std.process : execute;
	import std.uuid : randomUUID;

	auto root = buildPath(tempDir(), "cydo-disk-worker-" ~ randomUUID().toString());
	auto task = buildPath(root, "task");
	auto repo = buildPath(root, "repo");
	auto sharedRoot = buildPath(root, "shared");
	mkdirRecurse(task);
	mkdirRecurse(sharedRoot);
	scope (exit) rmdirRecurse(root);
	auto host = DiskUsageHost(
		taskDir: (int tid) => task,
		sharedTmpPath: (int tid) => sharedRoot,
		runStart: (int tid) => Clock.currTime,
		ownsWorktree: (int tid) => false,
		worktreePath: (int tid) => "",
		forkBaseSha: (int tid) => "",
		forkRepository: (int tid) => repo,
	);
	auto input = buildDiskScanInput(12, host);
	assert(input.taskDir == task);
	assert(input.temporaryDir == buildPath(sharedRoot, "cydo-task-12"));
	assert(input.forkWorktree.length == 0);
	// I: inherited worktrees and the project checkout are outside scan roots.
	bool baseCalled;
	bool repositoryCalled;
	auto inheritedHost = DiskUsageHost(
		taskDir: (int tid) => task,
		sharedTmpPath: (int tid) => sharedRoot,
		runStart: (int tid) => Clock.currTime,
		ownsWorktree: (int tid) => false,
		worktreePath: (int tid) => "/elsewhere/parent-fork",
		forkBaseSha: (int tid) { baseCalled = true; return "base"; },
		forkRepository: (int tid) { repositoryCalled = true; return repo; },
	);
	auto inherited = buildDiskScanInput(12, inheritedHost);
	assert(inherited.taskDir == task);
	assert(inherited.forkWorktree.length == 0);
	assert(inherited.forkBaseSha.length == 0);
	assert(inherited.forkRepository.length == 0);
	assert(!baseCalled);
	assert(!repositoryCalled);
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
	measureDiskUsageAsync(input, blockingList,
		(DiskSymlink[] links) => NixClosureReport.init).then((DiskEvaluation result) {
		assert(atomicLoad(progressed));
		assert(result.usage.totalBytes == 0);
		completed = true;
	}).ignoreResult();
	input.taskDir = "/nonexistent-after-dispatch";
	onNextTick(socketManager, { atomicStore(progressed, true); });
	socketManager.loop();
	assert(completed);
	input.taskDir = task;

	assert(execute(["git", "init", "-q", repo]).status == 0);
	auto fork = buildPath(task, "fork");
	mkdirRecurse(fork);
	input.forkWorktree = fork;
	input.forkRepository = repo;
	input.forkBaseSha = "bad-sha";
	bool rejected;
	measureDiskUsageAsync(input).then((DiskEvaluation result) {
		assert(false, "expected Git failure");
	}, (Exception e) {
		assert(e.msg.canFind("Cannot list fork base for " ~ fork));
		rejected = true;
	}).ignoreResult();
	socketManager.loop();
	assert(rejected);

	// K: an owned fork with no resolvable base rejects on the worker.
	auto ownedHost = DiskUsageHost(
		taskDir: (int tid) => task,
		sharedTmpPath: (int tid) => sharedRoot,
		runStart: (int tid) => Clock.currTime,
		ownsWorktree: (int tid) => true,
		worktreePath: (int tid) => fork,
		forkBaseSha: (int tid) => "",
		forkRepository: (int tid) => repo,
	);
	auto missingBase = buildDiskScanInput(12, ownedHost);
	assert(missingBase.forkRepository == repo);
	rejected = false;
	measureDiskUsageAsync(missingBase).then((DiskEvaluation result) {
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
		input.forkRepository = "";
		assert(chmod(task.toStringz, 0) == 0);
		scope (exit) assert(chmod(task.toStringz, 448) == 0);
		rejected = false;
		measureDiskUsageAsync(input).then((DiskEvaluation result) {
			assert(false, "expected unreadable-root failure");
		}, (Exception e) {
			assert(e.msg.canFind(task));
			rejected = true;
		}).ignoreResult();
		socketManager.loop();
		assert(rejected);
	}
}
