module cydo.cli.initialize;

import configy.read : parseConfigString;
import cydo.domain.task_types.definition : ContinuationDef, CreatableTaskDef,
	OutputType, SingletonAudience, SingletonDef, TaskTypeDef, TaskTypesFile,
	UserEntryPointDef, WorktreeMode,
	byName, loadTaskTypes;
import cydo.runtime.config : AgentConfig, AgentDriver, CydoConfig,
	GitIdentityConfig, ModelSpecFields, PathMode, PermissionsConfig,
	ProjectDiscoveryConfig, SandboxConfig, WorkspaceConfig;
import dyaml.loader : Loader;
import dyaml.node : Node;

import std.algorithm : canFind, count, sort, startsWith;
import std.array : array, join;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, mkdirRecurse, rmdirRecurse, write;
import std.path : buildPath;
import std.process : environment;
import std.string : indexOf, lineSplitter, strip;
import std.traits : EnumMembers, FieldNameTuple;

enum string configTemplate = import("config.yaml");
enum string taskTypesTemplate = import("task-types.yaml");

private struct TemplateExamples
{
	string complete;
	string[] snippets;
}

private TemplateExamples specimen(string source, string allowedActive)
{
	TemplateExamples result;
	string snippet;
	bool complete;
	size_t active;
	foreach (line; source.lineSplitter)
	{
		if (line.startsWith("# "))
		{
			if (complete)
				result.complete ~= line[2 .. $] ~ "\n";
			else
				snippet ~= line[2 .. $] ~ "\n";
			continue;
		}
		if (snippet.length > 0)
		{
			result.snippets ~= snippet;
			snippet = "";
		}
		switch (line)
		{
			case "## cydo-init: complete-example begin":
				assert(!complete);
				complete = true;
				break;
			case "## cydo-init: complete-example end":
				assert(complete);
				complete = false;
				break;
			default:
				if (line.strip.length == 0 || line == "##" || line.startsWith("## "))
					break;
				assert(line == allowedActive, "unexpected active content: " ~ line);
				++active;
		}
	}
	if (snippet.length > 0)
		result.snippets ~= snippet;
	assert(!complete && result.complete.length > 0);
	assert(active == 1, "template must contain exactly one active root");
	return result;
}

private void assertConfigMarkers()
{
	assert(configTemplate.length >= 2 && configTemplate[$ - 1] == '\n'
		&& configTemplate[$ - 2] != '\n');
	auto begin = "## cydo-init: detected-settings begin";
	auto end = "## cydo-init: detected-settings end";
	auto b = configTemplate.indexOf(begin);
	auto e = configTemplate.indexOf(end);
	assert(b >= 0 && e > b && configTemplate[b + begin.length .. e].strip == "workspaces: {}");
	assert(configTemplate.count(begin) == 1 && configTemplate.count(end) == 1);
}

private string[] nodeKeys(Node node)
{
	string[] result;
	foreach (Node key, Node value; node)
		result ~= key.as!string;
	return result.sort.array;
}

private Node at(Node node, string[] path)
{
	foreach (name; path)
	{
		bool found;
		foreach (Node key, Node value; node)
			if (key.as!string == name)
			{
				node = value;
				found = true;
				break;
			}
		enforce(found, "missing specimen path: " ~ path.join("."));
	}
	return node;
}

private void assertKeys(T)(Node node, string[] omitted = null)
{
	string[] expected;
	foreach (name; FieldNameTuple!T)
		if (omitted is null || !omitted.canFind(name))
			expected ~= name;
	expected.sort;
	assert(nodeKeys(node) == expected, "schema key mismatch for " ~ T.stringof);
}

private void assertEnum(T)(string[] values)
{
	string[] expected;
	foreach (member; EnumMembers!T)
		expected ~= to!string(member);
	expected.sort;
	values.sort;
	assert(values == expected, "enum documentation mismatch for " ~ T.stringof);
}

unittest
{
	// Physical blank lines are layout, including when they contain indentation.
	auto examples = specimen("workspaces: {}\n\n# suggestions: false\n"
		~ "## cydo-init: complete-example begin\n# workspaces:\n \t\n"
		~ "#   example-project: {}\n## cydo-init: complete-example end\n", "workspaces: {}");
	assert(examples.complete == "workspaces:\n  example-project: {}\n");
	assert(examples.snippets == ["suggestions: false\n"]);
}

unittest
{
	auto yaml = specimen(configTemplate, "workspaces: {}").complete;
	assertConfigMarkers();
	auto config = parseConfigString!CydoConfig(yaml, "config-template.yaml");
	auto root = Loader.fromString(yaml).load();
	assertKeys!CydoConfig(root);
	assertKeys!WorkspaceConfig(at(root, ["workspaces", "example-project"]), ["name"]);
	assertKeys!SandboxConfig(at(root, ["sandbox"]));
	assertKeys!GitIdentityConfig(at(root, ["sandbox", "git"]));
	foreach (path; [["agents", "custom-codex", "sandbox"],
		["workspaces", "example-project", "sandbox"]])
	{
		assertKeys!SandboxConfig(at(root, path));
		assertKeys!GitIdentityConfig(at(root, path ~ "git"));
	}
	assertKeys!ProjectDiscoveryConfig(at(root, ["workspaces", "example-project", "project_discovery"]));
	assertKeys!PermissionsConfig(at(root, ["permissions"]));
	assertKeys!AgentConfig(at(root, ["agents", "custom-codex"]), ["permissions"]);
	assertKeys!AgentConfig(at(root, ["agents", "claude-auto"]), ["sandbox", "model_aliases"]);
	assertKeys!ModelSpecFields(at(root, ["agents", "custom-codex", "model_aliases", "large"]));
	assert(config.workspaces[0].sandbox.isolate_filesystem.set);
	assert(config.workspaces[0].permissions.policy.value == "ask");
	assert(config.sandbox.isolate_processes.set);
	assert(config.permissions.policy.value == "{{ 'ask' if tool_name == 'Bash' else 'allow' }}");
	assert(config.permissions.auto_mode.set && !config.permissions.auto_mode.value);
	assert(config.permissions.prompt_timeout.value == 120);
	assert(config.agents["claude-auto"].permissions.auto_mode.value);
	assert(config.agents["custom-codex"].sandbox.isolate_environment.set);
	assert(config.agents["custom-codex"].model_aliases["small"].model == "gpt-5-mini");
	assert(config.agents["custom-codex"].model_aliases["large"].effort == "high");
	string[] pathModes;
	foreach (mode; config.sandbox.paths)
		pathModes ~= to!string(mode);
	assertEnum!PathMode(pathModes);
	string[] drivers;
	foreach (name, ac; config.agents)
		if (ac.driver.set)
			drivers ~= to!string(ac.driver.value);
	assertEnum!AgentDriver(drivers);
}

unittest
{
	auto examples = specimen(taskTypesTemplate, "task_types: {}");
	auto yaml = examples.complete;
	assert(taskTypesTemplate.length >= 2 && taskTypesTemplate[$ - 1] == '\n'
		&& taskTypesTemplate[$ - 2] != '\n');
	auto root = Loader.fromString(yaml).load();
	auto parsed = parseConfigString!TaskTypesFile(yaml, "task-types-template.yaml");
	assertKeys!TaskTypesFile(root);
	assertKeys!TaskTypeDef(at(root, ["task_types", "approval_steward"]), ["name"]);
	assertKeys!CreatableTaskDef(at(root, ["task_types", "coordinator", "creatable_tasks", "implement_change"]),
		["name", "result_note"]);
	assertKeys!CreatableTaskDef(at(root, ["task_types", "research_console", "creatable_tasks", "test"]),
		["name", "task_type", "description"]);
	assertKeys!ContinuationDef(at(root, ["task_types", "coordinator", "continuations", "after_research"]));
	assertKeys!ContinuationDef(at(root, ["task_types", "coordinator", "on_yield"]));
	assertKeys!UserEntryPointDef(at(root, ["user_entry_points", "start_research"]), ["name"]);
	assertKeys!SingletonDef(at(root, ["singletons", "research_desk"]), ["name"]);
	auto researchDesk = byName(parsed.singletons, "research_desk");
	assert(researchDesk !is null);
	assert(researchDesk.task_type == "research_console");
	assert(researchDesk.prompt_template == "prompts/blank.md");

	string[] audiences;
	foreach (example; [yaml] ~ examples.snippets)
	{
		auto sample = Loader.fromString(example).load();
		if (!nodeKeys(sample).canFind("singletons"))
			continue;
		foreach (Node name, Node singleton; sample["singletons"])
			if (nodeKeys(singleton).canFind("offered_to"))
				audiences ~= singleton["offered_to"].as!string;
	}
	import std.algorithm : uniq;
	assertEnum!SingletonAudience(audiences.sort.uniq.array);
	string[] outputs;
	foreach (task; parsed.task_types)
		foreach (output; task.output_type)
			outputs ~= to!string(output);
	assertEnum!OutputType(outputs);
	auto coordinator = byName(parsed.task_types, "coordinator");
	assert(coordinator !is null);
	assertEnum!WorktreeMode([
		to!string(byName(coordinator.creatable_tasks, "quick_research").worktree),
		to!string(byName(coordinator.creatable_tasks, "implement_change").worktree),
		to!string(byName(coordinator.creatable_tasks, "isolated_review").worktree),
	]);
}

unittest
{
	import ae.utils.path : findProgramDirectory;
	import std.file : readText;
	import std.regex : matchAll, matchFirst, regex;

	enum registryFile = "web/src/components/TaskTypeIcon.tsx";
	auto registryPath = environment.get("CYDO_TEST_TASK_TYPE_ICON_SOURCE", "");
	if (registryPath == "")
	{
		auto programDir = findProgramDirectory(registryFile);
		assert(programDir !is null, "Cannot locate " ~ registryFile);
		registryPath = buildPath(programDir, registryFile);
	}

	auto registry = readText(registryPath).matchFirst(
		regex(`(?ms)^const rawIcons\b[^=]*=\s*\{(.*?)^\};`));
	assert(!registry.empty, "Cannot locate rawIcons in " ~ registryPath);
	bool[string] registered;
	foreach (entry; registry[1].matchAll(regex(`(?m)^\s*(?:"([^"]+)"|'([^']+)'|(\w+))\s*:`)))
	{
		auto key = entry[1] ~ entry[2] ~ entry[3];
		registered[key] = true;
	}

	auto examples = specimen(taskTypesTemplate, "task_types: {}");
	size_t iconCount;
	foreach (yaml; [examples.complete] ~ examples.snippets)
	{
		auto root = Loader.fromString(yaml).load();
		if (!nodeKeys(root).canFind("task_types"))
			continue;
		foreach (Node name, Node role; root["task_types"])
		{
			if (!nodeKeys(role).canFind("icon"))
				continue;
			auto icon = role["icon"].as!string;
			assert(icon in registered, "Unknown task-types.yaml example icon: " ~ icon);
			iconCount++;
		}
	}
	assert(iconCount > 0, "No commented icon examples found in task-types.yaml");
}

private string packagedTaskTypesPath()
{
	auto packagedPath = environment.get("CYDO_TEST_PACKAGED_TASK_TYPES", "");
	if (packagedPath == "")
	{
		import ae.utils.path : findProgramDirectory;
		auto programDir = findProgramDirectory("defs/task-types.yaml");
		assert(programDir !is null);
		packagedPath = buildPath(programDir, "defs/task-types.yaml");
	}
	return packagedPath;
}

unittest
{
	auto dir = buildPath("/tmp", "cydo-init-template-overlay");
	if (exists(dir))
		rmdirRecurse(dir);
	mkdirRecurse(dir);
	scope (exit) rmdirRecurse(dir);
	auto overlay = buildPath(dir, "task-types.yaml");
	write(overlay, taskTypesTemplate);
	auto packagedPath = packagedTaskTypesPath();
	auto packaged = loadTaskTypes(packagedPath);
	auto combined = loadTaskTypes(packagedPath, overlay);
	assert(combined.types == packaged.types);
	assert(combined.entryPoints == packaged.entryPoints);
}

version (unittest)
{
	import cydo.domain.task_types.definition : TaskTypeConfig, buildTaskGuidancePromptVars,
		loadTaskTypeSystemPrompt, promptTemplateSource, renderContinuationPrompt,
		renderPrompt, resolveAgent, resolveModelClass, substituteVars;
	private string renderStrictExample(string source, string[string] variables)
	{
		import djinja.ast.node : IdentNode;
		import djinja.djinja : JinjaConfig, loadData;
		import djinja.render : Render;
		import uninode.serialization : serialize = serializeToUniNode;

		enum JinjaConfig syntax = { cmntOpInline: "$$", stmtOpInline: "$$$" };
		class StrictExampleRenderer : Render
		{
			this() { super(loadData!syntax(source)); }

			override void visit(IdentNode node)
			{
				assert(node.name.length == 0 || node.name in variables,
					"Unknown template variable: " ~ node.name ~ " in " ~ source);
				super.visit(node);
			}
		}

		return (new StrictExampleRenderer).render(serialize(variables));
	}

	private string[] exampleNames(Node root, string mapping)
	{
		return nodeKeys(root).canFind(mapping) ? nodeKeys(at(root, [mapping])) : [];
	}

	private void checkTaskExampleRendering(TaskTypeConfig catalog, string[] roles,
		string[] entries, string[] dirs, string workspaceName, string parentDirectory)
	{
		import std.path : dirName;

		enum description = "Example request";
		enum result = "Example predecessor result";
		auto outputFile = buildPath(parentDirectory, "child-task", "output.md");
		auto outputDir = dirName(outputFile);

		void checkPrompt(ref TaskTypeDef role, string path, bool handoff = false)
		{
			auto source = promptTemplateSource(dirs, path);
			string[string] vars = ["task_description": description,
				"output_file": outputFile, "output_dir": outputDir];
			if (role.knowledge_base.length > 0)
				vars["knowledge_base"] = role.knowledge_base;
			string[string] extra;
			if (handoff)
				extra["result_text"] = vars["result_text"] = result;
			assert(renderPrompt(role, description, dirs, outputFile, path, extra)
				== renderStrictExample(source, vars), path);
		}

		void checkContinuation(ref ContinuationDef edge)
		{
			if (edge.prompt_template.length == 0)
				return;
			if (edge.keep_context)
			{
				auto vars = ["result_text": result, "output_dir": parentDirectory];
				assert(renderContinuationPrompt(edge, "Continue", dirs, vars)
					== renderStrictExample(promptTemplateSource(dirs, edge.prompt_template), vars),
					edge.prompt_template);
			}
			else
				checkPrompt(*catalog.types.byName(edge.task_type), edge.prompt_template, true);
		}

		foreach (name; roles)
		{
			auto role = catalog.types.byName(name);
			foreach (parentAgent; ["codex", "claude"])
			{
				auto resolved = resolveAgent(role.agent, parentAgent, workspaceName);
				if (!role.agent.empty)
					assert(resolved == renderStrictExample(role.agent.source,
						["workspace": workspaceName, "parent_agent_type": parentAgent]).strip);
				auto modelClass = resolveModelClass(role.model_class, workspaceName, resolved);
				assert(modelClass == renderStrictExample(role.model_class.source,
					["workspace": workspaceName, "agent": resolved]).strip);
				if (name == "coordinator")
					assert(modelClass == (resolved == "codex" ? "small" : "large"));
			}

			if (role.prompt_template.length > 0)
				checkPrompt(*role, role.prompt_template);
			if (role.system_prompt_template.length > 0)
			{
				auto vars = buildTaskGuidancePromptVars(catalog.types, name, catalog.singletons);
				vars["output_file"] = outputFile;
				vars["output_dir"] = outputDir;
				if (role.knowledge_base.length > 0)
					vars["knowledge_base"] = role.knowledge_base;
				vars["role_prompt"] = renderStrictExample(
					promptTemplateSource(dirs, role.system_prompt_template), vars);
				assert(loadTaskTypeSystemPrompt(*role, catalog.types, name, dirs, outputFile,
					null, catalog.singletons)
					== renderStrictExample(promptTemplateSource(dirs, "system_prompts/master.md"), vars));
			}

			foreach (ref edge; role.creatable_tasks)
			{
				if (edge.prompt_template.length > 0)
					checkPrompt(*catalog.types.byName(edge.resolvedType), edge.prompt_template);
				if (edge.result_note.length > 0)
				{
					auto vars = ["output_dir": parentDirectory];
					auto note = substituteVars(edge.result_note, vars);
					assert(note == renderStrictExample(edge.result_note, vars));
					assert(note.canFind(parentDirectory), edge.result_note);
					assert(catalog.types.byName(edge.resolvedType).output_type.length == 0
						&& edge.worktree == WorktreeMode.inherit);
				}
			}
			foreach (_, ref edge; role.continuations)
				checkContinuation(edge);
			checkContinuation(role.on_yield);
		}

		foreach (name; entries)
		{
			auto entry = catalog.entryPoints.byName(name);
			checkPrompt(*catalog.types.byName(entry.resolvedType), entry.prompt_template);
		}
	}
}

unittest // The complete examples and documented edits load through the runtime.
{
	import cydo.agent.resolver : createConfiguredAgent, effectiveDefaultAgentName,
		isConfiguredAgentName, resolvePermissionSettings;
	import cydo.domain.policy.permissions : evaluatePermissionPolicy;
	import cydo.domain.task_types.definition : validateTaskTypes;
	import cydo.domain.tasks.model : resolveTaskDir;
	import cydo.runtime.launch.sandbox_resolver : resolveSandboxForDiscovery;
	import cydo.server.config_resolution : resolveConfig;
	import cydo.workflow.discovery.scanner : discoverProjects;
	import std.path : dirName;

	auto configExamples = specimen(configTemplate, "workspaces: {}");
	auto config = parseConfigString!CydoConfig(configExamples.complete, "config.yaml");
	resolveConfig(config);
	enum workspaceName = "example-project";
	assert(effectiveDefaultAgentName(config) == "claude");
	assert(effectiveDefaultAgentName(config, workspaceName) == "claude");
	auto agent = createConfiguredAgent(config, "custom-codex");
	agent.setModelAliases(config.agents["custom-codex"].model_aliases);
	auto model = agent.resolveModelSpec("large");
	assert(model.model == "gpt-5" && model.effort == "high");
	auto sandbox = resolveSandboxForDiscovery(config.sandbox,
		config.workspaces[0].sandbox, "/workspace", workspaceName);
	assert(sandbox.env["PATH"] == environment["PATH"]);
	auto globalPolicy = resolvePermissionSettings(config, "claude", "");
	assert(evaluatePermissionPolicy(globalPolicy.policy, globalPolicy.autoMode,
		"Bash", "{}", false, true) == "ask");
	assert(evaluatePermissionPolicy(globalPolicy.policy, globalPolicy.autoMode,
		"Read", "{}", false, true) == "allow");
	assert(resolveTaskDir(7, workspaceName, "/workspace", "/workspace", "/workspace",
		config.task_dir) == "/workspace/.cydo/tasks/7");

	auto root = buildPath("/tmp", "cydo-init-template-examples");
	resetInitializeTestDir(root);
	scope (exit) rmdirRecurse(root);
	auto scanRoot = buildPath(root, "discovery");
	foreach (prefix; ["", "one/two/three"])
	{
		mkdirRecurse(buildPath(scanRoot, prefix, "git-only", ".git"));
		auto packageDir = buildPath(scanRoot, prefix, "package-only");
		mkdirRecurse(packageDir);
		write(buildPath(packageDir, "package.json"), "{}");
	}

	void checkDiscovery(ref WorkspaceConfig workspace, string marker, bool deep)
	{
		import std.algorithm : map;
		auto paths = discoverProjects(scanRoot, workspace.name, workspace.exclude,
			workspace.project_discovery).map!(p => p.path).array;
		paths.sort;
		auto expected = [buildPath(scanRoot, marker)];
		if (deep)
			expected ~= buildPath(scanRoot, "one", "two", "three", marker);
		assert(paths == expected.sort.array,
			workspace.project_discovery.to!string ~ ": " ~ paths.to!string);
	}

	checkDiscovery(config.workspaces[0], "git-only", true);
	foreach (snippet; configExamples.snippets)
	{
		auto yaml = snippet.startsWith("workspaces:") || snippet.canFind("\nworkspaces:")
			? snippet : snippet ~ "workspaces: {}\n";
		auto sample = parseConfigString!CydoConfig(yaml, "config example.yaml");
		resolveConfig(sample);
		foreach (ref workspace; sample.workspaces)
		{
			effectiveDefaultAgentName(sample, workspace.name);
			auto discovery = workspace.project_discovery;
			if (discovery.is_project.length > 0 || discovery.recurse_when.length > 0)
				checkDiscovery(workspace,
					discovery.is_project.length > 0 ? "package-only" : "git-only",
					discovery.recurse_when.length > 0);
		}
	}

	auto taskExamples = specimen(taskTypesTemplate, "task_types: {}");
	auto packaged = packagedTaskTypesPath();
	auto overlay = buildPath(root, "task-types.yaml");
	auto edit = buildPath(root, "edit.yaml");
	write(overlay, taskExamples.complete);
	mkdirRecurse(buildPath(root, "prompts"));
	mkdirRecurse(buildPath(root, "system_prompts"));
	write(buildPath(root, "prompts", "my_task.md"), "Discuss: {{ task_description }}");
	write(buildPath(root, "system_prompts", "my_task.md"), "Guide this research.");
	write(buildPath(root, "prompts", "sample_report.md"),
		"Write a report at {{ output_file }} about: {{ task_description }}");
	write(buildPath(root, "system_prompts", "sample_steward.md"),
		"Review the request for quality and report your findings.");
	auto promptDirs = [root, dirName(packaged)];
	auto configured = (string name) => isConfiguredAgentName(config, name);
	auto catalog = loadTaskTypes(packaged, overlay);
	auto errors = validateTaskTypes(catalog.types, catalog.entryPoints, catalog.singletons,
		configured, promptDirs);
	assert(errors.length == 0, errors.join("\n"));
	auto exampleRoot = Loader.fromString(taskExamples.complete).load();
	auto roles = exampleNames(exampleRoot, "task_types");
	auto entries = exampleNames(exampleRoot, "user_entry_points")
		~ exampleNames(exampleRoot, "singletons") ~ ["integrator"];
	auto parentDirectory = buildPath(root, "parent-task");
	checkTaskExampleRendering(catalog, roles, entries, promptDirs, workspaceName, parentDirectory);
	foreach (snippet; taskExamples.snippets)
	{
		import std.algorithm : uniq;
		write(edit, snippet);
		auto edited = loadTaskTypes(packaged, overlay, edit);
		errors = validateTaskTypes(edited.types, edited.entryPoints, edited.singletons,
			configured, promptDirs);
		assert(errors.length == 0, snippet ~ errors.join("\n"));
		auto editRoot = Loader.fromString(snippet).load();
		auto editedRoles = (roles ~ exampleNames(editRoot, "task_types")).sort.uniq.array;
		auto editedEntries = (entries ~ exampleNames(editRoot, "user_entry_points")).sort.uniq.array;
		checkTaskExampleRendering(edited, editedRoles, editedEntries, promptDirs,
			workspaceName, parentDirectory);
	}

	assert(catalog.entryPoints.byName("research_console").resolvedType == "research_console");
	assert(catalog.entryPoints.byName(config.default_task_type) !is null);
	assert(catalog.entryPoints.byName(config.workspaces[0].default_task_type) !is null);
	auto console = catalog.types.byName("research_console");
	foreach (name; ["coordinator", "report_writer", "approval_steward", "native_helper", "worktree_builder"])
		assert(console.creatable_tasks.byName(name).resolvedType == name);

}

private void resetInitializeTestDir(string path)
{
	if (exists(path))
		rmdirRecurse(path);
	mkdirRecurse(path);
}
