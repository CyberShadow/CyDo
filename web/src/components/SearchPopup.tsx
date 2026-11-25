import {
  useState,
  useRef,
  useEffect,
  useLayoutEffect,
  useMemo,
} from "preact/hooks";
import type { TaskState } from "../types";
import type { TypeInfo } from "../useSessionManager";
import { TaskTypeIcon, hasTaskTypeIcon } from "./TaskTypeIcon";

const MAX_RESULTS = 99;
const INCLUDE_SUBTASKS_KEY = "searchIncludeSubtasks";

type TaskWithTid = TaskState & { tid: number };

interface Props {
  tasks: Map<string, TaskState>;
  tasksLoaded: boolean;
  onSelect: (tid: number) => void;
  onClose: () => void;
  taskTypes: TypeInfo[];
  getTaskHref: (tid: number) => string;
}

function isPlainLeftClick(e: MouseEvent): boolean {
  return (
    e.button === 0 &&
    !e.defaultPrevented &&
    !e.metaKey &&
    !e.ctrlKey &&
    !e.shiftKey &&
    !e.altKey
  );
}

export function SearchPopup({
  tasks,
  tasksLoaded,
  onSelect,
  onClose,
  taskTypes,
  getTaskHref,
}: Props) {
  const [query, setQuery] = useState("");
  const [selectedIdx, setSelectedIdx] = useState(0);
  const [includeSubtasks, setIncludeSubtasks] = useState(
    () => localStorage.getItem(INCLUDE_SUBTASKS_KEY) === "true",
  );
  const inputRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLDivElement>(null);

  // All tasks sorted by lastActive descending (most recent first); exclude virtual drafts
  const sortedTasks = useMemo(
    () =>
      Array.from(tasks.values())
        .filter((t): t is TaskWithTid => t.tid !== null)
        .sort(
          (a, b) => (b.lastActive ?? 0) - (a.lastActive ?? 0) || b.tid - a.tid,
        ),
    [tasks],
  );

  const { shown, hiddenCount } = useMemo(() => {
    const q = query.toLowerCase();
    const exactTid = /^\d+$/.test(query) ? Number(query) : null;
    let exact: TaskWithTid | undefined;
    const shown: TaskWithTid[] = [];
    let total = 0;
    for (const task of sortedTasks) {
      if (task.tid === exactTid) {
        exact = task;
        continue;
      }
      if (task.parentTid && !includeSubtasks) continue;
      if (
        q &&
        !(task.title?.toLowerCase().includes(q) || String(task.tid).includes(q))
      )
        continue;
      total++;
      if (shown.length < MAX_RESULTS) shown.push(task);
    }
    if (exact) {
      shown.unshift(exact);
      total++;
      if (shown.length > MAX_RESULTS) shown.pop();
    }
    return { shown, hiddenCount: total - shown.length };
  }, [sortedTasks, query, includeSubtasks]);

  const sel = Math.min(selectedIdx, shown.length - 1);

  // Move focus before the browser dispatches any queued key event.
  useLayoutEffect(() => {
    inputRef.current?.focus();
  }, []);

  useEffect(() => {
    const item = listRef.current?.children[sel];
    item?.scrollIntoView({ block: "nearest" });
  }, [sel, shown]);

  const toggleIncludeSubtasks = () => {
    const next = !includeSubtasks;
    localStorage.setItem(INCLUDE_SUBTASKS_KEY, String(next));
    setIncludeSubtasks(next);
    setSelectedIdx(0);
  };

  const handleKeyDown = (e: KeyboardEvent) => {
    if (e.key === "Escape") {
      onClose();
    } else if (
      e.altKey &&
      !e.ctrlKey &&
      !e.metaKey &&
      !e.shiftKey &&
      e.code === "KeyS"
    ) {
      e.preventDefault();
      toggleIncludeSubtasks();
    } else if (e.key === "ArrowDown") {
      e.preventDefault();
      setSelectedIdx((i) => Math.min(i + 1, Math.max(0, shown.length - 1)));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setSelectedIdx((i) => Math.max(Math.min(i, shown.length - 1) - 1, 0));
    } else if (e.key === "Enter" && shown.length > 0) {
      e.preventDefault();
      onSelect(shown[sel]!.tid);
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
            setQuery(e.currentTarget.value);
            setSelectedIdx(0);
          }}
          onKeyDown={handleKeyDown}
        />
        <div class="search-results" ref={listRef}>
          {shown.map((t, i) => {
            let statusClass = "";
            if (t.isProcessing)
              statusClass = t.status === "waiting" ? "waiting" : "processing";
            else if (t.alive)
              statusClass = t.status === "waiting" ? "waiting" : "alive";
            else if (t.resumable) statusClass = "resumable";
            else if (t.status === "completed") statusClass = "completed";
            else if (t.status === "failed") statusClass = "failed";
            const hasIcon = hasTaskTypeIcon(t.taskType, taskTypes);
            return (
              <a
                key={t.uuid}
                href={getTaskHref(t.tid)}
                class={`search-result-item${i === sel ? " selected" : ""}`}
                onClick={(e: MouseEvent) => {
                  if (!isPlainLeftClick(e)) return;
                  e.preventDefault();
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
              </a>
            );
          })}
          {hiddenCount > 0 && (
            <div class="search-more">…and {hiddenCount} more</div>
          )}
          {shown.length === 0 && (
            <div class="search-no-results">
              {tasksLoaded
                ? "No matching sessions"
                : "More sessions are loading…"}
            </div>
          )}
        </div>
        <div class="search-footer">
          <label class="search-option" title="Include sub-tasks (Alt+S)">
            <input
              type="checkbox"
              class="search-option-checkbox"
              checked={includeSubtasks}
              onChange={() => {
                toggleIncludeSubtasks();
                inputRef.current?.focus();
              }}
            />
            Include sub-tasks
          </label>
          <kbd class="search-option-key">Alt+S</kbd>
        </div>
      </div>
    </div>
  );
}
