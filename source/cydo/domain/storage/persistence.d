module cydo.domain.storage.persistence;

import ae.sys.database : Database;
import ae.sys.dataset : DataVec;

/// Open the cydo database, preferring the legacy data/cydo.db if present.
Persistence openDatabase()
{
	import std.file : exists;
	import std.path : buildPath;

	import ae.sys.paths : getDataDir;
	import std.logger : warningf;

	auto xdgDataDir = getDataDir("cydo");
	string dbPath;
	if (exists("data/cydo.db"))
	{
		dbPath = "data/cydo.db";
		warningf("Warning: using legacy database at data/cydo.db — move it to %s to silence this warning",
			buildPath(xdgDataDir, "cydo.db"));
	}
	else
		dbPath = buildPath(xdgDataDir, "cydo.db");
	return Persistence(dbPath);
}

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
			"    task_type TEXT NOT NULL DEFAULT 'blank'," ~
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
			// Migration 11: task dependency tracking for resumable sub-task awaits.
			// Also fix legacy tasks left with status "active" from before status
			// was persisted — they should be "alive" (idle) so they don't get
			// nudged on restart.
			"CREATE TABLE task_deps (" ~
			"    parent_tid INTEGER NOT NULL," ~
			"    child_tid INTEGER NOT NULL," ~
			"    PRIMARY KEY (parent_tid, child_tid)" ~
			");" ~
			"UPDATE tasks SET status = 'alive' WHERE status = 'active';",
			// Migration 12: persist sub-task result text for batch delivery after restart.
			"ALTER TABLE tasks ADD COLUMN result_text TEXT DEFAULT '';",
			// Migration 13: task timestamps (created_at, last_active)
			"ALTER TABLE tasks ADD COLUMN created_at INTEGER;" ~
			"ALTER TABLE tasks ADD COLUMN last_active INTEGER;",
			// Migration 14: cache for externally-discovered session metadata
			"CREATE TABLE session_meta_cache (" ~
			"    agent_type TEXT NOT NULL," ~
			"    session_id TEXT NOT NULL," ~
			"    mtime INTEGER NOT NULL," ~
			"    project_path TEXT NOT NULL DEFAULT ''," ~
			"    title TEXT NOT NULL DEFAULT ''," ~
			"    PRIMARY KEY (agent_type, session_id)" ~
			");",
			// Migration 15: replace has_worktree boolean with worktree_tid
			// (0 = no worktree, tid = owns worktree, other tid = shares worktree)
			"ALTER TABLE tasks ADD COLUMN worktree_tid INTEGER NOT NULL DEFAULT 0;" ~
			"UPDATE tasks SET worktree_tid = tid WHERE has_worktree = 1;",
			// Migration 16: persist selected entry point for user-facing tasks
			"ALTER TABLE tasks ADD COLUMN entry_point TEXT NOT NULL DEFAULT '';",
			// Migration 17: track whether sessions have user messages (filter ghost sessions)
			// Default 1 so existing cached entries are assumed to have messages.
			"ALTER TABLE session_meta_cache ADD COLUMN has_messages INTEGER NOT NULL DEFAULT 1;",
			// Migration 18: purge ghost importable tasks (hex-prefix titles from sessions
			// with no user messages) and their cache entries so they get re-scanned.
			"DELETE FROM tasks WHERE status = 'importable'" ~
			"  AND title GLOB '[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]…';" ~
			"DELETE FROM session_meta_cache" ~
			"  WHERE title GLOB '[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]…';",
			// Migration 19: persist needs_attention flag
			"ALTER TABLE tasks ADD COLUMN needs_attention INTEGER NOT NULL DEFAULT 0;",
		]);

		// In CI, disable durability to speed up tests. This trades crash-safety
		// for speed: synchronous=OFF skips fsync, journal_mode=MEMORY keeps the
		// rollback journal in RAM, temp_store=MEMORY keeps temp tables in RAM.
		import std.process : environment;
		if (environment.get("CI", "") != "")
		{
			db.db.exec("PRAGMA synchronous = OFF;");
			db.db.exec("PRAGMA journal_mode = MEMORY;");
			db.db.exec("PRAGMA temp_store = MEMORY;");
		}
	}

	void addTaskDep(int parentTid, int childTid)
	{
		db.stmt!"INSERT OR IGNORE INTO task_deps (parent_tid, child_tid) VALUES (?, ?)".exec(parentTid, childTid);
	}

	void removeTaskDep(int parentTid, int childTid)
	{
		db.stmt!"DELETE FROM task_deps WHERE parent_tid = ? AND child_tid = ?".exec(parentTid, childTid);
	}

	void removeAllChildDeps(int childTid)
	{
		db.stmt!"DELETE FROM task_deps WHERE child_tid = ?".exec(childTid);
	}

	/// Load all dependency rows. Returns parentTid → [childTids].
	int[][int] loadTaskDeps()
	{
		int[][int] deps;
		foreach (int parentTid, int childTid;
			db.stmt!"SELECT parent_tid, child_tid FROM task_deps".iterate())
		{
			deps.require(parentTid) ~= childTid;
		}
		return deps;
	}

	int[] loadChildDeps(int parentTid)
	{
		int[] children;
		foreach (int childTid; db.stmt!"SELECT child_tid FROM task_deps WHERE parent_tid = ?".iterate(parentTid))
			children ~= childTid;
		return children;
	}

	int findParentForChild(int childTid)
	{
		foreach (int parentTid; db.stmt!"SELECT parent_tid FROM task_deps WHERE child_tid = ?".iterate(childTid))
			return parentTid;
		return 0;
	}

	int createTask(string workspace = "", string projectPath = "", string agentType = "claude",
		string entryPoint = "")
	{
		import std.datetime : Clock;
		db.stmt!"INSERT INTO tasks (workspace, project_path, agent_type, created_at, entry_point) VALUES (?, ?, ?, ?, ?)".exec(workspace, projectPath, agentType, Clock.currStdTime, entryPoint);
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

	void setEntryPoint(int tid, string entryPoint)
	{
		db.stmt!"UPDATE tasks SET entry_point = ? WHERE tid = ?".exec(entryPoint, tid);
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

	void setWorktreeTid(int tid, int worktreeTid)
	{
		db.stmt!"UPDATE tasks SET worktree_tid = ? WHERE tid = ?".exec(worktreeTid, tid);
	}

	void setArchived(int tid, bool archived)
	{
		db.stmt!"UPDATE tasks SET archived = ? WHERE tid = ?".exec(archived ? 1 : 0, tid);
	}

	void setNeedsAttention(int tid, bool needsAttention)
	{
		db.stmt!"UPDATE tasks SET needs_attention = ? WHERE tid = ?".exec(needsAttention ? 1 : 0, tid);
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
		int worktreeTid;
		string title;
		string status;
		string agentType;
		bool archived;
		string draft;
		string resultText;
		long createdAt;
		long lastActive;
		string entryPoint;
		bool needsAttention;
	}

	TaskRow[] loadTasks()
	{
		TaskRow[] result;
		foreach (int tid, string agentSessionId, string description, string taskType,
			int parentTid, string relationType, string workspace, string projectPath,
			int worktreeTid, string title, string status, string agentType, int archived, string draft,
			string resultText, long createdAt, long lastActive, string entryPoint, int needsAttention;
			db.stmt!"SELECT tid, COALESCE(agent_session_id,''), COALESCE(description,''), COALESCE(task_type,'blank'), COALESCE(parent_tid,0), COALESCE(relation_type,''), COALESCE(workspace,''), COALESCE(project_path,''), COALESCE(worktree_tid,0), COALESCE(title,''), COALESCE(status,'completed'), COALESCE(agent_type,'claude'), COALESCE(archived,0), COALESCE(draft,''), COALESCE(result_text,''), COALESCE(created_at,0), COALESCE(last_active,0), COALESCE(entry_point,''), COALESCE(needs_attention,0) FROM tasks".iterate())
		{
			result ~= TaskRow(tid, agentSessionId, description, taskType, parentTid, relationType, workspace, projectPath, worktreeTid, title, status, agentType, archived != 0, draft, resultText, createdAt, lastActive, entryPoint, needsAttention != 0);
		}
		return result;
	}

	void setDraft(int tid, string draft)
	{
		db.stmt!"UPDATE tasks SET draft = ? WHERE tid = ?".exec(draft, tid);
	}

	void deleteTask(int tid)
	{
		db.stmt!"DELETE FROM task_deps WHERE parent_tid = ? OR child_tid = ?".exec(tid, tid);
		db.stmt!"DELETE FROM tasks WHERE tid = ?".exec(tid);
	}

	void setResultText(int tid, string resultText)
	{
		db.stmt!"UPDATE tasks SET result_text = ? WHERE tid = ?".exec(resultText, tid);
	}

	void setLastActive(int tid, long lastActive)
	{
		db.stmt!"UPDATE tasks SET last_active = ? WHERE tid = ?".exec(lastActive, tid);
	}

	void clearLastActive(int tid)
	{
		db.stmt!"UPDATE tasks SET last_active = NULL WHERE tid = ?".exec(tid);
	}

	void setCreatedAt(int tid, long createdAt)
	{
		db.stmt!"UPDATE tasks SET created_at = ? WHERE tid = ?".exec(createdAt, tid);
	}

	struct CacheRow
	{
		string agentType;
		string sessionId;
		long mtime;
		string projectPath;
		string title;
		bool hasMessages;
	}

	CacheRow[] loadSessionMetaCache()
	{
		CacheRow[] result;
		foreach (string agentType, string sessionId, long mtime, string projectPath, string title, int hasMessages;
			db.stmt!"SELECT agent_type, session_id, mtime, project_path, title, has_messages FROM session_meta_cache".iterate())
		{
			result ~= CacheRow(agentType, sessionId, mtime, projectPath, title, hasMessages != 0);
		}
		return result;
	}

	void upsertSessionMetaCache(string agentType, string sessionId, long mtime,
		string projectPath, string title, bool hasMessages)
	{
		db.stmt!"INSERT OR REPLACE INTO session_meta_cache (agent_type, session_id, mtime, project_path, title, has_messages) VALUES (?, ?, ?, ?, ?, ?)"
			.exec(agentType, sessionId, mtime, projectPath, title, hasMessages ? 1 : 0);
	}

	void deleteSessionMetaCacheEntry(string agentType, string sessionId)
	{
		db.stmt!"DELETE FROM session_meta_cache WHERE agent_type = ? AND session_id = ?"
			.exec(agentType, sessionId);
	}
}

/// Result from loadTaskHistory: translated events plus parallel raw sources.
enum noSourceLine = 0;

struct LoadedHistory
{
	DataVec history;
	string[] rawSource;
	int[] sourceLine;
}

int createForkTask(ref Persistence persistence, int sourceTid, string agentSessionId,
	string projectPath, string workspace, string title,
	string description = "", string taskType = "", string agentType = "claude")
{
	import std.datetime : Clock;
	auto forkTitle = title.length > 0 ? title ~ " (fork)" : "(fork)";
	persistence.db.stmt!"INSERT INTO tasks (agent_session_id, title, workspace, project_path, parent_tid, relation_type, status, description, task_type, agent_type, created_at, last_active) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
		.exec(agentSessionId, forkTitle, workspace, projectPath, sourceTid, "fork", "completed",
			description, taskType.length > 0 ? taskType : "blank", agentType,
			Clock.currStdTime, Clock.currStdTime);
	return cast(int) persistence.db.db.lastInsertRowID;
}
