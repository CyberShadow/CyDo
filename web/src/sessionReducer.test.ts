import { describe, expect, it } from "vitest";
import { reduceMessage } from "./sessionReducer";
import { makeTaskState } from "./types";

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
