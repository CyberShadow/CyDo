import { describe, expect, it, vi } from "vitest";
import { makeTaskState, type TaskState } from "./types";

vi.hoisted(() => {
  vi.stubGlobal("CSS", { supports: () => false });
  vi.stubGlobal("document", { querySelector: () => null });
});
import {
  receiveServerError,
  revertFilesForUndo,
  taskObservationFromEntry,
  taskStateFromEntry,
  type TaskSnapshotEntry,
} from "./useSessionManager";

describe("undo confirmation request", () => {
  it("forwards file revert only for the selected checkpoint boundary", () => {
    expect(revertFilesForUndo(false, true)).toBe(false); // assistant boundary
    expect(revertFilesForUndo(false, true)).toBe(false); // checkpoint-less user
    expect(revertFilesForUndo(false, true)).toBe(false); // unsupported agent
    expect(revertFilesForUndo(true, true)).toBe(true);
  });
});

function task(tid: number, undoPending = false): TaskState {
  return {
    ...makeTaskState(tid, true),
    uuid: `task-${tid}`,
    undoPending: undoPending
      ? {
          anchor: `message-${tid}`,
          kind: "codex_turns",
          messagesRemoved: 2,
          canRevertFiles: false,
          retainsPrompt: false,
        }
      : undefined,
  };
}

describe("receiveServerError", () => {
  it("returns the received error fields without changing tasks without a tid", () => {
    const tasks = new Map([["task-1", task(1, true)]]);

    const result = receiveServerError(tasks, "Command failed");

    expect(result.serverError).toEqual({ message: "Command failed" });
    expect(result.tasks).toBe(tasks);
  });

  it("clears undo pending only for the task named by the error", () => {
    const matching = task(1, true);
    const other = task(2, true);
    const tasks = new Map([
      [matching.uuid, matching],
      [other.uuid, other],
    ]);

    const result = receiveServerError(tasks, "Undo failed", 1);

    expect(result.serverError).toEqual({ message: "Undo failed", tid: 1 });
    expect(result.tasks).not.toBe(tasks);
    expect(result.tasks.get(matching.uuid)).toMatchObject({
      undoPending: null,
    });
    expect(result.tasks.get(other.uuid)).toBe(other);
    expect(other.undoPending).toEqual({
      anchor: "message-2",
      kind: "codex_turns",
      messagesRemoved: 2,
      canRevertFiles: false,
      retainsPrompt: false,
    });
  });

  it("preserves undo pending when the error names another task", () => {
    const pending = task(1, true);
    const tasks = new Map([[pending.uuid, pending]]);

    const result = receiveServerError(tasks, "Other task failed", 2);

    expect(result.serverError).toEqual({
      message: "Other task failed",
      tid: 2,
    });
    expect(result.tasks).toBe(tasks);
    expect(pending.undoPending).toEqual({
      anchor: "message-1",
      kind: "codex_turns",
      messagesRemoved: 2,
      canRevertFiles: false,
      retainsPrompt: false,
    });
  });
});

describe("taskStateFromEntry draft merge", () => {
  const entry = (draft?: string) => ({
    tid: 11,
    child_count: 0,
    alive: false,
    resumable: false,
    isProcessing: false,
    ...(draft === undefined ? {} : { draft }),
  });

  it("applies an explicitly present newer draft, including a clear", () => {
    const existing = { ...makeTaskState(11, false), serverDraft: "old draft" };

    expect(
      taskStateFromEntry(entry("new draft"), existing, existing.uuid)
        .serverDraft,
    ).toBe("new draft");
    expect(
      taskStateFromEntry(entry(""), existing, existing.uuid).serverDraft,
    ).toBeUndefined();
  });

  it("preserves a prior draft when a snapshot omits the field", () => {
    const existing = { ...makeTaskState(11, false), serverDraft: "old draft" };

    expect(
      taskStateFromEntry(entry(), existing, existing.uuid).serverDraft,
    ).toBe("old draft");
  });
});

describe("task observation adapter", () => {
  const entry = (fields: Record<string, unknown> = {}) =>
    ({
      tid: 11,
      child_count: 0,
      alive: false,
      resumable: false,
      isProcessing: false,
      ...fields,
    }) as TaskSnapshotEntry;

  it("drops own-present null and undefined form facts", () => {
    expect(
      taskObservationFromEntry(
        entry({
          draft: null,
          entry_point: undefined,
          agent_name: null,
          status: undefined,
        }),
        false,
      ),
    ).toEqual({ tid: 11 });
  });

  it("omits absent form facts", () => {
    expect(taskObservationFromEntry(entry(), false)).toEqual({ tid: 11 });
  });

  it("preserves explicitly empty form strings", () => {
    expect(
      taskObservationFromEntry(
        entry({ draft: "", entry_point: "", agent_name: "", status: "" }),
        false,
      ),
    ).toEqual({
      tid: 11,
      text: "",
      entryPoint: "",
      agent: "",
      active: true,
    });
  });
});
