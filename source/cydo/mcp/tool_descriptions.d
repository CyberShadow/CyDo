module cydo.mcp.tool_descriptions;

import ae.utils.json : JSONFragment, jsonParse, toJson;

import cydo.domain.task_types.definition : TaskTypeDef, UserEntryPointDef,
	ContinuationDef, CreatableTaskDef, WorktreeMode,
	formatCompactCreatableTaskTypeToolSummary,
	formatCompactHandoffToolSummary, formatCompactSwitchModeToolSummary,
	isInteractive;
import cydo.mcp.binding : SchemaObj, ToolDef, ToolsList, buildToolsListJson;
import cydo.mcp.tools : CydoTools;

/// Approximates Claude Code 2.1.185's roughly 2048-character truncation
/// trigger: Claude Code retained 2047 characters and appended the
/// 14-character `...[truncated]` marker, so CyDo uses a deliberate about-48-
/// character safety margin against version drift.
enum size_t mcpToolDescriptionMaxChars = 2000;

struct RenderedCydoToolsOptions
{
	bool includeBash = true;
	bool includePermissionPrompt;
}

struct ToolDescriptionViolation
{
	string taskType;
	string toolName;
	size_t actualChars;
	size_t maxChars;
}

ToolsList buildRenderedCydoToolsList(
	TaskTypeDef[] types,
	UserEntryPointDef[] entryPoints,
	string typeName,
	RenderedCydoToolsOptions options = RenderedCydoToolsOptions.init,
)
{
	auto creatableTaskTypes = formatCompactCreatableTaskTypeToolSummary(types, typeName);
	auto switchModes = formatCompactSwitchModeToolSummary(types, typeName);
	auto handoffs = formatCompactHandoffToolSummary(types, typeName);

	string[] includeTools;
	if (options.includeBash)
		includeTools ~= "Bash";
	if (creatableTaskTypes.length > 0)
		includeTools ~= "Task";
	if (switchModes.length > 0)
		includeTools ~= "SwitchMode";
	if (handoffs.length > 0)
		includeTools ~= "Handoff";
	if (isInteractive(types, entryPoints, typeName))
		includeTools ~= "AskUserQuestion";
	if (options.includePermissionPrompt)
		includeTools ~= "PermissionPrompt";

	return jsonParse!ToolsList(buildToolsListJson!CydoTools([
		"creatable_task_types": creatableTaskTypes,
		"switchmodes": switchModes,
		"handoffs": handoffs,
	], includeTools));
}

ToolDescriptionViolation[] checkToolDescriptionViolations(
	string taskType,
	ToolsList toolsList,
	size_t maxChars = mcpToolDescriptionMaxChars,
)
{
	ToolDescriptionViolation[] violations;
	foreach (ref tool; toolsList.tools)
	{
		auto actualChars = countCodePoints(tool.description);
		if (actualChars > maxChars)
			violations ~= ToolDescriptionViolation(taskType, tool.name, actualChars,
				maxChars);
	}
	return violations;
}

ToolDescriptionViolation[] checkRenderedCydoToolDescriptionViolations(
	TaskTypeDef[] types,
	UserEntryPointDef[] entryPoints,
	string typeName,
	size_t maxChars = mcpToolDescriptionMaxChars,
	RenderedCydoToolsOptions options = RenderedCydoToolsOptions.init,
)
{
	return checkToolDescriptionViolations(typeName,
		buildRenderedCydoToolsList(types, entryPoints, typeName, options), maxChars);
}

private size_t countCodePoints(string text)
{
	size_t count;
	foreach (dchar _; text)
		++count;
	return count;
}

unittest
{
	ToolDef[] tools = [
		ToolDef("unicode", "\u00E9\U0001F642x", SchemaObj.init),
	];
	auto violations = checkToolDescriptionViolations("review", ToolsList(tools), 2);

	assert(violations.length == 1);
	assert(violations[0].taskType == "review");
	assert(violations[0].toolName == "unicode");
	assert(violations[0].actualChars == 3);
	assert(violations[0].maxChars == 2);
	assert(tools[0].description.length > violations[0].actualChars);
}

unittest
{
	ToolDef[] tools = [
		ToolDef("Task", "abcd", SchemaObj.init),
		ToolDef("SwitchMode", "abc", SchemaObj.init),
		ToolDef("Handoff", "a", SchemaObj.init),
	];
	auto violations = checkToolDescriptionViolations("review", ToolsList(tools), 2);

	assert(violations.length == 2);
	assert(violations[0] == ToolDescriptionViolation("review", "Task", 4, 2));
	assert(violations[1] == ToolDescriptionViolation("review", "SwitchMode", 3, 2));
}

unittest
{
	ToolDef[] tools = [
		ToolDef("Task", "ok", SchemaObj("object", null, JSONFragment.init, [
			"prompt": SchemaObj("string", "12345", JSONFragment.init, null, null),
		], null)),
	];
	auto violations = checkToolDescriptionViolations("review", ToolsList(tools), 2);

	assert(violations.length == 0);
}

unittest
{
	TaskTypeDef review;
	review.name = "review";
	review.agent_description = "Review the implementation.";
	review.creatable_tasks = [CreatableTaskDef("implement", "implement",
		WorktreeMode.inherit, "", "", "Implement the requested change.")];
	review.continuations = [
		"finish": ContinuationDef("finish", false, true, WorktreeMode.inherit, "",
			"Wrap up in the same session."),
		"handoff": ContinuationDef("followup", false, false, WorktreeMode.inherit,
			"", "Hand off to a fresh task."),
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
	auto entryPoints = [UserEntryPointDef("review", "review", "Start a review task.",
		"", WorktreeMode.inherit)];

	auto expected = jsonParse!ToolsList(buildToolsListJson!CydoTools([
		"creatable_task_types": formatCompactCreatableTaskTypeToolSummary(types,
			"review"),
		"switchmodes": formatCompactSwitchModeToolSummary(types, "review"),
		"handoffs": formatCompactHandoffToolSummary(types, "review"),
	], ["Bash", "Task", "SwitchMode", "Handoff", "AskUserQuestion"]));
	auto toolsList = buildRenderedCydoToolsList(types, entryPoints, "review");
	auto directViolations = checkToolDescriptionViolations("review", toolsList);
	auto renderedViolations = checkRenderedCydoToolDescriptionViolations(types,
		entryPoints, "review");

	assert(toJson(toolsList) == toJson(expected));
	assert(toJson(directViolations) == toJson(renderedViolations));
	assert(renderedViolations.length == 0);
	assert(checkRenderedCydoToolDescriptionViolations(types, entryPoints, "review",
		mcpToolDescriptionMaxChars).length == 0);
}

unittest
{
	import std.conv : to;

	string verbose;
	foreach (i; 0 .. 180)
		verbose ~= "Verbose task metadata " ~ to!string(i)
			~ " that should never leak into compact rendered tool descriptions. ";

	TaskTypeDef review;
	review.name = "review";
	review.agent_description = verbose;
	review.creatable_tasks = [CreatableTaskDef("implement", "implement",
		WorktreeMode.inherit, "", "", verbose)];
	review.continuations = [
		"finish": ContinuationDef("finish", false, true, WorktreeMode.inherit, "",
			verbose),
		"handoff": ContinuationDef("followup", false, false, WorktreeMode.inherit,
			"", verbose),
	];

	TaskTypeDef implement;
	implement.name = "implement";
	implement.agent_description = verbose;
	implement.tool_guidance = verbose;

	TaskTypeDef finish;
	finish.name = "finish";
	finish.agent_description = verbose;
	finish.tool_guidance = verbose;

	TaskTypeDef followup;
	followup.name = "followup";
	followup.agent_description = verbose;
	followup.tool_guidance = verbose;

	auto types = [review, implement, finish, followup];
	auto entryPoints = [UserEntryPointDef("review", "review", "Start a review task.",
		"", WorktreeMode.inherit)];

	auto toolsList = buildRenderedCydoToolsList(types, entryPoints, "review");
	auto violations = checkRenderedCydoToolDescriptionViolations(types, entryPoints,
		"review");

	assert(violations.length == 0);
	foreach (ref tool; toolsList.tools)
		assert(countCodePoints(tool.description) <= mcpToolDescriptionMaxChars,
			tool.name ~ " description exceeded shared max");
}
