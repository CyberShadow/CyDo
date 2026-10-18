/** @vitest-environment jsdom */

import { h, render } from "preact";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import sidebarStyles from "../styles.css?inline";

vi.hoisted(() => {
  vi.stubGlobal("CSS", { escape: (value: string) => value });
});

import {
  buildTree,
  flatTaskOrder,
  flattenTree,
  Sidebar,
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

function task(tid: number, extra: Partial<SidebarTask> = {}): SidebarTask {
  return {
    tid,
    alive: false,
    canStop: false,
    resumable: false,
    isProcessing: false,
    childCount: 0,
    ...extra,
  };
}

function items(tasks: SidebarTask[], activeTaskId: string | null) {
  return flattenTree(buildTree(tasks), activeTaskId, [], false).filter(
    (item) => item.kind === "ordinary",
  );
}

function flatten(
  tasks: SidebarTask[],
  activeTaskId: string | null,
  tasksLoading: boolean,
) {
  return flattenTree(buildTree(tasks), activeTaskId, [], tasksLoading);
}

describe("Sidebar subtask collapsing", () => {
  const done = { status: "completed" };
  const parentWithTwoDone = [
    task(1),
    task(2, { parentTid: 1, ...done }),
    task(3, { parentTid: 1, ...done }),
  ];

  it("collapses stopped subtasks into a summary row when parent is not selected", () => {
    const flat = items(parentWithTwoDone, null);
    expect(flat.map((i) => i.id)).toEqual(["1", "subtasks:1"]);
    const summary = flat[1]!;
    expect(summary.title).toBe("(2 subtasks)");
    expect(summary.selectId).toBe("1");
    expect(summary.attentionTids).toEqual([2, 3]);
    expect(summary.iconName).toBe("subtasks");
    expect(summary.statusClass).toBe("completed");
  });

  it("counts failed subtasks as stopped, graying the mixed-status icon", () => {
    const tasks = [
      task(1),
      task(2, { parentTid: 1, status: "failed" }),
      task(3, { parentTid: 1, ...done }),
    ];
    const flat = items(tasks, null);
    expect(flat.map((i) => i.id)).toEqual(["1", "subtasks:1"]);
    expect(flat[1]!.statusClass).toBe("");
  });

  it("counts never-started (pending) subtasks as collapsible", () => {
    const tasks = [
      task(1),
      task(2, { parentTid: 1, status: "pending" }),
      task(3, { parentTid: 1, ...done }),
    ];
    expect(items(tasks, null).map((i) => i.id)).toEqual(["1", "subtasks:1"]);
  });

  it("colors the summary icon by the shared status of hidden subtasks", () => {
    const tasks = [
      task(1),
      task(2, { parentTid: 1, status: "failed" }),
      task(3, { parentTid: 1, status: "failed" }),
    ];
    expect(items(tasks, null)[1]!.statusClass).toBe("failed");
  });

  it("expands subtasks when the parent is selected", () => {
    expect(items(parentWithTwoDone, "1").map((i) => i.id)).toEqual([
      "1",
      "2",
      "3",
    ]);
  });

  it("expands when the selection is inside the collapsed run", () => {
    expect(items(parentWithTwoDone, "3").map((i) => i.id)).toEqual([
      "1",
      "2",
      "3",
    ]);
  });

  it("does not collapse an only stopped subtask", () => {
    const tasks = [task(1), task(2, { parentTid: 1, ...done })];
    expect(items(tasks, null).map((i) => i.id)).toEqual(["1", "2"]);
  });

  it("collapses only the leading stopped run, keeping running children visible", () => {
    const tasks = [
      ...parentWithTwoDone,
      task(4, { parentTid: 1, alive: true }),
      task(5, { parentTid: 1, ...done }),
    ];
    expect(items(tasks, null).map((i) => i.id)).toEqual([
      "1",
      "subtasks:1",
      "4",
      "5",
    ]);
  });

  it("keeps the stopped run collapsed while a running sibling is selected", () => {
    const tasks = [
      ...parentWithTwoDone,
      task(4, { parentTid: 1, alive: true }),
    ];
    expect(items(tasks, "4").map((i) => i.id)).toEqual([
      "1",
      "subtasks:1",
      "4",
    ]);
  });

  it("does not collapse a run interrupted by a running first child", () => {
    const tasks = [
      task(1),
      task(2, { parentTid: 1, alive: true }),
      task(3, { parentTid: 1, ...done }),
      task(4, { parentTid: 1, ...done }),
    ];
    expect(items(tasks, null).map((i) => i.id)).toEqual(["1", "2", "3", "4"]);
  });

  it("treats a subtree with a running descendant as not stopped", () => {
    const tasks = [
      task(1),
      task(2, { parentTid: 1, ...done }),
      task(3, { parentTid: 1, ...done }),
      task(4, { parentTid: 3, alive: true }),
    ];
    expect(items(tasks, null).map((i) => i.id)).toEqual(["1", "2", "3", "4"]);
  });

  it("collapses stopped runs recursively, including under a selected parent's children", () => {
    const tasks = [
      task(1),
      task(2, { parentTid: 1, ...done }),
      task(3, { parentTid: 1, alive: true }),
      task(4, { parentTid: 3, ...done }),
      task(5, { parentTid: 3, ...done }),
    ];
    expect(items(tasks, "1").map((i) => i.id)).toEqual([
      "1",
      "2",
      "3",
      "subtasks:3",
    ]);
  });

  it("treats archived children as stopped and excludes them from the count", () => {
    const tasks = [
      task(1),
      task(2, { parentTid: 1, ...done }),
      task(3, { parentTid: 1, ...done }),
      task(4, { parentTid: 1, resumable: true, archived: true }),
    ];
    const flat = items(tasks, null);
    expect(flat.map((i) => i.id)).toEqual(["1", "subtasks:1"]);
    const summary = flat[1]!;
    expect(summary.title).toBe("(2 subtasks)");
    expect(summary.attentionTids).toEqual([4, 2, 3]);
    // The archived resumable task does not dilute the status vote.
    expect(summary.statusClass).toBe("completed");
  });
});

describe("Sidebar child loading", () => {
  it("does not add a marker when a task has no children", () => {
    const flat = flatten([task(1)], null, true);

    expect(flat.some((item) => item.kind === "loading")).toBe(false);
  });

  it("adds a marker for an expected child that has not arrived", () => {
    const flat = flatten([task(1, { childCount: 1 })], null, true);
    const loading = flat.find((item) => item.kind === "loading");

    expect(loading).toMatchObject({
      kind: "loading",
      key: "loading:1",
      depth: 1,
      guides: 0,
    });
    expect(loading).toBeDefined();
    expect("id" in loading!).toBe(false);
    expect("tid" in loading!).toBe(false);
  });

  it("keeps incomplete descendants out of collapsed summaries while loading", () => {
    const tasks = [
      task(1),
      task(2, { parentTid: 1, status: "completed" }),
      task(3, { parentTid: 1, status: "completed", childCount: 1 }),
    ];
    const partial = flatten(tasks, null, true);

    expect(
      partial.map((item) => (item.kind === "ordinary" ? item.id : item.key)),
    ).toEqual(["1", "2", "3", "loading:3"]);
    expect(partial[2]).toMatchObject({
      kind: "ordinary",
      id: "3",
      depth: 1,
      guides: 0,
    });
    expect(partial[3]).toMatchObject({
      kind: "loading",
      key: "loading:3",
      depth: 2,
      guides: 0,
    });

    expect(
      flatten(tasks, null, false).map((item) =>
        item.kind === "ordinary" ? item.id : item.key,
      ),
    ).toEqual(["1", "subtasks:1"]);
  });

  it("places the marker after known children and keeps it out of task order", () => {
    const tasks = [
      task(1, { childCount: 2 }),
      task(2, { parentTid: 1, alive: true }),
    ];
    const flat = flatten(tasks, null, true);

    expect(
      flat.map((item) => (item.kind === "ordinary" ? item.id : item.key)),
    ).toEqual(["1", "2", "loading:1"]);
    expect(flat[1]).toMatchObject({
      kind: "ordinary",
      id: "2",
      depth: 1,
      guides: 1,
    });
    expect(flat[2]).toMatchObject({
      kind: "loading",
      depth: 1,
      guides: 0,
    });
    expect(flatTaskOrder(tasks)).toEqual(["1", "2"]);
  });

  it("removes the marker once all expected children arrive during loading", () => {
    const tasks = [
      task(1, { childCount: 2 }),
      task(2, { parentTid: 1, alive: true }),
      task(3, { parentTid: 1, alive: true }),
    ];

    expect(
      flatten(tasks, null, true).some((item) => item.kind === "loading"),
    ).toBe(false);
  });

  it("moves later archived children into Archive and removes the marker", () => {
    const partial = [
      task(1, { childCount: 3 }),
      task(2, { parentTid: 1, alive: true }),
      task(3, { parentTid: 1, archived: true }),
    ];
    expect(
      flatten(partial, "3", true).filter((item) => item.kind === "loading"),
    ).toHaveLength(1);

    const complete = [...partial, task(4, { parentTid: 1, archived: true })];
    const flat = flatten(complete, "4", true);

    expect(
      flat.map((item) => (item.kind === "ordinary" ? item.id : item.key)),
    ).toEqual(["1", "archive:1", "3", "4", "2"]);
    expect(
      flat.find((item) => item.kind === "ordinary" && item.id === "archive:1"),
    ).toMatchObject({ title: "Archive (2)" });
    expect(flat.some((item) => item.kind === "loading")).toBe(false);
  });

  it("uses raw archive state when an archived parent has an unarchived child", () => {
    const flat = flatten(
      [
        task(1, { archived: true, childCount: 2 }),
        task(2, { parentTid: 1, alive: true }),
      ],
      "1",
      true,
    );

    expect(
      flat.map((item) => (item.kind === "ordinary" ? item.id : item.key)),
    ).toEqual(["archive", "1", "2", "loading:1"]);
    expect(flat[2]).toMatchObject({
      kind: "ordinary",
      id: "2",
      isArchive: false,
    });
  });

  it("keeps Archive and collapsed summaries before the final child marker", () => {
    const flat = flatten(
      [
        task(1, { childCount: 3 }),
        task(2, { parentTid: 1, archived: true, status: "completed" }),
        task(3, { parentTid: 1, alive: true, childCount: 2 }),
        task(4, { parentTid: 3, status: "completed" }),
        task(5, { parentTid: 3, status: "completed" }),
      ],
      null,
      true,
    );

    expect(
      flat.map((item) => (item.kind === "ordinary" ? item.id : item.key)),
    ).toEqual(["1", "archive:1", "3", "subtasks:3", "loading:1"]);
    expect(flat[1]).toMatchObject({
      kind: "ordinary",
      title: "Archive (1)",
      depth: 1,
      guides: 1,
    });
    expect(flat[3]).toMatchObject({
      kind: "ordinary",
      title: "(2 subtasks)",
      depth: 2,
      guides: 1,
    });
    expect(flat[4]).toMatchObject({
      kind: "loading",
      depth: 1,
      guides: 0,
    });
  });

  it("hides incomplete child markers after loading completes", () => {
    const tasks = [
      task(1, { childCount: 2 }),
      task(2, { parentTid: 1, alive: true }),
    ];

    expect(
      flatten(tasks, null, false).some((item) => item.kind === "loading"),
    ).toBe(false);
  });

  it("trusts the projected child count when an off-scope row is absent", () => {
    const projectedTasks = [
      task(1, { childCount: 1 }),
      task(2, { parentTid: 1, alive: true }),
    ];

    expect(
      flatten(projectedTasks, null, true).some(
        (item) => item.kind === "loading",
      ),
    ).toBe(false);
  });

  it("naturally hides a pending child with its collapsed Archive parent", () => {
    const flat = flatten(
      [task(1, { archived: true, childCount: 1 })],
      null,
      true,
    );

    expect(
      flat.map((item) => (item.kind === "ordinary" ? item.id : item.key)),
    ).toEqual(["archive"]);
  });
});

describe("Sidebar loading marker markup", () => {
  let container: HTMLDivElement;

  const mount = (
    tasks: SidebarTask[],
    tasksLoading: boolean,
    onSelect = vi.fn(),
  ) => {
    render(
      h(Sidebar, {
        tasks,
        tasksLoading,
        activeTaskId: null,
        attention: new Set<number>(),
        onSelectTask: onSelect,
        getTaskHref: (id: string) => `/task/${id}`,
        taskTypes: [],
      }),
      container,
    );
    return onSelect;
  };

  beforeEach(() => {
    container = document.createElement("div");
    document.body.appendChild(container);
  });

  afterEach(() => {
    render(null, container);
    container.remove();
  });

  it("renders an expected child marker as a noninteractive tree row", () => {
    const onSelect = mount([task(1, { childCount: 1 })], true);
    const marker = container.querySelector<HTMLDivElement>(
      ".sidebar-loading-item",
    );

    expect(marker).not.toBeNull();
    expect(marker?.tagName).toBe("DIV");
    expect(marker?.textContent).toBe("(loading…)");
    expect(marker?.querySelector(".tree-connectors")).not.toBeNull();
    expect(marker?.querySelectorAll(".tree-connectors svg")).toHaveLength(1);
    expect(marker?.querySelector(".task-type-icon")).toBeNull();
    expect(marker?.classList.contains("sidebar-item")).toBe(false);
    expect(marker?.getAttribute("href")).toBeNull();
    expect(marker?.querySelector("[href]")).toBeNull();
    expect(marker?.getAttribute("data-tid")).toBeNull();
    expect(marker?.querySelector("[data-tid]")).toBeNull();
    expect(marker?.tabIndex).toBe(-1);

    marker?.dispatchEvent(
      new MouseEvent("click", { bubbles: true, cancelable: true }),
    );
    expect(onSelect).not.toHaveBeenCalled();
  });

  it("gives the loading marker the ordinary row leading layout", () => {
    const sidebarItemRule = sidebarStyles.match(
      /\.sidebar-item\s*\{([^}]*)\}/,
    )?.[1];
    const loadingItemRule = sidebarStyles.match(
      /\.sidebar-loading-item\s*\{([^}]*)\}/,
    )?.[1];

    expect(sidebarItemRule).toContain("padding: 0 16px;");
    expect(loadingItemRule).toContain("padding: 0 16px;");
    expect(sidebarItemRule).toContain("border-left: 3px solid transparent;");
    expect(loadingItemRule).toContain("border-left: 3px solid transparent;");
  });

  it("does not show a global loading row when there is no incomplete parent", () => {
    mount([], true);

    expect(container.querySelector(".sidebar-loading-item")).toBeNull();
    expect(container.querySelector(".sidebar-loading")).toBeNull();
    expect(container.querySelector('[role="status"]')).toBeNull();
    expect(container.textContent).not.toContain("(loading…)");
  });
});

describe("sidebar activity sort", () => {
  const activity = { sort: "activity" } as const;

  it("keeps the creation order by default", () => {
    const tasks = [
      task(1, { lastActive: 500 }),
      task(2, { lastActive: 100 }),
      task(3, { lastActive: 900 }),
    ];
    expect(flatTaskOrder(tasks)).toEqual(["1", "2", "3"]);
    expect(flatTaskOrder(tasks, { sort: "creation" })).toEqual(["1", "2", "3"]);
  });

  it("orders by activity like the creation order, oldest first", () => {
    const tasks = [
      task(1, { lastActive: 500 }),
      task(2, { lastActive: 100 }),
      task(3, { lastActive: 900 }),
    ];
    expect(flatTaskOrder(tasks, activity)).toEqual(["2", "1", "3"]);
  });

  it("counts a parent as active as its most recently active descendant", () => {
    // 1 is stale itself, but its grandchild 3 is the newest work anywhere
    const tasks = [
      task(1, { lastActive: 100 }),
      task(2, { lastActive: 100, parentTid: 1 }),
      task(3, { lastActive: 900, parentTid: 2 }),
      task(4, { lastActive: 500 }),
    ];
    expect(flatTaskOrder(tasks, activity)).toEqual(["4", "1", "2", "3"]);
  });

  it("re-sorts siblings among themselves without reparenting", () => {
    const tasks = [
      task(1, { lastActive: 100 }),
      task(2, { lastActive: 800, parentTid: 1 }),
      task(3, { lastActive: 200, parentTid: 1 }),
    ];
    expect(flatTaskOrder(tasks, activity)).toEqual(["1", "3", "2"]);
  });

  it("keeps the creation order between equally active tasks", () => {
    const tasks = [
      task(1, { lastActive: 500 }),
      task(2, { lastActive: 500 }),
      task(3, { lastActive: 100 }),
    ];
    expect(flatTaskOrder(tasks, activity)).toEqual(["3", "1", "2"]);
  });

  it("leaves Archive and Import where the creation order has them", () => {
    const tasks = [
      task(1, { lastActive: 900 }),
      task(2, { lastActive: 100, archived: true }),
      task(3, { lastActive: 800, status: "importable" }),
      task(4, { lastActive: 50 }),
    ];
    expect(flatTaskOrder(tasks, activity)).toEqual([
      "archive",
      "2",
      "import",
      "3",
      "4",
      "1",
    ]);
  });
});

describe("sidebar newest-first order", () => {
  const newestFirst = { order: "newest_first" } as const;

  it("mirrors every level, Archive and Import sinking to the end", () => {
    const tasks = [
      task(1),
      task(2, { parentTid: 1 }),
      task(3, { parentTid: 1 }),
      task(4, { archived: true }),
      task(5, { status: "importable" }),
      task(6),
    ];
    expect(flatTaskOrder(tasks)).toEqual([
      "archive",
      "4",
      "import",
      "5",
      "1",
      "2",
      "3",
      "6",
    ]);
    expect(flatTaskOrder(tasks, newestFirst)).toEqual([
      "6",
      "1",
      "3",
      "2",
      "import",
      "5",
      "archive",
      "4",
    ]);
  });

  it("puts the most recently active first when sorting by activity", () => {
    const tasks = [
      task(1, { lastActive: 100 }),
      task(2, { lastActive: 900, parentTid: 1 }),
      task(3, { lastActive: 500 }),
    ];
    expect(
      flatTaskOrder(tasks, { sort: "activity", order: "newest_first" }),
    ).toEqual(["1", "2", "3"]);
  });

  it("folds the oldest run of finished subtasks, which now trails", () => {
    const done = { status: "completed" };
    const tasks = [
      task(1),
      task(2, { parentTid: 1, ...done }),
      task(3, { parentTid: 1, ...done }),
      task(4, { parentTid: 1, alive: true }),
    ];
    const flat = flattenTree(
      buildTree(tasks, newestFirst),
      null,
      [],
      false,
      true,
    ).filter((item) => item.kind === "ordinary");
    expect(flat.map((i) => i.id)).toEqual(["1", "4", "subtasks:1"]);
    expect(flat[2]!.attentionTids).toEqual([3, 2]);
    // the summary is the parent's last row now, so its connector ends there
    expect(flat[1]!.guides & 1).toBe(1);
    expect(flat[2]!.guides & 1).toBe(0);
  });

  it("renders top-down with New Task first", () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    try {
      render(
        h(Sidebar, {
          tasks: [task(1, { title: "older" }), task(2, { title: "newer" })],
          tasksLoading: false,
          activeTaskId: "1",
          attention: new Set<number>(),
          onSelectTask: vi.fn(),
          onNewTask: vi.fn(),
          getTaskHref: (id: string) => `/task/${id}`,
          taskTypes: [],
          config: newestFirst,
        }),
        container,
      );
      const list = container.querySelector(".sidebar-list")!;
      expect(list.classList.contains("newest-first")).toBe(true);
      const rows = [...list.children].map((row) => row.textContent);
      expect(rows).toEqual(["New Task", "newer", "older"]);
    } finally {
      render(null, container);
      container.remove();
    }
  });

  it("keeps the bottom-up DOM order by default", () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    try {
      render(
        h(Sidebar, {
          tasks: [task(1, { title: "older" }), task(2, { title: "newer" })],
          tasksLoading: false,
          activeTaskId: "1",
          attention: new Set<number>(),
          onSelectTask: vi.fn(),
          onNewTask: vi.fn(),
          getTaskHref: (id: string) => `/task/${id}`,
          taskTypes: [],
        }),
        container,
      );
      const list = container.querySelector(".sidebar-list")!;
      expect(list.classList.contains("newest-first")).toBe(false);
      // column-reverse shows this bottom to top: older, newer, New Task
      const rows = [...list.children].map((row) => row.textContent);
      expect(rows).toEqual(["New Task", "newer", "older"]);
    } finally {
      render(null, container);
      container.remove();
    }
  });
});
