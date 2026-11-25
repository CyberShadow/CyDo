import { describe, expect, it } from "vitest";
import {
  reduceMessage,
  reduceAgentAck,
  replaceHistoryBoundary,
  rejectOrdinarySubmission,
} from "./sessionReducer";
import { makeTaskState, TaskState } from "./types";
import bashEditDiff from "./testFixtures/claude-bash-edit-diff.json";

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

describe("agent notices and command output", () => {
  const notice = {
    type: "agent/notice",
    severity: "error",
    subject: "SessionStart:startup failed (exit code 1)",
    body: "",
    stdout: "probe-hook-output",
    stderr: "probe-hook-error",
    output: "additional hook diagnostic",
    collapsible: true,
  } as const;

  const hookOutput = {
    stdout: "probe-hook-output",
    stderr: "probe-hook-error",
    output: "additional hook diagnostic",
  };

  it("keeps each hook stream on a standalone diagnostic", () => {
    const next = reduceMessage(makeState(), notice, 17, 123456);

    expect(next.messages).toHaveLength(1);
    expect(next.messages[0]).toMatchObject({
      type: "diagnostic",
      diagnostic: {
        severity: notice.severity,
        subject: notice.subject,
        hookOutput,
      },
      content: [{ type: "text", text: "" }],
      seq: 17,
      ts: 123456,
    });
  });

  it("adds each hook stream to the active assistant turn in transcript order", () => {
    const started = reduceMessage(
      makeState(),
      asEvent({
        type: "item/started",
        item_id: "text-1",
        item_type: "text",
        text: "Before the hook.",
      }),
    );
    const next = reduceMessage(started, notice);

    expect(next.messages).toHaveLength(1);
    const assistant = next.messages[0]!;
    expect(assistant).toMatchObject({ type: "assistant", streaming: true });
    const blocks = assistant.blockIds!.map((id) => next.blocks.get(id));
    expect(blocks).toMatchObject([
      { type: "text", text: "Before the hook." },
      {
        type: "diagnostic",
        severity: notice.severity,
        subject: notice.subject,
        text: "",
        hookOutput,
      },
    ]);
  });

  it("shows local command output as completed assistant text immediately", () => {
    const text = "Estimated cost:        $0.0000\nTotal duration (API):  0s";
    const next = reduceMessage(
      makeState(),
      { type: "agent/command_output", text },
      18,
      123457,
    );

    expect(next.messages).toHaveLength(1);
    const message = next.messages[0]!;
    expect(message).toMatchObject({ type: "assistant", seq: 18, ts: 123457 });
    expect(message.streaming).toBeFalsy();
    expect(message.blockIds).toHaveLength(1);
    expect(next.blocks.get(message.blockIds![0]!)).toMatchObject({
      type: "command_output",
      text,
      completed: true,
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

  it("rejects differing user item IDs for line boundaries", () => {
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
    const replacement = {
      type: "item/started" as const,
      item_type: "user_message",
      item_id: "different",
      history_boundary: { anchor: "line:12", kind: "user" as const },
    };
    expect(() => replaceHistoryBoundary(state, replacement, 4)).toThrow(
      "item identity",
    );
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
        id: "opt-user",
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

  it("keeps the displaced row's id when the replay itself is pending", () => {
    const state = makeUnconfirmedState();
    const echoed = reduceMessage(
      state,
      { ...replayUserEvent, pending: true },
      replaySeq,
    );
    expect(echoed.messages).toHaveLength(1);
    expect(echoed.messages[0]).toMatchObject({
      id: "opt-user",
      pending: true,
      uuid: nativeUuid,
      seq: replaySeq,
    });
  });

  it("allocates a fresh id when no placeholder matches the echo", () => {
    const state = makeUnconfirmedState();
    const placeholder = state.messages[0];
    const echoed = reduceMessage(
      state,
      asEvent({
        ...replayUserEvent,
        is_replay: false,
        correlation_id: "another-client",
      }),
      replaySeq,
    );
    expect(echoed.messages).toHaveLength(2);
    expect(echoed.messages[0]).toBe(placeholder);
    expect(echoed.messages[1]?.id).toBe("user-echo-2");
  });

  it.each([
    { scenario: "one removed row", otherContent: undefined, id: "opt-user" },
    {
      scenario: "multiple removed rows",
      otherContent: "other",
      id: "user-echo-2",
    },
  ])(
    "uses $id in the nonce-less fallback with $scenario",
    ({ otherContent, id }) => {
      const state = makeUnconfirmedState();
      const first = { ...state.messages[0]!, nonce: undefined };
      const messages = [first];
      if (otherContent !== undefined) {
        messages.push({
          ...first,
          id: "opt-other",
          content: [{ type: "text", text: otherContent }],
        });
      }
      const content = [{ type: "text" as const, text: "different content" }];
      const echoed = reduceMessage(
        { ...state, messages },
        { ...replayUserEvent, is_replay: false, content },
        replaySeq,
      );
      expect(echoed.messages).toHaveLength(1);
      expect(echoed.messages[0]).toMatchObject({
        id,
        uuid: nativeUuid,
        content,
      });
    },
  );

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

  it("drops a cancelled message's bubble", () => {
    let state: TaskState = makeUnconfirmedState();
    expect(userMessages(state)).toHaveLength(1);

    state = reduceMessage(state, {
      type: "user_message/consumed",
      uuid: "enqueue-12",
      correlation_id: correlationId,
      consumed_as: "cancelled",
    });

    expect(userMessages(state)).toEqual([]);
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
    expect(echoed.messages[0]?.id).toBe("pending");
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

  it("keeps multipart canonical echo blocks when replacing a pending placeholder", () => {
    const state = {
      ...makeState(),
      messages: [
        {
          id: "pending",
          type: "user" as const,
          content: [{ type: "text" as const, text: "firstsecond" }],
          ackState: 3 as const,
          pending: true,
        },
      ],
    };
    const content = [
      { type: "text" as const, text: "first" },
      { type: "text" as const, text: "second" },
    ];

    const next = reduceMessage(state, {
      type: "item/started",
      item_type: "user_message",
      item_id: "native-user",
      content,
    });

    expect(next.messages).toHaveLength(1);
    expect(next.messages[0]?.content).toEqual(content);
  });
});

describe("user echo meta kinds", () => {
  const echo = {
    type: "item/started" as const,
    item_type: "user_message",
    item_id: "native-user",
    content: [{ type: "text" as const, text: "harness context" }],
    is_meta: true,
  };

  it.each([false, true])("preserves meta kinds with pending=%s", (pending) => {
    const event = {
      ...echo,
      pending,
      meta_kinds: ["plugins.recommendations", "agents_md.instructions"],
    };

    const next = reduceMessage(makeState(), event);

    expect(next.messages).toEqual([
      expect.objectContaining({
        type: "user",
        isMeta: true,
        metaKinds: event.meta_kinds,
      }),
    ]);
  });

  it("leaves meta kinds undefined when the event omits them", () => {
    const next = reduceMessage(makeState(), echo);

    expect(next.messages).toHaveLength(1);
    expect(next.messages[0]?.metaKinds).toBeUndefined();
  });
});

describe("rejectOrdinarySubmission", () => {
  it("removes only the provisional user message with the rejected nonce", () => {
    const rejected = {
      id: "rejected",
      type: "user" as const,
      content: [{ type: "text" as const, text: "same text" }],
      nonce: "rejected-nonce",
      isProvisional: true,
      pending: true,
    };
    const confirmed = {
      ...rejected,
      id: "confirmed",
      isProvisional: false,
      pending: false,
    };
    const otherPending = {
      ...rejected,
      id: "other-pending",
      nonce: "other-nonce",
    };
    const task = {
      ...makeState(),
      messages: [confirmed, rejected, otherPending],
    };

    const next = rejectOrdinarySubmission(task, "rejected-nonce");

    expect(next.messages).toEqual([confirmed, otherPending]);
  });
});

describe("queue history reducer", () => {
  it("replaces a provisional enqueue bubble with its canonical text and image echo", () => {
    const image = {
      type: "image" as const,
      data: "base64-image-data",
      media_type: "image/png",
    };
    const provisional = {
      ...makeState(),
      messages: [
        {
          id: "queued-user",
          type: "user" as const,
          content: [
            { type: "text" as const, text: "describe this image" },
            image,
          ],
          uuid: "enqueue-42",
          ackState: 3 as const,
          pending: true,
          isProvisional: true,
        },
      ],
      msgIdCounter: 1,
    };
    const canonicalEcho = {
      type: "item/started" as const,
      item_type: "user_message",
      item_id: "native-item",
      uuid: "native-user",
      content: [{ type: "text" as const, text: "describe this image" }, image],
    };

    const confirmed = reduceMessage(provisional, {
      type: "user_message/consumed",
      uuid: "enqueue-42",
      native_uuid: "native-user",
      consumed_as: "turn_start",
    });
    const next = reduceMessage(confirmed, canonicalEcho, 43);

    expect(next.messages).toEqual([
      expect.objectContaining({
        uuid: "native-user",
        content: canonicalEcho.content,
        seq: 43,
      }),
    ]);
    expect(next.messages[0]).not.toHaveProperty("isProvisional");
    expect(next.messages[0]).not.toHaveProperty("pending");
  });
});

describe("tracked file edits", () => {
  it("tracks relative and absolute spellings of a file under one normalized path", () => {
    const initial = makeState();
    let state: TaskState = {
      ...initial,
      driver: "claude",
      sessionInfo: { ...initial.sessionInfo, cwd: "/w" },
    };
    for (const [id, path] of [
      ["relative", "./docs/x.md"],
      ["absolute", "/w//docs/../docs/x.md"],
    ] as const) {
      state = reduceMessage(state, {
        type: "item/started",
        item_type: "tool_use",
        item_id: id,
        name: "Write",
        input: { file_path: path, content: id },
      });
      state = reduceMessage(state, {
        type: "item/result",
        item_id: id,
        content: [],
      });
    }

    const path = "/w/docs/x.md";
    expect([...state.trackedFiles.keys()]).toEqual([path]);
    expect(
      state.trackedFiles.get(path)?.edits.map((edit) => edit.filePath),
    ).toEqual([path, path]);
  });

  it("tracks every included Claude Bash edit-diff hunk at result time", () => {
    const started = reduceMessage(
      { ...makeState(), driver: "claude" },
      asEvent({
        type: "item/started",
        item_type: "tool_use",
        item_id: "bash-edit-diff-1",
        name: "Bash",
        input: { command: "git diff" },
      }),
    );

    const next = reduceMessage(
      started,
      asEvent({
        type: "item/result",
        item_id: "bash-edit-diff-1",
        content: [{ type: "text", text: "done" }],
        is_error: false,
        tool_result: { bashEditDiff },
      }),
    );

    const impexp = next.trackedFiles.get("/workspace/source/btdu/impexp.d");
    const paths = next.trackedFiles.get("/workspace/source/btdu/paths.d");

    expect(impexp?.edits).toEqual([
      {
        toolUseId: "bash-edit-diff-1",
        messageId: "streaming-1",
        filePath: "/workspace/source/btdu/impexp.d",
        type: "edit",
        op: "update",
        status: "applied",
        source: "claude-bashEditDiff",
        changeIndex: 0,
        turnId: undefined,
        payload: { mode: "hunks", hunks: bashEditDiff.files[0]!.hunks },
      },
    ]);
    expect(paths?.edits).toEqual([
      {
        toolUseId: "bash-edit-diff-1",
        messageId: "streaming-1",
        filePath: "/workspace/source/btdu/paths.d",
        type: "edit",
        op: "update",
        status: "applied",
        source: "claude-bashEditDiff",
        changeIndex: 1,
        turnId: undefined,
        payload: { mode: "hunks", hunks: bashEditDiff.files[1]!.hunks },
      },
    ]);

    const duplicate = reduceMessage(
      next,
      asEvent({
        type: "item/result",
        item_id: "bash-edit-diff-1",
        content: [{ type: "text", text: "done" }],
        is_error: false,
        tool_result: { bashEditDiff },
      }),
    );
    expect(
      duplicate.trackedFiles.get("/workspace/source/btdu/impexp.d")?.edits,
    ).toHaveLength(1);
    expect(
      duplicate.trackedFiles.get("/workspace/source/btdu/paths.d")?.edits,
    ).toHaveLength(1);
  });

  it("tracks only included non-skipped Bash sidecar files", () => {
    const start = (state: TaskState, id: string) =>
      reduceMessage(
        state,
        asEvent({
          type: "item/started",
          item_type: "tool_use",
          item_id: id,
          name: "Bash",
          input: { command: "true" },
        }),
      );
    const result = (
      state: TaskState,
      id: string,
      sidecar: unknown,
      error = false,
    ) =>
      reduceMessage(
        state,
        asEvent({
          type: "item/result",
          item_id: id,
          content: [],
          is_error: error,
          tool_result: sidecar === undefined ? {} : { bashEditDiff: sidecar },
        }),
      );
    const hunk = {
      oldStart: 1,
      oldLines: 1,
      newStart: 1,
      newLines: 1,
      lines: ["-a", "+b"],
    };
    let state: TaskState = { ...makeState(), driver: "claude" };
    state = result(start(state, "created"), "created", {
      files: [{ filePath: "/created", hunks: [hunk], created: true }],
      moreFiles: 0,
    });
    state = result(start(state, "deleted"), "deleted", {
      files: [{ filePath: "/deleted", hunks: [hunk], deleted: true }],
      moreFiles: 0,
    });
    state = result(start(state, "shared"), "shared", {
      files: [{ filePath: "/shared", hunks: [] }],
      moreFiles: 0,
      shared: true,
    });
    state = result(start(state, "available"), "available", {
      files: [{ filePath: "/available", hunks: [hunk] }],
      moreFiles: 0,
      unavailable: true,
    });
    state = result(start(state, "changed-only"), "changed-only", {
      files: [],
      moreFiles: 1,
      changedFiles: ["/changed-only"],
    });
    state = result(start(state, "skipped"), "skipped", {
      files: [{ filePath: "/skipped", hunks: [hunk] }],
      moreFiles: 0,
      skipped: true,
    });
    state = result(start(state, "empty"), "empty", {
      files: [],
      moreFiles: 0,
      unavailable: true,
    });
    state = result(
      start(state, "error"),
      "error",
      { files: [{ filePath: "/error", hunks: [hunk] }], moreFiles: 0 },
      true,
    );

    expect(state.trackedFiles.get("/created")?.edits[0]?.op).toBe("add");
    expect(state.trackedFiles.get("/deleted")?.edits[0]?.op).toBe("delete");
    expect(state.trackedFiles.get("/shared")?.edits[0]?.payload).toEqual({
      mode: "hunks",
      hunks: [],
    });
    expect(state.trackedFiles.get("/available")?.edits).toHaveLength(1);
    for (const path of ["/changed-only", "/skipped", "/empty", "/error"]) {
      expect(state.trackedFiles.has(path)).toBe(false);
    }
  });

  it("leaves tracked files unchanged when a Bash result has no sidecar", () => {
    const started = reduceMessage(
      { ...makeState(), driver: "claude" },
      asEvent({
        type: "item/started",
        item_type: "tool_use",
        item_id: "bash-without-sidecar",
        name: "Bash",
        input: { command: "true" },
      }),
    );
    const next = reduceMessage(
      started,
      asEvent({
        type: "item/result",
        item_id: "bash-without-sidecar",
        content: [],
        is_error: false,
        tool_result: {},
      }),
    );

    expect(next.trackedFiles).toEqual(started.trackedFiles);
    expect(next.trackedFiles.has("/empty")).toBe(false);
  });

  it("appends Bash edits after existing Claude Write and Edit records", () => {
    const target = "/tmp/project/ordered.txt";
    const start = (state: TaskState, id: string, name: string, input: object) =>
      reduceMessage(
        state,
        asEvent({
          type: "item/started",
          item_type: "tool_use",
          item_id: id,
          name,
          input,
        }),
      );
    const result = (state: TaskState, id: string, tool_result?: object) =>
      reduceMessage(
        state,
        asEvent({
          type: "item/result",
          item_id: id,
          content: [],
          is_error: false,
          tool_result,
        }),
      );
    let state: TaskState = { ...makeState(), driver: "claude" };
    state = result(
      start(state, "write", "Write", { file_path: target, content: "a\n" }),
      "write",
    );
    state = result(
      start(state, "edit", "Edit", {
        file_path: target,
        old_string: "a",
        new_string: "b",
      }),
      "edit",
    );
    state = result(start(state, "bash", "Bash", { command: "true" }), "bash", {
      bashEditDiff: {
        files: [
          {
            filePath: target,
            hunks: [
              {
                oldStart: 1,
                oldLines: 1,
                newStart: 1,
                newLines: 1,
                lines: ["-b", "+c"],
              },
            ],
          },
        ],
        moreFiles: 0,
      },
    });

    expect(state.trackedFiles.get(target)?.edits).toEqual([
      expect.objectContaining({
        source: "claude-tool",
        status: "applied",
        payload: { mode: "full_content", content: "a\n" },
      }),
      expect.objectContaining({
        source: "claude-tool",
        status: "applied",
        payload: { mode: "none" },
      }),
      expect.objectContaining({
        source: "claude-bashEditDiff",
        status: "applied",
        changeIndex: 0,
        payload: {
          mode: "hunks",
          hunks: [
            {
              oldStart: 1,
              oldLines: 1,
              newStart: 1,
              newLines: 1,
              lines: ["-b", "+c"],
            },
          ],
        },
      }),
    ]);
  });

  it("does not silently accept malformed Bash sidecars", () => {
    const started = reduceMessage(
      { ...makeState(), driver: "claude" },
      asEvent({
        type: "item/started",
        item_type: "tool_use",
        item_id: "bad",
        name: "Bash",
        input: {},
      }),
    );
    const deliver = (bashEditDiff: unknown) =>
      reduceMessage(
        started,
        asEvent({
          type: "item/result",
          item_id: "bad",
          content: [],
          is_error: false,
          tool_result: { bashEditDiff },
        }),
      );
    expect(() => deliver({ files: "bad", moreFiles: 0 })).toThrow();
  });

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

describe("cydo/item_enriched reducer", () => {
  function startAnswer(s: TaskState, itemId: string) {
    return reduceMessage(s, {
      type: "item/started",
      item_type: "tool_use",
      item_id: itemId,
      name: "Answer",
      tool_server: "cydo",
    });
  }

  it("records the target of a pending tool call", () => {
    const before = startAnswer(makeState(), "answer");
    const after = reduceMessage(before, {
      type: "cydo/item_enriched",
      item_id: "answer",
      target_tid: 7,
    });

    expect(after.itemEnrichments.get(after.itemIdMap.get("answer")!)).toEqual({
      targetTid: 7,
    });
    expect(before.itemEnrichments.has(before.itemIdMap.get("answer")!)).toBe(
      false,
    );
  });

  it("attaches targets to two pending Answers in reverse start order", () => {
    let s = startAnswer(startAnswer(makeState(), "first"), "second");
    s = reduceMessage(s, {
      type: "cydo/item_enriched",
      item_id: "second",
      target_tid: 8,
    });
    expect(s.itemEnrichments.has(s.itemIdMap.get("first")!)).toBe(false);
    s = reduceMessage(s, {
      type: "cydo/item_enriched",
      item_id: "first",
      target_tid: 7,
    });
    expect(s.itemEnrichments.get(s.itemIdMap.get("first")!)?.targetTid).toBe(7);
    expect(s.itemEnrichments.get(s.itemIdMap.get("second")!)?.targetTid).toBe(
      8,
    );
  });

  it("retains separate enrichments when two turns reuse an item id", () => {
    const itemId = "answer";
    const first = startAnswer(makeState(), itemId);
    const firstKey = first.itemIdMap.get(itemId)!;
    const enriched = reduceMessage(first, {
      type: "cydo/item_enriched",
      item_id: itemId,
      target_tid: 7,
    });

    const second = startAnswer(
      reduceMessage(enriched, asEvent({ type: "turn/stop" })),
      itemId,
    );
    const secondKey = second.itemIdMap.get(itemId)!;
    expect(secondKey).not.toBe(firstKey);
    expect(second.itemEnrichments.has(secondKey)).toBe(false);

    const result = reduceMessage(second, {
      type: "cydo/item_enriched",
      item_id: itemId,
      target_tid: 8,
    });
    expect(result.itemEnrichments.get(firstKey)?.targetTid).toBe(7);
    expect(result.itemEnrichments.get(secondKey)?.targetTid).toBe(8);
  });

  it("rejects enrichment for an unknown item", () => {
    expect(() =>
      reduceMessage(makeState(), {
        type: "cydo/item_enriched",
        item_id: "unknown",
        target_tid: 7,
      }),
    ).toThrow(/unknown or non-tool item unknown/);
  });

  it("rejects enrichment for a non-tool item", () => {
    const s = reduceMessage(makeState(), {
      type: "item/started",
      item_type: "thinking",
      item_id: "thought",
    });
    expect(() =>
      reduceMessage(s, {
        type: "cydo/item_enriched",
        item_id: "thought",
        target_tid: 7,
      }),
    ).toThrow(/non-tool item thought/);
  });

  it("rejects an empty enrichment for a known tool", () => {
    const s = startAnswer(makeState(), "answer");
    expect(() =>
      reduceMessage(s, { type: "cydo/item_enriched", item_id: "answer" }),
    ).toThrow(/Empty enrichment for item answer/);
  });

  it("rejects a second target for the same tool call", () => {
    const s = reduceMessage(startAnswer(makeState(), "answer"), {
      type: "cydo/item_enriched",
      item_id: "answer",
      target_tid: 7,
    });
    expect(() =>
      reduceMessage(s, {
        type: "cydo/item_enriched",
        item_id: "answer",
        target_tid: 8,
      }),
    ).toThrow(/Duplicate target task enrichment for item answer/);
  });
});

describe("spawned child enrichment", () => {
  function startTask(s: TaskState, itemId: string) {
    return reduceMessage(s, {
      type: "item/started",
      item_type: "tool_use",
      item_id: itemId,
      name: "Task",
      tool_server: "cydo",
    });
  }

  function recordChild(
    s: TaskState,
    itemId: string,
    specIndex: number,
    childTid: number,
  ) {
    return reduceMessage(s, {
      type: "cydo/item_enriched",
      item_id: itemId,
      spawned_child: { spec_index: specIndex, child_tid: childTid },
    });
  }

  it("attributes interleaved children to parallel Task calls by item id", () => {
    const started = startTask(startTask(makeState(), "first"), "second");
    const secondChild = recordChild(started, "second", 0, 20);
    expect(
      secondChild.itemEnrichments.get(secondChild.itemIdMap.get("first")!),
    ).toBeUndefined();
    expect(
      secondChild.itemEnrichments.get(secondChild.itemIdMap.get("second")!)
        ?.spawnedTids,
    ).toEqual(new Map([[0, 20]]));

    const firstChild = recordChild(secondChild, "first", 0, 10);
    const bothChildren = recordChild(firstChild, "second", 1, 21);

    expect(
      bothChildren.itemEnrichments.get(bothChildren.itemIdMap.get("first")!)
        ?.spawnedTids,
    ).toEqual(new Map([[0, 10]]));
    expect(
      bothChildren.itemEnrichments.get(bothChildren.itemIdMap.get("second")!)
        ?.spawnedTids,
    ).toEqual(
      new Map([
        [0, 20],
        [1, 21],
      ]),
    );
    expect(
      firstChild.itemEnrichments.get(firstChild.itemIdMap.get("second")!)
        ?.spawnedTids,
    ).toEqual(new Map([[0, 20]]));
  });

  it("rejects a second child for the same spec in one Task call", () => {
    const s = recordChild(startTask(makeState(), "task"), "task", 0, 42);
    expect(() => recordChild(s, "task", 0, 43)).toThrow(
      /Duplicate spawned child enrichment for item task at spec index 0/,
    );
  });

  it("retains child links when replay reaches the Task result", () => {
    const completed = reduceMessage(startTask(makeState(), "task"), {
      type: "item/completed",
      item_id: "task",
      is_error: false,
    });
    const enriched = recordChild(completed, "task", 0, 77);
    const withResult = reduceMessage(enriched, {
      type: "item/result",
      item_id: "task",
      content: [],
      is_error: false,
    });

    expect(
      withResult.itemEnrichments.get(withResult.itemIdMap.get("task")!)
        ?.spawnedTids,
    ).toEqual(new Map([[0, 77]]));
  });
});

it("keeps interleaved root output in the root assistant message", () => {
  let s = reduceMessage(makeState(), {
    type: "item/started",
    item_type: "tool_use",
    item_id: "agent-call",
    name: "Agent",
  });
  s = reduceMessage(s, {
    type: "item/started",
    item_type: "text",
    item_id: "child-text",
    parent_tool_use_id: "agent-call",
    text: "Child output",
  });
  s = reduceMessage(s, {
    type: "item/started",
    item_type: "text",
    item_id: "root-text",
    text: "Root output",
  });

  expect(
    s.messages.map((message) => ({
      parentToolUseId: message.parentToolUseId,
      items: message.blockIds?.map((id) => s.blocks.get(id)!.itemId),
    })),
  ).toEqual([
    { parentToolUseId: undefined, items: ["agent-call", "root-text"] },
    { parentToolUseId: "agent-call", items: ["child-text"] },
  ]);
});

it("closes a child-only stream when an interrupted turn reports its result", () => {
  const started = reduceMessage(makeState(), {
    type: "item/started",
    item_type: "text",
    item_id: "child-text",
    parent_tool_use_id: "agent-call",
    text: "Partial output",
  });
  const child = started.messages[0]!;
  const interrupted = reduceMessage(started, {
    type: "turn/result",
    subtype: "error_during_execution",
    is_error: true,
    num_turns: 1,
    duration_ms: 1,
    total_cost_usd: 0,
    usage: { input_tokens: 1, output_tokens: 1 },
  });

  expect(interrupted.streamingMessageCount).toBe(0);
  expect(interrupted.messages[0]?.streaming).toBe(false);
  expect(interrupted.blocks.get(child.blockIds![0]!)?.completed).toBe(true);

  const resumed = reduceMessage(interrupted, {
    type: "item/started",
    item_type: "text",
    item_id: "next-child-text",
    parent_tool_use_id: "agent-call",
    text: "New output",
  });
  expect(resumed.messages[0]?.blockIds).toHaveLength(1);
  expect(resumed.messages[2]).toMatchObject({
    parentToolUseId: "agent-call",
    streaming: true,
  });
});

describe("task state reducer", () => {
  function startedRow(state: TaskState) {
    return state.messages.find(
      (m) => m.subtype === "task_lifecycle" && m.taskState !== undefined,
    );
  }

  const start = {
    type: "task/started",
    task_id: "task-1",
    run_id: "run-1",
    tool_use_id: "toolu_1",
    is_backgrounded: true,
  } as const;
  const completed = {
    type: "task/notification",
    task_id: start.task_id,
    run_id: start.run_id,
    tool_use_id: start.tool_use_id,
    status: "completed",
    summary: "Agent finished",
  } as const;

  function issueTool() {
    return reduceMessage(makeState(), {
      type: "item/started",
      item_type: "tool_use",
      item_id: start.tool_use_id,
      name: "Agent",
    });
  }

  function toolBlock(s: TaskState) {
    return [...s.blocks.values()].find((b) => b.itemId === start.tool_use_id);
  }

  it("tracks a background launch and completion on its tool call", () => {
    let s = reduceMessage(issueTool(), {
      type: "item/completed",
      item_id: start.tool_use_id,
    });
    expect(toolBlock(s)).toBeDefined();
    expect(toolBlock(s)?.nativeTask).toBeUndefined();
    s = reduceMessage(s, start);
    s = reduceMessage(s, {
      type: "item/result",
      item_id: start.tool_use_id,
      content: "Agent launched",
    });
    expect(toolBlock(s)?.result?.content).toBe("Agent launched");
    expect(toolBlock(s)?.nativeTask?.status).toBe("running");

    s = reduceMessage(s, completed);
    expect(toolBlock(s)?.nativeTask).toMatchObject({
      status: "completed",
      summary: "Agent finished",
    });
    expect(s.messages.map((m) => m.type)).toEqual(["assistant"]);
  });

  it("returns a completed agent to running when it resumes under a new run ID", () => {
    let s = reduceMessage(issueTool(), {
      type: "item/completed",
      item_id: start.tool_use_id,
    });
    s = reduceMessage(s, start);
    s = reduceMessage(s, {
      type: "item/result",
      item_id: start.tool_use_id,
      content: "Agent launched",
    });
    s = reduceMessage(s, completed);
    s = reduceMessage(s, { ...start, run_id: "run-2" });
    expect(toolBlock(s)?.nativeTask).toEqual({
      taskId: start.task_id,
      runId: "run-2",
      status: "running",
      foreground: false,
    });

    s = reduceMessage(s, {
      type: "task/updated",
      task_id: start.task_id,
      run_id: "run-2",
      status: "completed",
    });
    expect(toolBlock(s)?.nativeTask?.status).toBe("completed");
    s = reduceMessage(s, {
      ...completed,
      run_id: "run-2",
      summary: "Resumed agent finished",
    });
    expect(toolBlock(s)?.nativeTask?.summary).toBe("Resumed agent finished");
    expect(s.messages.map((m) => m.type)).toEqual(["assistant"]);
  });

  it("tracks a task's state on the row that announced its start", () => {
    let s: TaskState = reduceMessage(
      makeState(),
      asEvent({
        type: "task/started",
        task_id: "t1",
        description: "watch logs",
        task_type: "local_bash",
      }),
      1,
    );
    expect(startedRow(s)?.taskState).toEqual({ status: "running" });

    s = reduceMessage(
      s,
      asEvent({ type: "task/updated", task_id: "t1", status: "killed" }),
      2,
    );
    expect(startedRow(s)?.taskState).toEqual({ status: "killed" });
    expect(s.messages).toHaveLength(1);

    s = reduceMessage(
      s,
      asEvent({ type: "task/updated", task_id: "t1", error: "exit 137" }),
      3,
    );
    expect(startedRow(s)?.taskState).toEqual({
      status: "killed",
      error: "exit 137",
    });
  });

  it("keeps lifecycle rows when the launching tool call is absent", () => {
    let s: TaskState = reduceMessage(makeState(), start, 1);
    s = reduceMessage(s, { ...completed, status: "failed" }, 2);
    expect(startedRow(s)?.taskState).toEqual({ status: "failed" });
    expect(s.messages).toMatchObject([
      { subtype: "task_lifecycle", rawSource: start },
      {
        subtype: "task_lifecycle",
        content: [{ type: "text", text: "Task failed: Agent finished" }],
      },
    ]);
  });
});

describe("item denial reducer", () => {
  function toolBlock(s: TaskState) {
    return [...s.blocks.values()].find((b) => b.itemId === "toolu_1");
  }

  it("records who refused a tool call, and why", () => {
    const started = reduceMessage(
      makeState(),
      asEvent({
        type: "item/started",
        item_id: "toolu_1",
        item_type: "tool_use",
        name: "Bash",
        input: { command: "rm -rf build" },
      }),
      1,
    );
    const denied = reduceMessage(
      started,
      asEvent({ type: "item/denied", item_id: "toolu_1", by: "settingsRule" }),
      2,
    );
    expect(toolBlock(denied)?.denial).toEqual({
      by: "settingsRule",
      reason: undefined,
    });

    const classified = reduceMessage(
      started,
      asEvent({
        type: "item/denied",
        item_id: "toolu_1",
        by: "classifier",
        reason: "risky",
      }),
      2,
    );
    expect(toolBlock(classified)?.denial).toEqual({
      by: "classifier",
      reason: "risky",
    });
  });
});

describe("narration reducer", () => {
  function thinkingBlock(s: TaskState, itemId: string) {
    return [...s.blocks.values()].find((b) => b.itemId === itemId);
  }

  it("marks only thinking items completed as narration", () => {
    let s: TaskState = makeState();
    for (const [seq, itemId] of [
      [1, "narration-1"],
      [2, "reasoning-1"],
    ] as const) {
      s = reduceMessage(
        s,
        asEvent({
          type: "item/started",
          item_id: itemId,
          item_type: "thinking",
        }),
        seq,
      );
    }
    s = reduceMessage(
      s,
      asEvent({
        type: "item/completed",
        item_id: "narration-1",
        is_narration: true,
      }),
      3,
    );
    s = reduceMessage(
      s,
      asEvent({ type: "item/completed", item_id: "reasoning-1" }),
      4,
    );

    expect(thinkingBlock(s, "narration-1")?.narration).toBe(true);
    expect(thinkingBlock(s, "reasoning-1")?.narration).toBeUndefined();
  });
});

describe("turn retraction reducer", () => {
  it("marks the withdrawn response and shows the agent's notice", () => {
    let s: TaskState = reduceMessage(
      makeState(),
      asEvent({
        type: "item/started",
        item_id: "text-1",
        item_type: "text",
        text: "A partial answer",
      }),
      1,
    );
    s = reduceMessage(s, asEvent({ type: "turn/delta", uuid: "u-text" }), 2);
    s = reduceMessage(s, asEvent({ type: "turn/stop" }), 3);
    const notice = {
      type: "cydo/task_diagnostic" as const,
      severity: "warning" as const,
      subject: "Model refused; switched",
      body: "Using the fallback model",
    };

    s = reduceMessage(
      s,
      asEvent({ type: "turn/retracted", uuids: ["u-text"], notice }),
      4,
    );

    expect(s.messages[0]).toMatchObject({ type: "assistant", retracted: true });
    expect(s.messages[1]).toMatchObject({
      type: "diagnostic",
      diagnostic: { severity: "warning", subject: "Model refused; switched" },
    });
  });

  it("leaves responses it does not name alone", () => {
    let s: TaskState = reduceMessage(
      makeState(),
      asEvent({
        type: "item/started",
        item_id: "text-1",
        item_type: "text",
        text: "Kept",
      }),
      1,
    );
    s = reduceMessage(s, asEvent({ type: "turn/delta", uuid: "u-kept" }), 2);
    s = reduceMessage(s, asEvent({ type: "turn/stop" }), 3);
    s = reduceMessage(
      s,
      asEvent({
        type: "turn/retracted",
        uuids: ["u-other"],
        notice: {
          type: "cydo/task_diagnostic",
          severity: "warning",
          subject: "Model refused; switched",
          body: "",
        },
      }),
      4,
    );
    expect(s.messages[0]!.retracted).toBeUndefined();
  });
});

describe("Claude image companion replay", () => {
  const readA = asEvent({
    type: "item/started",
    item_type: "tool_use",
    item_id: "read-a",
    name: "Read",
  });
  const readB = { ...readA, item_id: "read-b" };
  const resultA = asEvent({
    type: "item/result",
    item_id: "read-a",
    content: [{ type: "text", text: "image result" }],
  });
  const companion = asEvent({
    type: "item/started",
    item_type: "user_message",
    item_id: "cc-user-msg",
    uuid: "image-companion",
    is_meta: true,
    content: [{ type: "text", text: "[Image: original 2400x2400]" }],
  });
  const stop = asEvent({
    type: "turn/stop",
    uuid: "X",
    history_boundary: { kind: "agent_turn", anchor: "X" },
  });

  it("keeps two reads in one reply above their interleaved companion", () => {
    const events = [
      readA,
      asEvent({ type: "item/completed", item_id: "read-a" }),
      resultA,
      companion,
      readB,
      asEvent({ type: "item/completed", item_id: "read-b" }),
      stop,
    ];
    const landed = events.reduce<TaskState>(
      (state, event, index) => reduceMessage(state, event, index + 1),
      makeState(),
    );
    expect(landed.messages.map((message) => message.type)).toEqual([
      "assistant",
      "user",
    ]);
    expect(landed.messages[0]).toMatchObject({
      streaming: false,
      uuid: "X",
      blockIds: ["read-a", "read-b"].map((id) => landed.itemIdMap.get(id)),
    });
    expect(landed.messages[1]).toMatchObject({
      isMeta: true,
      uuid: "image-companion",
    });
    const raw = landed.messages[0]?.rawSource as Array<{ type: string }>;
    expect(raw.filter((event) => event.type === "turn/stop")).toEqual([stop]);
  });

  it("keeps a trailing companion before the next prompt or refusal notice", () => {
    const prompt = asEvent({
      type: "item/started",
      item_type: "user_message",
      item_id: "cc-user-msg",
      uuid: "next-prompt",
    });
    const refusal = asEvent({
      type: "turn/retracted",
      uuids: ["other-message"],
      notice: {
        type: "cydo/task_diagnostic",
        severity: "warning",
        subject: "Model refused; switched",
        body: "Using fallback",
      },
    });
    for (const ending of [prompt, refusal]) {
      const events = [readA, companion, stop, ending];
      const landed = events.reduce<TaskState>(
        (state, event, index) => reduceMessage(state, event, index + 1),
        makeState(),
      );
      expect(landed.messages.map((message) => message.type)).toEqual([
        "assistant",
        "user",
        ending === prompt ? "user" : "diagnostic",
      ]);
      expect(landed.messages[0]).toMatchObject({ streaming: false });
      expect(landed.messages[1]).toMatchObject({ uuid: "image-companion" });
    }
  });
});

describe("item/abandoned reducer", () => {
  function startText(state: TaskState, item_id: string) {
    return reduceMessage(
      state,
      asEvent({ type: "item/started", item_type: "text", item_id }),
    );
  }

  function abandon(state: TaskState, item_id: string) {
    return reduceMessage(state, asEvent({ type: "item/abandoned", item_id }));
  }

  it("removes the discarded text block and keeps the thinking block", () => {
    const thinking = reduceMessage(
      makeState(),
      asEvent({
        type: "item/started",
        item_type: "thinking",
        item_id: "thinking",
      }),
    );
    const streamed = startText(thinking, "text");
    const thinkingKey = streamed.itemIdMap.get("thinking")!;
    const textKey = streamed.itemIdMap.get("text")!;

    const next = abandon(streamed, "text");

    expect(next.messages).toHaveLength(1);
    expect(next.messages[0]?.blockIds).toEqual([thinkingKey]);
    expect(next.blocks.get(thinkingKey)?.type).toBe("thinking");
    expect(next.blocks.has(textKey)).toBe(false);
    expect(next.itemIdMap.has("text")).toBe(false);
  });

  it("removes an emptied message and preserves the previous turn through the stop", () => {
    const completed = reduceMessage(
      startText(makeState(), "earlier"),
      asEvent({ type: "turn/stop", uuid: "earlier-turn", api_block_count: 1 }),
    );
    const streamed = startText(completed, "discarded");
    expect(streamed.messages).toHaveLength(2);

    const next = abandon(streamed, "discarded");
    expect(next.messages).toEqual(completed.messages);

    const stopped = reduceMessage(
      next,
      asEvent({
        type: "turn/stop",
        uuid: "discarded-turn",
        api_block_count: 0,
      }),
    );
    expect(stopped.messages).toEqual(completed.messages);
    expect(stopped.blocks).toEqual(completed.blocks);
  });

  it("throws for an unknown item ID", () => {
    expect(() => abandon(makeState(), "unknown")).toThrow(
      /unknown item unknown/,
    );
  });
});
