/// Reconstructs useful Codex DISPLAY history from rollout JSONL. This
/// projection is deliberately tolerant and must not authorize native
/// ROLLBACK; ledger.d supplies the lossless exact-shape evidence for that.
module cydo.agent.drivers.codex.rollout;

import std.conv : to;
import std.algorithm : canFind;
import std.json : JSONType, JSONValue, parseJSON;
import std.logger : tracef;
import std.typecons : Nullable;

import ae.utils.json : JSONFragment, JSONOptional, JSONPartial, jsonParse, toJson;
import ae.utils.serialization.json : JsonParser;
import ae.utils.serialization.serialization : isProtocolArray, isProtocolBoolean,
	isProtocolField, isProtocolMap, isProtocolNull, isProtocolNumeric,
	isProtocolString;

import cydo.agent.contract : PersistedHistoryBoundary, PersistedHistoryBoundaryKind;
import cydo.protocol : ContentBlock, decomposeToolName, makeUnrecognizedEvent;
public import cydo.agent.drivers.codex.ledger;

package enum ForkableMessageRole
{
	none,
	user,
	assistant,
}

package enum CodexUserMessageLineClassification
{
	normal,
	contextOnly,
	turnAborted,
}

package enum RolloutTopLevelKind
{
	unknown,
	sessionMeta,
	worldState,
	turnContext,
	responseItem,
	eventMsg,
	compacted,
}


/// Parse `num_turns` from a ThreadRolledBack event_msg JSONL line.
/// The payload is `{"type":"thread_rolled_back","num_turns":N}`.
/// Returns 0 if parsing fails.
uint parseRollbackNumTurns(string line)
{
	auto probe = parseRolloutLineProbe(line);
	return probe.isThreadRolledBack ? probe.rollbackNumTurns : 0;
}

/// Apply a rollback to persisted history boundaries: remove the last N user-turn groups.
PersistedHistoryBoundary[] applyRollbackToIdsWithInfo(PersistedHistoryBoundary[] ids, uint numTurns)
{
	if (numTurns == 0 || ids.length == 0)
		return ids;

	// Find the position of the Nth-from-last user message
	uint usersSeen = 0;
	for (size_t i = ids.length; i > 0; i--)
	{
		if (ids[i - 1].kind == PersistedHistoryBoundaryKind.user)
		{
			usersSeen++;
			if (usersSeen >= numTurns)
				return ids[0 .. i - 1];
		}
	}
	// Fewer user messages than numTurns — remove everything
	return [];
}

package PersistedHistoryBoundary[] extractPersistedHistoryBoundariesImpl(string content, int lineOffset = 0)
{
	PersistedHistoryBoundary[] ids;
	auto scan = scanRollout(content, lineOffset);
	// Codex prepends system context as a role=user response_item before the
	// first task_started event. Skip role=user lines until task_started is seen
	// so the system context is not treated as a forkable user message.
	bool seenTaskStarted = lineOffset > 0;
	foreach (ref line; scan.lines)
	{
		if (!seenTaskStarted && line.probe.isTaskStarted)
		{
			seenTaskStarted = true;
			continue;
		}
		if (line.probe.isThreadRolledBack)
		{
			if (line.probe.rollbackNumTurns > 0)
				ids = applyRollbackToIdsWithInfo(ids, line.probe.rollbackNumTurns);
			continue;
		}
		if (!line.probe.isForkableMessage)
			continue;
		if (line.probe.isUserMessage && !seenTaskStarted)
			continue;
		if (line.probe.isUserMessage)
		{
			if (isCodexContextOnlyUserMessage(line.userClassification))
				continue;
		}
		ids ~= PersistedHistoryBoundary("line:" ~ to!string(line.lineNumber),
			line.probe.isUserMessage ? PersistedHistoryBoundaryKind.user
				: PersistedHistoryBoundaryKind.agent_turn, null);
	}
	return ids;
}

private bool interruptedToolCallHasKey(ref JSONValue value, string key)
{
	return value.type == JSONType.object && key in value.object;
}

private string interruptedToolCallStringAt(ref JSONValue value, string key)
{
	if (!interruptedToolCallHasKey(value, key))
		return null;
	auto field = value.object[key];
	return field.type == JSONType.string ? field.str : null;
}

private string interruptedToolCallTurnId(ref JSONValue payload)
{
	if (!interruptedToolCallHasKey(payload,
		"internal_chat_message_metadata_passthrough"))
		return null;
	auto metadata = payload.object["internal_chat_message_metadata_passthrough"];
	return interruptedToolCallStringAt(metadata, "turn_id");
}

/// Repair a Codex rollout after CyDo interrupts a successful continuation MCP
/// call. Returns null when the expected function-call/output pair is absent.
package string[] repairInterruptedToolCallImpl(string[] lines, string toolName,
	string resultText)
{
	string splitName;
	string toolServer;
	string toolSource;
	decomposeToolName(toolName, splitName, toolServer, toolSource);
	auto splitNamespace = toolSource ~ "__" ~ toolServer;

	string callId;
	string turnId;
	foreach (line; lines)
	{
		JSONValue record;
		try
			record = parseJSON(line);
		catch (Exception)
			continue;
		if (interruptedToolCallStringAt(record, "type") != "response_item"
			|| !interruptedToolCallHasKey(record, "payload"))
			continue;

		auto payload = record.object["payload"];
		if (interruptedToolCallStringAt(payload, "type") != "function_call")
			continue;
		auto name = interruptedToolCallStringAt(payload, "name");
		if (name == toolName
			|| (name == splitName
				&& interruptedToolCallStringAt(payload, "namespace") == splitNamespace))
		{
			callId = interruptedToolCallStringAt(payload, "call_id");
			turnId = interruptedToolCallTurnId(payload);
		}
	}
	if (callId.length == 0)
		return null;

	bool rewroteOutput;
	size_t outputIndex = size_t.max;
	string[] repaired;
	foreach (lineIndex, line; lines)
	{
		JSONValue record;
		try
			record = parseJSON(line);
		catch (Exception)
		{
			repaired ~= line;
			continue;
		}
		if (!interruptedToolCallHasKey(record, "payload"))
		{
			repaired ~= line;
			continue;
		}

		auto type = interruptedToolCallStringAt(record, "type");
		auto payload = record.object["payload"];
		if (!rewroteOutput && type == "response_item"
			&& interruptedToolCallStringAt(payload, "type") == "function_call_output"
			&& interruptedToolCallStringAt(payload, "call_id") == callId)
		{
			payload.object["output"] = JSONValue(resultText);
			record.object["payload"] = payload;
			repaired ~= record.toString();
			rewroteOutput = true;
			outputIndex = lineIndex;
			continue;
		}

		if (turnId.length > 0 && lineIndex > outputIndex
			&& type == "response_item"
			&& interruptedToolCallStringAt(payload, "type") == "message"
			&& (interruptedToolCallStringAt(payload, "role") == "developer"
				|| interruptedToolCallStringAt(payload, "role") == "user")
			&& interruptedToolCallTurnId(payload) == turnId
			&& interruptedToolCallHasKey(payload, "content")
			&& payload.object["content"].type == JSONType.array
			&& payload.object["content"].array.length == 1)
		{
			auto firstBlock = payload.object["content"].array[0];
			if (interruptedToolCallStringAt(firstBlock, "type") == "input_text"
				&& isCodexTurnAbortedUserText(
					interruptedToolCallStringAt(firstBlock, "text")))
				continue;
		}

		if (turnId.length > 0 && lineIndex > outputIndex && type == "event_msg"
			&& interruptedToolCallStringAt(payload, "type") == "turn_aborted"
			&& interruptedToolCallStringAt(payload, "turn_id") == turnId
			&& interruptedToolCallStringAt(payload, "reason") == "interrupted")
			continue;

		repaired ~= line;
	}
	return rewroteOutput ? repaired : null;
}

unittest
{
	auto call = `{"type":"response_item","payload":{"type":"function_call","name":"SwitchMode","namespace":"mcp__cydo","arguments":"{\"continuation\":\"plan\"}","call_id":"call_switch","internal_chat_message_metadata_passthrough":{"turn_id":"turn_switch"}}}`;
	auto output = `{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_switch","output":"aborted by user after 0.1s","internal_chat_message_metadata_passthrough":{"turn_id":"turn_switch"}}}`;
	auto tokenCount = `{"type":"event_msg","payload":{"type":"token_count","info":{}}}`;
	auto developerMarker = `{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<turn_aborted>\nThe previous turn was interrupted on purpose.\n</turn_aborted>"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn_switch"}}}`;
	auto abortedEvent = `{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn_switch","reason":"interrupted"}}`;

	auto repaired = repairInterruptedToolCallImpl(
		[call, output, tokenCount, developerMarker, abortedEvent],
		"mcp__cydo__SwitchMode", "RESULT");
	assert(repaired !is null && repaired.length == 3);
	assert(parseJSON(repaired[1])["payload"]["output"].str == "RESULT");
	assert(repaired[2] == tokenCount);

	auto flattened = repairInterruptedToolCallImpl([
		`{"type":"response_item","payload":{"type":"function_call","name":"mcp__cydo__SwitchMode","call_id":"flat-call","internal_chat_message_metadata_passthrough":{"turn_id":"flat-turn"}}}`,
		`{"type":"response_item","payload":{"type":"function_call_output","call_id":"flat-call","output":"aborted by user after 0.2s"}}`,
	], "mcp__cydo__SwitchMode", "FLAT RESULT");
	assert(flattened !is null
		&& parseJSON(flattened[1])["payload"]["output"].str == "FLAT RESULT");

	auto handoffCall = `{"type":"response_item","payload":{"type":"function_call","name":"Handoff","namespace":"mcp__cydo","call_id":"handoff-call","internal_chat_message_metadata_passthrough":{"turn_id":"handoff-turn"}}}`;
	auto handoffOutput = `{"type":"response_item","payload":{"type":"function_call_output","call_id":"handoff-call","output":"aborted by user after 0.1s"}}`;
	auto handoffMarker = `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<turn_aborted>\nThe user interrupted the previous turn on purpose.\n</turn_aborted>"}],"internal_chat_message_metadata_passthrough":{"turn_id":"handoff-turn"}}}`;
	auto handoffEvent = `{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"handoff-turn","reason":"interrupted"}}`;
	auto handoff = repairInterruptedToolCallImpl(
		[handoffCall, handoffOutput, handoffMarker, handoffEvent],
		"mcp__cydo__Handoff", "HANDOFF RESULT");
	assert(handoff !is null && handoff.length == 2
		&& parseJSON(handoff[1])["payload"]["output"].str == "HANDOFF RESULT");

	void assertContains(string[] records, string expected)
	{
		foreach (record; records)
			if (record == expected)
				return;
		assert(false, "Expected retained record: " ~ expected);
	}

	auto preOutputMarker = `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<turn_aborted>\ninterrupted\n</turn_aborted>"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn_switch"}}}`;
	auto openingOnly = `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<turn_aborted>\ninterrupted"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn_switch"}}}`;
	auto trailingText = `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<turn_aborted>\ninterrupted\n</turn_aborted>\nordinary"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn_switch"}}}`;
	auto wrongContentType = `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"text","text":"<turn_aborted>\ninterrupted\n</turn_aborted>"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn_switch"}}}`;
	auto multipleContent = `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<turn_aborted>\ninterrupted\n</turn_aborted>"},{"type":"input_text","text":"extra"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn_switch"}}}`;
	auto unacceptedRole = `{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"input_text","text":"<turn_aborted>\ninterrupted\n</turn_aborted>"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn_switch"}}}`;
	auto differentTurn = `{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<turn_aborted>\ninterrupted\n</turn_aborted>"}],"internal_chat_message_metadata_passthrough":{"turn_id":"other-turn"}}}`;
	auto lookalikes = [openingOnly, trailingText, wrongContentType, multipleContent,
		unacceptedRole, differentTurn];
	auto retained = repairInterruptedToolCallImpl(
		[call, preOutputMarker, output] ~ lookalikes,
		"mcp__cydo__SwitchMode", "RESULT");
	assert(retained !is null && retained.length == 3 + lookalikes.length);
	assert(retained[1] == preOutputMarker);
	foreach (lookalike; lookalikes)
		assertContains(retained, lookalike);

	auto noMarkerEvent = repairInterruptedToolCallImpl([call, output, abortedEvent],
		"mcp__cydo__SwitchMode", "RESULT");
	assert(noMarkerEvent !is null && noMarkerEvent.length == 2);
	auto preOutputEvent = `{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn_switch","reason":"interrupted"}}`;
	auto otherTurnEvent = `{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"other-turn","reason":"interrupted"}}`;
	auto otherReasonEvent = `{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn_switch","reason":"shutdown"}}`;
	auto retainedEvents = repairInterruptedToolCallImpl(
		[call, preOutputEvent, output, otherTurnEvent, otherReasonEvent],
		"mcp__cydo__SwitchMode", "RESULT");
	assert(retainedEvents !is null && retainedEvents.length == 5);
	assertContains(retainedEvents, preOutputEvent);
	assertContains(retainedEvents, otherTurnEvent);
	assertContains(retainedEvents, otherReasonEvent);

	auto malformed = repairInterruptedToolCallImpl([call, "not json", output],
		"mcp__cydo__SwitchMode", "RESULT");
	assert(malformed !is null && malformed.length == 3 && malformed[1] == "not json");
	assert(repairInterruptedToolCallImpl([call, output],
		"mcp__cydo__Handoff", "RESULT") is null);
	assert(repairInterruptedToolCallImpl([`{"type":"event_msg","payload":{"type":"token_count"}}`],
		"mcp__cydo__SwitchMode", "RESULT") is null);
	assert(repairInterruptedToolCallImpl([call],
		"mcp__cydo__SwitchMode", "RESULT") is null);
}

package bool isCodexContextOnlyUserText(string text)
{
	import std.string : startsWith, stripLeft;

	auto trimmed = text.stripLeft;
	return trimmed.startsWith("<permissions instructions>")
		|| trimmed.startsWith("<environment_context>")
		|| trimmed.startsWith("[SYSTEM:")
		|| isCodexTurnAbortedUserText(trimmed);
}

package bool isCodexTurnAbortedUserText(string text)
{
	import std.ascii : toLower;
	import std.string : stripLeft, stripRight;

	enum openingMarker = "<turn_aborted>";
	enum closingMarker = "</turn_aborted>";

	auto leftTrimmed = text.stripLeft;
	if (leftTrimmed.length < openingMarker.length)
		return false;
	foreach (i, c; openingMarker)
		if (leftTrimmed[i].toLower != c)
			return false;

	auto trimmed = leftTrimmed.stripRight;
	if (trimmed.length < closingMarker.length)
		return false;
	foreach (i, c; closingMarker)
		if (trimmed[trimmed.length - closingMarker.length + i].toLower != c)
			return false;
	return true;
}

package bool extractCodexUserMessageText(string line, out string text)
{
	auto evidence = parseRolloutLineEvidence(line, 0);
	if (!evidence.probe.isUserMessage || !evidence.contentClassificationKnown)
		return false;
	text = evidence.inputText;
	return true;
}

package CodexUserMessageLineClassification classifyCodexUserMessageLine(string line)
{
	auto evidence = parseRolloutLineEvidence(line, 0);
	return evidence.userClassification;
}

package bool isCodexContextOnlyUserMessage(
	CodexUserMessageLineClassification classification)
{
	return classification != CodexUserMessageLineClassification.normal;
}

package bool isCodexContextOnlyUserMessageLine(string line)
{
	return isCodexContextOnlyUserMessage(classifyCodexUserMessageLine(line));
}

/// True when a parsed role=user response item represents a Codex rollback turn.
/// `[SYSTEM:]` retains its existing replay semantics; the Codex-generated
/// abort fragment does not form a separate rollback turn.
package bool isCodexRollbackEligibleUserMessage(
	CodexUserMessageLineClassification classification)
{
	return classification != CodexUserMessageLineClassification.turnAborted;
}

/// Count active persisted message records from `anchor` onward for JSONL undo.
/// Rollback-dead records are excluded by the active-boundary extraction.
int countActiveFallbackRecordsFromBoundary(string content, string anchor)
{
	auto boundaries = extractPersistedHistoryBoundariesImpl(content);
	foreach (i, ref boundary; boundaries)
		if (boundary.anchor == anchor)
			return cast(int)(boundaries.length - i);
	return -1;
}

/// The user-facing assistant boundary is the response item, but a JSONL
/// fallback cuts at whichever projection comes first so it removes its native
/// agent event as well.
string resolveCodexFallbackUndoAnchor(string content,
	PersistedHistoryBoundaryKind kind, string anchor)
{
	if (kind != PersistedHistoryBoundaryKind.agent_turn)
		return anchor;
	import std.conv : to;
	import std.string : startsWith;
	if (!anchor.startsWith("line:"))
		return null;
	int targetLine;
	try targetLine = to!int(anchor[5 .. $]);
	catch (Exception) return null;
	auto scan = scanRollout(content);
	RolloutLineEvidence target;
	int targetIndex = -1;
	foreach (i, ref line; scan.lines)
		if (line.lineNumber == targetLine)
		{
			target = line;
			targetIndex = cast(int)i;
			break;
		}
	if (targetIndex < 0 || !target.probe.isAssistantMessage || !target.contentKnown
		|| target.contentText.length == 0)
		return null;
	NativeRolloutSegment* segment;
	foreach (ref candidate; scan.nativeSegments)
		if (candidate.start <= cast(size_t)targetIndex
			&& cast(size_t)targetIndex < candidate.end)
		{
			if (segment !is null)
				return null;
			segment = &candidate;
		}
	if (segment is null)
		return null;
	int matchedLine;
	foreach (i; segment.start .. segment.end)
	{
		auto line = scan.lines[i];
		if (isExactNativeAgentEvent(line) && line.eventMessage == target.contentText)
		{
			if (matchedLine > 0)
				return null;
			matchedLine = line.lineNumber;
		}
	}
	return matchedLine > 0
		? "line:" ~ to!string(targetLine < matchedLine ? targetLine : matchedLine)
		: null;
}

unittest
{
	string submitted(string turnId, string answer, bool assistantFirst = false,
		string telemetry = null)
	{
		auto started = `{"type":"event_msg","payload":{"type":"task_started","turn_id":"`
			~ turnId ~ `","started_at":1,"model_context_window":1,"collaboration_mode_kind":"default"}}`;
		auto user = `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"prompt"}],"internal_chat_message_metadata_passthrough":{"turn_id":"`
			~ turnId ~ `"}}}`;
		auto userEvent = `{"type":"event_msg","payload":{"type":"user_message","client_id":"client-`
			~ turnId ~ `","message":"prompt","images":[],"local_images":[],"text_elements":[]}}`;
		auto agent = `{"type":"event_msg","payload":{"type":"agent_message","message":"`
			~ answer ~ `","phase":null,"memory_citation":null}}`;
		auto assistant = `{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"`
			~ answer ~ `"}],"internal_chat_message_metadata_passthrough":{"turn_id":"`
			~ turnId ~ `"},"id":"assistant-` ~ turnId ~ `"}}`;
		auto complete = `{"type":"event_msg","payload":{"type":"task_complete","turn_id":"`
			~ turnId ~ `","last_agent_message":"` ~ answer
			~ `","completed_at":1,"duration_ms":1,"time_to_first_token_ms":1}}`;
		string[] records = [started, user, userEvent];
		if (assistantFirst) records ~= assistant; else records ~= agent;
		if (telemetry !is null) records ~= telemetry;
		if (assistantFirst) records ~= agent; else records ~= assistant;
		records ~= complete;
		import std.array : join;
		return records.join("\n");
	}

	auto normal = submitted("normal", "answer");
	assert(resolveCodexFallbackUndoAnchor(normal,
		PersistedHistoryBoundaryKind.agent_turn, "line:5") == "line:4");
	assert(resolveCodexFallbackUndoAnchor(normal,
		PersistedHistoryBoundaryKind.user, "line:2") == "line:2");
	assert(resolveCodexFallbackUndoAnchor(normal,
		PersistedHistoryBoundaryKind.agent_turn, "line:1") is null);
	assert(resolveCodexFallbackUndoAnchor(normal,
		PersistedHistoryBoundaryKind.agent_turn, "line:99") is null);
	assert(resolveCodexFallbackUndoAnchor(normal,
		PersistedHistoryBoundaryKind.agent_turn, "not-a-line") is null);

	// Both observed response/event projections remain valid with their
	// pre-terminal token telemetry; the fallback anchor selects the earlier
	// projection so truncation removes both.
	auto telemetry = `{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":42,"reasoning_output_tokens":0,"total_tokens":62},"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":6494},"model_context_window":258400},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":null,"secondary":null,"credits":null,"individual_limit":null,"plan_type":null,"rate_limit_reached_type":null}}}`;
	foreach (assistantFirst; [false, true])
	{
		auto projected = submitted(assistantFirst ? "first" : "last", "telemetry",
			assistantFirst, telemetry);
		auto scan = scanRollout(projected);
		assert(scan.nativeSegments.length == 1);
		auto target = assistantFirst ? "line:4" : "line:6";
		auto native = assistantFirst ? "line:6" : "line:4";
		import std.algorithm : min;
		auto expected = min(target, native);
		assert(resolveCodexFallbackUndoAnchor(projected,
			PersistedHistoryBoundaryKind.agent_turn, target)
			== expected);
	}

	// A visible assistant record without a complete, corroborated lifecycle
	// cannot authorize deletion of a coincidental native event.
	auto uncorroborated = `{"type":"event_msg","payload":{"type":"agent_message","message":"answer","phase":null,"memory_citation":null}}\n`
		~ `{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"answer"}]}}`;
	assert(resolveCodexFallbackUndoAnchor(uncorroborated,
		PersistedHistoryBoundaryKind.agent_turn, "line:2") is null);

	// Matching twice in the selected lifecycle is ambiguous and fails closed.
	auto duplicate = submitted("duplicate", "answer");
	import std.string : replace;
	duplicate = duplicate.replace(`{"type":"response_item","payload":{"type":"message","role":"assistant"`,
		`{"type":"event_msg","payload":{"type":"agent_message","message":"answer","phase":null,"memory_citation":null}}\n{"type":"response_item","payload":{"type":"message","role":"assistant"`);
	assert(resolveCodexFallbackUndoAnchor(duplicate,
		PersistedHistoryBoundaryKind.agent_turn, "line:6") is null);

	// Equal assistant text in an earlier completed lifecycle does not make the
	// later response ambiguous: segment membership selects its own event.
	auto repeated = submitted("earlier", "same") ~ "\n" ~ submitted("later", "same");
	assert(resolveCodexFallbackUndoAnchor(repeated,
		PersistedHistoryBoundaryKind.agent_turn, "line:11") == "line:10");
}

/// Check if a JSONL line is a ThreadRolledBack event_msg.
bool isRollbackMarker(string line)
{
	return parseRolloutLineProbe(line).isThreadRolledBack;
}

/// Compute the set of 1-based line numbers that should be skipped when
/// replaying a Codex JSONL that contains ThreadRolledBack markers.
/// A rollback with num_turns=N removes the last N user-turn segments
/// (each segment = a user response_item and all following lines until
/// the next user response_item).
bool[int] computeRollbackSkipLines(string content)
{
	auto scan = scanRollout(content);
	bool hasRollback;
	foreach (ref line; scan.lines)
		if (line.probe.isThreadRolledBack)
			hasRollback = true;
	if (!hasRollback)
		return (bool[int]).init;

	struct TurnBoundary { int lineNum; }
	TurnBoundary[] userTurnStarts;
	struct RollbackInfo { int lineNum; uint numTurns; }
	RollbackInfo[] rollbacks;

	bool seenTaskStarted = false;
	foreach (ref line; scan.lines)
	{
		if (!seenTaskStarted && line.probe.isTaskStarted)
		{
			seenTaskStarted = true;
			continue;
		}
		if (line.probe.isThreadRolledBack)
		{
			rollbacks ~= RollbackInfo(line.lineNumber, line.probe.rollbackNumTurns);
			continue;
		}
		if (seenTaskStarted && line.probe.isUserMessage
			&& isCodexRollbackEligibleUserMessage(line.userClassification))
			userTurnStarts ~= TurnBoundary(line.lineNumber);
	}

	if (rollbacks.length == 0)
		return (bool[int]).init;

	bool[int] skipLines;
	size_t[] activeTurnIndices;
	size_t turnIdx = 0;

	foreach (ri, ref rb; rollbacks)
	{
		while (turnIdx < userTurnStarts.length && userTurnStarts[turnIdx].lineNum < rb.lineNum)
		{
			activeTurnIndices ~= turnIdx;
			turnIdx++;
		}
		if (rb.numTurns > 0)
		{
			auto toRemove = rb.numTurns > activeTurnIndices.length
				? activeTurnIndices.length : rb.numTurns;
			auto removedTurns = activeTurnIndices[$ - toRemove .. $];
			activeTurnIndices = activeTurnIndices[0 .. $ - toRemove];

			foreach (ri2, removedIdx; removedTurns)
			{
				auto startLine = userTurnStarts[removedIdx].lineNum;
				int endLine;
				if (ri2 + 1 < removedTurns.length)
					endLine = userTurnStarts[removedTurns[ri2 + 1]].lineNum;
				else
					endLine = rb.lineNum;
				for (int ln = startLine; ln < endLine; ln++)
					skipLines[ln] = true;
			}
		}
		skipLines[rb.lineNum] = true;
	}

	return skipLines;
}


unittest
{
	// Genuine message response_item lines are forkable.
	auto userProbe = parseRolloutLineProbe(
		`{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}`);
	assert(userProbe.isUserMessage);
	assert(userProbe.isForkableMessage);

	auto assistantProbe = parseRolloutLineProbe(
		`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}`);
	assert(assistantProbe.isAssistantMessage);
	assert(assistantProbe.isForkableMessage);

	// Internal/non-message response_item lines can contain nested "role":"user"
	// data, but must not be treated as forkable user turns.
	auto internalProbe = parseRolloutLineProbe(
		`{"type":"response_item","payload":{"type":"function_call_output","output":{"role":"user"}}}`);
	assert(!internalProbe.isForkableMessage);

	// Test parseRollbackNumTurns
	assert(parseRollbackNumTurns(`{"timestamp":"2025-01-01T00:00:00.000Z","type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":2}}`) == 2);
	assert(parseRollbackNumTurns(`{"timestamp":"2025-01-01T00:00:00.000Z","type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":0}}`) == 0);
	assert(parseRollbackNumTurns(`{"type":"event_msg","payload":{"type":"task_started"}}`) == 0);
	auto validRollbackMarker = classifyNativeRollbackMarker(
		`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":2}}`);
	assert(validRollbackMarker.status == NativeRollbackMarkerStatus.valid
		&& validRollbackMarker.numTurns == 2);
	auto malformedRollbackMarker = classifyNativeRollbackMarker(
		`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":"two"}}`);
	assert(malformedRollbackMarker.status == NativeRollbackMarkerStatus.malformed);
	assert(classifyNativeRollbackMarker(
		`{"type":"unexpected","payload":{"type":"thread_rolled_back","num_turns":2}}`)
		.status == NativeRollbackMarkerStatus.malformed);
	assert(classifyNativeRollbackMarker(
		`{"type":"event_msg","payload":{"type":"thread_rolled_back"`)
		.status == NativeRollbackMarkerStatus.malformed);
	assert(classifyNativeRollbackMarker(`{"type":"event_msg","payload":{"type":"task_complete"}}`)
		.status == NativeRollbackMarkerStatus.none);

	// Test applyRollbackToIdsWithInfo
	auto ids = [
		PersistedHistoryBoundary("line:1", PersistedHistoryBoundaryKind.user, null),
		PersistedHistoryBoundary("line:2", PersistedHistoryBoundaryKind.agent_turn, null),
		PersistedHistoryBoundary("line:3", PersistedHistoryBoundaryKind.user, null),
		PersistedHistoryBoundary("line:4", PersistedHistoryBoundaryKind.agent_turn, null),
		PersistedHistoryBoundary("line:5", PersistedHistoryBoundaryKind.user, null),
		PersistedHistoryBoundary("line:6", PersistedHistoryBoundaryKind.agent_turn, null),
	];
	auto rolled1 = applyRollbackToIdsWithInfo(ids, 1);
	assert(rolled1.length == 4, "rollback 1 should remove last user turn group");
	assert(rolled1[$ - 1].anchor == "line:4");

	auto rolled2 = applyRollbackToIdsWithInfo(ids, 2);
	assert(rolled2.length == 2, "rollback 2 should remove last 2 user turn groups");
	assert(rolled2[$ - 1].anchor == "line:2");

	auto rolledAll = applyRollbackToIdsWithInfo(ids, 10);
	assert(rolledAll.length == 0, "rollback > total should remove everything");

	// Fallback JSONL preview counts any active boundary, including assistants.
	{
		string jsonl =
			`{"type":"event_msg","payload":{"type":"task_started"}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}` ~ "\n" ~
			`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`;
		assert(countActiveFallbackRecordsFromBoundary(jsonl, "line:3") == 1);
		assert(countActiveFallbackRecordsFromBoundary(jsonl, "line:2") == 2);
		assert(countActiveFallbackRecordsFromBoundary(jsonl, "line:5") == -1);
		assert(countActiveFallbackRecordsFromBoundary(jsonl, "line:999999") == -1);
	}

	// A v1 interrupted turn persists a contextual role=user abort marker. It
	// belongs to the interrupted prompt rather than a separate Codex turn.
	{
		string beforeSecondRollback =
			`{"type":"event_msg","payload":{"type":"task_started"}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"interrupt-undo-one"}]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"interrupt-undo-two"}]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"interrupt-undo-three"}]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}` ~ "\n" ~
			`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"context-probe"}]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"interrupt-undo-running"}]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<turn_aborted>\nThe user interrupted the previous turn on purpose.\n</turn_aborted>"}]}}`;

		assert(countActiveFallbackRecordsFromBoundary(beforeSecondRollback, "line:4") == 5,
			"the contextual v1 abort wrapper must not add a fallback history entry");
		auto skip = computeRollbackSkipLines(beforeSecondRollback ~ "\n" ~
			`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":3}}`);
		assert(2 !in skip && 3 !in skip,
			"the second rollback must retain Codex's earlier first-turn prefix");
		foreach (line; 4 .. 14)
			assert(line in skip,
				"both rollback suffixes must be omitted during replay");
	}

	// Only a complete abort wrapper is contextual in Codex. Opening-only and
	// trailing-content lookalikes remain ordinary rollback turns.
	foreach (abortLikeText; [
		`<turn_aborted>\nThe user interrupted the previous turn on purpose.`,
		`<turn_aborted>\nThe user interrupted the previous turn on purpose.\n</turn_aborted>\nordinary user text`,
	])
	{
		string beforeRollback =
			`{"type":"event_msg","payload":{"type":"task_started"}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"retained-prefix"}]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"` ~ abortLikeText ~ `"}]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}`;

		assert(countActiveFallbackRecordsFromBoundary(beforeRollback, "line:2") == 4,
			"ordinary abort-like text must retain its fallback history entry");
		auto skip = computeRollbackSkipLines(beforeRollback ~ "\n" ~
			`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`);
		assert(2 !in skip && 3 !in skip,
			"replay must retain the prefix before an ordinary abort-like turn");
		foreach (line; 4 .. 7)
			assert(line in skip,
				"replay must remove the ordinary abort-like turn and rollback marker");
	}

	// Codex matches contextual abort wrappers case-insensitively after trimming
	// outer whitespace. This record must not consume a rollback turn.
	{
		string beforeRollback =
			`{"type":"event_msg","payload":{"type":"task_started"}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"retained-prefix"}]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"interrupted-turn"}]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"  \n<TURN_ABORTED>\nThe user interrupted the previous turn on purpose.\n</TURN_ABORTED>\n\t  "}]}}`;

		assert(countActiveFallbackRecordsFromBoundary(beforeRollback, "line:2") == 4,
			"the complete v1 abort wrapper must not add a fallback history entry");
		auto skip = computeRollbackSkipLines(beforeRollback ~ "\n" ~
			`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`);
		assert(2 !in skip && 3 !in skip,
			"replay must retain the prefix before the interrupted turn");
		foreach (line; 4 .. 8)
			assert(line in skip,
				"replay must remove the interrupted turn and contextual abort record");
	}

	// Test isRollbackMarker
	assert(isRollbackMarker(`{"timestamp":"2025-01-01T00:00:00.000Z","type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":2}}`));
	assert(!isRollbackMarker(`{"type":"event_msg","payload":{"type":"task_started"}}`));
	assert(!isRollbackMarker(`{"type":"response_item","payload":{"role":"user"}}`));

	// Test computeRollbackSkipLines — single rollback removing 1 turn
	{
		string jsonl =
			`{"type":"event_msg","payload":{"type":"task_started"}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}` ~ "\n" ~
			`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`;
		auto skip = computeRollbackSkipLines(jsonl);
		assert(4 in skip, "user 2 line should be skipped");
		assert(5 in skip, "assistant 2 line should be skipped");
		assert(6 in skip, "rollback marker should be skipped");
		assert(2 !in skip, "user 1 line should not be skipped");
		assert(3 !in skip, "assistant 1 line should not be skipped");
	}

	// Test computeRollbackSkipLines — double rollback (two markers)
	{
		string jsonl =
			`{"type":"event_msg","payload":{"type":"task_started"}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}` ~ "\n" ~
			`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}` ~ "\n" ~
			`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`;
		auto skip = computeRollbackSkipLines(jsonl);
		assert(6 in skip && 7 in skip, "user/assistant 3 should be skipped");
		assert(4 in skip && 5 in skip, "user/assistant 2 should be skipped");
		assert(8 in skip && 9 in skip, "rollback markers should be skipped");
		assert(2 !in skip && 3 !in skip, "user/assistant 1 should not be skipped");
	}

	// Test computeRollbackSkipLines — no rollback markers
	{
		string jsonl =
			`{"type":"event_msg","payload":{"type":"task_started"}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}`;
		auto skip = computeRollbackSkipLines(jsonl);
		assert(skip.length == 0, "no rollback markers should mean no skipped lines");
	}

	// Non-message response_item lines containing nested role/user data must not
	// shift user-turn boundaries.
	{
		string jsonl =
			`{"type":"event_msg","payload":{"type":"task_started"}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"function_call_output","output":{"role":"user"}}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}` ~ "\n" ~
			`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`;
		auto skip = computeRollbackSkipLines(jsonl);
		assert(5 in skip && 6 in skip, "rolled back second visible turn");
		assert(4 !in skip, "non-message response_item should not be treated as user turn");
	}
}

// ---------------------------------------------------------------------------
// Rollout JSONL translation: Codex rollout format → agnostic events.
// Codex rollout line: { timestamp, type: "session_meta"|"response_item"|
//   "event_msg"|"turn_context"|"compacted", payload: {...} }
// ---------------------------------------------------------------------------

/// Translate a session_meta rollout line → session/init agnostic event.
string translateRolloutSessionMeta(string line)
{
	@JSONPartial
	static struct Probe
	{
		@JSONPartial
		static struct Payload
		{
			string id;
			string cwd;
			string cli_version;
		}
		Payload payload;
	}

	Probe probe;
	try
		probe = jsonParse!Probe(line);
	catch (Exception e)
	{ tracef("translateHistoryEvent: probe parse error: %s", e.msg); return null; }

	if (probe.payload.id.length == 0)
		return null;

	import cydo.protocol : SessionInitEvent;

	SessionInitEvent ev;
	ev.session_id      = probe.payload.id;
	ev.model           = "";
	ev.cwd             = probe.payload.cwd;
	ev.tools           = [];
	ev.agent_version   = probe.payload.cli_version;
	ev.permission_mode = "dangerously-skip-permissions";
	ev.agent           = "codex";
	return toJson(ev);
}

/// Translate a turn_context rollout line → session/metadata agnostic event.
string translateRolloutTurnContext(string line)
{
	@JSONPartial
	static struct Probe
	{
		@JSONPartial
		static struct Payload
		{
			string model;
		}
		Payload payload;
	}

	Probe probe;
	try
		probe = jsonParse!Probe(line);
	catch (Exception e)
	{ tracef("translateHistoryEvent: turn_context parse error: %s", e.msg); return null; }

	if (probe.payload.model.length == 0)
		return null;

	import cydo.protocol : SessionMetadataEvent;

	SessionMetadataEvent ev;
	ev.model = probe.payload.model;
	return toJson(ev);
}

unittest
{
	@JSONPartial static struct MetadataEvent { string type; string model; }
	@JSONPartial static struct InitEvent { string type; string session_id; }

	auto init = translateRolloutSessionMeta(
		`{"type":"session_meta","payload":{"id":"thread-1","cwd":"/tmp","cli_version":"1.0"}}`);
	auto initEvent = jsonParse!InitEvent(init);
	assert(initEvent.type == "session/init");
	assert(initEvent.session_id == "thread-1");

	auto first = translateRolloutTurnContext(
		`{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}`);
	auto firstEvent = jsonParse!MetadataEvent(first);
	assert(firstEvent.type == "session/metadata");
	assert(firstEvent.model == "gpt-5.6-sol");

	assert(translateRolloutTurnContext(`{"type":"turn_context","payload":{}}`) is null);
	assert(translateRolloutTurnContext(`{"type":"turn_context","payload":{"model":""}}`) is null);

	auto second = translateRolloutTurnContext(
		`{"type":"turn_context","payload":{"model":"gpt-5.7"}}`);
	auto secondEvent = jsonParse!MetadataEvent(second);
	assert(secondEvent.type == "session/metadata");
	assert(secondEvent.model == "gpt-5.7");
}

/// Translate a response_item rollout line → item-based protocol events.
string[] translateRolloutResponseItem(string line, string forkId = null, bool forceMeta = false)
{
	@JSONPartial
	static struct Probe
	{
		@JSONPartial
		static struct Payload
		{
			string type;   // "message", "local_shell_call", "function_call",
			               // "custom_tool_call", "function_call_output", "reasoning"
			string role;   // for message type
			JSONFragment content;  // message content array or reasoning content

			// local_shell_call fields
			string call_id;
			JSONFragment action; // { type: "exec", command: [...] }

			// function_call fields
			string name;
			string arguments;
			string input;
			@JSONOptional string namespace;

			// function_call_output fields
			JSONFragment output;

			// reasoning fields
			JSONFragment summary;
		}
		Payload payload;
	}

	Probe probe;
	try
		probe = jsonParse!Probe(line);
	catch (Exception e)
	{ tracef("translateHistoryStreamEvent: probe parse error: %s", e.msg); return []; }

	auto ptype = probe.payload.type;

	string[] results;
	if (ptype == "message")
		results = translateRolloutMessage(probe.payload.role,
			probe.payload.content.json !is null ? probe.payload.content.json : "[]",
			forkId, forceMeta);
	else if (ptype == "local_shell_call")
		results = translateRolloutToolUse(probe.payload.call_id, "local_shell_call",
			extractCommandInput(probe.payload.action));
	else if (ptype == "function_call")
	{
		// Pass parsed arguments object directly (not wrapped as {"arguments":"..."}).
		string argsJson = probe.payload.arguments;
		string inputJson;
		if (argsJson.length > 0 && argsJson[0] == '{')
			inputJson = argsJson;  // already a JSON object
		else
			inputJson = `{}`;
		results = translateRolloutToolUse(probe.payload.call_id, probe.payload.name,
			inputJson, probe.payload.namespace);
	}
	else if (ptype == "custom_tool_call")
	{
		// exec input is always a script string, including scripts that begin with `{`.
		string inputJson = `{}`;
		auto rawInput = probe.payload.input;
		if (probe.payload.name == "exec")
			inputJson = `{"input":` ~ toJson(rawInput) ~ `}`;
		else if (rawInput.length > 0)
		{
			if (rawInput[0] == '{')
				inputJson = rawInput;
			else
				inputJson = `{"input":` ~ toJson(rawInput) ~ `}`;
		}
		results = translateRolloutToolUse(probe.payload.call_id, probe.payload.name,
			inputJson, probe.payload.namespace);
	}
	else if (ptype == "web_search_call")
	{
		// webSearch items in rollout: query and queries are inside action.
		string mainQuery;
		string[] queries;
		if (probe.payload.action.json !is null)
		{
			@JSONPartial
			static struct WSAction
			{
				@JSONOptional string query;
				@JSONOptional string[] queries;
			}
			try
			{
				auto act = jsonParse!WSAction(probe.payload.action.json);
				mainQuery = act.query;
				queries = act.queries;
			}
			catch (Exception) {}
		}

		string inputJson = `{}`;
		if (mainQuery.length > 0)
			inputJson = `{"query":` ~ toJson(mainQuery) ~ `}`;

		// Generate a stable call_id so tool_use and tool_result share the same ID.
		import std.uuid : randomUUID;

		string callId = probe.payload.call_id.length > 0
			? probe.payload.call_id : randomUUID().toString();
		results = translateRolloutToolUse(callId, "webSearch", inputJson);

		// Build structured tool_result instead of Claude-formatted text
		import std.array : appender;
		import cydo.protocol : ItemResultEvent;

		auto tr = appender!string;
		tr ~= `{`;
		if (mainQuery.length > 0)
			tr ~= `"query":` ~ toJson(mainQuery);
		if (queries.length > 0)
		{
			if (mainQuery.length > 0)
				tr ~= `,`;
			tr ~= `"queries":[`;
			foreach (i, q; queries)
			{
				if (i > 0)
					tr ~= `,`;
				tr ~= toJson(q);
			}
			tr ~= `]`;
		}
		tr ~= `}`;

		// Emit item/result with empty content and structured tool_result
		ItemResultEvent resEv;
		resEv.item_id = callId;
		resEv.content = JSONFragment(`[{"type":"text","text":""}]`);
		resEv.tool_result = JSONFragment(tr.data);
		results ~= toJson(resEv);
	}
	else if (ptype == "function_call_output" || ptype == "custom_tool_call_output"
		|| ptype == "mcp_tool_call_output")
	{
		auto r = translateRolloutToolResult(probe.payload.call_id,
			probe.payload.output.json !is null ? probe.payload.output.json : `""`);
		if (r !is null)
			results = [r];
	}
	else if (ptype == "reasoning")
		results = translateRolloutReasoning(
			probe.payload.summary.json !is null ? probe.payload.summary.json : "[]",
			probe.payload.content.json);
	else if (ptype == "ghost_snapshot")
		return [];
	else
		return [makeUnrecognizedEvent("unknown Codex response_item payload type: " ~ ptype)];

	if (results.length == 0)
		return [];

	return results;
}

/// Translate a message response_item payload → item/started [+ item/completed].
string[] translateRolloutMessage(string role, string contentJson, string forkId = null,
	bool forceMeta = false)
{
	import std.array : replace;

	// Remap Codex content types (input_text/output_text) → agnostic "text"
	auto content = contentJson
		.replace(`"type":"input_text"`, `"type":"text"`)
		.replace(`"type":"output_text"`, `"type":"text"`);

	if (role == "assistant")
	{
		import cydo.protocol : ItemCompletedEvent, ItemStartedEvent, TurnStopEvent, UsageInfo;

		// Parse content blocks from the JSON array string
		@JSONPartial
		static struct RawBlock
		{
			string type;
			@JSONOptional string text;
		}

		string[] events;
		try
		{
			auto rawBlocks = jsonParse!(RawBlock[])(content);
			foreach (i, ref rb; rawBlocks)
			{
				auto itemId = "codex-hist-" ~ to!string(i);
				ItemStartedEvent startEv;
				startEv.item_id = itemId;
				startEv.item_type = rb.type == "thinking" ? "thinking" : "text";
				if (rb.text.length > 0)
					startEv.text = rb.text;
				events ~= toJson(startEv);

				ItemCompletedEvent compEv;
				compEv.item_id = itemId;
				if (rb.text.length > 0)
					compEv.text = rb.text;
				events ~= toJson(compEv);
			}
		}
		catch (Exception e)
		{ tracef("translateRolloutMessage: content parse error: %s", e.msg); }

		TurnStopEvent tsev;
		tsev.model = "";
		tsev.usage = UsageInfo(0, 0);
		if (forkId !is null)
			tsev.uuid = forkId;
		events ~= toJson(tsev);
		return events;
	}
	else // user, developer, system
	{
		import cydo.protocol : ItemStartedEvent;

		// Extract text from the content array
		@JSONPartial
		static struct TextBlock
		{
			string type;
			@JSONOptional string text;
		}

		string userText;
		try
		{
			auto blocks = jsonParse!(TextBlock[])(content);
			foreach (ref b; blocks)
				if (b.type == "text")
					userText ~= b.text;
		}
		catch (Exception) {}

		ContentBlock cb;
		cb.type = "text";
		cb.text = userText;
		ItemStartedEvent ev;
		ev.item_id = "codex-user-hist";
		ev.item_type = "user_message";
		ev.content = [cb];
		if (role != "user" || forceMeta)
			ev.is_meta = true;
		else if (isCodexContextOnlyUserText(userText))
			ev.is_meta = true;
		if (forkId !is null)
			ev.uuid = forkId;
		return [toJson(ev)];
	}
}

/// Translate a tool_use response_item → item/started + item/completed.
string[] translateRolloutToolUse(string callId, string toolName, string inputJson, string namespace = "")
{
	import std.uuid : randomUUID;
	import cydo.protocol : ItemCompletedEvent, ItemStartedEvent, TurnStopEvent, UsageInfo,
		decomposeToolName;

	if (callId.length == 0)
		callId = randomUUID().toString();

	ItemStartedEvent startEv;
	startEv.item_id = callId;
	startEv.item_type = "tool_use";
	decomposeToolName(toolName, startEv.name, startEv.tool_server, startEv.tool_source);
	if (namespace.length > 0 && startEv.tool_server.length == 0)
	{
		// Parse namespace like "mcp__cydo__" → tool_server="cydo", tool_source="mcp"
		import std.algorithm : endsWith, startsWith;

		string ns = namespace;
		if (ns.startsWith("mcp__"))
			ns = ns["mcp__".length .. $];
		if (ns.endsWith("__"))
			ns = ns[0 .. $ - 2];
		if (ns.length > 0)
		{
			startEv.tool_server = ns;
			startEv.tool_source = "mcp";
		}
	}
	if (inputJson.length > 0 && inputJson != `{}`)
		startEv.input = JSONFragment(inputJson);

	ItemCompletedEvent compEv;
	compEv.item_id = callId;
	if (inputJson.length > 0 && inputJson != `{}`)
		compEv.input = JSONFragment(inputJson);

	TurnStopEvent tsev;
	tsev.usage = UsageInfo(0, 0);
	return [toJson(startEv), toJson(compEv), toJson(tsev)];
}

/// Translate a tool_result response_item → item/result.
Nullable!string tryExtractRolloutOutputJson(string outputJson)
{
	import std.json : parseJSON;
	import std.string : indexOf, strip;

	enum outputMarker = "Output:\n";
	if (outputJson.length == 0 || outputJson[0] != '"')
		return Nullable!string.init;

	string decoded;
	try
		decoded = jsonParse!string(outputJson);
	catch (Exception)
	{
		return Nullable!string.init;
	}

	auto markerPos = indexOf(decoded, outputMarker);
	if (markerPos < 0)
		return Nullable!string.init;

	auto extracted = decoded[markerPos + outputMarker.length .. $].strip();
	if (extracted.length == 0)
		return Nullable!string.init;
	if (extracted[0] != '{' && extracted[0] != '[')
		return Nullable!string.init;

	try
		parseJSON(extracted);
	catch (Exception)
	{
		return Nullable!string.init;
	}

	return Nullable!string(extracted);
}

string translateRolloutToolResult(string callId, string outputJson)
{
	import cydo.protocol : ItemResultEvent;

	ItemResultEvent ev;
	ev.item_id = callId;
	if (outputJson.length > 0 && outputJson[0] == '"')
	{
		auto extracted = tryExtractRolloutOutputJson(outputJson);
		if (!extracted.isNull)
			ev.content = JSONFragment(`[{"type":"text","text":` ~ toJson(extracted.get) ~ `}]`);
		else
			ev.content = JSONFragment(`[{"type":"text","text":` ~ outputJson ~ `}]`);
	}
	else if (outputJson.length > 0 && outputJson[0] == '[')
	{
		@JSONPartial
		static struct ContentItem
		{
			string type;
			JSONFragment text;
		}

		ContentItem[] items;
		try
			items = jsonParse!(ContentItem[])(outputJson);
		catch (Exception)
			return makeUnrecognizedEvent("malformed Codex tool output content-item array");

		string text;
		foreach (ref item; items)
		{
			if (item.type != "input_text" && item.type != "output_text")
				return makeUnrecognizedEvent(
					"unrecognized Codex tool output content-item type: " ~ item.type);
			if (item.text.json is null)
				return makeUnrecognizedEvent(
					"malformed Codex tool output content-item: " ~ item.type);
			try
				text ~= jsonParse!string(item.text.json);
			catch (Exception)
				return makeUnrecognizedEvent(
					"malformed Codex tool output content-item: " ~ item.type);
		}
		ev.content = JSONFragment(`[{"type":"text","text":` ~ toJson(text) ~ `}]`);
	}
	else
		ev.content = JSONFragment(outputJson);
	return toJson(ev);
}

unittest
{
	@JSONPartial static struct ToolUse { string type; string item_id; string name; JSONFragment input; }
	@JSONPartial static struct ToolCompleted { string type; string item_id; JSONFragment input; }
	@JSONPartial static struct ToolResult { string type; string item_id; JSONFragment content; }
	@JSONPartial static struct TextBlock { string type; string text; }
	@JSONPartial static struct WaitInput { string cell_id; uint yield_time_ms; uint max_tokens; }

	auto callId = "call_exec_history";
	auto script = "const result = await tools.exec_command({ cmd: \"pwd\" });\ntext(result.output);";
	auto call = translateRolloutResponseItem(
		`{"type":"response_item","payload":{"type":"custom_tool_call","call_id":"call_exec_history","name":"exec","input":` ~ toJson(script) ~ `}}`);
	assert(call.length == 3);
	auto toolUse = jsonParse!ToolUse(call[0]);
	assert(toolUse.type == "item/started");
	assert(toolUse.item_id == callId);
	assert(toolUse.name == "exec");
	assert(jsonParse!(string[string])(toolUse.input.json)["input"] == script);
	auto toolCompleted = jsonParse!ToolCompleted(call[1]);
	assert(toolCompleted.type == "item/completed");
	assert(toolCompleted.item_id == callId);
	assert(jsonParse!(string[string])(toolCompleted.input.json)["input"] == script);

	auto blockScript = `{ const result = await tools.exec_command({ cmd: "pwd" }); }`;
	auto blockCall = translateRolloutResponseItem(
		`{"type":"response_item","payload":{"type":"custom_tool_call","call_id":"call_exec_block","name":"exec","input":`
		~ toJson(blockScript) ~ `}}`);
	assert(blockCall.length == 3);
	auto blockToolUse = jsonParse!ToolUse(blockCall[0]);
	assert(jsonParse!(string[string])(blockToolUse.input.json)["input"] == blockScript);

	// Function-call wait arguments remain structured during history replay.
	auto waitCallId = "call_wait_history";
	auto waitArguments = `{"cell_id":"cell_123","yield_time_ms":1000,"max_tokens":2000}`;
	auto waitCall = translateRolloutResponseItem(
		`{"type":"response_item","payload":{"type":"function_call","call_id":"call_wait_history","name":"wait","arguments":`
		~ toJson(waitArguments) ~ `}}`);
	assert(waitCall.length == 3);
	auto waitToolUse = jsonParse!ToolUse(waitCall[0]);
	assert(waitToolUse.type == "item/started");
	assert(waitToolUse.item_id == waitCallId);
	assert(waitToolUse.name == "wait");
	auto waitInput = jsonParse!WaitInput(waitToolUse.input.json);
	assert(waitInput.cell_id == "cell_123");
	assert(waitInput.yield_time_ms == 1000);
	assert(waitInput.max_tokens == 2000);
	auto waitCompleted = jsonParse!ToolCompleted(waitCall[1]);
	assert(waitCompleted.item_id == waitCallId);

	auto waitResult = translateRolloutResponseItem(
		`{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_wait_history","output":"Command finished."}}`);
	assert(waitResult.length == 1);
	auto waitToolResult = jsonParse!ToolResult(waitResult[0]);
	assert(waitToolResult.item_id == waitCallId);
	auto waitBlocks = jsonParse!(TextBlock[])(waitToolResult.content.json);
	assert(waitBlocks.length == 1);
	assert(waitBlocks[0].text == "Command finished.");

	auto result = translateRolloutResponseItem(
		`{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_exec_history","output":[{"type":"input_text","text":"first "},{"type":"input_text","text":"second"}]}}`);
	assert(result.length == 1);
	auto toolResult = jsonParse!ToolResult(result[0]);
	assert(toolResult.type == "item/result");
	assert(toolResult.item_id == callId);
	auto blocks = jsonParse!(TextBlock[])(toolResult.content.json);
	assert(blocks.length == 1);
	assert(blocks[0].type == "text");
	assert(blocks[0].text == "first second");

	auto unrecognizedContent = translateRolloutResponseItem(
		`{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_exec_history","output":[{"type":"image","text":"x"}]}}`);
	assert(unrecognizedContent.length == 1);
	assert(unrecognizedContent[0].canFind(`"type":"agent/unrecognized"`));

	auto unrecognizedPayload = translateRolloutResponseItem(
		`{"type":"response_item","payload":{"type":"future_codex_payload"}}`);
	assert(unrecognizedPayload.length == 1);
	assert(unrecognizedPayload[0].canFind(`"type":"agent/unrecognized"`));

	auto ignoredPayload = translateRolloutResponseItem(
		`{"type":"response_item","payload":{"type":"ghost_snapshot"}}`);
	assert(ignoredPayload.length == 0);

	auto classicOutput = translateRolloutResponseItem(
		`{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_classic","output":"Output:\n{\"ok\":true}"}}`);
	assert(classicOutput.length == 1);
	auto classicResult = jsonParse!ToolResult(classicOutput[0]);
	auto classicBlocks = jsonParse!(TextBlock[])(classicResult.content.json);
	assert(classicBlocks[0].text == `{"ok":true}`);
}

/// Translate a reasoning response_item → item/started (thinking) + item/completed.
string[] translateRolloutReasoning(string summaryJson, string contentJson)
{
	// Extract text from summary array: [{ text: "..." }, ...]
	string thinkingText;
	if (contentJson !is null && contentJson.length > 2)
	{
		@JSONPartial static struct ReasoningContent { string text; }
		try
		{
			auto items = jsonParse!(ReasoningContent[])(contentJson);
			foreach (ref item; items)
				if (item.text.length > 0)
					thinkingText ~= item.text;
		}
		catch (Exception) {}
	}

	if (thinkingText.length == 0 && summaryJson.length > 2)
	{
		@JSONPartial static struct SummaryItem { string text; }
		try
		{
			auto items = jsonParse!(SummaryItem[])(summaryJson);
			foreach (ref item; items)
				if (item.text.length > 0)
					thinkingText ~= item.text;
		}
		catch (Exception e) { tracef("translateRolloutReasoning: parse error: %s", e.msg); }
	}

	if (thinkingText.length == 0)
		return [];

	import cydo.protocol : ItemCompletedEvent, ItemStartedEvent;

	ItemStartedEvent startEv;
	startEv.item_id = "codex-reasoning";
	startEv.item_type = "thinking";
	startEv.text = thinkingText;

	ItemCompletedEvent compEv;
	compEv.item_id = "codex-reasoning";
	compEv.text = thinkingText;

	return [toJson(startEv), toJson(compEv)];
}

/// Translate an event_msg rollout line → turn/result (for task_complete).
string translateRolloutEventMsg(string line)
{
	@JSONPartial
	static struct Probe
	{
		@JSONPartial
		static struct Payload
		{
			string type;
		}
		Payload payload;
	}

	Probe probe;
	try
		probe = jsonParse!Probe(line);
	catch (Exception e)
	{ tracef("translateStreamEvent: probe parse error: %s", e.msg); return null; }

	if (probe.payload.type == "task_complete")
	{
		import cydo.protocol : TurnResultEvent, UsageInfo;

		TurnResultEvent ev;
		ev.subtype = "success";
		ev.num_turns = 1;
		ev.usage = UsageInfo(0, 0);
		return toJson(ev);
	}

	// Skip user_message, task_started, error, etc.
	return null;
}

/// Extract command string from a Codex commandExecution action fragment.
string extractCommandInput(JSONFragment action)
{
	if (action.json is null || action.json.length == 0)
		return `{}`;

	@JSONPartial
	static struct ActionData
	{
		string[] command;
	}

	try
	{
		auto act = jsonParse!ActionData(action.json);
		string cmd;
		if (act.command.length >= 3 && act.command[0] == "sh" && act.command[1] == "-c")
			cmd = act.command[2];
		else if (act.command.length > 0)
		{
			import std.array : join;

			cmd = act.command.join(" ");
		}
		import cydo.protocol : CommandInput;
		return toJson(CommandInput(cmd, ""));
	}
	catch (Exception e)
	{ tracef("extractBashInput: parse error: %s", e.msg); return `{}`; }
}
