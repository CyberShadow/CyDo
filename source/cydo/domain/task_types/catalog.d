module cydo.domain.task_types.catalog;

import std.logger : warningf;

import cydo.domain.task_types.definition : TaskTypeDef, UserEntryPointDef, byName, computeReachesWorktree,
	computeTreeReadOnly, loadTaskTypes, validateTaskTypes;

private struct ProjectTypeCache
{
	TaskTypeDef[] types;
	UserEntryPointDef[] entryPoints;
	bool[string] reachesWorktree;
	bool[string] treeReadOnly;
}

class TaskTypeCatalog
{
	private ProjectTypeCache[string] taskTypesByProject;
	private string taskTypesDir;
	private string taskTypesPath;

	this(string taskTypesDir, string taskTypesPath)
	{
		this.taskTypesDir = taskTypesDir;
		this.taskTypesPath = taskTypesPath;
	}

	string[] promptSearchPath(string projectPath)
	{
		import std.path : buildPath, expandTilde;

		string[] dirs;
		if (projectPath.length > 0)
			dirs ~= buildPath(projectPath, ".cydo/defs");
		dirs ~= buildPath(expandTilde("~/.config/cydo"), "defs");
		dirs ~= taskTypesDir;
		return dirs;
	}

	TaskTypeDef[] getTaskTypesForProject(string projectPath)
	{
		import std.path : buildPath, expandTilde;

		try
		{
			auto userTypesPath = buildPath(expandTilde("~/.config/cydo"), "task-types.yaml");
			auto projectTypesPath = projectPath.length > 0
				? buildPath(projectPath, ".cydo/task-types.yaml") : "";
			auto config = loadTaskTypes(taskTypesPath, userTypesPath, projectTypesPath);
			auto errors = validateTaskTypes(config.types, config.entryPoints, promptSearchPath(projectPath));
			foreach (e; errors)
				warningf("task type: %s", e);
			taskTypesByProject[projectPath] = ProjectTypeCache(
				config.types,
				config.entryPoints,
				computeReachesWorktree(config.types),
				computeTreeReadOnly(config.types),
			);
			return taskTypesByProject[projectPath].types;
		}
		catch (Exception e)
		{
			warningf("task types file changed but failed to parse, keeping previous version: %s", e.msg);
			if (auto p = projectPath in taskTypesByProject)
				return p.types;
			return null;
		}
	}

	UserEntryPointDef[] getEntryPointsForProject(string projectPath)
	{
		if (auto p = projectPath in taskTypesByProject)
			return p.entryPoints;
		getTaskTypesForProject(projectPath);
		if (auto p = projectPath in taskTypesByProject)
			return p.entryPoints;
		return null;
	}

	TaskTypeDef[] getTaskTypes()
	{
		return getTaskTypesForProject("");
	}

	UserEntryPointDef[] getEntryPoints()
	{
		return getEntryPointsForProject("");
	}

	bool[string] reachesWorktreeFor(string projectPath)
	{
		if (projectPath.length > 0)
			if (auto p = projectPath in taskTypesByProject)
				return p.reachesWorktree;
		if (auto p = "" in taskTypesByProject)
			return p.reachesWorktree;
		return null;
	}

	bool[string] treeReadOnlyFor(string projectPath)
	{
		if (projectPath.length > 0)
			if (auto p = projectPath in taskTypesByProject)
				return p.treeReadOnly;
		if (auto p = "" in taskTypesByProject)
			return p.treeReadOnly;
		return null;
	}

	void invalidateProject(string projectPath)
	{
		taskTypesByProject.remove(projectPath);
	}

	void invalidateAll()
	{
		taskTypesByProject = null;
	}
}

version (unittest)
{
	import std.algorithm : canFind;
	import std.file : exists, mkdirRecurse, rmdirRecurse, write;
	import std.path : buildPath;
	import std.process : environment;
}

version (unittest) private string makeTempRoot(string name)
{
	return buildPath("/tmp", name);
}

version (unittest) private void writePromptFixture(string defsDir)
{
	mkdirRecurse(buildPath(defsDir, "prompts"));
	write(buildPath(defsDir, "prompts", "blank.md"), "Blank prompt\n");
	write(buildPath(defsDir, "prompts", "start.md"), "Start prompt\n");
}

version (unittest) private void writeGlobalTaskTypes(string defsDir, string yaml)
{
	mkdirRecurse(defsDir);
	writePromptFixture(defsDir);
	write(buildPath(defsDir, "task-types.yaml"), yaml);
}

version (unittest) private void writeProjectTaskTypes(string projectPath, string yaml)
{
	mkdirRecurse(buildPath(projectPath, ".cydo"));
	write(buildPath(projectPath, ".cydo", "task-types.yaml"), yaml);
}

unittest
{
	auto tmp = makeTempRoot("cydo-test-task-type-catalog-fallback");
	scope (exit)
	{
		if (exists(tmp))
			rmdirRecurse(tmp);
	}
	mkdirRecurse(tmp);

	auto oldHome = environment.get("HOME", "");
	auto hadHome = "HOME" in environment;
	scope (exit)
	{
		if (hadHome)
			environment["HOME"] = oldHome;
		else
			environment.remove("HOME");
	}
	auto home = buildPath(tmp, "home");
	mkdirRecurse(home);
	environment["HOME"] = home;

	auto defsDir = buildPath(tmp, "defs");
	auto globalPath = buildPath(defsDir, "task-types.yaml");
	writeGlobalTaskTypes(defsDir,
		"task_types:\n"
		~ "  alpha:\n"
		~ "    model_class: large\n"
		~ "user_entry_points:\n"
		~ "  start:\n"
		~ "    task_type: alpha\n"
		~ "    description: Start\n"
		~ "    prompt_template: prompts/start.md\n");

	auto catalog = new TaskTypeCatalog(defsDir, globalPath);
	auto loaded = catalog.getTaskTypesForProject("");
	assert(loaded.byName("alpha") !is null);

	write(globalPath, "task_types: [\n");
	auto cached = catalog.getTaskTypesForProject("");
	assert(cached.byName("alpha") !is null);
	assert(cached.canFind!(t => t.name == "blank"));
}

unittest
{
	auto tmp = makeTempRoot("cydo-test-task-type-catalog-worktree-fallback");
	scope (exit)
	{
		if (exists(tmp))
			rmdirRecurse(tmp);
	}
	mkdirRecurse(tmp);

	auto oldHome = environment.get("HOME", "");
	auto hadHome = "HOME" in environment;
	scope (exit)
	{
		if (hadHome)
			environment["HOME"] = oldHome;
		else
			environment.remove("HOME");
	}
	auto home = buildPath(tmp, "home");
	mkdirRecurse(home);
	environment["HOME"] = home;

	auto defsDir = buildPath(tmp, "defs");
	auto globalPath = buildPath(defsDir, "task-types.yaml");
	writeGlobalTaskTypes(defsDir,
		"task_types:\n"
		~ "  root:\n"
		~ "    model_class: large\n"
		~ "    read_only: true\n"
		~ "    creatable_tasks:\n"
		~ "      child:\n"
		~ "        worktree: require\n"
		~ "  child:\n"
		~ "    model_class: large\n"
		~ "    read_only: true\n"
		~ "user_entry_points:\n"
		~ "  start:\n"
		~ "    task_type: root\n"
		~ "    description: Start\n"
		~ "    prompt_template: prompts/start.md\n");

	auto catalog = new TaskTypeCatalog(defsDir, globalPath);
	catalog.getTaskTypes();

	auto projectPath = buildPath(tmp, "project");
	auto reachesWorktree = catalog.reachesWorktreeFor(projectPath);
	assert(("root" in reachesWorktree) !is null && reachesWorktree["root"]);
	auto treeReadOnly = catalog.treeReadOnlyFor(projectPath);
	assert(("root" in treeReadOnly) !is null && treeReadOnly["root"]);
	assert(("child" in treeReadOnly) !is null && treeReadOnly["child"]);
}

unittest
{
	auto tmp = makeTempRoot("cydo-test-task-type-catalog-invalidation");
	scope (exit)
	{
		if (exists(tmp))
			rmdirRecurse(tmp);
	}
	mkdirRecurse(tmp);

	auto oldHome = environment.get("HOME", "");
	auto hadHome = "HOME" in environment;
	scope (exit)
	{
		if (hadHome)
			environment["HOME"] = oldHome;
		else
			environment.remove("HOME");
	}
	auto home = buildPath(tmp, "home");
	mkdirRecurse(home);
	environment["HOME"] = home;

	auto defsDir = buildPath(tmp, "defs");
	auto globalPath = buildPath(defsDir, "task-types.yaml");
	writeGlobalTaskTypes(defsDir,
		"task_types:\n"
		~ "  root:\n"
		~ "    model_class: large\n"
		~ "    read_only: true\n"
		~ "user_entry_points:\n"
		~ "  start:\n"
		~ "    task_type: root\n"
		~ "    description: Start\n"
		~ "    prompt_template: prompts/start.md\n");

	auto projectPath = buildPath(tmp, "project");
	writeProjectTaskTypes(projectPath,
		"task_types:\n"
		~ "  root:\n"
		~ "    model_class: large\n"
		~ "    read_only: false\n"
		~ "    creatable_tasks:\n"
		~ "      child:\n"
		~ "        worktree: require\n"
		~ "  child:\n"
		~ "    model_class: large\n");

	auto catalog = new TaskTypeCatalog(defsDir, globalPath);
	catalog.getTaskTypes();
	catalog.getTaskTypesForProject(projectPath);

	auto projectReachesWorktree = catalog.reachesWorktreeFor(projectPath);
	assert(("root" in projectReachesWorktree) !is null && projectReachesWorktree["root"]);
	auto projectTreeReadOnly = catalog.treeReadOnlyFor(projectPath);
	assert(("root" in projectTreeReadOnly) !is null && !projectTreeReadOnly["root"]);

	catalog.invalidateProject(projectPath);

	auto fallbackReachesWorktree = catalog.reachesWorktreeFor(projectPath);
	assert(("root" in fallbackReachesWorktree) !is null && !fallbackReachesWorktree["root"]);
	auto fallbackTreeReadOnly = catalog.treeReadOnlyFor(projectPath);
	assert(("root" in fallbackTreeReadOnly) !is null && fallbackTreeReadOnly["root"]);

	catalog.invalidateAll();
	assert(catalog.reachesWorktreeFor(projectPath) is null);
	assert(catalog.treeReadOnlyFor(projectPath) is null);
	assert(catalog.reachesWorktreeFor("") is null);
	assert(catalog.treeReadOnlyFor("") is null);
}
