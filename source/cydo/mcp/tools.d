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

	@Description("Create a sub-task that runs autonomously and returns its output. "
		~ "Use this to delegate work to a specialized agent.\n\n"
		~ "Available task types:\n{{creatable_task_types}}")
	@McpName("CreateTask")
	McpResult createTask(
		@Description("The task type to create (e.g., 'research', 'plan', 'implement')")
		string task_type,
		@Description("Description of what the sub-task should accomplish")
		string description
	);
}

/// Tool implementation — executed by the backend.
/// Note: CreateTask is intercepted in handleMcpCall and never reaches this class.
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

	McpResult createTask(string task_type, string description)
	{
		return McpResult("CreateTask is handled by the server", true);
	}
}
