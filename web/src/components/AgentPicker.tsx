import type { AgentInfo } from "../useSessionManager";

interface Props {
  agents: readonly AgentInfo[];
  selected: string;
  onChange: (agentName: string) => void;
  disabled?: boolean;
}

export function AgentPicker({
  agents,
  selected,
  onChange,
  disabled = false,
}: Props) {
  if (agents.length === 0) return null;
  return (
    <select
      class="agent-picker"
      value={selected}
      disabled={disabled}
      onChange={(e) => {
        if (disabled) return;
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
