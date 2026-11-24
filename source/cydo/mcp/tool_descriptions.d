module cydo.mcp.tool_descriptions;

import ae.utils.json : JSONFragment, jsonParse, toJson;

import cydo.domain.task_types.definition : TaskTypeConfig, TaskTypeDef, UserEntryPointDef,
	ContinuationDef, CreatableTaskDef, WorktreeMode,
	formatCompactCreatableTaskTypeToolSummary,
	formatCompactHandoffToolSummary, formatCompactSwitchModeToolSummary,
	formatCompactSingletonToolSummary, isInteractive, singletonsOfferedTo;
import cydo.mcp.binding : SchemaObj, ToolDef, ToolsList, buildToolsListJson;
import cydo.mcp.tools : CydoTools, handoffToolDescription, taskToolDescription;

/// Approximates Claude Code 2.1.185's roughly 2048-character truncation
/// trigger: Claude Code retained 2047 characters and appended the
/// 14-character `...[truncated]` marker, so CyDo uses a deliberate about-48-
/// character safety margin against version drift.
enum size_t mcpToolDescriptionMaxChars = 2000;

struct RenderedCydoToolsOptions
{
	bool includeBash = true;
	bool includeAsk = true;
	bool includeAnswer = true;
	bool includeUnsandboxedCommand;
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
	string singletons,
	RenderedCydoToolsOptions options = RenderedCydoToolsOptions.init,
)
{
	auto creatableTaskTypes = formatCompactCreatableTaskTypeToolSummary(types, typeName);
	auto switchModes = formatCompactSwitchModeToolSummary(types, typeName);
	auto handoffs = formatCompactHandoffToolSummary(types, typeName);

	string[] includeTools;
	if (options.includeBash)
		includeTools ~= "Bash";
	if (options.includeUnsandboxedCommand)
		includeTools ~= "UnsandboxedCommand";
	if (creatableTaskTypes.length > 0)
		includeTools ~= "Task";
	if (switchModes.length > 0)
		includeTools ~= "SwitchMode";
	if (handoffs.length > 0)
		includeTools ~= "Handoff";
	if (isInteractive(types, entryPoints, typeName))
		includeTools ~= "AskUserQuestion";
	if (options.includeAsk)
		includeTools ~= "Ask";
	if (options.includeAnswer)
		includeTools ~= "Answer";
	if (singletons.length > 0)
		includeTools ~= "Request";

	return jsonParse!ToolsList(buildToolsListJson!CydoTools([
		"creatable_task_types": creatableTaskTypes,
		"switchmodes": switchModes,
		"handoffs": handoffs,
		"singletons": singletons,
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
	string singletons,
	size_t maxChars = mcpToolDescriptionMaxChars,
	RenderedCydoToolsOptions options = RenderedCydoToolsOptions.init,
)
{
	return checkToolDescriptionViolations(typeName,
		buildRenderedCydoToolsList(types, entryPoints, typeName, singletons, options), maxChars);
}

ToolDescriptionViolation[] checkConfiguredToolDescriptions(
	TaskTypeConfig config, size_t maxChars)
{
	ToolDescriptionViolation[] violations;
	foreach (ref typeDef; config.types)
	{
		auto singletons = singletonsOfferedTo(config.types, config.entryPoints,
			config.singletons, typeDef.name);
		violations ~= checkRenderedCydoToolDescriptionViolations(config.types,
			config.entryPoints, typeDef.name, formatCompactSingletonToolSummary(singletons),
			maxChars, RenderedCydoToolsOptions(includeUnsandboxedCommand: true));
	}
	return violations;
}

unittest
{
	import std.algorithm : filter;
	import std.array : array, replicate;
	import cydo.domain.task_types.definition : SingletonDef;

	TaskTypeConfig config;
	config.types = [TaskTypeDef(name: "conversation"), TaskTypeDef(name: "isolated"),
		TaskTypeDef(name: "integrator")];
	config.entryPoints = [UserEntryPointDef("chat", "conversation"),
		UserEntryPointDef("integrate", "integrator", system: true)];
	enum maxChars = mcpToolDescriptionMaxChars;
	config.singletons = [SingletonDef(name: "integrate", task_type: "integrator",
		description: "x".replicate(maxChars + 1))];

	auto requests = checkConfiguredToolDescriptions(config, maxChars)
		.filter!(violation => violation.toolName == "Request").array;
	assert(requests.length == 1);
	assert(requests[0].taskType == "conversation");
	assert(requests[0].actualChars > maxChars);
	assert(requests[0].maxChars == maxChars);
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
	import std.algorithm : canFind, filter;
	import std.array : array;
	import cydo.domain.task_types.definition : SingletonDef, SingletonAudience;

	TaskTypeDef task;
	task.name = "isolated";
	auto types = [task];
	auto defaultTools = buildRenderedCydoToolsList(types, [], task.name, "");
	assert(!defaultTools.tools.canFind!(tool => tool.name == "Request"));
	assert(jsonParse!ToolsList(buildToolsListJson!CydoTools(null, ["Land"])).tools.length == 0);

	auto singletons = [
		SingletonDef("integrate", "integrator", "", "", SingletonAudience.all,
			"Integrate changes.\nReport the resulting commit."),
		SingletonDef("review", "reviewer", "", "", SingletonAudience.all,
			"Review changes.\nReport actionable findings."),
	];
	auto summary = formatCompactSingletonToolSummary(singletons);
	auto tools = buildRenderedCydoToolsList(types, [], task.name, summary).tools;
	auto requests = tools.filter!(tool => tool.name == "Request").array;
	assert(requests.length == 1);
	auto description = requests[0].description;
	assert(description.canFind("- integrate: Integrate changes."));
	assert(description.canFind("- review: Review changes."));
	assert(!description.canFind("Report the resulting commit."));
	assert(!description.canFind("Report actionable findings."));
	assert(countCodePoints(description) < mcpToolDescriptionMaxChars);
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
	import std.algorithm : canFind;

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
	], ["Bash", "Task", "SwitchMode", "Handoff", "AskUserQuestion", "Ask",
		"Answer"]));
	auto toolsList = buildRenderedCydoToolsList(types, entryPoints, "review", "");
	auto directViolations = checkToolDescriptionViolations("review", toolsList);
	auto renderedViolations = checkRenderedCydoToolDescriptionViolations(types,
		entryPoints, "review", "");

	assert(toJson(toolsList) == toJson(expected));
	assert(toJson(directViolations) == toJson(renderedViolations));
	assert(renderedViolations.length == 0);
	assert(checkRenderedCydoToolDescriptionViolations(types, entryPoints, "review", "",
		mcpToolDescriptionMaxChars).length == 0);
	assert(toolsList.tools[$ - 2].name == "Ask");
	assert(toolsList.tools[$ - 1].name == "Answer");

	ToolDef taskTool;
	ToolDef handoffTool;
	bool foundTask;
	bool foundHandoff;
	foreach (ref tool; toolsList.tools)
	{
		if (tool.name == "Task")
		{
			taskTool = tool;
			foundTask = true;
		}
		else if (tool.name == "Handoff")
		{
			handoffTool = tool;
			foundHandoff = true;
		}
	}
	assert(foundTask);
	assert(foundHandoff);

	auto creatableSuffix = "\n\nAvailable task types:\n\n"
		~ formatCompactCreatableTaskTypeToolSummary(types, "review");
	auto handoffSuffix = "\n\nAvailable handoffs:\n\n"
		~ formatCompactHandoffToolSummary(types, "review");
	assert(taskTool.description == taskToolDescription ~ creatableSuffix,
		taskTool.description);
	assert(handoffTool.description == handoffToolDescription ~ handoffSuffix,
		handoffTool.description);

	assert(taskTool.description.canFind(
		"Each created child appears in the CyDo task tree; the returned `tid` opens that "
		~ "child session."), taskTool.description);
	assert(taskTool.description.canFind(
		"After a restart, CyDo resumes in-flight children and keeps unfinished batches grouped. "
		~ "Unanswered questions and recovered results are queued again and delivered like any other event."),
		taskTool.description);
	assert(taskTool.description.canFind(
		"Accepted multi-task batches launch every child before waiting, so the children run "
		~ "concurrently."), taskTool.description);
	assert(taskTool.description.canFind(
		"Once every child settles, the batch result contains one item per requested "
		~ "task in request order, regardless of completion order."), taskTool.description);
	assert(!taskTool.description.canFind(
		"Every child starts a fresh session and does not inherit this conversation"),
		taskTool.description);
	assert(!taskTool.description.canFind("Make each Task prompt self-contained"),
		taskTool.description);

	auto askDescription = toolsList.tools[$ - 2].description;
	auto answerDescription = toolsList.tools[$ - 1].description;
	foreach (description; [taskTool.description, askDescription, answerDescription])
	{
		assert(description.canFind(
			"Any blocked Task, Ask, or Answer call returns the next event in arrival order."),
			description);
		assert(description.canFind(
			"the child `tid`s in the `tasks` list for batch results."), description);
		assert(!description.canFind("returns early with a `qid`"), description);
		assert(!description.canFind("pauses your task until the target responds"), description);
	}
	assert(askDescription.canFind(
		"The answer to your question may arrive through a later call."), askDescription);
	assert(answerDescription.canFind(
		"After a successful Answer, the call returns `status: \"delivered\"` immediately unless "
		~ "you owe no other received question an answer and are still waiting for a Task batch result "
		~ "or for a reply or failure to your own question. In that case, it waits for the next event."),
		answerDescription);

	assert(handoffTool.description.canFind(
		"After this session exits, a valid Handoff marks this task completed, then creates a "
		~ "child successor in a fresh session from the supplied prompt; the successor does not "
		~ "inherit this conversation."), handoffTool.description);

	auto tasksSchema = "tasks" in taskTool.inputSchema.properties;
	assert(tasksSchema !is null);
	assert(tasksSchema.type == "array");
	assert(tasksSchema.description == "Task specifications to create");
	auto taskSpecSchema = jsonParse!SchemaObj(tasksSchema.items.json);
	assert(taskSpecSchema.type == "object");
	auto promptSchema = "prompt" in taskSpecSchema.properties;
	assert(promptSchema !is null);
	assert(promptSchema.type == "string");
	assert(promptSchema.description ==
		"The child task prompt; see the session's Create Sub-Tasks guidance for context requirements");
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

	auto toolsList = buildRenderedCydoToolsList(types, entryPoints, "review", "");
	auto violations = checkRenderedCydoToolDescriptionViolations(types, entryPoints,
		"review", "");

	assert(violations.length == 0);
	foreach (ref tool; toolsList.tools)
		assert(countCodePoints(tool.description) <= mcpToolDescriptionMaxChars,
			tool.name ~ " description exceeded shared max");
}
