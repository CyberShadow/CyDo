/// CyDo MCP tool definitions and implementations.
module cydo.mcp.tools;

import cydo.app : App;
import cydo.mcp : Description, McpName, McpResult;

/// Tool interface — each method is an MCP tool.
/// Compile-time introspection generates metadata and dispatch.
interface CydoTools
{
	@Description("Read the contents of a file from the filesystem. Returns the file content as text.")
	@McpName("Read")
	McpResult read(
		@Description("The absolute path to the file to read")
		string file_path
	);

	@Description(
		"Create a sub-task that runs autonomously and returns its output.\n\n"
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
		~ "## Usage notes\n"
		~ "- Provide clear, detailed prompts so the agent can work autonomously "
		~ "and return exactly the information you need.\n"
		~ "- Clearly tell the agent whether you expect it to write code or just "
		~ "do research, since it is not aware of your broader context.\n"
		~ "- Avoid duplicating work that sub-tasks are already doing.\n"
		~ "- The agent's outputs should generally be trusted.\n\n"
		~ "Available task types:\n{{creatable_task_types}}"
	)
	@McpName("Task")
	McpResult createTask(
		@Description("A short (3-5 word) description of the task")
		string description,
		@Description("The task type to create (e.g., 'research', 'plan', 'implement')")
		string task_type,
		@Description("The task for the agent to perform")
		string prompt
	);
}

/// Tool implementation — constructed per MCP call with the calling App and task ID.
/// Async tools (e.g. Task) use fiber-based await to block until completion.
class CydoToolsImpl : CydoTools
{
	private App app;
	private string callerTid;

	this(App app, string callerTid)
	{
		this.app = app;
		this.callerTid = callerTid;
	}

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

	McpResult createTask(string description, string task_type, string prompt)
	{
		import ae.utils.promise.await : await;
		return app.handleCreateTask(callerTid, description, task_type, prompt).await();
	}
}

