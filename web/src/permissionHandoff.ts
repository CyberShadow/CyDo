import type { PermissionPromptState, TaskState } from "./types";

/** The PermissionPrompt answered here, while the agent has yet to take the
 *  answer: it stops waiting once its tool_use block's permission stage moves
 *  past "answered", or the call has a result. */
export function permissionAwaitingAgent(
  task: TaskState,
): PermissionPromptState | undefined {
  const submitted = task.submittedPermission;
  if (!submitted || !task.alive) return undefined;
  const block = task.blocks.get(
    task.itemIdMap.get(submitted.toolUseId) ?? submitted.toolUseId,
  );
  if (
    !block ||
    block.result ||
    block.permission === "accepted" ||
    block.permission === "withdrawn"
  )
    return undefined;
  return submitted;
}
