module cydo.task;

import std.format : format;

import ae.sys.dataset : DataVec;
import ae.utils.json : JSONFragment, JSONPartial;
import ae.utils.promise : Promise;

import cydo.agent.session : AgentSession;
import cydo.sandbox : ResolvedSandbox;

struct TaskData
{
	int tid;
	string agentSessionId;
	string description;
	string taskType = "conversation";
	string agentType = "claude";
	int parentTid;
	string relationType;
	string workspace;
	string projectPath;
	bool hasWorktree;
	string title;
	string status = "pending";  // pending, active, completed, failed
	bool archived;

	/// Per-task directory: .cydo/tasks/<tid>/
	@property string taskDir() const
	{
		if (projectPath.length == 0)
			return "";
		import std.path : buildPath;
		return buildPath(projectPath, ".cydo", "tasks", format!"%d"(tid));
	}

	/// Worktree path (if this task has one), with symlinks resolved.
	@property string worktreePath() const
	{
		if (!hasWorktree)
			return "";
		import std.path : buildPath;
		auto path = buildPath(taskDir, "worktree");
		try
		{
			import ae.sys.file : realPath;
			return realPath(path);
		}
		catch (Exception)
		{
			return path;
		}
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
		return hasWorktree ? worktreePath : projectPath;
	}

	string draft;

	// Runtime state (not persisted)
	AgentSession session;
	ResolvedSandbox sandbox;
	DataVec history;          // unified: JSONL file events + live stdout events
	bool historyLoaded;       // whether JSONL has been loaded into history
	bool alive = false;
	bool isProcessing = false;
	bool needsAttention = false;
	string notificationBody;
	string resultText;    // result from the "result" event (canonical sub-task output)
	string resultNote;        // note from the creatable_tasks edge, returned with result
	string pendingContinuation; // continuation key set by SwitchMode/Handoff, consumed by onExit
	string handoffPrompt;      // prompt for the successor task (Handoff only)
	bool titleGenDone; // true after LLM title generation completed
	Promise!string titleGenHandle;   // prevent GC while running
	Promise!string suggestGenHandle; // prevent GC while running
	uint suggestGeneration;  // incremented each time generateSuggestions is called
	string[] lastSuggestions; // most recent suggestions, sent on subscribe
	string[] enqueuedSteeringTexts; // stash of enqueued steering message texts
	string pendingAskToolUseId;  // correlation ID of a pending AskUserQuestion call
	JSONFragment pendingAskQuestions;  // serialized questions for re-broadcast on reconnect
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

/// Build a synthetic message/user JSON string with optional flags.
string buildSyntheticUserEvent(string text,
	bool isSteering = false, bool pending = false)
{
	import ae.utils.json : toJson;
	auto contentJson = toJson(text);
	string extra;
	if (isSteering) extra ~= `,"is_steering":true`;
	if (pending) extra ~= `,"pending":true`;
	return `{"type":"message/user","content":` ~ contentJson ~ extra ~ `}`;
}

struct WsMessage
{
	string type;
	string content;
	int tid = -1;
	string workspace;
	string project_path;
	string after_uuid;
	string task_type;
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

struct TaskListEntry
{
	int tid;
	bool alive;
	bool resumable;
	bool isProcessing;
	bool needsAttention;
	string notificationBody;
	string title;
	string workspace;
	string project_path;
	int parent_tid;
	string relation_type;
	string status;
	string task_type;
	bool archived;
	string draft;
}

struct ProjectInfo
{
	string name;      // relative path within workspace
	string path;      // absolute path
}

struct WorkspaceInfo
{
	string name;
	ProjectInfo[] projects;
}

struct WorkspacesListMessage
{
	string type = "workspaces_list";
	WorkspaceInfo[] workspaces;
}

struct TaskTypeListEntry
{
	string name;
	string display_name;
	string description;
	string model_class;
	bool read_only;
	string icon;
	bool user_visible;
}

struct TaskTypesListMessage
{
	string type = "task_types_list";
	TaskTypeListEntry[] task_types;
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

struct DraftUpdatedMessage
{
	string type = "draft_updated";
	int tid;
	string new_draft;
}

struct AskUserQuestionMessage
{
	string type = "ask_user_question";
	int tid;
	string tool_use_id;
	JSONFragment questions;  // serialized AskQuestion[]
}
/// Structured result returned to the parent agent as JSON via MCP.
struct TaskResult
{
	import ae.utils.json : JSONOptional;

	string summary;                   // agent's final message (one-sentence summary)
	@JSONOptional string output_file; // path to output artifact, if any
	@JSONOptional string worktree;    // path to worktree, if any
	@JSONOptional string note;        // contextual guidance for the parent agent
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

/// Truncate text to maxLen chars, collapsing whitespace and appending "…" if needed.
string truncateTitle(string text, size_t maxLen)
{
	import std.regex : ctRegex, replaceAll;

	auto cleaned = text.replaceAll(ctRegex!`\s+`, " ");
	if (cleaned.length <= maxLen)
		return cleaned;
	return cleaned[0 .. maxLen] ~ "…";
}

/// Extract the "event" field from a task envelope JSON string.
/// Envelopes have the form: {"tid":N,"event":{...}}
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

/// Extract the inner event from a fileEvent envelope (JSONL-loaded history).
string extractFileEventFromEnvelope(string envelope)
{
	import std.string : indexOf;

	auto key = `"fileEvent":`;
	auto idx = envelope.indexOf(key);
	if (idx < 0)
		return "";

	auto start = idx + key.length;
	if (start >= envelope.length)
		return "";

	if (envelope[$ - 1] == '}')
		return envelope[start .. $ - 1];
	return envelope[start .. $];
}
