module cydo.persist;

import core.lifetime : move;

import std.format : format;
import std.path : buildPath;
import std.string : representation;

import ae.sys.data;
import ae.sys.database : Database;
import ae.sys.dataset : DataVec;

struct Persistence
{
	Database db;

	this(string dbPath)
	{
		import std.file : mkdirRecurse;
		import std.path : dirName;

		mkdirRecurse(dirName(dbPath));
		db = Database(dbPath, [
			"CREATE TABLE sessions (" ~
			"    sid INTEGER PRIMARY KEY AUTOINCREMENT," ~
			"    claude_session_id TEXT" ~
			");",
			"ALTER TABLE sessions ADD COLUMN title TEXT;",
			"ALTER TABLE sessions ADD COLUMN workspace TEXT NOT NULL DEFAULT '';" ~
			"ALTER TABLE sessions ADD COLUMN project_path TEXT NOT NULL DEFAULT '';",
			"ALTER TABLE sessions ADD COLUMN parent_sid INTEGER;" ~
			"ALTER TABLE sessions ADD COLUMN relation_type TEXT NOT NULL DEFAULT '';",
		]);
	}

	int createSession(string workspace = "", string projectPath = "")
	{
		db.stmt!"INSERT INTO sessions (workspace, project_path) VALUES (?, ?)".exec(workspace, projectPath);
		return cast(int) db.db.lastInsertRowID;
	}

	void setClaudeSessionId(int sid, string claudeSessionId)
	{
		db.stmt!"UPDATE sessions SET claude_session_id = ? WHERE sid = ?".exec(claudeSessionId, sid);
	}

	void setTitle(int sid, string title)
	{
		db.stmt!"UPDATE sessions SET title = ? WHERE sid = ?".exec(title, sid);
	}

	struct SessionRow
	{
		int sid;
		string claudeSessionId;
		string title;
		string workspace;
		string projectPath;
		int parentSid;
		string relationType;
	}

	SessionRow[] loadSessions()
	{
		SessionRow[] result;
		foreach (int sid, string claudeSessionId, string title, string workspace, string projectPath,
			int parentSid, string relationType;
			db.stmt!"SELECT sid, claude_session_id, title, workspace, project_path, COALESCE(parent_sid, 0), COALESCE(relation_type, '') FROM sessions".iterate())
		{
			result ~= SessionRow(sid, claudeSessionId, title, workspace, projectPath, parentSid, relationType);
		}
		return result;
	}
}

/// Load session history from Claude Code's JSONL file.
/// Returns lines wrapped in file-event envelope (distinct from live stdout events).
/// projectPath is the project's absolute path; falls back to getcwd() when empty (legacy sessions).
DataVec loadSessionHistory(int sid, string claudeSessionId, string projectPath = "")
{
	import std.file : exists, readText;
	import std.string : lineSplitter;

	auto jsonlPath = claudeJsonlPath(claudeSessionId, projectPath);
	if (!exists(jsonlPath))
		return DataVec();

	DataVec history;
	foreach (line; readText(jsonlPath).lineSplitter)
	{
		if (line.length == 0)
			continue;

		// Wrap with file-event envelope (frontend dispatches on "fileEvent" vs "event")
		string injected = format!`{"sid":%d,"fileEvent":`(sid) ~ line ~ `}`;
		history ~= Data(injected.representation);
	}
	return move(history);
}

/// Compute the path to Claude Code's JSONL file for a given session UUID.
/// Uses projectPath as the directory to mangle; falls back to getcwd() when empty.
string claudeJsonlPath(string sessionId, string projectPath = "")
{
	import std.file : getcwd;
	import std.process : environment;

	auto home = environment.get("HOME", "/tmp");
	auto cwd = projectPath.length > 0 ? projectPath : getcwd();

	// Mangle cwd: replace / with -
	auto buf = cwd.dup;
	foreach (ref c; buf)
		if (c == '/')
			c = '-';
	string mangledCwd = buf.idup;

	return buildPath(home, ".claude", "projects", mangledCwd, sessionId ~ ".jsonl");
}

struct ForkResult
{
	int sid = -1;
	string claudeSessionId;
}

/// Fork a session by truncating its JSONL after the given message UUID.
/// Creates a new JSONL file with a fresh session ID and a corresponding DB row.
ForkResult forkSession(ref Persistence persistence, int sourceSid, string sourceClaudeId, string afterUuid,
	string projectPath, string workspace, string title)
{
	import std.algorithm : canFind;
	import std.file : exists, readText, write;
	import std.string : lineSplitter, replace;

	auto sourcePath = claudeJsonlPath(sourceClaudeId, projectPath);
	if (!exists(sourcePath))
		return ForkResult.init;

	auto newClaudeId = generateUUID();
	auto destPath = claudeJsonlPath(newClaudeId, projectPath);

	// Read source, rewrite sessionId, truncate after target UUID
	string output;
	bool found = false;
	foreach (line; readText(sourcePath).lineSplitter)
	{
		if (line.length == 0)
			continue;

		auto rewritten = line
			.replace(`"sessionId":"` ~ sourceClaudeId ~ `"`, `"sessionId":"` ~ newClaudeId ~ `"`)
			.replace(`"session_id":"` ~ sourceClaudeId ~ `"`, `"session_id":"` ~ newClaudeId ~ `"`);
		output ~= rewritten ~ "\n";

		if (line.canFind(`"uuid":"` ~ afterUuid ~ `"`))
		{
			found = true;
			break;
		}
	}

	if (!found)
		return ForkResult.init;

	write(destPath, output);

	// Create DB entry with the new claude session ID
	auto forkTitle = title.length > 0 ? title ~ " (fork)" : "";
	persistence.db.stmt!"INSERT INTO sessions (claude_session_id, title, workspace, project_path, parent_sid, relation_type) VALUES (?, ?, ?, ?, ?, ?)"
		.exec(newClaudeId, forkTitle, workspace, projectPath, sourceSid, "fork");
	return ForkResult(cast(int) persistence.db.db.lastInsertRowID, newClaudeId);
}

/// Extract forkable UUIDs from JSONL content (user and assistant messages).
string[] extractForkableUuids(string content)
{
	import std.algorithm : canFind;
	import std.string : lineSplitter;

	string[] uuids;
	foreach (line; content.lineSplitter)
	{
		if (line.length == 0)
			continue;
		// Only user and assistant lines have meaningful UUIDs
		if (!line.canFind(`"type":"user"`) && !line.canFind(`"type":"assistant"`))
			continue;
		// Extract uuid value with string scanning (avoid full JSON parse)
		auto uuidVal = extractJsonField(line, `"uuid":"`);
		if (uuidVal.length > 0)
			uuids ~= uuidVal;
	}
	return uuids;
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
