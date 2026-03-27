import { useState, useRef, useEffect, useMemo } from "preact/hooks";
import type { TaskState } from "../types";
import type { TaskTypeInfo } from "../useSessionManager";
import { TaskTypeIcon, hasTaskTypeIcon } from "./TaskTypeIcon";

interface Props {
  tasks: Map<number, TaskState>;
  onSelect: (tid: number) => void;
  onClose: () => void;
  taskTypes: TaskTypeInfo[];
}

export function SearchPopup({ tasks, onSelect, onClose, taskTypes }: Props) {
  const [query, setQuery] = useState("");
  const [selectedIdx, setSelectedIdx] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLDivElement>(null);

  // All tasks sorted by tid descending (most recent first)
  const allTasks = useMemo(
    () => Array.from(tasks.values()).sort((a, b) => b.tid - a.tid),
    [tasks],
  );

  const filtered = useMemo(() => {
    if (!query) return allTasks;
    const q = query.toLowerCase();
    return allTasks.filter(
      (t) =>
        (t.title && t.title.toLowerCase().includes(q)) ||
        String(t.tid).includes(q),
    );
  }, [allTasks, query]);

  // Clamp selection when results change
  useEffect(() => {
    setSelectedIdx(0);
  }, [query]);

  // Auto-focus
  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  // Scroll selected item into view
  useEffect(() => {
    const item = listRef.current?.children[selectedIdx] as
      | HTMLElement
      | undefined;
    item?.scrollIntoView({ block: "nearest" });
  }, [selectedIdx]);

  const handleKeyDown = (e: KeyboardEvent) => {
    if (e.key === "Escape") {
      onClose();
    } else if (e.key === "ArrowDown") {
      e.preventDefault();
      setSelectedIdx((i) => Math.min(i + 1, filtered.length - 1));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setSelectedIdx((i) => Math.max(i - 1, 0));
    } else if (e.key === "Enter" && filtered.length > 0) {
      e.preventDefault();
      onSelect(filtered[selectedIdx]!.tid);
      onClose();
    }
  };

  return (
    <div class="search-overlay" onClick={onClose}>
      <div
        class="search-popup"
        onClick={(e) => {
          e.stopPropagation();
        }}
      >
        <input
          ref={inputRef}
          class="search-input"
          type="text"
          placeholder="Search sessions..."
          value={query}
          onInput={(e) => {
            setQuery((e.target as HTMLInputElement).value);
          }}
          onKeyDown={handleKeyDown}
        />
        <div class="search-results" ref={listRef}>
          {filtered.map((t, i) => {
            let statusClass = "";
            if (t.isProcessing)
              statusClass = t.status === "waiting" ? "waiting" : "processing";
            else if (t.alive) statusClass = "alive";
            else if (t.resumable) statusClass = "resumable";
            else if (t.status === "completed") statusClass = "completed";
            else if (t.status === "failed") statusClass = "failed";
            const hasIcon = hasTaskTypeIcon(t.taskType, taskTypes);
            return (
              <div
                key={t.tid}
                class={`search-result-item${
                  i === selectedIdx ? " selected" : ""
                }`}
                onClick={() => {
                  onSelect(t.tid);
                  onClose();
                }}
                onMouseEnter={() => {
                  setSelectedIdx(i);
                }}
              >
                {hasIcon ? (
                  <TaskTypeIcon
                    taskType={t.taskType}
                    taskTypes={taskTypes}
                    class={statusClass || undefined}
                  />
                ) : (
                  <span
                    class={`task-type-icon task-type-icon-dot${
                      statusClass ? ` ${statusClass}` : ""
                    }`}
                  />
                )}
                <span class="search-result-title">
                  {t.title || `Task ${t.tid}`}
                </span>
                {t.workspace && (
                  <span class="search-result-meta">{t.workspace}</span>
                )}
              </div>
            );
          })}
          {filtered.length === 0 && (
            <div class="search-no-results">No matching sessions</div>
          )}
        </div>
      </div>
    </div>
  );
}
