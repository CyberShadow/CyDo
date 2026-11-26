module cydo.workflow.history.jsonl_store;

import core.lifetime : move;

import std.format : format;
import std.string : representation;

import ae.sys.data : Data;
import ae.utils.json : JSONFragment, toJson;

import cydo.foundation.text.jsonl : completeJsonlPrefix, jsonlRows;
import cydo.protocol : TaskEventEnvelope, TranslatedEvent;
import cydo.agent.contract : InterruptedToolCallRepair;
import cydo.domain.storage.persistence : LoadedHistory, Persistence, createForkTask, noSourceLine;
import cydo.workflow.history.native_history : HistoryAccess;

/// Load task history from a JSONL file.
/// Returns events wrapped in file-event envelopes paired with raw source lines.
/// translateLine is called for each line to allow agent-specific translation.
/// The delegate receives (line, 1-based lineNum) and returns zero or more translated
/// event pairs (empty array = skip, one element = normal, two = compaction injection).
/// A bounded snapshot ends at the last complete record within maxBytes.
/// finishReplay flushes translated events deferred beyond the last line.
LoadedHistory loadTaskHistory(int tid, string jsonlPath,
	TranslatedEvent[] delegate(string, int) translateLine = null,
	ulong maxBytes = ulong.max,
	TranslatedEvent[] delegate() finishReplay = null)
{
	import std.file : exists, read;

	if (jsonlPath.length == 0 || !exists(jsonlPath))
		return LoadedHistory();

	auto content = cast(string) read(jsonlPath, cast(size_t) maxBytes);
	if (maxBytes != ulong.max)
		content = completeJsonlPrefix(content);
	return loadTaskHistoryContent(tid, content, translateLine, finishReplay);
}

package(cydo) LoadedHistory loadTaskHistoryContent(int tid, string content,
	TranslatedEvent[] delegate(string, int) translateLine,
	TranslatedEvent[] delegate() finishReplay = null)
{
	LoadedHistory result;
	int lineNum = 0;
	void appendTranslated(TranslatedEvent[] translated, int sourceLine)
	{
		foreach (t; translated)
		{
			auto injected = toJson(TaskEventEnvelope(tid, t.ts.stdTime,
				JSONFragment(t.translated)));
			result.history ~= Data(injected.representation);
			result.rawSource ~= t.raw;
			result.sourceLine ~= t.raw is null
				? noSourceLine
				: (t.sourceLine != noSourceLine ? t.sourceLine : sourceLine);
		}
	}
	foreach (line; content.jsonlRows)
	{
		lineNum++;
		if (line.length == 0)
			continue;

		TranslatedEvent[] translated = translateLine !is null
			? translateLine(line, lineNum)
			: [TranslatedEvent(line, line)];

		appendTranslated(translated, lineNum);
	}
	if (finishReplay !is null)
	{
		auto flushed = finishReplay();
		foreach (t; flushed)
			assert(t.raw is null || t.sourceLine != noSourceLine,
				"Deferred history events must carry their source line");
		appendTranslated(flushed, noSourceLine);
	}
	return move(result);
}

struct ForkResult
{
	int tid = -1;
	string agentSessionId;
	string destinationPath;
}

struct HistoryForkDestination
{
	string sessionId;
	string path;
}

/// Fork a task by truncating its JSONL after the given fork ID.
/// Creates a new JSONL file at an explicit target and a corresponding DB row.
/// rewriteSessionIdFn rewrites session ID references in each JSONL line.
/// matchFn checks whether a JSONL line (at 1-based lineNum) matches the fork ID.
ForkResult forkTask(ref Persistence persistence, int sourceTid,
	const ref HistoryAccess source, string afterForkId, string projectPath,
	string workspace, string title, const ref HistoryForkDestination destination,
	string delegate(string line, string oldId, string newId) rewriteSessionIdFn,
	bool delegate(string line, int lineNum, string forkId) matchFn,
	bool[int] delegate(string content, scope bool delegate(int line) dropped) dependentFn,
	string description = "", string taskType = "", string agentName = "claude")
{
	import std.file : exists, mkdirRecurse, readText, write;
	import std.path : dirName, isAbsolute;
	assert(exists(source.path), "Fork source history file must exist");
	assert(destination.sessionId.length > 0 && destination.path.length > 0
		&& isAbsolute(destination.path),
		"History fork destination must provide an absolute path and session ID");

	// An anchor can match several records. Fork keeps through the last match;
	// undo truncation cuts before the first match.
	auto content = readText(source.path);
	int lastMatch = 0;
	int lineNum = 0;
	foreach (line; content.jsonlRows)
	{
		lineNum++;
		if (line.length > 0 && matchFn(line, lineNum, afterForkId))
			lastMatch = lineNum;
	}

	if (lastMatch == 0)
		return ForkResult.init;

	auto dependent = dependentFn(content, line => line > lastMatch);
	string output;
	lineNum = 0;
	foreach (line; content.jsonlRows)
	{
		lineNum++;
		if (lineNum > lastMatch)
			break;
		if (line.length > 0 && lineNum !in dependent)
			output ~= rewriteSessionIdFn(line, source.sessionId, destination.sessionId) ~ "\n";
	}

	// Ensure the destination directory exists (e.g. copilot creates per-session
	// subdirectories: COPILOT_HOME/session-state/{newSessionId}/events.jsonl).
	{
		auto destDir = dirName(destination.path);
		if (destDir.length > 0)
			mkdirRecurse(destDir);
	}
	write(destination.path, output);

	// Create DB entry with the new agent session ID
	return ForkResult(createForkTask(persistence, sourceTid, destination.sessionId,
		projectPath, workspace, title, description, taskType, agentName),
		destination.sessionId, destination.path);
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
	if (jsonlPath.length == 0 || !exists(jsonlPath))
		return false;

	string output;
	bool found = false;
	int lineNum = 0;
	foreach (line; readText(jsonlPath).jsonlRows)
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

/// Apply a driver's interrupted-tool-call repair to an on-disk session file.
///
/// This is deliberately best-effort: Claude 2.1.220 and Codex 0.144.1 own
/// these third-party session formats, and their real behavior is pinned by the
/// continuation e2e tests. A vendor-format change must not make process exit
/// fail, but no-match and exception logging keeps that degradation visible.
/// Returns the removed native interruption UUID only after the file was
/// successfully rewritten. Every no-match or I/O failure returns null.
string repairInterruptedToolCallFile(string jsonlPath,
	InterruptedToolCallRepair delegate(string[] lines, string toolName,
		string resultText) repairFn,
	string toolName, string resultText)
{
	import std.array : array, join;
	import std.file : exists, readText, write;
	import std.logger : infof, warningf;
	try
	{
		if (jsonlPath.length == 0 || !exists(jsonlPath))
			return null;

		auto repaired = repairFn(readText(jsonlPath).jsonlRows.array,
			toolName, resultText);
		if (repaired is null)
		{
			infof("Interrupted tool-call repair did not match %s", jsonlPath);
			return null;
		}

		write(jsonlPath, repaired.lines.join("\n") ~ "\n");
		return repaired.removedInterruptionUuid.length > 0
			? repaired.removedInterruptionUuid
			: null;
	}
	catch (Exception e)
	{
		warningf("Interrupted tool-call repair failed for %s: %s", jsonlPath,
			e.msg);
		return null;
	}
}

unittest
{
	import core.sys.posix.sys.stat : chmod;
	import std.file : mkdirRecurse, readText, rmdirRecurse, write;
	import std.path : buildPath;
	import std.string : toStringz;

	auto dir = buildPath("/tmp", "cydo-persist-interrupted-tool-call-repair");
	mkdirRecurse(dir);
	scope(exit) rmdirRecurse(dir);

	auto jsonlPath = buildPath(dir, "events.jsonl");
	write(jsonlPath, "not json\n");
	InterruptedToolCallRepair delegate(string[], string, string) noRepair =
		(string[] lines, string toolName, string resultText) { return null; };
	assert(repairInterruptedToolCallFile(jsonlPath, noRepair,
		"mcp__cydo__SwitchMode", "RESULT") is null);
	assert(repairInterruptedToolCallFile(buildPath(dir, "missing.jsonl"), noRepair,
		"mcp__cydo__SwitchMode", "RESULT") is null);

	InterruptedToolCallRepair delegate(string[], string, string) rewriteWithoutMarker =
		(string[] lines, string toolName, string resultText) {
			return new InterruptedToolCallRepair(["rewritten"]);
		};
	assert(repairInterruptedToolCallFile(jsonlPath, rewriteWithoutMarker,
		"mcp__cydo__SwitchMode", "RESULT") is null);
	assert(readText(jsonlPath) == "rewritten\n");

	InterruptedToolCallRepair delegate(string[], string, string) rewriteMarker =
		(string[] lines, string toolName, string resultText) {
			return new InterruptedToolCallRepair(["repaired"], "u2");
		};
	assert(repairInterruptedToolCallFile(jsonlPath, rewriteMarker,
		"mcp__cydo__SwitchMode", "RESULT") == "u2");
	assert(readText(jsonlPath) == "repaired\n");

	auto readOnlyPath = buildPath(dir, "read-only.jsonl");
	write(readOnlyPath, "before\n");
	assert(chmod(readOnlyPath.toStringz, 256) == 0); // 0400
	scope(exit) chmod(readOnlyPath.toStringz, 384); // 0600
	assert(repairInterruptedToolCallFile(readOnlyPath, rewriteMarker,
		"mcp__cydo__SwitchMode", "RESULT") is null);
}

/// Replace the JSONL line at 1-based lineNum with zero, one, or many lines.
/// Returns true if the target line was found and spliced.
bool spliceJsonlByLine(string jsonlPath, int lineNum, string[] newLines)
{
	import std.file : exists, readText, write;
	if (jsonlPath.length == 0 || !exists(jsonlPath) || lineNum == noSourceLine)
		return false;

	string output;
	bool found = false;
	int currentLineNum = 0;
	foreach (line; readText(jsonlPath).jsonlRows)
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

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse, write, readText;
	import std.path : buildPath;
	import std.string : replace;
	import cydo.agent.contract : Agent;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import cydo.runtime.launch.types : NativeHistoryProfile;

	auto root = buildPath("/tmp", "cydo-explicit-history-fork");
	if (exists(root))
		rmdirRecurse(root);
	scope(exit)
		if (exists(root))
			rmdirRecurse(root);

	auto dbPath = buildPath(root, "cydo.db");
	mkdirRecurse(root);
	auto persistence = Persistence(dbPath);
	auto sourceTid = persistence.createTask("", "/tmp/fork-project", "claude");
	Agent agent = new ClaudeCodeAgent();
	auto profile = NativeHistoryProfile(agent.driver, buildPath(root, "profile"));
	auto sourcePath = buildPath(profile.root, "projects", "-tmp-fork-project",
		"source-session.jsonl");
	mkdirRecurse(buildPath(profile.root, "projects", "-tmp-fork-project"));
	write(sourcePath, "source-session first\nsource-session second\n");
	auto source = HistoryAccess(agent, profile, "source-session", sourcePath);
	auto destination = HistoryForkDestination("child-session",
		buildPath(root, "explicit", "nested", "child.jsonl"));

	string rewrite(string line, string oldId, string newId)
	{
		return line.replace(oldId, newId);
	}

	bool match(string line, int lineNum, string anchor)
	{
		return anchor == "first" && lineNum == 1;
	}

	assert(forkTask(persistence, sourceTid, source, "missing", "/tmp/fork-project",
		"", "parent", destination, &rewrite, &match, &agent.historyLinesDependentOn).tid < 0);
	assert(!exists(destination.path),
		"a missing anchor must not create the explicit child destination");

	auto result = forkTask(persistence, sourceTid, source, "first", "/tmp/fork-project",
		"", "parent", destination, &rewrite, &match, &agent.historyLinesDependentOn);
	assert(result.tid > 0);
	assert(result.agentSessionId == destination.sessionId);
	assert(result.destinationPath == destination.path);
	assert(readText(destination.path) == "child-session first\n");
}

/// Truncate a task's JSONL file in-place after the given fork ID.
/// matchFn checks whether a line (at 1-based lineNum) matches the fork ID.
/// Returns the number of lines removed, or -1 if fork ID not found.
int truncateJsonl(string jsonlPath, string afterForkId,
	bool delegate(string line, int lineNum, string forkId) matchFn,
	bool[int] delegate(string content, scope bool delegate(int line) dropped) dependentFn,
	bool excludeMatch = false)
{
	import std.file : exists, readText, write;
	if (jsonlPath.length == 0 || !exists(jsonlPath))
		return -1;

	auto content = readText(jsonlPath);
	int cut = 0;
	int lineNum = 0;
	foreach (line; content.jsonlRows)
	{
		lineNum++;
		if (line.length > 0 && matchFn(line, lineNum, afterForkId))
		{
			cut = lineNum + (excludeMatch ? 0 : 1);
			break;
		}
	}

	if (cut == 0)
		return -1;

	auto dependent = dependentFn(content, line => line >= cut);
	int removedCount = 0;
	string output;
	lineNum = 0;
	foreach (line; content.jsonlRows)
	{
		lineNum++;
		if (line.length == 0)
			continue;
		if (lineNum >= cut || lineNum in dependent)
			removedCount++;
		else
			output ~= line ~ "\n";
	}

	write(jsonlPath, output);
	return removedCount;
}

/// Count lines after a given fork ID in a JSONL file.
/// matchFn checks whether a line matches the fork ID.
/// countFn determines whether a line should be counted (e.g. user/assistant messages).
/// Lines on `inactiveLines` (see Agent.inactiveHistoryLines) are ignored.
/// Returns -1 if fork ID not found.
int countLinesAfterForkId(string jsonlPath, string afterForkId,
	bool delegate(string line, int lineNum, string forkId) matchFn,
	bool delegate(string line) countFn, const bool[int] inactiveLines)
{
	import std.file : exists, readText;
	if (jsonlPath.length == 0 || !exists(jsonlPath))
		return -1;

	bool pastTarget = false;
	int count = 0;
	int lineNum = 0;
	foreach (line; readText(jsonlPath).jsonlRows)
	{
		lineNum++;
		if (line.length == 0 || lineNum in inactiveLines)
			continue;

		if (pastTarget)
		{
			if (countFn(line))
				count++;
		}
		else if (matchFn(line, lineNum, afterForkId))
			pastTarget = true;
	}

	return pastTarget ? count : -1;
}

/// Find the UUID of the first type:"user" message appearing after the line
/// matching forkId.  Returns null if not found.
string findNextUserUuid(string jsonlPath, string forkId,
	bool delegate(string line, int lineNum, string forkId) matchFn)
{
	import std.file : exists, readText;
	if (jsonlPath.length == 0 || !exists(jsonlPath))
		return null;

	bool pastTarget = false;
	int lineNum = 0;
	foreach (line; readText(jsonlPath).jsonlRows)
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

	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	auto agent = new ClaudeCodeAgent();
	auto matchEnqueue = &agent.forkIdMatchesLine;

	assert(findNextUserUuid(jsonlPath, "enqueue-1", matchEnqueue) == "user-echo-1");

	bool delegate(string) countForkable = (string line) =>
		line.canFind(`"type":"user"`) || line.canFind(`"type":"assistant"`);
	assert(countLinesAfterForkId(jsonlPath, "enqueue-1", matchEnqueue, countForkable, null) == 2);
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
		return [TranslatedEvent(`{"type":"cydo/task_diagnostic","severity":"warning","subject":"Agent warning","body":"synthetic from file line"}`, null)];
	});

	assert(loaded.history.length == 1, "expected one translated event");
	assert(loaded.rawSource.length == 1 && loaded.rawSource[0] is null,
		"expected translated event to keep null raw source");
	assert(loaded.sourceLine == [noSourceLine],
		"expected null-raw translated event to keep the no-source sentinel");
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

unittest
{
	import std.file : exists, mkdirRecurse, readText, rmdirRecurse, write;
	import std.path : buildPath;
	import cydo.agent.contract : Agent;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import cydo.runtime.launch.types : NativeHistoryProfile;

	auto root = buildPath("/tmp", "cydo-multiple-record-anchor-fork");
	if (exists(root)) rmdirRecurse(root);
	mkdirRecurse(root);
	scope(exit) if (exists(root)) rmdirRecurse(root);
	auto persistence = Persistence(buildPath(root, "cydo.db"));
	auto sourceTid = persistence.createTask("", "/tmp/fork-project", "claude");
	Agent agent = new ClaudeCodeAgent();
	auto profile = NativeHistoryProfile(agent.driver, buildPath(root, "profile"));
	auto path = buildPath(profile.root, "projects", "-tmp-fork-project", "source.jsonl");
	mkdirRecurse(buildPath(profile.root, "projects", "-tmp-fork-project"));
	write(path, "one\ntwo\nthree\nfour\nfive\n");
	bool match(string, int lineNum, string anchor) {
		return anchor == "shared" && (lineNum == 2 || lineNum == 4);
	}
	string rewrite(string line, string, string) { return line; }
	bool count(string) { return true; }
	auto source = HistoryAccess(agent, profile, "source", path);
	auto dest = HistoryForkDestination("child", buildPath(root, "child.jsonl"));
	auto result = forkTask(persistence, sourceTid, source, "shared", "/tmp/fork-project",
		"", "parent", dest, &rewrite, &match, &agent.historyLinesDependentOn);
	assert(result.tid > 0);
	assert(readText(dest.path) == "one\ntwo\nthree\nfour\n");
	assert(countLinesAfterForkId(path, "shared", &match, &count, null) == 3);
	assert(truncateJsonl(path, "shared", &match, &agent.historyLinesDependentOn) == 3);
	assert(readText(path) == "one\ntwo\n");
	write(path, "one\ntwo\nthree\nfour\nfive\n");
	assert(truncateJsonl(path, "shared", &match, &agent.historyLinesDependentOn, true) == 4);
	assert(readText(path) == "one\n");
}

@("JSONL replay and fork preview use physical source lines")
unittest
{
	import std.file : remove, tempDir, write;
	import std.path : buildPath;
	import std.uuid : randomUUID;

	enum first = `{"type":"user","content":"` ~ "a\u2028b\u2029c\u0085d" ~ `"}`;
	enum anchor = `{"type":"assistant","content":"anchor"}`;
	enum last = `{"type":"user","content":"next"}`;
	auto path = buildPath(tempDir(), "cydo-jsonl-physical-lines-" ~ randomUUID().toString() ~ ".jsonl");
	write(path, first ~ "\r\n\r\n" ~ anchor ~ "\r\n" ~ last ~ "\n");
	scope(exit) remove(path);

	auto replay = loadTaskHistory(1, path);
	assert(replay.rawSource == [first, anchor, last]);
	assert(replay.sourceLine == [1, 3, 4]);

	assert(countLinesAfterForkId(path, "line:3",
		(line, lineNum, forkId) => forkId == "line:3" && lineNum == 3 && line == anchor,
		line => line == last, null) == 1);
}

@("Claude fork and undo cut at the last and first root message records")
unittest
{
	import std.array : join;
	import std.file : exists, mkdirRecurse, readText, rmdirRecurse, write;
	import std.path : buildPath;
	import cydo.agent.contract : Agent;
	import cydo.agent.drivers.claude : ClaudeCodeAgent, claudeHistoryAgreementFixture;
	import cydo.runtime.launch.types : NativeHistoryProfile;

	auto root = buildPath("/tmp", "cydo-claude-classified-cut");
	if (exists(root)) rmdirRecurse(root);
	mkdirRecurse(root);
	scope(exit) rmdirRecurse(root);
	auto persistence = Persistence(buildPath(root, "cydo.db"));
	auto sourceTid = persistence.createTask("", "/tmp/fork-project", "claude");
	Agent agent = new ClaudeCodeAgent();
	auto profile = NativeHistoryProfile(agent.driver, root);
	auto path = buildPath(root, "source.jsonl");
	auto source = HistoryAccess(agent, profile, "source", path);
	foreach (toolInputType; ["ordinary", "user", "queue-operation"])
	{
		auto rows = claudeHistoryAgreementFixture(toolInputType);
		write(path, rows.join("\n") ~ "\n");
		auto dest = HistoryForkDestination(toolInputType, buildPath(root, toolInputType ~ ".jsonl"));
		auto result = forkTask(persistence, sourceTid, source, "X", "/tmp/fork-project",
			"", "parent", dest, &agent.rewriteSessionId, &agent.forkIdMatchesLine,
			&agent.historyLinesDependentOn);
		assert(result.tid > 0);
		assert(readText(dest.path) == rows[0 .. 11].join("\n") ~ "\n");
		assert(countLinesAfterForkId(path, "X", &agent.forkIdMatchesLine, &agent.isForkableLine, null) == 1);
		assert(truncateJsonl(path, "X", &agent.forkIdMatchesLine, &agent.historyLinesDependentOn, true) == rows.length - 3);
		assert(readText(path) == rows[0 .. 3].join("\n") ~ "\n");

		// The next prompt's run-up is trimmed, while the complete retained
		// reply and any companion rows for its surviving tool results remain.
		foreach (end; [11, 13])
		{
			auto kept = rows[0 .. end].join("\n") ~ "\n";
			write(path, kept
				~ `{"type":"queue-operation","operation":"enqueue","content":"next"}` ~ "\n"
				~ `{"type":"queue-operation","operation":"dequeue"}` ~ "\n"
				~ `{"type":"user","uuid":"next","message":{"content":"next"}}` ~ "\n");
			assert(truncateJsonl(path, "next", &agent.forkIdMatchesLine, &agent.historyLinesDependentOn, true) == 3);
			assert(readText(path) == kept);
		}
	}
}


@("Editing a Claude meta image companion preserves both assistant members")
unittest
{
	import std.file : readText, remove, tempDir, write;
	import std.json : parseJSON;
	import std.path : buildPath;
	import std.uuid : randomUUID;
	import cydo.agent.drivers.claude : ClaudeCodeAgent, claudeHistoryAgreementFixture;
	import cydo.workflow.history.jsonl_edit : replaceUserMessageContent;

	auto fixture = claudeHistoryAgreementFixture("ordinary");
	auto before = fixture[3 .. 13];
	auto path = buildPath(tempDir(), "cydo-edit-companion-" ~ randomUUID().toString() ~ ".jsonl");
	import std.array : array, join;
	write(path, before.join("\n") ~ "\n");
	scope(exit) remove(path);

	auto agent = new ClaudeCodeAgent();
	enum replacement = "[Image: updated]";
	assert(editJsonlMessage(path, "companion", &agent.historyRecordIdMatchesLine,
		(string line) => replaceUserMessageContent(line, replacement)),
		"editJsonlMessage did not find the meta image companion by UUID");

	auto after = readText(path).jsonlRows.array;
	assert(after.length == before.length);
	enum companionIndex = 3;
	assert(after[0 .. companionIndex] == before[0 .. companionIndex]);
	auto edited = parseJSON(after[companionIndex]);
	assert(edited["uuid"].str == "companion");
	assert(edited["message"]["content"].str == replacement);
	assert(after[companionIndex + 1 .. $] == before[companionIndex + 1 .. $],
		"editing the companion changed later history rows");
}

@("Claude undo trims parent-linked queue run-up before the removed prompt")
unittest
{
	import std.file : readText, remove, tempDir, write;
	import std.path : buildPath;
	import std.uuid : randomUUID;
	import cydo.agent.drivers.claude : ClaudeCodeAgent, claudeParentLinkedQueueFixture;

	auto path = buildPath(tempDir(), "cydo-undo-queue-run-up-" ~ randomUUID().toString() ~ ".jsonl");
	scope(exit) remove(path);
	auto agent = new ClaudeCodeAgent();
	enum kept = `{"type":"assistant","message":{"id":"keep"}}` ~ "\n";
	write(path, kept
		~ claudeParentLinkedQueueFixture("queue-operation") ~ "\n"
		~ claudeParentLinkedQueueFixture("queue/operation", "dequeue") ~ "\n"
		~ `{"type":"user","uuid":"undo","message":{"role":"user","content":"queued"}}` ~ "\n");

	assert(truncateJsonl(path, "undo", &agent.forkIdMatchesLine, &agent.historyLinesDependentOn, true) == 3);
	assert(readText(path) == kept);
}

@("Claude history cuts remove only queue records whose recorded outcome was cut")
unittest
{
	import std.array : join;
	import std.file : mkdirRecurse, readText, rmdirRecurse, tempDir, write;
	import std.path : buildPath;
	import std.uuid : randomUUID;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import cydo.agent.drivers.claude_branches : claudeQueueCutRows;
	import cydo.agent.drivers.claude_queue : ClaudeQueueOutcomeKind, classifyClaudeQueueRecords;
	import cydo.runtime.launch.types : NativeHistoryProfile;

	auto root = buildPath(tempDir(), "cydo-queue-dependencies-" ~ randomUUID().toString());
	mkdirRecurse(root);
	scope(exit) rmdirRecurse(root);
	auto persistence = Persistence(buildPath(root, "cydo.db"));
	auto sourceTid = persistence.createTask("", root, "claude");
	auto agent = new ClaudeCodeAgent();
	auto profile = NativeHistoryProfile(agent.driver, root);
	auto path = buildPath(root, "source.jsonl");
	auto source = HistoryAccess(agent, profile, "source", path);
	auto dest = HistoryForkDestination("child", buildPath(root, "child.jsonl"));

	enum rows = claudeQueueCutRows;
	auto history = rows.join("\n") ~ "\n";
	auto retainedTurn = (rows[0 .. 3] ~ rows[4]).join("\n") ~ "\n";

	write(path, history);
	auto fork = forkTask(persistence, sourceTid, source, "P2", root,
		"", "child", dest, &agent.rewriteSessionId, &agent.forkIdMatchesLine,
		&agent.historyLinesDependentOn);
	assert(fork.tid > 0);
	assert(readText(dest.path) == retainedTurn);
	assert(readText(path) == history);

	assert(countLinesAfterForkId(path, "x", &agent.forkIdMatchesLine,
		&agent.isForkableLine, null) == 1);
	assert(truncateJsonl(path, "x", &agent.forkIdMatchesLine,
		&agent.historyLinesDependentOn, true) == 5);
	assert(readText(path) == retainedTurn);
	assert(classifyClaudeQueueRecords(readText(path), null).length == 0);

	enum priorEnqueue = `{"type":"queue-operation","operation":"enqueue","content":"prior"}` ~ "\n";
	enum pending = `{"type":"queue-operation","operation":"enqueue","content":"Y"}` ~ "\n";
	enum neutral = `{"type":"file-history-snapshot"}` ~ "\n" ~ `{"type":"progress"}` ~ "\n";
	auto priorQueue = priorEnqueue ~ rows[5] ~ "\n";
	write(path, priorQueue ~ rows[0 .. 5].join("\n") ~ "\n"
		~ pending ~ rows[5] ~ "\n" ~ neutral ~ rows[6 .. $].join("\n") ~ "\n");

	assert(countLinesAfterForkId(path, "x", &agent.forkIdMatchesLine,
		&agent.isForkableLine, null) == 1);
	assert(truncateJsonl(path, "x", &agent.forkIdMatchesLine,
		&agent.historyLinesDependentOn, true) == 5);
	auto kept = readText(path);
	assert(kept == priorQueue ~ retainedTurn ~ pending ~ neutral);
	auto outcomes = classifyClaudeQueueRecords(kept, null);
	assert(outcomes.length == 2);
	assert(outcomes[1].kind == ClaudeQueueOutcomeKind.turnStart);
	assert(outcomes[7].kind == ClaudeQueueOutcomeKind.queued);
}
