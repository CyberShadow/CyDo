module cydo.workflow.history.jsonl_store;

import core.lifetime : move;

import std.format : format;
import std.string : representation;

import ae.sys.data : Data;
import ae.utils.json : JSONFragment, toJson;

import cydo.protocol : TaskEventEnvelope, TranslatedEvent;
import cydo.domain.storage.persistence : LoadedHistory, Persistence, createForkTask, noSourceLine;

/// Load task history from a JSONL file.
/// Returns events wrapped in file-event envelopes paired with raw source lines.
/// translateLine is called for each line to allow agent-specific translation.
/// The delegate receives (line, 1-based lineNum) and returns zero or more translated
/// event pairs (empty array = skip, one element = normal, two = compaction injection).
/// maxBytes limits how many bytes of the file are read; ulong.max (default) reads all.
LoadedHistory loadTaskHistory(int tid, string jsonlPath,
	TranslatedEvent[] delegate(string, int) translateLine = null,
	ulong maxBytes = ulong.max)
{
	import std.file : exists, read;
	import std.string : lineSplitter;

	if (jsonlPath.length == 0 || !exists(jsonlPath))
		return LoadedHistory();

	LoadedHistory result;
	int lineNum = 0;
	foreach (line; (cast(string) read(jsonlPath, cast(size_t) maxBytes)).lineSplitter)
	{
		lineNum++;
		if (line.length == 0)
			continue;

		TranslatedEvent[] translated = translateLine !is null
			? translateLine(line, lineNum)
			: [TranslatedEvent(line, line)];

		// Wrap each translated event with file-event envelope; store raw separately.
		foreach (t; translated)
		{
			auto injected = toJson(TaskEventEnvelope(tid, t.ts.stdTime,
				JSONFragment(t.translated)));
			result.history ~= Data(injected.representation);
			result.rawSource ~= t.raw;
			result.sourceLine ~= t.raw is null
				? noSourceLine
				: (t.sourceLine != noSourceLine ? t.sourceLine : lineNum);
		}
	}
	return move(result);
}

struct ForkResult
{
	int tid = -1;
	string agentSessionId;
}

/// Fork a task by truncating its JSONL after the given fork ID.
/// Creates a new JSONL file with a fresh session ID and a corresponding DB row.
/// historyPathFn computes the JSONL file path for a given session ID.
/// rewriteSessionIdFn rewrites session ID references in each JSONL line.
/// matchFn checks whether a JSONL line (at 1-based lineNum) matches the fork ID.
ForkResult forkTask(ref Persistence persistence, int sourceTid, string sourceSessionId, string afterForkId,
	string projectPath, string workspace, string title, string delegate(string sessionId) historyPathFn,
	string delegate(string line, string oldId, string newId) rewriteSessionIdFn,
	bool delegate(string line, int lineNum, string forkId) matchFn,
	string description = "", string taskType = "", string agentType = "claude")
{
	import std.file : exists, mkdirRecurse, readText, write;
	import std.string : lineSplitter;

	auto sourcePath = historyPathFn(sourceSessionId);
	if (sourcePath.length == 0 || !exists(sourcePath))
		return ForkResult.init;

	auto newSessionId = generateUUID();
	auto destPath = historyPathFn(newSessionId);

	// For agents where historyPath uses glob (e.g. Codex), the new file
	// doesn't exist yet so the glob returns "".  Derive the destination
	// path from the source path by replacing the session ID in the filename.
	if (destPath.length == 0)
	{
		import std.path : buildPath, dirName, baseName;
		import std.string : replace;
		auto sourceFile = baseName(sourcePath);
		auto destFile = sourceFile.replace(sourceSessionId, newSessionId);
		destPath = buildPath(dirName(sourcePath), destFile);
	}

	// Read source, rewrite sessionId, truncate after target line
	string output;
	bool found = false;
	int lineNum = 0;
	foreach (line; readText(sourcePath).lineSplitter)
	{
		lineNum++;
		if (line.length == 0)
			continue;

		auto rewritten = rewriteSessionIdFn(line, sourceSessionId, newSessionId);
		output ~= rewritten ~ "\n";

		if (matchFn(line, lineNum, afterForkId))
		{
			found = true;
			break;
		}
	}

	if (!found)
		return ForkResult.init;

	// Ensure the destination directory exists (e.g. copilot creates per-session
	// subdirectories: COPILOT_HOME/session-state/{newSessionId}/events.jsonl).
	{
		import std.path : dirName;
		auto destDir = dirName(destPath);
		if (destDir.length > 0)
			mkdirRecurse(destDir);
	}
	write(destPath, output);

	// Create DB entry with the new agent session ID
	return ForkResult(createForkTask(persistence, sourceTid, newSessionId, projectPath,
		workspace, title, description, taskType, agentType), newSessionId);
}

/// Edit a message in a JSONL file by replacing its content.
/// matchFn checks whether a line matches the target ID.
/// editFn transforms the matched line (receives original, returns replacement).
/// Returns true if the message was found and edited, false otherwise.
bool editJsonlMessage(string jsonlPath, string targetId,
	bool delegate(string line, int lineNum, string id) matchFn,
	string delegate(string line) editFn)
{
	import std.file : exists, readText, write;
	import std.string : lineSplitter;

	if (jsonlPath.length == 0 || !exists(jsonlPath))
		return false;

	string output;
	bool found = false;
	int lineNum = 0;
	foreach (line; readText(jsonlPath).lineSplitter)
	{
		lineNum++;
		if (line.length == 0)
			continue;

		if (!found && matchFn(line, lineNum, targetId))
		{
			found = true;
			output ~= editFn(line) ~ "\n";
		}
		else
			output ~= line ~ "\n";
	}

	if (!found)
		return false;

	write(jsonlPath, output);
	return true;
}

/// Replace the JSONL line at 1-based lineNum with zero, one, or many lines.
/// Returns true if the target line was found and spliced.
bool spliceJsonlByLine(string jsonlPath, int lineNum, string[] newLines)
{
	import std.file : exists, readText, write;
	import std.string : lineSplitter;

	if (jsonlPath.length == 0 || !exists(jsonlPath) || lineNum == noSourceLine)
		return false;

	string output;
	bool found = false;
	int currentLineNum = 0;
	foreach (line; readText(jsonlPath).lineSplitter)
	{
		currentLineNum++;
		if (line.length == 0)
			continue;

		if (!found && currentLineNum == lineNum)
		{
			found = true;
			foreach (newLine; newLines)
				output ~= newLine ~ "\n";
		}
		else
			output ~= line ~ "\n";
	}

	if (!found)
		return false;

	write(jsonlPath, output);
	return true;
}

unittest
{
	import std.array : join;
	import std.file : mkdirRecurse, rmdirRecurse, write, readText;
	import std.path : buildPath;

	auto dir = buildPath("/tmp", "cydo-persist-splice-jsonl-by-line");
	mkdirRecurse(dir);
	scope(exit) rmdirRecurse(dir);

	auto jsonlPath = buildPath(dir, "events.jsonl");
	write(jsonlPath, [`{"a":1}`, "", `{"b":2}`, `{"c":3}`].join("\n") ~ "\n");

	assert(spliceJsonlByLine(jsonlPath, 3,
		[`{"x":1}`, `{"y":2}`]));
	assert(readText(jsonlPath) == [`{"a":1}`, `{"x":1}`, `{"y":2}`, `{"c":3}`, ""].join("\n"));

	assert(spliceJsonlByLine(jsonlPath, 0, [`{"ignored":true}`]) == false);
	assert(spliceJsonlByLine(jsonlPath, 2, []));
	assert(readText(jsonlPath) == [`{"a":1}`, `{"y":2}`, `{"c":3}`, ""].join("\n"));

	assert(spliceJsonlByLine(jsonlPath, 99, [`{"ignored":true}`]) == false);
}

bool writeJsonlPrefix(string sourcePath, string destPath, string afterForkId,
	bool delegate(string line, int lineNum, string forkId) matchFn)
{
	import std.file : exists, mkdirRecurse, readText, write;
	import std.path : dirName;
	import std.string : lineSplitter;

	if (sourcePath.length == 0 || !exists(sourcePath))
		return false;

	string output;
	bool found = false;
	int lineNum = 0;
	foreach (line; readText(sourcePath).lineSplitter)
	{
		lineNum++;
		if (line.length == 0)
			continue;

		output ~= line ~ "\n";
		if (matchFn(line, lineNum, afterForkId))
		{
			found = true;
			break;
		}
	}

	if (!found)
		return false;

	auto destDir = dirName(destPath);
	if (destDir.length > 0)
		mkdirRecurse(destDir);
	write(destPath, output);
	return true;
}

/// Truncate a task's JSONL file in-place after the given fork ID.
/// matchFn checks whether a line (at 1-based lineNum) matches the fork ID.
/// Returns the number of lines removed, or -1 if fork ID not found.
int truncateJsonl(string jsonlPath, string afterForkId,
	bool delegate(string line, int lineNum, string forkId) matchFn,
	bool excludeMatch = false)
{
	import std.file : exists, readText, write;
	import std.string : lineSplitter;

	if (jsonlPath.length == 0 || !exists(jsonlPath))
		return -1;

	string output;
	bool found = false;
	int removedCount = 0;
	bool pastTarget = false;
	int lineNum = 0;
	foreach (line; readText(jsonlPath).lineSplitter)
	{
		lineNum++;
		if (line.length == 0)
			continue;

		if (pastTarget)
		{
			removedCount++;
			continue;
		}

		if (matchFn(line, lineNum, afterForkId))
		{
			found = true;
			pastTarget = true;
			if (excludeMatch)
			{
				removedCount++;
				continue;
			}
		}

		output ~= line ~ "\n";
	}

	if (!found)
		return -1;

	write(jsonlPath, output);
	return removedCount;
}

/// Count lines after a given fork ID in a JSONL file.
/// matchFn checks whether a line matches the fork ID.
/// countFn determines whether a line should be counted (e.g. user/assistant messages).
/// Returns -1 if fork ID not found.
int countLinesAfterForkId(string jsonlPath, string afterForkId,
	bool delegate(string line, int lineNum, string forkId) matchFn,
	bool delegate(string line) countFn)
{
	import std.file : exists, readText;
	import std.string : lineSplitter;

	if (jsonlPath.length == 0 || !exists(jsonlPath))
		return -1;

	string[] beforeLines;
	bool pastTarget = false;
	int count = 0;
	int lineNum = 0;
	foreach (line; readText(jsonlPath).lineSplitter)
	{
		lineNum++;
		if (line.length == 0)
			continue;

		if (pastTarget)
		{
			if (countFn(line))
				count++;
		}
		else if (matchFn(line, lineNum, afterForkId))
		{
			pastTarget = true;
			// Count trailing neutral/queue-op lines preceding the match;
			// truncateJsonl will strip these too, so include them in the preview.
			foreach_reverse (bl; beforeLines)
			{
				if (isNeutralOrQueueOp(bl))
					count++;
				else
					break;
			}
		}
		else
			beforeLines ~= line;
	}

	return pastTarget ? count : -1;
}

/// Return the last forkable ID in a JSONL file.
/// extractFn extracts forkable IDs from JSONL content (agent-specific).
/// Returns null if no forkable messages found.
string lastForkIdInJsonl(string jsonlPath, string[] delegate(string content, int lineOffset = 0) extractFn)
{
	import std.file : exists, readText;

	if (jsonlPath.length == 0 || !exists(jsonlPath))
		return null;

	auto ids = extractFn(readText(jsonlPath));
	return ids.length > 0 ? ids[$ - 1] : null;
}

/// Find the UUID of the first type:"user" message appearing after the line
/// matching forkId.  Returns null if not found.
string findNextUserUuid(string jsonlPath, string forkId,
	bool delegate(string line, int lineNum, string forkId) matchFn)
{
	import std.file : exists, readText;
	import std.string : lineSplitter;

	if (jsonlPath.length == 0 || !exists(jsonlPath))
		return null;

	bool pastTarget = false;
	int lineNum = 0;
	foreach (line; readText(jsonlPath).lineSplitter)
	{
		lineNum++;
		if (line.length == 0)
			continue;

		if (!pastTarget)
		{
			if (matchFn(line, lineNum, forkId))
				pastTarget = true;
			continue;
		}

		// Past the anchor line — look for the first type:"user" with a uuid
		if (line.extractJsonField(`"type":"`) == "user")
		{
			auto uuid = line.extractJsonField(`"uuid":"`);
			if (uuid.length > 0)
				return uuid;
		}
	}
	return null;
}

unittest
{
	import std.algorithm : canFind;
	import std.array : join;
	import std.file : mkdirRecurse, rmdirRecurse, write;
	import std.path : buildPath;

	auto dir = buildPath("/tmp", "cydo-persist-find-next-user-uuid");
	mkdirRecurse(dir);
	scope(exit) rmdirRecurse(dir);

	auto jsonlPath = buildPath(dir, "events.jsonl");
	auto jsonl = [
		`{"type":"queue-operation","operation":"enqueue","content":"steer"}`,
		`{"type":"progress","stage":"queued"}`,
		`{"type":"user","uuid":"user-echo-1","message":{"content":"steer"}}`,
		`{"type":"assistant","uuid":"assistant-1","message":{"content":"ok"}}`,
	].join("\n") ~ "\n";
	write(jsonlPath, jsonl);

	bool delegate(string, int, string) matchEnqueue = (string line, int lineNum, string forkId) {
		return forkId == "enqueue-1"
			&& lineNum == 1
			&& line.canFind(`"queue-operation"`)
			&& line.canFind(`"operation":"enqueue"`);
	};

	assert(findNextUserUuid(jsonlPath, "enqueue-1", matchEnqueue) == "user-echo-1");

	bool delegate(string) countForkable = (string line) =>
		line.canFind(`"type":"user"`) || line.canFind(`"type":"assistant"`);
	assert(countLinesAfterForkId(jsonlPath, "enqueue-1", matchEnqueue, countForkable) == 2);
}

unittest
{
	import std.array : join;
	import std.file : mkdirRecurse, rmdirRecurse, write;
	import std.path : buildPath;

	auto dir = buildPath("/tmp", "cydo-persist-load-history-maxbytes");
	mkdirRecurse(dir);
	scope(exit) rmdirRecurse(dir);

	auto jsonlPath = buildPath(dir, "events.jsonl");
	// Three lines; first two are exactly N bytes, third is M bytes beyond.
	auto line1 = `{"type":"user","uuid":"u1","message":{"content":"a"}}`;
	auto line2 = `{"type":"assistant","uuid":"a1","message":{"content":"b"}}`;
	auto line3 = `{"type":"user","uuid":"u2","message":{"content":"c"}}`;
	auto jsonl = line1 ~ "\n" ~ line2 ~ "\n" ~ line3 ~ "\n";
	write(jsonlPath, jsonl);

	// N bytes: just the first two lines (including both newlines).
	ulong n = (line1 ~ "\n" ~ line2 ~ "\n").length;

	// Null translateLine: each raw line becomes one event.
	auto partial = loadTaskHistory(1, jsonlPath, null, n);
	assert(partial.history.length == 2, "expected 2 events for partial read");
	assert(partial.sourceLine == [1, 2], "expected source lines for partial read");

	auto full = loadTaskHistory(1, jsonlPath, null, ulong.max);
	assert(full.history.length == 3, "expected 3 events for full read");
	assert(full.sourceLine == [1, 2, 3], "expected source lines for full read");
}

unittest
{
	import std.file : mkdirRecurse, rmdirRecurse, write;
	import std.path : buildPath;

	auto dir = buildPath("/tmp", "cydo-persist-load-history-null-raw-source-line");
	mkdirRecurse(dir);
	scope(exit) rmdirRecurse(dir);

	auto jsonlPath = buildPath(dir, "events.jsonl");
	auto line = `{"type":"assistant","message":{"content":"file-backed line"}}`;
	write(jsonlPath, line ~ "\n");

	auto loaded = loadTaskHistory(1, jsonlPath, (string rawLine, int lineNum) {
		return [TranslatedEvent(`{"type":"agent/warning","message":"synthetic from file line"}`, null)];
	});

	assert(loaded.history.length == 1, "expected one translated event");
	assert(loaded.rawSource.length == 1 && loaded.rawSource[0] is null,
		"expected translated event to keep null raw source");
	assert(loaded.sourceLine == [noSourceLine],
		"expected null-raw translated event to keep the no-source sentinel");
}

/// Returns true if this JSONL line is a queue-operation, file-history-snapshot,
/// or progress event — lines that are "run-up" to a steered user message and
/// should be stripped together with it on undo.
private bool isNeutralOrQueueOp(string line)
{
	import std.algorithm : canFind;
	return line.canFind(`"queue-operation"`)
		|| line.canFind(`"file-history-snapshot"`)
		|| line.canFind(`"progress"`);
}

/// Extract a string field value from a JSON line by prefix scanning.
private string extractJsonField(string line, string prefix)
{
	import std.string : indexOf;

	auto idx = line.indexOf(prefix);
	if (idx < 0)
		return null;
	auto start = idx + prefix.length;
	auto end = line.indexOf('"', start);
	if (end < 0)
		return null;
	return line[start .. end];
}

/// Generate a random v4 UUID string.
private string generateUUID()
{
	import std.random : uniform;

	ubyte[16] bytes;
	foreach (ref b; bytes)
		b = cast(ubyte) uniform(0, 256);
	bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
	bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant 1
	return format!"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x"(
		bytes[0], bytes[1], bytes[2], bytes[3],
		bytes[4], bytes[5], bytes[6], bytes[7],
		bytes[8], bytes[9], bytes[10], bytes[11],
		bytes[12], bytes[13], bytes[14], bytes[15]);
}
