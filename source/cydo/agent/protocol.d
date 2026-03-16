module cydo.agent.protocol;

import ae.utils.json : JSONFragment, JSONOptional, JSONPartial, jsonParse, toJson;

/// Translate a Claude stream-json event to the agent-agnostic protocol.
/// Returns null for events that should be consumed (not forwarded).
string translateClaudeEvent(string rawLine)
{
	@JSONPartial
	static struct TypeProbe
	{
		string type;
		string subtype;
	}

	TypeProbe probe;
	try
		probe = jsonParse!TypeProbe(rawLine);
	catch (Exception)
		return rawLine; // unparseable → pass through

	switch (probe.type)
	{
		case "system":
			return translateSystemEvent(rawLine, probe.subtype);
		case "assistant":
			return translateAssistantMessage(rawLine);
		case "user":
			return normalizeUserMessage(rawLine);
		case "stream_event":
			return translateStreamEvent(rawLine);
		case "result":
			return normalizeTurnResult(rawLine);
		case "summary":
			return renameType(rawLine, "session/summary");
		case "rate_limit_event":
			return renameType(rawLine, "session/rate_limit");
		case "control_response":
			return renameType(rawLine, "control/response");
		case "stderr":
			return renameType(rawLine, "process/stderr");
		case "exit":
			return renameType(rawLine, "process/exit");
		case "queue-operation":
			return null; // consumed — handled by broadcastTask / stateful replay closure
		default:
			return rawLine; // unknown → pass through
	}
}

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
}

/// task/notification
struct TaskNotificationEvent
{
	string type = "task/notification";
	string task_id;
	string status;
	@JSONOptional string output_file;
	@JSONOptional string summary;
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
}

// ─────────────────────────────────────────────────────────────────────────────

private:

/// Translate system events by mapping subtype to the agnostic type string.
string translateSystemEvent(string rawLine, string subtype)
{
	switch (subtype)
	{
		case "init":
			return translateSessionInit(rawLine);
		case "status":
			return replaceTypeRemoveSubtype(rawLine, "session/status");
		case "compact_boundary":
			return replaceTypeRemoveSubtype(rawLine, "session/compacted");
		case "task_started":
			return normalizeTaskStarted(rawLine);
		case "task_notification":
			return normalizeTaskNotification(rawLine);
		default:
			return rawLine; // unknown subtypes pass through
	}
}

/// Normalize a Claude session/init event to the agnostic SessionInitEvent format.
/// Renames fields and drops Claude-specific fields.
string translateSessionInit(string rawLine)
{
	@JSONPartial
	static struct ClaudeInit
	{
		string session_id;
		string model;
		string cwd;
		@JSONOptional string[] tools;
		@JSONOptional string claude_code_version;
		@JSONOptional string permissionMode;
		@JSONOptional string apiKeySource;
		@JSONOptional string fast_mode_state;
		@JSONOptional string[] skills;
		@JSONOptional JSONFragment mcp_servers;
		@JSONOptional JSONFragment agents;
		@JSONOptional JSONFragment plugins;
		@JSONOptional string agent;
	}

	ClaudeInit raw;
	try
		raw = jsonParse!ClaudeInit(rawLine);
	catch (Exception)
		return replaceTypeRemoveSubtype(rawLine, "session/init"); // fallback

	SessionInitEvent ev;
	ev.session_id    = raw.session_id;
	ev.model         = raw.model;
	ev.cwd           = raw.cwd;
	ev.tools         = raw.tools;
	ev.agent_version = raw.claude_code_version;
	ev.permission_mode = raw.permissionMode;
	ev.agent         = raw.agent;
	ev.api_key_source  = raw.apiKeySource;
	ev.fast_mode_state = raw.fast_mode_state;
	ev.skills        = raw.skills;
	ev.mcp_servers   = raw.mcp_servers;
	ev.agents        = raw.agents;
	ev.plugins       = raw.plugins;
	return toJson(ev);
}

/// Normalize a Claude assistant message to the agnostic AssistantMessageEvent format.
/// Flattens message.* fields to top level, renames isSidechain/isApiErrorMessage,
/// renames thinking blocks' "thinking" field to "text", drops signature.
string translateAssistantMessage(string rawLine)
{
	@JSONPartial
	static struct ClaudeThinkingBlock
	{
		string type;     // "thinking"
		@JSONOptional string thinking;
		@JSONOptional string text;
		@JSONOptional string id;
		@JSONOptional string name;
		@JSONOptional JSONFragment input;
	}

	@JSONPartial
	static struct ClaudeMessage
	{
		string id;
		ClaudeThinkingBlock[] content;
		@JSONOptional string model;
		@JSONOptional string stop_reason;
		@JSONOptional int input_tokens;
		@JSONOptional int output_tokens;
		@JSONOptional JSONFragment usage;
	}

	@JSONPartial
	static struct ClaudeAssistant
	{
		@JSONOptional string parent_tool_use_id;
		@JSONOptional bool isSidechain;
		@JSONOptional bool isApiErrorMessage;
		ClaudeMessage message;
	}

	ClaudeAssistant raw;
	try
		raw = jsonParse!ClaudeAssistant(rawLine);
	catch (Exception)
		return renameType(rawLine, "message/assistant"); // fallback

	// Build normalized content blocks
	ContentBlock[] content;
	foreach (ref b; raw.message.content)
	{
		ContentBlock cb;
		cb.type = b.type;
		if (b.type == "thinking")
		{
			// Rename "thinking" field → "text"; drop signature
			cb.text = b.thinking.length > 0 ? b.thinking : b.text;
		}
		else if (b.type == "text")
		{
			cb.text = b.text;
		}
		else if (b.type == "tool_use")
		{
			cb.id    = b.id;
			cb.name  = b.name;
			cb.input = b.input;
		}
		content ~= cb;
	}

	// Extract usage
	UsageInfo usage;
	if (raw.message.usage.json !is null && raw.message.usage.json.length > 0)
	{
		@JSONPartial
		static struct UsageProbe { @JSONOptional int input_tokens; @JSONOptional int output_tokens; }
		try
		{
			auto u = jsonParse!UsageProbe(raw.message.usage.json);
			usage.input_tokens  = u.input_tokens;
			usage.output_tokens = u.output_tokens;
		}
		catch (Exception) {}
	}

	AssistantMessageEvent ev;
	ev.id                  = raw.message.id;
	ev.content             = content;
	ev.model               = raw.message.model;
	ev.stop_reason         = raw.message.stop_reason;
	ev.usage               = usage;
	ev.parent_tool_use_id  = raw.parent_tool_use_id;
	ev.is_sidechain        = raw.isSidechain;
	ev.is_api_error        = raw.isApiErrorMessage;
	return toJson(ev);
}


/// Normalize a Claude user message to the agnostic UserMessageEvent format.
/// Flattens message.content to top level, renames camelCase flags, unifies
/// toolUseResult/tool_use_result → tool_result, drops session_id/slug/role/uuid-less fields.
string normalizeUserMessage(string rawLine)
{
	@JSONPartial
	static struct ClaudeUserMsg
	{
		JSONFragment content;
	}

	@JSONPartial
	static struct ClaudeUser
	{
		ClaudeUserMsg message;
		@JSONOptional string parent_tool_use_id;
		@JSONOptional bool isSidechain;
		@JSONOptional bool isReplay;
		@JSONOptional bool isSynthetic;
		@JSONOptional bool isMeta;
		@JSONOptional bool isSteering;
		@JSONOptional bool pending;
		@JSONOptional string uuid;
		@JSONOptional JSONFragment toolUseResult;
		@JSONOptional JSONFragment tool_use_result;
	}

	ClaudeUser raw;
	try
		raw = jsonParse!ClaudeUser(rawLine);
	catch (Exception)
		return renameType(rawLine, "message/user"); // fallback

	UserMessageEvent ev;
	ev.content            = raw.message.content;
	ev.parent_tool_use_id = raw.parent_tool_use_id;
	ev.is_sidechain       = raw.isSidechain;
	ev.is_replay          = raw.isReplay;
	ev.is_synthetic       = raw.isSynthetic;
	ev.is_meta            = raw.isMeta;
	ev.is_steering        = raw.isSteering;
	ev.pending            = raw.pending;
	ev.uuid               = raw.uuid;
	if (raw.toolUseResult.json !is null && raw.toolUseResult.json.length > 0)
		ev.tool_result = raw.toolUseResult;
	else if (raw.tool_use_result.json !is null && raw.tool_use_result.json.length > 0)
		ev.tool_result = raw.tool_use_result;
	return toJson(ev);
}

/// Normalize a Claude result event to the agnostic TurnResultEvent format.
/// Renames modelUsage → model_usage, normalizes usage to input/output only,
/// drops uuid and session_id.
string normalizeTurnResult(string rawLine)
{
	@JSONPartial
	static struct ClaudeUsage
	{
		@JSONOptional int input_tokens;
		@JSONOptional int output_tokens;
	}

	@JSONPartial
	static struct ClaudeResult
	{
		string subtype;
		bool is_error;
		@JSONOptional string result;
		int num_turns;
		int duration_ms;
		@JSONOptional int duration_api_ms;
		double total_cost_usd;
		@JSONOptional ClaudeUsage usage;
		@JSONOptional JSONFragment modelUsage;
		@JSONOptional JSONFragment model_usage;
		@JSONOptional JSONFragment permission_denials;
		@JSONOptional string stop_reason;
		@JSONOptional string[] errors;
	}

	ClaudeResult raw;
	try
		raw = jsonParse!ClaudeResult(rawLine);
	catch (Exception)
		return renameType(rawLine, "turn/result"); // fallback

	TurnResultEvent ev;
	ev.subtype            = raw.subtype;
	ev.is_error           = raw.is_error;
	ev.result             = raw.result;
	ev.num_turns          = raw.num_turns;
	ev.duration_ms        = raw.duration_ms;
	ev.duration_api_ms    = raw.duration_api_ms;
	ev.total_cost_usd     = raw.total_cost_usd;
	ev.usage              = UsageInfo(raw.usage.input_tokens, raw.usage.output_tokens);
	if (raw.modelUsage.json !is null && raw.modelUsage.json.length > 0)
		ev.model_usage = raw.modelUsage;
	else if (raw.model_usage.json !is null && raw.model_usage.json.length > 0)
		ev.model_usage = raw.model_usage;
	ev.permission_denials = raw.permission_denials;
	ev.stop_reason        = raw.stop_reason;
	ev.errors             = raw.errors;
	return toJson(ev);
}

/// Translate stream_event: unwrap inner event and map to stream/* types.
string translateStreamEvent(string rawLine)
{
	import std.algorithm : canFind;
	import std.string : indexOf;

	// Extract the inner event object
	auto eventStart = rawLine.indexOf(`"event":`);
	if (eventStart < 0)
		return rawLine;

	// Find the start of the event value (skip whitespace after colon)
	auto valueStart = eventStart + `"event":`.length;
	while (valueStart < rawLine.length && rawLine[valueStart] == ' ')
		valueStart++;

	if (valueStart >= rawLine.length || rawLine[valueStart] != '{')
		return rawLine;

	// Find matching closing brace
	auto innerEnd = findMatchingBrace(rawLine, valueStart);
	if (innerEnd < 0)
		return rawLine;

	auto innerEvent = rawLine[valueStart .. innerEnd + 1];

	// Probe the inner event's type
	@JSONPartial
	static struct InnerProbe
	{
		string type;
	}

	InnerProbe inner;
	try
		inner = jsonParse!InnerProbe(innerEvent);
	catch (Exception)
		return rawLine;

	string newType;
	switch (inner.type)
	{
		case "content_block_start":
			newType = "stream/block_start";
			break;
		case "content_block_delta":
		{
			// Probe delta type — drop signature_delta, rename thinking_delta field
			@JSONPartial
			static struct BlockDeltaProbe
			{
				@JSONPartial
				static struct DeltaProbe
				{
					string type;
					@JSONOptional string thinking;
				}
				int index;
				DeltaProbe delta;
			}
			try
			{
				auto probe = jsonParse!BlockDeltaProbe(innerEvent);
				if (probe.delta.type == "signature_delta")
					return null; // drop
				if (probe.delta.type == "thinking_delta")
				{
					StreamBlockDeltaEvent ev;
					ev.index = probe.index;
					ev.delta.type = "thinking_delta";
					ev.delta.text = probe.delta.thinking;
					return toJson(ev);
				}
			}
			catch (Exception) {}
			newType = "stream/block_delta";
			break;
		}
		case "content_block_stop":
			newType = "stream/block_stop";
			break;
		case "message_stop":
			newType = "stream/turn_stop";
			break;
		case "message_start":
		case "message_delta":
			return null; // consumed — usage/stop_reason arrives in turn/result
		default:
			return rawLine; // unknown inner types pass through
	}

	// Replace the inner event's type with the agnostic type and promote to top level.
	// The result is: the inner event object with its "type" replaced.
	return renameType(innerEvent, newType);
}

/// Rename the top-level "type" field in a JSON line. Preserves all other fields.
/// Uses brace-depth tracking so nested "type" fields (e.g. inside "message")
/// are not accidentally matched.
string renameType(string rawLine, string newType)
{
	auto typeIdx = findTopLevelType(rawLine);
	if (typeIdx < 0)
		return rawLine;

	auto valueStart = typeIdx + `"type":"`.length;
	// Find closing quote of value
	foreach (i; valueStart .. rawLine.length)
	{
		if (rawLine[i] == '"')
			return rawLine[0 .. typeIdx] ~ `"type":"` ~ newType ~ `"` ~ rawLine[i + 1 .. $];
	}
	return rawLine;
}

/// Find the byte offset of the top-level `"type":"` in a JSON object string.
/// Returns -1 if not found.  Only matches at brace depth 1 (top-level keys).
private int findTopLevelType(string s)
{
	int depth = 0;
	bool inString = false;
	bool escaped = false;
	enum needle = `"type":"`;

	foreach (i; 0 .. s.length)
	{
		auto c = s[i];
		if (escaped)
		{
			escaped = false;
			continue;
		}
		if (c == '\\' && inString)
		{
			escaped = true;
			continue;
		}
		if (c == '"' && !inString)
		{
			// Starting a key or value at the current depth.
			// Check for needle match at top-level (depth 1).
			if (depth == 1 && i + needle.length <= s.length
				&& s[i .. i + needle.length] == needle)
				return cast(int) i;
			inString = true;
			continue;
		}
		if (c == '"')
		{
			inString = false;
			continue;
		}
		if (inString)
			continue;
		if (c == '{')
			depth++;
		else if (c == '}')
			depth--;
	}
	return -1;
}

/// Replace "type":"system" with the new type and remove "subtype":"..." field.
string replaceTypeRemoveSubtype(string rawLine, string newType)
{
	import std.string : indexOf;

	// First rename the type
	auto renamed = renameType(rawLine, newType);

	// Then remove the subtype field
	auto subtypeIdx = renamed.indexOf(`"subtype":"`);
	if (subtypeIdx < 0)
		return renamed;

	// Find the extent of "subtype":"value"
	auto subtypeValueStart = subtypeIdx + `"subtype":"`.length;
	auto subtypeValueEnd = renamed.indexOf('"', subtypeValueStart);
	if (subtypeValueEnd < 0)
		return renamed;

	auto fieldEnd = subtypeValueEnd + 1;

	// Remove trailing comma if present, or leading comma
	if (fieldEnd < renamed.length && renamed[fieldEnd] == ',')
		fieldEnd++;
	else if (subtypeIdx > 0 && renamed[subtypeIdx - 1] == ',')
		subtypeIdx--;

	return renamed[0 .. subtypeIdx] ~ renamed[fieldEnd .. $];
}

/// Normalize a Claude task_started system event to the agnostic TaskStartedEvent format.
/// Drops uuid and session_id fields.
string normalizeTaskStarted(string rawLine)
{
	@JSONPartial
	static struct ClaudeTaskStarted
	{
		string task_id;
		@JSONOptional string tool_use_id;
		@JSONOptional string description;
		@JSONOptional string task_type;
	}

	ClaudeTaskStarted raw;
	try
		raw = jsonParse!ClaudeTaskStarted(rawLine);
	catch (Exception)
		return replaceTypeRemoveSubtype(rawLine, "task/started"); // fallback

	TaskStartedEvent ev;
	ev.task_id      = raw.task_id;
	ev.tool_use_id  = raw.tool_use_id;
	ev.description  = raw.description;
	ev.task_type    = raw.task_type;
	return toJson(ev);
}

/// Normalize a Claude task_notification system event to the agnostic TaskNotificationEvent format.
/// Drops uuid and session_id fields.
string normalizeTaskNotification(string rawLine)
{
	@JSONPartial
	static struct ClaudeTaskNotification
	{
		string task_id;
		string status;
		@JSONOptional string output_file;
		@JSONOptional string summary;
	}

	ClaudeTaskNotification raw;
	try
		raw = jsonParse!ClaudeTaskNotification(rawLine);
	catch (Exception)
		return replaceTypeRemoveSubtype(rawLine, "task/notification"); // fallback

	TaskNotificationEvent ev;
	ev.task_id     = raw.task_id;
	ev.status      = raw.status;
	ev.output_file = raw.output_file;
	ev.summary     = raw.summary;
	return toJson(ev);
}

/// Find the index of the closing brace matching the opening brace at pos.
int findMatchingBrace(string s, size_t pos)
{
	if (pos >= s.length || s[pos] != '{')
		return -1;

	int depth = 0;
	bool inString = false;
	bool escaped = false;

	foreach (i; pos .. s.length)
	{
		auto c = s[i];
		if (escaped)
		{
			escaped = false;
			continue;
		}
		if (c == '\\' && inString)
		{
			escaped = true;
			continue;
		}
		if (c == '"')
		{
			inString = !inString;
			continue;
		}
		if (inString)
			continue;
		if (c == '{')
			depth++;
		else if (c == '}')
		{
			depth--;
			if (depth == 0)
				return cast(int) i;
		}
	}
	return -1;
}
