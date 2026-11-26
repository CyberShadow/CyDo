module cydo.domain.task_types.catalog;

import core.sys.posix.sys.stat : S_ISDIR;
import std.algorithm : map, reverse, sort;
import std.array : join;
import std.file : exists;
import std.logger : warningf;
import std.path : buildPath;

import cydo.foundation.platform.path : directoryEntryPaths, existingPathAttributes;

import cydo.runtime.config.paths : configDir, configPath, userDefsDir, userTaskTypesPath;
import cydo.runtime.config.yaml : ConfigErrorKind, ConfigFileException;
import cydo.domain.task_types.definition : TaskTypeDef, UserEntryPointDef, SingletonDef, byName, computeReachesWorktree,
	computeTreeReadOnly, composeTaskTypeLayers, readTaskTypeLayers, TaskTypeLayerSource, validateTaskTypes;

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
			throw new ConfigFileException(ConfigErrorKind.unreadable, path, e.msg);
		return null;
	}
}

struct TaskTypeLayers
{
	string[] yamlPaths;
	string[] promptDirs;
}

private TaskTypeLayers discoverConfigLayers(string dir)
{
	TaskTypeLayers layers;
	foreach (pack; taskTypePackDirectories(buildPath(dir, "packs")))
	{
		layers.yamlPaths ~= buildPath(pack, "task-types.yaml");
		layers.promptDirs ~= pack;
	}
	layers.yamlPaths ~= buildPath(dir, "task-types.yaml");
	layers.promptDirs ~= buildPath(dir, "defs");
	reverse(layers.promptDirs);
	return layers;
}

TaskTypeLayers discoverTaskTypeLayers(string taskTypesDir, string taskTypesPath, string projectPath)
{
	auto layers = discoverConfigLayers(configDir());
	layers.yamlPaths = taskTypesPath ~ layers.yamlPaths;
	layers.promptDirs ~= taskTypesDir;
	if (projectPath.length > 0)
	{
		auto project = discoverConfigLayers(buildPath(projectPath, ".cydo"));
		layers.yamlPaths ~= project.yamlPaths;
		layers.promptDirs = project.promptDirs ~ layers.promptDirs;
	}
	return layers;
}

struct TaskTypeSnapshot
{
	TaskTypeDef[] types;
	UserEntryPointDef[] entryPoints;
	SingletonDef[] singletons;
	bool[string] reachesWorktree;
	bool[string] treeReadOnly;
	string[] promptDirs;
}

private struct GlobalState
{
	TaskTypeLayerSource[] sources;
	string[] promptDirs;
	TaskTypeSnapshot snapshot;
}

private struct ProjectState
{
	TaskTypeSnapshot* snapshot;
	string error;
}

class TaskTypeCatalog
{
	private GlobalState global;
	private ProjectState[string] projects;
	private string taskTypesDir;
	private string taskTypesPath;
	private bool delegate(string) isConfiguredAgentName;
	private void delegate(string, string, bool) onProjectLoad;
	private void delegate(string) beforeProjectLoad;

	this(string taskTypesDir, string taskTypesPath, bool delegate(string) isConfiguredAgentName,
		void delegate(string projectPath, string error, bool keptPrevious) onProjectLoad = null,
		void delegate(string projectPath) beforeProjectLoad = null)
	{
		this.taskTypesDir = taskTypesDir;
		this.taskTypesPath = taskTypesPath;
		this.isConfiguredAgentName = isConfiguredAgentName;
		this.onProjectLoad = onProjectLoad is null
			? delegate void(string projectPath, string error, bool keptPrevious) {}
			: onProjectLoad;
		this.beforeProjectLoad = beforeProjectLoad is null
			? delegate void(string projectPath) {}
			: beforeProjectLoad;
	}

	this(string taskTypesDir, string taskTypesPath, bool function(string) isConfiguredAgentName,
		void delegate(string projectPath, string error, bool keptPrevious) onProjectLoad = null,
		void delegate(string projectPath) beforeProjectLoad = null)
	{
		this(taskTypesDir, taskTypesPath, (string name) => isConfiguredAgentName(name),
			onProjectLoad, beforeProjectLoad);
	}

	private static TaskTypeSnapshot buildSnapshot(TaskTypeLayerSource[] sources, string[] promptDirs,
		bool delegate(string) isConfiguredAgentName)
	{
		auto config = composeTaskTypeLayers(sources);
		auto errors = validateTaskTypes(config.types, config.entryPoints, config.singletons,
			isConfiguredAgentName, promptDirs);
		if (errors.length > 0)
			throw new ConfigFileException(ConfigErrorKind.invalid, sources.map!(source => source.path).join(", "),
				errors.join("; "));
		return TaskTypeSnapshot(config.types, config.entryPoints, config.singletons,
			computeReachesWorktree(config.types), computeTreeReadOnly(config.types), promptDirs);
	}

	void reloadGlobal()
	{
		auto layers = discoverTaskTypeLayers(taskTypesDir, taskTypesPath, "");
		auto sources = readTaskTypeLayers(layers.yamlPaths);
		if (sources.length == 0)
			throw new ConfigFileException(ConfigErrorKind.invalid, layers.yamlPaths.join(", "),
				"no task type files found");
		auto snapshot = buildSnapshot(sources, layers.promptDirs, isConfiguredAgentName);
		global = GlobalState(sources, layers.promptDirs, snapshot);
	}

	private void ensureGlobal()
	{
		if (global.sources.length == 0)
			reloadGlobal();
	}

	void reloadProject(string projectPath)
	{
		assert(projectPath.length > 0);
		beforeProjectLoad(projectPath);
		TaskTypeSnapshot* snapshot;
		string error;
		try
		{
			ensureGlobal();
			auto layers = discoverConfigLayers(buildPath(projectPath, ".cydo"));
			auto sources = global.sources ~ readTaskTypeLayers(layers.yamlPaths);
			auto promptDirs = layers.promptDirs ~ global.promptDirs;
			auto built = buildSnapshot(sources, promptDirs, isConfiguredAgentName);
			snapshot = new TaskTypeSnapshot;
			*snapshot = built;
		}
		catch (ConfigFileException e)
			error = e.msg;

		auto state = &projects.require(projectPath, ProjectState.init);
		if (error is null)
			state.snapshot = snapshot;
		state.error = error;
		auto keptPrevious = error !is null && state.snapshot !is null;
		if (error !is null)
			warningf("Project task types rejected for [%s]: %s", projectPath, error);
		onProjectLoad(projectPath, error, keptPrevious);
	}

	void reloadProjects()
	{
		foreach (projectPath; projects.keys)
			reloadProject(projectPath);
	}

	void checkAgents(bool delegate(string) candidate)
	{
		ensureGlobal();
		auto snapshot = &global.snapshot;
		auto errors = validateTaskTypes(snapshot.types, snapshot.entryPoints, snapshot.singletons,
			candidate, snapshot.promptDirs);
		if (errors.length > 0)
			throw new ConfigFileException(ConfigErrorKind.invalid, configPath(), errors.join("; "));
	}

	private TaskTypeSnapshot* ensureProject(string projectPath)
	{
		if (projectPath.length == 0)
		{
			ensureGlobal();
			return &global.snapshot;
		}
		if (projectPath !in projects)
			reloadProject(projectPath);
		return projects[projectPath].snapshot;
	}

	bool hasTaskTypes(string projectPath)
	{
		return ensureProject(projectPath) !is null;
	}

	string loadError(string projectPath)
	{
		ensureProject(projectPath);
		return projectPath.length == 0 ? null : projects[projectPath].error;
	}

	string[] promptSearchPath(string projectPath)
	{
		if (projectPath.length == 0 && global.sources.length > 0)
			return global.snapshot.promptDirs;
		if (auto project = projectPath in projects)
			if (project.snapshot !is null)
				return project.snapshot.promptDirs;
		return discoverTaskTypeLayers(taskTypesDir, taskTypesPath, projectPath).promptDirs;
	}

	TaskTypeDef[] getTaskTypesForProject(string projectPath)
	{
		auto snapshot = ensureProject(projectPath);
		return snapshot is null ? null : snapshot.types;
	}

	UserEntryPointDef[] getEntryPointsForProject(string projectPath)
	{
		auto snapshot = ensureProject(projectPath);
		return snapshot is null ? null : snapshot.entryPoints;
	}

	SingletonDef[] singletonsForProject(string projectPath)
	{
		auto snapshot = ensureProject(projectPath);
		return snapshot is null ? null : snapshot.singletons;
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
		auto snapshot = ensureProject(projectPath);
		return snapshot is null ? null : snapshot.reachesWorktree;
	}

	bool[string] treeReadOnlyFor(string projectPath)
	{
		auto snapshot = ensureProject(projectPath);
		return snapshot is null ? null : snapshot.treeReadOnly;
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

	catalog.reloadProject(projectPath);
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

	catalog.reloadGlobal();
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
		~ "        prompt_template: prompts/blank.md\n"
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
	auto tmp = makeTempRoot("cydo-test-task-type-catalog-rejected-graph");
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
		~ "        prompt_template: prompts/blank.md\n"
		~ "  child:\n"
		~ "    model_class: large\n");

	auto catalog = new TaskTypeCatalog(defsDir, globalPath, &isKnownTestAgent);
	catalog.getTaskTypes();
	catalog.getTaskTypesForProject(projectPath);

	auto projectReachesWorktree = catalog.reachesWorktreeFor(projectPath);
	assert(("root" in projectReachesWorktree) !is null && projectReachesWorktree["root"]);
	auto projectTreeReadOnly = catalog.treeReadOnlyFor(projectPath);
	assert(("root" in projectTreeReadOnly) !is null && !projectTreeReadOnly["root"]);

	assert(!catalog.reachesWorktreeFor("")["root"]);
	assert(catalog.treeReadOnlyFor("")["root"]);

	writeProjectTaskTypes(projectPath, "task_types: [\n");
	catalog.reloadProject(projectPath);
	assert(catalog.loadError(projectPath) !is null);
	assert(catalog.reachesWorktreeFor(projectPath) is projectReachesWorktree);
	assert(catalog.treeReadOnlyFor(projectPath) is projectTreeReadOnly);

	auto cold = new TaskTypeCatalog(defsDir, globalPath, &isKnownTestAgent);
	assert(cold.reachesWorktreeFor(projectPath) is null);
	assert(cold.treeReadOnlyFor(projectPath) is null);
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
	import std.algorithm : startsWith;
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
		if (layer[0].startsWith(fixture.userConfig))
			fixture.catalog.reloadGlobal();
		fixture.catalog.reloadProject(fixture.project);
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
		fixture.catalog.reloadProject(fixture.project);
		assert(fixture.catalog.promptSearchPath(fixture.project) == lastGoodDirs);
		assert(fixture.description() == "shipped");
	}

	fixture.writeLayer(pack, "recovered pack");
	fixture.catalog.reloadProject(fixture.project);
	assert(fixture.catalog.promptSearchPath(fixture.project).canFind(pack));
	assert(fixture.description() == "recovered pack");
}

unittest
{
	import core.sys.posix.unistd : geteuid;
	import std.conv : octal;
	import std.exception : collectException;
	import std.file : setAttributes;

	if (geteuid() == 0)
		return;

	PackCatalogFixture fixture;
	scope (exit) fixture.cleanup();
	fixture.setup("cydo-test-task-type-pack-directory-unreadable");

	auto packs = buildPath(fixture.projectConfig, "packs");
	mkdirRecurse(packs);
	setAttributes(packs, octal!300);
	scope (exit) setAttributes(packs, octal!700);
	auto error = collectException!ConfigFileException(
		discoverTaskTypeLayers(fixture.shipped, buildPath(fixture.shipped, "task-types.yaml"), fixture.project));
	assert(error !is null && error.kind == ConfigErrorKind.unreadable && error.path == packs);
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
	auto error = collectException!ConfigFileException(
		loadTaskTypes(buildPath(fixture.shipped, "task-types.yaml"), packYaml));
	assert(error !is null && error.kind == ConfigErrorKind.unreadable && error.path == packYaml);
	fixture.catalog.reloadProject(fixture.project);
	assert(fixture.description() == "pack");

	setAttributes(pack, octal!700);
	fixture.writeLayer(pack, "updated pack");
	fixture.catalog.reloadProject(fixture.project);
	assert(fixture.description() == "updated pack");
}

unittest
{
	import std.exception : collectException;
	import std.file : remove, rename, symlink;

	PackCatalogFixture fixture;
	scope (exit) fixture.cleanup();
	fixture.setup("cydo-test-task-type-pack-symlink-loop");

	auto packs = buildPath(fixture.projectConfig, "packs");
	auto shippedYaml = buildPath(fixture.shipped, "task-types.yaml");
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
	auto error = collectException!ConfigFileException(
		discoverTaskTypeLayers(fixture.shipped, shippedYaml, fixture.project));
	assert(error !is null && error.kind == ConfigErrorKind.unreadable && error.path == packs);
	fixture.catalog.reloadProject(fixture.project);
	assert(fixture.description() == "pack", "A looping pack entry must reject the reload");
	assert(fixture.catalog.promptSearchPath(fixture.project) == lastGoodDirs);
	remove(pack);
	symlink(target, pack);

	rename(packs, movedPacks);
	symlink(packs, packs);
	error = collectException!ConfigFileException(
		discoverTaskTypeLayers(fixture.shipped, shippedYaml, fixture.project));
	assert(error !is null && error.kind == ConfigErrorKind.unreadable && error.path == packs);
	fixture.catalog.reloadProject(fixture.project);
	assert(fixture.description() == "pack", "A looping packs container must reject the reload");
	assert(fixture.catalog.promptSearchPath(fixture.project) == lastGoodDirs);

	remove(packs);
	rename(movedPacks, packs);
	fixture.writeLayer(target, "restored pack");
	fixture.catalog.reloadProject(fixture.project);
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
	fixture.catalog.reloadProject(fixture.project);
	assert(fixture.description() == "second pack");
	assert(logger.warnings.length == 1, logger.warnings.join("\n"));
	auto warning = logger.warnings[0];
	auto diagnostic = warning[warning.indexOf("]: ") + 3 .. $];
	assert(diagnostic.canFind(secondYaml) && diagnostic.canFind("unknown_field"), warning);
}

unittest // An invalid project override preserves only a previously accepted snapshot.
{
	import std.file : remove;
	import std.typecons : Tuple, tuple;

	PackCatalogFixture fixture;
	fixture.setup("cydo-test-task-type-invalid-project-override");
	scope (exit) fixture.cleanup();
	auto overridePath = buildPath(fixture.projectConfig, "task-types.yaml");
	auto shippedPath = buildPath(fixture.shipped, "task-types.yaml");

	foreach (testCase; [
		tuple("syntax error", "", "task_types: [\n"),
		tuple("invalid", "read_only", PackCatalogFixture.yaml("invalid") ~ "    read_only: [true]\n"),
		tuple("invalid", "unknown_field", PackCatalogFixture.yaml("invalid") ~ "    unknown_field: true\n"),
		tuple("invalid", "references unknown type 'missing'", PackCatalogFixture.yaml("invalid")
			~ "    creatable_tasks:\n      delegate:\n        task_type: missing\n"),
	])
	{
		alias Observation = Tuple!(string, string, bool);
		Observation[] warmLoads, coldLoads;
		fixture.writeLayer(fixture.projectConfig, "last good");
		auto warm = new TaskTypeCatalog(fixture.shipped, shippedPath, &isKnownTestAgent,
			(path, error, kept) { warmLoads ~= tuple(path, error, kept); });
		auto lastGood = warm.getTaskTypesForProject(fixture.project);
		assert(lastGood.byName("sample").agent_description == "last good");
		assert(warmLoads == [tuple(fixture.project, cast(string) null, false)]);

		write(overridePath, testCase[2]);
		auto cold = new TaskTypeCatalog(fixture.shipped, shippedPath, &isKnownTestAgent,
			(path, error, kept) { coldLoads ~= tuple(path, error, kept); });
		assert(cold.getTaskTypesForProject(fixture.project) is null, testCase[2]);
		assert(!cold.hasTaskTypes(fixture.project), testCase[2]);
		auto error = cold.loadError(fixture.project);
		assert(error.canFind(overridePath) && error.canFind(": " ~ testCase[0] ~ ": "), error);
		assert(testCase[1].length == 0 || error.canFind(testCase[1]), error);
		assert(coldLoads == [tuple(fixture.project, error, false)]);

		warm.reloadProject(fixture.project);
		assert(warm.getTaskTypesForProject(fixture.project) is lastGood, testCase[2]);
		assert(warm.hasTaskTypes(fixture.project));
		assert(warm.loadError(fixture.project) == error);
		assert(warmLoads.length == 2 && warmLoads[1] == tuple(fixture.project, error, true));

		remove(overridePath);
		warm.reloadProject(fixture.project);
		assert(warm.getTaskTypesForProject(fixture.project).byName("sample").agent_description == "shipped");
		assert(warm.loadError(fixture.project) is null);
		assert(warmLoads.length == 3
			&& warmLoads[2] == tuple(fixture.project, cast(string) null, false));
	}
}

unittest // Rejected global edits leave the accepted layers available even to cold projects.
{
	import std.exception : collectException;

	PackCatalogFixture fixture;
	fixture.setup("cydo-test-task-type-rejected-global");
	scope (exit) fixture.cleanup();
	fixture.writeLayer(fixture.userConfig, "accepted user");
	auto acceptedGlobal = fixture.catalog.getTaskTypes();
	assert(fixture.description() == "accepted user");
	auto acceptedProject = fixture.catalog.getTaskTypesForProject(fixture.project);

	auto userYaml = buildPath(fixture.userConfig, "task-types.yaml");
	write(userYaml, "task_types: [\n");
	auto cold = new TaskTypeCatalog(fixture.shipped, buildPath(fixture.shipped, "task-types.yaml"),
		&isKnownTestAgent);
	foreach (catalog; [cold, fixture.catalog])
	{
		auto error = collectException!ConfigFileException(catalog.reloadGlobal());
		assert(error !is null && error.kind == ConfigErrorKind.syntax && error.path == userYaml);
	}
	auto error = collectException!ConfigFileException(cold.getTaskTypes());
	assert(error !is null && error.kind == ConfigErrorKind.syntax && error.path == userYaml);
	assert(fixture.catalog.getTaskTypes() is acceptedGlobal);
	assert(fixture.catalog.getTaskTypesForProject(fixture.project) is acceptedProject);

	auto newProject = buildPath(fixture.root, "new-project");
	auto sample = fixture.catalog.getTaskTypesForProject(newProject).byName("sample");
	assert(sample !is null && sample.agent_description == "accepted user");
}

unittest // Global snapshots reject unknown task type references.
{
	import std.exception : collectException;

	PackCatalogFixture fixture;
	fixture.setup("cydo-test-task-type-global-unknown-reference");
	scope (exit) fixture.cleanup();
	auto userYaml = buildPath(fixture.userConfig, "task-types.yaml");
	write(userYaml, PackCatalogFixture.yaml("invalid")
		~ "    creatable_tasks:\n      delegate:\n        task_type: missing\n");

	auto error = collectException!ConfigFileException(fixture.catalog.reloadGlobal());
	assert(error !is null && error.kind == ConfigErrorKind.invalid);
	assert(error.msg.canFind(userYaml) && error.msg.canFind("references unknown type 'missing'"), error.msg);
}

unittest // A candidate agent set must satisfy pins in the accepted global catalog.
{
	import std.exception : collectException;

	PackCatalogFixture fixture;
	fixture.setup("cydo-test-task-type-global-agent-pin");
	scope (exit) fixture.cleanup();
	write(userTaskTypesPath(), PackCatalogFixture.yaml("pinned") ~ "    agent: work-claude\n");
	bool acceptsPinnedAgent(string name)
	{
		return name == "work-claude" || isKnownTestAgent(name);
	}
	auto catalog = new TaskTypeCatalog(fixture.shipped, buildPath(fixture.shipped, "task-types.yaml"),
		&acceptsPinnedAgent);
	catalog.reloadGlobal();

	auto error = collectException!ConfigFileException(catalog.checkAgents(name => isKnownTestAgent(name)));
	assert(error !is null && error.kind == ConfigErrorKind.invalid && error.path == configPath());
	assert(error.msg.canFind("agent 'work-claude' is not a configured agent"), error.msg);
	catalog.checkAgents(&acceptsPinnedAgent);
}

unittest // Invalid prompt sources reject catalog reloads through the typed boundary.
{
	import std.exception : collectException;
	import std.typecons : Tuple, tuple;

	PackCatalogFixture fixture;
	fixture.setup("cydo-test-task-type-invalid-prompt");
	scope (exit) fixture.cleanup();

	enum promptName = "prompts/verifier.md";
	enum entryPoint = "user_entry_points:\n  blank:\n    description: Verifier\n"
		~ "    task_type: blank\n    prompt_template: " ~ promptName ~ "\n";
	auto prompt = buildPath(userDefsDir(), promptName);
	mkdirRecurse(buildPath(userDefsDir(), "prompts"));
	auto invalidUtf = buildPath(userDefsDir(), "prompts", "invalid-utf.md");
	write(invalidUtf, "\xff");
	auto directoryPrompt = buildPath(userDefsDir(), "prompts", "directory.md");
	mkdirRecurse(directoryPrompt);

	alias Observation = Tuple!(string, string, bool);
	Observation[] loads;
	auto catalog = new TaskTypeCatalog(fixture.shipped, buildPath(fixture.shipped, "task-types.yaml"),
		&isKnownTestAgent, (path, error, kept) { loads ~= tuple(path, error, kept); });

	write(prompt, "Valid prompt\n");
	write(userTaskTypesPath(), entryPoint);
	auto acceptedGlobal = catalog.getTaskTypes();
	auto acceptedProject = catalog.getTaskTypesForProject(fixture.project);
	assert(acceptedProject !is null);
	assert(loads == [tuple(fixture.project, cast(string) null, false)]);

	write(prompt, "{{ default }}\n");
	auto agentCheck = collectException!ConfigFileException(catalog.checkAgents(_ => true));
	assert(agentCheck !is null && agentCheck.kind == ConfigErrorKind.invalid && agentCheck.path == configPath());
	assert(agentCheck.msg.canFind(prompt) && agentCheck.msg.canFind("extends {{ default }}"));

	auto coldProject = buildPath(fixture.root, "cold-project");
	foreach (candidate; [
		tuple(promptName, prompt),
		tuple("prompts/directory.md", directoryPrompt),
		tuple("prompts/invalid-utf.md", invalidUtf),
	])
	{
		import std.array : replace;

		auto overlay = entryPoint.replace(promptName, candidate[0]);
		write(userTaskTypesPath(), overlay);
		auto error = collectException!ConfigFileException(catalog.reloadGlobal());
		assert(error !is null && error.kind == ConfigErrorKind.invalid);
		assert(error.msg.canFind(userTaskTypesPath()) && error.msg.canFind(candidate[1]), error.msg);
		assert(catalog.getTaskTypes() is acceptedGlobal);
		assert(catalog.getTaskTypesForProject(fixture.project) is acceptedProject);

		// Restore the prompt used by the accepted global layer when testing the
		// two other project overrides.
		if (candidate[0] != promptName)
			write(prompt, "Valid prompt\n");
		writeProjectTaskTypes(fixture.project, overlay);
		writeProjectTaskTypes(coldProject, overlay);
		catalog.reloadProject(fixture.project);
		assert(catalog.getTaskTypesForProject(fixture.project) is acceptedProject);
		auto warmError = catalog.loadError(fixture.project);
		assert(warmError.canFind(candidate[1]), warmError);
		assert(loads[$ - 1] == tuple(fixture.project, warmError, true));

		// Reuse the cold project state after its first failed attempt.
		catalog.reloadProject(coldProject);
		assert(!catalog.hasTaskTypes(coldProject));
		assert(catalog.getTaskTypesForProject(coldProject) is null);
		auto coldError = catalog.loadError(coldProject);
		assert(coldError.canFind(candidate[1]), coldError);
		assert(loads[$ - 1] == tuple(coldProject, coldError, false));
	}
}
