module cydo.agent.agent;

import cydo.agent.claude : ClaudeCodeAgent;
import cydo.agent.session : AgentSession;
import cydo.config : PathMode;

/// Per-session configuration passed to createSession.
struct SessionConfig
{
	string model;              /// CLI model alias (e.g., "haiku", "sonnet", "opus"); null = default
	string appendSystemPrompt; /// Appended to the default system prompt; null = none
	string creatableTaskTypes; /// Pre-formatted description of available task types for MCP tool
	string switchModes;        /// Pre-formatted description of available SwitchMode continuations
	string handoffs;           /// Pre-formatted description of available Handoff continuations
	string disallowedTools;    /// Comma-separated list of tools to remove from context
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

	/// Create a new session (or resume an existing one).
	/// bwrapPrefix is the full bwrap command including --bind/--chdir
	/// for the work directory. tid identifies the task for MCP tool routing.
	AgentSession createSession(int tid, string resumeSessionId, string[] bwrapPrefix,
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

	/// Map abstract model class ("small", "medium", "large") to
	/// agent-specific model name/alias.
	string resolveModelAlias(string modelClass);

	/// Compute the path to the agent's history file for a given session ID.
	/// projectPath is the project's absolute path; empty means use cwd.
	string historyPath(string sessionId, string projectPath);

	/// Translate a history line from the agent's native JSONL format.
	/// Claude returns lines unchanged (raw protocol); Codex translates
	/// from {timestamp, type, payload} to agnostic events.
	string translateHistoryLine(string line);

	/// Path to the last-created MCP config temp file, or null if none.
	/// Used for cleanup tracking (the file should be deleted when the
	/// session exits).
	@property string lastMcpConfigPath();

	/// Rewrite session ID references in a JSONL line during fork.
	/// Each agent knows its own session ID field names.
	string rewriteSessionId(string line, string oldId, string newId);

	/// Whether this agent supports reverting file changes.
	/// When false, the UI should hide/disable the file revert option.
	@property bool supportsFileRevert();

	/// Revert files to the state after a given message UUID.
	/// Only called when supportsFileRevert is true.
	/// Returns null on success, or an error string on failure.
	string rewindFiles(string sessionId, string afterUuid, string cwd);
}

/// Create an Agent instance by type name.
Agent createAgent(string agentType)
{
	switch (agentType)
	{
		case "claude":
			return new ClaudeCodeAgent();
		default:
			throw new Exception("Unknown agent type: " ~ agentType);
	}
}
