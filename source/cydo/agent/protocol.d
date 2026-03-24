module cydo.agent.protocol;

import ae.utils.json : JSONFragment, JSONOptional, JSONExtras, jsonParse, toJson;

// ── Agnostic protocol struct definitions ───────────────────────────────────

// ── Content types ──────────────────────────────────────────────

/// Content block in an assistant message.
struct ContentBlock
{
	string type;                     // "text", "tool_use", "thinking"
	@JSONOptional string text;       // text and thinking blocks
	@JSONOptional string id;         // tool_use blocks
	@JSONOptional string name;       // tool_use blocks
	@JSONOptional JSONFragment input; // tool_use blocks (opaque)
	@JSONOptional JSONFragment _extras;
}

/// Usage info (token counts).
struct UsageInfo
{
	int input_tokens;
	int output_tokens;
}

/// Compact metadata.
struct CompactMetadata
{
	@JSONOptional string trigger;
	@JSONOptional int pre_tokens;
}

// ── Event types ────────────────────────────────────────────────

/// session/init
struct SessionInitEvent
{
	string type = "session/init";
	string session_id;
	string model;
	string cwd;
	string[] tools;
	string agent_version;                  // was claude_code_version
	string permission_mode;                // was permissionMode
	@JSONOptional string agent;
	@JSONOptional string api_key_source;   // was apiKeySource
	@JSONOptional string fast_mode_state;
	@JSONOptional string[] skills;
	@JSONOptional JSONFragment mcp_servers;
	@JSONOptional JSONFragment agents;
	@JSONOptional JSONFragment plugins;
	bool supports_file_revert;
	@JSONOptional JSONFragment _extras;
}

/// session/status
struct SessionStatusEvent
{
	string type = "session/status";
	@JSONOptional string status;
}

/// session/compacted
struct SessionCompactedEvent
{
	string type = "session/compacted";
	@JSONOptional CompactMetadata compact_metadata;
}

/// turn/result
struct TurnResultEvent
{
	string type = "turn/result";
	string subtype;
	bool is_error;
	@JSONOptional string result;
	int num_turns;
	int duration_ms;
	@JSONOptional int duration_api_ms;
	double total_cost_usd;
	UsageInfo usage;
	@JSONOptional JSONFragment model_usage;
	@JSONOptional JSONFragment permission_denials;
	@JSONOptional string stop_reason;
	@JSONOptional string[] errors;
	@JSONOptional JSONFragment _extras;
}

/// session/summary
struct SessionSummaryEvent
{
	string type = "session/summary";
	string summary;
}

/// session/rate_limit
struct SessionRateLimitEvent
{
	string type = "session/rate_limit";
	JSONFragment rate_limit_info;
}

/// task/started
struct TaskStartedEvent
{
	string type = "task/started";
	string task_id;
	@JSONOptional string tool_use_id;
	@JSONOptional string description;
	@JSONOptional string task_type;
	@JSONOptional JSONFragment _extras;
}

/// task/notification
struct TaskNotificationEvent
{
	string type = "task/notification";
	string task_id;
	string status;
	@JSONOptional string output_file;
	@JSONOptional string summary;
	@JSONOptional JSONFragment _extras;
}

/// control/response
struct ControlResponseEvent
{
	string type = "control/response";
	JSONFragment response;
}

/// process/stderr
struct ProcessStderrEvent
{
	string type = "process/stderr";
	string text;
}

/// process/exit
struct ProcessExitEvent
{
	string type = "process/exit";
	int code;
	@JSONOptional bool is_continuation;
}

/// item/started — a new content item begins streaming.
struct ItemStartedEvent
{
	string type = "item/started";
	string item_id;
	string item_type;            // "text", "thinking", "tool_use", "user_message"
	@JSONOptional string name;           // tool name for tool_use
	@JSONOptional JSONFragment input;    // initial input for tool_use
	@JSONOptional string text;           // initial text for text/thinking or user_message
	@JSONOptional bool is_replay;
	@JSONOptional bool is_synthetic;
	@JSONOptional bool is_meta;
	@JSONOptional bool is_steering;
	@JSONOptional bool pending;
	@JSONOptional string uuid;
	@JSONOptional bool isCompactSummary;
	@JSONOptional string parent_tool_use_id;
	@JSONOptional bool is_sidechain;
	@JSONOptional JSONFragment _extras;
}

/// item/delta — incremental content for the active item.
struct ItemDeltaEvent
{
	string type = "item/delta";
	string item_id;
	string delta_type;  // "text_delta", "thinking_delta", "input_json_delta", "output_delta"
	string content;
}

/// item/completed — the active item has finished streaming.
struct ItemCompletedEvent
{
	string type = "item/completed";
	string item_id;
	@JSONOptional string text;
	@JSONOptional JSONFragment input;
	@JSONOptional string output;
	@JSONOptional bool is_error;
	@JSONOptional JSONFragment _extras;
}

/// item/result — tool result returned for a previously started tool_use item.
struct ItemResultEvent
{
	string type = "item/result";
	string item_id;
	JSONFragment content;  // string or content block array
	@JSONOptional bool is_error;
	@JSONOptional JSONFragment tool_result;  // opaque payload (toolUseResult/tool_use_result)
	@JSONOptional JSONFragment _extras;
}

/// turn/stop — the assistant turn has finished (replaces stream/turn_stop + message/assistant).
struct TurnStopEvent
{
	string type = "turn/stop";
	@JSONOptional string model;
	@JSONOptional UsageInfo usage;
	@JSONOptional string parent_tool_use_id;
	@JSONOptional bool is_sidechain;
	@JSONOptional bool is_api_error;
	@JSONOptional string uuid;
	@JSONOptional JSONFragment _extras;
}

/// turn/delta — turn-level metadata update from assistant events.
struct TurnDeltaEvent
{
	string type = "turn/delta";
	@JSONOptional string model;
	@JSONOptional UsageInfo usage;
	@JSONOptional string parent_tool_use_id;
	@JSONOptional bool is_sidechain;
	@JSONOptional bool is_api_error;
	@JSONOptional string uuid;
	@JSONOptional JSONFragment _extras;
}

/// Command input for Bash tool_use blocks (Codex agent).
struct CommandInput
{
	string command;
	string description;
}

/// agent/unrecognized — data from the agent process that we couldn't translate.
struct AgentUnrecognizedEvent
{
	string type = "agent/unrecognized";
	string reason;      // e.g. "unknown event type: foo", "unknown method: bar/baz", "non-JSON output"
	JSONFragment raw_content; // the raw string from the agent (JSON or otherwise)
}

string makeUnrecognizedEvent(string reason, string rawContent)
{
	AgentUnrecognizedEvent ev;
	ev.reason = reason;
	// Embed rawContent as a JSON value if it's valid JSON; otherwise quote it
	// as a string so the resulting event is always well-formed JSON.
	try { ev.raw_content = jsonParse!JSONFragment(rawContent); }
	catch (Exception) { ev.raw_content = JSONFragment(toJson(rawContent)); }
	return toJson(ev);
}

/// Inject `,"_raw":<rawJson>` before the final `}` of a JSON object string.
string injectRawField(string translated, string rawJson)
{
	auto idx = translated.length;
	while (idx > 0 && translated[--idx] != '}') {}
	return translated[0 .. idx] ~ `,"_raw":` ~ rawJson ~ translated[idx .. $];
}

/// Strip the `,"_raw":...` suffix from a translated event.
/// Assumes `_raw` was injected by `injectRawField` (always the last field).
string stripRawField(string event)
{
	import std.string : indexOf;
	enum marker = `,"_raw":`;
	auto idx = event.indexOf(marker);
	if (idx < 0)
		return event;
	return event[0 .. idx] ~ "}";
}

/// Extract the raw JSON value from a `_raw` field in an event string.
/// Returns null if no `_raw` field is present.
string extractRawField(string event)
{
	import std.string : indexOf;
	enum marker = `,"_raw":`;
	auto idx = event.indexOf(marker);
	if (idx < 0)
		return null;
	// Value spans from after marker to before the closing }
	return event[idx + marker.length .. $ - 1];
}
