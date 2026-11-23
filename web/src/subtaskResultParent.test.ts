import { describe, expect, it } from "vitest";
import { subtaskResultParent } from "./subtaskResultParent";

describe("subtaskResultParent", () => {
  const subtask = {
    tid: 2,
    parentTid: 1,
    relationType: "subtask",
    status: "completed",
  } as const;
  const noPredecessors = new Set<number>();
  const noTasks = () => undefined;

  it.each(["completed", "failed"] as const)(
    "returns the parent of a %s subtask",
    (status) => {
      expect(
        subtaskResultParent({ ...subtask, status }, noPredecessors, noTasks),
      ).toBe(1);
    },
  );

  it("returns the original subtask's parent through multiple continuations", () => {
    const firstContinuation = {
      tid: 3,
      parentTid: 2,
      relationType: "continuation",
      status: "completed",
    } as const;
    const lastContinuation = {
      ...firstContinuation,
      tid: 4,
      parentTid: 3,
    };
    const lineage = new Map<
      number,
      { parentTid: number; relationType: string }
    >([
      [subtask.tid, subtask],
      [firstContinuation.tid, firstContinuation],
    ]);

    expect(
      subtaskResultParent(lastContinuation, new Set([2, 3]), (tid) =>
        lineage.get(tid),
      ),
    ).toBe(1);
  });

  it("omits a continuation of a top-level task", () => {
    const lineage = new Map([[1, {}]]);

    expect(
      subtaskResultParent(
        { ...subtask, relationType: "continuation" },
        new Set([1]),
        (tid) => lineage.get(tid),
      ),
    ).toBeUndefined();
  });

  it("omits a fork of a subtask", () => {
    const lineage = new Map<number, typeof subtask>([[subtask.tid, subtask]]);

    expect(
      subtaskResultParent(
        { ...subtask, tid: 3, parentTid: 2, relationType: "fork" },
        noPredecessors,
        (tid) => lineage.get(tid),
      ),
    ).toBeUndefined();
  });

  it.each(["pending", "active", "alive", "waiting", "importable"] as const)(
    "omits a subtask with status %s",
    (status) => {
      expect(
        subtaskResultParent({ ...subtask, status }, noPredecessors, noTasks),
      ).toBeUndefined();
    },
  );

  it("omits a completed subtask with a continuation successor", () => {
    expect(
      subtaskResultParent(subtask, new Set([subtask.tid]), noTasks),
    ).toBeUndefined();
  });
});
