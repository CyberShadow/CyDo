module cydo.domain.storage.persistence;

import ae.sys.database : Database;
import ae.sys.dataset : DataVec;
import cydo.domain.tasks.yield_gate : NaggedYieldGates;

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

enum QuestionState
{
	open,
	answered,
	failed, // In memory only while the failure notice is owed.
	cancelled,
}

struct QuestionRecord
{
	int qid, askerTid, answererTid;
	string text, answer;
	QuestionState state;
}

struct PersistedBatch
{
	int parentTid;
	ulong batchId;
	int[] childTids;
}

private enum sessionMetaCacheSchema =
	"CREATE TABLE session_meta_cache (" ~
	"    driver TEXT NOT NULL," ~
	"    profile_root TEXT NOT NULL," ~
	"    session_id TEXT NOT NULL," ~
	"    mtime INTEGER NOT NULL," ~
	"    project_path TEXT NOT NULL DEFAULT ''," ~
	"    title TEXT NOT NULL DEFAULT ''," ~
	"    has_messages INTEGER NOT NULL DEFAULT 1," ~
	"    PRIMARY KEY (driver, profile_root, session_id)" ~
	");";

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
			sessionMetaCacheSchema,
			// Migration 22: Claude rows cached a directory-name guess and must be rescanned.
			"DELETE FROM session_meta_cache WHERE driver = 'claude';",
			// Migration 23: durable independent pre-yield retry opportunities.
			"ALTER TABLE tasks ADD COLUMN yield_gates_nagged INTEGER NOT NULL DEFAULT 0;",
			// Migration 24: retain outstanding questions and Task batch grouping.
			"CREATE TABLE questions (" ~
			"qid INTEGER PRIMARY KEY AUTOINCREMENT, asker_tid INTEGER NOT NULL, " ~
			"answerer_tid INTEGER NOT NULL, text TEXT NOT NULL, answer TEXT, " ~
			"cancelled INTEGER NOT NULL DEFAULT 0);" ~
			"ALTER TABLE task_deps ADD COLUMN batch_id INTEGER NOT NULL DEFAULT 0;" ~
			"ALTER TABLE task_deps ADD COLUMN ordinal INTEGER NOT NULL DEFAULT 0;" ~
			"DELETE FROM task_deps " ~
			"WHERE NOT EXISTS (SELECT 1 FROM tasks WHERE tid = task_deps.parent_tid " ~
			"AND status NOT IN ('completed', 'failed')) " ~
			"OR NOT EXISTS (SELECT 1 FROM tasks WHERE tid = task_deps.child_tid);" ~
			"WITH ranked AS (" ~
			"SELECT parent_tid, child_tid, MIN(child_tid) OVER (PARTITION BY parent_tid) AS batch_id, " ~
			"ROW_NUMBER() OVER (PARTITION BY parent_tid ORDER BY child_tid) - 1 AS ordinal " ~
			"FROM task_deps) " ~
			"UPDATE task_deps AS dep SET batch_id = ranked.batch_id, ordinal = ranked.ordinal " ~
			"FROM ranked WHERE dep.parent_tid = ranked.parent_tid AND dep.child_tid = ranked.child_tid;",

			// Migration 25: rescan Codex and Copilot sessions hidden by stale metadata.
			"DELETE FROM session_meta_cache WHERE driver IN ('codex', 'copilot');",
			// Migration 26: creator of an independent user task.
			"ALTER TABLE tasks ADD COLUMN creator_tid INTEGER NOT NULL DEFAULT 0;",
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

	void addTaskDep(int parentTid, int childTid, ulong batchId, size_t ordinal)
	{
		db.stmt!"INSERT INTO task_deps (parent_tid, child_tid, batch_id, ordinal) VALUES (?, ?, ?, ?)".exec(parentTid, childTid, batchId, ordinal);
	}

	void removeTaskBatch(ulong batchId)
	{
		db.stmt!"DELETE FROM task_deps WHERE batch_id = ?".exec(batchId);
	}

	void replaceTaskDepChild(ulong batchId, int oldTid, int newTid)
	{
		db.stmt!"UPDATE task_deps SET child_tid = ? WHERE batch_id = ? AND child_tid = ?".exec(newTid, batchId, oldTid);
	}

	PersistedBatch[] loadTaskDeps()
	{
		PersistedBatch[] batches;
		foreach (int parentTid, int childTid, long batchId;
			db.stmt!"SELECT parent_tid, child_tid, batch_id FROM task_deps ORDER BY batch_id, ordinal".iterate())
		{
			if (!batches.length || batches[$ - 1].batchId != cast(ulong) batchId)
				batches ~= PersistedBatch(parentTid, cast(ulong) batchId);
			batches[$ - 1].childTids ~= childTid;
		}
		return batches;
	}

	int insertQuestion(int askerTid, int answererTid, string text)
	{
		db.stmt!"INSERT INTO questions (asker_tid, answerer_tid, text) VALUES (?, ?, COALESCE(?, ''))".exec(askerTid, answererTid, text);
		return cast(int) db.db.lastInsertRowID;
	}

	void answerQuestion(int qid, string answer)
	{
		db.stmt!"UPDATE questions SET answer = COALESCE(?, '') WHERE qid = ?".exec(answer, qid);
	}

	void cancelQuestion(int qid)
	{
		db.stmt!"UPDATE questions SET cancelled = 1 WHERE qid = ?".exec(qid);
	}

	void deleteQuestion(int qid)
	{
		db.stmt!"DELETE FROM questions WHERE qid = ?".exec(qid);
	}

	QuestionRecord[] loadQuestions()
	{
		QuestionRecord[] questions;
		foreach (int qid, int askerTid, int answererTid, string text, string answer,
			bool answered, bool cancelled;
			db.stmt!"SELECT qid, asker_tid, answerer_tid, text, COALESCE(answer, ''), answer IS NOT NULL, cancelled FROM questions ORDER BY qid".iterate())
			questions ~= QuestionRecord(qid, askerTid, answererTid, text, answer,
				answered ? QuestionState.answered
					: cancelled ? QuestionState.cancelled : QuestionState.open);
		return questions;
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

	void setYieldGatesNagged(int tid, NaggedYieldGates nagged)
	{
		db.stmt!"UPDATE tasks SET yield_gates_nagged = ? WHERE tid = ?".exec(nagged.bits, tid);
	}

	void setCreatorTid(int tid, int creatorTid)
	{
		db.stmt!"UPDATE tasks SET creator_tid = ? WHERE tid = ?".exec(creatorTid, tid);
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
		NaggedYieldGates naggedYieldGates;
		int creatorTid;
	}

	TaskRow[] loadTasks()
	{
		TaskRow[] result;
		foreach (int tid, string agentSessionId, string description, string taskType,
			int parentTid, string relationType, string workspace, string projectPath,
			int worktreeTid, string taskStartHead, string title, string status, string agentName, int archived, string draft,
			string resultText, long createdAt, long lastActive, string entryPoint, int needsAttention, long yieldGatesNagged, int creatorTid;
			db.stmt!"SELECT tid, COALESCE(agent_session_id,''), COALESCE(description,''), COALESCE(task_type,'blank'), COALESCE(parent_tid,0), COALESCE(relation_type,''), COALESCE(workspace,''), COALESCE(project_path,''), COALESCE(worktree_tid,0), COALESCE(task_start_head,''), COALESCE(title,''), COALESCE(status,'completed'), COALESCE(agent_type,'claude'), COALESCE(archived,0), COALESCE(draft,''), COALESCE(result_text,''), COALESCE(created_at,0), COALESCE(last_active,0), COALESCE(entry_point,''), COALESCE(needs_attention,0), yield_gates_nagged, creator_tid FROM tasks".iterate())
		{
			// tasks.agent_type stores the configured agent name from config.agents.
			result ~= TaskRow(tid, agentSessionId, description, taskType, parentTid, relationType, workspace, projectPath, worktreeTid, taskStartHead, title, status, agentName, archived != 0, draft, resultText, createdAt, lastActive, entryPoint, needsAttention != 0, NaggedYieldGates.fromStored(yieldGatesNagged), creatorTid);
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
		db.stmt!"DELETE FROM questions WHERE asker_tid = ? OR answerer_tid = ?".exec(tid, tid);
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
		legacy.db.exec("CREATE TABLE task_deps (" ~
			"parent_tid INTEGER NOT NULL, child_tid INTEGER NOT NULL, " ~
			"PRIMARY KEY (parent_tid, child_tid));");
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
		legacy.db.exec("CREATE TABLE task_deps (" ~
			"parent_tid INTEGER NOT NULL, child_tid INTEGER NOT NULL, " ~
			"PRIMARY KEY (parent_tid, child_tid));");
		legacy.db.exec("PRAGMA user_version = 21;");
	}

	auto persistence = Persistence(dbPath);
	int userVersion;
	foreach (int value; persistence.db.stmt!"PRAGMA user_version".iterate())
		userVersion = value;
	assert(userVersion == 27);

	auto rows = persistence.loadTasks();
	assert(rows.length == 1);
	assert(rows[0].workspace == "existing-workspace");
	assert(rows[0].projectPath == "project");
	assert(rows[0].status == "completed");
	assert(rows[0].naggedYieldGates.bits == 0);
	foreach (uint mask; 0 .. 4)
	{
		persistence.setYieldGatesNagged(1, NaggedYieldGates(mask));
		assert(Persistence(dbPath).loadTasks()[0].naggedYieldGates.bits == mask);
	}
	foreach (long invalid; [-1L, 4L, 8L])
	{
		persistence.db.stmt!"UPDATE tasks SET yield_gates_nagged = ? WHERE tid = 1".exec(invalid);
		bool rejected;
		try
			Persistence(dbPath).loadTasks();
		catch (Exception)
			rejected = true;
		assert(rejected);
	}
	persistence.setYieldGatesNagged(1, NaggedYieldGates(0));
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
		"needs_attention", "task_start_head", "yield_gates_nagged", "creator_tid",
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

unittest
{
	import std.file : exists, remove, tempDir;
	import std.path : buildPath;

	auto dbPath = buildPath(tempDir(), "cydo-claude-cache-migration.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope (exit) remove(dbPath);

	{
		auto legacy = Database(dbPath);
		legacy.db.exec(sessionMetaCacheSchema);
		legacy.db.exec("INSERT INTO session_meta_cache VALUES " ~
			"('claude', '/profiles/one', 'same-id', 1, '/guessed', 'Claude session', 1), " ~
			"('other', '/profiles/one', 'same-id', 2, '/recorded', 'Other session', 1);"
		);
		// Later migrations alter the tasks and task_deps tables.
		legacy.db.exec("CREATE TABLE tasks (tid INTEGER PRIMARY KEY, status TEXT NOT NULL);");
		legacy.db.exec("CREATE TABLE task_deps (parent_tid INTEGER, child_tid INTEGER);");
		legacy.db.exec("PRAGMA user_version = 22;");
	}

	auto persistence = Persistence(dbPath);
	int userVersion;
	foreach (int value; persistence.db.stmt!"PRAGMA user_version".iterate())
		userVersion = value;
	assert(userVersion == 27);

	auto rows = persistence.loadSessionMetaCache();
	assert(rows == [Persistence.CacheRow("other", "/profiles/one", "same-id", 2,
		"/recorded", "Other session", true)]);
}

unittest
{
	import std.file : exists, remove, tempDir;
	import std.path : buildPath;
	import std.uuid : randomUUID;

	auto dbPath = buildPath(tempDir(), "cydo-session-meta-cache-" ~ randomUUID().toString ~ ".sqlite");
	scope (exit)
		if (exists(dbPath))
			remove(dbPath);
	{
		auto legacy = Persistence(dbPath);
		legacy.db.db.exec("INSERT INTO session_meta_cache VALUES " ~
			"('codex', '/profiles/one', 'same-id', 1, '/workspace', 'Stale Codex title', 0), " ~
			"('copilot', '/profiles/one', 'same-id', 2, '/workspace', 'Stale Copilot title', 0), " ~
			"('claude', '/profiles/one', 'same-id', 3, '/workspace', 'Claude session', 1);"
		);
		legacy.db.db.exec("ALTER TABLE tasks DROP COLUMN creator_tid;");
		legacy.db.db.exec("PRAGMA user_version = 25;");
	}

	auto persistence = Persistence(dbPath);
	int userVersion;
	foreach (int value; persistence.db.stmt!"PRAGMA user_version".iterate())
		userVersion = value;
	assert(userVersion == 27);
	assert(persistence.loadSessionMetaCache() ==
		[Persistence.CacheRow("claude", "/profiles/one", "same-id", 3, "/workspace", "Claude session", true)]);
}


unittest
{
	import std.file : exists, rmdirRecurse;
	import std.path : buildPath;

	auto root = buildPath("/tmp", "cydo-yield-gate-migration-unittest");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	auto path = buildPath(root, "cydo.db");
	{
		auto old = Persistence(path);
		old.createTask("workspace", "project");
		old.db.db.exec("ALTER TABLE tasks DROP COLUMN yield_gates_nagged;");
		old.db.db.exec("ALTER TABLE tasks DROP COLUMN creator_tid;");
		old.db.db.exec("DROP TABLE questions;");
		old.db.db.exec("ALTER TABLE task_deps DROP COLUMN batch_id;");
		old.db.db.exec("ALTER TABLE task_deps DROP COLUMN ordinal;");
		old.db.db.exec("PRAGMA user_version = 23;");
	}
	auto upgraded = Persistence(path);
	auto rows = upgraded.loadTasks();
	assert(rows.length == 1);
	assert(rows[0].workspace == "workspace");
	assert(rows[0].projectPath == "project");
	assert(rows[0].naggedYieldGates.bits == 0);
}

unittest
{
	import std.file : exists, remove, tempDir;
	import std.path : buildPath;

	auto dbPath = buildPath(tempDir(), "cydo-task-batch-migration.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);

	{
		auto legacy = Database(dbPath);
		legacy.db.exec("CREATE TABLE tasks (" ~
			"tid INTEGER PRIMARY KEY, status TEXT NOT NULL, parent_tid INTEGER);");
		legacy.db.exec("INSERT INTO tasks (tid, status) VALUES " ~
			"(1, 'completed'), (2, 'completed'), (3, 'completed'), (4, 'completed'), " ~
			"(5, 'failed'), (6, 'pending'), " ~
			"(7, 'waiting'), (8, 'active'), (9, 'completed');");
		legacy.db.exec("CREATE TABLE task_deps (" ~
			"parent_tid INTEGER NOT NULL, child_tid INTEGER NOT NULL, " ~
			"PRIMARY KEY (parent_tid, child_tid));");
		legacy.db.exec("INSERT INTO task_deps VALUES " ~
			"(1, 2), (1, 3), (1, 4), (5, 6), (7, 9), (7, 8), (7, 10), (11, 6);");
		legacy.db.exec(sessionMetaCacheSchema);
		legacy.db.exec("PRAGMA user_version = 24;");
	}

	auto persistence = Persistence(dbPath);
	assert(persistence.loadTaskDeps() == [PersistedBatch(7, 8, [8, 9])]);
	int[] ordinals;
	foreach (int ordinal; persistence.db.stmt!"SELECT ordinal FROM task_deps ORDER BY child_tid".iterate())
		ordinals ~= ordinal;
	assert(ordinals == [0, 1]);
}

unittest
{
	import std.file : exists, remove, tempDir;
	import std.path : buildPath;
	import std.uuid : randomUUID;

	auto dbPath = buildPath(tempDir(), "cydo-task-creator-" ~ randomUUID().toString ~ ".sqlite");
	scope (exit)
		if (exists(dbPath))
			remove(dbPath);

	int tid;
	{
		auto legacy = Persistence(dbPath);
		tid = legacy.createTask("workspace", "project");
		legacy.db.db.exec("ALTER TABLE tasks DROP COLUMN creator_tid;");
		legacy.db.db.exec("PRAGMA user_version = 26;");
	}

	auto persistence = Persistence(dbPath);
	int userVersion;
	foreach (int value; persistence.db.stmt!"PRAGMA user_version".iterate())
		userVersion = value;
	assert(userVersion == 27);

	auto rows = persistence.loadTasks();
	assert(rows.length == 1 && rows[0].tid == tid && rows[0].creatorTid == 0);
	persistence.setCreatorTid(tid, 7);
	auto reopenedRows = Persistence(dbPath).loadTasks();
	assert(reopenedRows.length == 1 && reopenedRows[0].tid == tid
		&& reopenedRows[0].creatorTid == 7);
}

unittest
{
	import std.file : exists, remove, tempDir;
	import std.path : buildPath;

	auto dbPath = buildPath(tempDir(), "cydo-question-id-reopen.sqlite");
	if (exists(dbPath))
		remove(dbPath);
	scope(exit) if (exists(dbPath)) remove(dbPath);

	int first, deleted;
	{
		auto persistence = Persistence(dbPath);
		first = persistence.insertQuestion(1, 2, "keep");
		deleted = persistence.insertQuestion(2, 1, "delete");
		assert(deleted > first);
		persistence.deleteQuestion(deleted);
	}

	auto persistence = Persistence(dbPath);
	auto next = persistence.insertQuestion(1, 2, "after reopen");
	assert(next > deleted);
	assert(persistence.loadQuestions() == [
		QuestionRecord(first, 1, 2, "keep"),
		QuestionRecord(next, 1, 2, "after reopen"),
	]);
}

unittest
{
	auto persistence = Persistence(":memory:");
	persistence.addTaskDep(1, 4, 3, 1);
	persistence.addTaskDep(1, 8, 8, 0);
	persistence.addTaskDep(1, 3, 3, 0);
	assert(persistence.loadTaskDeps() == [
		PersistedBatch(1, 3, [3, 4]), PersistedBatch(1, 8, [8]),
	]);

	// Handoff replaces the first child without changing the batch ID or slot.
	persistence.replaceTaskDepChild(3, 3, 9);
	assert(persistence.loadTaskDeps() == [
		PersistedBatch(1, 3, [9, 4]), PersistedBatch(1, 8, [8]),
	]);
}

unittest
{
	auto persistence = Persistence(":memory:");
	auto tid = persistence.createTask();
	auto other = persistence.createTask();
	auto third = persistence.createTask();
	persistence.insertQuestion(tid, other, "outgoing");
	persistence.insertQuestion(other, tid, "incoming");
	auto unrelated = persistence.insertQuestion(other, third, "unrelated");

	persistence.deleteTask(tid);
	assert(persistence.loadQuestions() == [
		QuestionRecord(unrelated, other, third, "unrelated"),
	]);
}
