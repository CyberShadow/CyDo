import { h } from "preact";
import { useState, useMemo } from "preact/hooks";
import type { TaskTypeInfo } from "../useSessionManager";

interface Props {
  taskTypes: TaskTypeInfo[];
  onTaskTypeChange: (taskType: string) => void;
}

export function SessionConfig({ taskTypes, onTaskTypeChange }: Props) {
  const [selected, setSelected] = useState("");

  // Sort: conversation first, then alphabetical
  const sorted = useMemo(() => {
    return [...taskTypes].sort((a, b) => {
      if (a.name === "conversation") return -1;
      if (b.name === "conversation") return 1;
      return a.name.localeCompare(b.name);
    });
  }, [taskTypes]);

  const handleChange = (e: Event) => {
    const val = (e.target as HTMLSelectElement).value;
    setSelected(val);
    onTaskTypeChange(val);
  };

  if (sorted.length === 0) return null;

  const current = sorted.find((t) => t.name === selected) ?? sorted[0];

  return (
    <div class="session-config">
      <div class="config-field">
        <label class="config-label">Task Type</label>
        <select
          class="config-select"
          value={selected || sorted[0]?.name}
          onChange={handleChange}
        >
          {sorted.map((t) => (
            <option key={t.name} value={t.name}>
              {t.name}
            </option>
          ))}
        </select>
      </div>
      {current && (
        <div class="config-detail">
          <span class="config-detail-text">{current.description}</span>
          <span class="config-badges">
            <span class="config-badge">{current.model_class}</span>
            <span class="config-badge">{current.tool_preset}</span>
          </span>
        </div>
      )}
    </div>
  );
}
