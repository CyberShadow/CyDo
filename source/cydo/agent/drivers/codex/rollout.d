module cydo.agent.drivers.codex.rollout;

import std.conv : to;
import std.logger : tracef;
import std.typecons : Nullable;

import ae.utils.json : JSONFragment, JSONOptional, JSONPartial, jsonParse, toJson;

import cydo.agent.contract : ForkableIdInfo;
import cydo.protocol : ContentBlock;

package enum ForkableMessageRole
{
	none,
	user,
	assistant,
}

package struct RolloutLineProbe
{
	bool isSessionMeta;
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

/// Parse one rollout JSONL line and return only the fields relevant to
/// history/forkable-line classification.
package RolloutLineProbe parseRolloutLineProbe(string line)
{
	@JSONPartial
	static struct TopLevelProbe
	{
		@JSONOptional string type;
		@JSONOptional JSONFragment payload;
	}

	@JSONPartial
	static struct PayloadProbe
	{
		@JSONOptional string type;
		@JSONOptional string role;
		@JSONOptional uint num_turns;
	}

	RolloutLineProbe result;
	try
	{
		auto top = jsonParse!TopLevelProbe(line);
		result.isSessionMeta = top.type == "session_meta";
		result.isResponseItem = top.type == "response_item";
		result.isEventMsg = top.type == "event_msg";

		if (top.payload.json is null || top.payload.json.length == 0)
			return result;

		auto payload = jsonParse!PayloadProbe(top.payload.json);
		if (result.isEventMsg)
		{
			result.isTaskStarted = payload.type == "task_started";
			result.isThreadRolledBack = payload.type == "thread_rolled_back";
			if (result.isThreadRolledBack)
				result.rollbackNumTurns = payload.num_turns;
		}
		if (result.isResponseItem && payload.type == "message")
		{
			if (payload.role == "user")
				result.messageRole = ForkableMessageRole.user;
			else if (payload.role == "assistant")
				result.messageRole = ForkableMessageRole.assistant;
		}
	}
	catch (Exception) {}
	return result;
}

/// Parse `num_turns` from a ThreadRolledBack event_msg JSONL line.
/// The payload is `{"type":"thread_rolled_back","num_turns":N}`.
/// Returns 0 if parsing fails.
uint parseRollbackNumTurns(string line)
{
	auto probe = parseRolloutLineProbe(line);
	return probe.isThreadRolledBack ? probe.rollbackNumTurns : 0;
}

/// Apply a rollback to a list of fork IDs: remove the last N user-turn groups.
/// A user-turn group is a user message and all following assistant messages
/// until the next user message.
string[] applyRollbackToIds(string[] ids, uint numTurns)
{
	if (numTurns == 0 || ids.length == 0)
		return ids;

	auto toRemove = numTurns * 2;
	if (toRemove >= ids.length)
		return [];
	return ids[0 .. $ - toRemove];
}

/// Apply a rollback to a list of ForkableIdInfo: remove the last N user-turn groups.
ForkableIdInfo[] applyRollbackToIdsWithInfo(ForkableIdInfo[] ids, uint numTurns)
{
	if (numTurns == 0 || ids.length == 0)
		return ids;

	// Find the position of the Nth-from-last user message
	uint usersSeen = 0;
	for (size_t i = ids.length; i > 0; i--)
	{
		if (ids[i - 1].isUser)
		{
			usersSeen++;
			if (usersSeen >= numTurns)
				return ids[0 .. i - 1];
		}
	}
	// Fewer user messages than numTurns — remove everything
	return [];
}

package ForkableIdInfo[] extractForkableIdsWithInfoImpl(string content, int lineOffset = 0)
{
	import std.string : lineSplitter;

	ForkableIdInfo[] ids;
	int lineNum = lineOffset;
	// Codex prepends system context as a role=user response_item before the
	// first task_started event. Skip role=user lines until task_started is seen
	// so the system context is not treated as a forkable user message.
	bool seenTaskStarted = lineOffset > 0;
	foreach (line; content.lineSplitter)
	{
		lineNum++;
		if (line.length == 0)
			continue;
		auto probe = parseRolloutLineProbe(line);
		if (!seenTaskStarted && probe.isTaskStarted)
		{
			seenTaskStarted = true;
			continue;
		}
		if (probe.isThreadRolledBack)
		{
			if (probe.rollbackNumTurns > 0)
				ids = applyRollbackToIdsWithInfo(ids, probe.rollbackNumTurns);
			continue;
		}
		if (!probe.isForkableMessage)
			continue;
		if (probe.isUserMessage && !seenTaskStarted)
			continue;
		if (probe.isUserMessage && isCodexContextOnlyUserMessageLine(line))
			continue;
		ids ~= ForkableIdInfo("line:" ~ to!string(lineNum), probe.isUserMessage);
	}
	return ids;
}

package bool isCodexContextOnlyUserText(string text)
{
	import std.string : startsWith, stripLeft;

	auto trimmed = text.stripLeft;
	return trimmed.startsWith("<permissions instructions>")
		|| trimmed.startsWith("<environment_context>");
}

package bool isCodexContextOnlyUserMessageLine(string line)
{
	@JSONPartial
	static struct Probe
	{
		@JSONPartial
		static struct Payload
		{
			string type;
			string role;
			JSONFragment content;
		}
		Payload payload;
	}
	@JSONPartial
	static struct TextBlock
	{
		string type;
		@JSONOptional string text;
	}

	try
	{
		auto probe = jsonParse!Probe(line);
		if (probe.payload.type != "message" || probe.payload.role != "user"
			|| probe.payload.content.json is null)
			return false;
		string text;
		foreach (ref block; jsonParse!(TextBlock[])(probe.payload.content.json))
			if (block.type == "text")
				text ~= block.text;
		return isCodexContextOnlyUserText(text);
	}
	catch (Exception)
		return false;
}

enum CodexActiveUserTurnsAfterStatus
{
	ok,
	targetMissing,
	targetNotUser,
}

struct CodexActiveUserTurnsAfterResult
{
	CodexActiveUserTurnsAfterStatus status;
	int count;
	int visibleCount;
}

/// Count active (marker-aware) user turns after `forkId` in Codex JSONL content.
/// Returns status `ok` with count for valid user targets, otherwise a status
/// describing whether the target is missing from active history or non-user.
CodexActiveUserTurnsAfterResult countActiveUserTurnsAfterForkId(string content, string forkId)
{
	auto ids = extractForkableIdsWithInfoImpl(content);

	size_t targetIdx = size_t.max;
	foreach (i, ref idInfo; ids)
	{
		if (idInfo.id == forkId)
		{
			targetIdx = i;
			break;
		}
	}

	if (targetIdx == size_t.max)
		return CodexActiveUserTurnsAfterResult(CodexActiveUserTurnsAfterStatus.targetMissing, 0, 0);
	if (!ids[targetIdx].isUser)
		return CodexActiveUserTurnsAfterResult(CodexActiveUserTurnsAfterStatus.targetNotUser, 0, 0);

	int count = 0;
	int visibleCount = 0;
	// Codex rollback counts active user segments. For UI preview, also provide
	// visible-turn counting where consecutive user lines are collapsed.
	bool inUserTurn = true;
	foreach (ref idInfo; ids[targetIdx + 1 .. $])
	{
		if (idInfo.isUser)
		{
			count++;
			if (!inUserTurn)
				visibleCount++;
			inUserTurn = true;
		}
		else
		{
			inUserTurn = false;
		}
	}
	return CodexActiveUserTurnsAfterResult(CodexActiveUserTurnsAfterStatus.ok, count, visibleCount);
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
	import std.algorithm : canFind;
	import std.string : lineSplitter;

	if (!content.canFind("thread_rolled_back"))
		return (bool[int]).init;

	struct TurnBoundary { int lineNum; }
	TurnBoundary[] userTurnStarts;
	struct RollbackInfo { int lineNum; uint numTurns; }
	RollbackInfo[] rollbacks;

	bool seenTaskStarted = false;
	int lineNum = 0;
	foreach (line; content.lineSplitter)
	{
		lineNum++;
		if (line.length == 0)
			continue;
		auto probe = parseRolloutLineProbe(line);
		if (!seenTaskStarted && probe.isTaskStarted)
		{
			seenTaskStarted = true;
			continue;
		}
		if (probe.isThreadRolledBack)
		{
			rollbacks ~= RollbackInfo(lineNum, probe.rollbackNumTurns);
			continue;
		}
		if (seenTaskStarted && probe.isUserMessage)
			userTurnStarts ~= TurnBoundary(lineNum);
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

	// Test applyRollbackToIdsWithInfo
	auto ids = [
		ForkableIdInfo("line:1", true),
		ForkableIdInfo("line:2", false),
		ForkableIdInfo("line:3", true),
		ForkableIdInfo("line:4", false),
		ForkableIdInfo("line:5", true),
		ForkableIdInfo("line:6", false),
	];
	auto rolled1 = applyRollbackToIdsWithInfo(ids, 1);
	assert(rolled1.length == 4, "rollback 1 should remove last user turn group");
	assert(rolled1[$ - 1].id == "line:4");

	auto rolled2 = applyRollbackToIdsWithInfo(ids, 2);
	assert(rolled2.length == 2, "rollback 2 should remove last 2 user turn groups");
	assert(rolled2[$ - 1].id == "line:2");

	auto rolledAll = applyRollbackToIdsWithInfo(ids, 10);
	assert(rolledAll.length == 0, "rollback > total should remove everything");

	// Test countActiveUserTurnsAfterForkId with rollback markers
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
			`{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}`;

		auto ok = countActiveUserTurnsAfterForkId(jsonl, "line:4");
		assert(ok.status == CodexActiveUserTurnsAfterStatus.ok);
		assert(ok.count == 1, "only visible user turn after line:4 should be counted");
		assert(ok.visibleCount == 1, "visible turn count should match collapsed user runs");

		auto hidden = countActiveUserTurnsAfterForkId(jsonl, "line:6");
		assert(hidden.status == CodexActiveUserTurnsAfterStatus.targetMissing);

		auto assistant = countActiveUserTurnsAfterForkId(jsonl, "line:5");
		assert(assistant.status == CodexActiveUserTurnsAfterStatus.targetNotUser);
	}

	// Count user-turn groups, not raw user lines, after rollback.
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
			`{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}` ~ "\n" ~
			`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}`;

		auto afterSecond = countActiveUserTurnsAfterForkId(jsonl, "line:4");
		assert(afterSecond.status == CodexActiveUserTurnsAfterStatus.ok);
		assert(afterSecond.count == 2,
			"rollback count should include all active user segments");
		assert(afterSecond.visibleCount == 1,
			"consecutive user lines for one turn must collapse in preview count");
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
		// custom_tool_call.input is string payload. Wrap plain string into {"input": "..."}
		// so frontend parser can recover apply_patch text consistently.
		string inputJson = `{}`;
		auto rawInput = probe.payload.input;
		if (rawInput.length > 0)
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
	else
		return [];

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
	else
		ev.content = JSONFragment(outputJson);
	return toJson(ev);
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
