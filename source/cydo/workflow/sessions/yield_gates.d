module cydo.workflow.sessions.yield_gates;

import cydo.domain.tasks.yield_gate : NaggedYieldGates, YieldGate;
import cydo.workflow.sessions.disk_usage : DiskEvaluation;
import cydo.runtime.storage.nix_roots : nixClosureLabel;
import std.conv : to;
import std.array : join;

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
	YieldGateFinding delegate(int tid) checkOutputs)
{
	if (nagged.contains(YieldGate.outputs))
		return YieldGateFinding(YieldGate.outputs);
	return checkOutputs(tid);
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
	string taskDir, string temporaryDir)
{
	bool over = evaluation.usage.totalBytes >= threshold;
	foreach (entry; evaluation.nix.entries)
		over = over || entry.closureSize >= threshold;
	if (!over && evaluation.usage.unmeasured.length == 0)
		return YieldGateFinding(YieldGate.diskCleanup);
	string[] paths;
	foreach (path; evaluation.usage.topPaths)
		paths ~= to!string(path.bytes) ~ " " ~ to!string(path.category) ~ " " ~ path.relativePath;
	string[] unmeasured;
	foreach (path; evaluation.usage.unmeasured)
		unmeasured ~= to!string(path.category) ~ " " ~ path.relativePath;
	string[] closures;
	foreach (entry; evaluation.nix.entries)
		closures ~= to!string(entry.closureSize) ~ " " ~ entry.storePath ~ " "
			~ entry.linkPaths.join(", ");
	string[string] vars = [
		"task_dir": taskDir,
		"task_bytes": to!string(evaluation.usage.taskBytes),
		"temporary_dir": temporaryDir,
		"temporary_bytes": to!string(evaluation.usage.temporaryBytes),
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
	assert(!checkDiskCleanupGate(evaluation, 100, "/task", "/tmp/task").found);
	assert(checkDiskCleanupGate(evaluation, 99, "/task", "/tmp/task").found);
	evaluation.usage.taskBytes = -30;
	evaluation.usage.temporaryBytes = 10;
	evaluation.usage.totalBytes = -20;
	assert(!checkDiskCleanupGate(evaluation, 1, "/task", "/tmp/task").found);
	evaluation.usage = typeof(evaluation.usage).init;
	evaluation.nix.entries = [
		NixClosureEntry(["/task/first"], "/nix/store/first", 49),
		NixClosureEntry(["/task/second"], "/nix/store/second", 49),
	];
	assert(!checkDiskCleanupGate(evaluation, 50, "/task", "/tmp/task").found);
	evaluation.nix.entries[1].closureSize = 50;
	auto finding = checkDiskCleanupGate(evaluation, 50, "/task", "/tmp/task");
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
	import cydo.runtime.storage.disk_usage : DiskCategory, DiskUnmeasured;

	DiskEvaluation evaluation;
	evaluation.usage.totalBytes = 99;
	assert(!checkDiskCleanupGate(evaluation, 100, "/task", "/tmp/task").found);
	auto finding = checkDiskCleanupGate(evaluation, 98, "/task", "/tmp/task");
	assert(finding.found);
	assert(finding.vars["unmeasured_paths"] == "(none)");

	evaluation.usage.unmeasured = [
		DiskUnmeasured(DiskCategory.temporary, "nested/blocked", "Permission denied"),
	];
	finding = checkDiskCleanupGate(evaluation, 100, "/task", "/tmp/task");
	assert(finding.found);
	assert(finding.vars["unmeasured_paths"] == "temporary nested/blocked");
}
