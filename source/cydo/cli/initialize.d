module cydo.cli.initialize;

import ae.sys.file : openFile;
import cydo.cli.init_detection : DetectedWorkspace, detectInitWorkspaces;
import cydo.domain.task_types.definition : ContinuationDef, CreatableEntryPointDef, CreatableTaskDef,
	OutputType, SingletonAudience, SingletonDef, TaskTypeDef, TaskTypesFile,
	UserEntryPointDef, WorktreeMode,
	byName, loadTaskTypes;
import cydo.runtime.config : AgentConfig, AgentDriver, CydoConfig, loadConfig,
	GitIdentityConfig, ModelSpecFields, PathMode, PermissionsConfig,
	ProjectDiscoveryConfig, SandboxConfig, UiConfig, UsageUiConfig, WorkspaceConfig;
import cydo.runtime.config.paths : configDir, configPath, userTaskTypesPath;
import cydo.runtime.config.yaml : loadYamlString, parseYamlConfigString;
import dyaml.node : Node;

import std.algorithm : canFind, count, sort, startsWith;
import std.array : array, join;
import std.conv : to;
import std.exception : assertThrown, enforce;
import std.file : FileException, SpanMode, dirEntries, exists, isDir, isSymlink,
	mkdirRecurse, read, readLink, remove, rmdirRecurse, symlink, write;
import std.path : baseName, buildPath;
import std.process : environment;
import std.stdio : File, writeln;
import std.string : indexOf, lineSplitter, strip;
import std.traits : EnumMembers, FieldNameTuple, getUDAs;

version (unittest) import cydo.domain.task_types.definition : packagedTaskTypesPath;

import core.stdc.errno : ENOENT;
import object : Throwable;

enum string configTemplate = import("config.yaml");
enum string taskTypesTemplate = import("task-types.yaml");

private enum beginMarker = "## cydo-init: detected-settings begin";
private enum endMarker = "## cydo-init: detected-settings end";

private string quoteYamlScalar(string value)
{
	import std.array : appender;
	import std.format : formattedWrite;

	auto quoted = appender!string();
	quoted.put('"');
	foreach (dchar c; value)
	{
		if (c == '"' || c == '\\')
		{
			quoted.put('\\');
			quoted.put(c);
		}
		else if (c < 0x20 || (c >= 0x7F && c <= 0x9F))
			quoted.formattedWrite("\\x%02X", cast(uint) c);
		else if (c == 0x2028 || c == 0x2029 || c == 0xFEFF
			|| c == 0xFFFE || c == 0xFFFF)
			quoted.formattedWrite("\\u%04X", cast(uint) c);
		else
			quoted.put(c);
	}
	quoted.put('"');
	return quoted.data;
}

/// Render the authored configuration with the selected workspace roots.
string renderInitConfig(DetectedWorkspace[] workspaces, string source = configTemplate)
{
	auto begin = source.indexOf(beginMarker);
	auto end = source.indexOf(endMarker);
	enforce(source.length > 0 && source[$ - 1] == '\n'
		&& begin >= 0 && end >= 0 && begin < end,
		"config template must contain one ordered detected-settings marker pair");
	enforce(source.count(beginMarker) == 1 && source.count(endMarker) == 1,
		"config template must contain exactly one detected-settings marker pair");
	enforce((begin == 0 || source[begin - 1] == '\n')
		&& begin + beginMarker.length < source.length
		&& source[begin + beginMarker.length] == '\n'
		&& (end == 0 || source[end - 1] == '\n')
		&& end + endMarker.length < source.length
		&& source[end + endMarker.length] == '\n',
		"config template markers must each occupy one complete line");
	auto contentStart = begin + beginMarker.length;
	string settings;
	if (workspaces.length == 0)
		settings = "\nworkspaces: {}\n";
	else
	{
		settings = "\nworkspaces:\n";
		foreach (workspace; workspaces)
			settings ~= "  " ~ quoteYamlScalar(workspace.name) ~ ":\n"
				~ "    root: " ~ quoteYamlScalar(workspace.root) ~ "\n";
	}
	return source[0 .. contentStart] ~ settings ~ source[end .. $];
}

alias InitRenderer = string delegate(DetectedWorkspace[] workspaces);

private void validateInitDocuments(string renderedConfig)
{
	parseYamlConfigString!CydoConfig(renderedConfig, "generated config.yaml");
	parseYamlConfigString!TaskTypesFile(taskTypesTemplate, "embedded task-types.yaml");
}

private void ensureUnoccupied(string path)
{
	if (exists(path))
		enforce(false, "configuration target already exists: " ~ path);
	try
	{
		if (isSymlink(path))
			enforce(false, "configuration target already exists: " ~ path);
	}
	catch (FileException e)
	{
		if (e.errno == ENOENT)
			return;
		throw e;
	}
}

alias InitContentWriter = void delegate(ref File file, string contents);

private void writeFileContents(ref File file, string contents)
{
	file.write(contents);
}

private void writeNewFile(string path, string contents,
	InitContentWriter contentWriter, ref string[] created)
{
	if (contentWriter is null)
		contentWriter = (ref File file, string text) { writeFileContents(file, text); };
	auto file = openFile(path, "wxb");
	created ~= path;
	contentWriter(file, contents);
	file.close();
}

private void removeCreatedFiles(string[] created, Exception original)
{
	Throwable cleanupErrors;
	foreach (path; created)
		try remove(path);
		catch (Exception e) cleanupErrors = Throwable.chainTogether(cleanupErrors, e);
	if (cleanupErrors !is null)
		original.next = Throwable.chainTogether(original.next, cleanupErrors);
}

/// Validate and install the canonical user configuration file pair.
void installInitConfiguration(DetectedWorkspace[] workspaces)
{
	installInitConfiguration(workspaces,
		null, null);
}

/// Test seams for an induced exclusive-write or rendering failure.
void installInitConfiguration(DetectedWorkspace[] workspaces,
	InitContentWriter contentWriter = null, InitRenderer renderer = null)
{
	if (renderer is null)
		renderer = (DetectedWorkspace[] selected) { return renderInitConfig(selected); };
	auto renderedConfig = renderer(workspaces);
	validateInitDocuments(renderedConfig);

	auto mainPath = configPath();
	auto taskTypesPath = userTaskTypesPath();
	ensureUnoccupied(mainPath);
	ensureUnoccupied(taskTypesPath);
	if (exists(configDir()))
		enforce(isDir(configDir()), "configuration directory is not a directory: " ~ configDir());
	else
		mkdirRecurse(configDir());

	string[] created;
	try
	{
		writeNewFile(mainPath, renderedConfig, contentWriter, created);
		writeNewFile(taskTypesPath, taskTypesTemplate, contentWriter, created);
	}
	catch (Exception e)
	{
		removeCreatedFiles(created, e);
		throw e;
	}
}

private void reportInitConfiguration(DetectedWorkspace[] workspaces,
	void delegate(string) output)
{
	output("Installed " ~ quoteYamlScalar(configPath()));
	output("Installed " ~ quoteYamlScalar(userTaskTypesPath()));
	output("Restart CyDo if init created its config directory while CyDo was running.");
	if (workspaces.length == 0)
		output("No workspaces were detected; the HOME local fallback applies.");
	else
		foreach (workspace; workspaces)
			output("Detected " ~ quoteYamlScalar(workspace.name) ~ " "
				~ quoteYamlScalar(workspace.root));
}

/// Detect and install the initial user configuration without starting the app.
void initializeUserConfiguration()
{
	auto workspaces = detectInitWorkspaces();
	initializeUserConfiguration(workspaces, (string line) { writeln(line); });
}

/// Test seam that keeps initialization independent of history and server startup.
void initializeUserConfiguration(DetectedWorkspace[] workspaces,
	void delegate(string) output)
{
	installInitConfiguration(workspaces);
	reportInitConfiguration(workspaces, output);
}

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
	import configy.attributes : Name;

	string[] expected;
	foreach (name; FieldNameTuple!T)
	{
		alias names = getUDAs!(__traits(getMember, T, name), Name);
		static if (names.length)
			enum key = names[0].name;
		else
			enum key = name;
		if (!omitted.canFind(key))
			expected ~= key;
	}
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
	auto config = parseYamlConfigString!CydoConfig(yaml, "config-template.yaml");
	auto root = loadYamlString(yaml, "config-template.yaml");
	assertKeys!CydoConfig(root);
	assertKeys!UiConfig(at(root, ["ui"]));
	assertKeys!UsageUiConfig(at(root, ["ui", "usage"]));
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
	assertKeys!AgentConfig(at(root, ["agents", "custom-codex"]), ["permissions", "usage_polling_period"]);
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
	auto root = loadYamlString(yaml, "task-types-template.yaml");
	auto parsed = parseYamlConfigString!TaskTypesFile(yaml, "task-types-template.yaml");
	assertKeys!TaskTypesFile(root);
	assertKeys!TaskTypeDef(at(root, ["task_types", "approval_steward"]), ["name"]);
	assertKeys!CreatableTaskDef(at(root, ["task_types", "coordinator", "creatable_tasks", "implement_change"]),
		["name", "result_note"]);
	assertKeys!CreatableTaskDef(at(root, ["task_types", "research_console", "creatable_tasks", "test"]),
		["name", "task_type", "description"]);
	assertKeys!CreatableEntryPointDef(
		at(root, ["task_types", "research_console", "creatable_entry_points", "start_research"]), ["name"]);
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
		auto sample = loadYamlString(example, "task-types example.yaml");
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
		auto root = loadYamlString(yaml, "task-types example.yaml");
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

unittest
{
	import std.algorithm : map;
	import cydo.domain.task_types.definition : creatableEntryPointsOf;

	auto packaged = loadTaskTypes(packagedTaskTypesPath());
	auto conversationEntries = creatableEntryPointsOf(packaged.types, packaged.entryPoints, "conversation");
	assert(conversationEntries.map!(entry => entry.target.name).array == ["agentic"]);
	assert(conversationEntries[0].edge.default_);
	foreach (ref type; packaged.types)
		if (type.name != "conversation")
			assert(creatableEntryPointsOf(packaged.types, packaged.entryPoints, type.name).length == 0,
				type.name);
}

version (unittest)
{
	import cydo.domain.task_types.definition : TaskTypeConfig, buildTaskGuidancePromptVars,
		loadTaskTypeSystemPrompt, promptTemplateSource, renderContinuationPrompt,
		renderPrompt, resolveAgent, resolveModelClass, substituteVars;
	private string renderStrictExample(string source, string[string] variables)
	{
		return substituteVars(source, variables);
	}

	private string[] exampleNames(Node root, string mapping)
	{
		return nodeKeys(root).canFind(mapping) ? nodeKeys(at(root, [mapping])) : [];
	}

	// Names under `mapping` that the example itself disables.
	private string[] disabledExampleNames(Node root, string mapping)
	{
		string[] result;
		foreach (name; exampleNames(root, mapping))
		{
			auto entry = at(root, [mapping, name]);
			if (nodeKeys(entry).canFind("enabled") && !at(entry, ["enabled"]).as!bool)
				result ~= name;
		}
		return result;
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
	auto config = parseYamlConfigString!CydoConfig(configExamples.complete, "config.yaml");
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
		auto sample = parseYamlConfigString!CydoConfig(yaml, "config example.yaml");
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
	auto exampleRoot = loadYamlString(taskExamples.complete, "task-types-template.yaml");
	auto roles = exampleNames(exampleRoot, "task_types");
	auto entries = exampleNames(exampleRoot, "user_entry_points")
		~ exampleNames(exampleRoot, "singletons") ~ ["integrator"];
	auto parentDirectory = buildPath(root, "parent-task");
	checkTaskExampleRendering(catalog, roles, entries, promptDirs, workspaceName, parentDirectory);
	foreach (snippet; taskExamples.snippets)
	{
		import std.algorithm : filter, uniq;
		write(edit, snippet);
		auto edited = loadTaskTypes(packaged, overlay, edit);
		errors = validateTaskTypes(edited.types, edited.entryPoints, edited.singletons,
			configured, promptDirs);
		assert(errors.length == 0, snippet ~ errors.join("\n"));
		auto editRoot = loadYamlString(snippet, "task-types edit.yaml");
		auto disabledRoles = disabledExampleNames(editRoot, "task_types");
		auto disabledEntries = disabledExampleNames(editRoot, "user_entry_points");
		auto editedRoles = (roles ~ exampleNames(editRoot, "task_types")).sort.uniq
			.filter!(name => !disabledRoles.canFind(name)).array;
		auto editedEntries = (entries ~ exampleNames(editRoot, "user_entry_points")).sort.uniq
			.filter!(name => !disabledEntries.canFind(name)).array;
		foreach (name; disabledRoles)
			assert(edited.types.byName(name) is null, name);
		foreach (name; disabledEntries)
			assert(edited.entryPoints.byName(name) is null, name);
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

unittest
{
	auto empty = renderInitConfig([]);
	assert(empty == configTemplate);
	enum syntax = " # : \" \\ \\n";
	enum lineBreaks = "\r\n\u0085\u2028\u2029";
	enum controls = "\x00\t\x1F\x7F\u0080\u0084\u0086\u009F";
	enum unicode = "\u2603\uFEFF\uFFFE\uFFFF\U0001F680";
	auto workspaces = [
		DetectedWorkspace("name" ~ syntax ~ lineBreaks ~ unicode,
			"/root" ~ syntax ~ unicode ~ lineBreaks),
		DetectedWorkspace("second" ~ controls, "/second root" ~ controls),
	];
	auto rendered = renderInitConfig(workspaces);
	auto begin = rendered.indexOf(beginMarker);
	auto end = rendered.indexOf(endMarker);
	assert(rendered[0 .. begin + beginMarker.length] ==
		configTemplate[0 .. configTemplate.indexOf(beginMarker) + beginMarker.length]);
	assert(rendered[end .. $] == configTemplate[configTemplate.indexOf(endMarker) .. $]);
	assert(rendered[$ - 1] == '\n');
	auto parsed = parseYamlConfigString!CydoConfig(rendered, "rendered.yaml");
	assert(parsed.workspaces.length == workspaces.length);
	foreach (i, workspace; workspaces)
	{
		assert(parsed.workspaces[i].name == workspace.name);
		assert(parsed.workspaces[i].root == workspace.root);
	}
	assertThrown!Exception(renderInitConfig([], "workspaces: {}\n"));
	assertThrown!Exception(renderInitConfig([], beginMarker ~ "\n" ~ beginMarker ~ "\n" ~ endMarker ~ "\n"));
	assertThrown!Exception(renderInitConfig([], endMarker ~ "\n" ~ beginMarker ~ "\n"));
	assertThrown!Exception(renderInitConfig([], beginMarker ~ "\n" ~ endMarker ~ "\n" ~ endMarker ~ "\n"));
	assertThrown!Exception(renderInitConfig([], "x " ~ beginMarker ~ "\n" ~ endMarker ~ "\n"));
	assertThrown!Exception(renderInitConfig([], beginMarker ~ " suffix\n" ~ endMarker ~ "\n"));
	assertThrown!Exception(renderInitConfig([], beginMarker ~ "\n" ~ endMarker ~ " suffix\n"));
}

unittest
{
	auto root = buildPath("/tmp", "cydo-init-install");
	resetInitializeTestDir(root);
	scope (exit) if (exists(root)) rmdirRecurse(root);
	auto oldHome = environment.get("HOME", "");
	auto hadHome = "HOME" in environment;
	scope (exit) { if (hadHome) environment["HOME"] = oldHome; else environment.remove("HOME"); }
	environment["HOME"] = root;
	auto workspaceRoot = buildPath(root, "workspace");
	mkdirRecurse(workspaceRoot);
	auto workspaces = [DetectedWorkspace("workspace", workspaceRoot)];
	installInitConfiguration(workspaces);
	auto mainPath = configPath();
	auto taskPath = userTaskTypesPath();
	assert(exists(mainPath) && exists(taskPath));
	string[] entries;
	foreach (entry; dirEntries(configDir(), SpanMode.shallow))
		entries ~= baseName(entry.name);
	entries.sort;
	assert(entries == ["config.yaml", "task-types.yaml"]);
	auto installedMain = cast(string) read(mainPath);
	auto installedTask = cast(string) read(taskPath);
	assert(installedMain[$ - 1] == '\n' && installedMain[$ - 2] != '\n');
	assert(installedTask[$ - 1] == '\n' && installedTask[$ - 2] != '\n');
	parseYamlConfigString!CydoConfig(installedMain, mainPath);
	parseYamlConfigString!TaskTypesFile(installedTask, taskPath);
	auto installedBegin = installedMain.indexOf(beginMarker);
	auto installedEnd = installedMain.indexOf(endMarker);
	auto templateBegin = configTemplate.indexOf(beginMarker);
	auto templateEnd = configTemplate.indexOf(endMarker);
	assert(installedMain[0 .. installedBegin + beginMarker.length]
		== configTemplate[0 .. templateBegin + beginMarker.length]);
	assert(installedMain[installedEnd .. $] == configTemplate[templateEnd .. $]);
	assert(installedTask == taskTypesTemplate);
	auto loaded = loadConfig();
	assert(loaded.workspaces.length == 1 && loaded.workspaces[0].name == "workspace");
	assert(loaded.workspaces[0].root == workspaceRoot);
	auto originalMain = read(mainPath).idup;
	auto originalTask = read(taskPath).idup;
	bool caught;
	try installInitConfiguration(workspaces);
	catch (Exception e)
	{
		caught = true;
		assert(e.msg.canFind(mainPath));
	}
	assert(caught);
	assert(read(mainPath).idup == originalMain && read(taskPath).idup == originalTask);
}

unittest
{
	auto root = buildPath("/tmp", "cydo-init-install-rollback");
	resetInitializeTestDir(root);
	scope (exit) if (exists(root)) rmdirRecurse(root);
	auto oldHome = environment.get("HOME", "");
	auto hadHome = "HOME" in environment;
	scope (exit) { if (hadHome) environment["HOME"] = oldHome; else environment.remove("HOME"); }
	environment["HOME"] = root;
	mkdirRecurse(configDir());
	auto sibling = buildPath(configDir(), "existing");
	write(sibling, "preserve");
	int writes;
	assertThrown!Exception(installInitConfiguration([], (ref File file, string contents) {
		++writes;
		if (writes == 2) throw new Exception("induced second write failure");
		file.write(contents);
	}));
	assert(!exists(configPath()) && !exists(userTaskTypesPath()));
	assert(read(sibling).idup == "preserve");
}

unittest // A first partial write is tracked at exclusive open and rolled back.
{
	auto root = buildPath("/tmp", "cydo-init-first-write-failure");
	resetInitializeTestDir(root);
	scope (exit) if (exists(root)) rmdirRecurse(root);
	auto oldHome = environment.get("HOME", ""); auto hadHome = "HOME" in environment;
	scope (exit) { if (hadHome) environment["HOME"] = oldHome; else environment.remove("HOME"); }
	environment["HOME"] = root;
	auto original = new Exception("first write failure");
	Exception caught;
	try installInitConfiguration([], (ref File file, string contents) { file.write("partial"); throw original; });
	catch (Exception e) caught = e;
	assert(caught is original && !exists(configPath()) && !exists(userTaskTypesPath()));
}

unittest // A foreign second target created after preflight survives exclusive-open failure.
{
	auto root = buildPath("/tmp", "cydo-init-exclusive-race");
	resetInitializeTestDir(root);
	scope (exit) if (exists(root)) rmdirRecurse(root);
	auto oldHome = environment.get("HOME", ""); auto hadHome = "HOME" in environment;
	scope (exit) { if (hadHome) environment["HOME"] = oldHome; else environment.remove("HOME"); }
	environment["HOME"] = root; mkdirRecurse(configDir());
	auto sibling = buildPath(configDir(), "sibling"); write(sibling, "keep");
	int writes; Exception caught;
	try installInitConfiguration([], (ref File file, string contents) {
		++writes; file.write(contents); if (writes == 1) write(userTaskTypesPath(), "foreign");
	}); catch (Exception e) caught = e;
	assert(writes == 1 && caught !is null && caught.msg.canFind(userTaskTypesPath()));
	assert(!exists(configPath()) && read(userTaskTypesPath).idup == "foreign" && read(sibling).idup == "keep");
}

unittest // Cleanup failures remain secondary and do not stop later cleanup attempts.
{
	auto root = buildPath("/tmp", "cydo-init-cleanup-failure");
	resetInitializeTestDir(root);
	scope (exit) if (exists(root)) rmdirRecurse(root);
	auto oldHome = environment.get("HOME", ""); auto hadHome = "HOME" in environment;
	scope (exit) { if (hadHome) environment["HOME"] = oldHome; else environment.remove("HOME"); }
	environment["HOME"] = root; mkdirRecurse(configDir());
	auto sibling = buildPath(configDir(), "sibling"); write(sibling, "keep");
	auto original = new Exception("original failure"); auto prior = new Exception("prior failure"); original.next = prior;
	int writes; Exception caught;
	try installInitConfiguration([], (ref File file, string contents) {
		++writes; file.write(contents);
		if (writes == 2) { remove(configPath()); mkdirRecurse(configPath()); write(buildPath(configPath(), "child"), "x"); throw original; }
	}); catch (Exception e) caught = e;
	assert(caught is original && caught.next is prior && caught.next.next !is null
		&& caught.next.next.msg.canFind(configPath()));
	assert(isDir(configPath()) && exists(buildPath(configPath(), "child"))
		&& !exists(userTaskTypesPath()) && read(sibling).idup == "keep");
}

unittest // An absent pair is vacant; a dangling symlink is still occupied.
{
	auto root = buildPath("/tmp", "cydo-init-install-occupancy");
	resetInitializeTestDir(root);
	scope (exit) if (exists(root)) rmdirRecurse(root);
	auto oldHome = environment.get("HOME", ""); auto hadHome = "HOME" in environment;
	scope (exit) { if (hadHome) environment["HOME"] = oldHome; else environment.remove("HOME"); }
	environment["HOME"] = root;
	installInitConfiguration([]);
	assert(exists(configPath()) && exists(userTaskTypesPath()));
	remove(configPath()); remove(userTaskTypesPath());
	symlink(buildPath(root, "missing"), configPath());
	Exception failure;
	try installInitConfiguration([]);
	catch (Exception e) failure = e;
	assert(failure !is null && failure.msg.canFind(configPath()));
	assert(isSymlink(configPath()) && !exists(userTaskTypesPath()));
}

unittest // Generated documents use only detected workspaces and real loader fixups.
{
	auto root = buildPath("/tmp", "cydo-init-loader-fixups");
	resetInitializeTestDir(root);
	scope (exit) if (exists(root)) rmdirRecurse(root);
	auto oldHome = environment.get("HOME", ""); auto hadHome = "HOME" in environment;
	scope (exit) { if (hadHome) environment["HOME"] = oldHome; else environment.remove("HOME"); }
	environment["HOME"] = root;
	installInitConfiguration([]);
	auto empty = loadConfig();
	assert(empty.workspaces == [WorkspaceConfig("local", root)]);
	remove(configPath()); remove(userTaskTypesPath());
	auto specialCharacters = " # : \" \\ \n\u2603";
	assert(specialCharacters.canFind("\n") && specialCharacters.canFind("☃"));
	auto specialRoot = buildPath(root, "root" ~ specialCharacters);
	mkdirRecurse(specialRoot);
	auto special = DetectedWorkspace("name" ~ specialCharacters, specialRoot);
	installInitConfiguration([special]);
	auto loaded = loadConfig();
	assert(loaded.workspaces.length == 1 && loaded.workspaces[0].name == special.name
		&& loaded.workspaces[0].root == special.root);
	auto generated = parseYamlConfigString!CydoConfig(cast(string) read(configPath), "generated.yaml");
	assert(!generated.sandbox.isolate_filesystem.set && generated.default_agent == ""
		&& generated.task_dir == "" && generated.agents.length == 0);
}

unittest // Target collisions are preflighted without changing either entry.
{
	auto root = buildPath("/tmp", "cydo-init-all-collisions");
	resetInitializeTestDir(root);
	scope (exit) if (exists(root)) rmdirRecurse(root);
	auto oldHome = environment.get("HOME", ""); auto hadHome = "HOME" in environment;
	scope (exit) { if (hadHome) environment["HOME"] = oldHome; else environment.remove("HOME"); }
	environment["HOME"] = root; mkdirRecurse(configDir());
	foreach (target; [configPath(), userTaskTypesPath()]) foreach (kind; 0 .. 4)
	{
		if (kind == 0) write(target, "file");
		else if (kind == 1) mkdirRecurse(target);
		else if (kind == 2) { auto linked = buildPath(root, "linked" ~ target.baseName); write(linked, "x"); symlink(linked, target); }
		else symlink(buildPath(root, "missing" ~ target.baseName), target);
		bool caught;
		try installInitConfiguration([]);
		catch (Exception e) { caught = true; assert(e.msg.canFind(target)); }
		assert(caught);
		assert(!exists(target == configPath() ? userTaskTypesPath() : configPath()));
		if (kind == 0) assert(read(target).idup == "file");
		else if (kind == 1) assert(isDir(target) && !isSymlink(target));
		else if (kind == 2) assert(isSymlink(target)
			&& readLink(target) == buildPath(root, "linked" ~ target.baseName));
		else assert(isSymlink(target)
			&& readLink(target) == buildPath(root, "missing" ~ target.baseName));
		if (kind == 1) rmdirRecurse(target); else remove(target);
	}
}

unittest // Existing config directories may be real or symlinked directories only.
{
	auto root = buildPath("/tmp", "cydo-init-config-dir");
	resetInitializeTestDir(root);
	scope (exit) if (exists(root)) rmdirRecurse(root);
	auto oldHome = environment.get("HOME", ""); auto hadHome = "HOME" in environment;
	scope (exit) { if (hadHome) environment["HOME"] = oldHome; else environment.remove("HOME"); }
	environment["HOME"] = root; mkdirRecurse(configDir()); installInitConfiguration([]);
	remove(configPath()); remove(userTaskTypesPath()); rmdirRecurse(configDir());
	auto actual = buildPath(root, "actual"); mkdirRecurse(actual); symlink(actual, configDir()); installInitConfiguration([]);
	remove(configPath()); remove(userTaskTypesPath()); remove(configDir());
	write(configDir(), "not a directory"); assertThrown!Exception(installInitConfiguration([])); remove(configDir());
	symlink(buildPath(root, "missing"), configDir()); assertThrown!Exception(installInitConfiguration([]));
}

unittest // Validation happens before creating the parent, and output is complete and ordered.
{
	auto root = buildPath("/tmp", "cydo-init-validation-output");
	resetInitializeTestDir(root);
	scope (exit) if (exists(root)) rmdirRecurse(root);
	auto oldHome = environment.get("HOME", ""); auto hadHome = "HOME" in environment;
	scope (exit)
	{
		if (hadHome) environment["HOME"] = oldHome; else environment.remove("HOME");
	}
	environment["HOME"] = root;
	bool caught;
	try installInitConfiguration([], null,
		(DetectedWorkspace[] selected) { return "workspaces: [malformed\n"; });
	catch (Exception) caught = true;
	assert(caught);
	assert(!exists(configDir()));
	string output;
	initializeUserConfiguration([], (string line) { output ~= line ~ "\n"; });
	assert(output == "Installed " ~ quoteYamlScalar(configPath()) ~ "\nInstalled "
		~ quoteYamlScalar(userTaskTypesPath())
		~ "\nRestart CyDo if init created its config directory while CyDo was running."
		~ "\nNo workspaces were detected; the HOME local fallback applies.\n");
	assert(output[$ - 1] == '\n');
	remove(configPath()); remove(userTaskTypesPath());
	output = "";
	auto workspaces = [DetectedWorkspace("first\u0085\u2028\u2029", "/one\u0085\u2028\u2029"),
		DetectedWorkspace("second", "/two")];
	initializeUserConfiguration(workspaces, (string line) { output ~= line ~ "\n"; });
	assert(output == "Installed " ~ quoteYamlScalar(configPath()) ~ "\nInstalled "
		~ quoteYamlScalar(userTaskTypesPath())
		~ "\nRestart CyDo if init created its config directory while CyDo was running."
		~ "\nDetected \"first\\x85\\u2028\\u2029\" \"/one\\x85\\u2028\\u2029\""
		~ "\nDetected \"second\" \"/two\"\n");
}
