module cydo.workflow.sessions.yield_gates;

import cydo.domain.tasks.yield_gate : NaggedYieldGates, YieldGate;
import cydo.workflow.sessions.disk_usage : DiskEvaluation;
import cydo.runtime.storage.disk_usage : DiskCategory;
import cydo.runtime.storage.nix_roots : nixClosureLabel;
import cydo.workflow.workspace.worktree : WorktreeHeadStatus, worktreeBranchName;
import std.conv : to;
import std.array : join;
import std.path : buildPath;

struct YieldGateFinding
{
	YieldGate gate;
	string detail;
	string[string] vars;

	bool found() const
	{
		return detail !is null;
	}
}

YieldGateFinding checkYieldGates(NaggedYieldGates nagged, int tid,
	YieldGateFinding delegate(int tid) checkOutputs,
	YieldGateFinding delegate(int tid) checkWorktreeBranch)
{
	if (!nagged.contains(YieldGate.outputs))
	{
		auto finding = checkOutputs(tid);
		if (finding.found)
			return finding;
	}
	if (nagged.contains(YieldGate.worktreeBranch))
		return YieldGateFinding(YieldGate.worktreeBranch);
	return checkWorktreeBranch(tid);
}

YieldGateFinding evaluateWorktreeBranchGate(WorktreeHeadStatus status,
	string worktreePath, int worktreeTid)
{
	auto branch = worktreeBranchName(worktreeTid);
	if (status.branchTip is null || status.currentBranch == branch)
		return YieldGateFinding(YieldGate.worktreeBranch);
	return YieldGateFinding(YieldGate.worktreeBranch, "worktree off its branch", [
		"worktree_path": worktreePath,
		"branch": branch,
		"head": status.currentBranch.length == 0
			? "a detached HEAD at " ~ status.headSha : "branch `" ~ status.currentBranch ~ "`",
	]);
}

bool shouldEvaluateDiskCleanup(NaggedYieldGates nagged)
{
	return !nagged.contains(YieldGate.diskCleanup);
}

bool shouldRetryYieldGate(NaggedYieldGates nagged, YieldGateFinding finding)
{
	return finding.found && !nagged.contains(finding.gate);
}

YieldGateFinding checkDiskCleanupGate(DiskEvaluation evaluation, long threshold,
	string taskDir, string temporaryDir, string sharedTmpDir)
{
	bool over = evaluation.usage.totalBytes >= threshold;
	foreach (entry; evaluation.nix.entries)
		over = over || entry.closureSize >= threshold;
	if (!over && evaluation.usage.unmeasured.length == 0)
		return YieldGateFinding(YieldGate.diskCleanup);
	string pathLabel(DiskCategory category, string relativePath)
	{
		return category.to!string ~ " " ~ (category == DiskCategory.sharedTemporary
			? buildPath(sharedTmpDir, relativePath) : relativePath);
	}
	string[] paths;
	foreach (path; evaluation.usage.topPaths)
		paths ~= to!string(path.bytes) ~ " " ~ pathLabel(path.category, path.relativePath);
	string[] unmeasured;
	foreach (path; evaluation.usage.unmeasured)
		unmeasured ~= pathLabel(path.category, path.relativePath);
	string[string] sharedLinkPaths;
	foreach (link; evaluation.usage.symlinks)
		if (link.sharedRelativePath.length > 0)
			sharedLinkPaths[link.linkPath] = buildPath(sharedTmpDir, link.sharedRelativePath);
	string[] closures;
	foreach (entry; evaluation.nix.entries)
	{
		string[] linkPaths;
		foreach (path; entry.linkPaths)
			linkPaths ~= sharedLinkPaths.get(path, path);
		closures ~= to!string(entry.closureSize) ~ " " ~ entry.storePath ~ " "
			~ linkPaths.join(", ");
	}
	string[string] vars = [
		"task_dir": taskDir,
		"task_bytes": to!string(evaluation.usage.taskBytes),
		"temporary_dir": temporaryDir,
		"temporary_bytes": to!string(evaluation.usage.temporaryBytes),
		"shared_tmp_dir": sharedTmpDir,
		"shared_tmp_bytes": to!string(evaluation.usage.sharedTemporaryBytes),
		"total_bytes": to!string(evaluation.usage.totalBytes),
		"threshold_bytes": to!string(threshold),
		"top_paths": paths.length ? paths.join("\n") : "(none)",
		"unmeasured_paths": unmeasured.length ? unmeasured.join("\n") : "(none)",
		"nix_closures": nixClosureLabel ~ "\n" ~
			(closures.length ? closures.join("\n") : "(none)"),
	];
	return YieldGateFinding(YieldGate.diskCleanup, "disk cleanup requested", vars);
}

unittest
{
	import cydo.workflow.sessions.disk_usage : DiskEvaluation;
	import cydo.runtime.storage.nix_roots : NixClosureEntry;

	DiskEvaluation evaluation;
	evaluation.usage.taskBytes = 120;
	evaluation.usage.temporaryBytes = -21;
	evaluation.usage.totalBytes = 99;
	assert(!checkDiskCleanupGate(evaluation, 100, "/task", "/tmp/task", "/tmp").found);
	assert(checkDiskCleanupGate(evaluation, 99, "/task", "/tmp/task", "/tmp").found);
	evaluation.usage.taskBytes = -30;
	evaluation.usage.temporaryBytes = 10;
	evaluation.usage.totalBytes = -20;
	assert(!checkDiskCleanupGate(evaluation, 1, "/task", "/tmp/task", "/tmp").found);
	evaluation.usage = typeof(evaluation.usage).init;
	evaluation.nix.entries = [
		NixClosureEntry(["/task/first"], "/nix/store/first", 49),
		NixClosureEntry(["/task/second"], "/nix/store/second", 49),
	];
	assert(!checkDiskCleanupGate(evaluation, 50, "/task", "/tmp/task", "/tmp").found);
	evaluation.nix.entries[1].closureSize = 50;
	auto finding = checkDiskCleanupGate(evaluation, 50, "/task", "/tmp/task", "/tmp");
	assert(finding.found);
	assert(finding.gate == YieldGate.diskCleanup);
	assert(finding.vars["total_bytes"] == "0");
	assert(shouldRetryYieldGate(NaggedYieldGates.init, finding));
	auto nagged = NaggedYieldGates.init;
	nagged.mark(YieldGate.diskCleanup);
	assert(!shouldRetryYieldGate(nagged, finding));
	assert(!shouldEvaluateDiskCleanup(nagged));
}

unittest
{
	import cydo.runtime.storage.disk_usage : DiskEntry, DiskScanInput, DiskUnmeasured, aggregateDiskUsage;

	DiskEvaluation evaluation;
	auto taskFile = DiskEntry(DiskCategory.task, "output", "/task/output", 90, 1, 1);
	auto sharedFile = DiskEntry(DiskCategory.sharedTemporary, "scratch", "/host-tmp/scratch",
		10, 1, 2);
	evaluation.usage = aggregateDiskUsage(DiskScanInput.init, [taskFile], null);
	assert(!checkDiskCleanupGate(evaluation, 100, "/task", "/tmp/task", "/tmp").found);

	evaluation.usage = aggregateDiskUsage(DiskScanInput.init, [taskFile, sharedFile], null);
	foreach (sharedTmpDir; ["/tmp", "/host-tmp"])
	{
		auto finding = checkDiskCleanupGate(evaluation, 100, "/task", "/tmp/task", sharedTmpDir);
		assert(finding.found);
		assert(finding.vars["total_bytes"] == "100");
		assert(finding.vars["shared_tmp_bytes"] == "10");
		assert(finding.vars["shared_tmp_dir"] == sharedTmpDir);
		assert(finding.vars["top_paths"] == "90 task output\n10 sharedTemporary "
			~ buildPath(sharedTmpDir, "scratch"));
	}

	evaluation.usage.unmeasured = [
		DiskUnmeasured(DiskCategory.sharedTemporary, "blocked", "Permission denied"),
	];
	auto finding = checkDiskCleanupGate(evaluation, 101, "/task", "/tmp/task", "/tmp");
	assert(finding.found);
	assert(finding.vars["unmeasured_paths"] == "sharedTemporary /tmp/blocked");
}

unittest
{
	import cydo.runtime.storage.disk_usage : DiskUnmeasured;

	DiskEvaluation evaluation;
	evaluation.usage.totalBytes = 99;
	assert(!checkDiskCleanupGate(evaluation, 100, "/task", "/tmp/task", "/tmp").found);
	auto finding = checkDiskCleanupGate(evaluation, 98, "/task", "/tmp/task", "/tmp");
	assert(finding.found);
	assert(finding.vars["unmeasured_paths"] == "(none)");

	evaluation.usage.unmeasured = [
		DiskUnmeasured(DiskCategory.temporary, "nested/blocked", "Permission denied"),
	];
	finding = checkDiskCleanupGate(evaluation, 100, "/task", "/tmp/task", "/tmp");
	assert(finding.found);
	assert(finding.vars["unmeasured_paths"] == "temporary nested/blocked");
}

unittest
{
	assert(!evaluateWorktreeBranchGate(WorktreeHeadStatus(null, "", "abc"),
		"/worktree", 7).found);
	assert(!evaluateWorktreeBranchGate(WorktreeHeadStatus("abc", "cydo/7", "abc"),
		"/worktree", 7).found);
}

unittest
{
	auto finding = evaluateWorktreeBranchGate(WorktreeHeadStatus("abc", "", "abc"),
		"/worktree", 7);
	assert(finding.found && finding.gate == YieldGate.worktreeBranch);
	assert(finding.vars["head"] == "a detached HEAD at abc");
	assert(finding.vars["branch"] == "cydo/7");
	assert(finding.vars["worktree_path"] == "/worktree");

	auto nagged = NaggedYieldGates.init;
	assert(shouldRetryYieldGate(nagged, finding));
	nagged.mark(YieldGate.worktreeBranch);
	assert(!shouldRetryYieldGate(nagged, finding));
}

unittest
{
	auto finding = evaluateWorktreeBranchGate(WorktreeHeadStatus("abc", "feature", "abc"),
		"/worktree", 7);
	assert(finding.found && finding.gate == YieldGate.worktreeBranch);
	assert(finding.vars["head"] == "branch `feature`");
}

unittest
{
	auto outputs = YieldGateFinding(YieldGate.outputs, "missing report");
	auto branch = YieldGateFinding(YieldGate.worktreeBranch, "worktree off its branch");
	YieldGateFinding unexpected(int tid)
	{
		assert(false, "yield gate delegate should have been skipped");
	}

	auto nagged = NaggedYieldGates.init;
	assert(checkYieldGates(nagged, 7, (int tid) => outputs, &unexpected) == outputs);
	assert(checkYieldGates(nagged, 7, (int tid) => YieldGateFinding(YieldGate.outputs),
		(int tid) => branch) == branch);
	nagged.mark(YieldGate.outputs);
	assert(checkYieldGates(nagged, 7, &unexpected, (int tid) => branch) == branch);
	nagged.mark(YieldGate.worktreeBranch);
	assert(!checkYieldGates(nagged, 7, &unexpected, &unexpected).found);
}
