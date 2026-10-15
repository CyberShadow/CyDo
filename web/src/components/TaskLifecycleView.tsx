import type { DisplayMessage } from "../types";

/** a background task's start, completion, or stop */
export function TaskLifecycleView({ message }: { message: DisplayMessage }) {
  const raw = message.rawSource as Record<string, unknown>;
  // live events carry the agnostic type ("task/started"); the subtype check
  // is kept for raw claude history events that retain the original shape
  const isStarted =
    raw.type === "task/started" || raw.subtype === "task_started";
  const taskType = raw.task_type;
  const taskId = raw.task_id;

  let label: string;
  let description: string;
  if (isStarted) {
    label = "Task started";
    description =
      (raw.description as string | undefined) ||
      (taskId as string | undefined) ||
      "";
  } else {
    label = `Task ${typeof raw.status === "string" ? raw.status : "updated"}`;
    description =
      (raw.summary as string | undefined) ||
      (taskId as string | undefined) ||
      "";
  }

  return (
    <div
      class={`message task-lifecycle-message${
        isStarted ? " task-started" : " task-notification"
      }`}
    >
      <span class="task-lifecycle-label">{label}</span>
      {taskType && <span class="task-lifecycle-type">{taskType}</span>}
      {description && <span class="task-lifecycle-desc">{description}</span>}
    </div>
  );
}
