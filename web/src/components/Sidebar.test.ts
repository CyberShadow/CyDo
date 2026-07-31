import { describe, expect, it } from "vitest";
import {
  flatTaskOrder,
  shouldHandleSidebarAltArchive,
  type SidebarTask,
} from "./Sidebar";

describe("Sidebar archive click guard", () => {
  it("allows Alt-click archive when task is not archiving", () => {
    expect(shouldHandleSidebarAltArchive(true, true, false)).toBe(true);
  });

  it("blocks Alt-click archive while task is archiving", () => {
    expect(shouldHandleSidebarAltArchive(true, true, true)).toBe(false);
  });

  it("blocks non-Alt clicks and missing handlers", () => {
    expect(shouldHandleSidebarAltArchive(false, true, false)).toBe(false);
    expect(shouldHandleSidebarAltArchive(true, false, false)).toBe(false);
  });
});

function task(
  tid: number,
  lastActive: number,
  extra: Partial<SidebarTask> = {},
): SidebarTask {
  return {
    tid,
    alive: false,
    canStop: false,
    resumable: false,
    isProcessing: false,
    lastActive,
    ...extra,
  };
}

describe("sidebar recency ordering", () => {
  it("leaves the order alone when the option is off", () => {
    const tasks = [task(1, 500), task(2, 100), task(3, 900)];
    expect(flatTaskOrder(tasks)).toEqual(["1", "2", "3"]);
  });

  it("puts the most recently active task first", () => {
    const tasks = [task(1, 500), task(2, 100), task(3, 900)];
    expect(flatTaskOrder(tasks, true)).toEqual(["3", "1", "2"]);
  });

  it("raises a parent to the top when a descendant is active, at any depth", () => {
    // tid 1 itself is stale, but its grandchild 3 is the newest thing anywhere
    const tasks = [
      task(1, 100),
      task(2, 100, { parentTid: 1 }),
      task(3, 900, { parentTid: 2 }),
      task(4, 500),
    ];
    // 1 leads on its grandchild's activity; hierarchy is unchanged
    expect(flatTaskOrder(tasks, true)).toEqual(["1", "2", "3", "4"]);
  });

  it("re-sorts siblings without reparenting them", () => {
    const tasks = [
      task(1, 100),
      task(2, 200, { parentTid: 1 }),
      task(3, 800, { parentTid: 1 }),
    ];
    // 3 sorts above its sibling 2, and both stay under 1
    expect(flatTaskOrder(tasks, true)).toEqual(["1", "3", "2"]);
  });

  it("pins Archive then Import below the live tasks", () => {
    const tasks = [
      task(1, 900),
      task(2, 100, { archived: true }),
      task(3, 800, { status: "importable" }),
    ];
    expect(flatTaskOrder(tasks, true)).toEqual([
      "1",
      "archive",
      "2",
      "import",
      "3",
    ]);
  });

  it("keeps Archive and Import above the tasks when the option is off", () => {
    const tasks = [
      task(1, 900),
      task(2, 100, { archived: true }),
      task(3, 800, { status: "importable" }),
    ];
    expect(flatTaskOrder(tasks)).toEqual(["archive", "2", "import", "3", "1"]);
  });
});
