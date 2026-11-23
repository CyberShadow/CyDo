import type { TaskState } from "./types";

type TaskLineage = Pick<TaskState, "parentTid" | "relationType">;
type ReportingTask = TaskLineage & Pick<TaskState, "status"> & { tid: number };

export function subtaskResultParent(
  task: ReportingTask,
  continuationPredecessors: ReadonlySet<number>,
  getByTid: (tid: number) => TaskLineage | undefined,
): number | undefined {
  if (task.status !== "completed" && task.status !== "failed") return;
  if (continuationPredecessors.has(task.tid)) return;

  let origin: TaskLineage | undefined = task;
  while (origin?.relationType === "continuation" && origin.parentTid) {
    origin = getByTid(origin.parentTid);
  }
  if (origin?.relationType === "subtask") return origin.parentTid || undefined;
}

/** End-of-log summary shown on a finished sub-task, linking back to the task
 * its result is reported to. */
export interface SubtaskEnd {
  parentHref: string;
  parentTitle?: string;
  failed: boolean;
}
