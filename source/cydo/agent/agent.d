module cydo.agent.agent;

import cydo.agent.session : AgentSession;
import cydo.config : PathMode;

/// Describes an agent type: its sandbox requirements, git identity,
/// and how to create sessions. Separates agent metadata from
/// the runtime AgentSession interface.
interface Agent
{
	/// Sandbox path requirements for this agent software.
	/// Map of absolute path → PathMode (ro or rw).
	@property PathMode[string] sandboxPaths();

	/// Git identity for commits made by this agent.
	@property string gitName();

	/// ditto
	@property string gitEmail();

	/// Create a new session (or resume an existing one).
	/// bwrapPrefix is the full bwrap command including --bind/--chdir
	/// for the work directory. sid identifies the session for MCP tool routing.
	AgentSession createSession(int sid, string resumeSessionId, string[] bwrapPrefix);
}
