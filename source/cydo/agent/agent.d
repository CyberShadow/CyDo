module cydo.agent.agent;

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
}
