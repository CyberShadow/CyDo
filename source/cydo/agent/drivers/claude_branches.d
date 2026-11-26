/// Claude Code session files are trees, not logs: every message row names
/// its parent (`parentUuid`), and the conversation is the chain of ancestors
/// of the latest leaf. A rewind (`rewind_conversation`, the TUI's /rewind)
/// does not rewrite the file. It appends a `last-prompt` marker with
/// `"rewound":true` whose `leafUuid` is the row preceding the cut. Turns
/// written later chain onto a row before the cut, and the rows of the undone
/// turns stay in the file as a dead branch.
///
/// CyDo reads session files line by line, so it must leave those rows out
/// to show the conversation the CLI continues.
module cydo.agent.drivers.claude_branches;

import std.algorithm : canFind;
import std.exception : enforce;
import std.json : JSONException, JSONType, JSONValue, parseJSON;
import cydo.foundation.text.jsonl : jsonlRows;

/// The 1-based lines of a Claude session file that belong to rewound
/// branches, i.e. are not part of the conversation the CLI continues.
///
/// Only rows the file itself proves abandoned are reported. Each rewind
/// marker spans the rows from its leaf to the marker. A row in such a span
/// is rewound when it is a message row off the final leaf's ancestor chain,
/// or a row without a UUID whose next message row is rewound. The marker
/// itself is also rewound. Rows outside these spans are never reported.
bool[int] claudeRewoundLines(string content)
{
	if (!content.canFind(`"rewound":true`))
		return null;

	static struct Row
	{
		string uuid;
		string parent; // parentUuid, else logicalParentUuid across compactions
		bool rewindMarker;
		bool hasLeaf; // a last-prompt row naming the leaf (possibly none)
		string leaf;
	}

	Row[] rows;
	size_t[string] lineOfUuid; // 0-based row index
	string finalLeaf;
	foreach (line; content.jsonlRows)
	{
		Row row;
		scope(success) rows ~= row;
		if (line.length == 0)
			continue;
		bool lastPrompt = line.canFind(`"last-prompt"`);
		if (!lastPrompt && !line.canFind(`"uuid"`))
			continue;
		JSONValue json;
		try
			json = parseJSON(line);
		catch (JSONException)
			continue; // the last line may still be being written
		if (json.type != JSONType.object)
			continue;
		string str(string key)
		{
			auto value = key in json.object;
			return value !is null && value.type == JSONType.string ? value.str : null;
		}
		if (str("type") == "last-prompt")
		{
			auto leaf = "leafUuid" in json.object;
			if (leaf is null)
				continue;
			row.hasLeaf = true;
			row.leaf = leaf.type == JSONType.string ? leaf.str : null;
			auto rewound = "rewound" in json.object;
			row.rewindMarker = rewound !is null && rewound.type == JSONType.true_;
			finalLeaf = row.leaf;
			continue;
		}
		row.uuid = str("uuid");
		if (row.uuid.length == 0)
			continue;
		row.parent = str("parentUuid");
		if (row.parent.length == 0)
			row.parent = str("logicalParentUuid");
		lineOfUuid[row.uuid] = rows.length;
		auto sidechain = "isSidechain" in json.object;
		if (sidechain is null || sidechain.type != JSONType.true_)
			finalLeaf = row.uuid;
	}

	bool[string] active;
	for (auto uuid = finalLeaf; uuid.length > 0 && uuid !in active; )
	{
		active[uuid] = true;
		auto index = uuid in lineOfUuid;
		if (index is null)
			break;
		uuid = rows[*index].parent;
	}

	bool[int] rewound;
	foreach (markerIndex, marker; rows)
	{
		if (!marker.rewindMarker)
			continue;
		size_t start = 0;
		if (marker.leaf.length > 0)
		{
			auto leafIndex = marker.leaf in lineOfUuid;
			enforce(leafIndex !is null && *leafIndex < markerIndex,
				"Claude rewind marker names a leaf not recorded before it: " ~ marker.leaf);
			start = *leafIndex + 1;
		}
		// Walk backwards so each row without a UUID can follow the next
		// message row's verdict.
		bool nextRewound = true;
		foreach_reverse (i; start .. markerIndex)
		{
			if (rows[i].uuid.length > 0)
				nextRewound = rows[i].uuid !in active;
			if (nextRewound)
				rewound[cast(int) i + 1] = true;
		}
		rewound[cast(int) markerIndex + 1] = true;
	}
	return rewound;
}

// The shape written by Claude Code 2.1.319: rewinding the second turn and
// then sending a third. The third chains onto the attachment that follows
// the first turn's reply, although the marker names the reply itself.
unittest
{
	import std.array : join;

	auto content = [
		/* 1 */ `{"type":"queue-operation","operation":"enqueue","content":"first"}`,
		/* 2 */ `{"type":"queue-operation","operation":"dequeue"}`,
		/* 3 */ `{"type":"user","uuid":"u1","parentUuid":null,"message":{"role":"user","content":"first"}}`,
		/* 4 */ `{"type":"assistant","uuid":"a1","parentUuid":"u1"}`,
		/* 5 */ `{"type":"attachment","uuid":"at1","parentUuid":"a1"}`,
		/* 6 */ `{"type":"last-prompt","lastPrompt":"first","leafUuid":"at1"}`,
		/* 7 */ `{"type":"queue-operation","operation":"enqueue","content":"second"}`,
		/* 8 */ `{"type":"queue-operation","operation":"dequeue"}`,
		/* 9 */ `{"type":"user","uuid":"u2","parentUuid":"at1","message":{"role":"user","content":"second"}}`,
		/* 10 */ `{"type":"file-history-snapshot","messageId":"u2"}`,
		/* 11 */ `{"type":"assistant","uuid":"a2","parentUuid":"u2"}`,
		/* 12 */ `{"type":"last-prompt","lastPrompt":"second","leafUuid":"a1","explicit":true,"rewound":true,"cutUuid":"u2"}`,
		/* 13 */ `{"type":"last-prompt","lastPrompt":"second","leafUuid":"a1"}`,
		/* 14 */ `{"type":"cost-state"}`,
		/* 15 */ `{"type":"queue-operation","operation":"enqueue","content":"third"}`,
		/* 16 */ `{"type":"queue-operation","operation":"dequeue"}`,
		/* 17 */ `{"type":"user","uuid":"u3","parentUuid":"at1","message":{"role":"user","content":"third"}}`,
		/* 18 */ `{"type":"assistant","uuid":"a3","parentUuid":"u3"}`,
		/* 19 */ `{"type":"last-prompt","lastPrompt":"third","leafUuid":"a3"}`,
	].join("\n") ~ "\n";

	import std.algorithm : sort;
	import std.array : array;
	assert(claudeRewoundLines(content).keys.sort.array == [6, 7, 8, 9, 10, 11, 12]);

	// Before the third turn the leaf is the marker's: the attachment after
	// the reply is off the conversation as well.
	auto rewoundOnly = content.jsonlRows.array[0 .. 13].join("\n") ~ "\n";
	assert(claudeRewoundLines(rewoundOnly).keys.sort.array == [5, 6, 7, 8, 9, 10, 11, 12]);

	// Without a rewind marker nothing is rewound, whatever the chain says.
	assert(claudeRewoundLines(content.jsonlRows.array[0 .. 11].join("\n")) is null);
}

// Rewinding to the first message leaves no leaf: everything up to the
// marker is rewound. A second rewind in the new branch nests.
unittest
{
	import std.algorithm : sort;
	import std.array : array, join;

	auto content = [
		/* 1 */ `{"type":"user","uuid":"u1","parentUuid":null,"message":{"role":"user","content":"first"}}`,
		/* 2 */ `{"type":"assistant","uuid":"a1","parentUuid":"u1"}`,
		/* 3 */ `{"type":"last-prompt","leafUuid":null,"explicit":true,"rewound":true,"cutUuid":"u1"}`,
		/* 4 */ `{"type":"user","uuid":"u2","parentUuid":null,"message":{"role":"user","content":"again"}}`,
		/* 5 */ `{"type":"assistant","uuid":"a2","parentUuid":"u2"}`,
		/* 6 */ `{"type":"user","uuid":"u3","parentUuid":"a2","message":{"role":"user","content":"more"}}`,
		/* 7 */ `{"type":"assistant","uuid":"a3","parentUuid":"u3"}`,
		/* 8 */ `{"type":"last-prompt","leafUuid":"a2","explicit":true,"rewound":true,"cutUuid":"u3"}`,
	].join("\n");
	assert(claudeRewoundLines(content).keys.sort.array == [1, 2, 3, 6, 7, 8]);
}

// A marker whose leaf was never recorded is a format this reader does not
// understand: refuse rather than guess.
unittest
{
	import std.exception : assertThrown;

	assertThrown(claudeRewoundLines(
		`{"type":"last-prompt","leafUuid":"missing","rewound":true}`));
}

// Keep only the first turn's tool exchange and final reply from the capture.
version (unittest) enum claudeQueueCutRows = [
	`{"type":"user","version":"2.1.330","uuid":"prior","message":{"role":"user","content":"prior"}}`,
	`{"type":"assistant","uuid":"tool","parentUuid":"prior","message":{"id":"P","content":[{"type":"tool_use","id":"t","name":"Bash","input":{"command":"true"}}]}}`,
	`{"type":"user","uuid":"result","parentUuid":"tool","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}}`,
	`{"type":"queue-operation","operation":"enqueue","content":"X"}`,
	`{"type":"assistant","uuid":"A","parentUuid":"result","message":{"id":"P2","content":[{"type":"text","text":"prior reply"}]}}`,
	`{"type":"queue-operation","operation":"dequeue"}`,
	`{"type":"user","uuid":"x","parentUuid":"A","message":{"role":"user","content":"X"}}`,
	`{"type":"assistant","uuid":"reply","parentUuid":"x","message":{"id":"reply","content":[{"type":"text","text":"X reply"}]}}`,
	`{"type":"last-prompt","lastPrompt":"X"}`,
];

version (unittest) private enum rewindFirstTurnMetadata = ()
{
	auto rows = new string[](25);
	rows[] = `{"type":"api-request","version":"2.1.330"}`;
	return rows;
}();

version (unittest) enum claudeQueueRewindRows = claudeQueueCutRows[0 .. 3]
	~ rewindFirstTurnMetadata ~ claudeQueueCutRows[3 .. 5] ~ [
	`{"type":"queue-operation","operation":"enqueue","content":"Y"}`,
] ~ claudeQueueCutRows[5 .. 7] ~ [
	`{"type":"file-history-snapshot","messageId":"x"}`,
	`{"type":"api-request","version":"2.1.330"}`,
	`{"type":"queue-operation","operation":"enqueue","content":"steer abandoned turn"}`,
	`{"type":"queue-operation","operation":"remove","reason":"absorbed_mid_turn","content":"steer abandoned turn","commandUuid":"S"}`,
	`{"type":"attachment","uuid":"attach","parentUuid":"x","attachment":{"type":"queued_command","prompt":"steer abandoned turn","source_uuid":"S"}}`,
	claudeQueueCutRows[7],
	`{"type":"last-prompt","lastPrompt":"X","rewound":true,"leafUuid":"A","cutUuid":"x"}`,
];

version (unittest) enum claudeLegacyQueueRewindRows = claudeQueueRewindRows[0 .. 30]
	~ claudeQueueRewindRows[31 .. 34] ~ [
	`{"type":"api-request","version":"2.1.249"}`,
	claudeQueueRewindRows[35],
	claudeQueueCutRows[5],
	claudeQueueRewindRows[30],
] ~ claudeQueueRewindRows[$ - 2 .. $];

@("Claude native rewind inactivates the enqueue before the retained leaf")
unittest
{
	import std.algorithm : sort;
	import std.array : array, join;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;

	auto agent = new ClaudeCodeAgent();
	auto content = claudeQueueRewindRows.join("\n") ~ "\n";
	assert(agent.inactiveHistoryLines(content).keys.sort.array == [29, 32, 33, 34, 35, 36, 37, 38, 39, 40]);
	assert(claudeRewoundLines(content).keys.sort.array == [31, 32, 33, 34, 35, 36, 37, 38, 39, 40]);
	assert(agent.inactiveHistoryLines(claudeQueueRewindRows[0 .. $ - 1].join("\n")) is null);
}

@("Claude native rewind inactivates legacy dequeue steering")
unittest
{
	import std.algorithm : sort;
	import std.array : array, join;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;

	auto content = claudeLegacyQueueRewindRows.join("\n") ~ "\n";
	assert((new ClaudeCodeAgent()).inactiveHistoryLines(content).keys.sort.array
		== [29, 31, 32, 33, 34, 35, 36, 38, 39]);
	assert(claudeRewoundLines(content).keys.sort.array == [31, 32, 33, 34, 35, 36, 37, 38, 39]);
}
