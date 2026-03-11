/// CyDo MCP tool definitions and implementations.
module cydo.mcp.tools;

import cydo.mcp : Description, McpName, McpResult;

/// Specification for a single sub-task.
struct TaskSpec
{
	@Description("A short (3-5 word) description of the task")
	string description;
	@Description("The task type to create (e.g., 'research', 'plan', 'implement')")
	string task_type;
	@Description("The task for the agent to perform")
	string prompt;
}

/// Tool interface — each method is an MCP tool.
/// Compile-time introspection generates metadata and dispatch.
interface CydoTools
{
	/+
	@Description("Read the contents of a file from the filesystem. Returns the file content as text.")
	@McpName("Read")
	McpResult read(
		@Description("The absolute path to the file to read")
		string file_path
	);
	+/

	@Description(
		"Create sub-tasks that run autonomously and return their output.\n\n"
		~ "**Prefer creating sub-tasks for any work that can stand alone.** Sub-tasks "
		~ "run as independent agent sessions, protect your context window, and make work "
		~ "visible in the CyDo task tree. When in doubt, delegate — sub-tasks are cheap "
		~ "and keep you focused on orchestration.\n\n"
		~ "## When to use this tool\n"
		~ "- Investigating something: \"how does the auth subsystem work?\"\n"
		~ "- Planning multi-file changes before implementing them\n"
		~ "- Implementing a scoped piece of work with clear requirements\n"
		~ "- Testing a theory or prototyping an approach in isolation\n"
		~ "- Exploring an unfamiliar part of the codebase\n"
		~ "- Any task you could describe in a sentence and hand to a colleague\n\n"
		~ "## When NOT to use this tool\n"
		~ "- Reading a single known file (use the Read tool directly)\n"
		~ "- Searching for a specific symbol or filename (use Grep or Glob directly)\n"
		~ "- Trivial one-step work you are certain about\n\n"
		~ "## How results work\n"
		~ "- The sub-task runs to completion and returns a structured summary\n"
		~ "- Results are also visible in the CyDo web UI task tree\n"
		~ "- Sub-tasks are persisted and survive backend restarts\n\n"
		~ "## Parallel execution\n"
		~ "- Pass multiple tasks in the array to run them in parallel\n"
		~ "- All tasks execute concurrently; the tool returns when all complete\n"
		~ "- Results are returned in order, one section per task\n\n"
		~ "## Usage notes\n"
		~ "- Provide clear, detailed prompts so the agent can work autonomously "
		~ "and return exactly the information you need.\n"
		~ "- Clearly tell the agent whether you expect it to write code or just "
		~ "do research, since it is not aware of your broader context.\n"
		~ "- Avoid duplicating work that sub-tasks are already doing.\n"
		~ "- The agent's outputs should generally be trusted.\n\n"
		~ "Available task types:\n\n{{creatable_task_types}}"
	)
	@McpName("Task")
	McpResult createTasks(
		@Description("Array of tasks to execute (in parallel if more than one)")
		TaskSpec[] tasks
	);

	@Description(
		"Switch this task to a different mode within the same session.\n\n"
		~ "The current conversation context is preserved — you will receive a new "
		~ "prompt describing the new mode's expectations, and may get a different "
		~ "tool set. Use this when your current phase is complete and the next phase "
		~ "needs the same context (e.g., plan → triage).\n\n"
		~ "**This is a terminal action.** After calling SwitchMode, yield your turn "
		~ "immediately — do not call any other tools or generate further output. "
		~ "The mode has not switched yet; you will receive new instructions when "
		~ "your session resumes.\n\n"
		~ "Available modes:\n\n{{switchmodes}}"
	)
	@McpName("SwitchMode")
	McpResult switchMode(
		@Description("The mode to switch to (e.g., 'done', 'implement', 'decompose')")
		string continuation
	);

	@Description(
		"Hand off this task to a successor with a fresh session.\n\n"
		~ "Use this when your work is complete and the next phase does NOT need "
		~ "your full conversation context — only the information you pass in the "
		~ "prompt. The current session ends, a new task is created with the prompt "
		~ "you provide, and your task is marked completed.\n\n"
		~ "**This is a terminal action.** After calling Handoff, your session will end. "
		~ "Do not call any other tools after Handoff.\n\n"
		~ "Available handoffs:\n\n{{handoffs}}"
	)
	@McpName("Handoff")
	McpResult handoff(
		@Description("The handoff name to follow (e.g., 'small_fix', 'needs_plan', 'done')")
		string continuation,
		@Description("The prompt for the successor task — include all findings and context needed")
		string prompt
	);
}

import ae.utils.promise : Promise;

/// Backend interface — methods that CydoToolsImpl needs from the application.
/// App implements this; the indirection breaks the compile-time dependency on cydo.app.
interface ToolsBackend
{
	Promise!McpResult handleCreateTask(string callerTid,
		string description, string taskType, string prompt);
	McpResult handleSwitchMode(string callerTid, string continuation);
	McpResult handleHandoff(string callerTid, string continuation, string prompt);
}

/// Tool implementation — constructed per MCP call with the calling App and task ID.
/// Async tools (e.g. Task) use fiber-based await to block until completion.
class CydoToolsImpl : CydoTools
{
	private ToolsBackend app;
	private string callerTid;

	this(ToolsBackend app, string callerTid)
	{
		this.app = app;
		this.callerTid = callerTid;
	}

	/+
	McpResult read(string file_path)
	{
		import std.file : exists, isFile, readText;

		if (!exists(file_path))
			return McpResult("File not found: " ~ file_path, true);

		if (!isFile(file_path))
			return McpResult("Not a file: " ~ file_path, true);

		try
		{
			auto content = readText(file_path);
			return McpResult(content, false);
		}
		catch (Exception e)
			return McpResult("Error reading file: " ~ e.msg, true);
	}
	+/

	McpResult createTasks(TaskSpec[] tasks)
	{
		import ae.utils.json : JSONFragment, toJson;
		import ae.utils.promise : Promise, all;
		import ae.utils.promise.await : await;

		if (tasks.length == 0)
			return McpResult("No tasks provided", true);

		// Launch all tasks — each returns a promise
		auto promises = new Promise!McpResult[tasks.length];
		foreach (i, ref spec; tasks)
			promises[i] = app.handleCreateTask(callerTid, spec.description, spec.task_type, spec.prompt);

		McpResult[] results = all(promises).await();

		// Collect into a JSON array
		bool anyError;
		JSONFragment[] items;
		foreach (ref result; results)
		{
			if (result.structuredContent)
				items ~= result.structuredContent;
			else
				items ~= JSONFragment(toJson(result.text));
			if (result.isError)
				anyError = true;
		}
		auto arrayJson = toJson(items);
		auto wrappedJson = `{"tasks":` ~ arrayJson ~ `}`;

		return McpResult(arrayJson, anyError, JSONFragment(wrappedJson));
	}

	McpResult switchMode(string continuation)
	{
		return app.handleSwitchMode(callerTid, continuation);
	}

	McpResult handoff(string continuation, string prompt)
	{
		return app.handleHandoff(callerTid, continuation, prompt);
	}
}
