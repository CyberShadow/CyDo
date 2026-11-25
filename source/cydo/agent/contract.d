module cydo.agent.contract;

import ae.utils.promise : Promise;

import cydo.protocol : TranslatedEvent;
import cydo.domain.policy.permissions : PermissionSettings;
import cydo.agent.session : AgentSession;
import cydo.runtime.config : AgentDriver, ModelSpec;
import cydo.runtime.launch.sandbox_paths : SandboxPaths;
import cydo.runtime.launch.types : NativeHistoryProfile, NativeHistoryRule,
	ProcessLaunch;

/// Per-session configuration passed to createSession.
struct SessionConfig
{
	string model;              /// CLI model alias (e.g., "haiku", "sonnet", "opus"); null = default
	string effort;             /// Reasoning/thinking effort; empty = the driver's default
	string appendSystemPrompt; /// Appended to the default system prompt; null = none
	string[string] toolPlaceholders; /// Pre-formatted text for MCP tool descriptions
	string[] includeTools;     /// MCP tool names visible to this session (only these appear in tools/list)
	bool allowNativeSubagents; /// When true, don't disable Claude's built-in Task tool
	bool allowScheduledWakeups; /// When true, the agent may schedule prompts that start a later turn
	string workspace;          /// Workspace name (Codex uses this as AppServerProcess pool key)
	string workDir;            /// Working directory for the session
	string taskDir;            /// The task's own directory (notes, output); exists at launch; empty = none
	string agentName;          /// User-chosen agent name (config key) — populates SessionInitEvent.agent_name
	string mcpSocketPath;      /// Absolute path to the backend's UNIX socket for MCP proxy
	PermissionSettings permissions; /// How the workspace decides on tool calls
}

/// Result from a rewindFiles call.
struct RewindResult
{
	bool success;
	string output; /// stdout from --rewind-files; contains file list on success, error on failure
}

/// Lightweight info from directory scanning — no file reads.
struct DiscoveredSession
{
	string sessionId;   /// Opaque agent-meaningful identifier (UUID, path-based ID, etc.)
	long mtime;         /// Modification time (SysTime.stdTime) — for cache invalidation
	string exactHistoryPath; /// Transient absolute locator from this discovery scan
}

/// Metadata extracted by reading session content.
struct SessionMeta
{
	string title;       /// First user message title. Every user message needs a non-empty
	                    /// title, such as "[Image]" for an image-only prompt.
	string projectPath; /// Starting working directory as recorded in the session content
	/// Whether a user message was found during metadata extraction.
	bool hasMessages() const { return title.length > 0; }
}

enum PersistedHistoryBoundaryKind
{
	user,
	provisional_user,
	agent_turn,
}

/// Persisted history boundary with its public kind and optional checkpoint.
/// An anchor may match consecutive records of one Claude API message. Fork
/// keeps through the last match; undo cuts before the first.
struct PersistedHistoryBoundary {
	string anchor;
	PersistedHistoryBoundaryKind kind;
	string checkpointUuid;
	int sourceLine;
}

/// Pure result of a driver repairing its persisted interrupted-tool-call
/// records. `removedInterruptionUuid` names the exact native user record that
/// was removed; it remains null unless that record was structurally proven.
/// The on-disk helper exposes this identity to callers only after it writes
/// `lines` successfully.
class InterruptedToolCallRepair
{
	string[] lines;
	string removedInterruptionUuid;

	this(string[] lines, string removedInterruptionUuid = null)
	{
		this.lines = lines;
		this.removedInterruptionUuid = removedInterruptionUuid;
	}
}

/// Translation delegates owned by one load of a native transcript.
struct HistoryReplay
{
	TranslatedEvent[] delegate(string line, int lineNum) translateHistoryLine;
	TranslatedEvent[] delegate() finishHistoryReplay;
}

/// Describes an agent type: its sandbox requirements, git identity,
/// and how to create sessions. Separates agent metadata from
/// the runtime AgentSession interface.
interface Agent
{
	/// Add joined sandbox requirements and environment for this agent software.
	/// Drivers cannot write declarations and must never downgrade access.
	void configureSandbox(ref SandboxPaths paths, ref string[string] env);

	/// Git identity for commits made by this agent.
	@property string gitName();

	/// ditto
	@property string gitEmail();

	/// The registered driver this Agent implements (claude/codex/copilot).
	/// Used for code paths that switch on driver-specific behavior
	/// (history rollback, codex SIGTERM, claude-anchor logic).
	@property AgentDriver driver();

	/// Native-history profile selection declared by this concrete driver.
	@property NativeHistoryRule nativeHistoryRule();

	/// Resolve the executable name/path to launch for this agent using the
	/// effective sandbox environment (including config-provided overrides).
	string executableName(string[string] env);

	/// Create a new session (or resume an existing one).
	/// launch carries the full process launch context, including the command
	/// prefix used to enforce sandbox policy and the effective working directory.
	/// tid identifies the task for MCP tool routing.
	AgentSession createSession(int tid, string resumeSessionId, ProcessLaunch launch,
		SessionConfig config = SessionConfig.init);

	/// Extract the canonical result text from an agent output line.
	/// Returns empty string if the line is not a result event.
	string extractResultText(string line);

	/// Extract assistant message text from an agent output line.
	/// Returns empty string if the line is not an assistant message.
	string extractAssistantText(string line);

	/// Set config-driven model alias overrides.
	/// These take precedence over the hardcoded defaults in resolveModelSpec.
	void setModelAliases(ModelSpec[string] aliases);

	/// The configured keyword of CyDo's [<keyword>: …] system framing.
	void setSystemKeyword(string keyword);

	/// Map a model class label to the driver-specific model name and launch
	/// parameters. "small"/"medium"/"large" have per-driver defaults; any other
	/// label resolves to itself unless overridden.
	ModelSpec resolveModelSpec(string modelClass);

	/// Locate the agent's history file for a session in an exact configured
	/// profile. Returns null when the session cannot be found there; callers
	/// own the existence check on the returned path.
	string historyPath(string sessionId, const ref NativeHistoryProfile profile);

	/// Record a session's exact history locator that CyDo learned outside the
	/// driver's own lookup (live session start, fork creation, discovery
	/// import), so subsequent historyPath calls resolve it without rescanning.
	void registerHistoryPath(string sessionId, string path,
		const ref NativeHistoryProfile profile);

	/// Compute the destination for a generic JSONL history fork, next to the
	/// fork's source history file so the agent resolves the forked session the
	/// same way it resolved the source.
	/// Codex native forks obtain their path from the thread RPC instead.
	string createHistoryForkDestination(string sessionId, string sourceHistoryPath,
		const ref NativeHistoryProfile profile);

	/// Create fresh translation state owned by one history loader.
	HistoryReplay createHistoryReplay();

	/// Path to the last-created MCP config temp file, or null if none.
	/// Used for cleanup tracking (the file should be deleted when the
	/// session exits).
	@property string lastMcpConfigPath();

	/// Rewrite session ID references in a JSONL line during fork.
	/// Each agent knows its own session ID field names.
	string rewriteSessionId(string line, string oldId, string newId);

	/// The 1-based lines of a whole history file that are not part of the
	/// conversation the agent continues: turns it rolled back or rewound
	/// in place, which stay in the file. Readers interpreting the file as
	/// a conversation skip these lines; line numbers stay stable.
	bool[int] inactiveHistoryLines(string content);

	/// Extract persisted history boundaries with explicit kinds.
	PersistedHistoryBoundary[] extractPersistedHistoryBoundaries(string content, int lineOffset = 0);

	/// Repair a persisted session file after CyDo deliberately interrupted an
	/// in-flight MCP tool call, which the harness records as a rejection or
	/// abort. `lines` is the whole session file split into lines; `toolName` is
	/// CyDo's canonical MCP tool name; `resultText` is the result CyDo intended
	/// to deliver. Returns repaired lines, or null if the expected shape is not
	/// present. Pure and non-throwing: an unrecognised shape returns null.
	/// A matching repair may omit removedInterruptionUuid when it rewrites only
	/// the tool result and finds no structurally linked interruption record.
	InterruptedToolCallRepair repairInterruptedToolCall(string[] lines, string toolName,
		string resultText);

	/// Check whether a raw JSONL line (at 1-based lineNum) matches a fork ID.
	/// Used by truncation/fork logic to find the cut point.
	bool forkIdMatchesLine(string line, int lineNum, string forkId);

	/// Match the persisted record targeted by a message edit.
	bool historyRecordIdMatchesLine(string line, int lineNum, string recordId);

	/// Whether a JSONL line represents a forkable message (user or assistant).
	/// Used for counting messages in undo preview.
	bool isForkableLine(string line);

	/// Translate a raw output line to agnostic protocol JSON.
	/// Returns zero or more translated event pairs (empty = consume event).
	TranslatedEvent[] translateLiveEvent(string rawLine);

	/// Whether a raw output line represents a completed turn.
	bool isTurnResult(string rawLine);

	/// Whether a persisted row represents a user prompt for steering bookkeeping.
	bool isHistoryPrompt(string rawLine);

	/// Whether this agent requires the Bash MCP tool.
	/// When false, the Bash tool is excluded from the MCP tools/list.
	@property bool needsBash();

	/// Whether this agent supports reverting file changes.
	/// When false, the UI should hide/disable the file revert option.
	@property bool supportsFileRevert();

	/// Whether this agent reliably supports task system prompts in the
	/// developer/system channel.
	/// When false, CyDo prepends rendered task system prompts to user input.
	@property bool supportsDeveloperPrompt();

	/// Revert files to the state after a given message UUID.
	/// Only called when supportsFileRevert is true.
	/// The rewind subprocess runs in launch.workDir.
	RewindResult rewindFiles(string sessionId, string afterUuid, ProcessLaunch launch);

	/// Extract user message text from a raw event line.
	string extractUserText(string line);

	/// Enumerate all persisted sessions for this agent type.
	/// Each session ID appears at most once per profile. Drivers whose storage
	/// can hold multiple files for one ID resolve those duplicates themselves.
	/// Returns lightweight info from directory scanning / DB query only — no content reads.
	/// Must be safe to call from a background thread (no shared mutable state).
	DiscoveredSession[] enumerateAllSessions(const ref NativeHistoryProfile profile);

	/// Extract metadata (title, project path) from a session's persisted content.
	/// The agent reads only as much as needed (e.g., first few lines via byLine).
	/// Must be safe to call from a background thread (pure I/O, no shared mutable state).
	SessionMeta readSessionMeta(const ref DiscoveredSession session);

	/// Run a one-shot LLM completion using the supplied process launch context.
	OneShotHandle completeOneShot(string prompt, string modelClass,
		ProcessLaunch launch);
}

struct DriverHistoryLaunch
{
	ProcessLaunch processLaunch;
	SessionConfig sessionConfig;
}

struct DriverHistory
{
	/// Boundaries are embedded in the translated event JSON.
	TranslatedEvent[] events;
	ubyte mode;
}

interface DriverServedHistoryAgent : Agent
{
	/// Reject with the detail to display when history is unavailable.
	/// `currentOwner` returns the task's live session, if it has one: a
	/// session can attach while the history is being read. Without one,
	/// `obtainLaunch` provides the launch of the task's own process.
	Promise!DriverHistory loadHistory(string sessionId,
		const ref NativeHistoryProfile profile, AgentSession delegate() currentOwner,
		DriverHistoryLaunch delegate() obtainLaunch);
}

/// Handle returned by completeOneShot, containing the result promise and a
/// cancel delegate that sends SIGTERM to the subprocess (no-op after exit).
struct OneShotHandle
{
	Promise!string promise;
	void delegate() cancel;
}
