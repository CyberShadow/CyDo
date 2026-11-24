module cydo.cli.tasktype_context;

import std.algorithm : filter, map;
import std.array : join;
import std.conv : to;
import std.format : format;
import std.stdio : stderr, write, writefln, writeln;
import std.string : lineSplitter, strip;

import cydo.domain.task_types.definition : ContinuationDef, CreatableTaskDef, TaskTypeConfig, TaskTypeDef,
	UserEntryPointDef, SingletonDef, WorktreeMode, byName, computeReachesWorktree,
	formatCompactSingletonToolSummary, singletonsOfferedTo, isInteractive,
	computeTreeReadOnly, promptTemplateSource, renderPrompt, validateTaskTypes;
import cydo.domain.policy.unsandboxed_command : evaluateUnsandboxedCommandExecution;
import cydo.mcp.tool_descriptions : RenderedCydoToolsOptions, buildRenderedCydoToolsList;
import cydo.runtime.config : UnsandboxedCommandExecution;

private string renderDumpContextToolsSection(
	TaskTypeConfig config,
	string typeName,
)
{
	string rendered = "─── MCP Tools ───\n\n";
	auto singletons = singletonsOfferedTo(config.types, config.entryPoints, config.singletons, typeName);
	auto def = config.types.byName(typeName);
	auto verdict = evaluateUnsandboxedCommandExecution(def.unsandboxed_command_execution,
		"task type '" ~ typeName ~ "'", typeName,
		isInteractive(config.types, config.entryPoints, typeName));
	auto options = RenderedCydoToolsOptions(
		includeUnsandboxedCommand: verdict != UnsandboxedCommandExecution.no);
	auto toolsList = buildRenderedCydoToolsList(config.types, config.entryPoints, typeName,
		formatCompactSingletonToolSummary(singletons), options);
	foreach (ref tool; toolsList.tools)
	{
		rendered ~= format("### %s\n\n", tool.name);
		if (tool.description.length > 0)
			rendered ~= tool.description ~ "\n\n";
	}
	return rendered;
}

void runDumpContext(TaskTypeConfig config, string[] promptDirs, string typeName,
	bool delegate(string) isConfiguredAgentName)
{
	auto errors = validateTaskTypes(config.types, config.entryPoints, config.singletons,
		isConfiguredAgentName, promptDirs);
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
	writefln("Model:          %s", def.model_class.source);
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
	auto rendered = renderPrompt(def, "<task description>", promptDirs);
	writeln(rendered);
	writeln();

	{
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
				auto source = promptTemplateSource(promptDirs, cont.prompt_template);
				if (source !is null)
					writeln(source);
				else
					writefln("  (template not found: %s)", cont.prompt_template);
				writeln();
			}
		}
	}

	write(renderDumpContextToolsSection(config, typeName));
}

unittest
{
	import std.algorithm : filter;
	import cydo.domain.task_types.definition : CreatableEntryPointDef;
	import std.array : array;
	import std.algorithm.searching : canFind;

	TaskTypeDef review;
	review.name = "review";
	review.agent_description = "Review the implementation.";
	review.creatable_entry_points = [CreatableEntryPointDef("review")];
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

	auto singletons = [SingletonDef("follow-up", "followup", description: "Follow up on review.")];
	auto config = TaskTypeConfig(types, entryPoints, singletons);
	auto actual = buildRenderedCydoToolsList(types, entryPoints, "review",
		formatCompactSingletonToolSummary(singletons));

	auto rendered = renderDumpContextToolsSection(config, "review");
	assert(rendered.canFind("### Request"));
	assert(rendered.canFind("- follow-up: Follow up on review."));
	assert(rendered.canFind("─── MCP Tools ───"));
	foreach (ref tool; actual.tools)
	{
		assert(rendered.canFind("### " ~ tool.name));
		if (tool.description.length > 0)
			assert(rendered.canFind(tool.description));
	}

	auto toolNames = actual.tools.map!(tool => tool.name).array;
	assert(toolNames == ["Bash", "Task", "SwitchMode", "Handoff",
		"AskUserQuestion", "Ask", "Answer", "Request", "CreateTask"]);
}
