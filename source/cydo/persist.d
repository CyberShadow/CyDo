module cydo.persist;

import std.format : format;
import std.path : buildPath;

import ae.sys.database : Database;

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
			");"
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

	struct SessionRow
	{
		int sid;
		string claudeSessionId;
	}

	SessionRow[] loadSessions()
	{
		SessionRow[] result;
		foreach (int sid, string claudeSessionId;
			db.stmt!"SELECT sid, claude_session_id FROM sessions".iterate())
		{
			result ~= SessionRow(sid, claudeSessionId);
		}
		return result;
	}
}

/// Load session history from Claude Code's JSONL file.
/// Returns lines with `sid` injected and `session_id` fixed.
string[] loadSessionHistory(int sid, string claudeSessionId)
{
	import std.file : exists, readText;
	import std.string : lineSplitter;

	auto jsonlPath = claudeJsonlPath(claudeSessionId);
	if (!exists(jsonlPath))
		return null;

	string[] history;
	auto sessionIdReplacement = `"session_id":"` ~ claudeSessionId ~ `"`;
	foreach (line; readText(jsonlPath).lineSplitter)
	{
		if (line.length == 0)
			continue;

		// Fix session_id: null -> actual value
		auto fixed = replaceSubstring(line, `"session_id":null`, sessionIdReplacement);

		// Inject "sid":N at the start of each JSON object
		if (fixed.length > 0 && fixed[0] == '{')
			history ~= format!`{"sid":%d,`(sid) ~ fixed[1 .. $];
		else
			history ~= fixed;
	}
	return history;
}

/// Replace first occurrence of `from` with `to` in `s`.
private string replaceSubstring(string s, string from, string to)
{
	import std.algorithm.searching : findSplit;

	auto parts = s.findSplit(from);
	if (parts[1].length == 0)
		return s;
	return parts[0] ~ to ~ parts[2];
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
