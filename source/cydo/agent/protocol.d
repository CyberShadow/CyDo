module cydo.agent.protocol;

import ae.utils.json : JSONFragment, JSONOptional, JSONExtras;

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

/// Block descriptor in stream/block_start.
struct BlockDescriptor
{
	string type;                     // "text", "tool_use", "thinking"
	@JSONOptional string id;         // tool_use
	@JSONOptional string name;       // tool_use
}

/// Stream delta.
struct StreamDelta
{
	string type;                          // "text_delta", "thinking_delta", "input_json_delta"
	@JSONOptional string text;            // text_delta and thinking_delta
	@JSONOptional string partial_json;    // input_json_delta
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

/// message/assistant (flat — no message wrapper)
struct AssistantMessageEvent
{
	string type = "message/assistant";
	string id;
	ContentBlock[] content;
	string model;
	string stop_reason;
	@JSONOptional UsageInfo usage;
	@JSONOptional string parent_tool_use_id;
	@JSONOptional bool is_sidechain;       // was isSidechain
	@JSONOptional bool is_api_error;       // was isApiErrorMessage
	@JSONOptional string uuid;             // for fork support
	@JSONOptional JSONFragment _extras;
}

/// message/user (flat — no message wrapper)
struct UserMessageEvent
{
	string type = "message/user";
	JSONFragment content;                  // string or ContentBlock[]
	@JSONOptional string parent_tool_use_id;
	@JSONOptional bool is_sidechain;
	@JSONOptional JSONFragment tool_result; // unified from toolUseResult/tool_use_result
	@JSONOptional bool is_replay;          // was isReplay
	@JSONOptional bool is_synthetic;       // was isSynthetic
	@JSONOptional bool is_meta;            // was isMeta
	@JSONOptional bool is_steering;        // was isSteering
	@JSONOptional bool pending;
	@JSONOptional string uuid;             // for fork support
	@JSONOptional JSONFragment _extras;
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

/// stream/block_start
struct StreamBlockStartEvent
{
	string type = "stream/block_start";
	int index;
	BlockDescriptor content_block;
}

/// stream/block_delta
struct StreamBlockDeltaEvent
{
	string type = "stream/block_delta";
	int index;
	StreamDelta delta;
}

/// stream/block_stop
struct StreamBlockStopEvent
{
	string type = "stream/block_stop";
	int index;
}

/// stream/turn_stop
struct StreamTurnStopEvent
{
	string type = "stream/turn_stop";
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

/// Command input for Bash tool_use blocks (Codex agent).
struct CommandInput
{
	string command;
	string description;
}

/// Tool result content block for message/user events.
struct ToolResultBlock
{
	string type = "tool_result";
	string tool_use_id;
	JSONFragment content;
	@JSONOptional bool is_error;
}
