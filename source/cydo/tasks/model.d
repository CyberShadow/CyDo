module cydo.tasks.model;

private string[string] repoPathCache;

import ae.sys.data : Data;
import ae.sys.dataset : DataVec;
import ae.utils.json : JSONFragment, JSONOptional, JSONPartial;
import ae.utils.promise : Promise, PromiseQueue;
import ae.utils.statequeue : StateQueue;

import cydo.agent.protocol : ContentBlock, ItemStartedEvent;
import cydo.launch.types : ProcessLaunch;
import cydo.storage.persistence : LoadedHistory;

import cydo.agent.session : AgentSession;
import cydo.mcp : McpResult;
import cydo.tasktype : substituteVars;
import std.exception : enforce;
import std.format : format;
import std.path : buildPath, expandTilde;

enum defaultTaskDirTemplate = "{{ workspace_root }}/.cydo/tasks/{{ tid }}";

/// Git repository root for the selected project.
/// Falls back to projectPath if git resolution fails.
string resolveProjectRepoPath(string projectPath)
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

string resolveTaskDir(int tid, string workspace, string workspaceRoot, string projectPath,
	string repoPath, string taskDirTemplate)
{
	enforce(tid > 0, "Task id must be positive");
	enforce(workspaceRoot.length > 0, "workspace_root must not be empty");
	enforce(taskDirTemplate.length > 0, "task_dir template must not be empty");
	string[string] vars = [
		"tid": format!"%d"(tid),
		"workspace": workspace,
		"workspace_root": workspaceRoot,
		"project_path": projectPath,
		"repo_path": repoPath,
	];

	return expandTilde(substituteVars(taskDirTemplate, vars));
}

string outputPathForTaskDir(string taskDir)
{
	enforce(taskDir.length > 0, "taskDir must not be empty");
	return buildPath(taskDir, "output.md");
}

string worktreePathForTaskDir(string taskDir)
{
	enforce(taskDir.length > 0, "taskDir must not be empty");
	return buildPath(taskDir, "worktree");
}

string effectiveCwdForTask(string projectPath, string repoPath, string worktreePath,
	int worktreeTid)
{
	if (worktreeTid <= 0)
		return projectPath;
	enforce(worktreePath.length > 0, "worktreePath must not be empty for worktree task");
	if (projectPath.length == 0)
		return worktreePath;
	if (repoPath.length == 0 || repoPath == projectPath)
		return worktreePath;

	import std.path : relativePath;
	auto relProjectPath = relativePath(projectPath, repoPath);
	if (relProjectPath.length == 0 || relProjectPath == ".")
		return worktreePath;
	return buildPath(worktreePath, relProjectPath);
}

/// Snapshot of the on-disk JSONL state at HistoryStore.reset() time.
///
/// Pass to reset() one of:
///   - Watermark.none() — there is no on-disk JSONL to load. The store goes
///     straight to loaded state and accepts live events immediately. Use for
///     brand-new tasks (createTask), tasks without an agent session, and
///     post-truncation paths whose JSONL no longer exists.
///   - Watermark.atBytes(N) — the JSONL holds N bytes at snapshot time. The
///     store enters deferred state; live events are buffered in pendingEvents_
///     and the load() delegate receives N as its maxBytes parameter.
///   - Watermark.unreadable() — the JSONL is expected but cannot be read
///     (orphan agent, missing path). The store enters deferred state so the
///     load() codepath still runs (e.g. to synthesize error events), but the
///     load delegate is invoked with maxBytes==0 and must return
///     LoadedHistory.init.
struct Watermark
{
private:
    ulong bytes_;
    bool deferred_;

    this(ulong bytes, bool deferred) pure nothrow @safe @nogc
    {
        bytes_ = bytes;
        deferred_ = deferred;
    }

public:
    static Watermark none() pure nothrow @safe @nogc { return Watermark(0, false); }
    static Watermark atBytes(ulong bytes) pure nothrow @safe @nogc { return Watermark(bytes, true); }
    static Watermark unreadable() pure nothrow @safe @nogc { return Watermark(0, true); }

    /// Bytes the load() delegate is allowed to read. 0 for none() and unreadable().
    @property ulong maxBytes() const pure nothrow @safe @nogc { return bytes_; }
    /// True when reset() will transition into the deferred state.
    @property bool isDeferred() const pure nothrow @safe @nogc { return deferred_; }
}

/// Convenience: snapshot an optional on-disk JSONL into a Watermark.
/// Returns atBytes(getSize(path)) when path is present, none() otherwise.
/// Use in truncation/rollback paths where a missing file means "nothing to
/// load" (loaded state). Orphan handling should call Watermark.unreadable()
/// directly instead — the semantic there is "force deferred even though
/// nothing is readable".
Watermark watermarkFromPath(string path)
{
    import std.file : exists, getSize;
    return (path.length > 0 && exists(path))
        ? Watermark.atBytes(getSize(path))
        : Watermark.none();
}

/// Encapsulates per-task history with a watermark/buffer state machine.
///
/// The three states:
///   - uninitialized: initial default; every public op (except reset and isLoaded)
///     asserts. Callers must call reset() before any other operation.
///   - loaded: history_ holds the canonical event sequence; pendingEvents_ is empty.
///     All query and mutation operations are available.
///   - deferred: the on-disk JSONL has not been read yet. Live events are buffered
///     in pendingEvents_ until load() is called. Read operations (length, opIndex,
///     opApply, ...) assert isLoaded — callers must call ensureHistoryLoaded first.
///
/// Design rationale:
///   - appendLive routes new events between history_ (loaded) and pendingEvents_
///     (deferred) based on state, so callers cannot append to history without
///     having first loaded it. Read accessors assert loaded state.
///   - The watermark makes the durable-vs-live boundary unambiguous: no event
///     is ever discarded; no content-aware dedup is needed; the two streams meet
///     at a known byte offset.
struct HistoryStore
{
private:
    DataVec  history_;
    string[] rawSource_;
    DataVec  pendingEvents_;
    string[] pendingRaw_;
    enum State : ubyte { uninitialized, loaded, deferred }
    State     state_ = State.uninitialized;
    Watermark watermark_;

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
        import cydo.tasks.model : extractTsFromEnvelope;
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
    /// See Watermark for the three reset shapes (none/atBytes/unreadable).
    ///
    /// Re-resetting an already-initialized store is legal and used by truncation
    /// paths (performUndoExecution, handleEditMessage, thread/rollback, etc.) to
    /// discard in-memory state and re-snapshot the post-truncation JSONL size.
    void reset(Watermark wm)
    {
        history_ = DataVec();
        rawSource_ = null;
        pendingEvents_ = DataVec();
        pendingRaw_ = null;
        watermark_ = wm;
        state_ = wm.isDeferred ? State.deferred : State.loaded;
    }

    /// The only exit from deferred state. The delegate receives the watermark
    /// snapshotted at reset() time and returns the parsed loaded portion.
    /// HistoryStore splices the loaded portion with the pending buffer atomically
    /// and flips to loaded state. Asserts state == deferred on entry.
    void load(scope LoadedHistory delegate(ulong maxBytes) loader)
    {
        assert(state_ == State.deferred, "HistoryStore.load requires deferred state");
        auto loaded = loader(watermark_.maxBytes);
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
                       && !watermark_.isDeferred && watermark_.maxBytes == 0,
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
	this(int tid, string workspace, string projectPath)
	{
		enforce(tid > 0, "Task id must be positive");
		this.tid = tid;
		this.workspace = workspace;
		this.projectPath = projectPath;
	}

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
		return resolveProjectRepoPath(projectPath);
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

	string effectiveCwd(string worktreePath) const
	{
		return effectiveCwdForTask(projectPath, repoPath, worktreePath, worktreeTid);
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
	bool undoStopInProgress; // true while undo fallback owns post-stop reload/finalization
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

struct ScanStatusMessage
{
	string type = "scan_status";
	bool scanning;
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

unittest
{
	auto dir = resolveTaskDir(
		42,
		"main",
		"/tmp/ws",
		"/tmp/ws/project",
		"/tmp/ws/project",
		defaultTaskDirTemplate,
	);
	assert(dir == buildPath("/tmp/ws", ".cydo", "tasks", "42"));
}

unittest
{
	auto dir = resolveTaskDir(
		7,
		"main",
		"/tmp/ws",
		"/tmp/ws/project",
		"/tmp/ws/project",
		"{{ workspace_root }}/runs/{{ tid }}",
	);
	assert(dir == buildPath("/tmp/ws", "runs", "7"));
}

unittest
{
	auto taskDir = buildPath("/tmp/ws", ".cydo", "tasks", "42");
	auto worktreePath = buildPath(taskDir, "worktree");
	assert(outputPathForTaskDir(taskDir) == buildPath(taskDir, "output.md"));
	assert(worktreePathForTaskDir(taskDir) == worktreePath);
	assert(effectiveCwdForTask(
		buildPath("/tmp/repo", "project"),
		"/tmp/repo",
		worktreePath,
		42,
	) == buildPath(worktreePath, "project"));
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
long extractTsFromEnvelope(const(char)[] envelope)
{
	import ae.utils.json : JSONOptional, JSONPartial, jsonParse;
	@JSONPartial static struct TsProbe { @JSONOptional long ts; }
	try { return jsonParse!TsProbe(envelope).ts; }
	catch (Exception) { return 0; }
}

/// Extract the "event" field from a task envelope JSON string.
/// Envelopes have the form: {"tid":N,"ts":N,"event":{...}}
/// Constness-polymorphic via `inout` so callers can keep the mutable
/// view they obtained from `Data.enter` — no immutability hard-cast.
inout(char)[] extractEventFromEnvelope(inout(char)[] envelope)
{
	import std.string : indexOf;

	// Find ,"event": — comma prevents matching inside other keys
	// like "unconfirmedUserEvent".
	auto key = `,"event":`;
	auto idx = envelope.indexOf(key);
	if (idx < 0)
		return envelope[0 .. 0];

	auto start = idx + key.length;
	if (start >= envelope.length)
		return envelope[0 .. 0];

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

    // 2. Watermark.none() → loaded+empty; appendLive returns sequential seqs.
    {
        HistoryStore hs;
        hs.reset(Watermark.none());
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

    // 3. Watermark.atBytes(N) → deferred; length asserts; appendLive returns cast(size_t)-1.
    {
        HistoryStore hs;
        hs.reset(Watermark.atBytes(42));
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
        hs.reset(Watermark.atBytes(42));
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

    // 5. load() keeps collecting deferred live events until the loader returns,
    //    then appends the full pending buffer after the loaded prefix.
    {
        HistoryStore hs;
        hs.reset(Watermark.atBytes(42));
        hs.appendLive(makeData("pending-before"), "praw-before");

        hs.load((_) {
            auto deferred0 = hs.appendLive(makeData("pending-during0"), "praw-during0");
            auto deferred1 = hs.appendLive(makeData("pending-during1"), "praw-during1");
            assert(deferred0 == cast(size_t) -1);
            assert(deferred1 == cast(size_t) -1);

            LoadedHistory lh;
            lh.history ~= makeData("loaded0");
            lh.rawSource ~= "lraw0";
            lh.history ~= makeData("loaded1");
            lh.rawSource ~= "lraw1";
            return lh;
        });

        assert(hs.isLoaded);
        assert(hs.length == 5);
        assert(cast(string) hs[0].unsafeContents == "loaded0");
        assert(cast(string) hs[1].unsafeContents == "loaded1");
        assert(cast(string) hs[2].unsafeContents == "pending-before");
        assert(cast(string) hs[3].unsafeContents == "pending-during0");
        assert(cast(string) hs[4].unsafeContents == "pending-during1");
        assert(hs.rawAt(0) == "lraw0");
        assert(hs.rawAt(1) == "lraw1");
        assert(hs.rawAt(2) == "praw-before");
        assert(hs.rawAt(3) == "praw-during0");
        assert(hs.rawAt(4) == "praw-during1");
    }

    // 6. load() with empty result: pending event at seq 0.
    {
        HistoryStore hs;
        hs.reset(Watermark.atBytes(42));
        hs.appendLive(makeData("ev"), "r");
        hs.load((_) => LoadedHistory.init);
        assert(hs.isLoaded);
        assert(hs.length == 1);
        assert(cast(string) hs[0].unsafeContents == "ev");
        assert(hs.rawAt(0) == "r");
    }

    // 7. replaceLastEvent in both states.
    {
        // Deferred: replaceLastEvent mutates pending tail.
        HistoryStore hs;
        hs.reset(Watermark.atBytes(10));
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

    // 8. replaceAt asserts for non-loaded state (deferred).
    {
        HistoryStore hs;
        hs.reset(Watermark.atBytes(5));
        hs.appendLive(makeData("x"), null);
        assertThrown!AssertError(hs.replaceAt(0, makeData("y")));
    }

    // 9. Invariant: loaded state must have empty pending buffer; parallel arrays
    //    must stay length-matched. D's invariant fires on every public method entry.
    {
        // Violate loaded-implies-empty-pending by directly setting pendingEvents_.
        HistoryStore hs;
        hs.reset(Watermark.none());
        assert(hs.isLoaded);
        // Sneak a pending event in while bypassing the API — only possible from
        // within this module (private field access).
        hs.pendingEvents_ ~= makeData("ghost");
        hs.pendingRaw_ ~= "ghostraw";
        assertThrown!AssertError(hs.isLoaded);  // invariant fires on re-entry
        // Restore valid state before scope exit — the invariant also fires on
        // the implicit destructor, so leaving the struct in corrupt state would
        // re-trigger the assertion during cleanup.
        hs.pendingEvents_ = DataVec();
        hs.pendingRaw_ = null;
    }
    {
        // Violate parallel-array invariant: history length != rawSource length.
        HistoryStore hs2;
        hs2.reset(Watermark.none());
        hs2.history_ ~= makeData("ev");
        // rawSource_ intentionally left empty → length mismatch
        assertThrown!AssertError(hs2.isLoaded);
        // Restore before scope exit.
        hs2.history_ = DataVec();
    }

    // 10. reset() re-snapshots the watermark; next load receives new maxBytes.
    {
        HistoryStore hs;
        hs.reset(Watermark.atBytes(10));
        hs.appendLive(makeData("pending"), null);
        hs.reset(Watermark.atBytes(99));  // re-reset clears pending and updates watermark
        hs.load((ulong maxBytes) {
            assert(maxBytes == 99);
            return LoadedHistory.init;
        });
        assert(hs.isLoaded);
        assert(hs.length == 0);
    }

    // 11. Watermark.unreadable() → deferred with maxBytes==0.
    {
        HistoryStore hs;
        hs.reset(Watermark.unreadable());
        assert(!hs.isLoaded);
        bool loaderCalled = false;
        hs.load((ulong maxBytes) {
            assert(maxBytes == 0);
            loaderCalled = true;
            return LoadedHistory.init;
        });
        assert(loaderCalled);
        assert(hs.isLoaded);
        assert(hs.length == 0);
    }
}
