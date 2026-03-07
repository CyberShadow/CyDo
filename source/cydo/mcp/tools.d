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
}

/// Tool implementation — executed by the backend.
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
}
