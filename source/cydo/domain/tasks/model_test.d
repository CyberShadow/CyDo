module cydo.domain.tasks.model_test;

import cydo.domain.tasks.model : ProjectRepoResolution, resolveProjectRepo,
	resolveProjectRepoPath;

unittest
{
	import std.exception : assertThrown;
	import std.file : exists, mkdirRecurse, rmdirRecurse;
	import std.path : buildPath;
	import std.process : environment, execute, ProcessException;

	auto root = buildPath("/tmp", "cydo-test-public-project-repo-resolution");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);

	auto plainDir = buildPath(root, "plain");
	auto repoDir = buildPath(root, "repository");
	auto failedProbeRepo = buildPath(root, "probe-failure-repository");
	mkdirRecurse(plainDir);
	mkdirRecurse(repoDir);
	mkdirRecurse(failedProbeRepo);
	assert(execute(["git", "-C", repoDir, "init", "-q"]).status == 0);
	assert(execute(["git", "-C", failedProbeRepo, "init", "-q"]).status == 0);

	ProjectRepoResolution plain = resolveProjectRepo(plainDir);
	assert(!plain.isGitCheckout);
	assert(plain.repoPath == plainDir);
	assert(resolveProjectRepoPath(plainDir) == plain.repoPath);

	ProjectRepoResolution checkout = resolveProjectRepo(repoDir);
	assert(checkout.isGitCheckout);
	assert(checkout.repoPath == repoDir);
	assert(resolveProjectRepoPath(repoDir) == checkout.repoPath);

	auto oldPath = environment.get("PATH", "");
	auto hadPath = "PATH" in environment;
	scope (exit)
	{
		if (hadPath)
			environment["PATH"] = oldPath;
		else
			environment.remove("PATH");
	}
	environment["PATH"] = buildPath(root, "without-git");
	assertThrown!ProcessException(resolveProjectRepo(failedProbeRepo));
}

unittest // Git's record terminator is separate from whitespace in the path.
{
	import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
	import std.path : buildPath;
	import std.process : execute;

	auto root = buildPath(tempDir(), "cydo-test-project-repo-trailing-space");
	if (exists(root))
		rmdirRecurse(root);
	auto repo = buildPath(root, "repository ");
	auto project = buildPath(repo, "subdirectory");
	mkdirRecurse(project);
	scope (exit) rmdirRecurse(root);

	auto result = execute(["git", "-C", repo, "init", "-q"]);
	assert(result.status == 0, result.output);
	assert(resolveProjectRepo(project) == ProjectRepoResolution(repo, true));
}
