import { makeTaskState, type TaskState } from "./types";

/**
 * task_history_start marks the beginning of a full replay bundle for one task.
 * The replay must rebuild timeline state from scratch so repeated bundles do
 * not duplicate transcript messages, blocks, or tracked artifacts.
 */
export function resetTaskForHistoryReplay(
  task: TaskState,
  total: number,
): TaskState {
  const pendingUserMessages = task.messages.filter(
    (message) =>
      message.type === "user" && message.ackState === 4 && message.nonce,
  );

  const reset = makeTaskState(
    task.tid,
    task.alive,
    task.resumable,
    task.title,
    false,
    task.workspace,
    task.projectPath,
    task.parentTid,
    task.relationType,
    task.status,
    task.isProcessing,
    task.stdinClosed,
    task.needsAttention,
    task.hasPendingQuestion,
    task.taskType,
    task.archived || false,
    task.createdAt,
    task.lastActive,
    task.agentType,
    task.entryPoint,
    task.archiving || false,
    task.canStop,
  );

  return {
    ...reset,
    uuid: task.uuid,
    everLoaded: task.everLoaded,
    messages: pendingUserMessages,
    msgIdCounter: Math.max(reset.msgIdCounter, task.msgIdCounter),
    historyTotal: total,
    historyReceived: 0,
    pendingHistoryReplies: task.pendingHistoryReplies,
    preReloadDrafts: task.preReloadDrafts,
    inputDraft: task.inputDraft,
    error: task.error,
    undoPending: task.undoPending,
    undoResult: task.undoResult,
    suggestions: task.suggestions,
    serverDraft: task.serverDraft,
    pendingAskUser: task.pendingAskUser,
    pendingPermission: task.pendingPermission,
  };
}
