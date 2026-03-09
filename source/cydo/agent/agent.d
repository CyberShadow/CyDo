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
	/// Add sandbox path requirements for this agent software.
	/// Called with already-merged paths from config layers;
	/// implementations should avoid downgrading existing rw entries to ro.
	void configureSandboxPaths(ref PathMode[string] paths);

	/// Git identity for commits made by this agent.
	@property string gitName();

	/// ditto
	@property string gitEmail();

	/// Create a new session (or resume an existing one).
	/// bwrapPrefix is the full bwrap command including --bind/--chdir
	/// for the work directory. tid identifies the task for MCP tool routing.
	AgentSession createSession(int tid, string resumeSessionId, string[] bwrapPrefix,
		SessionConfig config = SessionConfig.init);
}
