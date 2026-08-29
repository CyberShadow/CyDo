import { describe, expect, it } from "vitest";
import {
  reduceMessage,
  reduceAgentAck,
  reduceCydoTaskSpawned,
  replaceHistoryBoundary,
} from "./sessionReducer";
import { makeTaskState, TaskState } from "./types";

function asEvent(event: object): Parameters<typeof reduceMessage>[1] {
  return event as Parameters<typeof reduceMessage>[1];
}

function makeState() {
  return {
    ...makeTaskState(1),
    sessionInfo: {
      model: "claude-sonnet",
      version: "1.0.0",
      sessionId: "sid-1",
      cwd: "/tmp/project",
      tools: [],
      permission_mode: "default",
      supports_file_revert: false,
    },
  };
}

describe("session/status reducer", () => {
  it("stores configured agent name separately from runtime driver on session/init", () => {
    const next = reduceMessage(makeState(), {
      type: "session/init",
      model: "codex-mini-latest",
      agent_version: "1.0.0",
      session_id: "sid-1",
      cwd: "/tmp/project",
      tools: [],
      permission_mode: "default",
      agent: "codex",
      agent_name: "work-codex",
      supports_file_revert: false,
    });

    expect(next.agentName).toBe("work-codex");
    expect(next.driver).toBe("codex");
    expect(next.sessionInfo?.agent_name).toBe("work-codex");
    expect(next.sessionInfo?.agent).toBe("codex");
  });

  it("updates transient status and permission mode without transcript messages", () => {
    const s = makeState();
    const next = reduceMessage(s, {
      type: "session/status",
      status: "requesting",
      permission_mode: "acceptEdits",
    });

    expect(next.sessionStatus).toBe("requesting");
    expect(next.sessionInfo?.permission_mode).toBe("acceptEdits");
    expect(next.messages).toHaveLength(0);
  });

  it("clears transient status for null/empty status payloads", () => {
    const s = { ...makeState(), sessionStatus: "compacting" };
    const next = reduceMessage(s, {
      type: "session/status",
      status: "",
      permission_mode: "acceptEdits",
    });

    expect(next.sessionStatus).toBeNull();
    expect(next.messages.some((m) => m.subtype === "status")).toBe(false);
    expect(next.sessionInfo?.permission_mode).toBe("acceptEdits");
  });

  it("preserves unknown status strings as transient UI text", () => {
    const s = makeState();
    const next = reduceMessage(s, {
      type: "session/status",
      status: "future_status_value",
    });

    expect(next.sessionStatus).toBe("future_status_value");
    expect(next.messages).toHaveLength(0);
  });

  it("clears transient status on turn/result and process/exit", () => {
    const s = { ...makeState(), sessionStatus: "requesting" };
    const afterResult = reduceMessage(s, {
      type: "turn/result",
      subtype: "success",
      is_error: false,
      num_turns: 1,
      duration_ms: 1,
      total_cost_usd: 0,
      usage: { input_tokens: 1, output_tokens: 1 },
    });

    expect(afterResult.sessionStatus).toBeNull();

    const afterExit = reduceMessage(
      { ...s, sessionStatus: "compacting" },
      {
        type: "process/exit",
        code: 0,
      },
    );
    expect(afterExit.sessionStatus).toBeNull();
  });
});

describe("task diagnostic reducer", () => {
  it("keeps an out-of-turn terminal diagnostic as a top-level message", () => {
    const state = {
      ...makeState(),
      messages: [
        {
          id: "pending-user",
          type: "user" as const,
          content: [{ type: "text" as const, text: "optimistic input" }],
          ackState: 4 as const,
          nonce: "nonce-1",
          pending: true,
        },
      ],
      msgIdCounter: 1,
    };
    const diagnostic = {
      type: "cydo/task_diagnostic" as const,
      severity: "error" as const,
      subject: "Failed to resume session",
      body: "**The session is unavailable.**",
    };

    const next = reduceMessage(state, diagnostic, 17, 123456);

    expect(next.messages).toHaveLength(2);
    expect(next.messages[1]).toMatchObject({
      id: "task-diagnostic-2",
      type: "diagnostic",
      diagnostic: {
        severity: "error",
        subject: diagnostic.subject,
      },
      rawSource: diagnostic,
      seq: 17,
      ts: 123456,
    });
    expect(next.messages[1]).not.toHaveProperty("cydoMeta");
    expect(next.messages[1]).not.toHaveProperty("nonce");
    expect(next.messages[1]).not.toHaveProperty("ackState");
    expect(next.messages[1]).not.toHaveProperty("pending");
    expect(next.messages[0]).toEqual(state.messages[0]);
    expect(next.messages.some((message) => message.type === "assistant")).toBe(
      false,
    );
  });

  it("inserts retry diagnostics into the active assistant turn in block order", () => {
    const started = reduceMessage(
      makeState(),
      asEvent({
        type: "item/started",
        item_id: "text-1",
        item_type: "text",
        text: "Before the retry.",
      }),
    );
    const diagnostic = {
      type: "cydo/task_diagnostic" as const,
      severity: "warning" as const,
      subject: "Agent error (retrying)",
      body: "API error: overloaded (attempt 1/3)",
    };

    const next = reduceMessage(started, diagnostic, 18, 123457);
    const assistant = next.messages[0]!;
    const block = next.blocks.get("diagnostic-2");

    expect(assistant).toMatchObject({
      type: "assistant",
      streaming: true,
      blockIds: ["streaming-1:text-1", "diagnostic-2"],
      nextCreationOrder: 2,
      rawSource: [
        expect.objectContaining({ type: "item/started" }),
        diagnostic,
      ],
      seq: 18,
    });
    expect(block).toMatchObject({
      itemId: "diagnostic-2",
      type: "diagnostic",
      text: diagnostic.body,
      severity: diagnostic.severity,
      subject: diagnostic.subject,
      completed: false,
      creationOrder: 1,
    });
  });
});

describe("session init and metadata reducers", () => {
  it("bootstraps session state from init, then applies metadata as a model update", () => {
    const init = {
      type: "session/init" as const,
      session_id: "sid-2",
      model: "codex-mini",
      cwd: "/tmp/replay-project",
      tools: ["Read", "Write"],
      agent_version: "2.0.0",
      permission_mode: "acceptEdits",
      agent: "codex",
      agent_name: "reviewer",
      supports_file_revert: true,
    };
    const initialized = reduceMessage(
      { ...makeTaskState(1), sessionStatus: "requesting" },
      init,
      10,
    );

    expect(initialized.driver).toBe("codex");
    expect(initialized.agentName).toBe("reviewer");
    expect(initialized.sessionStatus).toBeNull();
    expect(initialized.sessionInfo).toMatchObject({
      model: "codex-mini",
      version: "2.0.0",
      sessionId: "sid-2",
      cwd: "/tmp/replay-project",
      tools: ["Read", "Write"],
      permission_mode: "acceptEdits",
      agent: "codex",
      agent_name: "reviewer",
      supports_file_revert: true,
    });
    expect(initialized.messages).toEqual([
      expect.objectContaining({
        type: "system",
        subtype: "init",
        rawSource: init,
        seq: 10,
      }),
    ]);

    const metadata = { type: "session/metadata", model: "codex-max" };
    const updated = reduceMessage(initialized, asEvent(metadata), 11);

    expect(updated.sessionInfo).toMatchObject({
      ...initialized.sessionInfo,
      model: "codex-max",
    });
    expect(updated.messages).toHaveLength(2);
    expect(updated.messages[1]).toEqual(
      expect.objectContaining({
        type: "system",
        subtype: "metadata",
        rawSource: metadata,
        seq: 11,
      }),
    );

    const latest = reduceMessage(
      updated,
      asEvent({ type: "session/metadata", model: "codex-latest" }),
    );
    expect(latest.sessionInfo?.model).toBe("codex-latest");
    expect(latest.messages.filter((m) => m.subtype === "init")).toHaveLength(1);
    expect(
      latest.messages.filter((m) => m.subtype === "metadata"),
    ).toHaveLength(2);
  });

  it("rejects metadata received before session init", () => {
    expect(() =>
      reduceMessage(
        makeTaskState(1),
        asEvent({ type: "session/metadata", model: "codex-max" }),
      ),
    ).toThrow("session/metadata received before session/init");
  });
});

describe("history boundary replacement", () => {
  it("materializes an empty text user message for history boundary replacement", () => {
    const userMessage = {
      type: "item/started" as const,
      item_type: "user_message" as const,
      item_id: "empty-user",
      content: [{ type: "text" as const, text: "" }],
    };
    const materialized = reduceMessage(makeState(), userMessage, 4);

    expect(materialized.messages).toHaveLength(1);
    expect(materialized.messages[0]).toMatchObject({
      type: "user",
      content: [{ type: "text", text: "" }],
      rawSource: userMessage,
      seq: 4,
    });
    expect(materialized.messages[0]).not.toHaveProperty("pending");

    const replacement = {
      ...userMessage,
      history_boundary: { anchor: "empty-user", kind: "user" as const },
    };
    expect(
      replaceHistoryBoundary(
        materialized,
        replacement,
        4,
      ).replacementEvents.get(4),
    ).toEqual(replacement);
  });

  it("materializes missing user content for history boundary replacement", () => {
    const userMessage = {
      type: "item/started" as const,
      item_type: "user_message" as const,
      item_id: "empty-user",
      content: [],
    };
    const materialized = reduceMessage(makeState(), userMessage, 4);

    expect(materialized.messages).toHaveLength(1);
    expect(materialized.messages[0]).toMatchObject({
      type: "user",
      content: [{ type: "text", text: "" }],
      rawSource: userMessage,
      seq: 4,
    });

    const replacement = {
      ...userMessage,
      history_boundary: { anchor: "empty-user", kind: "user" as const },
    };
    expect(
      replaceHistoryBoundary(
        materialized,
        replacement,
        4,
      ).replacementEvents.get(4),
    ).toEqual(replacement);
  });

  it("replaces only the matching raw contribution", () => {
    const at4 = {
      type: "item/started",
      item_type: "user_message",
      item_id: "u",
    };
    const at5 = {
      type: "item/started",
      item_type: "user_message",
      item_id: "u2",
    };
    const state = {
      ...makeState(),
      messages: [
        {
          id: "u",
          type: "user" as const,
          content: [],
          seq: [4, 5],
          rawSource: [at4, at5],
        },
      ],
    };
    const replacement = {
      type: "item/started" as const,
      item_type: "user_message",
      item_id: "u",
      history_boundary: { anchor: "anchor", kind: "user" as const },
    };
    const next = replaceHistoryBoundary(state, replacement, 4);
    expect(next.messages).toBe(state.messages);
    expect(next.messages[0]?.rawSource).toBe(state.messages[0]?.rawSource);
    expect(next.replacementEvents.get(4)).toEqual(replacement);
  });

  it("rejects invalid replacement targets", () => {
    const state = makeState();
    expect(() =>
      replaceHistoryBoundary(
        state,
        {
          type: "turn/stop",
          history_boundary: { anchor: "a", kind: "agent_turn" },
        },
        4,
      ),
    ).toThrow("matched 0");
  });

  it("rejects mismatched canonical identity", () => {
    const state = {
      ...makeState(),
      messages: [
        {
          id: "u",
          type: "user" as const,
          content: [],
          seq: 4,
          rawSource: {
            type: "item/started",
            item_type: "user_message",
            item_id: "original",
          },
        },
      ],
    };
    expect(() =>
      replaceHistoryBoundary(
        state,
        {
          type: "item/started",
          item_type: "user_message",
          item_id: "different",
          history_boundary: { anchor: "a", kind: "user" },
        },
        4,
      ),
    ).toThrow("item identity");
  });

  it("accepts differing Codex item IDs for line boundaries", () => {
    const state = {
      ...makeState(),
      messages: [
        {
          id: "u",
          type: "user" as const,
          content: [],
          seq: 4,
          rawSource: {
            type: "item/started",
            item_type: "user_message",
            item_id: "codex-user-1",
          },
        },
      ],
    };
    const replacement = {
      type: "item/started" as const,
      item_type: "user_message",
      item_id: "codex-user-hist",
      history_boundary: { anchor: "line:12", kind: "user" as const },
    };
    expect(
      replaceHistoryBoundary(state, replacement, 4).replacementEvents.get(4),
    ).toEqual(replacement);
  });

  it("replaces an assistant turn without changing display state", () => {
    const raw = { type: "turn/stop", uuid: "turn" };
    const state = {
      ...makeState(),
      pendingHistoryReplies: 2,
      messages: [
        {
          id: "a",
          type: "assistant" as const,
          content: [{ type: "text", text: "answer" }],
          blockIds: ["b"],
          streaming: false,
          seq: 7,
          rawSource: raw,
        },
      ],
    };
    const replacement = {
      type: "turn/stop" as const,
      uuid: "turn",
      history_boundary: { anchor: "a", kind: "agent_turn" as const },
    };
    const next = replaceHistoryBoundary(state, replacement, 7);
    expect(next.messages).toHaveLength(1);
    expect(next.messages[0]?.content).toEqual(state.messages[0]?.content);
    expect(next.messages[0]?.blockIds).toEqual(["b"]);
    expect(next.pendingHistoryReplies).toBe(2);
  });
});

describe("live user echo reconciliation", () => {
  const prompt = "reconcile this replayed user message";
  const correlationId = "replay-correlation";
  const nativeUuid = "native-user-uuid";
  const replaySeq = 47;

  const replayUserEvent = {
    type: "item/started" as const,
    item_type: "user_message",
    item_id: "cc-user-msg",
    content: [{ type: "text" as const, text: prompt }],
    is_replay: true,
    uuid: nativeUuid,
  };
  const consumedEvent = {
    type: "user_message/consumed" as const,
    uuid: nativeUuid,
    native_uuid: nativeUuid,
    correlation_id: correlationId,
    consumed_as: "turn_start",
  };
  const firstAssistantItem = {
    type: "item/started" as const,
    item_type: "tool_use",
    item_id: "assistant-tool",
    name: "Bash",
  };

  function makeUnconfirmedState() {
    return {
      ...makeState(),
      messages: [
        {
          id: "opt-user",
          type: "user" as const,
          content: [{ type: "text" as const, text: prompt }],
          ackState: 3 as const,
          pending: true,
          nonce: correlationId,
          isProvisional: true,
        },
      ],
      msgIdCounter: 1,
    };
  }

  function userMessages(state: TaskState) {
    return state.messages.filter((message) => message.type === "user");
  }

  function expectPendingUser(state: TaskState) {
    expect(userMessages(state)).toEqual([
      expect.objectContaining({
        content: [{ type: "text", text: prompt }],
        ackState: 3,
        pending: true,
      }),
    ]);
  }

  function expectConfirmedUser(state: TaskState) {
    expect(userMessages(state)).toHaveLength(1);
    expect(userMessages(state)[0]?.ackState).toBeUndefined();
    expect(userMessages(state)[0]?.pending).toBeUndefined();
    expect(userMessages(state)[0]?.echoPending).toBeUndefined();
  }

  function expectCanonicalReplayUser(state: TaskState) {
    expect(userMessages(state)).toEqual([
      expect.objectContaining({
        content: [{ type: "text", text: prompt }],
        uuid: nativeUuid,
        seq: replaySeq,
        rawSource: replayUserEvent,
      }),
    ]);
  }

  it("keeps the replay-backed user message pending until a later confirmation", () => {
    let state: TaskState = makeUnconfirmedState();
    expectPendingUser(state);

    state = reduceMessage(state, replayUserEvent, replaySeq);
    expectPendingUser(state);
    expect(userMessages(state)[0]).toMatchObject({ echoPending: true });
    expectCanonicalReplayUser(state);

    state = reduceMessage(state, consumedEvent);
    expectConfirmedUser(state);
    expectCanonicalReplayUser(state);

    state = reduceMessage(state, firstAssistantItem, replaySeq + 1);
    expectConfirmedUser(state);
    expectCanonicalReplayUser(state);
  });

  it("keeps an early confirmation when its replayed user message arrives later", () => {
    let state: TaskState = makeUnconfirmedState();
    expectPendingUser(state);

    state = reduceMessage(state, consumedEvent);
    expectConfirmedUser(state);
    expect(userMessages(state)[0]).toMatchObject({
      isProvisional: true,
      expectedNativeUuid: nativeUuid,
    });

    state = reduceMessage(state, replayUserEvent, replaySeq);
    expectConfirmedUser(state);
    expectCanonicalReplayUser(state);
    expect(userMessages(state)[0]).not.toHaveProperty("isProvisional");

    state = reduceMessage(state, firstAssistantItem, replaySeq + 1);
    expectConfirmedUser(state);
    expectCanonicalReplayUser(state);
  });

  it("ends provisional identity after a steering confirmation without a replay", () => {
    let state: TaskState = makeUnconfirmedState();

    state = reduceMessage(state, {
      type: "user_message/consumed",
      uuid: "steering-user-uuid",
      correlation_id: correlationId,
      consumed_as: "steering",
    });

    expect(userMessages(state)[0]).toMatchObject({ isSteering: true });
    expect(userMessages(state)[0]?.isProvisional).toBeUndefined();
  });

  it("does not replace a terminal removed message with a later identical replay", () => {
    const firstNonce = "removed-first";
    const secondNonce = "replayed-second";
    const secondUuid = "native-second-uuid";
    const secondSeq = 48;
    const secondReplay = {
      type: "item/started" as const,
      item_type: "user_message",
      item_id: "cc-user-msg",
      content: [{ type: "text" as const, text: prompt }],
      is_replay: true,
      uuid: secondUuid,
    };

    let state: TaskState = {
      ...makeState(),
      messages: [
        {
          id: "opt-first",
          type: "user",
          content: [{ type: "text", text: prompt }],
          ackState: 3,
          pending: true,
          nonce: firstNonce,
          isProvisional: true,
        },
      ],
      msgIdCounter: 1,
    };

    state = reduceMessage(state, {
      type: "user_message/consumed",
      uuid: "removed-first-uuid",
      correlation_id: firstNonce,
      consumed_as: "removed",
    });
    expect(userMessages(state)[0]).toMatchObject({
      id: "opt-first",
      removed: true,
    });
    expect(userMessages(state)[0]?.isProvisional).toBeUndefined();

    state = {
      ...state,
      messages: [
        ...state.messages,
        {
          id: "opt-second",
          type: "user",
          content: [{ type: "text", text: prompt }],
          ackState: 3,
          pending: true,
          nonce: secondNonce,
          isProvisional: true,
        },
      ],
      msgIdCounter: 2,
    };

    state = reduceMessage(state, secondReplay, secondSeq);
    state = reduceMessage(state, {
      type: "user_message/consumed",
      uuid: secondUuid,
      native_uuid: secondUuid,
      correlation_id: secondNonce,
      consumed_as: "turn_start",
    });

    expect(userMessages(state)).toEqual([
      expect.objectContaining({
        id: "opt-first",
        removed: true,
      }),
      expect.objectContaining({
        uuid: secondUuid,
        seq: secondSeq,
        rawSource: secondReplay,
      }),
    ]);
    expect(userMessages(state)[0]?.isProvisional).toBeUndefined();
    expect(userMessages(state)[1]?.removed).toBeUndefined();
    expect(userMessages(state).some((message) => message.isProvisional)).toBe(
      false,
    );
  });

  it("keeps a confirmed echo non-pending when its agent acknowledgement arrives late", () => {
    const nonce = "steering-nonce";
    const placeholder = {
      ...makeState(),
      messages: [
        {
          id: "pending",
          type: "user" as const,
          content: [{ type: "text" as const, text: "steered-reply" }],
          ackState: 3 as const,
          pending: true,
          nonce,
        },
      ],
    };
    const echoed = reduceMessage(
      placeholder,
      asEvent({
        type: "item/started",
        item_type: "user_message",
        item_id: "native-user",
        content: [{ type: "text", text: "steered-reply" }],
        correlation_id: nonce,
      }),
    );
    const afterAck = reduceAgentAck(echoed, nonce);
    expect(afterAck).toBe(echoed);
    expect(afterAck.messages[0]).not.toHaveProperty("ackState");
  });

  it("replaces a nonce-less pending placeholder before boundary reconciliation", () => {
    const state = {
      ...makeState(),
      messages: [
        {
          id: "pending",
          type: "user" as const,
          content: [{ type: "text" as const, text: "live-three" }],
          ackState: 3 as const,
          pending: true,
          nonce: "local-nonce",
        },
      ],
    };
    const echo = {
      type: "item/started" as const,
      item_type: "user_message",
      item_id: "user-item",
      content: [{ type: "text" as const, text: "live-three" }],
    };
    const echoed = reduceMessage(state, echo, 12);
    expect(echoed.messages).toHaveLength(1);
    expect(echoed.messages[0]?.seq).toBe(12);
    expect(echoed.messages[0]?.nonce).toBe("local-nonce");
    expect(
      replaceHistoryBoundary(
        echoed,
        {
          ...echo,
          history_boundary: { anchor: "anchor", kind: "user" as const },
        },
        12,
      ).replacementEvents.get(12),
    ).toMatchObject({ history_boundary: { anchor: "anchor" } });
  });
});

describe("system event suppression", () => {
  it("ignores thinking_tokens system events without adding parse errors", () => {
    const s = makeState();
    const next = reduceMessage(
      s,
      asEvent({
        type: "system",
        subtype: "thinking_tokens",
        estimated_tokens: 5559,
        estimated_tokens_delta: 3594,
        uuid: "uuid-1",
        session_id: "sid-1",
      }),
    );

    expect(next).toBe(s);
    expect(next.messages).toHaveLength(0);
  });
});

describe("tracked file edits", () => {
  it("tracks codex fileChange markdown add events as full-content edits", () => {
    const state = {
      ...makeState(),
      agentName: "work-codex",
      driver: "codex",
    };
    const next = reduceMessage(
      state,
      asEvent({
        type: "item/started",
        item_type: "tool_use",
        item_id: "fc-1",
        name: "fileChange",
        input: {
          changes: [
            {
              path: "docs/new.md",
              kind: { type: "add" },
              diff: "# New markdown\n",
            },
          ],
        },
      }),
    );

    const tracked = next.trackedFiles.get("/tmp/project/docs/new.md");
    const blockKey = next.itemIdMap.get("fc-1");
    expect(tracked).toBeTruthy();
    expect(tracked?.edits).toHaveLength(1);
    expect(tracked?.edits[0]?.source).toBe("codex-fileChange");
    expect(tracked?.edits[0]?.status).toBe("pending");
    expect(next.blocks.get(blockKey!)?.driver).toBe("codex");
    expect(tracked?.edits[0]?.payload).toEqual({
      mode: "full_content",
      content: "# New markdown\n",
    });
  });

  it("tracks codex apply_patch markdown update events as patch-text edits", () => {
    const state = {
      ...makeState(),
      agentName: "work-codex",
      driver: "codex",
    };
    const next = reduceMessage(
      state,
      asEvent({
        type: "item/started",
        item_type: "tool_use",
        item_id: "ap-1",
        name: "apply_patch",
        input: {
          input: [
            "*** Begin Patch",
            "*** Update File: docs/readme.md",
            "@@ -1 +1 @@",
            "-old",
            "+new",
            "*** End Patch",
            "",
          ].join("\n"),
        },
      }),
    );

    const tracked = next.trackedFiles.get("/tmp/project/docs/readme.md");
    expect(tracked).toBeTruthy();
    expect(tracked?.edits).toHaveLength(1);
    expect(tracked?.edits[0]?.source).toBe("codex-apply_patch-history");
    expect(tracked?.edits[0]?.payload).toEqual({
      mode: "patch_text",
      patchText: "*** Update File: docs/readme.md\n@@ -1 +1 @@\n-old\n+new",
    });
  });

  it("keeps claude Write tracking behavior", () => {
    const started = reduceMessage(
      { ...makeState(), agentName: "work-claude", driver: "claude" },
      asEvent({
        type: "item/started",
        item_type: "tool_use",
        item_id: "write-1",
        name: "Write",
        input: {
          file_path: "/tmp/project/notes.md",
          content: "# Hello",
        },
      }),
    );

    const next = reduceMessage(
      started,
      asEvent({
        type: "item/result",
        item_id: "write-1",
        content: [{ type: "text", text: "ok" }],
        is_error: false,
      }),
    );

    const tracked = next.trackedFiles.get("/tmp/project/notes.md");
    expect(tracked).toBeTruthy();
    expect(tracked?.edits).toHaveLength(1);
    expect(tracked?.edits[0]?.source).toBe("claude-tool");
    expect(tracked?.edits[0]?.status).toBe("applied");
    expect(tracked?.edits[0]?.payload).toEqual({
      mode: "full_content",
      content: "# Hello",
    });
  });
});

describe("thinking block rendering state", () => {
  // These tests verify that an item/started event with item_type:"thinking"
  // and no text produces a block with text:"". The component renders
  // .thinking-dots (not an empty Markdown box) when block.text.trim() === "".

  it("item/started with thinking type and no text creates block with empty text", () => {
    const s = makeState();
    const afterStarted = reduceMessage(
      s,
      asEvent({
        type: "item/started",
        item_id: "think-1",
        item_type: "thinking",
      }),
    );

    const blockKey = afterStarted.itemIdMap.get("think-1");
    expect(blockKey).toBeTruthy();
    const block = afterStarted.blocks.get(blockKey!);
    expect(block).toBeTruthy();
    expect(block?.type).toBe("thinking");
    expect(block?.text).toBe("");
    expect(block?.completed).toBe(false);
  });

  it("turn/stop marks empty thinking block as completed with text still empty", () => {
    const s = makeState();
    const afterStarted = reduceMessage(
      s,
      asEvent({
        type: "item/started",
        item_id: "think-1",
        item_type: "thinking",
      }),
    );
    const afterStop = reduceMessage(
      afterStarted,
      asEvent({ type: "turn/stop" }),
    );

    const blockKey = afterStop.itemIdMap.get("think-1");
    const block = afterStop.blocks.get(blockKey!);
    expect(block?.completed).toBe(true);
    expect(block?.text).toBe("");
  });
});

describe("task diagnostic streaming sequence", () => {
  it("continues the same assistant message after a diagnostic and completes every block", () => {
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

    const next = events.reduce<TaskState>(
      (state, event) => reduceMessage(state, asEvent(event)),
      makeState(),
    );
    const assistant = next.messages[0]!;

    expect(next.messages).toHaveLength(1);
    expect(assistant).toMatchObject({
      type: "assistant",
      streaming: false,
      blockIds: ["streaming-1:text-1", "diagnostic-2", "streaming-1:text-2"],
      nextCreationOrder: 3,
    });
    expect(next.blocks.get("streaming-1:text-1")).toMatchObject({
      text: "First output",
      completed: true,
      creationOrder: 0,
    });
    expect(next.blocks.get("diagnostic-2")).toMatchObject({
      type: "diagnostic",
      completed: true,
      creationOrder: 1,
    });
    expect(next.blocks.get("streaming-1:text-2")).toMatchObject({
      text: "Second output",
      completed: true,
      creationOrder: 2,
    });
  });
});

describe("item/started idempotency", () => {
  it("does not duplicate or overwrite an existing block on duplicate item/started", () => {
    let s: TaskState = makeState();
    s = reduceMessage(
      s,
      asEvent({
        type: "item/started",
        item_id: "cp-text-0",
        item_type: "text",
      }),
      1,
    );
    s = reduceMessage(
      s,
      asEvent({
        type: "item/delta",
        item_id: "cp-text-0",
        delta_type: "text_delta",
        content: "pre-tool-visible-text",
      }),
    );

    const next = reduceMessage(
      s,
      asEvent({
        type: "item/started",
        item_id: "cp-text-0",
        item_type: "text",
      }),
      2,
    );

    const msg = next.messages[0]!;
    const blockKey = next.itemIdMap.get("cp-text-0");

    expect(blockKey).toBeTruthy();
    expect(msg.blockIds).toEqual([blockKey]);
    expect(next.blocks.get(blockKey!)?.text).toBe("pre-tool-visible-text");
    expect(Array.isArray(msg.rawSource)).toBe(true);
    expect(msg.rawSource).toHaveLength(2);
  });
});

describe("cydo/task_spawned reducer", () => {
  it("pushes to pendingCydoTaskItemIds on cydo:Task item/started", () => {
    const s = makeState();
    const next = reduceMessage(
      s,
      asEvent({
        type: "item/started",
        item_type: "tool_use",
        item_id: "t1",
        name: "Task",
        tool_server: "cydo",
      }),
    );
    expect(next.pendingCydoTaskItemIds).toEqual(["t1"]);
  });

  it("does not push for non-cydo tools", () => {
    const s = makeState();
    const next = reduceMessage(
      s,
      asEvent({
        type: "item/started",
        item_type: "tool_use",
        item_id: "b1",
        name: "Bash",
      }),
    );
    expect(next.pendingCydoTaskItemIds).toEqual([]);
  });

  it("attaches spawn event to front-of-FIFO item", () => {
    const s = makeState();
    const afterPush = reduceMessage(
      s,
      asEvent({
        type: "item/started",
        item_type: "tool_use",
        item_id: "t1",
        name: "Task",
        tool_server: "cydo",
      }),
    );
    const afterSpawn = reduceCydoTaskSpawned(afterPush, {
      type: "cydo/task_spawned",
      child_tid: 42,
      spec_index: 0,
    });
    expect(afterSpawn.spawnedTidsByItemId.get("t1")?.get(0)).toBe(42);
  });

  it("handles multi-spec single call", () => {
    const s = makeState();
    const afterPush = reduceMessage(
      s,
      asEvent({
        type: "item/started",
        item_type: "tool_use",
        item_id: "t1",
        name: "Task",
        tool_server: "cydo",
      }),
    );
    const afterSpawn0 = reduceCydoTaskSpawned(afterPush, {
      type: "cydo/task_spawned",
      child_tid: 42,
      spec_index: 0,
    });
    const afterSpawn1 = reduceCydoTaskSpawned(afterSpawn0, {
      type: "cydo/task_spawned",
      child_tid: 43,
      spec_index: 1,
    });
    expect(afterSpawn1.spawnedTidsByItemId.get("t1")?.get(0)).toBe(42);
    expect(afterSpawn1.spawnedTidsByItemId.get("t1")?.get(1)).toBe(43);
  });

  it("handles two sequential cydo:Task calls correctly", () => {
    let s: TaskState = makeState();
    // Push t1, spawn for t1, item/result for t1 (pop t1)
    s = reduceMessage(
      s,
      asEvent({
        type: "item/started",
        item_type: "tool_use",
        item_id: "t1",
        name: "Task",
        tool_server: "cydo",
      }),
    );
    s = reduceCydoTaskSpawned(s, {
      type: "cydo/task_spawned",
      child_tid: 10,
      spec_index: 0,
    });
    s = reduceMessage(
      s,
      asEvent({
        type: "item/result",
        item_id: "t1",
        content: [],
        is_error: false,
      }),
    );
    expect(s.pendingCydoTaskItemIds).toEqual([]);

    // Push t2, spawn for t2
    s = reduceMessage(
      s,
      asEvent({
        type: "item/started",
        item_type: "tool_use",
        item_id: "t2",
        name: "Task",
        tool_server: "cydo",
      }),
    );
    s = reduceCydoTaskSpawned(s, {
      type: "cydo/task_spawned",
      child_tid: 20,
      spec_index: 0,
    });
    expect(s.spawnedTidsByItemId.get("t2")?.get(0)).toBe(20);
    // t1 entry is unaffected
    expect(s.spawnedTidsByItemId.get("t1")?.get(0)).toBe(10);
  });

  it("drops spawn silently when no in-flight cydo:Task", () => {
    const s = makeState();
    const next = reduceCydoTaskSpawned(s, {
      type: "cydo/task_spawned",
      child_tid: 99,
      spec_index: 0,
    });
    expect(next).toBe(s);
    expect(next.spawnedTidsByItemId.size).toBe(0);
  });

  it("pops by item_id not blind shift (parallel case)", () => {
    let s: TaskState = makeState();
    // Push t1 then t2
    s = reduceMessage(
      s,
      asEvent({
        type: "item/started",
        item_type: "tool_use",
        item_id: "t1",
        name: "Task",
        tool_server: "cydo",
      }),
    );
    s = reduceMessage(
      s,
      asEvent({
        type: "item/started",
        item_type: "tool_use",
        item_id: "t2",
        name: "Task",
        tool_server: "cydo",
      }),
    );
    expect(s.pendingCydoTaskItemIds).toEqual(["t1", "t2"]);

    // item/result for t2 removes only t2
    s = reduceMessage(
      s,
      asEvent({
        type: "item/result",
        item_id: "t2",
        content: [],
        is_error: false,
      }),
    );
    expect(s.pendingCydoTaskItemIds).toEqual(["t1"]);
  });

  it("replay sequence item/started → item/completed → cydo/task_spawned → item/result", () => {
    let s: TaskState = makeState();
    s = reduceMessage(
      s,
      asEvent({
        type: "item/started",
        item_type: "tool_use",
        item_id: "t1",
        name: "Task",
        tool_server: "cydo",
      }),
    );
    s = reduceMessage(
      s,
      asEvent({ type: "item/completed", item_id: "t1", is_error: false }),
    );
    s = reduceCydoTaskSpawned(s, {
      type: "cydo/task_spawned",
      child_tid: 77,
      spec_index: 0,
    });
    s = reduceMessage(
      s,
      asEvent({
        type: "item/result",
        item_id: "t1",
        content: [],
        is_error: false,
      }),
    );
    expect(s.spawnedTidsByItemId.get("t1")?.get(0)).toBe(77);
    expect(s.pendingCydoTaskItemIds).toEqual([]);
  });
});

describe("mid-turn absorption", () => {
  const consumed = (event: {
    uuid: string;
    consumed_as: string;
    native_uuid?: string;
  }) => asEvent({ type: "user_message/consumed", ...event });

  it("hands a queued provisional over to the mid-turn delivery", () => {
    // the enqueue-emitted provisional sits in the agent's queue; the mid-turn
    // delivery confirms it and hands over to the canonical message
    let state = reduceMessage(
      makeState(),
      asEvent({
        type: "item/started",
        item_id: "synthetic-user",
        item_type: "user_message",
        uuid: "enqueue-3",
        pending: true,
        content: [{ type: "text", text: "sent while busy" }],
      }),
    );
    expect(state.messages).toHaveLength(1);
    expect(state.messages[0]?.removed).toBeUndefined();

    state = reduceMessage(
      state,
      consumed({
        uuid: "enqueue-3",
        native_uuid: "native-9",
        consumed_as: "steering",
      }),
    );
    // the canonical message follows, so the provisional is gone entirely
    expect(state.messages.filter((m) => m.type === "user")).toHaveLength(0);

    state = reduceMessage(
      state,
      asEvent({
        type: "item/started",
        item_id: "cc-queued-command",
        item_type: "user_message",
        uuid: "native-9",
        content: [{ type: "text", text: "sent while busy" }],
      }),
    );
    const users = state.messages.filter((m) => m.type === "user");
    expect(users).toHaveLength(1);
    expect(users[0]?.uuid).toBe("native-9");
    expect(users[0]?.removed).toBeUndefined();
  });

  it("keeps the not-delivered badge for a queue clear", () => {
    let state = reduceMessage(
      makeState(),
      asEvent({
        type: "item/started",
        item_id: "synthetic-user",
        item_type: "user_message",
        uuid: "enqueue-5",
        pending: true,
        content: [{ type: "text", text: "never sent" }],
      }),
    );
    // no delivery record: the confirmation carries no native uuid
    state = reduceMessage(
      state,
      consumed({ uuid: "enqueue-5", consumed_as: "removed" }),
    );
    const users = state.messages.filter((m) => m.type === "user");
    expect(users).toHaveLength(1);
    expect(users[0]?.removed).toBe(true);
  });
});
