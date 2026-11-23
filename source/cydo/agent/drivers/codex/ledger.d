/// Decode rollout records for legacy history replay.
module cydo.agent.drivers.codex.ledger;

import std.conv : to;
import ae.utils.serialization.json : JsonParser;
import ae.utils.serialization.serialization : isProtocolArray, isProtocolBoolean,
	isProtocolField, isProtocolMap, isProtocolNull, isProtocolNumeric,
	isProtocolString;

import cydo.agent.drivers.codex.rollout;

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
	string inputText;
	CodexUserMessageLineClassification userClassification;

	bool eventTurnIdValid;
	string eventTurnId;
	bool eventMessageValid;
	string eventMessage;
}

private void decodeContent(ref RolloutLineEvidence evidence,
	const(RolloutValue)* value)
{
	if (value is null || value.type != RolloutValueType.array)
		return;
	bool classificationKnown = true;
	foreach (ref item; value.values)
	{
		size_t typeCount;
		auto type = rolloutField(item, "type", typeCount);
		string contentType;
		if (typeCount != 1 || !rolloutString(type, contentType))
		{
			classificationKnown = false;
			continue;
		}
		if (contentType != "input_text" && contentType != "text")
			continue;
		size_t textCount;
		auto text = rolloutField(item, "text", textCount);
		string textValue;
		if (textCount == 1 && rolloutString(text, textValue))
			evidence.inputText ~= textValue;
		else
			classificationKnown = false;
	}
	if (classificationKnown && isCodexTurnAbortedUserText(evidence.inputText))
		evidence.userClassification = CodexUserMessageLineClassification.turnAborted;
	else if (classificationKnown && isCodexContextOnlyUserText(evidence.inputText))
		evidence.userClassification = CodexUserMessageLineClassification.contextOnly;
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

	if (!evidence.probe.isUserMessage)
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
