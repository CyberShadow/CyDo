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

	package(cydo) void delegate(bool delivered) settleDelivery;

	/// Construct a result with structured content. Sets text = json string
	/// so that content[0].text and structuredContent are identical per MCP spec.
	static McpResult structured(string json, bool isError = false)
	{
		return McpResult(json, isError, JSONFragment(json));
	}
}

import ae.utils.json : JSONFragment;

/// Cancellation signal for a single dispatched tool call.
/// A disconnect can cancel the token after the handler has produced its result.
/// Handlers that opt in must treat cancellation after completion as a no-op.
final class ToolCallCancellation
{
	private bool cancelled_;
	private void delegate() handler;

	@property bool cancelled() const { return cancelled_; }

	void cancel()
	{
		if (cancelled_)
			return;
		cancelled_ = true;
		auto callback = handler;
		handler = null;
		if (callback)
			callback();
	}

	void onCancel(void delegate() dg)
	{
		assert(!cancelled_ && handler is null && dg !is null);
		handler = dg;
	}
}
