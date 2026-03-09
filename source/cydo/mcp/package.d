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
struct McpResult
{
	string text;
	bool isError;
	JSONFragment structuredContent; /// Optional structured JSON result (MCP structuredContent)
}

import ae.utils.json : JSONFragment;
