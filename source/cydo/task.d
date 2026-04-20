module cydo.task;

import std.format : format;

private string[string] repoPathCache;

import ae.sys.dataset : DataVec;
import ae.utils.json : JSONFragment, JSONOptional, JSONPartial;
import ae.utils.promise : Promise, PromiseQueue;
import ae.utils.statequeue : StateQueue;

import cydo.agent.protocol : ContentBlock, ItemStartedEvent;

import cydo.agent.session : AgentSession;
import cydo.mcp : McpResult;
import cydo.sandbox : ProcessLaunch;

/// Signal type for batch event queue: child completion or child question.
struct BatchSignal
{
	enum Kind { childDone, question }
	Kind kind;
	int childTid;
	McpResult result;      // populated for childDone
	string questionText;   // populated for question

	static BatchSignal childDone(int tid, McpResult r)
	{
		BatchSignal s;
		s.kind = Kind.childDone;
		s.childTid = tid;
		s.result = r;
		return s;
	}

	int qid;            // question ID for question signals

	static BatchSignal question(int tid, string text, int qid)
	{
		BatchSignal s;
		s.kind = Kind.question;
		s.childTid = tid;
		s.questionText = text;
		s.qid = qid;
		return s;
	}
}

enum ProcessState : bool { Dead = false, Alive = true }
enum ArchiveState : bool { Unarchived = false, Archived = true }

struct TaskData
{
	int tid;
	string agentSessionId;
	string description;
	string entryPoint;
	string taskType = "blank";
	string agentType = "claude";
	int parentTid;
	string relationType;
	string workspace;
	string projectPath;
	int worktreeTid;  // 0 = no worktree; own tid = owns worktree; other tid = shares worktree
	string title;
	string status = "pending";  // pending, active, alive, waiting, completed, failed, importable
	bool archived;
	long createdAt;    // StdTime; 0 = not set
	long lastActive;   // StdTime; 0 = not set

	/// Git repository root for the selected project.
	/// Falls back to projectPath if git resolution fails.
	@property string repoPath() const
	{
		if (projectPath.length == 0)
			return "";
		return repoPathCache.require(projectPath, {
			import std.process : execute;
			import std.string : strip;
			auto repoResult = execute(["git", "-C", projectPath, "rev-parse", "--show-toplevel"]);
			if (repoResult.status != 0)
				return projectPath;
			auto repoRoot = repoResult.output.strip();
			return repoRoot.length > 0 ? repoRoot : projectPath;
		}());
	}

	/// Per-task directory: .cydo/tasks/<tid>/
	@property string taskDir() const
	{
		auto repoRoot = repoPath;
		if (repoRoot.length == 0)
			return "";
		import std.path : buildPath;
		return buildPath(repoRoot, ".cydo", "tasks", format!"%d"(tid));
	}

	/// Worktree path: .cydo/tasks/{worktree_tid}/worktree
	/// Returns "" if no worktree.
	@property string worktreePath() const
	{
		if (worktreeTid <= 0)
			return "";
		import std.path : buildPath;
		return buildPath(repoPath, ".cydo", "tasks", format!"%d"(worktreeTid), "worktree");
	}

	/// Output file path: .cydo/tasks/<tid>/output.md
	@property string outputPath() const
	{
		if (taskDir.length == 0)
			return "";
		import std.path : buildPath;
		return buildPath(taskDir, "output.md");
	}

	/// Effective working directory: worktree path if set, otherwise project path.
	@property string effectiveCwd() const
	{
		if (worktreeTid <= 0)
			return projectPath;

		auto wtPath = worktreePath;
		if (wtPath.length == 0 || projectPath.length == 0)
			return wtPath;

		import std.path : buildPath, relativePath;

		auto repoRoot = repoPath;
		if (repoRoot.length == 0 || repoRoot == projectPath)
			return wtPath;

		auto relProjectPath = relativePath(projectPath, repoRoot);
		if (relProjectPath.length == 0 || relProjectPath == ".")
			return wtPath;

		return buildPath(wtPath, relProjectPath);
	}

	/// Returns true if this task owns its worktree (worktreeTid == own tid).
	bool ownsWorktree() const
	{
		return worktreeTid == tid && worktreeTid > 0;
	}

	/// True if this task uses any worktree (owned or shared).
	@property bool hasWorktree() const
	{
		return worktreeTid > 0;
	}

	string draft;

	// Runtime state (not persisted)
	AgentSession session;
	ProcessLaunch launch;
	DataVec history;          // unified: JSONL file events + live stdout events
	string[] rawSource;       // parallel to history: original agent line per event (null for synthetics)
	bool historyLoaded;       // whether JSONL has been loaded into history
	@property bool alive() { return session !is null && session.alive; }
	StateQueue!ProcessState* processQueue;
	StateQueue!ArchiveState* archiveQueue;
	bool archiving;  // true while an archive/unarchive transition is in progress
	Promise!ProcessState killPromise;  // non-null during active Dead transition
	bool isProcessing = false;
	bool wasKilledByUser = false;  // set when user explicitly kills via stop button
	bool outputEnforcementAttempted; // true after first enforcement retry for missing outputs
	bool needsAttention = false;
	bool hasPendingQuestion = false;
	string notificationBody;
	string resultText;    // result from the "result" event (canonical sub-task output)
	string resultNote;        // note from the creatable_tasks edge, returned with result
	string pendingContinuation; // continuation key set by SwitchMode/Handoff, consumed by onExit
	string handoffPrompt;      // prompt for the successor task (Handoff only)
	bool titleGenDone; // true after LLM title generation completed
	Promise!string titleGenHandle;   // prevent GC while running
	void delegate() titleGenKill;    // cancel one-shot subprocess; null if not running
	Promise!string suggestGenHandle; // prevent GC while running
	void delegate() suggestGenKill;  // cancel one-shot subprocess; null if not running
	uint suggestGeneration;  // incremented each time generateSuggestions is called
	string[] lastSuggestions; // most recent suggestions, sent on subscribe
	string[] enqueuedSteeringTexts; // stash of enqueued steering message texts
	string[] enqueuedSteeringRawLines; // parallel: raw JSONL lines for _raw
	/// Texts of all messages sent to this task, in send order.
	/// Populated in handleUserMessage; NOT cleared by history reset.
	/// Consumed by ensureHistoryLoaded to supply text for queue-operation:enqueue
	/// lines (which Claude's JSONL does not include a content field for).
	string[] pendingSteeringTexts;
	string pendingAskToolUseId;  // correlation ID of a pending AskUserQuestion call
	JSONFragment pendingAskQuestions;  // serialized questions for re-broadcast on reconnect
	string pendingPermissionToolUseId;  // tool_use_id for pending PermissionPrompt, empty when none
	string pendingPermissionToolName;   // tool name for pending PermissionPrompt
	JSONFragment pendingPermissionInput; // input for pending PermissionPrompt (for late-join)
	Promise!McpResult pendingAskPromise;   // child waiting for parent's answer
	string pendingAskQuestion;             // question text from child
	int pendingAskQid;                     // qid allocated for this question
	string error;  // last stderr text on non-zero exit; cleared on restart
}

struct TaskHistoryEndMessage
{
	string type = "task_history_end";
	int tid;
}

/// Check if a raw line is a queue-operation event (fast string search).
bool isQueueOperation(string line)
{
	import std.algorithm : canFind;
	return line.canFind(`"queue-operation"`);
}

/// Parsed queue-operation fields.
@JSONPartial
struct QueueOperationProbe
{
	string type;
	string operation;
	string content;
}

/// Build a synthetic item/started (type=user_message) struct with optional flags.
/// Callers should set additional fields (e.g. uuid) and call toJson() to serialize.
ItemStartedEvent buildSyntheticUserEvent(string text,
	bool isSteering = false, bool pending = false)
{
	ItemStartedEvent ev;
	ev.item_id   = "synthetic-user";
	ev.item_type = "user_message";
	ev.content   = [ContentBlock("text", text)];
	ev.is_steering = isSteering;
	ev.pending     = pending;
	return ev;
}

struct WsMessage
{
	string type;
	@JSONOptional JSONFragment content;  // string (for legacy fields) or ContentBlock[] (for messages)
	int tid = -1;
	int seq = -1;
	string workspace;
	string project_path;
	string after_uuid;
	string task_type;
	string entry_point;
	string agent_type;
	bool dry_run;
	bool revert_conversation;
	bool revert_files;
	string correlation_id;
	string tool_use_id;
}

struct TaskCreatedMessage
{
	string type;
	int tid;
	string workspace;
	string project_path;
	int parent_tid;
	string relation_type;
	string correlation_id;
}

struct TasksListMessage
{
	string type;
	TaskListEntry[] tasks;
}

struct TaskUpdatedMessage
{
	string type;
	TaskListEntry task;
}

struct FocusHintMessage
{
	string type;
	int from_tid;
	int to_tid;
}

struct TaskListEntry
{
	int tid;
	bool alive;
	bool resumable;
	bool isProcessing;
	bool needsAttention;
	bool hasPendingQuestion;
	string notificationBody;
	string title;
	string workspace;
	string project_path;
	int parent_tid;
	string relation_type;
	string status;
	string task_type;
	string entry_point;
	string agent_type;
	bool archived;
	bool archiving;  // true while an archive/unarchive transition is in progress
	string draft;
	string error;
	long created_at;
	long last_active;
}

struct ProjectInfo
{
	string name;      // relative path within workspace
	string path;      // absolute path
	bool virtual_;    // true = implied by tasks, not discovered
	bool exists;      // false = directory no longer on disk (only meaningful when virtual_)
}

struct WorkspaceInfo
{
	string name;
	ProjectInfo[] projects;
	string default_agent_type;   // per-workspace override, empty = use global
	string default_task_type;    // per-workspace override, empty = use global
}

struct WorkspacesListMessage
{
	string type = "workspaces_list";
	WorkspaceInfo[] workspaces;
}

struct EntryPointEntry
{
	string name;         // entry point name (used as display name in UI)
	string task_type;    // resolved type name
	string description;  // from entry point
	string model_class;  // from task type
	bool read_only;      // from task type
	string icon;         // from task type
}

struct TypeInfoEntry
{
	string name;
	string icon;
}

struct TaskTypesListMessage
{
	string type = "task_types_list";
	EntryPointEntry[] entry_points;
	TypeInfoEntry[] type_info;
	string default_task_type;
}

struct ProjectTaskTypesListMessage
{
	string type = "project_task_types_list";
	string project_path;
	EntryPointEntry[] entry_points;
	TypeInfoEntry[] type_info;
}

struct AgentTypeListEntry
{
	string name;           // "claude", "codex", "copilot"
	string display_name;   // "Claude Code", "Codex", "Copilot"
	bool is_available;
}

struct AgentTypesListMessage
{
	string type = "agent_types_list";
	AgentTypeListEntry[] agent_types;
	string default_agent_type;   // global default from config
}

struct ServerStatusMessage
{
	string type = "server_status";
	bool auth_enabled;
	bool dev_mode;
}

enum NoticeLevel { info, warning, alert }

struct Notice
{
	NoticeLevel level;
	string description;
	string impact;
	string action;
}

struct NoticesListMessage
{
	string type = "notices_list";
	Notice[string] notices;
}

struct TaskReloadMessage
{
	string type = "task_reload";
	int tid;
	string reason;
}

struct TitleUpdateMessage
{
	string type = "title_update";
	int tid;
	string title;
}

struct SuggestionsUpdateMessage
{
	string type = "suggestions_update";
	int tid;
	string[] suggestions;
}

struct ForkableUuidsMessage
{
	string type = "forkable_uuids";
	int tid;
	string[] uuids;
}

struct UuidAssignment
{
	string uuid;
	size_t seq;
}

struct AssignUuidsMessage
{
	string type = "assign_uuids";
	int tid;
	UuidAssignment[] assignments;
}

struct ErrorMessage
{
	string type = "error";
	string message;
	int tid = -1;
}

struct UndoPreviewMessage
{
	string type = "undo_preview";
	int tid;
	int messages_removed;
}

struct UndoResultMessage
{
	string type = "undo_result";
	int tid;
	string output;
}

struct DraftUpdatedMessage
{
	string type = "draft_updated";
	int tid;
	string new_draft;
}

struct TaskDeletedMessage
{
	string type = "task_deleted";
	int tid;
}

struct AskUserQuestionMessage
{
	string type = "ask_user_question";
	int tid;
	string tool_use_id;
	JSONFragment questions;  // serialized AskQuestion[]
}

struct PermissionPromptMessage
{
	string type = "permission_prompt";
	int tid;
	string tool_use_id;
	string tool_name;
	JSONFragment input;
}

/// Structured result returned to the parent agent as JSON via MCP.
struct TaskResult
{
	import ae.utils.json : JSONOptional;

	string summary;                   // agent's final message (one-sentence summary)
	@JSONOptional string output_file; // path to output artifact, if any
	@JSONOptional string worktree;    // path to worktree, if any
	@JSONOptional string note;        // contextual guidance for the parent agent
	@JSONOptional string error;       // canonical per-task error message
	@JSONOptional int tid;            // child task ID for follow-up via Ask
	@JSONOptional int qid;            // question ID, present when status=="question"
}

struct McpContentItem
{
	string type;
	string text;
}

struct McpContentResult
{
	import ae.utils.json : JSONOptional;

	McpContentItem[] content;
	bool isError;
	@JSONOptional JSONFragment structuredContent;
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse, write;
	import std.path : buildPath;
	import std.process : execute;

	auto repoDir = buildPath("/tmp", "cydo-taskdata-subproject");
	if (exists(repoDir))
		rmdirRecurse(repoDir);
	scope(exit)
		if (exists(repoDir))
			rmdirRecurse(repoDir);

	auto projectDir = buildPath(repoDir, "project");
	mkdirRecurse(projectDir);
	execute(["git", "-C", repoDir, "init", "-q"]);
	execute(["git", "-C", repoDir, "config", "user.email", "test@test"]);
	execute(["git", "-C", repoDir, "config", "user.name", "Test"]);
	write(buildPath(projectDir, "README.md"), "project\n");
	execute(["git", "-C", repoDir, "add", "."]);
	execute(["git", "-C", repoDir, "commit", "-qm", "init"]);

	auto td = TaskData(42);
	td.projectPath = projectDir;
	td.worktreeTid = 42;

	assert(td.repoPath == repoDir);
	assert(td.taskDir == buildPath(repoDir, ".cydo", "tasks", "42"));
	assert(td.worktreePath == buildPath(repoDir, ".cydo", "tasks", "42", "worktree"));
	assert(td.outputPath == buildPath(repoDir, ".cydo", "tasks", "42", "output.md"));
	assert(td.effectiveCwd == buildPath(repoDir, ".cydo", "tasks", "42", "worktree", "project"));
}

/// Truncate text to maxLen chars, collapsing whitespace and appending "…" if needed.
string truncateTitle(string text, size_t maxLen)
{
	import std.regex : ctRegex, replaceAll;

	auto cleaned = text.replaceAll(ctRegex!`\s+`, " ");
	if (cleaned.length <= maxLen)
		return cleaned;
	return cleaned[0 .. maxLen] ~ "…";
}

/// Convert D StdTime (hnsecs since Windows epoch) to unix milliseconds.
/// Returns 0 if the input is 0 (not set).
long stdTimeToUnixMillis(long stdTime)
{
	if (stdTime == 0)
		return 0;
	import std.datetime : SysTime, UTC;
	enum long unixEpochStdTime = SysTime.fromUnixTime(0, UTC()).stdTime;
	return (stdTime - unixEpochStdTime) / 10_000;
}

/// Extract the "ts" field from a task envelope JSON string.
/// Returns 0 if not present (envelope predates timestamp support).
long extractTsFromEnvelope(string envelope)
{
	import ae.utils.json : JSONOptional, JSONPartial, jsonParse;
	@JSONPartial static struct TsProbe { @JSONOptional long ts; }
	try { return jsonParse!TsProbe(envelope).ts; }
	catch (Exception) { return 0; }
}

/// Extract the "event" field from a task envelope JSON string.
/// Envelopes have the form: {"tid":N,"ts":N,"event":{...}}
string extractEventFromEnvelope(string envelope)
{
	import std.string : indexOf;

	// Find ,"event": — comma prevents matching inside other keys
	// like "unconfirmedUserEvent".
	auto key = `,"event":`;
	auto idx = envelope.indexOf(key);
	if (idx < 0)
		return "";

	auto start = idx + key.length;
	if (start >= envelope.length)
		return "";

	// The event value is a JSON object/string that extends to the second-to-last char
	// (the envelope's closing }). This works because "event" is the last field.
	if (envelope[$ - 1] == '}')
		return envelope[start .. $ - 1];
	return envelope[start .. $];
}
