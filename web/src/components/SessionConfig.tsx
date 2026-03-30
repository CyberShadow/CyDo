import { RefObject } from "preact";
import type { EntryPointInfo } from "../useSessionManager";
import { ensureIconStyles } from "./TaskTypeIcon";

interface Props {
  entryPoints: EntryPointInfo[];
  selected: string;
  onTaskTypeChange: (taskType: string) => void;
  pickerRef?: RefObject<HTMLDivElement>;
  onConfirm?: () => void;
  onType?: () => void;
}

export function SessionConfig({
  entryPoints,
  selected,
  onTaskTypeChange,
  pickerRef,
  onConfirm,
  onType,
}: Props) {
  ensureIconStyles();
  if (entryPoints.length === 0) return null;

  const selectedIdx = entryPoints.findIndex((t) => t.name === selected);

  const handleKeyDown = (e: KeyboardEvent) => {
    if (
      (e.key === "ArrowDown" || e.key === "ArrowUp") &&
      !e.ctrlKey &&
      !e.metaKey &&
      !e.altKey &&
      !e.shiftKey
    ) {
      e.preventDefault();
      const dir = e.key === "ArrowDown" ? 1 : -1;
      const next =
        (selectedIdx + dir + entryPoints.length) % entryPoints.length;
      onTaskTypeChange(entryPoints[next]!.name);
    } else if (e.key === "Enter") {
      e.preventDefault();
      onConfirm?.();
    } else if (e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) {
      // Redirect typing to the input box
      onType?.();
    }
  };

  return (
    <div
      class="task-type-picker"
      ref={pickerRef}
      tabIndex={0}
      onKeyDown={handleKeyDown}
    >
      {entryPoints.map((t) => (
        <button
          key={t.name}
          class={`task-type-row ${t.name === selected ? "selected" : ""}`}
          tabIndex={-1}
          onMouseDown={(e: MouseEvent) => {
            e.preventDefault();
          }}
          onClick={() => {
            onTaskTypeChange(t.name);
          }}
        >
          <div class="task-type-header">
            {t.icon && (
              <span class={`task-type-icon task-type-icon-${t.icon}`} />
            )}
            <span class="task-type-name">{t.display_name || t.name}</span>
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
