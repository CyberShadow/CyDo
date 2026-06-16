module cydo.history.abbrev;

import std.logger : tracef;

import cydo.task : extractEventFromEnvelope;

/// Extract text content from a translated protocol event. Handles agnostic
/// protocol (item/started user_message, item/completed) and legacy formats.
package(cydo) string extractMessageText(string event)
{
	import ae.utils.json : jsonParse, JSONPartial;

	// Try top-level text field first (item/started user_message, item/completed text items)
	@JSONPartial
	static struct TopTextProbe { string text; bool pending; }

	try
	{
		auto probe = jsonParse!TopTextProbe(event);
		if (probe.text.length > 0 && !probe.pending)
			return probe.text;
	}
	catch (Exception) {}

	// Try result field (turn/result events — Codex emits the assistant text here)
	@JSONPartial
	static struct ResultFieldProbe { string result; }

	try
	{
		auto probe = jsonParse!ResultFieldProbe(event);
		if (probe.result.length > 0)
			return probe.result;
	}
	catch (Exception) {}

	// Try top-level string content (item/delta text_delta merged events)
	@JSONPartial
	static struct FlatStringProbe { string content; string delta_type; }

	try
	{
		auto probe = jsonParse!FlatStringProbe(event);
		if (probe.delta_type == "text_delta" && probe.content.length > 0)
			return probe.content;
	}
	catch (Exception) {}

	// Try string content (legacy user messages)
	@JSONPartial
	static struct StringMsg { string content; }
	@JSONPartial
	static struct StringProbe { StringMsg message; bool pending; }

	try
	{
		auto probe = jsonParse!StringProbe(event);
		if (probe.message.content.length > 0 && !probe.pending)
			return probe.message.content;
	}
	catch (Exception) {}

	// Try nested params.item.text (Codex item/completed agentMessage events)
	@JSONPartial
	static struct ParamsItemTextInner { string text; }
	@JSONPartial
	static struct ParamsItemParamsInner { ParamsItemTextInner item; }
	@JSONPartial
	static struct ParamsItemProbe { ParamsItemParamsInner params; }

	try
	{
		auto probe = jsonParse!ParamsItemProbe(event);
		if (probe.params.item.text.length > 0)
			return probe.params.item.text;
	}
	catch (Exception) {}

	// Try flat array content (agnostic assistant messages: content at top level)
	@JSONPartial
	static struct Block { string type; string text; }
	@JSONPartial
	static struct FlatProbe { Block[] content; }

	try
	{
		auto probe = jsonParse!FlatProbe(event);
		string result;
		foreach (ref block; probe.content)
			if (block.type == "text")
				result ~= block.text;
		if (result.length > 0)
			return result;
	}
	catch (Exception) {}

	// Try wrapped array content (legacy format with message wrapper)
	@JSONPartial
	static struct ArrayMsg { Block[] content; }
	@JSONPartial
	static struct ArrayProbe { ArrayMsg message; }

	try
	{
		auto probe = jsonParse!ArrayProbe(event);
		string result;
		foreach (ref block; probe.message.content)
			if (block.type == "text")
				result ~= block.text;
		return result;
	}
	catch (Exception e)
	{ tracef("extractAssistantText: all parse attempts failed: %s", e.msg); return ""; }
}

private string abbreviateText(string text, size_t threshold)
{
	import std.regex : replaceAll;
	import ae.utils.regex : re;

	text = text.replaceAll(re!`\s+`, " ");
	if (text.length <= threshold)
		return text;
	auto keepEach = threshold / 2 - 3;
	return text[0 .. keepEach] ~ " [...] " ~ text[$ - keepEach .. $];
}

/// Build an abbreviated conversation history string from raw history envelope strings.
/// Performs two passes: first counting stats for the header, then building abbreviated
/// entries walking history in reverse.
package(cydo) string buildAbbreviatedHistoryFromStrings(string[] envelopes)
{
	// First pass: count stats for structured header
	int userMsgCount = 0;
	int toolUseCount = 0;
	foreach (envelope; envelopes)
	{
		auto event = extractEventFromEnvelope(envelope);
		if (event.length == 0)
			continue;
		import std.algorithm : canFind;
		if (event.canFind(`"user_message"`))
			userMsgCount++;
		if (event.canFind(`"tool_use"`))
			toolUseCount++;
	}

	// Second pass: build entries walking history in reverse
	string[] entries;
	size_t totalLen = 0;
	enum maxLen = 2_500;
	enum truncThreshold = 256;

	bool seenAssistantText = false;
	bool turnCollapsed = false;
	// True when the most-recent "A:" entry came from a non-streaming source
	// (turn/result or item/completed) that can be superseded by a later
	// item/delta text_delta event for the same turn.  This prevents spurious
	// "[...]" entries when multiple event types carry the same assistant text:
	//   Claude live:   item/delta (set) -> item/completed (no text) -> turn/result (skip)
	//   Claude history: item/completed (set, no delta follows) -> correct
	//   Codex:         turn/result (set, no delta follows) -> correct
	//   Copilot:       turn/result (set) -> item/completed (replace) -> item/delta (replace)
	bool lastEntryFromNonDelta = false;

	foreach_reverse (envelope; envelopes)
	{
		auto event = extractEventFromEnvelope(envelope);
		if (event.length == 0)
			continue;

		import std.algorithm : canFind;

		string entry;

		if (event.canFind(`"user_message"`))
		{
			auto text = extractMessageText(event);
			if (text.length > 0)
			{
				seenAssistantText = false;
				turnCollapsed = false;
				lastEntryFromNonDelta = false;
				entry = "USER: " ~ abbreviateText(text, truncThreshold);
			}
			else
				continue;
		}
		else if (event.canFind(`"turn/result"`))
		{
			// turn/result echoes the full assistant response. Used as a fallback source
			// when no item/delta text_delta events are present (e.g. Codex). For Claude
			// and Copilot, item/delta text_delta arrives later in the reverse scan and
			// replaces this entry, so we mark it as supersedable (lastEntryFromNonDelta).
			if (seenAssistantText)
				continue;
			auto text = extractMessageText(event);
			if (text.length == 0)
				continue;
			seenAssistantText = true;
			lastEntryFromNonDelta = true;
			entry = "A: " ~ abbreviateText(text, truncThreshold);
		}
		else if (event.canFind(`"item/completed"`) ||
		         (event.canFind(`"item/delta"`) && event.canFind(`"text_delta"`)))
		{
			auto text = extractMessageText(event);
			if (text.length == 0)
				continue;

			if (!seenAssistantText)
			{
				seenAssistantText = true;
				lastEntryFromNonDelta = event.canFind(`"item/completed"`);
				entry = "A: " ~ abbreviateText(text, truncThreshold);
			}
			else if (lastEntryFromNonDelta && !turnCollapsed)
			{
				entries[$ - 1] = "A: " ~ abbreviateText(text, truncThreshold);
				lastEntryFromNonDelta = event.canFind(`"item/completed"`);
				continue;
			}
			else
			{
				if (!turnCollapsed)
				{
					turnCollapsed = true;
					entry = "[...]";
				}
				else
					continue;
			}
		}
		else if (event.canFind(`"tool_use"`) || event.canFind(`"tool_result"`))
		{
			if (seenAssistantText)
			{
				if (!turnCollapsed)
				{
					turnCollapsed = true;
					lastEntryFromNonDelta = false;
					entry = "[...]";
				}
				else
					continue;
			}
			else
				continue;
		}
		else
			continue;

		totalLen += entry.length;
		if (totalLen > maxLen)
			break;

		entries ~= entry;
	}

	import std.algorithm : reverse;
	entries.reverse();

	enum maxTurns = 4;
	int turnCount = 0;
	size_t sliceFrom = 0;
	foreach_reverse (i, ref e; entries)
	{
		if (e.length > 5 && e[0 .. 5] == "USER:")
		{
			turnCount++;
			if (turnCount <= maxTurns)
				sliceFrom = i;
		}
	}
	if (turnCount > maxTurns)
		entries = entries[sliceFrom .. $];

	import std.conv : to;
	import std.array : join;
	string header = "[Session: " ~ userMsgCount.to!string ~ " user messages, "
		~ toolUseCount.to!string ~ " tool uses]\n\n";

	return header ~ entries.join("\n\n");
}

unittest
{
	string envelope(string event)
	{
		return `{"sid":1,"timestamp":0,"event":` ~ event ~ `}`;
	}

	auto history = buildAbbreviatedHistoryFromStrings([
		envelope(`{"type":"item/started","item_type":"user_message","text":"hello from user"}`),
	]);

	assert(history == "[Session: 1 user messages, 0 tool uses]\n\nUSER: hello from user");
}

unittest
{
	string envelope(string event)
	{
		return `{"sid":1,"timestamp":0,"event":` ~ event ~ `}`;
	}

	auto history = buildAbbreviatedHistoryFromStrings([
		envelope(`{"type":"turn/result","result":"assistant reply"}`),
	]);

	assert(history == "[Session: 0 user messages, 0 tool uses]\n\nA: assistant reply");
}

unittest
{
	string envelope(string event)
	{
		return `{"sid":1,"timestamp":0,"event":` ~ event ~ `}`;
	}

	auto history = buildAbbreviatedHistoryFromStrings([
		envelope(`{"type":"item/started","item_type":"user_message","text":"Run the command"}`),
		envelope(`{"type":"item/started","item_type":"tool_use","text":"shell"}`),
		envelope(`{"type":"item/result","tool_result":{"ok":true}}`),
		envelope(`{"type":"turn/result","result":"Command finished."}`),
	]);

	assert(history == "[Session: 1 user messages, 1 tool uses]\n\nUSER: Run the command\n\n[...]\n\nA: Command finished.");
}

unittest
{
	import std.array : replicate;
	import std.algorithm : canFind;

	auto original = ("a" ~ "\n") ~ ("b" ~ " ").replicate(200);
	auto abbreviated = abbreviateText(original, 256);

	assert(abbreviated.canFind(" [...] "));
	assert(abbreviated.length == 257);
	assert(!abbreviated.canFind("\n"));
}
