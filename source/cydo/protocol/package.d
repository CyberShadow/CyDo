module cydo.protocol;

import ae.utils.json : JSONFragment, JSONName, JSONOptional, JSONExtras, jsonParse, toJson;
import ae.utils.time.types : AbsTime;

/// Convert a JSONExtras map to a JSONFragment wrapping it as a JSON object.
/// Returns JSONFragment.init (null) if the extras map is empty.
JSONFragment extrasToFragment(JSONExtras extras)
{
	if (extras._data is null || extras._data.length == 0)
		return JSONFragment.init;
	return JSONFragment(toJson(extras._data));
}

// ── Agnostic protocol struct definitions ───────────────────────────────────

// ── Content types ──────────────────────────────────────────────

/// Content block in a message (assistant or user).
struct ContentBlock
{
	string type;                     // "text", "tool_use", "thinking", "image"
	@JSONOptional string text;       // text and thinking blocks
	@JSONOptional string id;         // tool_use blocks
	@JSONOptional string name;       // tool_use blocks
	@JSONOptional JSONFragment input; // tool_use blocks (opaque)
	@JSONOptional string data;       // image blocks: base64-encoded image data
	@JSONOptional string media_type; // image blocks: MIME type (e.g., "image/png")
	@JSONOptional JSONFragment extras;
}

/// Extract plain text from a ContentBlock[].
/// Concatenates all text blocks. Used for descriptions, titles, etc.
string extractContentText(const(ContentBlock)[] blocks)
{
	string result;
	foreach (ref block; blocks)
	{
		if (block.type == "text" && block.text.length > 0)
		{
			if (result.length > 0) result ~= "\n";
			result ~= block.text;
		}
	}
	return result;
}

/// Usage info (token counts).
struct UsageInfo
{
	int input_tokens;
	int output_tokens;
}

/// Per-model usage entry (used in the model_usage map).
struct ModelUsageInfo
{
	@JSONOptional int input_tokens;
	@JSONOptional int output_tokens;
	JSONExtras extras;
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
	@JSONOptional string agent_name;       // user-chosen agent name (config key)
	@JSONOptional string api_key_source;   // was apiKeySource
	@JSONOptional string fast_mode_state;
	@JSONOptional string[] skills;
	@JSONOptional JSONFragment[] mcp_servers;
	@JSONOptional JSONFragment[] agents;
	@JSONOptional JSONFragment[] plugins;
	bool supports_file_revert;
	@JSONOptional JSONFragment extras;
}

/// session/metadata
struct SessionMetadataEvent
{
	string type = "session/metadata";
	string model;
}

/// session/status
struct SessionStatusEvent
{
	string type = "session/status";
	@JSONOptional string status;
	@JSONOptional string permission_mode;
	@JSONOptional JSONFragment extras;
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
	@JSONOptional ModelUsageInfo[string] model_usage;
	@JSONOptional JSONFragment[] permission_denials;
	@JSONOptional string stop_reason;
	@JSONOptional string[] errors;
	@JSONOptional JSONFragment extras;
}

/// session/summary
struct SessionSummaryEvent
{
	string type = "session/summary";
	string summary;
}

/// Rate limit information.
struct RateLimitInfo
{
	@JSONOptional string status;
	@JSONOptional string rateLimitType;
	@JSONOptional double resetsAt;
	@JSONOptional double utilization;
	@JSONOptional string overageStatus;
	@JSONOptional double overageResetsAt;
	@JSONOptional string overageDisabledReason;
	@JSONOptional bool isUsingOverage;
	@JSONOptional double surpassedThreshold;
	JSONExtras extras;
}

/// session/rate_limit
struct SessionRateLimitEvent
{
	string type = "session/rate_limit";
	RateLimitInfo rate_limit_info;
}

/// task/started
struct TaskStartedEvent
{
	string type = "task/started";
	string task_id;
	@JSONOptional string tool_use_id;
	@JSONOptional string description;
	@JSONOptional string task_type;
	@JSONOptional JSONFragment extras;
}

/// task/notification
struct TaskNotificationEvent
{
	string type = "task/notification";
	string task_id;
	string status;
	@JSONOptional string output_file;
	@JSONOptional string summary;
	@JSONOptional JSONFragment extras;
}

/// Payload of a control/response event.
struct ControlResponse
{
	@JSONOptional string subtype;
	@JSONOptional string request_id;
	JSONExtras extras;
}

/// control/response
struct ControlResponseEvent
{
	string type = "control/response";
	ControlResponse response;
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

enum TaskDiagnosticSeverity : string
{
	info = "info",
	warning = "warning",
	error = "error",
}

struct TaskDiagnosticEvent
{
	string type = "cydo/task_diagnostic";
	TaskDiagnosticSeverity severity;
	string subject;
	string body;
}

/// item/started — a new content item begins streaming.
enum HistoryBoundaryKind
{
	user,
	provisional_user,
	agent_turn,
}

struct HistoryBoundary
{
	string anchor;
	HistoryBoundaryKind kind;
	@JSONOptional string checkpoint_uuid;
}

struct ItemStartedEvent
{
	string type = "item/started";
	string item_id;
	string item_type;            // "text", "thinking", "tool_use", "user_message"
	@JSONOptional string name;           // tool name for tool_use (canonical, no prefix)
	@JSONOptional string tool_server;    // MCP server name (e.g. "cydo", "github"); null = built-in
	@JSONOptional string tool_source;    // "mcp" for MCP tools; null = built-in
	@JSONOptional JSONFragment input;    // initial input for tool_use
	@JSONOptional string text;           // initial text for text/thinking or user_message
	@JSONOptional ContentBlock[] content; // structured content blocks (for user messages with images)
	@JSONOptional bool is_replay;
	@JSONOptional bool is_synthetic;
	@JSONOptional bool is_meta;
	@JSONOptional bool is_steering;
	@JSONOptional bool pending;
	@JSONOptional string uuid;
	@JSONOptional HistoryBoundary history_boundary;
	@JSONOptional bool isCompactSummary;
	@JSONOptional string parent_tool_use_id;
	@JSONOptional bool is_sidechain;
	@JSONOptional string correlation_id;
	@JSONOptional JSONFragment extras;
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
	@JSONOptional JSONFragment extras;
}

/// item/result — tool result returned for a previously started tool_use item.
struct ItemResultEvent
{
	string type = "item/result";
	string item_id;
	JSONFragment content;  // string or content block array
	@JSONOptional bool is_error;
	@JSONOptional JSONFragment tool_result;  // opaque payload (toolUseResult/tool_use_result)
	@JSONOptional JSONFragment extras;
}

/// user_message/consumed — the agent's queue confirmed what became of a
/// previously displayed user message. The message itself is emitted from the
/// queue enqueue record (the authoritative "user sent this" fact, shown with
/// the pending presentation); this confirmation upgrades it once the queue
/// records prove the outcome: consumed as a mid-turn steering injection,
/// consumed as an ordinary turn opener, or removed without being consumed.
struct UserMessageConsumedEvent
{
	string type = "user_message/consumed";
	string uuid;          // identity of the user message being upgraded
	string consumed_as;   // "steering" | "turn_start" | "removed"
	@JSONOptional string correlation_id;  // send nonce, when the backend can link it
	// The consumption echo's own uuid (the CLI's user-line identity). Replay
	// swallows that line; live sessions display the message under this
	// identity, so anchor resolution accepts either name.
	@JSONOptional string native_uuid;
}

/// turn/stop — the assistant turn has finished (replaces stream/turn_stop + message/assistant).
struct TurnStopEvent
{
	string type = "turn/stop";
	@JSONOptional string model;
	@JSONOptional UsageInfo usage;
	@JSONOptional string parent_tool_use_id;
	@JSONOptional bool is_sidechain;
	@JSONOptional string uuid;
	@JSONOptional HistoryBoundary history_boundary;
	@JSONOptional JSONFragment extras;
}

/// turn/delta — turn-level metadata update from assistant events.
struct TurnDeltaEvent
{
	string type = "turn/delta";
	@JSONOptional string model;
	@JSONOptional UsageInfo usage;
	@JSONOptional string parent_tool_use_id;
	@JSONOptional bool is_sidechain;
	@JSONOptional string uuid;
	@JSONOptional JSONFragment extras;
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
}

string makeUnrecognizedEvent(string reason)
{
	AgentUnrecognizedEvent ev;
	ev.reason = reason;
	return toJson(ev);
}

/// cydo/task_spawned — emitted when CyDo spawns a child task in response
/// to a parent's mcp__cydo__Task tool call. Lands in the parent's task
/// event stream; replays on F5 in the same position.
struct CydoTaskSpawnedEvent
{
	string type = "cydo/task_spawned";
	int child_tid;   // tid of the newly created child task
	int spec_index;  // 0-based index within the parent call's tasks[] array
}

/// Parse an ISO 8601 timestamp string (e.g. "2026-03-30T14:29:14.993Z") into AbsTime.
/// Returns AbsTime.init (stdTime == 0) on failure or empty input.
AbsTime parseIso8601Timestamp(string s) nothrow
{
	import ae.utils.time.parse : parseAbsTime;
	if (s.length == 0)
		return AbsTime.init;
	try
		return parseAbsTime!(`Y-m-d\TH:i:s.vP`)(s);
	catch (Exception) {}
	try
		return parseAbsTime!(`Y-m-d\TH:i:sP`)(s);
	catch (Exception) {}
	return AbsTime.init;
}

/// A translated event paired with its raw agent source.
struct TranslatedEvent
{
	string translated;  // clean agnostic-protocol JSON (no _raw)
	string raw;         // original agent output line (null for synthetic events)
	AbsTime ts;         // AbsTime.init (stdTime == 0) means "not available"
	int sourceLine;     // 1-based physical JSONL line for raw, 0 when not file-backed
	bool isContextBootstrap; // internal submission provenance, never sent on the wire

	this(string translated, string raw, AbsTime ts = AbsTime.init,
		int sourceLine = 0, bool isContextBootstrap = false) @safe nothrow
	{
		this.translated = translated;
		this.raw = raw;
		this.ts = ts;
		this.sourceLine = sourceLine;
		this.isContextBootstrap = isContextBootstrap;
	}
}


// ── Envelope structs ───────────────────────────────────────────────────────

/// Envelope wrapping a translated event with its task ID.
struct TaskEventEnvelope
{
	int tid;
	long ts;           // AbsTime.stdTime; 0 = not available
	JSONFragment event;
}

/// Envelope wrapping a translated event with task ID and sequence number.
struct TaskEventSeqEnvelope
{
	int tid;
	int seq;
	long ts;           // AbsTime.stdTime; 0 = not available
	JSONFragment event;
}

/// History-boundary enrichment of a canonical sequenced event after persistence correlation.
struct TaskHistoryBoundaryReplacedEnvelope
{
	string type = "task_history_boundary_replaced";
	int tid;
	int seq;
	long ts;
	JSONFragment event;
}

/// Envelope for an unconfirmed user event broadcast.
/// For type:"message" sends, correlation_id is the message nonce (optional).
struct UnconfirmedUserEventEnvelope
{
	int tid;
	@JSONName("unconfirmedUserEvent") JSONFragment unconfirmedUserEvent;
	@JSONOptional string correlation_id;
}

/// Envelope signaling that the agent has acknowledged receipt of a user
/// message but it has not yet entered the LLM context.
/// Only emitted by agents that have a separable agent-ack signal (codex,
/// copilot); skipped entirely by claude.
struct AgentAckEnvelope
{
	int tid;
	@JSONName("agentAck") string agentAck; // value: the correlation_id (nonce)
}

// ── Permission response structs ────────────────────────────────────────────

/// Permission allow response sent to the agent.
struct PermissionAllow
{
	string behavior = "allow";
	JSONFragment updatedInput;
}

/// Permission deny response sent to the agent.
struct PermissionDeny
{
	string behavior = "deny";
	string message;
}

// ── MCP result structs ─────────────────────────────────────────────────────

/// Structured content of a "question" MCP result returned to the parent agent.
struct QuestionResult
{
	string status = "question";
	int tid;
	int qid;
	string title;
	string message;
}

/// Structured content of an "answered"/"delivered" MCP result for Ask/Answer tools.
struct AnswerResult
{
	import ae.utils.json : JSONOptional;

	string status;
	int tid;
	@JSONOptional int qid;
	@JSONOptional string title;
	@JSONOptional string message;
	@JSONOptional string note;
}

/// Wrapper for batch task results.
/// Each entry is a discriminated result object.
struct BatchResultEnvelope
{
	JSONFragment[] tasks;
}

/// Decompose a raw tool name (possibly `mcp__server__tool`) into structured fields.
/// On return, `name` holds the canonical display name, `tool_server` and `tool_source`
/// are set for MCP tools and left unchanged (null) for built-in tools.
void decomposeToolName(string rawName, ref string name, ref string tool_server, ref string tool_source)
{
	import std.string : indexOf;
	if (rawName.length > 5 && rawName[0 .. 5] == "mcp__")
	{
		auto rest = rawName[5 .. $];
		auto sep = indexOf(rest, "__");
		if (sep >= 0)
		{
			tool_server = rest[0 .. sep];
			name = rest[sep + 2 .. $];
			tool_source = "mcp";
			return;
		}
	}
	name = rawName;
}

unittest
{
	import std.algorithm : canFind;

	foreach (severity; [TaskDiagnosticSeverity.info, TaskDiagnosticSeverity.warning,
		TaskDiagnosticSeverity.error])
	{
		TaskDiagnosticEvent event;
		event.severity = severity;
		event.subject = "Subject";
		event.body = "Body";
		auto json = toJson(event);
		assert(json == `{"type":"cydo/task_diagnostic","severity":"` ~ severity
			~ `","subject":"Subject","body":"Body"}`);
		assert(!json.canFind(`"item_id"`) && !json.canFind(`"item_type"`)
			&& !json.canFind(`"user_message"`) && !json.canFind(`"is_meta"`)
			&& !json.canFind(`"meta"`));
	}
}

unittest
{
	import ae.utils.json : toJson;
	auto boundary = HistoryBoundary("anchor", HistoryBoundaryKind.user, "checkpoint");
	auto replacement = toJson(TaskHistoryBoundaryReplacedEnvelope("task_history_boundary_replaced", 7, 4, 9,
		JSONFragment(`{"type":"item/started","item_type":"user_message","history_boundary":` ~ toJson(boundary) ~ `}`)));
	auto ordinary = toJson(TaskEventSeqEnvelope(7, 4, 9,
		JSONFragment(`{"type":"item/started","item_type":"user_message"}`)));
	assert(replacement == `{"type":"task_history_boundary_replaced","tid":7,"seq":4,"ts":9,"event":{"type":"item/started","item_type":"user_message","history_boundary":{"anchor":"anchor","kind":"user","checkpoint_uuid":"checkpoint"}}}`);
	assert(ordinary == `{"tid":7,"seq":4,"ts":9,"event":{"type":"item/started","item_type":"user_message"}}`);
}
