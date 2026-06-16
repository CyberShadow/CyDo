module cydo.tools.tasktype_context;

import std.algorithm : filter, map;
import std.array : join;
import std.conv : to;
import std.format : format;
import std.path : dirName;
import std.stdio : stderr, write, writefln, writeln;
import std.string : lineSplitter, strip;

import ae.utils.json : jsonParse, toJson;

import cydo.mcp.binding : ToolsList, buildToolsListJson;
import cydo.mcp.tools : CydoTools;
import cydo.task_types.definition : ContinuationDef, CreatableTaskDef, TaskTypeConfig, TaskTypeDef,
	UserEntryPointDef, WorktreeMode, byName, computeReachesWorktree,
	computeTreeReadOnly, formatCreatableTaskTypes, formatHandoffs,
	formatSwitchModes, isInteractive, loadTaskTypes, renderPrompt,
	validateTaskTypes;

private ToolsList buildDumpContextToolsList(
	TaskTypeDef[] types,
	UserEntryPointDef[] entryPoints,
	string typeName,
)
{
	auto creatableTaskTypes = formatCreatableTaskTypes(types, typeName);
	auto switchModes = formatSwitchModes(types, typeName);
	auto handoffs = formatHandoffs(types, typeName);

	string[] includeTools;
	includeTools ~= "Bash";
	if (creatableTaskTypes.length > 0)
		includeTools ~= "Task";
	if (switchModes.length > 0)
		includeTools ~= "SwitchMode";
	if (handoffs.length > 0)
		includeTools ~= "Handoff";
	if (isInteractive(types, entryPoints, typeName))
		includeTools ~= "AskUserQuestion";

	return jsonParse!ToolsList(buildToolsListJson!CydoTools([
		"creatable_task_types": creatableTaskTypes,
		"switchmodes": switchModes,
		"handoffs": handoffs,
	], includeTools));
}

private string renderDumpContextToolsSection(
	TaskTypeDef[] types,
	UserEntryPointDef[] entryPoints,
	string typeName,
)
{
	string rendered = "─── MCP Tools ───\n\n";
	auto toolsList = buildDumpContextToolsList(types, entryPoints, typeName);
	foreach (ref tool; toolsList.tools)
	{
		rendered ~= format("### %s\n\n", tool.name);
		if (tool.description.length > 0)
			rendered ~= tool.description ~ "\n\n";
	}
	return rendered;
}

void runDumpContext(string path, string typeName)
{
	auto typesDir = dirName(path);

	TaskTypeConfig config;
	try
		config = loadTaskTypes(path);
	catch (Exception e)
	{
		stderr.writefln("Error loading %s: %s", path, e.msg);
		return;
	}

	auto errors = validateTaskTypes(config.types, config.entryPoints, [typesDir]);
	if (errors.length > 0)
	{
		foreach (e; errors)
			stderr.writefln("  WARN: %s", e);
		stderr.writeln();
	}

	auto types = config.types;
	auto entryPoints = config.entryPoints;

	auto defp = types.byName(typeName);
	if (defp is null)
	{
		stderr.writefln("Unknown task type '%s'", typeName);
		stderr.writefln("Available types: %s",
			types.map!(d => d.name).join(", "));
		return;
	}
	auto def = *defp;

	writefln("=== Agent Context for '%s' ===\n", typeName);

	{
		auto firstLine = def.agent_description.length > 0
			? def.agent_description.strip.lineSplitter.front.to!string : "—";
		writefln("Description:    %s", firstLine);
	}
	writefln("Model:          %s", def.model_class);
	writefln("Output:         %s", def.output_type.length == 0 ? "—"
		: def.output_type.map!(o => cast(string) o).join("+"));
	writefln("Read-only:      %s", def.read_only);
	auto treeRO = computeTreeReadOnly(types);
	writefln("Tree-read-only: %s", typeName in treeRO ? treeRO[typeName] : false);
	auto reachesWt = computeReachesWorktree(types);
	writefln("Reaches worktree: %s", typeName in reachesWt ? reachesWt[typeName] : false);
	{
		auto epNames = entryPoints.filter!(ep => ep.resolvedType == typeName).map!(ep => ep.name).join(", ");
		writefln("Entry points:   %s", epNames.length > 0 ? epNames : "—");
	}
	if (def.steward)
	{
		writefln("Steward:        true");
		writefln("Steward domain: %s", def.steward_domain.strip);
	}
	if (def.max_turns > 0)
		writefln("Max turns:      %d", def.max_turns);
	if (def.on_yield.task_type.length > 0)
		writefln("On-yield:       %s%s%s%s",
			def.on_yield.task_type,
			def.on_yield.keep_context ? " (keep-context)" : "",
			def.on_yield.worktree != WorktreeMode.inherit
				? format(" (worktree: %s)", def.on_yield.worktree) : "",
			def.on_yield.requires_approval ? " (approval)" : "");
	writefln("Disallowed:     (agent-specific)");
	writeln();

	writeln("─── Rendered Prompt (with placeholder \"<task description>\") ───");
	writeln();
	auto rendered = renderPrompt(def, "<task description>", [typesDir]);
	writeln(rendered);
	writeln();

	{
		import std.file : exists, readText;
		import std.path : buildPath;

		bool headerPrinted = false;
		foreach (ref srcDef; types)
		{
			foreach (cname, ref cont; srcDef.continuations)
			{
				if (cont.task_type != typeName || !cont.keep_context)
					continue;
				if (cont.prompt_template.length == 0)
					continue;
				if (!headerPrinted)
				{
					writeln("─── Incoming Continuation Prompts ───");
					writeln();
					headerPrinted = true;
				}
				writefln("From %s via '%s':", srcDef.name, cname);
				auto tmplPath = buildPath(typesDir, cont.prompt_template);
				if (exists(tmplPath))
					writeln(readText(tmplPath));
				else
					writefln("  (template not found: %s)", cont.prompt_template);
				writeln();
			}
		}
	}

	write(renderDumpContextToolsSection(types, entryPoints, typeName));
}

unittest
{
	import std.algorithm : filter;
	import std.array : array;
	import std.algorithm.searching : canFind;

	TaskTypeDef review;
	review.name = "review";
	review.agent_description = "Review the implementation.";
	review.creatable_tasks = [CreatableTaskDef("implement", "implement", WorktreeMode.inherit, "", "", "Implement the requested change.")];
	review.continuations = [
		"finish": ContinuationDef("finish", false, true, WorktreeMode.inherit, "", "Wrap up in the same session."),
		"handoff": ContinuationDef("followup", false, false, WorktreeMode.inherit, "", "Hand off to a fresh task."),
	];

	TaskTypeDef implement;
	implement.name = "implement";
	implement.agent_description = "Write the code change.";

	TaskTypeDef finish;
	finish.name = "finish";
	finish.agent_description = "Finalize the result.";

	TaskTypeDef followup;
	followup.name = "followup";
	followup.agent_description = "Continue in a new task.";

	auto types = [review, implement, finish, followup];
	auto entryPoints = [UserEntryPointDef("review", "review", "Start a review task.", "", WorktreeMode.inherit)];

	auto expected = jsonParse!ToolsList(buildToolsListJson!CydoTools([
		"creatable_task_types": formatCreatableTaskTypes(types, "review"),
		"switchmodes": formatSwitchModes(types, "review"),
		"handoffs": formatHandoffs(types, "review"),
	], ["Bash", "Task", "SwitchMode", "Handoff", "AskUserQuestion"]));
	auto actual = buildDumpContextToolsList(types, entryPoints, "review");

	assert(toJson(actual) == toJson(expected));

	auto rendered = renderDumpContextToolsSection(types, entryPoints, "review");
	assert(rendered.canFind("─── MCP Tools ───"));
	foreach (ref tool; expected.tools)
	{
		assert(rendered.canFind("### " ~ tool.name));
		if (tool.description.length > 0)
			assert(rendered.canFind(tool.description));
	}

	auto toolNames = actual.tools.map!(tool => tool.name).array;
	assert(toolNames == ["Bash", "Task", "SwitchMode", "Handoff", "AskUserQuestion"]);
}
