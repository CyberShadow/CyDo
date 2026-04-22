import { describe, expect, it } from "vitest";
import { reduceMessage } from "./sessionReducer";
import { makeTaskState } from "./types";

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
