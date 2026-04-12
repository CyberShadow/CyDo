module cydo.agent.agent;

import ae.utils.promise : Promise;

import cydo.agent.protocol : TranslatedEvent;
import cydo.agent.session : AgentSession;
import cydo.config : PathMode;
import cydo.sandbox : ProcessLaunch;

/// Per-session configuration passed to createSession.
struct SessionConfig
{
	string model;              /// CLI model alias (e.g., "haiku", "sonnet", "opus"); null = default
	string appendSystemPrompt; /// Appended to the default system prompt; null = none
	string creatableTaskTypes; /// Pre-formatted description of available task types for MCP tool
	string switchModes;        /// Pre-formatted description of available SwitchMode continuations
	string handoffs;           /// Pre-formatted description of available Handoff continuations
	string[] includeTools;     /// MCP tool names visible to this session (only these appear in tools/list)
	bool allowNativeSubagents; /// When true, don't disable Claude's built-in Task tool
	string workspace;          /// Workspace name (Codex uses this as AppServerProcess pool key)
	string workDir;            /// Working directory for the session
	string mcpSocketPath;      /// Absolute path to the backend's UNIX socket for MCP proxy
	string permissionPolicy;   /// Permission policy from workspace config (empty = not configured)
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
	string projectPath; /// Project path if cheaply derivable from directory structure (empty otherwise)
}

/// Metadata extracted by reading session content.
struct SessionMeta
{
	string title;       /// First user message text (truncated)
	string projectPath; /// Working directory from init/meta event (empty if not found)
	bool hasMessages;   /// Whether the session contains any user messages
}

/// Forkable ID with user/assistant classification.
struct ForkableIdInfo {
	string id;
	bool isUser;  // true = user message, false = assistant
}

/// Describes an agent type: its sandbox requirements, git identity,
/// and how to create sessions. Separates agent metadata from
/// the runtime AgentSession interface.
interface Agent
{
	/// Add sandbox path and env requirements for this agent software.
	/// Called with already-merged paths/env from config layers;
	/// implementations should avoid downgrading existing rw entries to ro.
	void configureSandbox(ref PathMode[string] paths, ref string[string] env);

	/// Git identity for commits made by this agent.
	@property string gitName();

	/// ditto
	@property string gitEmail();

	/// Resolve the executable name/path to launch for this agent using the
	/// effective sandbox environment (including config-provided overrides).
	string executableName(string[string] env);

	/// Create a new session (or resume an existing one).
	/// launch carries the full process launch context, including the command
	/// prefix used to enforce sandbox policy and the effective working directory.
	/// tid identifies the task for MCP tool routing.
	AgentSession createSession(int tid, string resumeSessionId, ProcessLaunch launch,
		SessionConfig config = SessionConfig.init);

	/// Try to extract the agent session ID from an output line.
	/// Returns the session ID string if found, null otherwise.
	/// Called for each line of agent output until the session ID is discovered.
	string parseSessionId(string line);

	/// Extract the canonical result text from an agent output line.
	/// Returns empty string if the line is not a result event.
	string extractResultText(string line);

	/// Extract assistant message text from an agent output line.
	/// Returns empty string if the line is not an assistant message.
	string extractAssistantText(string line);

	/// Set config-driven model alias overrides.
	/// These take precedence over hardcoded defaults in resolveModelAlias.
	void setModelAliases(string[string] aliases);

	/// Map abstract model class ("small", "medium", "large") to
	/// agent-specific model name/alias.
	string resolveModelAlias(string modelClass);

	/// Compute the path to the agent's history file for a given session ID.
	/// projectPath is the project's absolute path; empty means use cwd.
	string historyPath(string sessionId, string projectPath);

	/// Translate a history line from the agent's native JSONL format.
	/// Claude returns lines unchanged (raw protocol); Codex translates
	/// from {timestamp, type, payload} to agnostic events.
	/// lineNum is 1-based; agents using line-number fork IDs can inject
	/// the fork ID into translated output.
	/// Returns zero or more translated event pairs (empty = skip line).
	TranslatedEvent[] translateHistoryLine(string line, int lineNum);

	/// Path to the last-created MCP config temp file, or null if none.
	/// Used for cleanup tracking (the file should be deleted when the
	/// session exits).
	@property string lastMcpConfigPath();

	/// Rewrite session ID references in a JSONL line during fork.
	/// Each agent knows its own session ID field names.
	string rewriteSessionId(string line, string oldId, string newId);

	/// Extract forkable identifiers from JSONL content.
	/// Returns opaque ID strings that the frontend sends back as afterUuid.
	/// Each ID corresponds to a user or assistant message boundary.
	/// lineOffset is added to line numbers for agents that use line-based IDs
	/// (used when extracting from a partial read of the file).
	string[] extractForkableIds(string content, int lineOffset = 0);

	/// Extract forkable identifiers with user/assistant classification.
	/// Same as extractForkableIds but includes whether each ID is a user message.
	ForkableIdInfo[] extractForkableIdsWithInfo(string content, int lineOffset = 0);

	/// Check whether a raw JSONL line (at 1-based lineNum) matches a fork ID.
	/// Used by truncation/fork logic to find the cut point.
	bool forkIdMatchesLine(string line, int lineNum, string forkId);

	/// Whether a JSONL line represents a forkable message (user or assistant).
	/// Used for counting messages in undo preview.
	bool isForkableLine(string line);

	/// Translate a raw output line to agnostic protocol JSON.
	/// Returns zero or more translated event pairs (empty = consume event).
	TranslatedEvent[] translateLiveEvent(string rawLine);

	/// Whether a raw output line represents a completed turn.
	bool isTurnResult(string rawLine);

	/// Whether a raw JSONL line is a user message (for compaction detection).
	bool isUserMessageLine(string rawLine);

	/// Whether a raw JSONL line is an assistant message (for compaction detection).
	bool isAssistantMessageLine(string rawLine);

	/// Whether this agent requires the Bash MCP tool.
	/// When false, the Bash tool is excluded from the MCP tools/list.
	@property bool needsBash();

	/// Whether this agent supports reverting file changes.
	/// When false, the UI should hide/disable the file revert option.
	@property bool supportsFileRevert();

	/// Revert files to the state after a given message UUID.
	/// Only called when supportsFileRevert is true.
	RewindResult rewindFiles(string sessionId, string afterUuid, string cwd,
		ProcessLaunch launch = ProcessLaunch.init);

	/// Extract user message text from a raw event line.
	string extractUserText(string line);

	/// Enumerate all persisted sessions for this agent type.
	/// Returns lightweight info from directory scanning / DB query only — no content reads.
	/// Must be safe to call from a background thread (no shared mutable state).
	DiscoveredSession[] enumerateAllSessions();

	/// Extract metadata (title, project path) from a session's persisted content.
	/// The agent reads only as much as needed (e.g., first few lines via byLine).
	/// Must be safe to call from a background thread (pure I/O, no shared mutable state).
	SessionMeta readSessionMeta(string sessionId);

	/// Cheaply match a session to a project path using directory structure only — no file reads.
	/// Returns the matching project path, or "" if not determinable without reading content.
	/// Must be safe to call from a background thread (no shared mutable state).
	string matchProject(string sessionId, const string[] knownProjectPaths);

	/// Run a one-shot LLM completion using the same task-scoped process launch
	/// context as the parent session when the caller needs sandbox env/cwd parity.
	OneShotHandle completeOneShot(string prompt, string modelClass,
		ProcessLaunch launch = ProcessLaunch.init);
}

/// Handle returned by completeOneShot, containing the result promise and a
/// cancel delegate that sends SIGTERM to the subprocess (no-op after exit).
struct OneShotHandle
{
	Promise!string promise;
	void delegate() cancel;
}
