/** @vitest-environment jsdom */

import { h, render } from "preact";
import { act } from "preact/test-utils";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { makeTaskState, type TaskState } from "../types";
import type { WorkspaceInfo } from "../useSessionManager";
import { sortFilteredWorkspaceGroups, WelcomePage } from "./WelcomePage";

type FilteredWorkspaceGroups = Parameters<
  typeof sortFilteredWorkspaceGroups
>[0];
type FilteredWorkspaceGroup = FilteredWorkspaceGroups[number];
type ProjectMatch = FilteredWorkspaceGroup["projects"][number];

function makeProjectMatch(
  workspaceName: string,
  projectName: string,
  options: { active?: boolean; maxLastActive?: number } = {},
): ProjectMatch {
  const { active = false, maxLastActive = 0 } = options;
  return {
    project: {
      name: projectName,
      path: `/tmp/${workspaceName}/${projectName}`,
    },
    tasks: [],
    active,
    maxLastActive,
  };
}

function makeWorkspaceGroup(
  workspaceName: string,
  projects: ProjectMatch[],
): FilteredWorkspaceGroup {
  return {
    workspace: {
      name: workspaceName,
      projects: projects.map(({ project }) => project),
    },
    projects,
  };
}

function workspaceOrder(groups: FilteredWorkspaceGroups): string[] {
  return groups.map((group) => group.workspace.name);
}

describe("sortFilteredWorkspaceGroups", () => {
  it("sorts filtered workspaces by the best visible project across groups", () => {
    const groups: FilteredWorkspaceGroups = [
      makeWorkspaceGroup("Recent Inactive", [
        makeProjectMatch("Recent Inactive", "match-zeta", {
          active: false,
          maxLastActive: 300,
        }),
      ]),
      makeWorkspaceGroup("Older Active", [
        makeProjectMatch("Older Active", "match-beta", {
          active: true,
          maxLastActive: 100,
        }),
      ]),
      makeWorkspaceGroup("Newest Active", [
        makeProjectMatch("Newest Active", "match-alpha", {
          active: true,
          maxLastActive: 400,
        }),
      ]),
    ];

    const sorted = sortFilteredWorkspaceGroups([...groups], "match");

    expect(workspaceOrder(sorted)).toEqual([
      "Newest Active",
      "Older Active",
      "Recent Inactive",
    ]);
  });

  it("preserves the original workspace order when the filter is empty", () => {
    const groups: FilteredWorkspaceGroups = [
      makeWorkspaceGroup("Zulu", [
        makeProjectMatch("Zulu", "project-zulu", {
          active: false,
          maxLastActive: 1,
        }),
      ]),
      makeWorkspaceGroup("Alpha", [
        makeProjectMatch("Alpha", "project-alpha", {
          active: true,
          maxLastActive: 999,
        }),
      ]),
    ];

    const sorted = sortFilteredWorkspaceGroups(groups, "");

    expect(workspaceOrder(sorted)).toEqual(["Zulu", "Alpha"]);
  });

  it("uses project and workspace names as deterministic tie-breakers", () => {
    const groups: FilteredWorkspaceGroups = [
      makeWorkspaceGroup("Zulu Workspace", [
        makeProjectMatch("Zulu Workspace", "alpha-project", {
          active: false,
          maxLastActive: 200,
        }),
      ]),
      makeWorkspaceGroup("Bravo Workspace", [
        makeProjectMatch("Bravo Workspace", "beta-project", {
          active: false,
          maxLastActive: 200,
        }),
      ]),
      makeWorkspaceGroup("Alpha Workspace", [
        makeProjectMatch("Alpha Workspace", "alpha-project", {
          active: false,
          maxLastActive: 200,
        }),
      ]),
    ];

    const sorted = sortFilteredWorkspaceGroups([...groups], "project");

    expect(workspaceOrder(sorted)).toEqual([
      "Alpha Workspace",
      "Zulu Workspace",
      "Bravo Workspace",
    ]);
  });
});

describe("WelcomePage task loading", () => {
  let container: HTMLDivElement;
  const workspace: WorkspaceInfo = {
    name: "Workspace",
    projects: [{ name: "Project", path: "/project" }],
  };

  const mount = (tasks: Map<string, TaskState>, tasksLoaded: boolean) => {
    void act(() => {
      render(
        h(WelcomePage, {
          workspaces: [workspace],
          tasks,
          tasksLoaded,
          attention: new Set<number>(),
          onSelectTask: () => {},
          onNavigateToProject: () => {},
          getProjectHref: () => "/workspace/project",
          getTaskHref: (id: string) => `/task/${id}`,
          taskTypes: [],
          notices: {},
          onRefreshWorkspaces: () => {},
          scanState: "idle",
        }),
        container,
      );
    });
  };

  beforeEach(() => {
    container = document.createElement("div");
    document.body.appendChild(container);
  });

  afterEach(() => {
    void act(() => {
      render(null, container);
    });
    container.remove();
  });

  it("labels an empty project as loading while task discovery is partial", () => {
    mount(new Map(), false);

    expect(container.querySelector(".project-card-empty")?.textContent).toBe(
      "Loading tasks…",
    );
  });

  it("labels an empty project as empty after task discovery is complete", () => {
    mount(new Map(), true);

    expect(container.querySelector(".project-card-empty")?.textContent).toBe(
      "No tasks yet",
    );
  });

  it("shows known tasks immediately while discovery is still partial", () => {
    const knownTask = makeTaskState(
      7,
      false,
      false,
      "Known partial task",
      false,
      "Workspace",
      "/project",
    );
    mount(new Map([[knownTask.uuid, knownTask]]), false);
    const taskLink = container.querySelector<HTMLAnchorElement>(
      ".project-card-sessions .sidebar-item",
    );

    expect(taskLink?.textContent).toContain("Known partial task");
    expect(taskLink?.getAttribute("href")).toBe("/workspace/project/task/7");
    expect(container.querySelector(".project-card-empty")).toBeNull();
  });
});
