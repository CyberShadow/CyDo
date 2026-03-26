module cydo.agent.registry;

import cydo.agent.agent : Agent;

struct AgentRegistration
{
	string name;         // "claude", "codex", "copilot"
	string displayName;  // "Claude Code", "Codex", "Copilot"
	Agent function() create;
	string function() resolveBinary;  // returns binary path or "" if not found
}

/// The agent registry. To add a new agent, add an entry here.
immutable agentRegistry = [
	AgentRegistration("claude", "Claude Code",
		function Agent() { import cydo.agent.claude : ClaudeCodeAgent; return new ClaudeCodeAgent(); },
		function string() { import cydo.agent.claude : resolveClaudeBinary; return resolveClaudeBinary(); },
	),
	AgentRegistration("codex", "Codex",
		function Agent() { import cydo.agent.codex : CodexAgent; return new CodexAgent(); },
		function string() { import cydo.agent.codex : resolveCodexBinary; return resolveCodexBinary(); },
	),
	AgentRegistration("copilot", "Copilot",
		function Agent() { import cydo.agent.copilot : CopilotAgent; return new CopilotAgent(); },
		function string() { import cydo.agent.copilot : resolveCopilotBinary; return resolveCopilotBinary(); },
	),
];
