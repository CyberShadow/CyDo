module cydo.cli.tasktype_config;

import std.stdio : stderr;

import cydo.domain.task_types.definition : TaskTypeConfig;

private string selectTaskTypeProject(string cwd, string project)
{
	import cydo.domain.tasks.model : resolveProjectRepo;
	import cydo.foundation.platform.path : canonicalProjectPath;

	if (project !is null)
		return canonicalProjectPath(project);

	auto repo = resolveProjectRepo(cwd);
	return repo.isGitCheckout ? repo.repoPath : null;
}

unittest
{
	import ae.sys.file : realPath;
	import std.exception : assertThrown;
	import std.file : mkdirRecurse, rmdirRecurse, tempDir;
	import std.path : buildPath;
	import std.process : execute;
	import std.uuid : randomUUID;

	auto root = buildPath(realPath(tempDir()), "cydo-task-type-project-" ~ randomUUID().toString());
	mkdirRecurse(root);
	scope (exit) rmdirRecurse(root);

	auto repo = buildPath(root, "repo");
	auto nested = buildPath(repo, "src", "nested");
	auto plain = buildPath(root, "plain");
	mkdirRecurse(nested);
	mkdirRecurse(plain);
	auto init = execute(["git", "-C", repo, "init", "-q"]);
	assert(init.status == 0, init.output);

	assert(selectTaskTypeProject(nested, null) == repo);
	assert(selectTaskTypeProject(nested, plain) == plain);
	assert(selectTaskTypeProject(plain, null) is null);
	assertThrown!Exception(selectTaskTypeProject(nested, buildPath(root, "missing")));
}

TaskTypeConfig loadCliTaskTypes(string taskTypesPath, string project, out string[] promptDirs)
{
	import std.array : join;
	import std.file : getcwd;
	import std.path : dirName;

	import cydo.domain.task_types.catalog : discoverTaskTypeLayers;
	import cydo.domain.task_types.definition : loadTaskTypeLayers;

	auto layers = discoverTaskTypeLayers(dirName(taskTypesPath), taskTypesPath,
		selectTaskTypeProject(getcwd(), project));
	promptDirs = layers.promptDirs;
	string[] loadedPaths;
	auto config = loadTaskTypeLayers(layers.yamlPaths, loadedPaths);
	stderr.writefln("Loaded task type YAML layers in order: %s", loadedPaths.join(", "));
	stderr.writefln("Task type prompt search path: %s", promptDirs.join(", "));
	return config;
}
