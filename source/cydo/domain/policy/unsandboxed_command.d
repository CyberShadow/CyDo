module cydo.domain.policy.unsandboxed_command;

import cydo.runtime.config : UnsandboxedCommandExecution, parseUnsandboxedCommandExecution;

enum string defaultUnsandboxedCommandExecutionExpr = `{{ "ask" if interactive else "no" }}`;

UnsandboxedCommandExecution evaluateUnsandboxedCommandExecution(string expression,
	string source, string taskType, bool interactive, string taskDefault = null)
{
	import djinja.djinja : loadData;
	import djinja.render : Render;
	import std.algorithm : canFind;
	import std.string : strip;
	import uninode.node : UniNode;

	if (expression.canFind("{{"))
	{
		UniNode[string] context = [
			"task_type": UniNode(taskType),
			"interactive": UniNode(interactive),
		];
		if (taskDefault !is null)
			context["default"] = UniNode(taskDefault);
		try
			expression = (new Render(loadData(expression))).render(UniNode(context)).strip();
		catch (Exception e)
			throw new Exception(source ~ ": unsandboxed_command_execution: " ~ e.msg, e);
	}
	return parseUnsandboxedCommandExecution(expression, source);
}

unittest
{
	import std.algorithm : canFind;
	import std.exception : collectException;

	alias evaluate = evaluateUnsandboxedCommandExecution;
	alias Verdict = UnsandboxedCommandExecution;
	assert(evaluate("no", "task type 'chat'", "chat", true) == Verdict.no);
	assert(evaluate("ask", "task type 'worker'", "worker", false) == Verdict.ask);
	assert(evaluate("yes", "task type 'worker'", "worker", false) == Verdict.yes);
	assert(evaluate(`{{ "yes" if task_type == "build" else default }}`,
		"sandbox", "build", false, "no") == Verdict.yes);
	assert(evaluate(defaultUnsandboxedCommandExecutionExpr, "task type 'chat'",
		"chat", true) == Verdict.ask);
	assert(evaluate(defaultUnsandboxedCommandExecutionExpr, "task type 'worker'",
		"worker", false) == Verdict.no);
	assert(evaluate(`{{ default if task_type == "chat" and interactive else "no" }}`,
		"sandbox", "chat", true, "ask") == Verdict.ask);
	auto error = collectException(evaluate(`{{ "maybe" }}`, "workspace 'local'",
		"chat", true));
	assert(error && error.msg.canFind("workspace 'local'") && error.msg.canFind("maybe"));
}
