import type { AgentTypeInfo } from "../useSessionManager";

interface Props {
  agentTypes: AgentTypeInfo[];
  selected: string;
  onChange: (agentType: string) => void;
}

export function AgentPicker({ agentTypes, selected, onChange }: Props) {
  if (agentTypes.length === 0) return null;
  return (
    <select
      class="agent-picker"
      value={selected}
      onChange={(e) => {
        onChange((e.target as HTMLSelectElement).value);
      }}
    >
      {agentTypes.map((a) => (
        <option key={a.name} value={a.name} disabled={a.is_available === false}>
          {a.display_name || a.name}
          {a.is_available === false ? " (not installed)" : ""}
        </option>
      ))}
    </select>
  );
}
