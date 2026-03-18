module cydo.persist;

import core.lifetime : move;

import std.format : format;
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
			// Migration 0: original sessions table
			"CREATE TABLE sessions (" ~
			"    sid INTEGER PRIMARY KEY AUTOINCREMENT," ~
			"    claude_session_id TEXT" ~
			");",
			// Migration 1
			"ALTER TABLE sessions ADD COLUMN title TEXT;",
			// Migration 2
			"ALTER TABLE sessions ADD COLUMN workspace TEXT NOT NULL DEFAULT '';" ~
			"ALTER TABLE sessions ADD COLUMN project_path TEXT NOT NULL DEFAULT '';",
			// Migration 3
			"ALTER TABLE sessions ADD COLUMN parent_sid INTEGER;" ~
			"ALTER TABLE sessions ADD COLUMN relation_type TEXT NOT NULL DEFAULT '';",
			// Migration 4: transition to task-centric model
			"CREATE TABLE tasks (" ~
			"    tid INTEGER PRIMARY KEY AUTOINCREMENT," ~
			"    claude_session_id TEXT," ~
			"    description TEXT NOT NULL DEFAULT ''," ~
			"    task_type TEXT NOT NULL DEFAULT 'conversation'," ~
			"    parent_tid INTEGER," ~
			"    relation_type TEXT NOT NULL DEFAULT ''," ~
			"    workspace TEXT NOT NULL DEFAULT ''," ~
			"    project_path TEXT NOT NULL DEFAULT ''," ~
			"    title TEXT NOT NULL DEFAULT ''," ~
			"    status TEXT NOT NULL DEFAULT 'pending'" ~
			");" ~
			"INSERT INTO tasks (tid, claude_session_id, title, workspace, project_path, parent_tid, relation_type, status)" ~
			"    SELECT sid, claude_session_id, COALESCE(title,''), COALESCE(workspace,''), COALESCE(project_path,'')," ~
			"           parent_sid, COALESCE(relation_type,''), 'completed' FROM sessions;" ~
			"DROP TABLE sessions;",
			// Migration 5: worktree path (legacy, replaced by migration 6)
			"ALTER TABLE tasks ADD COLUMN worktree_path TEXT NOT NULL DEFAULT '';",
			// Migration 6: replace worktree_path with has_worktree flag
			"ALTER TABLE tasks ADD COLUMN has_worktree INTEGER NOT NULL DEFAULT 0;" ~
			"UPDATE tasks SET has_worktree = 1 WHERE worktree_path != '';",
			// Migration 7: rename claude_session_id → agent_session_id
			"ALTER TABLE tasks RENAME COLUMN claude_session_id TO agent_session_id;",
			// Migration 8: agent type (claude, codex, etc.)
			"ALTER TABLE tasks ADD COLUMN agent_type TEXT NOT NULL DEFAULT 'claude';",
			// Migration 9: archived flag for completed/inactive tasks
			"ALTER TABLE tasks ADD COLUMN archived INTEGER NOT NULL DEFAULT 0;",
			// Migration 10: draft text for unsent input
			"ALTER TABLE tasks ADD COLUMN draft TEXT NOT NULL DEFAULT '';",
		]);
	}

	int createTask(string workspace = "", string projectPath = "", string agentType = "claude")
	{
		db.stmt!"INSERT INTO tasks (workspace, project_path, agent_type) VALUES (?, ?, ?)".exec(workspace, projectPath, agentType);
		return cast(int) db.db.lastInsertRowID;
	}

	void setAgentSessionId(int tid, string agentSessionId)
	{
		db.stmt!"UPDATE tasks SET agent_session_id = ? WHERE tid = ?".exec(agentSessionId, tid);
	}

	void setTitle(int tid, string title)
	{
		db.stmt!"UPDATE tasks SET title = ? WHERE tid = ?".exec(title, tid);
	}

	void setDescription(int tid, string description)
	{
		db.stmt!"UPDATE tasks SET description = ? WHERE tid = ?".exec(description, tid);
	}

	void setStatus(int tid, string status)
	{
		db.stmt!"UPDATE tasks SET status = ? WHERE tid = ?".exec(status, tid);
	}

	void setTaskType(int tid, string taskType)
	{
		db.stmt!"UPDATE tasks SET task_type = ? WHERE tid = ?".exec(taskType, tid);
	}

	void setAgentType(int tid, string agentType)
	{
		db.stmt!"UPDATE tasks SET agent_type = ? WHERE tid = ?".exec(agentType, tid);
	}

	void setParentTid(int tid, int parentTid)
	{
		db.stmt!"UPDATE tasks SET parent_tid = ? WHERE tid = ?".exec(parentTid, tid);
	}

	void setRelationType(int tid, string relationType)
	{
		db.stmt!"UPDATE tasks SET relation_type = ? WHERE tid = ?".exec(relationType, tid);
	}

	void setHasWorktree(int tid, bool hasWorktree)
	{
		db.stmt!"UPDATE tasks SET has_worktree = ? WHERE tid = ?".exec(hasWorktree ? 1 : 0, tid);
	}

	void setArchived(int tid, bool archived)
	{
		db.stmt!"UPDATE tasks SET archived = ? WHERE tid = ?".exec(archived ? 1 : 0, tid);
	}

	struct TaskRow
	{
		int tid;
		string agentSessionId;
		string description;
		string taskType;
		int parentTid;
		string relationType;
		string workspace;
		string projectPath;
		bool hasWorktree;
		string title;
		string status;
		string agentType;
		bool archived;
		string draft;
	}

	TaskRow[] loadTasks()
	{
		TaskRow[] result;
		foreach (int tid, string agentSessionId, string description, string taskType,
			int parentTid, string relationType, string workspace, string projectPath,
			int hasWorktree, string title, string status, string agentType, int archived, string draft;
			db.stmt!"SELECT tid, COALESCE(agent_session_id,''), COALESCE(description,''), COALESCE(task_type,'conversation'), COALESCE(parent_tid,0), COALESCE(relation_type,''), COALESCE(workspace,''), COALESCE(project_path,''), COALESCE(has_worktree,0), COALESCE(title,''), COALESCE(status,'completed'), COALESCE(agent_type,'claude'), COALESCE(archived,0), COALESCE(draft,'') FROM tasks".iterate())
		{
			result ~= TaskRow(tid, agentSessionId, description, taskType, parentTid, relationType, workspace, projectPath, hasWorktree != 0, title, status, agentType, archived != 0, draft);
		}
		return result;
	}

	void setDraft(int tid, string draft)
	{
		db.stmt!"UPDATE tasks SET draft = ? WHERE tid = ?".exec(draft, tid);
	}
}

/// Load task history from a JSONL file.
/// Returns lines wrapped in file-event envelope (distinct from live stdout events).
/// translateLine is called for each line to allow agent-specific translation.
/// The delegate receives (line, 1-based lineNum) and returns zero or more translated
/// strings to emit (empty array = skip, one element = normal, two = compaction injection).
DataVec loadTaskHistory(int tid, string jsonlPath,
	string[] delegate(string, int) translateLine = null)
{
	import std.file : exists, readText;
	import std.string : lineSplitter;

	if (jsonlPath.length == 0 || !exists(jsonlPath))
		return DataVec();

	DataVec history;
	int lineNum = 0;
	foreach (line; readText(jsonlPath).lineSplitter)
	{
		lineNum++;
		if (line.length == 0)
			continue;

		string[] translated = translateLine !is null ? translateLine(line, lineNum) : [line];

		// Wrap each translated line with file-event envelope
		foreach (t; translated)
		{
			string injected = format!`{"tid":%d,"fileEvent":`(tid) ~ t ~ `}`;
			history ~= Data(injected.representation);
		}
	}
	return move(history);
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
	string description = "", string taskType = "")
{
	import std.file : exists, readText, write;
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

	write(destPath, output);

	// Create DB entry with the new agent session ID
	auto forkTitle = title.length > 0 ? title ~ " (fork)" : "(fork)";
	persistence.db.stmt!"INSERT INTO tasks (agent_session_id, title, workspace, project_path, parent_tid, relation_type, status, description, task_type) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
		.exec(newSessionId, forkTitle, workspace, projectPath, sourceTid, "fork", "completed", description, taskType.length > 0 ? taskType : "conversation");
	return ForkResult(cast(int) persistence.db.db.lastInsertRowID, newSessionId);
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

	// Strip trailing neutral/queue-op lines that preceded the truncation target
	// (the "run-up" to a steered user message being undone).
	import std.string : lastIndexOf;
	while (output.length > 0)
	{
		auto nlPos = output[0 .. $ - 1].lastIndexOf('\n');
		auto lastLine = nlPos >= 0 ? output[nlPos + 1 .. $ - 1] : output[0 .. $ - 1];
		if (isNeutralOrQueueOp(lastLine))
		{
			output = nlPos >= 0 ? output[0 .. nlPos + 1] : "";
			removedCount++;
		}
		else
			break;
	}

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
