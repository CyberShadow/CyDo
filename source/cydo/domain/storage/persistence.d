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
			// Migration 20: immutable task-local commit collection boundary
			"ALTER TABLE tasks ADD COLUMN task_start_head TEXT NOT NULL DEFAULT '';",
			// Migration 21: cache native session metadata by its exact profile namespace.
			"DROP TABLE session_meta_cache;" ~
			"CREATE TABLE session_meta_cache (" ~
			"    driver TEXT NOT NULL," ~
			"    profile_root TEXT NOT NULL," ~
			"    session_id TEXT NOT NULL," ~
			"    mtime INTEGER NOT NULL," ~
			"    project_path TEXT NOT NULL DEFAULT ''," ~
			"    title TEXT NOT NULL DEFAULT ''," ~
			"    has_messages INTEGER NOT NULL DEFAULT 1," ~
			"    PRIMARY KEY (driver, profile_root, session_id)" ~
			");",
			// Migration 23: whether the transcript ends inside an open turn.
			// Maintained on every translated event (set on turn activity,
			// cleared on turn/result and process/exit), so a restart or crash
			// landing mid-turn is visible at resume time regardless of what
			// the status field recorded; such tasks get the restart nudge.
			"ALTER TABLE tasks ADD COLUMN turn_open INTEGER NOT NULL DEFAULT 0;",
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

	int createTask(string workspace = "", string projectPath = "", string agentName = "claude",
		string entryPoint = "")
	{
		import std.datetime : Clock;
		// tasks.agent_type stores the configured agent name from config.agents.
		db.stmt!"INSERT INTO tasks (workspace, project_path, agent_type, created_at, entry_point) VALUES (?, ?, ?, ?, ?)".exec(workspace, projectPath, agentName, Clock.currStdTime, entryPoint);
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

	void setTurnOpen(int tid, bool open)
	{
		db.stmt!"UPDATE tasks SET turn_open = ? WHERE tid = ?".exec(open ? 1 : 0, tid);
	}

	void promoteImportableTask(int tid, string workspace)
	{
		db.stmt!"UPDATE tasks SET workspace = ?, status = 'completed' WHERE tid = ? AND status = 'importable'"
			.exec(workspace, tid);
	}

	void setTaskType(int tid, string taskType)
	{
		db.stmt!"UPDATE tasks SET task_type = ? WHERE tid = ?".exec(taskType, tid);
	}

	void setEntryPoint(int tid, string entryPoint)
	{
		db.stmt!"UPDATE tasks SET entry_point = ? WHERE tid = ?".exec(entryPoint, tid);
	}

	void setAgentName(int tid, string agentName)
	{
		db.stmt!"UPDATE tasks SET agent_type = ? WHERE tid = ?".exec(agentName, tid);
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

	void setTaskStartHead(int tid, string sha)
	{
		db.stmt!"UPDATE tasks SET task_start_head = ? WHERE tid = ?".exec(sha, tid);
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
		string taskStartHead;
		string title;
		string status;
		string agentName;
		bool archived;
		string draft;
		string resultText;
		long createdAt;
		long lastActive;
		string entryPoint;
		bool needsAttention;
		bool turnOpen;
	}

	TaskRow[] loadTasks()
	{
		TaskRow[] result;
		foreach (int tid, string agentSessionId, string description, string taskType,
			int parentTid, string relationType, string workspace, string projectPath,
			int worktreeTid, string taskStartHead, string title, string status, string agentName, int archived, string draft,
			string resultText, long createdAt, long lastActive, string entryPoint, int needsAttention, int turnOpen;
			db.stmt!"SELECT tid, COALESCE(agent_session_id,''), COALESCE(description,''), COALESCE(task_type,'blank'), COALESCE(parent_tid,0), COALESCE(relation_type,''), COALESCE(workspace,''), COALESCE(project_path,''), COALESCE(worktree_tid,0), COALESCE(task_start_head,''), COALESCE(title,''), COALESCE(status,'completed'), COALESCE(agent_type,'claude'), COALESCE(archived,0), COALESCE(draft,''), COALESCE(result_text,''), COALESCE(created_at,0), COALESCE(last_active,0), COALESCE(entry_point,''), COALESCE(needs_attention,0), COALESCE(turn_open,0) FROM tasks".iterate())
		{
			// tasks.agent_type stores the configured agent name from config.agents.
			result ~= TaskRow(tid, agentSessionId, description, taskType, parentTid, relationType, workspace, projectPath, worktreeTid, taskStartHead, title, status, agentName, archived != 0, draft, resultText, createdAt, lastActive, entryPoint, needsAttention != 0, turnOpen != 0);
		}
		return result;
	}

	void normalizeProjectPaths(string function(string) normalize)
	{
		struct TaskPathRow
		{
			int tid;
			string projectPath;
		}
		TaskPathRow[] tasks;
		foreach (int tid, string projectPath;
			db.stmt!"SELECT tid, project_path FROM tasks".iterate())
			tasks ~= TaskPathRow(tid, projectPath);
		foreach (row; tasks)
		{
			auto normalized = normalize(row.projectPath);
			if (normalized != row.projectPath)
				db.stmt!"UPDATE tasks SET project_path = ? WHERE tid = ?"
					.exec(normalized, row.tid);
		}

		struct CachePathRow
		{
			string driverName;
			string profileRoot;
			string sessionId;
			string projectPath;
		}
		CachePathRow[] cacheRows;
		foreach (string driverName, string profileRoot, string sessionId, string projectPath;
			db.stmt!"SELECT driver, profile_root, session_id, project_path FROM session_meta_cache".iterate())
			cacheRows ~= CachePathRow(driverName, profileRoot, sessionId, projectPath);
		foreach (row; cacheRows)
		{
			auto normalized = normalize(row.projectPath);
			if (normalized != row.projectPath)
				db.stmt!"UPDATE session_meta_cache SET project_path = ? WHERE driver = ? AND profile_root = ? AND session_id = ?"
					.exec(normalized, row.driverName, row.profileRoot, row.sessionId);
		}
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
		string driverName;
		string profileRoot;
		string sessionId;
		long mtime;
		string projectPath;
		string title;
		bool hasMessages;
	}

	CacheRow[] loadSessionMetaCache()
	{
		CacheRow[] result;
		foreach (string driverName, string profileRoot, string sessionId, long mtime, string projectPath, string title, int hasMessages;
			db.stmt!"SELECT driver, profile_root, session_id, mtime, project_path, title, has_messages FROM session_meta_cache".iterate())
		{
			result ~= CacheRow(driverName, profileRoot, sessionId, mtime, projectPath,
				title, hasMessages != 0);
		}
		return result;
	}

	void upsertSessionMetaCache(string driverName, string profileRoot,
		string sessionId, long mtime, string projectPath, string title,
		bool hasMessages)
	{
		db.stmt!"INSERT OR REPLACE INTO session_meta_cache (driver, profile_root, session_id, mtime, project_path, title, has_messages) VALUES (?, ?, ?, ?, ?, ?, ?)"
			.exec(driverName, profileRoot, sessionId, mtime, projectPath, title,
				hasMessages ? 1 : 0);
	}

	void deleteSessionMetaCacheEntry(string driverName, string profileRoot,
		string sessionId)
	{
		db.stmt!"DELETE FROM session_meta_cache WHERE driver = ? AND profile_root = ? AND session_id = ?"
			.exec(driverName, profileRoot, sessionId);
	}

	void deleteSessionMetaCacheGroup(string driverName, string profileRoot)
	{
		db.stmt!"DELETE FROM session_meta_cache WHERE driver = ? AND profile_root = ?"
			.exec(driverName, profileRoot);
	}
}

version (unittest)
unittest
{
	import cydo.foundation.platform.path : bestEffortProjectPathIdentity, canonicalProjectPath;
	import std.file : exists, mkdirRecurse, rmdirRecurse, symlink, write;
	import std.path : absolutePath, buildNormalizedPath, buildPath;

	auto root = buildPath("/tmp", "cydo-persistence-project-path-unittest");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);

	auto project = buildPath(root, "project");
	auto projectLink = buildPath(root, "project-link");
	auto missing = buildPath(root, "missing", "project");
	auto regularFile = buildPath(root, "file");
	mkdirRecurse(project);
	symlink(project, projectLink);
	write(regularFile, "file");

	auto persistence = Persistence(buildPath(root, "cydo.db"));
	auto firstTid = persistence.createTask("", projectLink);
	auto secondTid = persistence.createTask("", projectLink);
	auto forkTid = createForkTask(persistence, firstTid, "fork-session",
		canonicalProjectPath(project), "", "parent");
	auto fileTid = persistence.createTask("", regularFile);
	persistence.upsertSessionMetaCache("claude", "/profiles/one", "symlink-session", 1,
		projectLink, "", true);
	persistence.upsertSessionMetaCache("claude", "/profiles/one", "missing-session", 1,
		missing, "", true);
	persistence.upsertSessionMetaCache("claude", "/profiles/one", "file-session", 1,
		regularFile, "", true);

	persistence.normalizeProjectPaths(&bestEffortProjectPathIdentity);
	auto canonical = canonicalProjectPath(project);
	auto tasks = persistence.loadTasks();
	assert(tasks.length == 4);
	assert(tasks[0].tid == firstTid && tasks[0].projectPath == canonical);
	assert(tasks[1].tid == secondTid && tasks[1].projectPath == canonical);
	assert(tasks[2].tid == forkTid && tasks[2].projectPath == canonical);
	assert(tasks[3].tid == fileTid && tasks[3].projectPath == buildNormalizedPath(absolutePath(regularFile)));
	auto cacheRows = persistence.loadSessionMetaCache();
	assert(cacheRows.length == 3);
	assert(cacheRows[0].projectPath == canonical);
	assert(cacheRows[1].projectPath == buildNormalizedPath(absolutePath(missing)));
	assert(cacheRows[2].projectPath == buildNormalizedPath(absolutePath(regularFile)));

	persistence.normalizeProjectPaths(&bestEffortProjectPathIdentity);
	tasks = persistence.loadTasks();
	cacheRows = persistence.loadSessionMetaCache();
	assert(tasks.length == 4 && tasks[0].tid == firstTid && tasks[1].tid == secondTid && tasks[2].tid == forkTid && tasks[3].tid == fileTid);
	assert(tasks[2].projectPath == canonical);
	assert(cacheRows[0].projectPath == canonical);
	assert(cacheRows[1].projectPath == buildNormalizedPath(absolutePath(missing)));
	assert(cacheRows[2].projectPath == buildNormalizedPath(absolutePath(regularFile)));
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
	string description = "", string taskType = "", string agentName = "claude")
{
	import std.datetime : Clock;
	auto forkTitle = title.length > 0 ? title ~ " (fork)" : "(fork)";
	persistence.db.stmt!"INSERT INTO tasks (agent_session_id, title, workspace, project_path, parent_tid, relation_type, status, description, task_type, agent_type, created_at, last_active) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
		.exec(agentSessionId, forkTitle, workspace, projectPath, sourceTid, "fork", "completed",
			description, taskType.length > 0 ? taskType : "blank", agentName,
			Clock.currStdTime, Clock.currStdTime);
	return cast(int) persistence.db.db.lastInsertRowID;
}

unittest
{
	import std.file : exists, remove, tempDir;
	import std.path : buildPath;

	auto dbPath = buildPath(tempDir(), "cydo-task-start-head-round-trip.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);

	auto persistence = Persistence(dbPath);
	auto tid = persistence.createTask();
	persistence.setTaskStartHead(tid, "7f3a9c2");
	auto rows = persistence.loadTasks();

	assert(rows.length == 1);
	assert(rows[0].taskStartHead == "7f3a9c2");
}

unittest
{
	import std.file : exists, remove, tempDir;
	import std.path : buildPath;

	auto dbPath = buildPath(tempDir(), "cydo-task-start-head-migration.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);

	{
		auto legacy = Database(dbPath);
		legacy.db.exec("CREATE TABLE tasks (" ~
			"tid INTEGER PRIMARY KEY AUTOINCREMENT, agent_session_id TEXT, " ~
			"description TEXT NOT NULL DEFAULT '', task_type TEXT NOT NULL DEFAULT 'blank', " ~
			"parent_tid INTEGER, relation_type TEXT NOT NULL DEFAULT '', " ~
			"workspace TEXT NOT NULL DEFAULT '', project_path TEXT NOT NULL DEFAULT '', " ~
			"title TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'pending', " ~
			"worktree_path TEXT NOT NULL DEFAULT '', has_worktree INTEGER NOT NULL DEFAULT 0, " ~
			"agent_type TEXT NOT NULL DEFAULT 'claude', archived INTEGER NOT NULL DEFAULT 0, " ~
			"draft TEXT NOT NULL DEFAULT '', result_text TEXT DEFAULT '', created_at INTEGER, " ~
			"last_active INTEGER, worktree_tid INTEGER NOT NULL DEFAULT 0, " ~
			"entry_point TEXT NOT NULL DEFAULT '');"
		);
		legacy.db.exec("CREATE TABLE session_meta_cache (" ~
			"agent_type TEXT NOT NULL, session_id TEXT NOT NULL, mtime INTEGER NOT NULL, " ~
			"project_path TEXT NOT NULL DEFAULT '', title TEXT NOT NULL DEFAULT '', " ~
			"has_messages INTEGER NOT NULL DEFAULT 1, PRIMARY KEY (agent_type, session_id));"
		);
		legacy.db.exec("INSERT INTO tasks (tid, workspace, project_path) VALUES (1, 'ws', 'project');");
		legacy.db.exec("PRAGMA user_version = 18;");
	}

	auto persistence = Persistence(dbPath);
	auto rows = persistence.loadTasks();

	assert(rows.length == 1);
	assert(rows[0].taskStartHead == "");
}

unittest
{
	import std.file : exists, remove, tempDir;
	import std.path : buildPath;

	auto dbPath = buildPath(tempDir(), "cydo-profile-cache-migration.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);

	{
		auto legacy = Database(dbPath);
		legacy.db.exec("CREATE TABLE tasks (" ~
			"tid INTEGER PRIMARY KEY AUTOINCREMENT, agent_session_id TEXT, " ~
			"description TEXT NOT NULL DEFAULT '', task_type TEXT NOT NULL DEFAULT 'blank', " ~
			"parent_tid INTEGER, relation_type TEXT NOT NULL DEFAULT '', " ~
			"workspace TEXT NOT NULL DEFAULT '', project_path TEXT NOT NULL DEFAULT '', " ~
			"title TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'pending', " ~
			"worktree_path TEXT NOT NULL DEFAULT '', has_worktree INTEGER NOT NULL DEFAULT 0, " ~
			"agent_type TEXT NOT NULL DEFAULT 'claude', archived INTEGER NOT NULL DEFAULT 0, " ~
			"draft TEXT NOT NULL DEFAULT '', result_text TEXT DEFAULT '', created_at INTEGER, " ~
			"last_active INTEGER, worktree_tid INTEGER NOT NULL DEFAULT 0, " ~
			"entry_point TEXT NOT NULL DEFAULT '', needs_attention INTEGER NOT NULL DEFAULT 0, " ~
			"task_start_head TEXT NOT NULL DEFAULT '');"
		);
		legacy.db.exec("CREATE TABLE session_meta_cache (" ~
			"agent_type TEXT NOT NULL, session_id TEXT NOT NULL, mtime INTEGER NOT NULL, " ~
			"project_path TEXT NOT NULL DEFAULT '', title TEXT NOT NULL DEFAULT '', " ~
			"has_messages INTEGER NOT NULL DEFAULT 1, PRIMARY KEY (agent_type, session_id));"
		);
		legacy.db.exec("INSERT INTO tasks (tid, workspace, project_path, status) " ~
			"VALUES (1, 'existing-workspace', 'project', 'completed');"
		);
		legacy.db.exec("INSERT INTO session_meta_cache " ~
			"(agent_type, session_id, mtime, project_path, title, has_messages) " ~
			"VALUES ('claude', 'ambiguous-id', 1, 'project', 'old cache row', 1);"
		);
		legacy.db.exec("PRAGMA user_version = 21;");
	}

	auto persistence = Persistence(dbPath);
	int userVersion;
	foreach (int value; persistence.db.stmt!"PRAGMA user_version".iterate())
		userVersion = value;
	assert(userVersion == 23);

	auto rows = persistence.loadTasks();
	assert(rows.length == 1);
	assert(rows[0].workspace == "existing-workspace");
	assert(rows[0].projectPath == "project");
	assert(rows[0].status == "completed");
	assert(persistence.loadSessionMetaCache().length == 0,
		"ambiguous pre-profile cache rows must be discarded");

	string[] taskColumns;
	foreach (int index, string name;
		persistence.db.stmt!"PRAGMA table_info(tasks)".iterate())
		taskColumns ~= name;
	assert(taskColumns == [
		"tid", "agent_session_id", "description", "task_type", "parent_tid",
		"relation_type", "workspace", "project_path", "title", "status",
		"worktree_path", "has_worktree", "agent_type", "archived", "draft",
		"result_text", "created_at", "last_active", "worktree_tid", "entry_point",
		"needs_attention", "task_start_head",
		"turn_open",
	]);

	persistence.upsertSessionMetaCache("claude", "/profiles/one", "same-id", 1,
		"project-one", "one", true);
	persistence.upsertSessionMetaCache("claude", "/profiles/two", "same-id", 2,
		"project-two", "two", true);
	persistence.upsertSessionMetaCache("codex", "/profiles/one", "same-id", 3,
		"project-three", "three", true);
	assert(persistence.loadSessionMetaCache().length == 3);
	persistence.deleteSessionMetaCacheEntry("claude", "/profiles/one", "same-id");
	auto cacheRows = persistence.loadSessionMetaCache();
	assert(cacheRows.length == 2);
	bool hasClaudeProfileTwo;
	bool hasCodexProfileOne;
	foreach (row; cacheRows)
	{
		hasClaudeProfileTwo |= row.driverName == "claude" && row.profileRoot == "/profiles/two";
		hasCodexProfileOne |= row.driverName == "codex" && row.profileRoot == "/profiles/one";
	}
	assert(hasClaudeProfileTwo && hasCodexProfileOne);
	persistence.deleteSessionMetaCacheGroup("claude", "/profiles/two");
	cacheRows = persistence.loadSessionMetaCache();
	assert(cacheRows.length == 1);
	assert(cacheRows[0].driverName == "codex" && cacheRows[0].profileRoot == "/profiles/one");

	auto importableTid = persistence.createTask("", "project");
	persistence.setStatus(importableTid, "importable");
	persistence.promoteImportableTask(importableTid, "selected-workspace");
	auto pendingTid = persistence.createTask("old-workspace", "project");
	persistence.promoteImportableTask(pendingTid, "new-workspace");
	rows = persistence.loadTasks();
	bool promoted;
	bool pendingUnchanged;
	foreach (row; rows)
	{
		if (row.tid == importableTid)
			promoted = row.workspace == "selected-workspace" && row.status == "completed";
		if (row.tid == pendingTid)
			pendingUnchanged = row.workspace == "old-workspace" && row.status == "pending";
	}
	assert(promoted);
	assert(pendingUnchanged);
}
