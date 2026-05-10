import type { AgentInfo } from "../useSessionManager";

interface Props {
  agents: AgentInfo[];
  selected: string;
  onChange: (agentName: string) => void;
}

export function AgentPicker({ agents, selected, onChange }: Props) {
  if (agents.length === 0) return null;
  return (
    <select
      class="agent-picker"
      value={selected}
      onChange={(e) => {
        onChange((e.target as HTMLSelectElement).value);
      }}
    >
      {agents.map((a) => (
        <option key={a.name} value={a.name} disabled={a.is_available === false}>
          {a.display_name || a.name}
          {a.is_available === false ? " (not installed)" : ""}
        </option>
      ))}
    </select>
  );
}
