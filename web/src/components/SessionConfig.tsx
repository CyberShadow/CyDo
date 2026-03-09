import { h } from "preact";
import type { TaskTypeInfo } from "../useSessionManager";

interface Props {
  taskTypes: TaskTypeInfo[];
  selected: string;
  onTaskTypeChange: (taskType: string) => void;
}

export function SessionConfig({
  taskTypes,
  selected,
  onTaskTypeChange,
}: Props) {
  if (taskTypes.length === 0) return null;

  return (
    <div class="task-type-picker">
      {taskTypes.map((t) => (
        <button
          key={t.name}
          class={`task-type-row ${t.name === selected ? "selected" : ""}`}
          onClick={() => onTaskTypeChange(t.name)}
        >
          <div class="task-type-header">
            <span class="task-type-name">{t.name}</span>
            <span class="task-type-badges">
              <span class="config-badge">{t.model_class}</span>
              {t.read_only && <span class="config-badge">ro</span>}
            </span>
          </div>
          <span class="task-type-desc">{t.description}</span>
        </button>
      ))}
    </div>
  );
}
