import { describe, expect, it } from "vitest";
import { reduceMessage, reduceCydoTaskSpawned } from "./sessionReducer";
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
    const state = { ...makeState(), agentType: "codex" };
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
    expect(tracked).toBeTruthy();
    expect(tracked?.edits).toHaveLength(1);
    expect(tracked?.edits[0]?.source).toBe("codex-fileChange");
    expect(tracked?.edits[0]?.status).toBe("pending");
    expect(tracked?.edits[0]?.payload).toEqual({
      mode: "full_content",
      content: "# New markdown\n",
    });
  });

  it("tracks codex apply_patch markdown update events as patch-text edits", () => {
    const state = { ...makeState(), agentType: "codex" };
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
      { ...makeState(), agentType: "claude" },
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

describe("agent warning reducer", () => {
  it("creates a standalone assistant warning block when nothing is streaming", () => {
    const next = reduceMessage(
      makeState(),
      asEvent({
        type: "agent/warning",
        message:
          "Heads up: Long threads and multiple compactions can cause the model to be less accurate.",
      }),
    );

    expect(next.messages).toHaveLength(1);
    expect(next.messages[0]?.type).toBe("assistant");
    expect(next.messages[0]?.streaming).toBe(false);
    expect(next.messages[0]?.blockIds).toEqual(["warning-1"]);

    const block = next.blocks.get("warning-1");
    expect(block).toMatchObject({
      itemId: "warning-1",
      type: "warning",
      text: "Heads up: Long threads and multiple compactions can cause the model to be less accurate.",
      completed: true,
      creationOrder: 0,
    });
  });

  it("appends a warning block to the streaming assistant message in temporal order", () => {
    const streaming = reduceMessage(
      makeState(),
      asEvent({
        type: "item/started",
        item_id: "text-1",
        item_type: "text",
        text: "Working on it",
      }),
    );

    const next = reduceMessage(
      streaming,
      asEvent({
        type: "agent/warning",
        message:
          "Heads up: Long threads and multiple compactions can cause the model to be less accurate.",
      }),
    );

    expect(next.messages).toHaveLength(1);
    expect(next.messages[0]?.type).toBe("assistant");
    expect(next.messages[0]?.streaming).toBe(true);
    expect(next.messages[0]?.blockIds).toEqual([
      "streaming-1:text-1",
      "warning-2",
    ]);

    const textBlock = next.blocks.get("streaming-1:text-1");
    expect(textBlock?.type).toBe("text");

    const warningBlock = next.blocks.get("warning-2");
    expect(warningBlock).toMatchObject({
      itemId: "warning-2",
      type: "warning",
      text: "Heads up: Long threads and multiple compactions can cause the model to be less accurate.",
      completed: false,
      creationOrder: 1,
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

describe("result text visibility", () => {
  const resultEvent = (result?: string) =>
    asEvent({
      type: "turn/result",
      subtype: "success",
      is_error: false,
      num_turns: 1,
      duration_ms: 1,
      total_cost_usd: 0,
      usage: { input_tokens: 1, output_tokens: 1 },
      result,
    });

  function streamAssistantText(s: TaskState, text: string): TaskState {
    s = reduceMessage(
      s,
      asEvent({
        type: "item/started",
        item_type: "text",
        item_id: "cc-block-0",
      }),
    );
    s = reduceMessage(
      s,
      asEvent({
        type: "item/delta",
        item_id: "cc-block-0",
        delta_type: "text_delta",
        content: text,
      }),
    );
    s = reduceMessage(
      s,
      asEvent({ type: "item/completed", item_id: "cc-block-0" }),
    );
    return reduceMessage(s, asEvent({ type: "turn/stop" }));
  }

  it("marks result as redundant when its text was streamed", () => {
    let s: TaskState = makeState();
    s = streamAssistantText(s, "Hello there friend.");
    s = reduceMessage(s, resultEvent("Hello there friend."));
    expect(s.messages.at(-1)?.resultData?.resultUnseen).toBe(false);
  });

  it("marks result as unseen when no assistant message exists", () => {
    let s: TaskState = makeState();
    s = reduceMessage(s, resultEvent("Reply that never streamed."));
    expect(s.messages.at(-1)?.resultData?.resultUnseen).toBe(true);
  });

  it("marks result as unseen when the streamed text differs", () => {
    let s: TaskState = makeState();
    s = streamAssistantText(s, "Some earlier partial output.");
    s = reduceMessage(s, resultEvent("Reply that never streamed."));
    expect(s.messages.at(-1)?.resultData?.resultUnseen).toBe(true);
  });

  it("does not mark resultless events as unseen", () => {
    let s: TaskState = makeState();
    s = reduceMessage(s, resultEvent(undefined));
    expect(s.messages.at(-1)?.resultData?.resultUnseen).toBe(false);
  });

  it("marks result as unseen when only a thinking block rendered", () => {
    // Partial stream: the thinking block streamed and rendered, but the text
    // block's stream events never arrived, so the final reply survived only in
    // the result. A rendered thinking block is not a text block, so it must not
    // count the result text as seen.
    let s: TaskState = makeState();
    s = reduceMessage(
      s,
      asEvent({ type: "item/started", item_id: "think-1", item_type: "thinking" }),
    );
    s = reduceMessage(s, asEvent({ type: "turn/stop" }));
    s = reduceMessage(s, resultEvent("Both done, committed."));
    expect(s.messages.at(-1)?.resultData?.resultUnseen).toBe(true);
  });
});
