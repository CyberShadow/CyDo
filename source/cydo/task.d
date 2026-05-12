module cydo.task;

import std.format : format;

private string[string] repoPathCache;

import ae.sys.data : Data;
import ae.sys.dataset : DataVec;
import ae.utils.json : JSONFragment, JSONOptional, JSONPartial;
import ae.utils.promise : Promise, PromiseQueue;
import ae.utils.statequeue : StateQueue;

import cydo.agent.protocol : ContentBlock, ItemStartedEvent;
import cydo.persist : LoadedHistory;

import cydo.agent.session : AgentSession;
import cydo.mcp : McpResult;
import cydo.sandbox : ProcessLaunch;

/// Encapsulates per-task history with a watermark/buffer state machine.
///
/// The three states:
///   - uninitialized: initial default; every public op (except reset and isLoaded)
///     asserts. Callers must call reset() before any other operation.
///   - loaded: history_ holds the canonical event sequence; pendingEvents_ is empty.
///     All query and mutation operations are available.
///   - deferred: the on-disk JSONL has not been read yet. live events are buffered
///     in pendingEvents_ until load() is called. Read operations (length, opIndex,
///     opApply, ...) assert isLoaded — callers must call ensureHistoryLoaded first.
///
/// Design rationale:
///   - I3 "must call ensureHistoryLoaded before appending to td.history" is now
///     structurally enforced: appendLive routes between history_ and pendingEvents_
///     based on state, and the asserts prevent read access while deferred.
///   - I4 "historyLoaded==false ⇒ history empty" is replaced by the deferred/loaded
///     distinction: deferred state has history_ empty, pending may hold live events.
///   - The watermark makes the durable-vs-live boundary unambiguous: no event is
///     ever discarded; no content-aware dedup is needed; the two streams meet at
///     a known byte offset.
struct HistoryStore
{
private:
    DataVec  history_;
    string[] rawSource_;
    DataVec  pendingEvents_;
    string[] pendingRaw_;
    enum State : ubyte { uninitialized, loaded, deferred }
    State    state_ = State.uninitialized;
    ulong    watermark_;

    void assertInitialized() const
    {
        assert(state_ != State.uninitialized,
            "HistoryStore operation on uninitialized store: call reset() first");
    }

public:
    // -------- queries (any initialized state) --------

    @property bool isLoaded() const { return state_ == State.loaded; }

    /// Contents of the most recently appended event (pending if deferred, history
    /// if loaded). Returns empty slice if nothing has been appended yet.
    /// Used by mergeStreamingDelta to peek at the last event regardless of state.
    const(char)[] lastEventContents() const
    {
        assertInitialized();
        if (state_ == State.deferred)
            return pendingEvents_.length > 0
                ? cast(const(char)[]) pendingEvents_[$ - 1].unsafeContents
                : null;
        return history_.length > 0
            ? cast(const(char)[]) history_[$ - 1].unsafeContents
            : null;
    }

    /// Timestamp parsed from the envelope of the most recent event, or 0.
    long lastEventTs() const
    {
        assertInitialized();
        import cydo.task : extractTsFromEnvelope;
        auto contents = lastEventContents();
        if (contents.length == 0)
            return 0;
        return extractTsFromEnvelope(cast(string) contents);
    }

    // -------- queries (loaded state only — asserted) --------

    @property size_t length() const
    {
        assert(state_ == State.loaded, "HistoryStore.length requires loaded state");
        return history_.length;
    }

    ref const(Data) opIndex(size_t i) const
    {
        assert(state_ == State.loaded, "HistoryStore.opIndex requires loaded state");
        return history_[i];
    }

    /// Returns the raw JSONL source line at index i, or null for synthetic events.
    string rawAt(size_t i) const
    {
        assert(state_ == State.loaded, "HistoryStore.rawAt requires loaded state");
        if (i >= rawSource_.length)
            return null;
        return rawSource_[i];
    }

    int opApply(scope int delegate(size_t, ref Data) dg)
    {
        assert(state_ == State.loaded, "HistoryStore.opApply requires loaded state");
        foreach (i, ref d; history_)
            if (auto r = dg(i, d)) return r;
        return 0;
    }

    int opApply(scope int delegate(ref Data) dg)
    {
        assert(state_ == State.loaded, "HistoryStore.opApply requires loaded state");
        foreach (ref d; history_)
            if (auto r = dg(d)) return r;
        return 0;
    }

    int opApplyReverse(scope int delegate(ref Data) dg)
    {
        assert(state_ == State.loaded, "HistoryStore.opApplyReverse requires loaded state");
        foreach_reverse (ref d; history_)
            if (auto r = dg(d)) return r;
        return 0;
    }

    // -------- mutations --------

    /// Append a live event. Routes to pendingEvents_ if deferred, history_ if loaded.
    /// Returns the new seq index if loaded; cast(size_t)-1 if deferred (callers
    /// use this to skip subscriber-side broadcast/anchor work that is meaningless
    /// in the deferred state).
    ///
    /// history is the durable replay source; live broadcasts must not be treated as
    /// the only delivery path for persisted events.
    size_t appendLive(Data event, string raw)
    {
        assertInitialized();
        if (state_ == State.deferred)
        {
            pendingEvents_ ~= event;
            pendingRaw_ ~= raw;
            return cast(size_t) -1;
        }
        history_ ~= event;
        rawSource_ ~= raw;
        return history_.length - 1;
    }

    /// Replace the most recently appended event (pending if deferred, history if loaded).
    /// Used by mergeStreamingDelta to merge streaming item/delta chunks in-place.
    void replaceLastEvent(Data event)
    {
        assertInitialized();
        if (state_ == State.deferred)
        {
            assert(pendingEvents_.length > 0, "replaceLastEvent: no pending events");
            pendingEvents_[$ - 1] = event;
            return;
        }
        assert(history_.length > 0, "replaceLastEvent: no history events");
        history_[$ - 1] = event;
    }

    /// In-place replace inside loaded history (for backfillHistoryAnchor).
    void replaceAt(size_t i, Data event)
    {
        assert(state_ == State.loaded, "HistoryStore.replaceAt requires loaded state");
        history_[i] = event;
    }

    // -------- state transitions --------

    /// Initialize or re-initialize the store from an on-disk JSONL state. Clears
    /// all content and pending events.
    ///
    /// - reset(0) → loaded+empty. The caller declares "no on-disk state to load";
    ///   appendLive works immediately. Use for brand-new tasks (createTask) and
    ///   orphaned-agent tasks.
    /// - reset(N>0) → deferred+watermark N. Live events are buffered in pendingEvents_
    ///   until load() is called. Use when the JSONL has N bytes already on disk.
    ///
    /// Re-resetting an already-initialized store is legal and used by truncation
    /// paths (performUndoExecution, handleEditMessage, thread/rollback, etc.) to
    /// discard in-memory state and re-snapshot the post-truncation JSONL size.
    void reset(ulong newWatermark)
    {
        import core.lifetime : move;
        history_ = DataVec();
        rawSource_ = null;
        pendingEvents_ = DataVec();
        pendingRaw_ = null;
        watermark_ = newWatermark;
        state_ = newWatermark == 0 ? State.loaded : State.deferred;
    }

    /// The only exit from deferred state. The delegate receives the watermark
    /// snapshotted at reset() time and returns the parsed loaded portion.
    /// HistoryStore splices the loaded portion with the pending buffer atomically
    /// and flips to loaded state. Asserts state == deferred on entry.
    void load(scope LoadedHistory delegate(ulong maxBytes) loader)
    {
        assert(state_ == State.deferred, "HistoryStore.load requires deferred state");
        auto loaded = loader(watermark_);
        foreach (i, ref ev; loaded.history)
        {
            history_ ~= ev;
            rawSource_ ~= (i < loaded.rawSource.length ? loaded.rawSource[i] : null);
        }
        foreach (i, ref ev; pendingEvents_)
        {
            history_ ~= ev;
            rawSource_ ~= (i < pendingRaw_.length ? pendingRaw_[i] : null);
        }
        pendingEvents_ = DataVec();
        pendingRaw_ = null;
        state_ = State.loaded;
    }

    // -------- invariants --------

    invariant
    {
        assert(history_.length == rawSource_.length,
               "history/rawSource length mismatch");
        assert(pendingEvents_.length == pendingRaw_.length,
               "pending events/raw length mismatch");
        final switch (state_)
        {
            case State.uninitialized:
                assert(history_.length == 0 && pendingEvents_.length == 0
                       && watermark_ == 0,
                       "uninitialized state must be fully empty");
                break;
            case State.loaded:
                assert(pendingEvents_.length == 0,
                       "loaded state must have empty pending buffer");
                break;
            case State.deferred:
                break;
        }
    }
}

/// Signal type for batch event queue: child completion or child question.
struct BatchSignal
{
	enum Kind { childDone, question }
	Kind kind;
	ulong batchId;
	size_t slot;
	int childTid;
	McpResult result;      // populated for childDone
	string questionText;   // populated for question

	static BatchSignal childDone(ulong batchId, size_t slot, int tid, McpResult r)
	{
		BatchSignal s;
		s.kind = Kind.childDone;
		s.batchId = batchId;
		s.slot = slot;
		s.childTid = tid;
		s.result = r;
		return s;
	}

	int qid;            // question ID for question signals

	static BatchSignal question(ulong batchId, size_t slot, int tid, string text, int qid)
	{
		BatchSignal s;
		s.kind = Kind.question;
		s.batchId = batchId;
		s.slot = slot;
		s.childTid = tid;
		s.questionText = text;
		s.qid = qid;
		return s;
	}
}

struct VisibleTurnAnchor
{
	size_t seq;
	bool isUser;
	bool isSteering;
	bool pending;
	string anchor;
	string checkpointUuid;
}

enum ProcessState : bool { Dead = false, Alive = true }
enum ArchiveState : bool { Unarchived = false, Archived = true }

/// Pending SwitchMode or Handoff continuation, set by the tool handler and
/// consumed by onExit. Null when no continuation is pending.
struct PendingContinuation
{
	enum Kind { switchMode, handoff }
	Kind kind;
	string key;           // continuation key (was pendingContinuation)
	string handoffPrompt; // only set for Kind.handoff
}

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
	/// Nonces of messages accepted in this session lifetime; cleared on exit.
	bool[string] recentNonces;
	/// Nonce of the last user message sent to the agent; tagged onto the
	/// agent's user_message echo so the reducer can dedupe by nonce alone.
	string pendingUserNonce;
	AgentSession session;
	ProcessLaunch launch;
	HistoryStore history;     // unified: JSONL file events + live stdout events
	@property bool alive() { return session !is null && session.alive; }
	StateQueue!ProcessState* processQueue;
	StateQueue!ArchiveState* archiveQueue;
	bool archiving;  // true while an archive/unarchive transition is in progress
	Promise!ProcessState killPromise;  // non-null during active Dead transition
	bool isProcessing = false;
	bool hadTurnResult = false;    // true after first turn/result in this session lifetime
	bool wasKilledByUser = false;  // set when user explicitly kills via stop button
	bool stdinClosed = false;      // set after closeStdin, cleared on session restart/exit
	bool outputEnforcementAttempted; // true after first enforcement retry for missing outputs
	bool needsAttention = false;
	bool hasPendingQuestion = false;
	string lastSessionStatus;
	long lastSessionStatusTs; // StdTime, 0 when unset
	string notificationBody;
	string resultText;    // result from the "result" event (canonical sub-task output)
	string resultNote;        // note from the creatable_tasks edge, returned with result
	PendingContinuation* pendingContinuation; // null when not set, consumed by onExit
	bool titleGenDone; // true after LLM title generation completed
	Promise!string titleGenHandle;   // prevent GC while running
	void delegate() titleGenKill;    // cancel one-shot subprocess; null if not running
	Promise!string suggestGenHandle; // prevent GC while running
	void delegate() suggestGenKill;  // cancel one-shot subprocess; null if not running
	uint suggestGeneration;  // incremented each time generateSuggestions is called
	string[] lastSuggestions; // most recent suggestions, sent on subscribe
	// --- enqueuedSteering*: parallel arrays, mutate only via helpers below ---
	string[] enqueuedSteeringTexts; // stash of enqueued steering message texts
	string[] enqueuedSteeringRawLines; // parallel: raw JSONL lines for _raw
	VisibleTurnAnchor[] visibleTurnAnchors;
	string pendingDequeuedSteeringText;
	string pendingDequeuedSteeringRawLine;
	bool compactionReminderInFlight;

	invariant (enqueuedSteeringTexts.length == enqueuedSteeringRawLines.length, "steering texts/rawLines length mismatch");

	void setLastSessionStatus(string translatedStatus, long ts)
	{
		lastSessionStatus = translatedStatus;
		lastSessionStatusTs = ts;
	}

	void clearLastSessionStatus()
	{
		lastSessionStatus = null;
		lastSessionStatusTs = 0;
	}

	@property bool hasLastSessionStatus() const
	{
		return lastSessionStatus.length > 0;
	}

	// -- Steering parallel-array helpers --

	/// Enqueue a steering message text and its raw line.
	void enqueueSteering(string text, string rawLine)
	{
		enqueuedSteeringTexts ~= text;
		enqueuedSteeringRawLines ~= rawLine;
		assert(enqueuedSteeringTexts.length == enqueuedSteeringRawLines.length);
	}

	/// Dequeue (pop front) from steering arrays. Returns false if empty.
	bool dequeueSteering()
	{
		if (enqueuedSteeringTexts.length == 0)
			return false;
		enqueuedSteeringTexts = enqueuedSteeringTexts[1 .. $];
		enqueuedSteeringRawLines = enqueuedSteeringRawLines[1 .. $];
		assert(enqueuedSteeringTexts.length == enqueuedSteeringRawLines.length);
		return true;
	}

	/// Pop and return the front steering entry. Returns false if empty.
	bool popSteering(out string text, out string rawLine)
	{
		if (enqueuedSteeringTexts.length == 0)
			return false;
		text = enqueuedSteeringTexts[0];
		rawLine = enqueuedSteeringRawLines[0];
		enqueuedSteeringTexts = enqueuedSteeringTexts[1 .. $];
		enqueuedSteeringRawLines = enqueuedSteeringRawLines[1 .. $];
		assert(enqueuedSteeringTexts.length == enqueuedSteeringRawLines.length);
		return true;
	}

	void setPendingDequeuedSteering(string text, string rawLine)
	{
		pendingDequeuedSteeringText = text;
		pendingDequeuedSteeringRawLine = rawLine;
	}

	bool hasPendingDequeuedSteering() const
	{
		return pendingDequeuedSteeringText.length > 0;
	}

	bool popPendingDequeuedSteering(out string text, out string rawLine)
	{
		if (pendingDequeuedSteeringText.length == 0)
			return false;
		text = pendingDequeuedSteeringText;
		rawLine = pendingDequeuedSteeringRawLine;
		pendingDequeuedSteeringText = null;
		pendingDequeuedSteeringRawLine = null;
		return true;
	}

	void clearPendingDequeuedSteering()
	{
		pendingDequeuedSteeringText = null;
		pendingDequeuedSteeringRawLine = null;
	}

	private size_t visibleTurnAnchorIndex(size_t seq) const
	{
		foreach (i, rec; visibleTurnAnchors)
			if (rec.seq == seq)
				return i;
		return cast(size_t) -1;
	}

	void registerVisibleTurnAnchor(size_t seq, bool isUser, bool isSteering,
		string anchor, string checkpointUuid, bool pending)
	{
		auto idx = visibleTurnAnchorIndex(seq);
		if (idx == cast(size_t) -1)
		{
			VisibleTurnAnchor rec;
			rec.seq = seq;
			rec.isUser = isUser;
			rec.isSteering = isSteering;
			rec.pending = pending;
			rec.anchor = anchor;
			rec.checkpointUuid = checkpointUuid;
			visibleTurnAnchors ~= rec;
			return;
		}

		auto rec = &visibleTurnAnchors[idx];
		rec.isUser = isUser;
		rec.isSteering = isSteering;
		rec.pending = pending;
		rec.anchor = anchor;
		rec.checkpointUuid = checkpointUuid;
	}

	size_t[] pendingVisibleTurnSeqs() const
	{
		size_t[] seqs;
		foreach (rec; visibleTurnAnchors)
			if (rec.pending)
				seqs ~= rec.seq;
		return seqs;
	}

	bool resolveVisibleTurnAnchor(size_t seq, string anchor)
	{
		auto idx = visibleTurnAnchorIndex(seq);
		if (idx == cast(size_t) -1)
			return false;
		auto rec = &visibleTurnAnchors[idx];
		if (rec.anchor == anchor && !rec.pending)
			return false;
		rec.anchor = anchor;
		rec.pending = false;
		return true;
	}

	string[] resolvedVisibleAnchors() const
	{
		string[] anchors;
		bool[string] seen;
		foreach (rec; visibleTurnAnchors)
		{
			if (rec.pending || rec.anchor.length == 0)
				continue;
			if (rec.anchor in seen)
				continue;
			seen[rec.anchor] = true;
			anchors ~= rec.anchor;
		}
		return anchors;
	}

	string[] resolvedEnqueueAnchors() const
	{
		string[] anchors;
		foreach (rec; visibleTurnAnchors)
		{
			if (rec.pending || rec.anchor.length <= "enqueue-".length)
				continue;
			if (rec.anchor[0 .. "enqueue-".length] == "enqueue-")
				anchors ~= rec.anchor;
		}
		return anchors;
	}

	string checkpointUuidForAnchor(string anchor) const
	{
		if (anchor.length == 0)
			return null;
		foreach (rec; visibleTurnAnchors)
		{
			if (rec.pending || rec.anchor != anchor || rec.checkpointUuid.length == 0)
				continue;
			return rec.checkpointUuid;
		}
		return null;
	}

	/// Texts of all messages sent to this task, in send order.
	/// Populated by sendPreparedTaskMessage; NOT cleared by history reset.
	/// Consumed by ensureHistoryLoaded to supply text for queue-operation:enqueue
	/// lines (which Claude's JSONL does not include a content field for), and for
	/// reload replay of un-flushed user messages on agents without queue-ops
	/// (e.g. Copilot).
	string[] pendingSteeringTexts;
	string pendingAskToolUseId;  // correlation ID of a pending AskUserQuestion call
	JSONFragment pendingAskQuestions;  // serialized questions for re-broadcast on reconnect
	string pendingPermissionToolUseId;  // tool_use_id for pending PermissionPrompt, empty when none
	string pendingPermissionToolName;   // tool name for pending PermissionPrompt
	JSONFragment pendingPermissionInput; // input for pending PermissionPrompt (for late-join)
	Promise!McpResult pendingAskPromise;   // child waiting for parent's answer
	string pendingAskQuestion;             // question text from child
	int pendingAskQid;                     // qid allocated for this question
	void delegate()[] onIdleCallbacks;     // callbacks to run when the task next yields idle
	string error;  // last stderr text on non-zero exit; cleared on restart
}

struct TaskHistoryStartMessage
{
	string type = "task_history_start";
	int tid;
	int total;
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
	string agent_name;
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
	bool stdinClosed;
	bool canStop;
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
	string agent_name;
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
	string default_agent;   // per-workspace override, empty = use global
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

struct AgentInfoEntry
{
	string name;           // user-chosen agent name (or driver name when no agents{} block)
	string driver;         // "claude" | "codex" | "copilot"
	string display_name;   // "Claude Code", "Codex", "Copilot"
	bool is_available;
}

struct AgentsListMessage
{
	string type = "agents_list";
	AgentInfoEntry[] agents;
	string default_agent;   // global default from config
}

struct ServerStatusMessage
{
	string type = "server_status";
	bool auth_enabled;
	bool dev_mode;
	string build_id;
}

enum NoticeLevel { info, warning, alert }

struct Notice
{
	NoticeLevel level;
	string description;
	string impact;
	string action;
	string action_kind;
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
	@JSONOptional int qid;            // reserved for compatibility; QuestionResult carries qid for questions
	@JSONOptional string[] commits;   // commit SHAs from worktree (for commit output type)
	string status = "success";
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

unittest
{
    import core.exception : AssertError;
    import std.exception : assertThrown;

    // Helper to make a minimal Data from a string
    auto makeData(string s) { return Data(cast(void[]) s.dup); }

    // 1. Default state is uninitialized — operations assert except isLoaded and reset.
    {
        HistoryStore hs;
        assert(!hs.isLoaded);
        assertThrown!AssertError(hs.appendLive(makeData("x"), null));
        assertThrown!AssertError(hs.lastEventContents());
        assertThrown!AssertError(hs.lastEventTs());
        assertThrown!AssertError(hs.replaceLastEvent(makeData("x")));
        assertThrown!AssertError(hs.load((_) => LoadedHistory.init));
    }

    // 2. reset(0) → loaded+empty; appendLive returns sequential seqs.
    {
        HistoryStore hs;
        hs.reset(0);
        assert(hs.isLoaded);
        assert(hs.length == 0);
        assert(hs.lastEventContents().length == 0);
        auto seq0 = hs.appendLive(makeData("e0"), "raw0");
        assert(seq0 == 0);
        auto seq1 = hs.appendLive(makeData("e1"), "raw1");
        assert(seq1 == 1);
        assert(hs.length == 2);
        assert(hs.rawAt(0) == "raw0");
        assert(hs.rawAt(1) == "raw1");
    }

    // 3. reset(N>0) → deferred; length asserts; appendLive returns cast(size_t)-1.
    {
        HistoryStore hs;
        hs.reset(42);
        assert(!hs.isLoaded);
        assertThrown!AssertError(hs.length);
        assertThrown!AssertError(hs.rawAt(0));
        assertThrown!AssertError({ foreach (i, ref d; hs) {} }());
        auto deferred = hs.appendLive(makeData("live"), "rawlive");
        assert(deferred == cast(size_t) -1);
        assert(hs.lastEventContents() == cast(const(char)[]) "live");
    }

    // 4. load() delegates with correct maxBytes and splices in order.
    {
        HistoryStore hs;
        hs.reset(42);
        hs.appendLive(makeData("pending0"), "praw0");
        hs.appendLive(makeData("pending1"), "praw1");

        bool called = false;
        hs.load((ulong maxBytes) {
            assert(maxBytes == 42);
            assert(!called);
            called = true;
            LoadedHistory lh;
            lh.history ~= makeData("loaded0");
            lh.rawSource ~= "lraw0";
            lh.history ~= makeData("loaded1");
            lh.rawSource ~= "lraw1";
            lh.history ~= makeData("loaded2");
            lh.rawSource ~= "lraw2";
            return lh;
        });
        assert(called);
        assert(hs.isLoaded);
        assert(hs.length == 5);
        assert(cast(string) hs[0].unsafeContents == "loaded0");
        assert(cast(string) hs[1].unsafeContents == "loaded1");
        assert(cast(string) hs[2].unsafeContents == "loaded2");
        assert(cast(string) hs[3].unsafeContents == "pending0");
        assert(cast(string) hs[4].unsafeContents == "pending1");
        assert(hs.rawAt(0) == "lraw0");
        assert(hs.rawAt(3) == "praw0");
        assert(hs.rawAt(4) == "praw1");
    }

    // 5. load() with empty result: pending event at seq 0.
    {
        HistoryStore hs;
        hs.reset(42);
        hs.appendLive(makeData("ev"), "r");
        hs.load((_) => LoadedHistory.init);
        assert(hs.isLoaded);
        assert(hs.length == 1);
        assert(cast(string) hs[0].unsafeContents == "ev");
        assert(hs.rawAt(0) == "r");
    }

    // 6. replaceLastEvent in both states.
    {
        // Deferred: replaceLastEvent mutates pending tail.
        HistoryStore hs;
        hs.reset(10);
        hs.appendLive(makeData("orig"), "r");
        hs.replaceLastEvent(makeData("replaced"));
        hs.load((_) => LoadedHistory.init);
        assert(hs.length == 1);
        assert(cast(string) hs[0].unsafeContents == "replaced");

        // Loaded: replaceLastEvent mutates history tail.
        hs.appendLive(makeData("first"), null);
        hs.appendLive(makeData("second"), null);
        hs.replaceLastEvent(makeData("mutated"));
        assert(cast(string) hs[hs.length - 1].unsafeContents == "mutated");
    }

    // 7. replaceAt asserts for non-loaded state (deferred).
    {
        HistoryStore hs;
        hs.reset(5);
        hs.appendLive(makeData("x"), null);
        assertThrown!AssertError(hs.replaceAt(0, makeData("y")));
    }

    // 8. reset() re-snapshots the watermark; next load receives new maxBytes.
    {
        HistoryStore hs;
        hs.reset(10);
        hs.appendLive(makeData("pending"), null);
        hs.reset(99);  // re-reset clears pending and updates watermark
        // pending should be gone
        hs.load((ulong maxBytes) {
            assert(maxBytes == 99);
            return LoadedHistory.init;
        });
        assert(hs.isLoaded);
        assert(hs.length == 0);
    }
}
