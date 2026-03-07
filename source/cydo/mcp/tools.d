/// CyDo MCP tool definitions and implementations.
module cydo.mcp.tools;

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
		~ "Use this tool to delegate work to a specialized agent. Each task runs as an "
		~ "independent agent session, visible in the CyDo web UI task tree, and persisted "
		~ "across restarts.\n\n"
		~ "## When NOT to use this tool\n"
		~ "- If you want to read a specific file path, use the Read tool directly\n"
		~ "- If you are searching for a specific class, function, or filename pattern, "
		~ "use Glob or Grep directly\n"
		~ "- For trivial tasks you can complete yourself in a single step\n\n"
		~ "## How results work\n"
		~ "- The sub-task runs to completion and returns a structured summary\n"
		~ "- Results are also visible in the CyDo web UI task tree\n"
		~ "- Sub-tasks are persisted and survive backend restarts\n\n"
		~ "## Usage notes\n"
		~ "- Sub-tasks protect your context window from excessive search results "
		~ "and long outputs. Use them to keep your main conversation focused.\n"
		~ "- Avoid duplicating work that sub-tasks are already doing — if you "
		~ "delegate research to a sub-task, do not also perform the same searches yourself.\n"
		~ "- Provide clear, detailed prompts so the agent can work autonomously "
		~ "and return exactly the information you need.\n"
		~ "- Clearly tell the agent whether you expect it to write code or just "
		~ "do research, since it is not aware of the user's intent.\n"
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

/// Tool implementation — executed by the backend.
/// Note: Task is intercepted in handleMcpCall and never reaches this class.
class CydoToolsImpl : CydoTools
{
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
		return McpResult("Task is handled by the server", true);
	}
}
