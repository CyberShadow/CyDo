module cydo.agent.protocol;

import ae.utils.json : JSONFragment, JSONPartial, jsonParse, toJson;

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
			return renameType(rawLine, "message/assistant");
		case "user":
			return renameType(rawLine, "message/user");
		case "stream_event":
			return translateStreamEvent(rawLine);
		case "result":
			return renameType(rawLine, "turn/result");
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

private:

/// Translate system events by mapping subtype to the agnostic type string.
string translateSystemEvent(string rawLine, string subtype)
{
	string newType;
	switch (subtype)
	{
		case "init":
			newType = "session/init";
			break;
		case "status":
			newType = "session/status";
			break;
		case "compact_boundary":
			newType = "session/compacted";
			break;
		case "task_started":
			newType = "task/started";
			break;
		case "task_notification":
			newType = "task/notification";
			break;
		default:
			return rawLine; // unknown subtypes pass through
	}

	// Replace "type":"system" with the agnostic type and remove "subtype"
	return replaceTypeRemoveSubtype(rawLine, newType);
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
			newType = "stream/block_delta";
			break;
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
