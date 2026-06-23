module cydo.agent.drivers.registry;

import cydo.agent.contract : Agent;

struct AgentRegistration
{
	string name;         // "claude", "codex", "copilot"
	string displayName;  // "Claude Code", "Codex", "Copilot"
	Agent function() create;
}

/// The agent registry. To add a new agent, add an entry here.
immutable agentRegistry = [
	AgentRegistration("claude", "Claude Code",
		function Agent() { import cydo.agent.drivers.claude : ClaudeCodeAgent; return new ClaudeCodeAgent(); },
	),
	AgentRegistration("codex", "Codex",
		function Agent() { import cydo.agent.drivers.codex : CodexAgent; return new CodexAgent(); },
	),
	AgentRegistration("copilot", "Copilot",
		function Agent() { import cydo.agent.drivers.copilot : CopilotAgent; return new CopilotAgent(); },
	),
];
