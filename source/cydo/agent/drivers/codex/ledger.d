/// Decode rollout records for legacy history replay.
module cydo.agent.drivers.codex.ledger;

import std.conv : to;
import ae.utils.serialization.json : JsonParser;
import ae.utils.serialization.serialization : isProtocolArray, isProtocolBoolean,
	isProtocolField, isProtocolMap, isProtocolNull, isProtocolNumeric,
	isProtocolString;

import cydo.agent.drivers.codex.rollout;
import cydo.agent.drivers.codex.user_message;

/// Preserve repeated object keys so field lookups can reject ambiguity.
package enum RolloutValueType
{
	none,
	null_,
	boolean,
	numeric,
	string_,
	array,
	object,
}

package struct RolloutValue
{
	RolloutValueType type;
	string text;
	RolloutValue[] values;
	string[] keys;
}

private struct RolloutValueSink
{
	RolloutValue* output;

	void handle(V)(V value)
	{
		static if (isProtocolNull!V)
			output.type = RolloutValueType.null_;
		else static if (isProtocolBoolean!V)
			output.type = RolloutValueType.boolean;
		else static if (isProtocolNumeric!V)
		{
			output.type = RolloutValueType.numeric;
			output.text = value.text.to!string;
		}
		else static if (isProtocolString!V)
		{
			output.type = RolloutValueType.string_;
			output.text = value.text.to!string;
		}
		else static if (isProtocolArray!V)
		{
			output.type = RolloutValueType.array;
			value.reader(RolloutArraySink(&output.values));
		}
		else static if (isProtocolMap!V)
		{
			output.type = RolloutValueType.object;
			value.reader(RolloutMapSink(output));
		}
		else
			static assert(false, "Unsupported rollout JSON value");
	}
}

private struct RolloutArraySink
{
	RolloutValue[]* output;

	void handle(V)(V value)
	{
		RolloutValue item;
		RolloutValueSink(&item).handle(value);
		*output ~= item;
	}
}

private struct RolloutMapSink
{
	RolloutValue* output;

	void handle(V)(V field)
	{
		static if (isProtocolField!V)
		{
			string key;
			field.nameReader(RolloutKeySink(&key));
			RolloutValue value;
			value.type = RolloutValueType.none;
			field.valueReader(RolloutValueSink(&value));
			output.keys ~= key;
			output.values ~= value;
		}
		else
			static assert(false, "Rollout JSON object expected a field");
	}
}

private struct RolloutKeySink
{
	string* output;

	void handle(V)(V value)
	{
		static if (isProtocolString!V)
			*output = value.text.to!string;
		else
			static assert(false, "Rollout JSON object key must be a string");
	}
}

private bool parseRolloutValue(string line, out RolloutValue result)
{
	try
	{
		auto parser = JsonParser!(immutable char)(cast(immutable char[]) line, 0);
		parser.read(RolloutValueSink(&result));
		parser.skipWhitespace();
		return parser.eof;
	}
	catch (Exception)
		return false;
}

private const(RolloutValue)* rolloutField(const ref RolloutValue object,
	string key, out size_t count)
{
	const(RolloutValue)* result;
	if (object.type != RolloutValueType.object)
		return null;
	foreach (i, ref value; object.values)
	{
		if (object.keys[i] != key)
			continue;
		count++;
		if (count == 1)
			result = &value;
	}
	return result;
}

private bool rolloutString(const(RolloutValue)* value, out string text)
{
	if (value is null || value.type != RolloutValueType.string_)
		return false;
	text = value.text;
	return true;
}

package struct RolloutLineProbe
{
	bool isSessionMeta;
	bool isTurnContext;
	bool isResponseItem;
	bool isEventMsg;
	bool isTaskStarted;
	bool isThreadRolledBack;
	uint rollbackNumTurns;
	ForkableMessageRole messageRole = ForkableMessageRole.none;

	@property bool isUserMessage() const
	{
		return messageRole == ForkableMessageRole.user;
	}

	@property bool isAssistantMessage() const
	{
		return messageRole == ForkableMessageRole.assistant;
	}

	@property bool isForkableMessage() const
	{
		return isUserMessage || isAssistantMessage;
	}
}

package struct RolloutLineEvidence
{
	int lineNumber;
	bool parsed;
	RolloutLineProbe probe;
	string payloadType;
	CodexUserItem user;

	bool eventTurnIdValid;
	string eventTurnId;
	bool eventMessageValid;
	string eventMessage;
}

private bool optionalField(const ref RolloutValue item, string key, RolloutValueType type)
{
	size_t count;
	auto field = rolloutField(item, key, count);
	return count == 0 || (count == 1 && (field.type == RolloutValueType.null_ || field.type == type));
}

private bool optionalUnitEnum(const ref RolloutValue item, string key, const(string)[] allowed)
{
	import std.algorithm : canFind;

	size_t count;
	auto field = rolloutField(item, key, count);
	if (count == 0 || (count == 1 && field.type == RolloutValueType.null_))
		return true;
	if (count != 1)
		return false;
	if (field.type == RolloutValueType.string_)
		return allowed.canFind(field.text);
	// Serde also accepts an externally tagged unit variant as a one-key map.
	if (field.type != RolloutValueType.object || field.keys.length != 1)
		return false;
	auto tag = &field.values[0];
	return allowed.canFind(field.keys[0]) && (tag.type == RolloutValueType.null_
		|| (tag.type == RolloutValueType.object && tag.keys.length == 0));
}

private void decodeContent(ref RolloutLineEvidence evidence,
	const(RolloutValue)* value)
{
	if (value is null || value.type != RolloutValueType.array)
		return;
	alias Type = CodexContentItem.Type;
	CodexContentItem[] content;
	bool valid = true;
	foreach (ref item; value.values)
	{
		size_t count;
		string type;
		if (!rolloutString(rolloutField(item, "type", count), type) || count != 1)
		{
			valid = false;
			continue;
		}
		string text;
		switch (type)
		{
			case "output_text":
				if (!optionalField(item, "annotations", RolloutValueType.array)
					|| !optionalField(item, "logprobs", RolloutValueType.array))
					break;
				goto case "input_text";
			case "input_text":
				if (rolloutString(rolloutField(item, "text", count), text) && count == 1)
				{
					content ~= CodexContentItem(
						type == "input_text" ? Type.inputText : Type.outputText, text);
					continue;
				}
				break;
			case "input_image":
			case "input_audio":
				auto image = type == "input_image";
				if (image && !optionalUnitEnum(item, "detail",
					["auto", "low", "high", "original"]))
					break;
				// Untagged references try Inline first. Each variant ignores the
				// other variant's field, even when its value is malformed.
				auto url = rolloutField(item, image ? "image_url" : "audio_url", count);
				if (count == 1 && rolloutString(url, text))
				{
					content ~= CodexContentItem(image ? Type.inputImage : Type.inputAudio, null, text);
					continue;
				}
				auto fileId = rolloutField(item, "file_id", count);
				if (count == 1 && rolloutString(fileId, text))
				{
					content ~= CodexContentItem(image ? Type.inputImage : Type.inputAudio);
					continue;
				}
				break;
			default:
				break;
		}
		valid = false;
	}
	evidence.user = parseCodexUserItem(content);
	if (!valid)
		evidence.user = CodexUserItem(CodexUserItemKind.unrecognized, null, false,
			evidence.user.classification);
}

private bool validUserMessageFields(const ref RolloutValue payload)
{
	if (!optionalField(payload, "encrypted_content", RolloutValueType.string_)
		|| !optionalField(payload, "status", RolloutValueType.string_)
		|| !optionalField(payload, "id", RolloutValueType.string_)
		|| !optionalUnitEnum(payload, "phase",
			["commentary", "partial_answer", "final_answer"]))
		return false;

	size_t count;
	auto metadata = rolloutField(payload, "internal_chat_message_metadata_passthrough", count);
	if (count == 0 || (count == 1 && metadata.type == RolloutValueType.null_))
		return true;
	return count == 1 && validMessageMetadata(*metadata);
}

private bool validMessageMetadata(const ref RolloutValue metadata)
{
	if (metadata.type == RolloutValueType.array)
	{
		// Serde's positional struct representation has five input fields.
		auto fields = metadata.values;
		return fields.length <= 5
			&& (fields.length < 1 || fields[0].type == RolloutValueType.null_
				|| fields[0].type == RolloutValueType.string_)
			&& (fields.length < 2 || validCreateTime(fields[1]));
	}
	if (metadata.type != RolloutValueType.object)
		return false;

	// DefaultOnError tolerates any value for these deserialized fields.
	size_t count;
	foreach (key; ["content_token_count", "content_item_kinds", "content_item_metadata"])
	{
		rolloutField(metadata, key, count);
		if (count > 1)
			return false;
	}
	// Host-only metadata fields are marked skip_deserializing.
	auto createTime = rolloutField(metadata, "create_time", count);
	return optionalField(metadata, "turn_id", RolloutValueType.string_)
		&& (count == 0 || (count == 1 && validCreateTime(*createTime)));
}

private bool validCreateTime(const ref RolloutValue field)
{
	import std.regex : ctRegex, matchFirst;

	if (field.type == RolloutValueType.null_ || field.type == RolloutValueType.numeric)
		return true;
	// serde_json's arbitrary-precision Number also decodes this tagged form.
	return field.type == RolloutValueType.object && field.keys.length == 1
		&& field.keys[0] == "$serde_json::private::Number"
		&& field.values[0].type == RolloutValueType.string_
		&& !field.values[0].text.matchFirst(
			ctRegex!`^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$`).empty;
}

private void decodeResponseItem(ref RolloutLineEvidence evidence,
	const ref RolloutValue payload)
{
	size_t typeCount;
	auto payloadType = rolloutField(payload, "type", typeCount);
	if (typeCount != 1 || !rolloutString(payloadType, evidence.payloadType))
		return;

	size_t roleCount;
	auto role = rolloutField(payload, "role", roleCount);
	string messageRole;
	rolloutString(role, messageRole);
	if (evidence.payloadType != "message")
		return;

	if (messageRole == "user")
		evidence.probe.messageRole = ForkableMessageRole.user;
	else if (messageRole == "assistant")
		evidence.probe.messageRole = ForkableMessageRole.assistant;

	if (!evidence.probe.isUserMessage || !validUserMessageFields(payload))
		return;
	size_t contentCount;
	auto content = rolloutField(payload, "content", contentCount);
	if (contentCount == 1)
		decodeContent(evidence, content);
}

private void decodeEventMessage(ref RolloutLineEvidence evidence,
	const ref RolloutValue payload)
{
	size_t typeCount;
	auto type = rolloutField(payload, "type", typeCount);
	if (typeCount != 1 || !rolloutString(type, evidence.payloadType))
		return;
	size_t turnIdCount;
	auto turnId = rolloutField(payload, "turn_id", turnIdCount);
	if (turnIdCount == 1 && rolloutString(turnId, evidence.eventTurnId))
		evidence.eventTurnIdValid = evidence.eventTurnId.length > 0;

	if (evidence.payloadType == "task_started")
	{
		evidence.probe.isTaskStarted = true;
		return;
	}
	if (evidence.payloadType == "thread_rolled_back")
	{
		evidence.probe.isThreadRolledBack = true;
		size_t count;
		auto numTurns = rolloutField(payload, "num_turns", count);
		if (count == 1 && numTurns !is null && numTurns.type == RolloutValueType.numeric)
		{
			try evidence.probe.rollbackNumTurns = to!uint(numTurns.text);
			catch (Exception) {}
		}
		return;
	}
	if (evidence.payloadType == "user_message")
	{
		size_t messageCount;
		auto message = rolloutField(payload, "message", messageCount);
		evidence.eventMessageValid = messageCount == 1
			&& rolloutString(message, evidence.eventMessage);
	}
}

package RolloutLineEvidence parseRolloutLineEvidence(string line, int lineNumber)
{
	RolloutLineEvidence result;
	result.lineNumber = lineNumber;
	RolloutValue raw;
	result.parsed = parseRolloutValue(line, raw);
	if (!result.parsed || raw.type != RolloutValueType.object)
		return result;

	size_t typeCount;
	auto type = rolloutField(raw, "type", typeCount);
	string topType;
	if (typeCount != 1 || !rolloutString(type, topType))
		return result;
	result.probe.isSessionMeta = topType == "session_meta";
	result.probe.isTurnContext = topType == "turn_context";
	result.probe.isResponseItem = topType == "response_item";
	result.probe.isEventMsg = topType == "event_msg";

	size_t payloadCount;
	auto payload = rolloutField(raw, "payload", payloadCount);
	if (payloadCount != 1 || payload is null || payload.type != RolloutValueType.object)
		return result;
	if (result.probe.isResponseItem)
		decodeResponseItem(result, *payload);
	else if (result.probe.isEventMsg)
		decodeEventMessage(result, *payload);
	return result;
}

/// Scan rollout JSONL in physical line order, preserving the source line numbers.
package RolloutLineEvidence[] scanRollout(string content)
{
	import std.string : lineSplitter;

	RolloutLineEvidence[] lines;
	int lineNumber;
	foreach (line; content.lineSplitter)
		lines ~= parseRolloutLineEvidence(line, ++lineNumber);
	return lines;
}

/// Parse one rollout JSONL line and return only the fields relevant to
/// history/forkable-line classification.
package RolloutLineProbe parseRolloutLineProbe(string line)
{
	return parseRolloutLineEvidence(line, 0).probe;
}
