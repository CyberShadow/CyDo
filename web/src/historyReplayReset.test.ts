import { describe, expect, it } from "vitest";
import { reduceMessage } from "./sessionReducer";
import { resetTaskForHistoryReplay } from "./historyReplayReset";
import { makeTaskState, type TaskState } from "./types";

function asEvent(event: object): Parameters<typeof reduceMessage>[1] {
  return event as Parameters<typeof reduceMessage>[1];
}

function makeRichState(): TaskState {
  return {
    ...makeTaskState(
      7,
      true,
      true,
      "Replay task",
      true,
      "local",
      "/tmp/project",
      3,
      "subtask",
      "waiting",
      true,
      false,
      true,
      true,
      "implement",
      true,
      1000,
      2000,
      "codex",
      "agentic",
      true,
      true,
    ),
    uuid: "task-uuid-7",
    sessionStatus: "requesting",
    sessionInfo: {
      model: "codex-mini-latest",
      version: "1.0.0",
      sessionId: "sid-7",
      cwd: "/tmp/project",
      tools: [],
      permission_mode: "default",
      supports_file_revert: false,
    },
    totalCost: 1.25,
    msgIdCounter: 4,
    messages: [
      {
        id: "user-1",
        type: "user",
        content: [{ type: "text", text: "hello" }],
      },
      {
        id: "sys-1",
        type: "system",
        subtype: "task_lifecycle",
        content: [{ type: "text", text: "Task completed" }],
      },
      {
        id: "pending-1",
        type: "user",
        content: [{ type: "text", text: "local pending" }],
        ackState: 4,
        nonce: "nonce-1",
        pending: true,
      },
      {
        id: "pending-2",
        type: "user",
        content: [{ type: "text", text: "backend acked pending" }],
        ackState: 3,
        nonce: "nonce-2",
        pending: true,
      },
    ],
    historyTotal: 9,
    historyReceived: 5,
    pendingHistoryReplies: 2,
    preReloadDrafts: ["draft A"],
    inputDraft: "draft B",
    error: "stderr line",
    undoPending: { afterUuid: "u-1", messagesRemoved: 1 },
    undoResult: "undo-ok",
    suggestions: ["next step"],
    serverDraft: "server draft",
    pendingAskUser: { toolUseId: "ask-1", questions: [] },
    pendingPermission: {
      toolUseId: "perm-1",
      toolName: "Read",
      input: { file_path: "/tmp/project/a.txt" },
    },
  };
}

describe("history replay reset", () => {
  it("preserves task metadata but clears replay-derived timeline state", () => {
    const before = makeRichState();
    const reset = resetTaskForHistoryReplay(before, 12);

    expect(reset.uuid).toBe(before.uuid);
    expect(reset.tid).toBe(before.tid);
    expect(reset.title).toBe(before.title);
    expect(reset.workspace).toBe(before.workspace);
    expect(reset.projectPath).toBe(before.projectPath);
    expect(reset.parentTid).toBe(before.parentTid);
    expect(reset.relationType).toBe(before.relationType);
    expect(reset.status).toBe(before.status);
    expect(reset.taskType).toBe(before.taskType);
    expect(reset.entryPoint).toBe(before.entryPoint);
    expect(reset.agentType).toBe(before.agentType);
    expect(reset.archived).toBe(before.archived);
    expect(reset.archiving).toBe(before.archiving);
    expect(reset.createdAt).toBe(before.createdAt);
    expect(reset.lastActive).toBe(before.lastActive);
    expect(reset.isProcessing).toBe(before.isProcessing);
    expect(reset.hasPendingQuestion).toBe(before.hasPendingQuestion);
    expect(reset.undoPending).toEqual(before.undoPending);
    expect(reset.undoResult).toBe(before.undoResult);
    expect(reset.pendingAskUser).toEqual(before.pendingAskUser);
    expect(reset.pendingPermission).toEqual(before.pendingPermission);

    expect(reset.messages).toEqual([
      {
        id: "pending-1",
        type: "user",
        content: [{ type: "text", text: "local pending" }],
        ackState: 4,
        nonce: "nonce-1",
        pending: true,
      },
    ]);
    expect(reset.sessionInfo).toBeNull();
    expect(reset.totalCost).toBe(0);
    expect(reset.msgIdCounter).toBe(before.msgIdCounter);
    expect(reset.forkableUuids.size).toBe(0);
    expect(reset.trackedFiles.size).toBe(0);
    expect(reset.blocks.size).toBe(0);
    expect(reset.itemIdMap.size).toBe(0);
    expect(reset.pendingCydoTaskItemIds).toEqual([]);
    expect(reset.spawnedTidsByItemId.size).toBe(0);
    expect(reset.historyTotal).toBe(12);
    expect(reset.historyReceived).toBe(0);
    expect(reset.historyLoaded).toBe(false);
  });

  it("does not duplicate replayed user/system messages across full bundles", () => {
    const userEvent = asEvent({
      type: "item/started",
      item_id: "u-1",
      item_type: "user_message",
      content: [{ type: "text", text: "hello replay" }],
    });
    const systemEvent = asEvent({
      type: "task/notification",
      task_id: "t-1",
      status: "completed",
      summary: "done",
    });

    const initial = makeTaskState(1, true, true);
    const firstBundle = reduceMessage(
      reduceMessage(initial, userEvent),
      systemEvent,
    );
    expect(firstBundle.messages.filter((m) => m.type === "user")).toHaveLength(
      1,
    );
    expect(
      firstBundle.messages.filter((m) => m.type === "system"),
    ).toHaveLength(1);

    const duplicateWithoutReset = reduceMessage(
      reduceMessage(firstBundle, userEvent),
      systemEvent,
    );
    expect(
      duplicateWithoutReset.messages.filter((m) => m.type === "user"),
    ).toHaveLength(2);
    expect(
      duplicateWithoutReset.messages.filter((m) => m.type === "system"),
    ).toHaveLength(2);

    const reset = resetTaskForHistoryReplay(firstBundle, 2);
    const secondBundle = reduceMessage(
      reduceMessage(reset, userEvent),
      systemEvent,
    );
    expect(secondBundle.messages.filter((m) => m.type === "user")).toHaveLength(
      1,
    );
    expect(
      secondBundle.messages.filter((m) => m.type === "system"),
    ).toHaveLength(1);
  });

  it("keeps local pending user messages until their matching replay arrives", () => {
    const initial = {
      ...makeTaskState(1, true, true),
      messages: [
        {
          id: "pending-1",
          type: "user" as const,
          content: [{ type: "text" as const, text: "local pending" }],
          ackState: 4 as const,
          nonce: "nonce-1",
          pending: true,
        },
      ],
      msgIdCounter: 1,
    };

    const unrelatedReplay = reduceMessage(
      resetTaskForHistoryReplay(initial, 1),
      asEvent({
        type: "item/started",
        item_id: "u-1",
        item_type: "user_message",
        content: [{ type: "text", text: "older replay" }],
        is_replay: true,
      }),
    );

    expect(
      unrelatedReplay.messages.some((message) => message.nonce === "nonce-1"),
    ).toBe(true);

    const matchingReplay = reduceMessage(
      unrelatedReplay,
      asEvent({
        type: "item/started",
        item_id: "u-2",
        item_type: "user_message",
        content: [{ type: "text", text: "local pending" }],
        is_replay: true,
        correlation_id: "nonce-1",
      }),
    );

    expect(
      matchingReplay.messages.filter((message) => message.nonce === "nonce-1"),
    ).toHaveLength(0);
    expect(
      matchingReplay.messages.filter((message) =>
        message.content.some(
          (block) => block.type === "text" && block.text === "local pending",
        ),
      ),
    ).toHaveLength(1);
  });

  it("drops local pending user messages when replay without a nonce matches", () => {
    const initial = {
      ...makeTaskState(1, true, true),
      messages: [
        {
          id: "pending-1",
          type: "user" as const,
          content: [{ type: "text" as const, text: "local pending" }],
          ackState: 4 as const,
          nonce: "nonce-1",
          pending: true,
        },
      ],
      msgIdCounter: 1,
    };

    const matchingReplay = reduceMessage(
      resetTaskForHistoryReplay(initial, 1),
      asEvent({
        type: "item/started",
        item_id: "u-1",
        item_type: "user_message",
        content: [{ type: "text", text: "local pending" }],
        is_replay: true,
      }),
    );

    expect(
      matchingReplay.messages.filter((message) => message.nonce === "nonce-1"),
    ).toHaveLength(0);
    expect(
      matchingReplay.messages.filter((message) =>
        message.content.some(
          (block) => block.type === "text" && block.text === "local pending",
        ),
      ),
    ).toHaveLength(1);
  });
});
