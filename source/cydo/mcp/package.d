/// MCP (Model Context Protocol) tool definitions.
///
/// Tools are defined as D interface methods with UDAs.
/// Compile-time introspection generates MCP metadata and dispatch logic.
module cydo.mcp;

/// Attach a description to a tool (method) or parameter.
struct Description
{
	string text;
}

/// Override the MCP tool name (default is the D method name).
struct McpName
{
	string name;
}

/// Result of an MCP tool call.
///
/// When returning structured content, use `McpResult.structured(json, isError)`
/// which sets `text` to the same JSON string — per the MCP spec, `content[0].text`
/// must equal `structuredContent` when both are present.
struct McpResult
{
	string text;
	bool isError;
	JSONFragment structuredContent; /// Optional structured JSON; must equal text when present.

	/// Construct a result with structured content. Sets text = json string
	/// so that content[0].text and structuredContent are identical per MCP spec.
	static McpResult structured(string json, bool isError = false)
	{
		return McpResult(json, isError, JSONFragment(json));
	}
}

import ae.utils.json : JSONFragment;
