/// Interpretation of the queue records Claude Code writes to its session file.
///
/// Every user message the CLI receives is recorded at receipt as a
/// `queue-operation` `enqueue` row carrying only the message text. What
/// became of the message is recorded later, in one of these shapes:
///
/// - consumed as a turn opener: a `dequeue` row followed by the echoed
///   `user` row (possibly after a synthetic assistant row), whose text
///   matches the enqueue unless the message was since edited;
/// - absorbed mid-turn as steering (≥2.1.250): a `remove` row with reason
///   `absorbed_mid_turn` and the message text, next to a `queued_command`
///   attachment;
/// - withdrawn before consumption (`cancel_async_message`, ≥2.1.250): an
///   anonymous `dequeue` row with no echo. It names neither the message nor
///   its text, and need not target the front of the queue.
///
/// Older CLIs wrote reason-less `remove` rows for messages taken off the
/// queue unconsumed, and classified mid-turn consumption only by assistant
/// output following a `dequeue` with no echo.
///
/// Outcomes therefore cannot be decided one row at a time: deciding whether a
/// `dequeue` opened a turn needs lookahead, and a withdrawal can only be
/// attributed once every other message has been accounted for. This module
/// classifies the whole file up front.
module cydo.agent.drivers.claude_queue;

import std.string : lineSplitter;

import ae.utils.json : JSONFragment, JSONName, JSONOptional, JSONPartial, jsonParse;

enum ClaudeQueueOutcomeKind
{
	/// No outcome recorded: still queued when the session file ends.
	queued,
	/// Consumed as a turn opener; `line` is the echoed user row.
	turnStart,
	/// Absorbed into the running turn; `line` is the recording row.
	steering,
	/// Taken off the queue unconsumed by a pre-2.1.250 CLI.
	removed,
	/// Withdrawn by the host before consumption; `line` is its `dequeue` row.
	cancelled,
}

struct ClaudeQueueOutcome
{
	ClaudeQueueOutcomeKind kind;
	/// 1-based line at which the outcome is recorded; 0 for `queued`.
	int line;
}

/// Classify every `enqueue` row of a Claude session file, keyed by its
/// 1-based line number. Rows on `inactiveLines` (rewound branches) are
/// ignored.
ClaudeQueueOutcome[int] classifyClaudeQueueRecords(string content,
	const bool[int] inactiveLines)
{
	Row[] rows;
	foreach (line; content.lineSplitter)
		rows ~= cast(int) rows.length + 1 in inactiveLines ? Row.init : Row.parse(line);

	ClaudeQueueOutcome[int] outcomes;
	Entry[] queued; // unresolved enqueues, in enqueue order
	int[] withdrawals; // dequeue lines that opened no turn (≥2.1.250)
	bool legacy = true;

	void resolve(size_t queueIndex, ClaudeQueueOutcomeKind kind, int line)
	{
		outcomes[queued[queueIndex].line] = ClaudeQueueOutcome(kind, line);
		queued = queued[0 .. queueIndex] ~ queued[queueIndex + 1 .. $];
	}

	// Index of the oldest unresolved message with this text, else the front.
	size_t byText(string text)
	{
		foreach (i, entry; queued)
			if (entry.text == text)
				return i;
		return 0;
	}

	foreach (i, row; rows)
	{
		auto lineNum = cast(int) i + 1;
		if (row.version_.length > 0)
			legacy = versionBefore(row.version_, 2, 1, 250);
		if (row.kind != RowKind.queueOperation)
			continue;
		switch (row.operation)
		{
			case "enqueue":
				outcomes[lineNum] = ClaudeQueueOutcome(ClaudeQueueOutcomeKind.queued, 0);
				queued ~= Entry(lineNum, row.text);
				break;
			case "dequeue":
				if (queued.length == 0)
					break;
				auto echo = findEcho(rows, i + 1);
				if (echo >= 0)
					resolve(byText(rows[echo].text), ClaudeQueueOutcomeKind.turnStart,
						cast(int) echo + 1);
				else if (legacy)
					resolve(0, ClaudeQueueOutcomeKind.steering, lineNum);
				else
					withdrawals ~= lineNum;
				break;
			case "remove":
				if (queued.length == 0)
					break;
				if (row.reason == "absorbed_mid_turn")
					resolve(byText(row.text), ClaudeQueueOutcomeKind.steering, lineNum);
				else
					resolve(0, ClaudeQueueOutcomeKind.removed, lineNum);
				break;
			default:
				break;
		}
	}

	// A withdrawal record names no message. Every consumed message has been
	// matched by now, so each withdrawal belongs to one of the messages still
	// unresolved that were enqueued before it; the host withdraws the message
	// it sent most recently, so prefer the latest.
	foreach (withdrawal; withdrawals)
		foreach_reverse (j, entry; queued)
			if (entry.line < withdrawal)
			{
				resolve(j, ClaudeQueueOutcomeKind.cancelled, withdrawal);
				break;
			}
	return outcomes;
}

private:

struct Entry { int line; string text; }

enum RowKind { other, queueOperation, user }

struct Row
{
	RowKind kind;
	string version_;
	string operation;
	string reason;
	/// Queue rows: the recorded text. Canonical user rows: the message text.
	string text;
	/// A user row carrying a user-authored message (not a tool result or
	/// meta row).
	bool canonicalUser;

	static Row parse(string line)
	{
		@JSONPartial static struct Message { @JSONOptional JSONFragment content; }
		@JSONPartial static struct Probe
		{
			@JSONOptional string type;
			@JSONOptional @JSONName("version") string version_;
			@JSONOptional string operation;
			@JSONOptional string reason;
			@JSONOptional string content;
			@JSONOptional Message message;
		}

		Row row;
		if (line.length == 0)
			return row;
		Probe probe;
		try
			probe = jsonParse!Probe(line);
		catch (Exception)
			return row;
		row.version_ = probe.version_;
		import cydo.domain.tasks.model : isQueueOperationType;
		if (isQueueOperationType(probe.type))
		{
			row.kind = RowKind.queueOperation;
			row.operation = probe.operation;
			row.reason = probe.reason;
			row.text = probe.content;
		}
		else if (probe.type == "user")
		{
			row.kind = RowKind.user;
			import cydo.agent.drivers.claude : ClaudeCodeAgent;
			if (ClaudeCodeAgent.isCanonicalHistoryPrompt(line))
			{
				row.canonicalUser = true;
				canonicalText(probe.message.content, row.text);
			}
		}
		return row;
	}
}

/// Whether user message content is user-authored (text or images, not tool
/// results); if so, also yields its text.
bool canonicalText(JSONFragment content, out string text)
{
	import std.array : join;

	auto json = content.json;
	if (json.length == 0)
		return false;
	if (json[0] == '"')
	{
		text = jsonParse!string(json);
		return true;
	}
	if (json[0] != '[')
		return false;
	@JSONPartial static struct Block { string type; @JSONOptional string text; }
	Block[] blocks;
	try
		blocks = jsonParse!(Block[])(json);
	catch (Exception)
		return false;
	string[] texts;
	bool canonical;
	foreach (block; blocks)
	{
		if (block.type == "text")
			texts ~= block.text;
		canonical |= block.type == "text" || block.type == "image";
	}
	text = texts.join("\n");
	return canonical;
}

/// Find the echo of a dequeued message: the first canonical user row up to
/// the next queue record, other than an interruption marker. Returns its row
/// index, or -1 when the dequeue opened no turn.
///
/// The echo is identified by position, not text: editing a message rewrites
/// its echo row but not its enqueue record. Text only picks which queued
/// message the echo consumed.
ptrdiff_t findEcho(const Row[] rows, size_t from)
{
	foreach (i; from .. rows.length)
	{
		if (rows[i].kind == RowKind.queueOperation)
			return -1;
		if (!rows[i].canonicalUser
			|| rows[i].text == "[Request interrupted by user]"
			|| rows[i].text == "[Request interrupted by user for tool use]")
			continue;
		return cast(ptrdiff_t) i;
	}
	return -1;
}

bool versionBefore(string ver, int major, int minor, int patch)
{
	import std.array : split;
	import std.conv : to;

	auto parts = ver.split(".");
	if (parts.length < 3)
		return false;
	int[3] have;
	try
		foreach (i; 0 .. 3)
			have[i] = parts[i].to!int;
	catch (Exception)
		return false;
	int[3] want = [major, minor, patch];
	return have < want;
}

unittest
{
	assert(versionBefore("2.1.241", 2, 1, 250));
	assert(!versionBefore("2.1.250", 2, 1, 250));
	assert(!versionBefore("2.1.319", 2, 1, 250));
	assert(versionBefore("2.0.76", 2, 1, 250));
}

// Shapes recorded by Claude Code 2.1.319 (captured from the real CLI).
unittest
{
	import std.array : join;

	auto content = [
		/* 1 */ `{"type":"queue-operation","operation":"enqueue","content":"run command sleep 4"}`,
		/* 2 */ `{"type":"queue-operation","operation":"dequeue"}`,
		/* 3 */ `{"type":"user","version":"2.1.319","uuid":"u1","message":{"role":"user","content":"run command sleep 4"}}`,
		/* 4 */ `{"type":"assistant","version":"2.1.319","uuid":"a1","message":{"content":[]}}`,
		// Two steers queued mid-turn; the second is withdrawn, the first absorbed.
		/* 5 */ `{"type":"queue-operation","operation":"enqueue","content":"steer two"}`,
		/* 6 */ `{"type":"queue-operation","operation":"enqueue","content":"steer three"}`,
		/* 7 */ `{"type":"queue-operation","operation":"dequeue"}`,
		/* 8 */ `{"type":"user","version":"2.1.319","uuid":"r1","message":{"role":"user","content":[{"tool_use_id":"t","type":"tool_result","content":"ok"}]}}`,
		/* 9 */ `{"type":"queue-operation","operation":"remove","content":"steer two","reason":"absorbed_mid_turn","commandUuid":"c2"}`,
		/* 10 */ `{"type":"attachment","attachment":{"type":"queued_command","prompt":"steer two","source_uuid":"c2"}}`,
		// A turn opened by a CyDo system message, echoed after a synthetic reply.
		/* 11 */ `{"type":"queue-operation","operation":"enqueue","content":"[SYSTEM: Mode switch]"}`,
		/* 12 */ `{"type":"queue-operation","operation":"dequeue"}`,
		/* 13 */ `{"type":"assistant","version":"2.1.319","message":{"content":[{"type":"text","text":"No response requested."}]}}`,
		/* 14 */ `{"type":"user","version":"2.1.319","uuid":"u3","message":{"role":"user","content":[{"type":"text","text":"[SYSTEM: Mode switch]"}]}}`,
		// Still queued when the session ended.
		/* 15 */ `{"type":"queue-operation","operation":"enqueue","content":"late"}`,
	].join("\n") ~ "\n";

	auto outcomes = classifyClaudeQueueRecords(content, null);
	with (ClaudeQueueOutcomeKind)
	{
		assert(outcomes[1] == ClaudeQueueOutcome(turnStart, 3));
		assert(outcomes[5] == ClaudeQueueOutcome(steering, 9));
		assert(outcomes[6] == ClaudeQueueOutcome(cancelled, 7));
		assert(outcomes[11] == ClaudeQueueOutcome(turnStart, 14));
		assert(outcomes[15] == ClaudeQueueOutcome(queued, 0));
	}
	assert(outcomes.length == 5);
}

// Editing a message rewrites its echo row but not its enqueue record.
unittest
{
	import std.array : join;

	auto content = [
		/* 1 */ `{"type":"queue-operation","operation":"enqueue","content":"original"}`,
		/* 2 */ `{"type":"queue-operation","operation":"dequeue"}`,
		/* 3 */ `{"type":"user","version":"2.1.319","uuid":"u1","message":{"role":"user","content":""}}`,
	].join("\n") ~ "\n";

	auto outcomes = classifyClaudeQueueRecords(content, null);
	assert(outcomes[1] == ClaudeQueueOutcome(ClaudeQueueOutcomeKind.turnStart, 3));
}

// A withdrawal is attributed only after consumed messages are matched, even
// when the withdrawn message is not at the front of the queue.
unittest
{
	import std.array : join;

	auto content = [
		/* 1 */ `{"type":"user","version":"2.1.319","uuid":"u0","message":{"role":"user","content":"x"}}`,
		/* 2 */ `{"type":"queue-operation","operation":"enqueue","content":"keep"}`,
		/* 3 */ `{"type":"queue-operation","operation":"enqueue","content":"withdraw"}`,
		/* 4 */ `{"type":"queue-operation","operation":"dequeue"}`,
		/* 5 */ `{"type":"queue-operation","operation":"dequeue"}`,
		/* 6 */ `{"type":"user","version":"2.1.319","uuid":"u2","message":{"role":"user","content":"keep"}}`,
	].join("\n") ~ "\n";

	auto outcomes = classifyClaudeQueueRecords(content, null);
	with (ClaudeQueueOutcomeKind)
	{
		assert(outcomes[2] == ClaudeQueueOutcome(turnStart, 6));
		assert(outcomes[3] == ClaudeQueueOutcome(cancelled, 4));
	}
}

// Pre-2.1.250 CLIs: a reason-less remove took the message off the queue
// unconsumed, and a dequeue with no echo was consumed mid-turn.
unittest
{
	import std.array : join;

	auto content = [
		/* 1 */ `{"type":"user","version":"2.1.220","uuid":"u0","message":{"role":"user","content":"x"}}`,
		/* 2 */ `{"type":"queue-operation","operation":"enqueue","content":"steer"}`,
		/* 3 */ `{"type":"queue-operation","operation":"dequeue"}`,
		/* 4 */ `{"type":"assistant","version":"2.1.220","message":{"content":[]}}`,
		/* 5 */ `{"type":"queue-operation","operation":"enqueue","content":"dropped"}`,
		/* 6 */ `{"type":"queue-operation","operation":"remove"}`,
	].join("\n") ~ "\n";

	auto outcomes = classifyClaudeQueueRecords(content, null);
	with (ClaudeQueueOutcomeKind)
	{
		assert(outcomes[2] == ClaudeQueueOutcome(steering, 3));
		assert(outcomes[5] == ClaudeQueueOutcome(removed, 6));
	}
}

@("Claude parent-linked queue confirmation waits for the canonical root echo")
unittest
{
	import std.array : join;
	import cydo.agent.drivers.claude : claudeParentLinkedQueueFixture;
	auto content = [
		claudeParentLinkedQueueFixture("queue-operation", "enqueue", "root"),
		claudeParentLinkedQueueFixture("queue/operation", "dequeue"),
		`{"type":"user","parent_tool_use_id":"t","message":{"content":"nested"}}`,
		`{"type":"user","isMeta":true,"turnCompanion":true,"message":{"content":"[Image: original 2x2]"}}`,
		`{"type": "user", "message":{"content":"root"}}`,
	].join("\n");
	auto outcomes = classifyClaudeQueueRecords(content, null);
	assert(outcomes[1] == ClaudeQueueOutcome(ClaudeQueueOutcomeKind.turnStart, 5));
}
