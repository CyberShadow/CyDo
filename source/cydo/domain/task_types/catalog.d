module cydo.domain.task_types.catalog;

import core.sys.posix.sys.stat : S_ISDIR;
import std.algorithm : sort;
import std.array : join;
import std.file : exists;
import std.logger : infof, warningf;
import std.path : buildPath;

import cydo.foundation.platform.path : directoryEntryPaths, existingPathAttributes;

import cydo.runtime.config.paths : configDir, userDefsDir, userTaskTypesPath;
import cydo.domain.task_types.definition : TaskTypeDef, UserEntryPointDef, SingletonDef, byName, computeReachesWorktree,
	computeTreeReadOnly, loadTaskTypeLayers, validateTaskTypes;

private string[] orderedPackDirectories(string[] paths)
{
	string[] dirs;
	foreach (path; paths)
		if (S_ISDIR(existingPathAttributes(path)))
			dirs ~= path;
	sort(dirs);
	return dirs;
}

private string[] taskTypePackDirectories(string path)
{
	import core.stdc.errno : ENOENT, ENOTDIR;
	import std.file : FileException;

	try
		return orderedPackDirectories(directoryEntryPaths(path));
	catch (FileException e)
	{
		if (e.errno != ENOENT && e.errno != ENOTDIR)
			throw e;
		return null;
	}
}

struct TaskTypeLayers
{
	string[] yamlPaths;
	string[] promptDirs;
}

TaskTypeLayers discoverTaskTypeLayers(string taskTypesDir, string taskTypesPath, string projectPath)
{
	TaskTypeLayers layers;
	void addLayer(string yamlPath, string promptDir)
	{
		layers.yamlPaths ~= yamlPath;
		layers.promptDirs ~= promptDir;
	}

	void addConfigDirectory(string dir)
	{
		foreach (pack; taskTypePackDirectories(buildPath(dir, "packs")))
			addLayer(buildPath(pack, "task-types.yaml"), pack);
		addLayer(buildPath(dir, "task-types.yaml"), buildPath(dir, "defs"));
	}

	addLayer(taskTypesPath, taskTypesDir);
	addConfigDirectory(configDir());
	if (projectPath.length > 0)
		addConfigDirectory(buildPath(projectPath, ".cydo"));

	import std.algorithm : reverse;
	reverse(layers.promptDirs);
	return layers;
}
import cydo.runtime.config.yaml : yamlConfigDiagnostic;

private struct ProjectTypeCache
{
	TaskTypeDef[] types;
	UserEntryPointDef[] entryPoints;
	SingletonDef[] singletons;
	bool[string] reachesWorktree;
	bool[string] treeReadOnly;
	string[] promptDirs;
	bool stale;
}

class TaskTypeCatalog
{
	private ProjectTypeCache[string] taskTypesByProject;
	private string taskTypesDir;
	private string taskTypesPath;
	private bool delegate(string) isConfiguredAgentName;

	this(string taskTypesDir, string taskTypesPath, bool delegate(string) isConfiguredAgentName)
	{
		this.taskTypesDir = taskTypesDir;
		this.taskTypesPath = taskTypesPath;
		this.isConfiguredAgentName = isConfiguredAgentName;
	}

	this(string taskTypesDir, string taskTypesPath, bool function(string) isConfiguredAgentName)
	{
		this(taskTypesDir, taskTypesPath,
			(string name) => isConfiguredAgentName(name));
	}

	string[] promptSearchPath(string projectPath)
	{
		if (projectPath in taskTypesByProject)
		{
			getTaskTypesForProject(projectPath);
			return taskTypesByProject[projectPath].promptDirs;
		}
		return discoverTaskTypeLayers(taskTypesDir, taskTypesPath, projectPath).promptDirs;
	}

	TaskTypeDef[] getTaskTypesForProject(string projectPath)
	{
		if (auto cache = projectPath in taskTypesByProject)
			if (!cache.stale)
				return cache.types;

		string[] paths;
		try
		{
			auto layers = discoverTaskTypeLayers(taskTypesDir, taskTypesPath, projectPath);
			paths = layers.yamlPaths;
			auto promptDirs = layers.promptDirs;

			string[] loadedPaths;
			auto config = loadTaskTypeLayers(paths, loadedPaths);
			auto errors = validateTaskTypes(config.types, config.entryPoints, config.singletons,
				isConfiguredAgentName, promptDirs);
			foreach (e; errors)
				warningf("task type: %s", e);
			taskTypesByProject[projectPath] = ProjectTypeCache(
				config.types,
				config.entryPoints,
				config.singletons,
				computeReachesWorktree(config.types),
				computeTreeReadOnly(config.types),
				promptDirs,
			);
			infof("Loaded task type YAML layers in order: %s", loadedPaths.join(", "));
			infof("Task type prompt search path: %s", promptDirs.join(", "));
			return config.types;
		}
		catch (Exception e)
		{
			warningf("Failed to load task types from [%s]: %s", paths.join(", "),
				yamlConfigDiagnostic(e));
			if (auto cache = projectPath in taskTypesByProject)
			{
				cache.stale = false;
				return cache.types;
			}
			return null;
		}
	}

	UserEntryPointDef[] getEntryPointsForProject(string projectPath)
	{
		getTaskTypesForProject(projectPath);
		if (auto p = projectPath in taskTypesByProject)
			return p.entryPoints;
		return null;
	}

	SingletonDef[] singletonsForProject(string projectPath)
	{
		getTaskTypesForProject(projectPath);
		if (auto p = projectPath in taskTypesByProject)
			return p.singletons;
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
				if (!p.stale)
					return p.reachesWorktree;
		if (auto p = "" in taskTypesByProject)
			if (!p.stale)
				return p.reachesWorktree;
		return null;
	}

	bool[string] treeReadOnlyFor(string projectPath)
	{
		if (projectPath.length > 0)
			if (auto p = projectPath in taskTypesByProject)
				if (!p.stale)
					return p.treeReadOnly;
		if (auto p = "" in taskTypesByProject)
			if (!p.stale)
				return p.treeReadOnly;
		return null;
	}

	void invalidateProject(string projectPath)
	{
		if (auto cache = projectPath in taskTypesByProject)
			cache.stale = true;
	}

	void invalidateAll()
	{
		foreach (ref cache; taskTypesByProject)
			cache.stale = true;
	}
}

version (unittest)
{
	import std.algorithm : canFind;
	import std.file : mkdirRecurse, rmdirRecurse, write;
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

version (unittest) private bool isKnownTestAgent(string name)
{
	return ["claude", "codex", "copilot"].canFind(name);
}

unittest
{
	auto tmp = makeTempRoot("cydo-test-task-type-catalog-user-project-precedence");
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

	auto defsDir = buildPath(tmp, "built-in-defs");
	auto globalPath = buildPath(defsDir, "task-types.yaml");
	writeGlobalTaskTypes(defsDir,
		"task_types:\n"
		~ "  alpha:\n"
		~ "    model_class: global\n"
		~ "user_entry_points:\n"
		~ "  start:\n"
		~ "    task_type: alpha\n"
		~ "    description: Start\n"
		~ "    prompt_template: prompts/start.md\n");

	mkdirRecurse(userDefsDir());
	writePromptFixture(userDefsDir());
	write(userTaskTypesPath(),
		"task_types:\n"
		~ "  alpha:\n"
		~ "    model_class: user\n");

	auto projectPath = buildPath(tmp, "project");
	writeProjectTaskTypes(projectPath,
		"task_types:\n"
		~ "  alpha:\n"
		~ "    model_class: project\n");

	auto catalog = new TaskTypeCatalog(defsDir, globalPath, &isKnownTestAgent);
	auto alpha = catalog.getTaskTypesForProject(projectPath).byName("alpha");
	assert(alpha !is null);
	assert(alpha.model_class.source == "project");
	assert(catalog.promptSearchPath(projectPath) == [
		buildPath(projectPath, ".cydo/defs"),
		userDefsDir(),
		defsDir,
	]);

	catalog.invalidateProject(projectPath);
	alpha = catalog.getTaskTypesForProject("").byName("alpha");
	assert(alpha !is null);
	assert(alpha.model_class.source == "user");
	assert(catalog.promptSearchPath("") == [userDefsDir(), defsDir]);
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

	auto catalog = new TaskTypeCatalog(defsDir, globalPath, &isKnownTestAgent);
	auto loaded = catalog.getTaskTypesForProject("");
	assert(loaded.byName("alpha") !is null);

	auto projectPath = buildPath(tmp, "project");
	writeProjectTaskTypes(projectPath, "task_types: [\n");
	auto uncached = catalog.getTaskTypesForProject(projectPath);
	assert(uncached is null);
}

unittest
{
	auto tmp = makeTempRoot("cydo-test-task-type-catalog-cache-hit");
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

	auto catalog = new TaskTypeCatalog(defsDir, globalPath, &isKnownTestAgent);
	auto loaded = catalog.getTaskTypesForProject("");
	assert(loaded.byName("alpha") !is null);
	assert(loaded.byName("beta") is null);

	writeGlobalTaskTypes(defsDir,
		"task_types:\n"
		~ "  beta:\n"
		~ "    model_class: large\n"
		~ "user_entry_points:\n"
		~ "  start:\n"
		~ "    task_type: beta\n"
		~ "    description: Start\n"
		~ "    prompt_template: prompts/start.md\n");

	auto stillCached = catalog.getTaskTypesForProject("");
	assert(stillCached.byName("alpha") !is null);
	assert(stillCached.byName("beta") is null);

	catalog.invalidateProject("");
	auto reloaded = catalog.getTaskTypesForProject("");
	assert(reloaded.byName("beta") !is null);
	assert(reloaded.byName("alpha") is null);
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

	auto catalog = new TaskTypeCatalog(defsDir, globalPath, &isKnownTestAgent);
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

	auto catalog = new TaskTypeCatalog(defsDir, globalPath, &isKnownTestAgent);
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

version (unittest) private struct PackCatalogFixture
{
	string root;
	string userConfig;
	string project;
	string projectConfig;
	string shipped;
	TaskTypeCatalog catalog;
	private string oldHome;
	private bool hadHome;

	void setup(string name)
	{
		oldHome = environment.get("HOME", "");
		hadHome = "HOME" in environment;
		root = makeTempRoot(name);
		auto home = buildPath(root, "home");
		userConfig = buildPath(home, ".config", "cydo");
		project = buildPath(root, "project");
		projectConfig = buildPath(project, ".cydo");
		shipped = buildPath(root, "shipped");
		mkdirRecurse(userConfig);
		environment["HOME"] = home;
		writeGlobalTaskTypes(shipped, yaml("shipped"));
		catalog = new TaskTypeCatalog(shipped, buildPath(shipped, "task-types.yaml"), &isKnownTestAgent);
	}

	void cleanup()
	{
		if (hadHome)
			environment["HOME"] = oldHome;
		else
			environment.remove("HOME");
		rmdirRecurse(root);
	}

	static string yaml(string description)
	{
		return "task_types:\n  sample:\n    agent_description: " ~ description ~ "\n";
	}

	void writeLayer(string dir, string description)
	{
		mkdirRecurse(dir);
		write(buildPath(dir, "task-types.yaml"), yaml(description));
	}

	string description()
	{
		auto sample = catalog.getTaskTypesForProject(project).byName("sample");
		assert(sample !is null);
		return sample.agent_description;
	}
}

unittest
{
	import std.file : remove, rmdir, symlink;
	import std.typecons : tuple;

	PackCatalogFixture fixture;
	scope (exit) fixture.cleanup();
	fixture.setup("cydo-test-task-type-pack-precedence");

	auto early = buildPath(fixture.userConfig, "packs", "a-early");
	auto late = buildPath(fixture.userConfig, "packs", "z-late");
	auto projectPack = buildPath(fixture.projectConfig, "packs", "project-pack");
	// Create the user packs in reverse lexical order.
	fixture.writeLayer(late, "late user pack");
	fixture.writeLayer(early, "early user pack");
	fixture.writeLayer(fixture.userConfig, "user YAML");
	fixture.writeLayer(projectPack, "project pack");
	fixture.writeLayer(fixture.projectConfig, "project YAML");

	auto packs = buildPath(fixture.userConfig, "packs");
	auto vanished = buildPath(packs, "vanished");
	auto dangling = buildPath(packs, "dangling");
	mkdirRecurse(vanished);
	symlink(vanished, dangling);
	assert(directoryEntryPaths(packs).canFind(vanished));
	rmdir(vanished);
	assert(orderedPackDirectories([late, vanished, dangling, early]) == [early, late]);

	foreach (layer; [
		tuple(fixture.projectConfig, "project YAML"),
		tuple(projectPack, "project pack"),
		tuple(fixture.userConfig, "user YAML"),
		tuple(late, "late user pack"),
		tuple(early, "early user pack"),
	])
	{
		assert(fixture.description() == layer[1], layer[1]);
		remove(buildPath(layer[0], "task-types.yaml"));
		fixture.catalog.invalidateProject(fixture.project);
	}
	assert(fixture.description() == "shipped");
}

unittest
{
	import cydo.domain.task_types.definition : promptTemplateSource;

	PackCatalogFixture fixture;
	scope (exit) fixture.cleanup();
	fixture.setup("cydo-test-task-type-pack-prompts");

	auto userPromptPack = buildPath(fixture.userConfig, "packs", "prompts");
	auto projectPromptPack = buildPath(fixture.projectConfig, "packs", "a-prompts");
	auto yamlOnlyPack = buildPath(fixture.projectConfig, "packs", "z-types");
	fixture.writeLayer(yamlOnlyPack, "YAML-only pack");

	enum prompt = "prompts/start.md";
	mkdirRecurse(buildPath(userPromptPack, "prompts"));
	mkdirRecurse(buildPath(projectPromptPack, "prompts"));
	write(buildPath(fixture.shipped, prompt), "shipped");
	write(buildPath(userPromptPack, prompt), "{{ default }}\nuser pack");
	write(buildPath(projectPromptPack, prompt), "project pack\n{{ default }}");

	assert(fixture.description() == "YAML-only pack");
	assert(promptTemplateSource(fixture.catalog.promptSearchPath(fixture.project), prompt)
		== "project pack\nshipped\nuser pack");
}

unittest
{
	PackCatalogFixture fixture;
	scope (exit) fixture.cleanup();
	fixture.setup("cydo-test-task-type-pack-last-good");

	assert(fixture.description() == "shipped");
	auto lastGoodDirs = fixture.catalog.promptSearchPath(fixture.project).dup;
	fixture.writeLayer(fixture.shipped, "updated shipped");
	auto pack = buildPath(fixture.projectConfig, "packs", "new-pack");
	mkdirRecurse(pack);
	foreach (invalid; ["task_types: [\n", "- invalid overlay\n"])
	{
		write(buildPath(pack, "task-types.yaml"), invalid);
		fixture.catalog.invalidateProject(fixture.project);
		assert(fixture.catalog.promptSearchPath(fixture.project) == lastGoodDirs);
		assert(fixture.description() == "shipped");
	}

	fixture.writeLayer(pack, "recovered pack");
	fixture.catalog.invalidateProject(fixture.project);
	assert(fixture.catalog.promptSearchPath(fixture.project).canFind(pack));
	assert(fixture.description() == "recovered pack");
}

unittest
{
	import core.sys.posix.unistd : geteuid;
	import std.conv : octal;
	import std.exception : collectException;
	import std.file : setAttributes;
	import cydo.domain.task_types.definition : loadTaskTypes;

	// A privileged process can open a file in a directory without search permission.
	if (geteuid() == 0)
		return;

	PackCatalogFixture fixture;
	scope (exit) fixture.cleanup();
	fixture.setup("cydo-test-task-type-pack-inaccessible");

	auto pack = buildPath(fixture.projectConfig, "packs", "restricted");
	auto packYaml = buildPath(pack, "task-types.yaml");
	fixture.writeLayer(pack, "pack");
	assert(fixture.description() == "pack");
	fixture.writeLayer(fixture.shipped, "updated shipped");

	setAttributes(pack, octal!600);
	scope (exit) setAttributes(pack, octal!700);
	auto error = collectException(loadTaskTypes(buildPath(fixture.shipped, "task-types.yaml"), packYaml));
	assert(error !is null && error.msg.canFind(packYaml));
	fixture.catalog.invalidateProject(fixture.project);
	assert(fixture.description() == "pack");

	setAttributes(pack, octal!700);
	fixture.writeLayer(pack, "updated pack");
	fixture.catalog.invalidateProject(fixture.project);
	assert(fixture.description() == "updated pack");
}

unittest
{
	import std.file : remove, rename, symlink;

	PackCatalogFixture fixture;
	scope (exit) fixture.cleanup();
	fixture.setup("cydo-test-task-type-pack-symlink-loop");

	auto packs = buildPath(fixture.projectConfig, "packs");
	auto pack = buildPath(packs, "linked");
	auto target = buildPath(fixture.root, "pack-target");
	auto movedPacks = buildPath(fixture.root, "moved-packs");
	fixture.writeLayer(target, "pack");
	mkdirRecurse(packs);
	symlink(target, pack);
	assert(fixture.description() == "pack");
	auto lastGoodDirs = fixture.catalog.promptSearchPath(fixture.project).dup;

	remove(pack);
	symlink(pack, pack);
	fixture.catalog.invalidateProject(fixture.project);
	assert(fixture.description() == "pack", "A looping pack entry must reject the reload");
	assert(fixture.catalog.promptSearchPath(fixture.project) == lastGoodDirs);
	remove(pack);
	symlink(target, pack);

	rename(packs, movedPacks);
	symlink(packs, packs);
	fixture.catalog.invalidateProject(fixture.project);
	assert(fixture.description() == "pack", "A looping packs container must reject the reload");
	assert(fixture.catalog.promptSearchPath(fixture.project) == lastGoodDirs);

	remove(packs);
	rename(movedPacks, packs);
	fixture.writeLayer(target, "restored pack");
	fixture.catalog.invalidateProject(fixture.project);
	assert(fixture.description() == "restored pack");
}

unittest
{
	import std.logger.core : Logger, LogLevel, stdThreadLocalLog;
	import std.string : indexOf;

	final class WarningLogger : Logger
	{
		string[] warnings;

		this()
		{
			super(LogLevel.warning);
		}

		override protected void writeLogMsg(ref LogEntry entry) @safe
		{
			warnings ~= entry.msg;
		}
	}

	PackCatalogFixture fixture;
	scope (exit) fixture.cleanup();
	fixture.setup("cydo-test-task-type-pack-schema-error");

	auto first = buildPath(fixture.projectConfig, "packs", "10-first");
	auto second = buildPath(fixture.projectConfig, "packs", "20-second");
	auto secondYaml = buildPath(second, "task-types.yaml");
	fixture.writeLayer(first, "first pack");
	fixture.writeLayer(second, "second pack");
	assert(fixture.description() == "second pack");
	write(secondYaml, "task_types:\n  sample:\n    unknown_field: true\n");

	auto previous = stdThreadLocalLog;
	scope (exit) stdThreadLocalLog = previous;
	auto logger = new WarningLogger;
	stdThreadLocalLog = logger;
	fixture.catalog.invalidateProject(fixture.project);
	assert(fixture.description() == "second pack");
	assert(logger.warnings.length == 1, logger.warnings.join("\n"));
	auto warning = logger.warnings[0];
	auto diagnostic = warning[warning.indexOf("]: ") + 3 .. $];
	assert(diagnostic.canFind(secondYaml) && diagnostic.canFind("unknown_field"), warning);
}
