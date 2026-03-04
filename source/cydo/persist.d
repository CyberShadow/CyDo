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
		]);
	}

	int createSession()
	{
		db.stmt!"INSERT INTO sessions DEFAULT VALUES".exec();
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
	}

	SessionRow[] loadSessions()
	{
		SessionRow[] result;
		foreach (int sid, string claudeSessionId, string title;
			db.stmt!"SELECT sid, claude_session_id, title FROM sessions".iterate())
		{
			result ~= SessionRow(sid, claudeSessionId, title);
		}
		return result;
	}
}

/// Load session history from Claude Code's JSONL file.
/// Returns lines wrapped in file-event envelope (distinct from live stdout events).
DataVec loadSessionHistory(int sid, string claudeSessionId)
{
	import std.file : exists, readText;
	import std.string : lineSplitter;

	auto jsonlPath = claudeJsonlPath(claudeSessionId);
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
private string claudeJsonlPath(string sessionId)
{
	import std.file : getcwd;
	import std.process : environment;

	auto home = environment.get("HOME", "/tmp");
	auto cwd = getcwd();

	// Mangle cwd: replace / with -
	auto buf = cwd.dup;
	foreach (ref c; buf)
		if (c == '/')
			c = '-';
	string mangledCwd = buf.idup;

	return buildPath(home, ".claude", "projects", mangledCwd, sessionId ~ ".jsonl");
}
