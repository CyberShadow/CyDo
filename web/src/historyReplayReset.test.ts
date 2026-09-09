import { describe, expect, it } from "vitest";
import { reduceMessage } from "./sessionReducer";
import {
  beginTaskHistoryReplay,
  excludeReloadDraftUuid,
  reconcileInputDraft,
  resetTaskForReload,
  resetTaskForHistoryReplay,
  snapshotUserDrafts,
} from "./historyReplayReset";
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
      "work-codex",
      "agentic",
      true,
      true,
      "codex",
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
    preReloadDrafts: [{ text: "draft A" }],
    inputDraft: "draft B",
    error: "stderr line",
    undoPending: {
      anchor: "u-1",
      kind: "history_entries",
      messagesRemoved: 1,
      canRevertFiles: false,
      retainsPrompt: false,
    },
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
  it("reconstructs in-turn diagnostic placement exactly during replay", () => {
    const events = [
      {
        type: "item/started",
        item_id: "text-1",
        item_type: "text",
        text: "First",
      },
      {
        type: "item/delta",
        item_id: "text-1",
        delta_type: "text_delta",
        content: " output",
      },
      {
        type: "cydo/task_diagnostic",
        severity: "warning",
        subject: "Agent error (retrying)",
        body: "API error: overloaded (attempt 1/3)",
      },
      {
        type: "item/started",
        item_id: "text-2",
        item_type: "text",
        text: "Second",
      },
      {
        type: "item/delta",
        item_id: "text-2",
        delta_type: "text_delta",
        content: " output",
      },
      { type: "turn/stop" },
    ];
    const initial = makeTaskState(1, true, true);
    const live = events.reduce<TaskState>(
      (state, event) => reduceMessage(state, asEvent(event)),
      initial,
    );
    const replayed = events.reduce<TaskState>(
      (state, event) => reduceMessage(state, asEvent(event)),
      resetTaskForHistoryReplay(live, events.length),
    );

    const shape = (state: typeof live) => ({
      messages: state.messages.map((message) => ({
        type: message.type,
        streaming: message.streaming,
        nextCreationOrder: message.nextCreationOrder,
        blocks: (message.blockIds ?? []).map((id) => {
          const block = state.blocks.get(id)!;
          return {
            type: block.type,
            text: block.text,
            ...(block.type === "diagnostic"
              ? { severity: block.severity, subject: block.subject }
              : {}),
            completed: block.completed,
            creationOrder: block.creationOrder,
          };
        }),
      })),
    });

    expect(shape(replayed)).toEqual(shape(live));
    expect(replayed.messages[0]).toMatchObject({
      type: "assistant",
      streaming: false,
      nextCreationOrder: 3,
    });
    expect(replayed.messages[0]?.blockIds).toHaveLength(3);
  });

  it("preserves optimistic user drafts while discarding and replaying diagnostics", () => {
    const before = reduceMessage(
      {
        ...makeTaskState(1, true, true),
        messages: [
          {
            id: "user-1",
            type: "user" as const,
            content: [{ type: "text" as const, text: "unreplayed input" }],
          },
          {
            id: "pending-1",
            type: "user" as const,
            content: [{ type: "text" as const, text: "optimistic input" }],
            ackState: 4 as const,
            nonce: "nonce-1",
            pending: true,
          },
        ],
      },
      asEvent({
        type: "cydo/task_diagnostic",
        severity: "error",
        subject: "Failed to load session history",
        body: "The session is unavailable.",
      }),
    );
    const preReloadDrafts = snapshotUserDrafts(before);
    const reset = resetTaskForHistoryReplay({ ...before, preReloadDrafts }, 1);
    const replayed = reduceMessage(
      reset,
      asEvent({
        type: "cydo/task_diagnostic",
        severity: "error",
        subject: "Failed to load session history",
        body: "The session is unavailable.",
      }),
    );

    expect(preReloadDrafts).toEqual([
      { text: "unreplayed input" },
      { text: "optimistic input" },
    ]);
    expect(reset.messages).toEqual([before.messages[1]]);
    expect(
      replayed.messages.filter((message) => message.type === "diagnostic"),
    ).toHaveLength(1);
    expect(
      replayed.messages.find((message) => message.type === "diagnostic"),
    ).not.toHaveProperty("nonce");
    expect(
      replayed.messages.find((message) => message.type === "diagnostic"),
    ).toMatchObject({
      diagnostic: {
        severity: "error",
        subject: "Failed to load session history",
      },
    });
    expect(reconcileInputDraft(replayed)).toBe("unreplayed input");
  });

  it("excludes only the repaired native UUID from a fresh draft snapshot", () => {
    const interruptionText = "[Request interrupted by user for tool use]";
    const before = {
      ...makeTaskState(1, true, true),
      messages: [
        {
          id: "interruption",
          type: "user" as const,
          uuid: "removed-u2",
          content: [{ type: "text" as const, text: interruptionText }],
        },
        {
          id: "real-steer",
          type: "user" as const,
          uuid: "real-u3",
          content: [{ type: "text" as const, text: interruptionText }],
        },
      ],
    };

    const preReloadDrafts = excludeReloadDraftUuid(
      snapshotUserDrafts(before),
      "removed-u2",
    );

    expect(preReloadDrafts).toEqual([
      { text: interruptionText, nativeUuid: "real-u3" },
    ]);
    expect(
      reconcileInputDraft({
        ...before,
        messages: [],
        preReloadDrafts,
      }),
    ).toBe(interruptionText);
  });

  it("filters a repaired UUID from an already-open reload snapshot", () => {
    const interruptionText = "[Request interrupted by user for tool use]";
    const before = {
      ...makeTaskState(1, true, true),
      pendingHistoryReplies: 1,
      preReloadDrafts: [
        { text: interruptionText, nativeUuid: "removed-u2" },
        { text: interruptionText, nativeUuid: "real-u3" },
        { text: "browser draft" },
      ],
    };

    const filtered = excludeReloadDraftUuid(
      before.preReloadDrafts,
      "removed-u2",
    );
    const reset = resetTaskForReload(before, filtered);

    expect(reset.pendingHistoryReplies).toBe(1);
    expect(reset.preReloadDrafts).toEqual([
      { text: interruptionText, nativeUuid: "real-u3" },
      { text: "browser draft" },
    ]);
  });

  it("keeps text-multiset draft recovery unchanged without an excluded UUID", () => {
    const duplicateText = "same user text";
    const before = {
      ...makeTaskState(1, true, true),
      messages: [
        {
          id: "first-duplicate",
          type: "user" as const,
          uuid: "first-u1",
          content: [{ type: "text" as const, text: duplicateText }],
        },
        {
          id: "second-duplicate",
          type: "user" as const,
          uuid: "second-u2",
          content: [{ type: "text" as const, text: duplicateText }],
        },
        {
          id: "other",
          type: "user" as const,
          uuid: "other-u3",
          content: [{ type: "text" as const, text: "other text" }],
        },
      ],
    };

    const preReloadDrafts = snapshotUserDrafts(before);
    const replayed = {
      ...before,
      messages: [
        {
          id: "replayed-duplicate",
          type: "user" as const,
          uuid: "first-u1",
          content: [{ type: "text" as const, text: duplicateText }],
        },
        {
          id: "replayed-other",
          type: "user" as const,
          uuid: "other-u3",
          content: [{ type: "text" as const, text: "other text" }],
        },
      ],
      preReloadDrafts,
    };

    expect(reconcileInputDraft(replayed)).toBe(duplicateText);
  });

  it("keeps live events that arrive after reload before its replay starts", () => {
    const reloaded = {
      ...makeTaskState(1, true, true),
      pendingHistoryReplies: 1,
      messages: [
        {
          id: "live-third",
          type: "assistant" as const,
          content: [{ type: "text" as const, text: "third-reply" }],
        },
      ],
    };

    const started = beginTaskHistoryReplay(reloaded, 4);

    expect(started.messages).toEqual(reloaded.messages);
    expect(started.historyLoaded).toBe(false);
    expect(started.historyTotal).toBe(4);
    expect(started.historyReceived).toBe(0);
  });

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
    expect(reset.agentName).toBe(before.agentName);
    expect(reset.driver).toBe(before.driver);
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
    expect(reset.replacementEvents.size).toBe(0);
    expect(reset.sessionInfo).toBeNull();
    expect(reset.totalCost).toBe(0);
    expect(reset.msgIdCounter).toBe(before.msgIdCounter);
    expect(reset.historyOperations).toBeNull();
    expect(reset.trackedFiles.size).toBe(0);
    expect(reset.blocks.size).toBe(0);
    expect(reset.itemIdMap.size).toBe(0);
    expect(reset.pendingCydoTaskItemIds).toEqual([]);
    expect(reset.spawnedTidsByItemId.size).toBe(0);
    expect(reset.historyTotal).toBe(12);
    expect(reset.historyReceived).toBe(0);
    expect(reset.historyLoaded).toBe(false);
  });

  it("preserves stable server metadata when task reload clears task state", () => {
    const before = makeRichState();
    const preReloadDrafts = [{ text: "draft captured before reload" }];
    const reset = resetTaskForReload(before, preReloadDrafts);

    expect(reset).toMatchObject({
      uuid: before.uuid,
      tid: before.tid,
      title: before.title,
      workspace: before.workspace,
      projectPath: before.projectPath,
      parentTid: before.parentTid,
      relationType: before.relationType,
      status: before.status,
      resumable: before.resumable,
      taskType: before.taskType,
      entryPoint: before.entryPoint,
      agentName: before.agentName,
      driver: before.driver,
      archived: before.archived,
      archiving: before.archiving,
      createdAt: before.createdAt,
      lastActive: before.lastActive,
      everLoaded: before.everLoaded,
      preReloadDrafts,
      pendingHistoryReplies: before.pendingHistoryReplies,
      undoResult: before.undoResult,
      alive: false,
      isProcessing: false,
      stdinClosed: false,
      needsAttention: false,
      hasPendingQuestion: false,
      canStop: false,
      historyLoaded: false,
      sessionInfo: null,
      sessionStatus: null,
      totalCost: 0,
    });
    expect(reset.messages).toEqual([]);
    expect(reset.replacementEvents.size).toBe(0);
    expect(reset.blocks.size).toBe(0);
    expect(reset.itemIdMap.size).toBe(0);
    expect(reset.trackedFiles.size).toBe(0);
  });

  it("rebuilds init and metadata session state during history replay", () => {
    const reset = resetTaskForHistoryReplay(makeRichState(), 2);
    const initialized = reduceMessage(
      reset,
      asEvent({
        type: "session/init",
        session_id: "replayed-sid",
        model: "codex-mini",
        cwd: "/tmp/replayed-project",
        tools: ["Read"],
        agent_version: "2.0.0",
        permission_mode: "default",
        agent: "codex",
        supports_file_revert: true,
      }),
    );
    const replayed = reduceMessage(
      initialized,
      asEvent({ type: "session/metadata", model: "codex-max" }),
    );

    expect(replayed.driver).toBe("codex");
    expect(replayed.sessionInfo).toMatchObject({
      sessionId: "replayed-sid",
      cwd: "/tmp/replayed-project",
      tools: ["Read"],
      version: "2.0.0",
      model: "codex-max",
    });
    expect(replayed.messages.map((message) => message.subtype)).toEqual([
      undefined,
      "init",
      "metadata",
    ]);
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
          isProvisional: true,
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
          isProvisional: true,
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
