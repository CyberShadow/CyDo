module cydo.agent.drivers.codex.native_undo;

import std.conv : to;
import std.typecons : Nullable;

import ae.utils.json : JSONExtras, jsonParse, toJson;
import ae.utils.promise : Promise;

import cydo.agent.drivers.codex.rollout;
import cydo.agent.drivers.codex.rpc;
import cydo.protocol : HistoryBoundary, HistoryBoundaryKind;

/// Immutable evidence produced immediately before a native undo dispatch. The
/// execution unit intentionally receives the pre-read vector and exact prefix
/// rather than reconstructing either from a count or rollout history.
struct NativeUndoPlan
{
	uint numTurns;
	LedgerTurn[] preTurns;
	SO[] preRawTurns;
	LedgerTurn[] retainedPrefix;
	SO[] retainedRawPrefix;
	size_t targetLedgerIndex;
	string targetTurnId;
	Nullable!string targetClientId;
	string preparedThreadId;
	string preparedRolloutPath;
	ulong preparedRolloutFileId;
	size_t preparedRolloutSize;
}

/// The execution outcome deliberately separates harmless pre-dispatch
/// refusals from uncertainty after the provider call could have happened.
enum NativeUndoExecutionStatus
{
	verified,
	refusedBeforeDispatch,
	unverifiableAfterDispatch,
}

struct NativeUndoExecutionResult
{
	NativeUndoExecutionStatus status;
	string diagnostic;
}

package enum NativeUndoMarkerVerificationStatus
{
	waiting,
	verified,
	failure,
}

package struct NativeUndoMarkerVerification
{
	NativeUndoMarkerVerificationStatus status;
	string diagnostic;
}

enum NativeUndoPreparationRefusalCategory
{
	sessionDead,
	missingThread,
	missingRolloutPath,
	turnInProgress,
	queuedNativeInput,
	inFlightSubmission,
	rolloutUnavailable,
	threadReadFailed,
	providerData,
	invalidBoundary,
	targetUnavailable,
	threadStatus,
	ledger,
	association,
	unsupportedSuffix,
	arithmetic,
}

/// A preparation error is deliberately typed so callers can report a precise
/// no-dispatch refusal without selecting the JSONL fallback after native has
/// already been chosen.
class NativeUndoPreparationRefusal : Exception
{
	this(NativeUndoPreparationRefusalCategory category, string diagnostic)
	{
		super(diagnostic);
		this.category = category;
		this.diagnostic = diagnostic;
	}

	NativeUndoPreparationRefusalCategory category;
	string diagnostic;
}

private void refuse(NativeUndoPreparationRefusalCategory category, string diagnostic)
{
	throw new NativeUndoPreparationRefusal(category, diagnostic);
}

package Promise!NativeUndoPlan refusedNativeUndoPreparation(
	NativeUndoPreparationRefusalCategory category, string diagnostic)
{
	auto result = new Promise!NativeUndoPlan;
	result.reject(new NativeUndoPreparationRefusal(category, diagnostic));
	return result;
}

private bool rawHasField(SO value, string name)
{
	return value.type == SO.Type.object && name in value;
}

private bool rawObjectHasExactKeys(SO value, scope const string[] keys)
{
	if (value.type != SO.Type.object || value.length != keys.length)
		return false;
	foreach (key; keys)
		if (!rawHasField(value, key))
			return false;
	return true;
}

private bool rawExplicitNull(SO value, string name)
{
	return rawHasField(value, name) && value[name].type == SO.Type.null_;
}

private bool rawString(SO value, string name, out string result)
{
	if (!rawHasField(value, name) || value[name].type != SO.Type.string_)
		return false;
	try
	{
		result = jsonParse!string(value[name].toJson());
		return true;
	}
	catch (Exception)
		return false;
}

private bool rawArray(SO value, string name, out SO result)
{
	if (!rawHasField(value, name) || value[name].type != SO.Type.array)
		return false;
	result = value[name];
	return true;
}

private bool hasExtras(const ref JSONExtras extras)
{
	return extras.length != 0;
}

private bool isFullView(const ref LedgerTurn turn, SO raw)
{
	string view;
	return turn.itemsView == "full" && rawString(raw, "itemsView", view) && view == "full";
}

private bool validThreadStatus(const ref LedgerThread thread, SO rawThread)
{
	if (rawThread.type != SO.Type.object || !rawHasField(rawThread, "status"))
		return false;
	auto rawStatus = rawThread["status"];
	string rawType;
	// The captured idle thread/read status is exactly {"type":"idle"}.
	// Presence-aware raw validation rejects optional fields decoded from null
	// and future status data before native preparation.
	return rawObjectHasExactKeys(rawStatus, ["type"])
		&& rawString(rawStatus, "type", rawType) && rawType == "idle"
		&& thread.status.type == "idle" && thread.status.activeFlags.length == 0
		&& !hasExtras(thread.status.extras);
}

private uint checkedNativeUndoCount(size_t length, size_t targetIndex)
{
	if (targetIndex >= length)
		refuse(NativeUndoPreparationRefusalCategory.arithmetic,
			"native undo target index is outside the materialized turn vector");
	auto count = length - targetIndex;
	if (count == 0 || count > uint.max)
		refuse(NativeUndoPreparationRefusalCategory.arithmetic,
			"native undo turn count is not representable as uint");
	return cast(uint) count;
}

private bool parseLineAnchor(string anchor, out int line)
{
	if (anchor.length <= "line:".length || anchor[0 .. "line:".length] != "line:")
		return false;
	auto digits = anchor["line:".length .. $];
	if (digits.length > 1 && digits[0] == '0')
		return false;
	foreach (c; digits)
		if (c < '0' || c > '9')
			return false;
	try
	{
		line = to!int(digits);
		return line > 0;
	}
	catch (Exception)
		return false;
}

private alias RawLifecycle = RolloutTurnLifecycleEvidence;

private RawLifecycle lifecycleFor(const ref RolloutScan scan, string turnId)
{
	auto lifecycle = turnId in scan.nativeLifecycles;
	return lifecycle is null ? RawLifecycle.init : *lifecycle;
}

private struct RawSubmission
{
	int responseIndex;
	int eventIndex;
	size_t turnIndex;
	bool modern;
}

private bool isEligibleRawSubmission(const ref RolloutLineEvidence line)
{
	return line.nativeActive && isExactNativeSubmittedUser(line, line.turnId);
}

private bool isExactRawUserEvent(const ref RolloutLineEvidence event,
	const ref RolloutLineEvidence response)
{
	return event.nativeActive && isExactNativeUserEvent(event, response);
}

private bool validRawUserItem(SO rawItem, const ref LedgerThreadItem item,
	const ref RolloutLineEvidence response, const ref RolloutLineEvidence event,
	bool modern)
{
	if (!rawObjectHasExactKeys(rawItem, ["type", "id", "clientId", "content"])
		&& !( !modern && rawObjectHasExactKeys(rawItem, ["type", "id", "content"])))
		return false;
	if (item.type != "userMessage" || item.id.length == 0 || hasExtras(item.extras)
		|| item.content.length != 1 || item.content[0].type != "text"
		|| item.content[0].text != response.inputText || item.content[0].textElements.length != 0
		|| hasExtras(item.content[0].extras))
		return false;
	string rawType, rawId;
	if (!rawString(rawItem, "type", rawType) || rawType != "userMessage"
		|| !rawString(rawItem, "id", rawId) || rawId != item.id)
		return false;
	SO rawContent;
	if (!rawArray(rawItem, "content", rawContent) || rawContent.length != 1)
		return false;
	auto rawInput = rawContent[0];
	if (!rawObjectHasExactKeys(rawInput, ["type", "text", "text_elements"]))
		return false;
	string rawInputType, rawText;
	SO rawTextElements;
	if (!rawString(rawInput, "type", rawInputType) || rawInputType != "text"
		|| !rawString(rawInput, "text", rawText) || rawText != response.inputText
		|| !rawArray(rawInput, "text_elements", rawTextElements)
		|| rawTextElements.length != 0)
		return false;
	if (modern)
	{
		string rawClientId;
		return rawString(rawItem, "clientId", rawClientId) && rawClientId == event.eventClientId
			&& item.clientId == event.eventClientId;
	}
	return !rawHasField(rawItem, "clientId") && item.clientId.length == 0;
}

private bool validRawAgentItem(SO rawItem, const ref LedgerThreadItem item,
	const ref RolloutLineEvidence assistant,
	const ref RolloutLineEvidence agentEvent)
{
	if (!rawObjectHasExactKeys(rawItem,
		["type", "id", "text", "phase", "memoryCitation"])
		|| item.type != "agentMessage" || item.id.length == 0 || item.text.length == 0
		|| item.phase !is null || item.memoryCitation.type != SO.Type.null_
		|| hasExtras(item.extras))
		return false;
	string rawType, rawId, rawText;
	if (!rawString(rawItem, "type", rawType) || rawType != "agentMessage"
		|| !rawString(rawItem, "id", rawId) || rawId != item.id
		|| !rawString(rawItem, "text", rawText) || rawText != item.text
		|| !rawExplicitNull(rawItem, "phase") || !rawExplicitNull(rawItem, "memoryCitation"))
		return false;
	return isExactNativeAssistantResponse(assistant, assistant.turnId)
		&& assistant.contentText == item.text && isExactNativeAgentEvent(agentEvent)
		&& agentEvent.eventMessage == item.text;
}

private int findAssistantResponse(const ref RolloutScan scan, string turnId,
	const ref RawLifecycle lifecycle, int afterIndex)
{
	int found = -1;
	auto terminalIndex = lifecycle.completeIndex >= 0
		? lifecycle.completeIndex : lifecycle.abortIndex;
	for (int i = afterIndex + 1; i < terminalIndex; i++)
	{
		auto line = scan.lines[i];
		if (!line.nativeActive || !line.probe.isAssistantMessage || !line.metadataKnown
			|| !line.turnIdValid
			|| line.turnId != turnId)
			continue;
		if (found >= 0)
			return -2;
		found = i;
	}
	return found;
}

private int findAgentEvent(const ref RolloutScan scan, const ref RawLifecycle lifecycle,
	int afterIndex)
{
	int found = -1;
	auto terminalIndex = lifecycle.completeIndex >= 0
		? lifecycle.completeIndex : lifecycle.abortIndex;
	for (int i = afterIndex + 1; i < terminalIndex; i++)
	{
		auto line = scan.lines[i];
		if (!line.nativeActive || !line.probe.isEventMsg || line.payloadType != "agent_message")
			continue;
		if (found >= 0)
			return -2;
		found = i;
	}
	return found;
}

private bool isAllowedPreSubmissionContext(const ref RolloutLineEvidence line,
	string turnId)
{
	return isExactNativePreSubmissionContext(line, turnId);
}

private bool onlyExpectedSimpleResponses(const ref RolloutScan scan,
	const ref RawLifecycle lifecycle, string turnId, int userIndex, int userEventIndex,
	int assistantIndex)
{
	for (int i = lifecycle.startIndex + 1; i < lifecycle.completeIndex; i++)
	{
		auto line = scan.lines[i];
		if (!line.nativeActive)
			continue;
		if (line.probe.isEventMsg
			&& (line.payloadType == "user_message" && i != userEventIndex
				|| line.probe.isTaskStarted || line.payloadType == "task_complete"
				|| line.payloadType == "turn_aborted"))
			return false;
		if (!line.probe.isResponseItem)
			continue;
		// Codex's initial developer/environment context is recorded after the
		// first task_started but before the submitted caller. It remains outside
		// the candidate raw suffix; response items after the caller must be the
		// exact simple pair.
		if (i < userIndex)
		{
			if (!isAllowedPreSubmissionContext(line, turnId))
				return false;
			continue;
		}
		if (i == userIndex || i == assistantIndex)
			continue;
		return false;
	}
	return true;
}

private bool onlyExpectedInterruptedResponses(const ref RolloutScan scan,
	const ref RawLifecycle lifecycle, string turnId, int userIndex, int userEventIndex,
	int wrapperIndex)
{
	for (int i = lifecycle.startIndex + 1; i < lifecycle.abortIndex; i++)
	{
		auto line = scan.lines[i];
		if (!line.nativeActive)
			continue;
		if (line.probe.isEventMsg
			&& (line.payloadType == "user_message" && i != userEventIndex
				|| line.probe.isTaskStarted || line.payloadType == "task_complete"
				|| line.payloadType == "turn_aborted"))
			return false;
		if (!line.probe.isResponseItem)
			continue;
		if (i < userIndex)
		{
			if (!isAllowedPreSubmissionContext(line, turnId))
				return false;
			continue;
		}
		if (i == userIndex || i == wrapperIndex)
			continue;
		return false;
	}
	return true;
}

private int terminalLifecycleIndex(const ref RawLifecycle lifecycle)
{
	return lifecycle.completeIndex >= 0 ? lifecycle.completeIndex : lifecycle.abortIndex;
}

private bool isAllowedCandidateTelemetry(const ref RolloutScan scan,
	const ref RolloutLineEvidence line,
	const ref RawLifecycle[] lifecycles, size_t targetIndex, int physicalIndex)
{
	foreach (turnIndex; targetIndex .. lifecycles.length)
	{
		auto lifecycle = lifecycles[turnIndex];
		auto terminalIndex = terminalLifecycleIndex(lifecycle);
		if (physicalIndex > lifecycle.startIndex && physicalIndex < terminalIndex)
			return isExactNativePreTerminalTelemetry(line);
		if (physicalIndex > terminalIndex && (turnIndex + 1 == lifecycles.length
			|| physicalIndex < lifecycles[turnIndex + 1].startIndex))
			return isExactNativePostTerminalTelemetry(line,
				nativeTerminalKind(scan.lines[terminalIndex]));
	}
	return false;
}

private bool isKnownPreSubmissionEnvelope(const ref RolloutLineEvidence line,
	string turnId)
{
	return isExactNativePreSubmissionEnvelope(line, turnId);
}

private int findCompactedRecord(const ref RolloutScan scan,
	const ref RawLifecycle lifecycle)
{
	int found = -1;
	foreach (i; lifecycle.startIndex + 1 .. lifecycle.completeIndex)
	{
		auto line = scan.lines[i];
		if (!line.nativeActive || !line.isCompacted)
			continue;
		if (found >= 0)
			return -2;
		found = i;
	}
	return found;
}

private int findContextCompactedEvent(const ref RolloutScan scan,
	const ref RawLifecycle lifecycle)
{
	int found = -1;
	foreach (i; lifecycle.startIndex + 1 .. lifecycle.completeIndex)
	{
		auto line = scan.lines[i];
		if (!line.nativeActive || !line.probe.isEventMsg
			|| line.payloadType != "context_compacted")
			continue;
		if (found >= 0)
			return -2;
		found = i;
	}
	return found;
}

/// Every active physical line from the selected lifecycle onward must belong
/// to one admitted lifecycle position. This is deliberately a total check:
/// malformed, future, residual, and unclaimed raw data cannot disappear while
/// typed materialization happens to look like a simple suffix.
private bool validClosedRawSuffix(const ref RolloutScan scan,
	const ref RawSubmission[] submissions, const ref LedgerTurn[] turns,
	size_t targetIndex)
{
	if (targetIndex >= turns.length)
		return false;
	auto firstLifecycle = lifecycleFor(scan, turns[targetIndex].id);
	if (firstLifecycle.startIndex < 0)
		return false;
	int[] submissionIndices;
	submissionIndices.length = turns.length;
	foreach (ref submissionIndex; submissionIndices)
		submissionIndex = -1;
	foreach (i, ref submission; submissions)
	{
		if (submission.turnIndex < targetIndex || submission.turnIndex >= turns.length
			|| submissionIndices[submission.turnIndex] >= 0)
			return false;
		submissionIndices[submission.turnIndex] = cast(int)i;
	}
	RawLifecycle[] lifecycles;
	lifecycles.length = turns.length;
	int[] terminalIndices;
	terminalIndices.length = turns.length;
	int lastTerminal = -1;
	bool[int] consumed;

	foreach (turnIndex; targetIndex .. turns.length)
	{
		auto lifecycle = lifecycleFor(scan, turns[turnIndex].id);
		auto terminalIndex = terminalLifecycleIndex(lifecycle);
		if (lifecycle.startIndex < 0 || terminalIndex <= lifecycle.startIndex
			|| (lastTerminal >= 0 && lifecycle.startIndex <= lastTerminal))
			return false;
		lifecycles[turnIndex] = lifecycle;
		terminalIndices[turnIndex] = terminalIndex;
		consumed[lifecycle.startIndex] = true;
		consumed[terminalIndex] = true;

		auto submissionIndex = submissionIndices[turnIndex];
		if (submissionIndex >= 0)
		{
			auto submission = submissions[submissionIndex];
			if (submission.responseIndex <= lifecycle.startIndex
				|| submission.eventIndex != submission.responseIndex + 1
				|| submission.eventIndex >= terminalIndex)
				return false;
			consumed[submission.responseIndex] = true;
			consumed[submission.eventIndex] = true;
			if (turns[turnIndex].status == "completed")
			{
				auto assistantIndex = findAssistantResponse(scan, turns[turnIndex].id,
					lifecycle, submission.eventIndex);
				auto agentIndex = findAgentEvent(scan, lifecycle, submission.eventIndex);
				if (assistantIndex < 0 || agentIndex < 0)
					return false;
				consumed[assistantIndex] = true;
				consumed[agentIndex] = true;
			}
			else if (turns[turnIndex].status == "interrupted")
			{
				int wrapperIndex = -1;
				size_t wrappers;
				foreach (i; lifecycle.startIndex + 1 .. lifecycle.abortIndex)
					if (isExactV1AbortWrapper(scan.lines[i])
						&& scan.lines[i].nativeActive
						&& scan.lines[i].turnId == turns[turnIndex].id)
					{
						wrapperIndex = i;
						wrappers++;
					}
				if (wrappers != 1 || wrapperIndex <= submission.eventIndex
					|| wrapperIndex + 1 != lifecycle.abortIndex)
					return false;
				consumed[wrapperIndex] = true;
			}
			else
				return false;
		}
		else
		{
			auto assistantIndex = findAssistantResponse(scan, turns[turnIndex].id,
				lifecycle, lifecycle.startIndex);
			auto compactedIndex = findCompactedRecord(scan, lifecycle);
			auto contextCompactedIndex = findContextCompactedEvent(scan, lifecycle);
			if (assistantIndex < 0 || compactedIndex < 0 || contextCompactedIndex < 0
				|| assistantIndex >= compactedIndex || compactedIndex >= contextCompactedIndex)
				return false;
			consumed[assistantIndex] = true;
			consumed[compactedIndex] = true;
			consumed[contextCompactedIndex] = true;
		}
		lastTerminal = terminalIndex;
	}

	size_t candidateTurnIndex = targetIndex;
	foreach (i; firstLifecycle.startIndex .. scan.lines.length)
	{
		auto physicalIndex = cast(int)i;
		auto line = scan.lines[i];
		if (!line.nativeActive)
			continue;
		// Claimed lifecycle records are no less authoritative than residual
		// records. Check their lossless outer envelope before the consumed map
		// hides them from the physical-line closure below.
		if (!line.parsed || !line.topLevelEnvelopeKnown)
			return false;
		if (physicalIndex in consumed)
			continue;
		if (isAllowedCandidateTelemetry(scan, line, lifecycles, targetIndex, physicalIndex))
			continue;

		while (candidateTurnIndex < turns.length
			&& physicalIndex > terminalIndices[candidateTurnIndex])
			candidateTurnIndex++;
		if (candidateTurnIndex >= turns.length
			|| submissionIndices[candidateTurnIndex] < 0)
			return false;
		auto lifecycle = lifecycles[candidateTurnIndex];
		auto submission = submissions[submissionIndices[candidateTurnIndex]];
		if (physicalIndex <= lifecycle.startIndex || physicalIndex >= submission.responseIndex
			|| !(isKnownPreSubmissionEnvelope(line, turns[candidateTurnIndex].id)
				|| isAllowedPreSubmissionContext(line, turns[candidateTurnIndex].id)))
			return false;
	}
	return true;
}

private bool isExactLeadingNativeSessionMeta(const ref RolloutLineEvidence line)
{
	return line.parsed && line.topLevelEnvelopeKnown
		&& line.topLevelKind == RolloutTopLevelKind.sessionMeta
		&& line.probe.isSessionMeta;
}

/// Marker processing intentionally leaves malformed, orphan, and unsupported
/// evidence native-active. A later clicked target must still observe every one
/// of those physical lines. The only pre-target exception is a complete,
/// corroborated lifecycle range whose exact start ID is represented by the
/// opaque retained prefix, or the one-record leading session_meta preamble.
/// The latter is system context, not a native turn; raw data within a proven
/// prefix range remains preserved rather than re-admitted by this unit.
private bool hasOnlyOpaqueRetainedPrefixNativeEvidence(const ref RolloutScan scan,
	const ref LedgerTurn[] turns, size_t targetIndex)
{
	if (targetIndex >= turns.length)
		return false;
	auto targetLifecycle = lifecycleFor(scan, turns[targetIndex].id);
	if (targetLifecycle.startIndex < 0)
		return false;
	int[] owners;
	owners.length = targetLifecycle.startIndex;
	foreach (ref owner; owners)
		owner = -1;
	const size_t leadingSessionMetaEnd = scan.lines.length > 0
		&& isExactLeadingNativeSessionMeta(scan.lines[0]) ? 1 : 0;

	foreach (turnIndex; 0 .. targetIndex)
	{
		auto lifecycle = lifecycleFor(scan, turns[turnIndex].id);
		auto terminalIndex = terminalLifecycleIndex(lifecycle);
		if (lifecycle.startIndex < 0 || lifecycle.startIndex >= targetLifecycle.startIndex)
			continue;
		if (lifecycle.starts != 1 || lifecycle.completes + lifecycle.aborts != 1
			|| !lifecycle.known || terminalIndex <= lifecycle.startIndex
			|| terminalIndex >= targetLifecycle.startIndex)
			return false;
		auto start = scan.lines[lifecycle.startIndex];
		auto terminal = scan.lines[terminalIndex];
		if (!isKnownNativeLifecycleRecord(start, "task_started")
			|| start.eventTurnId != turns[turnIndex].id
			|| terminal.eventTurnId != turns[turnIndex].id
			|| !(lifecycle.completes == 1
				? isKnownNativeLifecycleRecord(terminal, "task_complete")
				: isKnownNativeLifecycleRecord(terminal, "turn_aborted")))
			return false;

		int end = targetLifecycle.startIndex;
		for (int i = lifecycle.startIndex + 1; i < targetLifecycle.startIndex; i++)
			if (scan.lines[i].probe.isTaskStarted || scan.lines[i].probe.isThreadRolledBack)
			{
				end = i;
				break;
			}
		if (terminalIndex >= end)
			return false;
		foreach (i; lifecycle.startIndex .. end)
		{
			if (!scan.lines[i].nativeActive)
				continue;
			if (owners[i] >= 0)
				return false;
			owners[i] = cast(int)turnIndex;
		}
	}

	foreach (i; 0 .. cast(size_t) targetLifecycle.startIndex)
	{
		auto line = scan.lines[i];
		if (!line.nativeActive)
			continue;
		// session_meta is opaque system context only at physical line zero. A
		// duplicate or later copy must not hide inside an opaque prefix range.
		if (i >= leadingSessionMetaEnd
			&& line.topLevelKind == RolloutTopLevelKind.sessionMeta)
			return false;
		if (owners[i] < 0 && i >= leadingSessionMetaEnd)
			return false;
	}
	return true;
}

private bool validCompletedSimple(const ref RolloutScan scan,
	const ref RawSubmission submission, const ref LedgerTurn[] turns,
	ref SO[] rawTurns)
{
	auto response = scan.lines[submission.responseIndex];
	auto event = scan.lines[submission.eventIndex];
	auto turn = turns[submission.turnIndex];
	auto rawTurn = rawTurns[submission.turnIndex];
	auto lifecycle = lifecycleFor(scan, turn.id);
	if (lifecycle.starts != 1 || lifecycle.completes != 1 || lifecycle.aborts != 0
		|| !lifecycle.known || lifecycle.startIndex >= submission.responseIndex
		|| lifecycle.completeIndex <= submission.responseIndex)
		return false;
	if (turn.id.length == 0 || turn.itemsView != "full" || turn.status != "completed"
		|| turn.error.type != SO.Type.null_ || !turn.startedAt || !turn.completedAt
		|| !turn.durationMs || hasExtras(turn.extras)
		|| !rawObjectHasExactKeys(rawTurn,
			["id", "items", "itemsView", "status", "error", "startedAt", "completedAt",
			"durationMs"]) || !rawExplicitNull(rawTurn, "error") || turn.items.length != 2)
		return false;
	string rawTurnId, rawStatus, rawView;
	SO rawItems;
	if (!rawString(rawTurn, "id", rawTurnId) || rawTurnId != turn.id
		|| !rawString(rawTurn, "status", rawStatus) || rawStatus != "completed"
		|| !rawString(rawTurn, "itemsView", rawView) || rawView != "full"
		|| !rawArray(rawTurn, "items", rawItems) || rawItems.length != 2)
		return false;
	if (!validRawUserItem(rawItems[0], turn.items[0], response, event, submission.modern))
		return false;
	auto assistantIndex = findAssistantResponse(scan, turn.id, lifecycle,
		submission.eventIndex);
	if (assistantIndex < 0)
		return false;
	auto completion = scan.lines[lifecycle.completeIndex];
	if (!isExactNativeCompletedTerminal(completion, turn.id, turn.items[1].text))
		return false;
	auto agentEventIndex = findAgentEvent(scan, lifecycle, submission.eventIndex);
	if (agentEventIndex < 0 || !onlyExpectedSimpleResponses(scan, lifecycle,
		turn.id, submission.responseIndex, submission.eventIndex, assistantIndex))
		return false;
	return validRawAgentItem(rawItems[1], turn.items[1], scan.lines[assistantIndex],
		scan.lines[agentEventIndex]);
}

private bool validCompletedCompaction(const ref RolloutScan scan, size_t turnIndex,
	const ref LedgerTurn[] turns, ref SO[] rawTurns, size_t simpleCount)
{
	if (simpleCount == 0)
		return false;
	auto turn = turns[turnIndex];
	auto rawTurn = rawTurns[turnIndex];
	auto lifecycle = lifecycleFor(scan, turn.id);
	if (turn.id.length == 0 || turn.itemsView != "full" || turn.status != "completed"
		|| turn.error.type != SO.Type.null_ || !turn.startedAt || !turn.completedAt
		|| !turn.durationMs || hasExtras(turn.extras) || turn.items.length != 1
		|| lifecycle.starts != 1 || lifecycle.completes != 1 || lifecycle.aborts != 0
		|| !lifecycle.known
		|| !rawObjectHasExactKeys(rawTurn,
			["id", "items", "itemsView", "status", "error", "startedAt", "completedAt",
			"durationMs"]) || !rawExplicitNull(rawTurn, "error"))
		return false;
	string rawTurnId, rawStatus, rawView;
	if (!rawString(rawTurn, "id", rawTurnId) || rawTurnId != turn.id
		|| !rawString(rawTurn, "status", rawStatus) || rawStatus != "completed"
		|| !rawString(rawTurn, "itemsView", rawView) || rawView != "full")
		return false;
	auto item = turn.items[0];
	SO rawItems;
	if (item.type != "contextCompaction" || item.id.length == 0 || hasExtras(item.extras)
		|| !rawArray(rawTurn, "items", rawItems) || rawItems.length != 1
		|| !rawObjectHasExactKeys(rawItems[0], ["type", "id"]))
		return false;
	string rawType, rawId;
	if (!rawString(rawItems[0], "type", rawType) || rawType != "contextCompaction"
		|| !rawString(rawItems[0], "id", rawId) || rawId != item.id)
		return false;
	auto completion = scan.lines[lifecycle.completeIndex];
	if (!isExactNativeCompactionTerminal(completion, turn.id))
		return false;

	string[] expectedReplacementTurnIds;
	foreach (replacementTurn; turns[0 .. turnIndex + 1])
		expectedReplacementTurnIds ~= replacementTurn.id;

	size_t compactedCount;
	size_t contextCompactedCount;
	size_t assistantResponseCount;
	for (int i = lifecycle.startIndex + 1; i < lifecycle.completeIndex; i++)
	{
		auto line = scan.lines[i];
		if (!line.nativeActive)
			continue;
		if (line.isCompacted)
		{
			compactedCount++;
			if (!hasExactCompactionReplacementHistory(line, expectedReplacementTurnIds))
				return false;
		}
		else if (line.probe.isEventMsg && line.payloadType == "context_compacted")
		{
			contextCompactedCount++;
			if (!line.eventKnown)
				return false;
		}
		else if (line.probe.isEventMsg
			&& (line.probe.isTaskStarted || line.payloadType == "task_complete"
				|| line.payloadType == "turn_aborted" || line.payloadType == "user_message"
				|| line.payloadType == "agent_message"))
			return false;
		else if (line.probe.isResponseItem)
		{
			if (!line.probe.isAssistantMessage || !line.metadataKnown || !line.turnIdValid
				|| line.turnId != turn.id
				|| !line.itemIdValid || !line.contentSingleOutputText
				|| line.contentText.length == 0 || line.responseUnknownFields)
				return false;
			assistantResponseCount++;
		}
	}
	return compactedCount == 1 && contextCompactedCount == 1 && assistantResponseCount == 1;
}

private enum nativeV1AbortWrapper = capturedNativeV1AbortWrapper;

private bool isExactV1AbortWrapper(const ref RolloutLineEvidence line)
{
	return isExactNativeV1AbortWrapper(line);
}

private bool validInterruptedFinal(const ref RolloutScan scan,
	const ref RawSubmission submission, const ref LedgerTurn[] turns,
	ref SO[] rawTurns)
{
	if (!submission.modern)
		return false;
	auto response = scan.lines[submission.responseIndex];
	auto event = scan.lines[submission.eventIndex];
	auto turn = turns[submission.turnIndex];
	auto rawTurn = rawTurns[submission.turnIndex];
	auto lifecycle = lifecycleFor(scan, turn.id);
	if (turn.id.length == 0 || turn.itemsView != "full" || turn.status != "interrupted"
		|| turn.error.type != SO.Type.null_ || !turn.startedAt || !turn.completedAt
		|| !turn.durationMs || hasExtras(turn.extras) || turn.items.length != 1
		|| lifecycle.starts != 1 || lifecycle.completes != 0 || lifecycle.aborts != 1
		|| !lifecycle.known || lifecycle.startIndex >= submission.responseIndex
		|| lifecycle.abortIndex <= submission.responseIndex
		|| !rawObjectHasExactKeys(rawTurn,
			["id", "items", "itemsView", "status", "error", "startedAt", "completedAt",
			"durationMs"]) || !rawExplicitNull(rawTurn, "error"))
		return false;
	SO rawItems;
	string rawTurnId, rawStatus, rawView;
	if (!rawString(rawTurn, "id", rawTurnId) || rawTurnId != turn.id
		|| !rawString(rawTurn, "status", rawStatus) || rawStatus != "interrupted"
		|| !rawString(rawTurn, "itemsView", rawView) || rawView != "full"
		|| !rawArray(rawTurn, "items", rawItems) || rawItems.length != 1
		|| !validRawUserItem(rawItems[0], turn.items[0], response, event, true))
		return false;
	int wrapperIndex = -1;
	size_t wrapperCount;
	for (int i = lifecycle.startIndex + 1; i < lifecycle.abortIndex; i++)
	{
		auto line = scan.lines[i];
		if (!line.nativeActive || !isExactV1AbortWrapper(line) || line.turnId != turn.id)
			continue;
		wrapperCount++;
		wrapperIndex = i;
	}
	if (wrapperCount != 1 || wrapperIndex + 1 != lifecycle.abortIndex
		|| scan.lines[wrapperIndex].lineNumber + 1
			!= scan.lines[lifecycle.abortIndex].lineNumber
		|| !onlyExpectedInterruptedResponses(scan, lifecycle, turn.id,
			submission.responseIndex, submission.eventIndex, wrapperIndex))
		return false;
	auto abortLine = scan.lines[lifecycle.abortIndex];
	if (!isExactNativeInterruptedTerminal(abortLine, turn.id))
		return false;
	foreach (i, ref line; scan.lines)
		if (line.nativeActive && cast(int)i > lifecycle.abortIndex
			&& (line.probe.isTaskStarted || line.isCompacted
				|| (line.probe.isEventMsg && line.payloadType == "context_compacted")))
			return false;
	return true;
}

private int findTurnForModernClient(const ref LedgerTurn[] turns, string clientId)
{
	int result = -1;
	foreach (turnIndex, ref turn; turns)
	foreach (ref item; turn.items)
	{
		if (item.type != "userMessage" || item.clientId != clientId)
			continue;
		if (result >= 0)
			return -2;
		result = cast(int)turnIndex;
	}
	return result;
}

private int findTurnById(const ref LedgerTurn[] turns, string turnId)
{
	foreach (i, ref turn; turns)
		if (turn.id == turnId)
			return cast(int)i;
	return -1;
}

private SO cloneRawValue(SO value)
{
	SO result;
	if (value.type != SO.Type.none)
		value.read(&result);
	return result;
}

package SO[] cloneRawValues(SO[] values)
{
	if (values is null)
		return null;
	SO[] result;
	result.length = values.length;
	foreach (i, value; values)
		result[i] = cloneRawValue(value);
	return result;
}

private JSONExtras cloneExtras(JSONExtras extras)
{
	JSONExtras result;
	if (extras._data !is null)
		result._data = extras._data.dup;
	return result;
}

private UserInput cloneUserInput(UserInput input)
{
	UserInput result;
	result.type = input.type;
	result.text = input.text;
	result.textElements = cloneRawValues(input.textElements);
	result.extras = cloneExtras(input.extras);
	return result;
}

private UserInput[] cloneUserInputs(UserInput[] inputs)
{
	if (inputs is null)
		return null;
	UserInput[] result;
	result.length = inputs.length;
	foreach (i, input; inputs)
		result[i] = cloneUserInput(input);
	return result;
}

private LedgerThreadItem cloneThreadItem(LedgerThreadItem item)
{
	LedgerThreadItem result;
	result.type = item.type;
	result.id = item.id;
	result.clientId = item.clientId;
	result.content = cloneUserInputs(item.content);
	result.text = item.text;
	result.phase = item.phase;
	result.memoryCitation = cloneRawValue(item.memoryCitation);
	result.extras = cloneExtras(item.extras);
	return result;
}

private LedgerThreadItem[] cloneThreadItems(LedgerThreadItem[] items)
{
	if (items is null)
		return null;
	LedgerThreadItem[] result;
	result.length = items.length;
	foreach (i, item; items)
		result[i] = cloneThreadItem(item);
	return result;
}

private LedgerTurn cloneTurn(LedgerTurn turn)
{
	LedgerTurn result;
	result.id = turn.id;
	result.items = cloneThreadItems(turn.items);
	result.itemsView = turn.itemsView;
	result.status = turn.status;
	result.error = cloneRawValue(turn.error);
	result.startedAt = turn.startedAt;
	result.completedAt = turn.completedAt;
	result.durationMs = turn.durationMs;
	result.extras = cloneExtras(turn.extras);
	return result;
}

package LedgerTurn[] cloneTurns(LedgerTurn[] turns)
{
	if (turns is null)
		return null;
	LedgerTurn[] result;
	result.length = turns.length;
	foreach (i, turn; turns)
		result[i] = cloneTurn(turn);
	return result;
}

private bool sameOptionalSO(const SO left, const SO right)
{
	if (left.type != right.type)
		return false;
	return left.type == SO.Type.none || sameSO(cast() left, cast() right);
}

private bool sameRawValues(const ref SO[] left, const ref SO[] right)
{
	if (left.length != right.length)
		return false;
	foreach (i; 0 .. left.length)
		if (!sameOptionalSO(left[i], right[i]))
			return false;
	return true;
}

private bool sameExtras(const ref JSONExtras left, const ref JSONExtras right)
{
	if (left.length != right.length)
		return false;
	foreach (key, leftValue; left)
	{
		auto rightValue = key in right;
		if (rightValue is null)
			return false;
		try
		{
			if (!sameSO(jsonParse!SO(leftValue.json), jsonParse!SO((*rightValue).json)))
				return false;
		}
		catch (Exception)
			return false;
	}
	return true;
}

private bool sameNullableLong(Nullable!long left, Nullable!long right)
{
	if (!!left != !!right)
		return false;
	return !left || left.get == right.get;
}

private bool sameUserInput(const ref UserInput left, const ref UserInput right)
{
	return left.type == right.type && left.text == right.text
		&& sameRawValues(left.textElements, right.textElements)
		&& sameExtras(left.extras, right.extras);
}

private bool sameUserInputs(const ref UserInput[] left, const ref UserInput[] right)
{
	if (left.length != right.length)
		return false;
	foreach (i; 0 .. left.length)
		if (!sameUserInput(left[i], right[i]))
			return false;
	return true;
}

private bool sameThreadItem(const ref LedgerThreadItem left, const ref LedgerThreadItem right)
{
	return left.type == right.type && left.id == right.id && left.clientId == right.clientId
		&& sameUserInputs(left.content, right.content) && left.text == right.text
		&& left.phase == right.phase && sameOptionalSO(left.memoryCitation, right.memoryCitation)
		&& sameExtras(left.extras, right.extras);
}

private bool sameThreadItems(const ref LedgerThreadItem[] left, const ref LedgerThreadItem[] right)
{
	if (left.length != right.length)
		return false;
	foreach (i; 0 .. left.length)
		if (!sameThreadItem(left[i], right[i]))
			return false;
	return true;
}

private bool sameNativeUndoTurn(const ref LedgerTurn left, const ref LedgerTurn right)
{
	return left.id == right.id && sameThreadItems(left.items, right.items)
		&& left.itemsView == right.itemsView && left.status == right.status
		&& sameOptionalSO(left.error, right.error)
		&& sameNullableLong(left.startedAt, right.startedAt)
		&& sameNullableLong(left.completedAt, right.completedAt)
		&& sameNullableLong(left.durationMs, right.durationMs)
		&& sameExtras(left.extras, right.extras);
}

private bool sameNativeUndoTurns(const ref LedgerTurn[] left, const ref LedgerTurn[] right)
{
	if (left.length != right.length)
		return false;
	foreach (i; 0 .. left.length)
		if (!sameNativeUndoTurn(left[i], right[i]))
			return false;
	return true;
}

package bool validNativeUndoPlan(const ref NativeUndoPlan plan, out string diagnostic)
{
	if (plan.numTurns == 0)
	{
		diagnostic = "native undo plan has a zero turn count";
		return false;
	}
	if (plan.preTurns.length != plan.preRawTurns.length
		|| plan.retainedPrefix.length != plan.retainedRawPrefix.length)
	{
		diagnostic = "native undo plan typed and raw vectors differ in length";
		return false;
	}
	if (plan.targetLedgerIndex != plan.retainedPrefix.length
		|| plan.targetLedgerIndex >= plan.preTurns.length)
	{
		diagnostic = "native undo plan target index does not match its retained prefix";
		return false;
	}
	if (plan.numTurns > plan.preTurns.length - plan.retainedPrefix.length
		|| plan.retainedPrefix.length + plan.numTurns != plan.preTurns.length)
	{
		diagnostic = "native undo plan count does not match its pre-rollback vector";
		return false;
	}
	if (plan.targetTurnId.length == 0
		|| plan.targetTurnId != plan.preTurns[plan.targetLedgerIndex].id)
	{
		diagnostic = "native undo plan target id does not match its target turn";
		return false;
	}
	auto expectedTypedPrefix = plan.preTurns[0 .. plan.targetLedgerIndex];
	auto expectedRawPrefix = plan.preRawTurns[0 .. plan.targetLedgerIndex];
	if (!sameNativeUndoTurns(plan.retainedPrefix, expectedTypedPrefix)
		|| !sameRawValues(plan.retainedRawPrefix, expectedRawPrefix))
	{
		diagnostic = "native undo plan retained prefix does not match its pre-rollback vector";
		return false;
	}
	return true;
}

/// Inspect only the post-dispatch rollout window. This pure seam makes marker
/// failures deterministic while the live operation retains bounded polling.
package NativeUndoMarkerVerification verifyNativeUndoMarkerWindow(string content,
	size_t offset, uint expectedNumTurns)
{
	import std.string : lineSplitter;

	NativeUndoMarkerVerification result;
	result.status = NativeUndoMarkerVerificationStatus.waiting;
	if (content.length < offset)
	{
		result.status = NativeUndoMarkerVerificationStatus.failure;
		result.diagnostic = "retained Codex rollout file shrank after rollback dispatch";
		return result;
	}
	foreach (line; content[offset .. $].lineSplitter)
	{
		auto marker = classifyNativeRollbackMarker(line);
		if (marker.status == NativeRollbackMarkerStatus.none)
			continue;
		if (marker.status == NativeRollbackMarkerStatus.malformed)
		{
			result.status = NativeUndoMarkerVerificationStatus.failure;
			result.diagnostic = "observed a malformed Codex thread_rolled_back marker";
			return result;
		}
		if (marker.numTurns != expectedNumTurns)
		{
			result.status = NativeUndoMarkerVerificationStatus.failure;
			result.diagnostic = "observed a conflicting Codex thread_rolled_back marker count";
			return result;
		}
		result.status = NativeUndoMarkerVerificationStatus.verified;
		return result;
	}
	return result;
}

package bool validNativeUndoResponse(const ref ThreadRollbackResult response,
	const ref NativeUndoPlan plan, string liveThreadId, out string diagnostic)
{
	if (response.thread.id != liveThreadId)
	{
		diagnostic = "thread/rollback returned a different thread id";
		return false;
	}
	auto responseThread = response.thread;
	auto responseRawThread = cast() response.rawThread;
	if (!validThreadStatus(responseThread, responseRawThread))
	{
		diagnostic = "thread/rollback did not return the exact idle status shape";
		return false;
	}
	SO rawTurns;
	if (!rawArray(responseRawThread, "turns", rawTurns)
		|| response.thread.turns.length != plan.retainedPrefix.length
		|| response.rawTurns.length != plan.retainedRawPrefix.length
		|| rawTurns.length != response.rawTurns.length)
	{
		diagnostic = "thread/rollback returned an incomplete retained turn vector";
		return false;
	}
	if (!sameNativeUndoTurns(response.thread.turns, plan.retainedPrefix))
	{
		diagnostic = "thread/rollback typed retained turn vector differs from the plan";
		return false;
	}
	if (!sameRawValues(response.rawTurns, plan.retainedRawPrefix))
	{
		diagnostic = "thread/rollback raw retained turn vector differs from the plan";
		return false;
	}
	return true;
}

/// Pure native association/admission/count logic. It consumes the one active
/// rollout scan and a freshly decoded materialized ledger; it never reads a
/// path, sends RPC, or derives a count from raw history.
package NativeUndoPlan prepareNativeUndoPlan(HistoryBoundary boundary,
	const ref RolloutScan scan, ref ThreadReadResult read, string liveThreadId)
{
	if (boundary.kind != HistoryBoundaryKind.user)
		refuse(NativeUndoPreparationRefusalCategory.invalidBoundary,
			"native undo requires a user history boundary");
	int targetLine;
	if (!parseLineAnchor(boundary.anchor, targetLine))
		refuse(NativeUndoPreparationRefusalCategory.invalidBoundary,
			"native undo requires a nonempty exact line:N boundary anchor");
	if (read.thread.id != liveThreadId)
		refuse(NativeUndoPreparationRefusalCategory.providerData,
			"thread/read returned a different thread id");
	if (!validThreadStatus(read.thread, read.rawThread))
		refuse(NativeUndoPreparationRefusalCategory.threadStatus,
			"thread/read did not return the exact idle status shape");
	if (read.thread.turns.length == 0 || read.thread.turns.length != read.rawTurns.length)
		refuse(NativeUndoPreparationRefusalCategory.ledger,
			"thread/read typed and raw turn vectors are absent or differ in length");

	bool[string] turnIds;
	foreach (i, ref turn; read.thread.turns)
	{
		if (turn.id.length == 0 || turn.id in turnIds || read.rawTurns[i].type != SO.Type.object)
			refuse(NativeUndoPreparationRefusalCategory.ledger,
				"thread/read contains an empty, duplicate, or malformed turn id");
		turnIds[turn.id] = true;
	}

	int targetResponse = -1;
	size_t targetMatches;
	foreach (i, ref line; scan.lines)
	{
		if (line.lineNumber != targetLine)
			continue;
		if (isEligibleRawSubmission(line))
		{
			targetMatches++;
			targetResponse = cast(int)i;
		}
	}
	if (targetMatches != 1)
		refuse(NativeUndoPreparationRefusalCategory.targetUnavailable,
			"clicked line does not identify exactly one active eligible submitted user record");
	foreach (i, ref line; scan.lines)
		if (cast(int)i >= targetResponse && line.probe.isThreadRolledBack && !line.eventKnown)
			refuse(NativeUndoPreparationRefusalCategory.association,
				"candidate suffix contains a malformed rollback marker");

	RawSubmission[] submissions;
	bool[string] rawTurnIds;
	bool[string] rawClientIds;
	foreach (i, ref line; scan.lines)
	{
		if (!line.nativeActive || !line.probe.isUserMessage || cast(int)i < targetResponse)
			continue;
		if (line.userClassification != CodexUserMessageLineClassification.normal)
		{
			if (line.userClassification != CodexUserMessageLineClassification.turnAborted)
				refuse(NativeUndoPreparationRefusalCategory.association,
					"candidate suffix contains a contextual or future role-user record");
			continue;
		}
		if (!isEligibleRawSubmission(line))
			refuse(NativeUndoPreparationRefusalCategory.association,
				"candidate suffix contains a malformed or unsupported user response item");
		if (line.immediateUserEventIndex < 0)
			refuse(NativeUndoPreparationRefusalCategory.association,
				"submitted user response item is not immediately followed by user_message");
		auto event = scan.lines[line.immediateUserEventIndex];
		if (!isExactRawUserEvent(event, line))
			refuse(NativeUndoPreparationRefusalCategory.association,
				"raw user response and adjacent user_message do not have the admitted shape");
		if (line.turnId in rawTurnIds)
			refuse(NativeUndoPreparationRefusalCategory.association,
				"candidate suffix reuses a raw turn id");
		rawTurnIds[line.turnId] = true;

		RawSubmission submission;
		submission.responseIndex = cast(int)i;
		submission.eventIndex = line.immediateUserEventIndex;
		submission.modern = event.eventClientIdPresent;
		if (submission.modern)
		{
			if (!event.eventClientIdValid || event.eventClientId in rawClientIds)
				refuse(NativeUndoPreparationRefusalCategory.association,
					"candidate suffix has an empty, malformed, or reused client id");
			rawClientIds[event.eventClientId] = true;
			auto turnIndex = findTurnForModernClient(read.thread.turns, event.eventClientId);
			if (turnIndex < 0 || read.thread.turns[turnIndex].id != line.turnId)
				refuse(NativeUndoPreparationRefusalCategory.association,
					"modern raw user identity does not map uniquely to the same materialized turn");
			submission.turnIndex = cast(size_t)turnIndex;
		}
		else
		{
			auto turnIndex = findTurnById(read.thread.turns, line.turnId);
			if (turnIndex < 0)
				refuse(NativeUndoPreparationRefusalCategory.association,
					"legacy raw user turn is absent from the materialized ledger");
			submission.turnIndex = cast(size_t)turnIndex;
		}
		submissions ~= submission;
	}

	int targetSubmission = -1;
	size_t previousTurnIndex;
	bool havePreviousTurnIndex;
	foreach (i, ref submission; submissions)
	{
		if (havePreviousTurnIndex && submission.turnIndex <= previousTurnIndex)
			refuse(NativeUndoPreparationRefusalCategory.association,
				"raw submitted-user order does not match the materialized turn vector");
		previousTurnIndex = submission.turnIndex;
		havePreviousTurnIndex = true;
		if (submission.responseIndex == targetResponse)
			targetSubmission = cast(int)i;
	}
	if (targetSubmission < 0)
		refuse(NativeUndoPreparationRefusalCategory.targetUnavailable,
			"clicked raw user record was not associated with a materialized turn");
	auto targetIndex = submissions[targetSubmission].turnIndex;
	foreach (i; 0 .. targetIndex)
		if (!isFullView(read.thread.turns[i], read.rawTurns[i]))
			refuse(NativeUndoPreparationRefusalCategory.ledger,
				"a retained prefix turn does not have a full materialized view");
	if (!hasOnlyOpaqueRetainedPrefixNativeEvidence(scan, read.thread.turns, targetIndex))
		refuse(NativeUndoPreparationRefusalCategory.unsupportedSuffix,
			"live native lifecycle evidence before the selected turn is not an opaque retained prefix");
	foreach (ref submission; submissions)
		if (submission.turnIndex < targetIndex)
			refuse(NativeUndoPreparationRefusalCategory.association,
				"a candidate raw user mapped before the selected materialized turn");

	size_t simpleCount;
	size_t compactionCount;
	size_t usedSubmissions;
	bool interrupted;
	bool[string] suffixItemIds;
	foreach (turnIndex; targetIndex .. read.thread.turns.length)
	{
		int submissionIndex = -1;
		foreach (i, ref submission; submissions)
			if (submission.turnIndex == turnIndex)
			{
				if (submissionIndex >= 0)
					refuse(NativeUndoPreparationRefusalCategory.association,
						"multiple raw users map to one materialized turn");
				submissionIndex = cast(int)i;
		}
		auto turn = read.thread.turns[turnIndex];
		foreach (ref item; turn.items)
		{
			if (item.id.length == 0 || item.id in suffixItemIds)
				refuse(NativeUndoPreparationRefusalCategory.unsupportedSuffix,
					"candidate suffix contains an empty or reused materialized item id");
			suffixItemIds[item.id] = true;
		}
		if (turn.status == "completed" && submissionIndex >= 0)
		{
			if (!validCompletedSimple(scan, submissions[submissionIndex], read.thread.turns,
				read.rawTurns))
				refuse(NativeUndoPreparationRefusalCategory.unsupportedSuffix,
					"completed native turn does not match the simple one-user grammar");
			simpleCount++;
			usedSubmissions++;
			continue;
		}
		if (turn.status == "completed" && submissionIndex < 0
			&& turnIndex == read.thread.turns.length - 1 && compactionCount == 0
			&& validCompletedCompaction(scan, turnIndex, read.thread.turns, read.rawTurns,
				simpleCount))
		{
			compactionCount++;
			continue;
		}
		if (turn.status == "interrupted" && submissionIndex >= 0
			&& turnIndex == read.thread.turns.length - 1 && compactionCount == 0
			&& validInterruptedFinal(scan, submissions[submissionIndex], read.thread.turns,
				read.rawTurns))
		{
			interrupted = true;
			usedSubmissions++;
			continue;
		}
		refuse(NativeUndoPreparationRefusalCategory.unsupportedSuffix,
			"candidate suffix does not match an admitted native undo grammar");
	}
	if (usedSubmissions != submissions.length || (simpleCount == 0 && !interrupted))
		refuse(NativeUndoPreparationRefusalCategory.unsupportedSuffix,
			"raw user evidence and materialized suffix do not form a closed grammar");
	if (!validClosedRawSuffix(scan, submissions, read.thread.turns, targetIndex))
		refuse(NativeUndoPreparationRefusalCategory.unsupportedSuffix,
			"candidate raw suffix contains an unclaimed or unsupported physical record");

	NativeUndoPlan plan;
	plan.numTurns = checkedNativeUndoCount(read.thread.turns.length, targetIndex);
	plan.preTurns = cloneTurns(read.thread.turns);
	plan.preRawTurns = cloneRawValues(read.rawTurns);
	plan.retainedPrefix = cloneTurns(read.thread.turns[0 .. targetIndex]);
	plan.retainedRawPrefix = cloneRawValues(read.rawTurns[0 .. targetIndex]);
	plan.targetLedgerIndex = targetIndex;
	plan.targetTurnId = read.thread.turns[targetIndex].id;
	if (submissions[targetSubmission].modern)
		plan.targetClientId = scan.lines[submissions[targetSubmission].eventIndex].eventClientId;
	return plan;
}

unittest
{
	import std.string : lineSplitter, replace;

	enum nativeThreadId = "native-undo-test-thread";
	enum v1AbortWrapper = nativeV1AbortWrapper;
	assert(verifyNativeUndoMarkerWindow(
		`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1},"payload":{"type":"task_complete"}}`,
		0, 1).status == NativeUndoMarkerVerificationStatus.failure);
	assert(checkedNativeUndoCount(1, 0) == 1);
	int parsedLine;
	assert(parseLineAnchor("line:1", parsedLine) && parsedLine == 1);
	foreach (anchor; ["", "line:", "line:0", "line:-1", "line:01", "line:1x",
		"other:1", "line:999999999999999999999999999999999999"])
		assert(!parseLineAnchor(anchor, parsedLine));
	bool invalidIndexRefused;
	try checkedNativeUndoCount(0, 0);
	catch (NativeUndoPreparationRefusal e)
		invalidIndexRefused = e.category == NativeUndoPreparationRefusalCategory.arithmetic;
	assert(invalidIndexRefused);
	static if (size_t.max > uint.max)
	{
		bool overflowRefused;
		try checkedNativeUndoCount(cast(size_t)uint.max + 1, 0);
		catch (NativeUndoPreparationRefusal e)
			overflowRefused = e.category == NativeUndoPreparationRefusalCategory.arithmetic;
		assert(overflowRefused);
	}

	string joinParts(scope const string[] values, string separator = "\n")
	{
		string result;
		foreach (i, value; values)
		{
			if (i > 0)
				result ~= separator;
			result ~= value;
		}
		return result;
	}

	string taskStarted(string turnId)
	{
		return `{"type":"event_msg","payload":{"type":"task_started","turn_id":`
			~ toJson(turnId)
			~ `,"started_at":1,"model_context_window":1,"collaboration_mode_kind":"default"}}`;
	}

	string taskComplete(string turnId, string text)
	{
		return `{"type":"event_msg","payload":{"type":"task_complete","turn_id":`
			~ toJson(turnId) ~ `,"last_agent_message":` ~ toJson(text)
			~ `,"completed_at":1,"duration_ms":1,"time_to_first_token_ms":1}}`;
	}

	string compactionComplete(string turnId)
	{
		return `{"type":"event_msg","payload":{"type":"task_complete","turn_id":`
			~ toJson(turnId)
			~ `,"last_agent_message":null,"completed_at":1,"duration_ms":1}}`;
	}

	string userResponse(string turnId, string text)
	{
		return `{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":`
			~ toJson(text) ~ `}],"internal_chat_message_metadata_passthrough":{"turn_id":`
			~ toJson(turnId) ~ `}}}`;
	}

	string assistantResponse(string turnId, string text, string itemId)
	{
		return `{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":`
			~ toJson(text) ~ `}],"internal_chat_message_metadata_passthrough":{"turn_id":`
			~ toJson(turnId) ~ `},"id":` ~ toJson(itemId) ~ `}}`;
	}

	string userEvent(string text, string clientId, bool modern = true,
		string images = "[]", string localImages = "[]", string textElements = "[]")
	{
		string result = `{"type":"event_msg","payload":{"type":"user_message"`;
		if (modern)
			result ~= `,"client_id":` ~ toJson(clientId);
		result ~= `,"message":` ~ toJson(text) ~ `,"images":` ~ images
			~ `,"local_images":` ~ localImages ~ `,"text_elements":` ~ textElements ~ `}}`;
		return result;
	}

	string agentEvent(string text)
	{
		return `{"type":"event_msg","payload":{"type":"agent_message","message":`
			~ toJson(text) ~ `,"phase":null,"memory_citation":null}}`;
	}

	string capturedTokenCountInfo()
	{
		return `{"total_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":42,"reasoning_output_tokens":0,"total_tokens":62},"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":6494},"model_context_window":258400}`;
	}

	string capturedNullRateLimitsTokenCount()
	{
		return `{"type":"event_msg","payload":{"type":"token_count","info":`
			~ capturedTokenCountInfo() ~ `,"rate_limits":null}}`;
	}

	string capturedObjectRateLimitsTokenCount()
	{
		return `{"type":"event_msg","payload":{"type":"token_count","info":`
			~ capturedTokenCountInfo()
			~ `,"rate_limits":{"limit_id":"codex","limit_name":null,"primary":null,"secondary":null,"credits":null,"individual_limit":null,"plan_type":null,"rate_limit_reached_type":null}}}`;
	}

	string threadSettingsApplied(string settings)
	{
		return `{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":`
			~ settings ~ `}}`;
	}

	string capturedThreadSettingsObject()
	{
		return `{"model":"codex-mini-latest","model_provider_id":"cydo-mock","approval_policy":"never","approvals_reviewer":"user","permission_profile":{"type":"external","network":"enabled"},"cwd":"/workspace","reasoning_summary":"auto","personality":"pragmatic","collaboration_mode":{"mode":"default","settings":{"model":"codex-mini-latest","reasoning_effort":null,"developer_instructions":null}}}`;
	}

	string capturedThreadSettingsApplied()
	{
		return threadSettingsApplied(capturedThreadSettingsObject());
	}

	string capturedWorldState()
	{
		return `{"type":"world_state","payload":{"full":true,"state":{"agents_md":{},"apps_instructions":false,"environments":{"environments":{"local":{"cwd":"/workspace","status":"available","shell":"zsh"}},"current_date":"2026-08-06","timezone":"Etc/UTC","filesystem":"<filesystem/>"},"plugins_instructions":false,"skills":{"includeInstructions":true}}}}`;
	}

	// The outer envelope and opaque payload structure are from the duplicate
	// capture's first physical record. Native admission intentionally leaves
	// the provider-owned payload uninterpreted.
	string capturedLeadingSessionMeta()
	{
		return `{"timestamp":"2026-08-06T11:26:17.667Z","type":"session_meta","payload":{"session_id":"019fd6d2-f60f-7850-8924-e3566e56f9e6","id":"019fd6d2-f60f-7850-8924-e3566e56f9e6","timestamp":"2026-08-06T11:26:17.622Z","cwd":"/workspace","originator":"cydo-undo-spike","cli_version":"0.144.1","source":"vscode","model_provider":"cydo-mock","base_instructions":{"text":"captured opaque instructions"},"context_window":{"window_id":"019fd6d2-f60f-7850-8924-e36303f07a64"},"history_mode":"legacy","git":{}}}`;
	}

	string capturedTurnContext(string turnId)
	{
		return `{"type":"turn_context","payload":{"turn_id":` ~ toJson(turnId)
			~ `,"cwd":"/workspace","workspace_roots":["/workspace"],"current_date":"2026-08-06","timezone":"Etc/UTC","approval_policy":"never","approvals_reviewer":"user","sandbox_policy":{"type":"external-sandbox","network_access":"enabled"},"permission_profile":{"type":"external","network":"enabled"},"model":"gpt-5.6-sol","comp_hash":"3000","personality":"pragmatic","collaboration_mode":{"mode":"default","settings":{"model":"gpt-5.6-sol","reasoning_effort":null,"developer_instructions":null}},"multi_agent_version":"v2","multi_agent_mode":"explicitRequestOnly","realtime_active":false,"summary":"auto"}}`;
	}

	string turnAborted(string turnId)
	{
		return `{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":`
			~ toJson(turnId) ~ `,"reason":"interrupted","completed_at":1,"duration_ms":1}}`;
	}

	string turnAbortedWithReason(string turnId, string reason)
	{
		return `{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":`
			~ toJson(turnId) ~ `,"reason":` ~ toJson(reason)
			~ `,"completed_at":1,"duration_ms":1}}`;
	}

	string simpleRollout(string turnId, string clientId, string text, string answer,
		bool modern = true, string eventClientId = null, string images = "[]",
		string localImages = "[]", string textElements = "[]")
	{
		if (eventClientId is null)
			eventClientId = clientId;
		return joinParts([
			taskStarted(turnId),
			userResponse(turnId, text),
			userEvent(text, eventClientId, modern, images, localImages, textElements),
			assistantResponse(turnId, answer, "raw-agent-" ~ turnId),
			agentEvent(answer),
			taskComplete(turnId, answer),
		]);
	}

	string simpleRolloutWithPreTerminalTelemetry(string turnId, string clientId,
		string text, string answer, string telemetry)
	{
		auto terminal = taskComplete(turnId, answer);
		auto rollout = simpleRollout(turnId, clientId, text, answer);
		return rollout[0 .. $ - terminal.length] ~ telemetry ~ "\n" ~ terminal;
	}

	string simpleTurn(string turnId, string clientId, string text, string answer,
		bool modern = true)
	{
		string user = `{"type":"userMessage","id":` ~ toJson("user-item-" ~ turnId);
		if (modern)
			user ~= `,"clientId":` ~ toJson(clientId);
		user ~= `,"content":[{"type":"text","text":` ~ toJson(text)
			~ `,"text_elements":[]}]}`;
		return `{"id":` ~ toJson(turnId) ~ `,"items":[` ~ user
			~ `,{"type":"agentMessage","id":` ~ toJson("agent-item-" ~ turnId)
			~ `,"text":` ~ toJson(answer)
			~ `,"phase":null,"memoryCitation":null}],"itemsView":"full","status":"completed","error":null,"startedAt":1,"completedAt":1,"durationMs":1}`;
	}

	string compactionTurn(string turnId)
	{
		return `{"id":` ~ toJson(turnId)
			~ `,"items":[{"type":"contextCompaction","id":` ~ toJson("compact-item-" ~ turnId)
			~ `}],"itemsView":"full","status":"completed","error":null,"startedAt":1,"completedAt":1,"durationMs":1}`;
	}

	string compactedLine(string compactionTurnId, scope const string[] replacementTurnIds)
	{
		string[] history;
		foreach (turnId; replacementTurnIds)
			history ~= `{"type":"message","role":"user","content":[{"type":"input_text","text":"replacement"}],"internal_chat_message_metadata_passthrough":{"turn_id":`
				~ toJson(turnId) ~ `}}`;
		return `{"type":"compacted","payload":{"message":"summary","replacement_history":[`
			~ joinParts(history, ",")
			~ `],"window_number":1,"first_window_id":"first","previous_window_id":"previous","window_id":`
			~ toJson(compactionTurnId) ~ `}}`;
	}

	string compactionRollout(string compactionTurnId,
		scope const string[] replacementTurnIds)
	{
	return joinParts([
		taskStarted(compactionTurnId),
		assistantResponse(compactionTurnId, "Conversation summary: previous context compacted.",
			"raw-agent-" ~ compactionTurnId),
		compactedLine(compactionTurnId, replacementTurnIds),
			`{"type":"event_msg","payload":{"type":"context_compacted"}}`,
		compactionComplete(compactionTurnId),
		]);
	}

	string ledger(scope const string[] turns, string threadId = nativeThreadId)
	{
		return `{"thread":{"id":` ~ toJson(threadId)
			~ `,"status":{"type":"idle"},"turns":[` ~ joinParts(turns, ",") ~ `]}}`;
	}

	string ledgerWithStatus(string status)
	{
		return `{"thread":{"id":` ~ toJson(nativeThreadId) ~ `,"status":` ~ status
			~ `,"turns":[` ~ simpleTurn("U1", "client-one", "prompt", "answer") ~ `]}}`;
	}

	struct PositiveCase
	{
		string name;
		string rollout;
		string nativeLedger;
		string anchor;
		uint numTurns;
		string[] retainedTurnIds;
		string targetTurnId;
		string targetClientId;
		bool hasTargetClientId;
	}

	auto duplicateRollout = joinParts([
		simpleRollout("U1", "client-duplicate-one", "same prompt", "answer one"),
		simpleRollout("U2", "client-duplicate-two", "same prompt", "answer two"),
	]);
	auto duplicateLedger = ledger([
		simpleTurn("U1", "client-duplicate-one", "same prompt", "answer one"),
		simpleTurn("U2", "client-duplicate-two", "same prompt", "answer two"),
	]);
	auto capturedSessionMetaFirstRollout = joinParts([
		capturedLeadingSessionMeta(),
		simpleRollout("U1", "client-one", "prompt", "answer"),
	]);
	auto capturedSessionMetaLaterRollout = joinParts([
		capturedLeadingSessionMeta(),
		duplicateRollout,
	]);

	auto compactionFixtureRollout = joinParts([
		simpleRollout("U1", "client-one", "prompt one", "answer one"),
		simpleRollout("U2", "client-two", "prompt two", "answer two"),
		simpleRollout("U3", "client-three", "prompt three", "answer three"),
		compactionRollout("C", ["U1", "U2", "U3", "C"]),
	]);
	auto compactionFixtureLedger = ledger([
		simpleTurn("U1", "client-one", "prompt one", "answer one"),
		simpleTurn("U2", "client-two", "prompt two", "answer two"),
		simpleTurn("U3", "client-three", "prompt three", "answer three"),
		compactionTurn("C"),
	]);
	auto postRollbackCompactionRollout = compactionFixtureRollout ~ "\n"
		~ `{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":2}}`;
	auto postRollbackCompactionLedger = ledger([
		simpleTurn("U1", "client-one", "prompt one", "answer one"),
		simpleTurn("U2", "client-two", "prompt two", "answer two"),
	]);
	auto ordinaryNullTelemetryAfterRollback = joinParts([
		simpleRollout("U1", "client-one", "prompt one", "answer one"),
		simpleRollout("U2", "client-two", "prompt two", "answer two"),
		capturedNullRateLimitsTokenCount(),
		`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`,
	]);
	auto ordinaryNullTelemetryAfterRollbackLedger = ledger([
		simpleTurn("U1", "client-one", "prompt one", "answer one"),
	]);
	auto compactionNullTelemetryAfterRollback = joinParts([
		simpleRollout("U1", "client-one", "prompt one", "answer one"),
		compactionRollout("C", ["U1", "C"]),
		capturedNullRateLimitsTokenCount(),
		`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`,
	]);
	auto compactionNullTelemetryAfterRollbackLedger = ledger([
		simpleTurn("U1", "client-one", "prompt one", "answer one"),
	]);
	auto ordinaryObjectTelemetryAfterRollback = joinParts([
		simpleRollout("U1", "client-one", "prompt one", "answer one"),
		simpleRolloutWithPreTerminalTelemetry("U2", "client-two", "prompt two",
			"answer two", capturedObjectRateLimitsTokenCount()),
		`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`,
	]);
	auto ordinaryObjectTelemetryAfterRollbackLedger = ledger([
		simpleTurn("U1", "client-one", "prompt one", "answer one"),
	]);
	auto compactionObjectTelemetryAfterRollback = joinParts([
		simpleRollout("U1", "client-one", "prompt one", "answer one"),
		simpleRollout("U2", "client-two", "prompt two", "answer two"),
		simpleRollout("U3", "client-three", "prompt three", "answer three"),
		compactionRollout("C", ["U1", "U2", "U3", "C"]),
		capturedObjectRateLimitsTokenCount(),
		`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":2}}`,
	]);
	auto compactionObjectTelemetryAfterRollbackLedger = ledger([
		simpleTurn("U1", "client-one", "prompt one", "answer one"),
		simpleTurn("U2", "client-two", "prompt two", "answer two"),
	]);

	auto interruptedRollout = joinParts([
		simpleRollout("U1", "client-retained", "retained prompt", "retained answer"),
		joinParts([
			taskStarted("I"),
			userResponse("I", "interrupted prompt"),
			userEvent("interrupted prompt", "client-interrupted"),
			userResponse("I", v1AbortWrapper),
			turnAborted("I"),
		]),
	]);
	auto interruptedLedger = ledger([
		simpleTurn("U1", "client-retained", "retained prompt", "retained answer"),
		`{"id":"I","items":[{"type":"userMessage","id":"user-item-I","clientId":"client-interrupted","content":[{"type":"text","text":"interrupted prompt","text_elements":[]}]}],"itemsView":"full","status":"interrupted","error":null,"startedAt":1,"completedAt":1,"durationMs":1}`,
	]);
	auto interruptedObjectTelemetryAfterRollback = joinParts([
		simpleRollout("U1", "client-retained", "retained prompt", "retained answer"),
		joinParts([
			taskStarted("I"),
			userResponse("I", "interrupted prompt"),
			userEvent("interrupted prompt", "client-interrupted"),
			userResponse("I", v1AbortWrapper),
			turnAborted("I"),
		]),
		capturedObjectRateLimitsTokenCount(),
		`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`,
	]);
	auto interruptedObjectTelemetryAfterRollbackLedger = ledger([
		simpleTurn("U1", "client-retained", "retained prompt", "retained answer"),
	]);
	auto completeWithThreadSettings = simpleRollout("U1", "client-one", "prompt", "answer")
		~ "\n" ~ capturedThreadSettingsApplied();

	auto legacyRollout = simpleRollout("L", "", "legacy prompt", "legacy answer", false);
	auto legacyLedger = ledger([
		simpleTurn("L", "", "legacy prompt", "legacy answer", false),
	]);
	string initialContextRolloutWithDeveloperContent(string developerContent)
	{
		return joinParts([
			taskStarted("CTX"),
			capturedWorldState(),
			capturedTurnContext("CTX"),
			`{"type":"response_item","payload":{"type":"message","role":"developer","content":`
				~ developerContent
				~ `,"internal_chat_message_metadata_passthrough":{"turn_id":"CTX"}}}`,
			`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>initial context</environment_context>"}],"internal_chat_message_metadata_passthrough":{"turn_id":"CTX"}}}`,
			userResponse("CTX", "first prompt"),
			userEvent("first prompt", "first-client"),
			assistantResponse("CTX", "first answer", "raw-agent-CTX"),
			agentEvent("first answer"),
			taskComplete("CTX", "first answer"),
		]);
	}
	enum singleDeveloperContextContent = `[{"type":"input_text","text":"developer context"}]`;
	enum multipleDeveloperContextContent = `[{"type":"input_text","text":"developer context"},{"type":"input_text","text":"additional developer context"}]`;
	auto initialContextRollout = initialContextRolloutWithDeveloperContent(
		singleDeveloperContextContent);
	auto multipleDeveloperContextRollout = initialContextRolloutWithDeveloperContent(
		multipleDeveloperContextContent);
	auto initialContextLedger = ledger([
		simpleTurn("CTX", "first-client", "first prompt", "first answer"),
	]);

	PositiveCase[] positives = [
		PositiveCase("captured leading session_meta permits first target",
			capturedSessionMetaFirstRollout, ledger([
				simpleTurn("U1", "client-one", "prompt", "answer"),
			]), "line:3", 1, [], "U1", "client-one", true),
		PositiveCase("captured leading session_meta permits later target",
			capturedSessionMetaLaterRollout, duplicateLedger, "line:9", 1, ["U1"],
			"U2", "client-duplicate-two", true),
		PositiveCase("later duplicate prompt binds its distinct client id", duplicateRollout,
			duplicateLedger, "line:8", 1, ["U1"], "U2", "client-duplicate-two", true),
		PositiveCase("trailing compaction is counted with target U3", compactionFixtureRollout,
			compactionFixtureLedger, "line:14", 2, ["U1", "U2"], "U3", "client-three", true),
		PositiveCase("marker rollback counts terminal compaction as a native turn",
			postRollbackCompactionRollout, postRollbackCompactionLedger, "line:8", 1,
			["U1"], "U2", "client-two", true),
		PositiveCase("ordinary null-rate-limits rollback leaves U1 for the next undo",
			ordinaryNullTelemetryAfterRollback, ordinaryNullTelemetryAfterRollbackLedger,
			"line:2", 1, [], "U1", "client-one", true),
		PositiveCase("compaction null-rate-limits rollback leaves U1 for the next undo",
			compactionNullTelemetryAfterRollback, compactionNullTelemetryAfterRollbackLedger,
			"line:2", 1, [], "U1", "client-one", true),
		PositiveCase("ordinary object-rate-limits rollback leaves U1 for the next undo",
			ordinaryObjectTelemetryAfterRollback,
			ordinaryObjectTelemetryAfterRollbackLedger, "line:2", 1, [], "U1",
			"client-one", true),
		PositiveCase("captured cross-compaction object telemetry retires U3 and C",
			compactionObjectTelemetryAfterRollback,
			compactionObjectTelemetryAfterRollbackLedger, "line:8", 1, ["U1"], "U2",
			"client-two", true),
		PositiveCase("terminal v1 interrupted turn is one native turn", interruptedRollout,
			interruptedLedger, "line:8", 1, ["U1"], "I", "client-interrupted", true),
		PositiveCase("interrupted object telemetry rollback leaves U1 for next undo",
			interruptedObjectTelemetryAfterRollback,
			interruptedObjectTelemetryAfterRollbackLedger, "line:2", 1, [], "U1",
			"client-retained", true),
		PositiveCase("captured thread settings remain admitted post-terminal evidence",
			completeWithThreadSettings, ledger([
				simpleTurn("U1", "client-one", "prompt", "answer"),
			]), "line:2", 1, [], "U1",
			"client-one", true),
		PositiveCase("legacy completed triangle admits absent client ids", legacyRollout,
			legacyLedger, "line:2", 1, [], "L", "", false),
		PositiveCase("initial system context stays outside the submitted suffix",
			initialContextRollout, initialContextLedger, "line:6", 1, [], "CTX",
			"first-client", true),
		PositiveCase("multiple developer context blocks stay outside the submitted suffix",
			multipleDeveloperContextRollout, initialContextLedger, "line:6", 1, [], "CTX",
			"first-client", true),
	];

	foreach (ref test; positives)
	{
		auto scan = scanRollout(test.rollout);
		auto read = jsonParse!ThreadReadResult(test.nativeLedger);
		NativeUndoPlan plan;
		try
			plan = prepareNativeUndoPlan(
				HistoryBoundary(test.anchor, HistoryBoundaryKind.user, null), scan, read,
				nativeThreadId);
		catch (NativeUndoPreparationRefusal e)
			assert(false, test.name ~ ": " ~ e.diagnostic);
		assert(plan.numTurns == test.numTurns, test.name);
		assert(plan.targetLedgerIndex == read.thread.turns.length - test.numTurns, test.name);
		assert(plan.targetTurnId == test.targetTurnId, test.name);
		assert(plan.retainedPrefix.length == test.retainedTurnIds.length, test.name);
		assert(plan.retainedRawPrefix.length == test.retainedTurnIds.length, test.name);
		foreach (i, turnId; test.retainedTurnIds)
		{
			assert(plan.retainedPrefix[i].id == turnId, test.name);
			assert(sameSO(plan.retainedRawPrefix[i], read.rawTurns[i]), test.name);
		}
		assert(plan.preTurns.length == read.thread.turns.length
			&& plan.preRawTurns.length == read.rawTurns.length, test.name);
		foreach (i; 0 .. read.rawTurns.length)
			assert(sameSO(plan.preRawTurns[i], read.rawTurns[i]), test.name);
		if (test.hasTargetClientId)
			assert(!plan.targetClientId.isNull
				&& plan.targetClientId.get == test.targetClientId, test.name);
		else
			assert(plan.targetClientId.isNull, test.name);
	}

	// Plan snapshots own all nested typed and raw storage. Mutating the fresh
	// thread/read result or any one snapshot view must not alter another view.
	string rawInputText(SO rawTurn)
	{
		string text;
		assert(rawString(rawTurn["items"][0]["content"][0], "text", text));
		return text;
	}

	void setRawInputText(ref SO rawTurn, string text)
	{
		rawTurn["items"][0]["content"][0]["text"] = text;
	}

	auto isolationScan = scanRollout(duplicateRollout);
	auto isolationRead = jsonParse!ThreadReadResult(duplicateLedger);
	auto isolationPlan = prepareNativeUndoPlan(
		HistoryBoundary("line:8", HistoryBoundaryKind.user, null), isolationScan,
		isolationRead, nativeThreadId);
	isolationRead.thread.turns[0].items[0].id = "source-user-item";
	isolationRead.thread.turns[0].items[0].content[0].text = "source typed input";
	setRawInputText(isolationRead.rawTurns[0], "source raw input");
	assert(isolationPlan.preTurns[0].items[0].id == "user-item-U1"
		&& isolationPlan.preTurns[0].items[0].content[0].text == "same prompt"
		&& isolationPlan.retainedPrefix[0].items[0].id == "user-item-U1"
		&& isolationPlan.retainedPrefix[0].items[0].content[0].text == "same prompt"
		&& rawInputText(isolationPlan.preRawTurns[0]) == "same prompt"
		&& rawInputText(isolationPlan.retainedRawPrefix[0]) == "same prompt");

	isolationPlan.preTurns[0].items[0].id = "pre-user-item";
	isolationPlan.preTurns[0].items[0].content[0].text = "pre typed input";
	assert(isolationRead.thread.turns[0].items[0].id == "source-user-item"
		&& isolationRead.thread.turns[0].items[0].content[0].text == "source typed input"
		&& isolationPlan.retainedPrefix[0].items[0].id == "user-item-U1"
		&& isolationPlan.retainedPrefix[0].items[0].content[0].text == "same prompt");

	isolationPlan.retainedPrefix[0].items[0].id = "prefix-user-item";
	isolationPlan.retainedPrefix[0].items[0].content[0].text = "prefix typed input";
	assert(isolationRead.thread.turns[0].items[0].id == "source-user-item"
		&& isolationRead.thread.turns[0].items[0].content[0].text == "source typed input"
		&& isolationPlan.preTurns[0].items[0].id == "pre-user-item"
		&& isolationPlan.preTurns[0].items[0].content[0].text == "pre typed input");

	setRawInputText(isolationPlan.preRawTurns[0], "pre raw input");
	assert(rawInputText(isolationRead.rawTurns[0]) == "source raw input"
		&& rawInputText(isolationPlan.retainedRawPrefix[0]) == "same prompt");
	setRawInputText(isolationPlan.retainedRawPrefix[0], "prefix raw input");
	assert(rawInputText(isolationRead.rawTurns[0]) == "source raw input"
		&& rawInputText(isolationPlan.preRawTurns[0]) == "pre raw input");

	struct RefusalCase
	{
		string name;
		string rollout;
		string nativeLedger;
		NativeUndoPreparationRefusalCategory category;
	}

	auto oneTurnLedger = ledger([
		simpleTurn("U1", "client-one", "prompt", "answer"),
	]);
	auto nonAdjacentRollout = joinParts([
		taskStarted("U1"),
		userResponse("U1", "prompt"),
		taskComplete("U1", ""),
		userEvent("prompt", "client-one"),
		assistantResponse("U1", "answer", "raw-agent-U1"),
		agentEvent("answer"),
		taskComplete("U1", "answer"),
	]);
	auto malformedEventRollout = joinParts([
		taskStarted("U1"),
		userResponse("U1", "prompt"),
		`{"type":"event_msg","payload":{"type":"user_message","client_id":"client-one","message":"prompt","images":[],"images":[],"local_images":[],"text_elements":[]}}`,
		assistantResponse("U1", "answer", "raw-agent-U1"),
		agentEvent("answer"),
		taskComplete("U1", "answer"),
	]);
	auto lifecycleMismatchRollout = joinParts([
		taskStarted("different-turn"),
		userResponse("U1", "prompt"),
		userEvent("prompt", "client-one"),
		assistantResponse("U1", "answer", "raw-agent-U1"),
		agentEvent("answer"),
		taskComplete("different-turn", "answer"),
	]);
	auto rollbackDeadRollout = joinParts([
		simpleRollout("U1", "client-one", "prompt", "answer"),
		`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`,
	]);
	auto futureContextRollout = joinParts([
		simpleRollout("U1", "client-one", "prompt", "answer"),
		taskStarted("CTX"),
		userResponse("CTX", "[SYSTEM: future contextual input]"),
		userEvent("[SYSTEM: future contextual input]", "", false),
	]);
	auto duplicateIdentityRollout = joinParts([
		simpleRollout("U1", "client-one", "prompt one", "answer one"),
		simpleRollout("U2", "client-two", "prompt two", "answer two", true, "client-one"),
	]);
	auto duplicateIdentityLedger = ledger([
		simpleTurn("U1", "client-one", "prompt one", "answer one"),
		simpleTurn("U2", "client-two", "prompt two", "answer two"),
	]);
	auto richUserEventRollout = simpleRollout("U1", "client-one", "prompt", "answer",
		true, null, "[\"image\"]");
	auto richLocalImageRollout = simpleRollout("U1", "client-one", "prompt", "answer",
		true, null, "[]", "[\"local-image\"]");
	auto richTextElementsRollout = simpleRollout("U1", "client-one", "prompt", "answer",
		true, null, "[]", "[]", "[{\"type\":\"mention\"}]");
	auto terminalTextMismatchRollout = joinParts([
		taskStarted("U1"),
		userResponse("U1", "prompt"),
		userEvent("prompt", "client-one"),
		assistantResponse("U1", "answer", "raw-agent-U1"),
		agentEvent("answer"),
		taskComplete("U1", "different answer"),
	]);
	auto duplicateUserEventRollout = joinParts([
		taskStarted("U1"),
		userResponse("U1", "prompt"),
		userEvent("prompt", "client-one"),
		userEvent("prompt", "client-one"),
		assistantResponse("U1", "answer", "raw-agent-U1"),
		agentEvent("answer"),
		taskComplete("U1", "answer"),
	]);
	auto malformedMarkerRollout = simpleRollout("U1", "client-one", "prompt", "answer")
		~ "\n" ~ `{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":"bad"}}`;
	auto duplicatePayloadMarkerRollout = simpleRollout("U1", "client-one", "prompt", "answer")
		~ "\n" ~ `{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1},"payload":{"type":"task_complete"}}`;
	auto malformedCandidateLineRollout = simpleRollout("U1", "client-one", "prompt", "answer")
		~ "\n" ~ `{"type":"event_msg","payload":`;
	auto unknownCandidateLineRollout = simpleRollout("U1", "client-one", "prompt", "answer")
		~ "\n" ~ `{"type":"future_rollout_record","payload":{}}`;
	auto misplacedCompactedRollout = simpleRollout("U1", "client-one", "prompt", "answer")
		~ "\n" ~ compactedLine("C", ["U1"]);
	auto residualAssistantRollout = simpleRollout("U1", "client-one", "prompt", "answer")
		~ "\n" ~ assistantResponse("U1", "residual answer", "residual-agent");
	auto richResponseItemRollout = joinParts([
		taskStarted("U1"),
		userResponse("U1", "prompt"),
		userEvent("prompt", "client-one"),
		`{"type":"response_item","payload":{"type":"function_call","id":"call","name":"future"}}`,
		assistantResponse("U1", "answer", "raw-agent-U1"),
		agentEvent("answer"),
		taskComplete("U1", "answer"),
	]);
	auto duplicateStartRollout = joinParts([
		taskStarted("U1"),
		userResponse("U1", "prompt"),
		userEvent("prompt", "client-one"),
		taskStarted("U1"),
		assistantResponse("U1", "answer", "raw-agent-U1"),
		agentEvent("answer"),
		taskComplete("U1", "answer"),
	]);
	auto duplicateCompleteRollout = simpleRollout("U1", "client-one", "prompt", "answer")
		~ "\n" ~ taskComplete("U1", "answer");
	auto conflictingAbortRollout = simpleRollout("U1", "client-one", "prompt", "answer")
		~ "\n" ~ turnAborted("U1");
	auto rawInputMismatchRollout = joinParts([
		taskStarted("U1"),
		userResponse("U1", "prompt"),
		userEvent("different prompt", "client-one"),
		assistantResponse("U1", "answer", "raw-agent-U1"),
		agentEvent("answer"),
		taskComplete("U1", "answer"),
	]);
	auto unknownRawUserFieldRollout = joinParts([
		taskStarted("U1"),
		`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"prompt"}],"internal_chat_message_metadata_passthrough":{"turn_id":"U1"},"future":true}}`,
		userEvent("prompt", "client-one"),
		assistantResponse("U1", "answer", "raw-agent-U1"),
		agentEvent("answer"),
		taskComplete("U1", "answer"),
	]);
	auto interruptedNullTelemetryAfterRollback = joinParts([
		simpleRollout("U1", "client-retained", "retained prompt", "retained answer"),
		joinParts([
			taskStarted("I"),
			userResponse("I", "interrupted prompt"),
			userEvent("interrupted prompt", "client-interrupted"),
			userResponse("I", v1AbortWrapper),
			turnAborted("I"),
		]),
		capturedNullRateLimitsTokenCount(),
		`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`,
	]);
	auto interruptedRetainedLedger = ledger([
		simpleTurn("U1", "client-retained", "retained prompt", "retained answer"),
	]);

	RefusalCase[] refusals = [
		RefusalCase("non-adjacent user event", nonAdjacentRollout, oneTurnLedger,
			NativeUndoPreparationRefusalCategory.association),
		RefusalCase("malformed user event", malformedEventRollout, oneTurnLedger,
			NativeUndoPreparationRefusalCategory.association),
		RefusalCase("lifecycle turn-id disagreement", lifecycleMismatchRollout,
			oneTurnLedger, NativeUndoPreparationRefusalCategory.unsupportedSuffix),
		RefusalCase("rollback-dead target", rollbackDeadRollout, oneTurnLedger,
			NativeUndoPreparationRefusalCategory.targetUnavailable),
		RefusalCase("future contextual user record", futureContextRollout, oneTurnLedger,
			NativeUndoPreparationRefusalCategory.association),
		RefusalCase("duplicated raw client identity", duplicateIdentityRollout,
			duplicateIdentityLedger, NativeUndoPreparationRefusalCategory.association),
		RefusalCase("rich user event", richUserEventRollout, oneTurnLedger,
			NativeUndoPreparationRefusalCategory.association),
		RefusalCase("rich local-image event", richLocalImageRollout, oneTurnLedger,
			NativeUndoPreparationRefusalCategory.association),
		RefusalCase("rich text-elements event", richTextElementsRollout, oneTurnLedger,
			NativeUndoPreparationRefusalCategory.association),
		RefusalCase("terminal message mismatch", terminalTextMismatchRollout, oneTurnLedger,
			NativeUndoPreparationRefusalCategory.unsupportedSuffix),
		RefusalCase("duplicate nonassociated user event", duplicateUserEventRollout,
			oneTurnLedger, NativeUndoPreparationRefusalCategory.unsupportedSuffix),
		RefusalCase("malformed rollback marker", malformedMarkerRollout, oneTurnLedger,
			NativeUndoPreparationRefusalCategory.association),
		RefusalCase("duplicate payload rollback marker", duplicatePayloadMarkerRollout,
			oneTurnLedger, NativeUndoPreparationRefusalCategory.unsupportedSuffix),
		RefusalCase("malformed candidate physical line", malformedCandidateLineRollout,
			oneTurnLedger, NativeUndoPreparationRefusalCategory.unsupportedSuffix),
		RefusalCase("unknown candidate top-level record", unknownCandidateLineRollout,
			oneTurnLedger, NativeUndoPreparationRefusalCategory.unsupportedSuffix),
		RefusalCase("misplaced compacted record", misplacedCompactedRollout, oneTurnLedger,
			NativeUndoPreparationRefusalCategory.unsupportedSuffix),
		RefusalCase("residual assistant response after terminal", residualAssistantRollout,
			oneTurnLedger, NativeUndoPreparationRefusalCategory.unsupportedSuffix),
		RefusalCase("rich future response item", richResponseItemRollout, oneTurnLedger,
			NativeUndoPreparationRefusalCategory.unsupportedSuffix),
		RefusalCase("duplicate task_started lifecycle", duplicateStartRollout, oneTurnLedger,
			NativeUndoPreparationRefusalCategory.unsupportedSuffix),
		RefusalCase("duplicate task_complete lifecycle", duplicateCompleteRollout,
			oneTurnLedger, NativeUndoPreparationRefusalCategory.unsupportedSuffix),
		RefusalCase("conflicting task abort lifecycle", conflictingAbortRollout,
			oneTurnLedger, NativeUndoPreparationRefusalCategory.unsupportedSuffix),
		RefusalCase("raw submitted input text mismatch", rawInputMismatchRollout,
			oneTurnLedger, NativeUndoPreparationRefusalCategory.association),
		RefusalCase("unknown raw submitted-user field", unknownRawUserFieldRollout,
			oneTurnLedger, NativeUndoPreparationRefusalCategory.targetUnavailable),
		RefusalCase("interrupted null telemetry cannot retire the aborted turn",
			interruptedNullTelemetryAfterRollback, interruptedRetainedLedger,
			NativeUndoPreparationRefusalCategory.targetUnavailable),
	];

	foreach (ref test; refusals)
	{
		auto scan = scanRollout(test.rollout);
		auto read = jsonParse!ThreadReadResult(test.nativeLedger);
		bool refused;
		try
		{
			prepareNativeUndoPlan(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
				scan, read, nativeThreadId);
		}
		catch (NativeUndoPreparationRefusal e)
		{
			refused = true;
			assert(e.category == test.category, test.name ~ ": " ~ e.diagnostic);
		}
		assert(refused, test.name);
	}

	void expectLedgerRefusal(HistoryBoundary boundary, string rollout,
		ThreadReadResult read, NativeUndoPreparationRefusalCategory expectedCategory,
		string name = "")
	{
		auto scan = scanRollout(rollout);
		bool refused;
		try
			prepareNativeUndoPlan(boundary, scan, read, nativeThreadId);
		catch (NativeUndoPreparationRefusal e)
		{
			refused = true;
			assert(e.category == expectedCategory, name ~ ": " ~ e.diagnostic);
		}
		assert(refused, name);
	}

	// session_meta is only the exact first physical system-preamble record. The
	// captured envelope must not make a duplicate, moved, or interstitial line
	// disappear from native physical-line closure.
	struct SessionMetaRefusalCase
	{
		string name;
		string rollout;
		string anchor;
		ThreadReadResult read;
	}
	auto capturedSessionMeta = capturedLeadingSessionMeta();
	SessionMetaRefusalCase[] sessionMetaRefusals = [
		SessionMetaRefusalCase("duplicate contiguous leading preamble", joinParts([
			capturedSessionMeta,
			capturedSessionMeta,
			simpleRollout("U1", "client-one", "prompt", "answer"),
		]), "line:4", jsonParse!ThreadReadResult(oneTurnLedger)),
		SessionMetaRefusalCase("moved after selected lifecycle", joinParts([
			simpleRollout("U1", "client-one", "prompt", "answer"),
			capturedSessionMeta,
		]), "line:2", jsonParse!ThreadReadResult(oneTurnLedger)),
		SessionMetaRefusalCase("duplicate after retained lifecycle", joinParts([
			capturedSessionMeta,
			simpleRollout("U1", "client-one", "prompt", "answer"),
			capturedSessionMeta,
			simpleRollout("U2", "client-two", "prompt two", "answer two"),
		]), "line:10", jsonParse!ThreadReadResult(ledger([
			simpleTurn("U1", "client-one", "prompt", "answer"),
			simpleTurn("U2", "client-two", "prompt two", "answer two"),
		]))),
		SessionMetaRefusalCase("interstitial selected lifecycle", joinParts([
			taskStarted("U1"),
			capturedSessionMeta,
			userResponse("U1", "prompt"),
			userEvent("prompt", "client-one"),
			assistantResponse("U1", "answer", "raw-agent-U1"),
			agentEvent("answer"),
			taskComplete("U1", "answer"),
		]), "line:3", jsonParse!ThreadReadResult(oneTurnLedger)),
		SessionMetaRefusalCase("malformed leading envelope", joinParts([
			`{"type":"session_meta","payload":[]}`,
			simpleRollout("U1", "client-one", "prompt", "answer"),
		]), "line:3", jsonParse!ThreadReadResult(oneTurnLedger)),
		SessionMetaRefusalCase("future leading envelope", joinParts([
			capturedSessionMeta.replace(`"payload":`, `"future":true,"payload":`),
			simpleRollout("U1", "client-one", "prompt", "answer"),
		]), "line:3", jsonParse!ThreadReadResult(oneTurnLedger)),
	];
	foreach (ref test; sessionMetaRefusals)
		expectLedgerRefusal(HistoryBoundary(test.anchor, HistoryBoundaryKind.user, null),
			test.rollout, test.read, NativeUndoPreparationRefusalCategory.unsupportedSuffix,
			test.name);

	// task_started mode is an exact captured discriminant. A malformed active
	// mode refuses the selected suffix, while a malformed later mode cannot be
	// allowed to consume the marker slot that would otherwise retire it.
	foreach (mode; ["", "future", "unsupported"])
	{
		auto activeMode = simpleRollout("U1", "client-one", "prompt", "answer").replace(
			`"collaboration_mode_kind":"default"`,
			`"collaboration_mode_kind":` ~ toJson(mode));
		expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
			activeMode, jsonParse!ThreadReadResult(oneTurnLedger),
			NativeUndoPreparationRefusalCategory.unsupportedSuffix,
			"unsupported task-start mode remains active: " ~ mode);

		auto markerMode = joinParts([
			simpleRollout("U1", "client-one", "prompt", "answer"),
			simpleRollout("U2", "client-two", "prompt two", "answer two").replace(
				`"collaboration_mode_kind":"default"`,
				`"collaboration_mode_kind":` ~ toJson(mode)),
			`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`,
		]);
		expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
			markerMode, jsonParse!ThreadReadResult(oneTurnLedger),
			NativeUndoPreparationRefusalCategory.targetUnavailable,
			"unsupported task-start mode cannot consume a marker slot: " ~ mode);
	}

	// Strict native lifecycle evidence remains globally live across markers.
	// A raw segment before a later target may be opaque only when its exact
	// start identity is represented in the materialized retained prefix.
	auto laterTargetLedger = jsonParse!ThreadReadResult(ledger([
		simpleTurn("U2", "client-two", "prompt two", "answer two"),
	]));
	auto validBeforeLaterTarget = simpleRollout("U1", "client-one", "prompt", "answer");
	foreach (strictBeforeTarget; [
		taskStarted("orphan"),
		`{"type":"event_msg","payload":{"type":"task_started"}}`,
		joinParts([
			taskStarted("unsupported"),
			`{"type":"response_item","payload":{"type":"function_call","id":"call","name":"future"}}`,
			taskComplete("unsupported", ""),
		]),
	])
	{
		auto beforeLaterTarget = joinParts([
			validBeforeLaterTarget,
			strictBeforeTarget,
			`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`,
			simpleRollout("U2", "client-two", "prompt two", "answer two"),
		]);
		auto beforeLaterScan = scanRollout(beforeLaterTarget);
		int laterTargetLine;
		foreach (line; beforeLaterScan.lines)
			if (isEligibleRawSubmission(line) && line.turnId == "U2")
				laterTargetLine = line.lineNumber;
		assert(laterTargetLine > 0);
		expectLedgerRefusal(HistoryBoundary("line:" ~ to!string(laterTargetLine),
			HistoryBoundaryKind.user, null),
			beforeLaterTarget, laterTargetLedger,
			NativeUndoPreparationRefusalCategory.unsupportedSuffix,
			"live strict lifecycle evidence before later target refuses");
	}

	// A marker can retire U1 without retiring later malformed, orphan, or
	// future physical evidence. With U2 at ledger index zero, every such live
	// pre-target line is outside an opaque retained-prefix range and must refuse.
	struct InterstitialEvidenceCase
	{
		string name;
		string evidence;
	}
	InterstitialEvidenceCase[] interstitialEvidence = [
		InterstitialEvidenceCase("orphan completion", taskComplete("orphan", "answer")),
		InterstitialEvidenceCase("orphan abort", turnAborted("orphan")),
		InterstitialEvidenceCase("future top-level record",
			`{"type":"future_event","payload":{}}`),
		InterstitialEvidenceCase("malformed physical record", `{`),
		InterstitialEvidenceCase("orphan start", taskStarted("orphan")),
		InterstitialEvidenceCase("unsupported lifecycle", joinParts([
			taskStarted("unsupported"),
			`{"type":"response_item","payload":{"type":"function_call","id":"call","name":"future"}}`,
			taskComplete("unsupported", ""),
		])),
	];
	foreach (test; interstitialEvidence)
	{
		auto interstitialRollout = joinParts([
			validBeforeLaterTarget,
			`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`,
			test.evidence,
			simpleRollout("U2", "client-two", "prompt two", "answer two"),
		]);
		auto interstitialScan = scanRollout(interstitialRollout);
		int laterTargetLine;
		foreach (line; interstitialScan.lines)
			if (isEligibleRawSubmission(line) && line.turnId == "U2")
				laterTargetLine = line.lineNumber;
		assert(laterTargetLine > 0, test.name);
		expectLedgerRefusal(HistoryBoundary("line:" ~ to!string(laterTargetLine),
			HistoryBoundaryKind.user, null),
			interstitialRollout, jsonParse!ThreadReadResult(ledger([
				simpleTurn("U2", "client-two", "prompt two", "answer two"),
			])), NativeUndoPreparationRefusalCategory.unsupportedSuffix,
			"live interstitial evidence after marker refuses: " ~ test.name);
	}

	// Repeated valid markers leave no live strict segment and do not trigger a
	// blanket historical rejection for the subsequent target.
	auto repeatedMarkerControl = joinParts([
		simpleRollout("U1", "client-one", "prompt", "answer"),
		simpleRollout("U2", "client-two", "prompt two", "answer two"),
		`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`,
		`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`,
		simpleRollout("U3", "client-three", "prompt three", "answer three"),
	]);
	auto repeatedMarkerScan = scanRollout(repeatedMarkerControl);
	auto repeatedMarkerRead = jsonParse!ThreadReadResult(ledger([
		simpleTurn("U3", "client-three", "prompt three", "answer three"),
	]));
	auto repeatedMarkerPlan = prepareNativeUndoPlan(
		HistoryBoundary("line:16", HistoryBoundaryKind.user, null), repeatedMarkerScan,
		repeatedMarkerRead, nativeThreadId);
	assert(repeatedMarkerPlan.numTurns == 1 && repeatedMarkerPlan.targetTurnId == "U3");

	// Opaque raw data strictly before the selected turn is preserved alongside
	// its corroborated retained prefix instead of being re-admitted as suffix
	// grammar.
	auto opaquePrefixControl = joinParts([
		joinParts([
			taskStarted("P"),
			`{"type":"response_item","payload":{"type":"function_call","id":"opaque","name":"future"}}`,
			taskComplete("P", ""),
		]),
		simpleRollout("U2", "client-two", "prompt two", "answer two"),
	]);
	auto opaquePrefixScan = scanRollout(opaquePrefixControl);
	auto opaquePrefixRead = jsonParse!ThreadReadResult(ledger([
		simpleTurn("P", "client-prefix", "opaque", "opaque"),
		simpleTurn("U2", "client-two", "prompt two", "answer two"),
	]));
	auto opaquePrefixPlan = prepareNativeUndoPlan(
		HistoryBoundary("line:5", HistoryBoundaryKind.user, null), opaquePrefixScan,
		opaquePrefixRead, nativeThreadId);
	assert(opaquePrefixPlan.numTurns == 1 && opaquePrefixPlan.targetTurnId == "U2"
		&& opaquePrefixPlan.retainedPrefix.length == 1
		&& opaquePrefixPlan.retainedPrefix[0].id == "P");

	string mutatePhysicalLine(string rollout, size_t lineIndex, string needle,
		string replacement)
	{
		string[] lines;
		foreach (line; rollout.lineSplitter)
			lines ~= line;
		assert(lineIndex < lines.length);
		auto mutated = lines[lineIndex].replace(needle, replacement);
		assert(mutated != lines[lineIndex]);
		lines[lineIndex] = mutated;
		return joinParts(lines);
	}

	string withFutureTopLevelField(string rollout, size_t lineIndex)
	{
		string[] lines;
		foreach (line; rollout.lineSplitter)
			lines ~= line;
		assert(lineIndex < lines.length && lines[lineIndex].length > 0
			&& lines[lineIndex][$ - 1] == '}');
		lines[lineIndex] = lines[lineIndex][0 .. $ - 1] ~ `,"future":true}`;
		return joinParts(lines);
	}

	string withFutureResponseMetadata(string rollout, size_t lineIndex, string turnId)
	{
		auto metadata = `"turn_id":` ~ toJson(turnId) ~ `}`;
		return mutatePhysicalLine(rollout, lineIndex, metadata,
			`"turn_id":` ~ toJson(turnId) ~ `,"future":true}`);
	}

	string withRawResponseItemId(string rollout, size_t lineIndex, string itemId)
	{
		string[] lines;
		foreach (line; rollout.lineSplitter)
			lines ~= line;
		assert(lineIndex < lines.length && lines[lineIndex].length >= 2
			&& lines[lineIndex][$ - 1] == '}' && lines[lineIndex][$ - 2] == '}');
		lines[lineIndex] = lines[lineIndex][0 .. $ - 2]
			~ `,"id":` ~ toJson(itemId) ~ `}}`;
		return joinParts(lines);
	}

	string withoutRawResponseItemId(string rollout, size_t lineIndex, string itemId)
	{
		return mutatePhysicalLine(rollout, lineIndex, `,"id":` ~ toJson(itemId), "");
	}

	string withCompactionReplacementHistory(string rollout,
		scope const string[] replacementTurnIds)
	{
		return mutatePhysicalLine(rollout, 20, compactedLine("C", ["U1", "U2", "U3", "C"]),
			compactedLine("C", replacementTurnIds));
	}

	string withBlankPhysicalLineAfter(string rollout, size_t lineIndex)
	{
		string[] lines;
		foreach (line; rollout.lineSplitter)
			lines ~= line;
		assert(lineIndex + 1 < lines.length);
		return joinParts(lines[0 .. lineIndex + 1]) ~ "\n\n"
			~ joinParts(lines[lineIndex + 1 .. $]);
	}

	// The settings record is admitted post-terminal evidence, so each nested
	// shape mutation must fail both while active and when a marker would
	// otherwise hide the newer lifecycle.
	struct ThreadSettingsRefusalCase
	{
		string name;
		string settings;
	}
	auto capturedSettings = capturedThreadSettingsObject();
	ThreadSettingsRefusalCase[] threadSettingsRefusals = [
		ThreadSettingsRefusalCase("empty thread settings", `{}`),
		ThreadSettingsRefusalCase("null thread settings", "null"),
		ThreadSettingsRefusalCase("future thread settings field",
			capturedSettings[0 .. $ - 1] ~ `,"future":true}`),
		ThreadSettingsRefusalCase("future thread settings permission field",
			capturedSettings.replace(`"type":"external","network":"enabled"`,
				`"type":"external","network":"enabled","future":true`)),
		ThreadSettingsRefusalCase("missing thread settings permission field",
			capturedSettings.replace(`,"network":"enabled"`, "")),
		ThreadSettingsRefusalCase("future collaboration settings field",
			capturedSettings.replace(`"developer_instructions":null`,
				`"developer_instructions":null,"future":true`)),
		ThreadSettingsRefusalCase("future collaboration mode field",
			capturedSettings.replace(`"mode":"default"`,
				`"mode":"default","future":true`)),
		ThreadSettingsRefusalCase("missing collaboration settings field",
			capturedSettings.replace(`,"developer_instructions":null`, "")),
		ThreadSettingsRefusalCase("mistyped collaboration reasoning effort",
			capturedSettings.replace(`"reasoning_effort":null`,
				`"reasoning_effort":"high"`)),
		ThreadSettingsRefusalCase("duplicate thread settings model",
			capturedSettings[0 .. $ - 1] ~ `,"model":"codex-mini-latest"}`),
	];
	foreach (ref test; threadSettingsRefusals)
	{
		auto activeSettings = simpleRollout("U1", "client-one", "prompt", "answer")
			~ "\n" ~ threadSettingsApplied(test.settings);
		expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
			activeSettings, jsonParse!ThreadReadResult(oneTurnLedger),
			NativeUndoPreparationRefusalCategory.unsupportedSuffix,
			test.name ~ " remains active strict evidence");
		auto markerSettings = joinParts([
			simpleRollout("U1", "client-one", "prompt", "answer"),
			simpleRollout("U2", "client-two", "prompt two", "answer two"),
			threadSettingsApplied(test.settings),
			`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`,
		]);
		expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
			markerSettings, jsonParse!ThreadReadResult(oneTurnLedger),
			NativeUndoPreparationRefusalCategory.targetUnavailable,
			test.name ~ " cannot consume a marker slot");
	}

	// The closed raw suffix must validate every physical record before the
	// consumed map can hide it. Mutate each admitted record family at its outer
	// envelope, rather than only testing an unclaimed future record.
	struct EnvelopeRefusalCase
	{
		string name;
		string rollout;
		string nativeLedger;
		string anchor;
		size_t lineIndex;
		NativeUndoPreparationRefusalCategory category;
	}
	EnvelopeRefusalCase[] envelopeRefusals = [
		EnvelopeRefusalCase("selected response envelope", simpleRollout("U1", "client-one",
			"prompt", "answer"), oneTurnLedger, "line:2", 1,
			NativeUndoPreparationRefusalCategory.targetUnavailable),
		EnvelopeRefusalCase("adjacent user event envelope", simpleRollout("U1", "client-one",
			"prompt", "answer"), oneTurnLedger, "line:2", 2,
			NativeUndoPreparationRefusalCategory.association),
		EnvelopeRefusalCase("lifecycle start envelope", simpleRollout("U1", "client-one",
			"prompt", "answer"), oneTurnLedger, "line:2", 0,
			NativeUndoPreparationRefusalCategory.unsupportedSuffix),
		EnvelopeRefusalCase("assistant response envelope", simpleRollout("U1", "client-one",
			"prompt", "answer"), oneTurnLedger, "line:2", 3,
			NativeUndoPreparationRefusalCategory.unsupportedSuffix),
		EnvelopeRefusalCase("agent event envelope", simpleRollout("U1", "client-one",
			"prompt", "answer"), oneTurnLedger, "line:2", 4,
			NativeUndoPreparationRefusalCategory.unsupportedSuffix),
		EnvelopeRefusalCase("lifecycle terminal envelope", simpleRollout("U1", "client-one",
			"prompt", "answer"), oneTurnLedger, "line:2", 5,
			NativeUndoPreparationRefusalCategory.unsupportedSuffix),
		EnvelopeRefusalCase("v1 abort wrapper envelope", interruptedRollout,
			interruptedLedger, "line:8", 9,
			NativeUndoPreparationRefusalCategory.unsupportedSuffix),
		EnvelopeRefusalCase("v1 abort event envelope", interruptedRollout,
			interruptedLedger, "line:8", 10,
			NativeUndoPreparationRefusalCategory.unsupportedSuffix),
		EnvelopeRefusalCase("compaction start envelope", compactionFixtureRollout,
			compactionFixtureLedger, "line:14", 18,
			NativeUndoPreparationRefusalCategory.unsupportedSuffix),
		EnvelopeRefusalCase("compaction assistant envelope", compactionFixtureRollout,
			compactionFixtureLedger, "line:14", 19,
			NativeUndoPreparationRefusalCategory.unsupportedSuffix),
		EnvelopeRefusalCase("compacted record envelope", compactionFixtureRollout,
			compactionFixtureLedger, "line:14", 20,
			NativeUndoPreparationRefusalCategory.unsupportedSuffix),
		EnvelopeRefusalCase("context compacted envelope", compactionFixtureRollout,
			compactionFixtureLedger, "line:14", 21,
			NativeUndoPreparationRefusalCategory.unsupportedSuffix),
		EnvelopeRefusalCase("compaction terminal envelope", compactionFixtureRollout,
			compactionFixtureLedger, "line:14", 22,
			NativeUndoPreparationRefusalCategory.unsupportedSuffix),
	];
	foreach (ref test; envelopeRefusals)
		expectLedgerRefusal(HistoryBoundary(test.anchor, HistoryBoundaryKind.user, null),
			withFutureTopLevelField(test.rollout, test.lineIndex),
			jsonParse!ThreadReadResult(test.nativeLedger), test.category, test.name);

	// The shared response-item allowlist deliberately admits the fields used by
	// both roles. Native admission therefore pins their captured role-specific
	// presence and nested metadata separately.
	struct NestedShapeRefusalCase
	{
		string name;
		string rollout;
		string nativeLedger;
		string anchor;
		NativeUndoPreparationRefusalCategory category;
	}
	auto simpleFixture = simpleRollout("U1", "client-one", "prompt", "answer");
	NestedShapeRefusalCase[] nestedShapeRefusals = [
		NestedShapeRefusalCase("normal caller has unsupported item id",
			withRawResponseItemId(simpleFixture, 1, "future-user-item"), oneTurnLedger,
			"line:2", NativeUndoPreparationRefusalCategory.targetUnavailable),
		NestedShapeRefusalCase("assistant omits required item id",
			withoutRawResponseItemId(simpleFixture, 3, "raw-agent-U1"), oneTurnLedger,
			"line:2", NativeUndoPreparationRefusalCategory.unsupportedSuffix),
		NestedShapeRefusalCase("simple assistant metadata has future field",
			withFutureResponseMetadata(simpleFixture, 3, "U1"), oneTurnLedger,
			"line:2", NativeUndoPreparationRefusalCategory.unsupportedSuffix),
		NestedShapeRefusalCase("compaction assistant metadata has future field",
			withFutureResponseMetadata(compactionFixtureRollout, 19, "C"),
			compactionFixtureLedger, "line:14",
			NativeUndoPreparationRefusalCategory.unsupportedSuffix),
		NestedShapeRefusalCase("retained compaction metadata has future field",
			withFutureResponseMetadata(compactionFixtureRollout, 20, "U1"),
			compactionFixtureLedger, "line:14",
			NativeUndoPreparationRefusalCategory.unsupportedSuffix),
	];
	foreach (ref test; nestedShapeRefusals)
		expectLedgerRefusal(HistoryBoundary(test.anchor, HistoryBoundaryKind.user, null),
			test.rollout, jsonParse!ThreadReadResult(test.nativeLedger), test.category,
			test.name);

	struct ContextGrammarRefusalCase
	{
		string name;
		string rollout;
	}
	enum environmentContextContent
		= `[{"type":"input_text","text":"<environment_context>initial context</environment_context>"}]`;
	ContextGrammarRefusalCase[] contextGrammarRefusals = [
		ContextGrammarRefusalCase("developer context has unsupported item id",
			withRawResponseItemId(initialContextRollout, 3, "unexpected-developer-id")),
		ContextGrammarRefusalCase("context-only user has unsupported item id",
			withRawResponseItemId(initialContextRollout, 4, "unexpected-context-id")),
		ContextGrammarRefusalCase("developer context uses output text",
			initialContextRolloutWithDeveloperContent(
				`[{"type":"output_text","text":"developer context"}]`)),
		ContextGrammarRefusalCase("context-only user has additional output text",
			mutatePhysicalLine(initialContextRollout, 4,
				`"content":` ~ environmentContextContent,
				`"content":` ~ environmentContextContent[0 .. $ - 1]
					~ `,{"type":"output_text","text":"unexpected context output"}]`)),
		ContextGrammarRefusalCase("developer context has empty content",
			initialContextRolloutWithDeveloperContent(`[]`)),
		ContextGrammarRefusalCase("developer context has empty input text",
			initialContextRolloutWithDeveloperContent(
				`[{"type":"input_text","text":""}]`)),
		ContextGrammarRefusalCase("developer context uses text content",
			initialContextRolloutWithDeveloperContent(
				`[{"type":"text","text":"developer context"}]`)),
		ContextGrammarRefusalCase("developer context mixes input and output text",
			mutatePhysicalLine(multipleDeveloperContextRollout, 3,
				`"type":"input_text","text":"additional developer context"`,
				`"type":"output_text","text":"additional developer context"`)),
		ContextGrammarRefusalCase("context-only user has multiple input blocks",
			mutatePhysicalLine(initialContextRollout, 4,
				`"content":` ~ environmentContextContent,
				`"content":` ~ environmentContextContent[0 .. $ - 1]
					~ `,{"type":"input_text","text":"additional context"}]`)),
		ContextGrammarRefusalCase("developer context uses unsupported role",
			mutatePhysicalLine(initialContextRollout, 3, `"role":"developer"`,
				`"role":"system"`)),
	];
	foreach (ref test; contextGrammarRefusals)
		expectLedgerRefusal(HistoryBoundary("line:6", HistoryBoundaryKind.user, null),
			test.rollout, jsonParse!ThreadReadResult(initialContextLedger),
			NativeUndoPreparationRefusalCategory.unsupportedSuffix, test.name);

	// Contextual envelopes are native evidence before the submitted caller.
	// Keep every captured nested object lossless so a future setting cannot be
	// admitted merely because its outer contextual record is recognized.
	struct ContextualNestedRefusalCase
	{
		string name;
		string rollout;
	}
	ContextualNestedRefusalCase[] contextualNestedRefusals = [
		ContextualNestedRefusalCase("future world state field",
			mutatePhysicalLine(initialContextRollout, 1, `"state":{`,
				`"state":{"future":true,`)),
		ContextualNestedRefusalCase("future agents-md field",
			mutatePhysicalLine(initialContextRollout, 1, `"agents_md":{}`,
				`"agents_md":{"future":true}`)),
		ContextualNestedRefusalCase("future local environment field",
			mutatePhysicalLine(initialContextRollout, 1, `"shell":"zsh"`,
				`"shell":"zsh","future":true`)),
		ContextualNestedRefusalCase("duplicate local environment field",
			mutatePhysicalLine(initialContextRollout, 1, `"shell":"zsh"`,
				`"shell":"zsh","shell":"zsh"`)),
		ContextualNestedRefusalCase("future skills field",
			mutatePhysicalLine(initialContextRollout, 1, `"includeInstructions":true`,
				`"includeInstructions":true,"future":true`)),
		ContextualNestedRefusalCase("empty workspace roots",
			mutatePhysicalLine(initialContextRollout, 2, `["/workspace"]`, `[]`)),
		ContextualNestedRefusalCase("future sandbox policy field",
			mutatePhysicalLine(initialContextRollout, 2,
				`"network_access":"enabled"`, `"network_access":"enabled","future":true`)),
		ContextualNestedRefusalCase("null sandbox policy",
			mutatePhysicalLine(initialContextRollout, 2,
				`{"type":"external-sandbox","network_access":"enabled"}`, "null")),
		ContextualNestedRefusalCase("missing sandbox policy field",
			mutatePhysicalLine(initialContextRollout, 2, `,"network_access":"enabled"`, "")),
		ContextualNestedRefusalCase("missing permission profile field",
			mutatePhysicalLine(initialContextRollout, 2, `,"network":"enabled"`, "")),
		ContextualNestedRefusalCase("future permission profile field",
			mutatePhysicalLine(initialContextRollout, 2, `"network":"enabled"`,
				`"network":"enabled","future":true`)),
		ContextualNestedRefusalCase("future collaboration mode field",
			mutatePhysicalLine(initialContextRollout, 2, `"mode":"default"`,
				`"mode":"default","future":true`)),
		ContextualNestedRefusalCase("future collaboration settings field",
			mutatePhysicalLine(initialContextRollout, 2, `"developer_instructions":null`,
				`"developer_instructions":null,"future":true`)),
		ContextualNestedRefusalCase("mistyped collaboration settings null",
			mutatePhysicalLine(initialContextRollout, 2, `"reasoning_effort":null`,
				`"reasoning_effort":"high"`)),
	];
	foreach (ref test; contextualNestedRefusals)
		expectLedgerRefusal(HistoryBoundary("line:6", HistoryBoundaryKind.user, null),
			test.rollout, jsonParse!ThreadReadResult(initialContextLedger),
			NativeUndoPreparationRefusalCategory.unsupportedSuffix, test.name);

	struct CompactionHistoryRefusalCase
	{
		string name;
		string[] replacementTurnIds;
	}
	CompactionHistoryRefusalCase[] compactionHistoryRefusals = [
		CompactionHistoryRefusalCase("compaction replacement history has foreign ids",
			["foreign-one", "foreign-two", "foreign-three", "C"]),
		CompactionHistoryRefusalCase("compaction replacement history reuses an id",
			["U1", "U1", "U3", "C"]),
		CompactionHistoryRefusalCase("compaction replacement history is missing an id",
			["U1", "U2", "C"]),
		CompactionHistoryRefusalCase("compaction replacement history is reordered",
			["U2", "U1", "U3", "C"]),
		CompactionHistoryRefusalCase("compaction replacement history has an extra id",
			["U1", "U2", "U3", "extra", "C"]),
	];
	foreach (ref test; compactionHistoryRefusals)
		expectLedgerRefusal(HistoryBoundary("line:14", HistoryBoundaryKind.user, null),
			withCompactionReplacementHistory(compactionFixtureRollout,
				test.replacementTurnIds), jsonParse!ThreadReadResult(compactionFixtureLedger),
			NativeUndoPreparationRefusalCategory.unsupportedSuffix, test.name);

	struct BlankPhysicalLineRefusalCase
	{
		string name;
		string rollout;
		string nativeLedger;
		string anchor;
		size_t afterLineIndex;
	}
	BlankPhysicalLineRefusalCase[] blankPhysicalLineRefusals = [
		BlankPhysicalLineRefusalCase("blank after submitted-user event", simpleFixture,
			oneTurnLedger, "line:2", 2),
		BlankPhysicalLineRefusalCase("blank after simple assistant response", simpleFixture,
			oneTurnLedger, "line:2", 3),
		BlankPhysicalLineRefusalCase("blank before simple lifecycle terminal", simpleFixture,
			oneTurnLedger, "line:2", 4),
		BlankPhysicalLineRefusalCase("blank after compaction assistant response",
			compactionFixtureRollout, compactionFixtureLedger, "line:14", 19),
		BlankPhysicalLineRefusalCase("blank after compacted record",
			compactionFixtureRollout, compactionFixtureLedger, "line:14", 20),
		BlankPhysicalLineRefusalCase("blank before compaction lifecycle terminal",
			compactionFixtureRollout, compactionFixtureLedger, "line:14", 21),
	];
	foreach (ref test; blankPhysicalLineRefusals)
		expectLedgerRefusal(HistoryBoundary(test.anchor, HistoryBoundaryKind.user, null),
			withBlankPhysicalLineAfter(test.rollout, test.afterLineIndex),
			jsonParse!ThreadReadResult(test.nativeLedger),
			NativeUndoPreparationRefusalCategory.unsupportedSuffix, test.name);

	// An orphan/malformed task_started has no complete known lifecycle and
	// therefore cannot consume the marker slot that rolls back U1.
	auto orphanNativeStart = simpleRollout("U1", "client-one", "prompt", "answer")
		~ "\n" ~ taskStarted("orphan") ~ "\n"
		~ `{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`;
	auto malformedNativeStart = simpleRollout("U1", "client-one", "prompt", "answer")
		~ "\n" ~ `{"type":"event_msg","payload":{"type":"task_started"}}` ~ "\n"
		~ `{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`;
	foreach (rollout; [orphanNativeStart, malformedNativeStart])
		expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
			rollout, jsonParse!ThreadReadResult(oneTurnLedger),
			NativeUndoPreparationRefusalCategory.targetUnavailable);

	// Captured developer/environment/world/turn context remains an exact
	// pre-submission projection and therefore does not prevent its completed
	// lifecycle from occupying the marker slot.
	auto contextualNativeMarker = initialContextRollout ~ "\n"
		~ `{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`;
	expectLedgerRefusal(HistoryBoundary("line:6", HistoryBoundaryKind.user, null),
		contextualNativeMarker, jsonParse!ThreadReadResult(initialContextLedger),
		NativeUndoPreparationRefusalCategory.targetUnavailable,
		"captured pre-submission context remains a corroborable marker slot");

	// A complete lifecycle without a submitted caller cannot prove a provider
	// materialized turn for marker liveness. It must not consume the marker and
	// leave U1 selectable.
	auto assistantOnlyNativeLifecycle = joinParts([
		taskStarted("phantom"),
		assistantResponse("phantom", "phantom answer", "raw-agent-phantom"),
		agentEvent("phantom answer"),
		taskComplete("phantom", "phantom answer"),
	]);
	auto assistantOnlyBeforeMarker = simpleRollout("U1", "client-one", "prompt", "answer")
		~ "\n" ~ assistantOnlyNativeLifecycle ~ "\n"
		~ `{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`;
	expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
		assistantOnlyBeforeMarker, jsonParse!ThreadReadResult(oneTurnLedger),
		NativeUndoPreparationRefusalCategory.targetUnavailable);

	// A syntactically exact caller after its terminal cannot corroborate a
	// provider turn for a marker slot.
	auto postTerminalCallerBeforeMarker = joinParts([
		simpleRollout("U1", "client-one", "prompt", "answer"),
		taskStarted("post-terminal"),
		taskComplete("post-terminal", "post-terminal answer"),
		userResponse("post-terminal", "post-terminal prompt"),
		userEvent("post-terminal prompt", "post-terminal-client"),
		`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`,
	]);
	expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
		postTerminalCallerBeforeMarker, jsonParse!ThreadReadResult(oneTurnLedger),
		NativeUndoPreparationRefusalCategory.targetUnavailable);

	string submittedProjectionBeforeMarker(scope const string[] projection,
		string terminal = null)
	{
		if (terminal is null)
			terminal = taskComplete("U2", "answer");
		string[] parts = [
			simpleRollout("U1", "client-one", "prompt", "answer"),
			taskStarted("U2"),
			userResponse("U2", "prompt"),
			userEvent("prompt", "client-two"),
		];
		parts ~= projection;
		parts ~= [
			terminal,
			`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`,
		];
		return joinParts(parts);
	}

	// An invalid U2 must remain strict evidence behind its marker. It cannot
	// consume the provider slot and make U1 appear safe to undo again.
	struct SubmittedMarkerProjectionRefusalCase
	{
		string name;
		string rollout;
	}
	SubmittedMarkerProjectionRefusalCase[] submittedMarkerProjectionRefusals = [
		SubmittedMarkerProjectionRefusalCase("function call before terminal",
			submittedProjectionBeforeMarker([
				`{"type":"response_item","payload":{"type":"function_call","id":"call","name":"future"}}`,
				agentEvent("answer"), assistantResponse("U2", "answer", "raw-agent-U2"),
			])),
		SubmittedMarkerProjectionRefusalCase("malformed agent event before terminal",
			submittedProjectionBeforeMarker([
				`{"type":"event_msg","payload":{"type":"agent_message","message":"answer","phase":null}}`,
				assistantResponse("U2", "answer", "raw-agent-U2"),
			])),
		SubmittedMarkerProjectionRefusalCase("unknown record before terminal",
			submittedProjectionBeforeMarker([
				`{"type":"future_rollout_record","payload":{}}`, agentEvent("answer"),
				assistantResponse("U2", "answer", "raw-agent-U2"),
			])),
		SubmittedMarkerProjectionRefusalCase("blank physical record before terminal",
			submittedProjectionBeforeMarker([
				"", agentEvent("answer"), assistantResponse("U2", "answer", "raw-agent-U2"),
			])),
		SubmittedMarkerProjectionRefusalCase("future assistant metadata before terminal",
			submittedProjectionBeforeMarker([
				agentEvent("answer"),
				mutatePhysicalLine(assistantResponse("U2", "answer", "raw-agent-U2"), 0,
					`"turn_id":"U2"}`, `"turn_id":"U2","future":true}`),
			])),
		SubmittedMarkerProjectionRefusalCase("duplicate adjacent user event",
			submittedProjectionBeforeMarker([
				userEvent("prompt", "client-two"), agentEvent("answer"),
				assistantResponse("U2", "answer", "raw-agent-U2"),
			])),
	];
	foreach (ref test; submittedMarkerProjectionRefusals)
		expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
			test.rollout, jsonParse!ThreadReadResult(oneTurnLedger),
			NativeUndoPreparationRefusalCategory.targetUnavailable, test.name);
	foreach (terminal; [
		taskComplete("U2", "different answer"),
		compactionComplete("U2"),
	])
		expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
			submittedProjectionBeforeMarker([
				agentEvent("answer"), assistantResponse("U2", "answer", "raw-agent-U2"),
			], terminal), jsonParse!ThreadReadResult(oneTurnLedger),
			NativeUndoPreparationRefusalCategory.targetUnavailable,
			"nonmatching completed terminal cannot consume a marker slot");
	string interruptedProjectionBeforeMarker(string reason)
	{
		return joinParts([
			simpleRollout("U1", "client-one", "prompt", "answer"),
			taskStarted("U2"),
			userResponse("U2", "prompt"),
			userEvent("prompt", "client-two"),
			userResponse("U2", v1AbortWrapper),
			turnAbortedWithReason("U2", reason),
			`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`,
		]);
	}
	foreach (reason; ["other", "cancelled", "", "Interrupted", "interrupted "])
		expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
			interruptedProjectionBeforeMarker(reason),
			jsonParse!ThreadReadResult(oneTurnLedger),
			NativeUndoPreparationRefusalCategory.targetUnavailable,
			"non-interrupted terminal cannot consume a marker slot");
	auto assistantBeforeCallerBeforeMarker = joinParts([
		simpleRollout("U1", "client-one", "prompt", "answer"),
		taskStarted("U2"), assistantResponse("U2", "answer", "raw-agent-U2"),
		userResponse("U2", "prompt"), userEvent("prompt", "client-two"),
		agentEvent("answer"), taskComplete("U2", "answer"),
		`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`,
	]);
	expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
		assistantBeforeCallerBeforeMarker, jsonParse!ThreadReadResult(oneTurnLedger),
		NativeUndoPreparationRefusalCategory.targetUnavailable,
		"assistant before submitted caller cannot consume a marker slot");

	string markerCompactionRollout(scope const string[] compactionRecords)
	{
		string[] parts = [
			simpleRollout("U1", "client-one", "prompt", "answer"),
			taskStarted("C"),
		];
		parts ~= compactionRecords;
		parts ~= `{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`;
		return joinParts(parts);
	}
	enum compactionAssistantRecord = "Conversation summary: previous context compacted.";
	enum contextCompactedRecord = `{"type":"event_msg","payload":{"type":"context_compacted"}}`;
	struct MarkerCompactionRefusalCase
	{
		string name;
		string[] records;
	}
	MarkerCompactionRefusalCase[] markerCompactionRefusals = [
		MarkerCompactionRefusalCase("misordered compaction projection", [
			compactedLine("C", ["U1", "C"]),
			assistantResponse("C", compactionAssistantRecord, "raw-agent-C"),
			contextCompactedRecord,
			compactionComplete("C"),
		]),
		MarkerCompactionRefusalCase("post-terminal compaction assistant", [
			compactedLine("C", ["U1", "C"]),
			contextCompactedRecord,
			compactionComplete("C"),
			assistantResponse("C", compactionAssistantRecord, "raw-agent-C"),
		]),
		MarkerCompactionRefusalCase("post-terminal compacted record", [
			assistantResponse("C", compactionAssistantRecord, "raw-agent-C"),
			contextCompactedRecord,
			compactionComplete("C"),
			compactedLine("C", ["U1", "C"]),
		]),
		MarkerCompactionRefusalCase("post-terminal context-compacted event", [
			assistantResponse("C", compactionAssistantRecord, "raw-agent-C"),
			compactedLine("C", ["U1", "C"]),
			compactionComplete("C"),
			contextCompactedRecord,
		]),
	];
	foreach (ref test; markerCompactionRefusals)
		expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
			markerCompactionRollout(test.records), jsonParse!ThreadReadResult(oneTurnLedger),
			NativeUndoPreparationRefusalCategory.targetUnavailable, test.name);

	// Marker liveness must bind C's history before consuming it; otherwise the
	// active-suffix comparison never observes this forged replacement vector.
	auto forgedCompactionHistoryBeforeMarker = markerCompactionRollout([
		assistantResponse("C", compactionAssistantRecord, "raw-agent-C"),
		compactedLine("C", ["foreign", "C"]),
		contextCompactedRecord,
		compactionComplete("C"),
	]);
	expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
		forgedCompactionHistoryBeforeMarker, jsonParse!ThreadReadResult(oneTurnLedger),
		NativeUndoPreparationRefusalCategory.targetUnavailable,
		"forged compaction history cannot consume a marker slot");

	string tokenCount(string info, string rateLimits)
	{
		return `{"type":"event_msg","payload":{"type":"token_count","info":`
			~ info ~ `,"rate_limits":` ~ rateLimits ~ `}}`;
	}
	string malformedTokenCountWithoutRateLimits(string info)
	{
		return `{"type":"event_msg","payload":{"type":"token_count","info":`
			~ info ~ `}}`;
	}
	enum duplicateUsageInfo = `{"total_token_usage":{"input_tokens":20,"input_tokens":20,"cached_input_tokens":0,"output_tokens":42,"reasoning_output_tokens":0,"total_tokens":62},"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":6494},"model_context_window":258400}`;
	enum mistypedUsageInfo = `{"total_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":42,"reasoning_output_tokens":0,"total_tokens":62},"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":6494},"model_context_window":"bad"}`;
	enum unknownRateLimits = `{"limit_id":"codex","limit_name":null,"primary":null,"secondary":null,"credits":null,"individual_limit":null,"plan_type":null,"rate_limit_reached_type":null,"future":true}`;
	struct TokenTelemetryMarkerRefusalCase
	{
		string name;
		string telemetry;
	}
	auto tokenInfo = capturedTokenCountInfo();
	TokenTelemetryMarkerRefusalCase[] invalidTokenTelemetry = [
		TokenTelemetryMarkerRefusalCase("empty token info", tokenCount(`{}`, "null")),
		TokenTelemetryMarkerRefusalCase("future token info", tokenCount(
			`{"future":true}`, "{}")),
		TokenTelemetryMarkerRefusalCase("empty object rate limits", tokenCount(tokenInfo,
			"{}")),
		TokenTelemetryMarkerRefusalCase("missing rate limits",
			malformedTokenCountWithoutRateLimits(tokenInfo)),
		TokenTelemetryMarkerRefusalCase("future rate limits field", tokenCount(tokenInfo,
			unknownRateLimits)),
		TokenTelemetryMarkerRefusalCase("duplicate nested usage field", tokenCount(
			duplicateUsageInfo, "null")),
		TokenTelemetryMarkerRefusalCase("mistyped nested usage field", tokenCount(
			mistypedUsageInfo, "null")),
	];
	foreach (ref test; invalidTokenTelemetry)
	{
		auto ordinary = joinParts([
			simpleRollout("U1", "client-one", "prompt", "answer"),
			simpleRollout("U2", "client-two", "prompt", "answer"),
			test.telemetry,
			`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`,
		]);
		expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
			ordinary, jsonParse!ThreadReadResult(oneTurnLedger),
			NativeUndoPreparationRefusalCategory.targetUnavailable,
			"ordinary " ~ test.name ~ " cannot consume a marker slot");
		auto compaction = markerCompactionRollout([
			assistantResponse("C", compactionAssistantRecord, "raw-agent-C"),
			compactedLine("C", ["U1", "C"]),
			contextCompactedRecord,
			compactionComplete("C"),
			test.telemetry,
		]);
		expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
			compaction, jsonParse!ThreadReadResult(oneTurnLedger),
			NativeUndoPreparationRefusalCategory.targetUnavailable,
			"compaction " ~ test.name ~ " cannot consume a marker slot");
	}
	auto nullBeforeSubmittedTerminal = joinParts([
		simpleRollout("U1", "client-one", "prompt", "answer"),
		simpleRolloutWithPreTerminalTelemetry("U2", "client-two", "prompt", "answer",
			capturedNullRateLimitsTokenCount()),
		`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`,
	]);
	auto objectAfterSubmittedTerminal = joinParts([
		simpleRollout("U1", "client-one", "prompt", "answer"),
		simpleRollout("U2", "client-two", "prompt", "answer"),
		capturedObjectRateLimitsTokenCount(),
		`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`,
	]);
	expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
		nullBeforeSubmittedTerminal, jsonParse!ThreadReadResult(oneTurnLedger),
		NativeUndoPreparationRefusalCategory.targetUnavailable,
		"null token-count cannot occupy the pre-submitted-terminal position");
	// thread/rollback recomputes thread token usage and appends that object
	// rate_limits token_count immediately before the marker it also appends,
	// even when the retired turn completed plainly. Observed from Codex CLI
	// 0.144.1; refusing it retires the wrong turn on the next undo.
	auto objectAfterSubmittedScan = scanRollout(objectAfterSubmittedTerminal);
	auto objectAfterSubmittedRead = jsonParse!ThreadReadResult(oneTurnLedger);
	auto objectAfterSubmittedPlan = prepareNativeUndoPlan(
		HistoryBoundary("line:2", HistoryBoundaryKind.user, null), objectAfterSubmittedScan,
		objectAfterSubmittedRead, nativeThreadId);
	assert(objectAfterSubmittedPlan.numTurns == 1
		&& objectAfterSubmittedPlan.targetTurnId == "U1");
	// The same record one line earlier is not the rollback's recomputation, so
	// it still retires nothing.
	auto objectBeforeMarkerTail = joinParts([
		simpleRollout("U1", "client-one", "prompt", "answer"),
		simpleRollout("U2", "client-two", "prompt", "answer"),
		capturedObjectRateLimitsTokenCount(),
		capturedNullRateLimitsTokenCount(),
		`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`,
	]);
	expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
		objectBeforeMarkerTail, jsonParse!ThreadReadResult(oneTurnLedger),
		NativeUndoPreparationRefusalCategory.targetUnavailable,
		"recomputed token-count is admitted only directly before the marker");
	auto nullBeforeCompactionTerminal = markerCompactionRollout([
		assistantResponse("C", compactionAssistantRecord, "raw-agent-C"),
		capturedNullRateLimitsTokenCount(),
		compactedLine("C", ["U1", "C"]),
		contextCompactedRecord,
		compactionComplete("C"),
	]);
	auto objectAfterCompactionTerminal = markerCompactionRollout([
		assistantResponse("C", compactionAssistantRecord, "raw-agent-C"),
		compactedLine("C", ["U1", "C"]),
		contextCompactedRecord,
		compactionComplete("C"),
		capturedObjectRateLimitsTokenCount(),
	]);
	expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
		nullBeforeCompactionTerminal, jsonParse!ThreadReadResult(oneTurnLedger),
		NativeUndoPreparationRefusalCategory.targetUnavailable,
		"null token-count cannot occupy the pre-compaction terminal position");
	auto objectAfterCompactionScan = scanRollout(objectAfterCompactionTerminal);
	auto objectAfterCompactionRead = jsonParse!ThreadReadResult(oneTurnLedger);
	auto objectAfterCompactionPlan = prepareNativeUndoPlan(
		HistoryBoundary("line:2", HistoryBoundaryKind.user, null), objectAfterCompactionScan,
		objectAfterCompactionRead, nativeThreadId);
	assert(objectAfterCompactionPlan.numTurns == 1
		&& objectAfterCompactionPlan.targetTurnId == "U1");

	// A repeated lifecycle ID is equally ambiguous: neither copy can decide
	// which materialized turn the marker removed.
	auto duplicateNativeTurnBeforeMarker = simpleRollout("U1", "client-one", "prompt", "answer")
		~ "\n" ~ simpleRollout("U1", "client-two", "duplicate prompt", "duplicate answer")
		~ "\n"
		~ `{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`;
	expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
		duplicateNativeTurnBeforeMarker, jsonParse!ThreadReadResult(oneTurnLedger),
		NativeUndoPreparationRefusalCategory.association);

	expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
		simpleRollout("U1", "client-one", "prompt", "answer"),
		jsonParse!ThreadReadResult(ledger([
			simpleTurn("U1", "client-one", "prompt", "answer"),
		], "different-thread")), NativeUndoPreparationRefusalCategory.providerData);
	foreach (status; [
		`{"type":"notLoaded"}`,
		`{"type":"active","activeFlags":[]}`,
		`{"type":"idle","activeFlags":["busy"]}`,
		`{"type":"idle","activeFlags":null}`,
		`{"type":"idle","activeFlags":[]}`,
		`{"type":"idle","futureStatus":true}`,
	])
		expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
			simpleRollout("U1", "client-one", "prompt", "answer"),
			jsonParse!ThreadReadResult(ledgerWithStatus(status)),
			NativeUndoPreparationRefusalCategory.threadStatus);

	// Native interruption is not the tolerant replay classifier. The complete
	// captured v1 wrapper is accepted only at the exact terminal position.
	auto appendedAbortWrapper = interruptedRollout ~ "\n" ~ userResponse("I", v1AbortWrapper);
	expectLedgerRefusal(HistoryBoundary("line:8", HistoryBoundaryKind.user, null),
		appendedAbortWrapper, jsonParse!ThreadReadResult(interruptedLedger),
		NativeUndoPreparationRefusalCategory.unsupportedSuffix);
	string interruptedWithWrapper(string wrapper)
	{
		return joinParts([
			simpleRollout("U1", "client-retained", "retained prompt", "retained answer"),
			joinParts([
				taskStarted("I"),
				userResponse("I", "interrupted prompt"),
				userEvent("interrupted prompt", "client-interrupted"),
				userResponse("I", wrapper),
				turnAborted("I"),
			]),
		]);
	}
	auto upperCaseWrapper = "<TURN_ABORTED>"
		~ v1AbortWrapper["<turn_aborted>".length .. $];
	auto lookalikeWrapper = "<turn_aborted_notice>"
		~ v1AbortWrapper["<turn_aborted>".length .. $];
	enum alteredWrapper = "<turn_aborted>\nThe user interrupted a previous turn on purpose.\n</turn_aborted>";
	foreach (wrapper; [v1AbortWrapper ~ " ", alteredWrapper, upperCaseWrapper])
		expectLedgerRefusal(HistoryBoundary("line:8", HistoryBoundaryKind.user, null),
			interruptedWithWrapper(wrapper), jsonParse!ThreadReadResult(interruptedLedger),
			NativeUndoPreparationRefusalCategory.unsupportedSuffix);
	foreach (wrapper; [v1AbortWrapper[0 .. $ - 1], lookalikeWrapper])
		expectLedgerRefusal(HistoryBoundary("line:8", HistoryBoundaryKind.user, null),
			interruptedWithWrapper(wrapper), jsonParse!ThreadReadResult(interruptedLedger),
			NativeUndoPreparationRefusalCategory.association);
	auto duplicateInterruptedWrapper = joinParts([
		simpleRollout("U1", "client-retained", "retained prompt", "retained answer"),
		joinParts([
			taskStarted("I"),
			userResponse("I", "interrupted prompt"),
			userEvent("interrupted prompt", "client-interrupted"),
			userResponse("I", v1AbortWrapper),
			userResponse("I", v1AbortWrapper),
			turnAborted("I"),
		]),
	]);
	auto wrongAbortReason = joinParts([
		simpleRollout("U1", "client-retained", "retained prompt", "retained answer"),
		joinParts([
			taskStarted("I"),
			userResponse("I", "interrupted prompt"),
			userEvent("interrupted prompt", "client-interrupted"),
			userResponse("I", v1AbortWrapper),
			`{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"I","reason":"other","completed_at":1,"duration_ms":1}}`,
		]),
	]);
	foreach (rollout; [duplicateInterruptedWrapper, wrongAbortReason])
		expectLedgerRefusal(HistoryBoundary("line:8", HistoryBoundaryKind.user, null),
			rollout, jsonParse!ThreadReadResult(interruptedLedger),
			NativeUndoPreparationRefusalCategory.unsupportedSuffix);

	auto lengthMismatch = jsonParse!ThreadReadResult(oneTurnLedger);
	lengthMismatch.rawTurns.length = 0;
	expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
		simpleRollout("U1", "client-one", "prompt", "answer"), lengthMismatch,
		NativeUndoPreparationRefusalCategory.ledger);
	expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
		simpleRollout("U1", "client-one", "prompt", "answer"),
		jsonParse!ThreadReadResult(ledger([
			simpleTurn("", "client-one", "prompt", "answer"),
		])), NativeUndoPreparationRefusalCategory.ledger);
	expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
		simpleRollout("U1", "client-one", "prompt", "answer"),
		jsonParse!ThreadReadResult(ledger([
			simpleTurn("U1", "client-one", "prompt", "answer"),
			simpleTurn("U1", "client-two", "prompt two", "answer two"),
		])), NativeUndoPreparationRefusalCategory.ledger);

	auto nonFullPrefix = `{"id":"U1","items":[],"itemsView":"summary","status":"completed","error":null,"startedAt":1,"completedAt":1,"durationMs":1}`;
	expectLedgerRefusal(HistoryBoundary("line:8", HistoryBoundaryKind.user, null),
		duplicateRollout, jsonParse!ThreadReadResult(ledger([
			nonFullPrefix,
			simpleTurn("U2", "client-duplicate-two", "same prompt", "answer two"),
		])), NativeUndoPreparationRefusalCategory.ledger);

	// Legacy callers are admitted only by the complete null-client triangle.
	auto legacyMissingComplete = joinParts([
		taskStarted("L"),
		userResponse("L", "legacy prompt"),
		userEvent("legacy prompt", "", false),
		assistantResponse("L", "legacy answer", "raw-agent-L"),
		agentEvent("legacy answer"),
	]);
	auto legacyMissingStart = joinParts([
		userResponse("L", "legacy prompt"),
		userEvent("legacy prompt", "", false),
		assistantResponse("L", "legacy answer", "raw-agent-L"),
		agentEvent("legacy answer"),
		taskComplete("L", "legacy answer"),
	]);
	auto legacyImplicitClient = joinParts([
		taskStarted("L"),
		userResponse("L", "legacy prompt"),
		`{"type":"event_msg","payload":{"type":"user_message","client_id":null,"message":"legacy prompt","images":[],"local_images":[],"text_elements":[]}}`,
		assistantResponse("L", "legacy answer", "raw-agent-L"),
		agentEvent("legacy answer"),
		taskComplete("L", "legacy answer"),
	]);
	expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
		legacyMissingComplete, jsonParse!ThreadReadResult(legacyLedger),
		NativeUndoPreparationRefusalCategory.unsupportedSuffix);
	expectLedgerRefusal(HistoryBoundary("line:1", HistoryBoundaryKind.user, null),
		legacyMissingStart, jsonParse!ThreadReadResult(legacyLedger),
		NativeUndoPreparationRefusalCategory.unsupportedSuffix);
	expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
		legacyImplicitClient, jsonParse!ThreadReadResult(legacyLedger),
		NativeUndoPreparationRefusalCategory.association);
	expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
		legacyRollout, jsonParse!ThreadReadResult(ledger([
			simpleTurn("L", "unexpected-client", "legacy prompt", "legacy answer"),
		])), NativeUndoPreparationRefusalCategory.unsupportedSuffix);

	// A same-turn steering record cannot become a second caller by accident.
	auto steeringRollout = joinParts([
		taskStarted("U1"),
		userResponse("U1", "prompt"),
		userEvent("prompt", "client-one"),
		userResponse("U1", "steer"),
		userEvent("steer", "client-steer"),
		assistantResponse("U1", "answer", "raw-agent-U1"),
		agentEvent("answer"),
		taskComplete("U1", "answer"),
	]);
	expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
		steeringRollout, jsonParse!ThreadReadResult(oneTurnLedger),
		NativeUndoPreparationRefusalCategory.association);

	// Materialized simple turns must retain the exact completed two-item shape.
	auto baseSimpleTurn = simpleTurn("U1", "client-one", "prompt", "answer");
	foreach (badTurn; [
		baseSimpleTurn.replace(`"status":"completed"`, `"status":"failed"`),
		baseSimpleTurn.replace(`"itemsView":"full"`, `"itemsView":"summary"`),
		baseSimpleTurn.replace(`"error":null`, `"error":{"message":"boom"}`),
		baseSimpleTurn.replace(`"text_elements":[]`, `"text_elements":[{"type":"mention"}]`),
		baseSimpleTurn.replace(`"phase":null`, `"phase":"commentary"`),
		baseSimpleTurn.replace(`"memoryCitation":null}`, `"memoryCitation":null,"future":true}`),
		baseSimpleTurn.replace(`],"itemsView"`, `,{"type":"reasoning","id":"reasoning-item"}],"itemsView"`),
	])
		expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
			simpleRollout("U1", "client-one", "prompt", "answer"),
			jsonParse!ThreadReadResult(ledger([badTurn])),
			NativeUndoPreparationRefusalCategory.unsupportedSuffix);

	// Contextual top-level data is only admitted in the captured pre-submission
	// shapes; a future/malformed context record cannot be silently ignored.
	auto malformedTurnContext = joinParts([
		taskStarted("U1"),
		`{"type":"turn_context","payload":{"turn_id":"U1"}}`,
		userResponse("U1", "prompt"),
		userEvent("prompt", "client-one"),
		assistantResponse("U1", "answer", "raw-agent-U1"),
		agentEvent("answer"),
		taskComplete("U1", "answer"),
	]);
	expectLedgerRefusal(HistoryBoundary("line:3", HistoryBoundaryKind.user, null),
		malformedTurnContext, jsonParse!ThreadReadResult(oneTurnLedger),
		NativeUndoPreparationRefusalCategory.unsupportedSuffix);

	// Compaction is a single final ledger position with its exact raw trio.
	auto missingCompactionEvent = joinParts([
		simpleRollout("U1", "client-one", "prompt", "answer"),
		taskStarted("C"),
		assistantResponse("C", "Conversation summary: previous context compacted.",
			"raw-agent-C"),
		compactedLine("C", ["U1", "C"]),
		compactionComplete("C"),
	]);
	auto simpleAndCompactionLedger = ledger([
		simpleTurn("U1", "client-one", "prompt", "answer"),
		compactionTurn("C"),
	]);
	expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
		missingCompactionEvent, jsonParse!ThreadReadResult(simpleAndCompactionLedger),
		NativeUndoPreparationRefusalCategory.unsupportedSuffix);
	auto compactionBeforeUserRollout = joinParts([
		simpleRollout("U1", "client-one", "prompt", "answer"),
		compactionRollout("C", ["U1", "C"]),
		simpleRollout("U2", "client-two", "later prompt", "later answer"),
	]);
	expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
		compactionBeforeUserRollout, jsonParse!ThreadReadResult(ledger([
			simpleTurn("U1", "client-one", "prompt", "answer"),
			compactionTurn("C"),
			simpleTurn("U2", "client-two", "later prompt", "later answer"),
		])), NativeUndoPreparationRefusalCategory.unsupportedSuffix);

	// An interrupted turn is terminal only; later materialization is not an
	// admitted suffix even if each raw lifecycle looks valid on its own.
	auto interruptedThenSimple = joinParts([
		interruptedRollout,
		simpleRollout("U2", "client-two", "later prompt", "later answer"),
	]);
	expectLedgerRefusal(HistoryBoundary("line:8", HistoryBoundaryKind.user, null),
		interruptedThenSimple, jsonParse!ThreadReadResult(ledger([
			simpleTurn("U1", "client-retained", "retained prompt", "retained answer"),
			`{"id":"I","items":[{"type":"userMessage","id":"user-item-I","clientId":"client-interrupted","content":[{"type":"text","text":"interrupted prompt","text_elements":[]}]}],"itemsView":"full","status":"interrupted","error":null,"startedAt":1,"completedAt":1,"durationMs":1}`,
			simpleTurn("U2", "client-two", "later prompt", "later answer"),
		])), NativeUndoPreparationRefusalCategory.unsupportedSuffix);

	// Native liveness follows the task_started segment: a trailing contextual
	// user record cannot protect the target from a one-turn marker rollback.
	auto contextTailMarker = simpleRollout("U1", "client-one", "prompt", "answer")
		~ "\n" ~ userResponse("U1", "[SYSTEM: context tail]") ~ "\n"
		~ `{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`;
	expectLedgerRefusal(HistoryBoundary("line:2", HistoryBoundaryKind.user, null),
		contextTailMarker, jsonParse!ThreadReadResult(oneTurnLedger),
		NativeUndoPreparationRefusalCategory.targetUnavailable);
	}
