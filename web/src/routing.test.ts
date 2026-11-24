import { describe, expect, it } from "vitest";
import {
  buildProjectHref,
  buildScopedHref,
  canonicalTaskRedirect,
  decodeProjectSegment,
  encodeProjectName,
  parseRoute,
  taskPath,
} from "./routing";

describe("encodeProjectName", () => {
  it("replaces slashes with colons", () => {
    expect(encodeProjectName("a/b")).toBe("a:b");
  });
});

describe("decodeProjectSegment", () => {
  it("replaces colons with slashes", () => {
    expect(decodeProjectSegment("a:b")).toBe("a/b");
  });
});

describe("parseRoute", () => {
  const cases: [string, ReturnType<typeof parseRoute>][] = [
    ["/", { workspace: null, project: null, tid: null }],
    ["/task/32639", { workspace: null, project: null, tid: "32639" }],
    [
      "/cydo/cydo/task/32639",
      { workspace: "cydo", project: "cydo", tid: "32639" },
    ],
    [
      "/local/foo:bar/task/7",
      { workspace: "local", project: "foo/bar", tid: "7" },
    ],
    ["/archive", { workspace: null, project: null, tid: "archive" }],
    ["/archive/5", { workspace: null, project: null, tid: "archive:5" }],
    [
      "/cydo/cydo/archive",
      { workspace: "cydo", project: "cydo", tid: "archive" },
    ],
    [
      "/cydo/cydo/archive/9",
      { workspace: "cydo", project: "cydo", tid: "archive:9" },
    ],
    [
      "/cydo/cydo/import",
      { workspace: "cydo", project: "cydo", tid: "import" },
    ],
    [
      "/cydo/archive/task/5",
      { workspace: "cydo", project: "archive", tid: "5" },
    ],
    ["/cydo/import/task/5", { workspace: "cydo", project: "import", tid: "5" }],
    [
      "/local/foo%3Abar/session/abc%201/",
      { workspace: "local", project: "foo/bar", tid: "abc 1" },
    ],
    ["/local/project", { workspace: "local", project: "project", tid: null }],
    ["/local/project/unknown", { workspace: null, project: null, tid: null }],
    ["/import", { workspace: null, project: null, tid: "import" }],
  ];

  it.each(cases)("parses %s", (path, expected) => {
    expect(parseRoute(path)).toEqual(expected);
  });
});

describe("buildProjectHref", () => {
  it("builds a workspace/project href", () => {
    expect(buildProjectHref("ws", "a/b")).toBe("/ws/a:b");
  });
});

describe("taskPath", () => {
  it("builds a task href under the project", () => {
    expect(taskPath("ws", "a/b", 7)).toBe("/ws/a:b/task/7");
  });
});

describe("buildScopedHref", () => {
  it("keeps an unresolvable task at the unscoped /task/<tid> href", () => {
    const currentWorkspace = "current-workspace";
    const currentProject = "current-project";
    const href = buildScopedHref(null, null, "/task/32639");

    expect(href).toBe("/task/32639");
    expect(href).not.toContain(currentWorkspace);
    expect(href).not.toContain(currentProject);
  });

  it("scopes the suffix under the workspace/project href", () => {
    expect(buildScopedHref("ws", "p", "/archive")).toBe("/ws/p/archive");
  });
});

describe("canonicalTaskRedirect", () => {
  it("returns null when the URL is already canonical", () => {
    expect(
      canonicalTaskRedirect({
        tid: 7,
        taskWorkspace: "ws",
        taskProject: "proj",
        urlWorkspace: "ws",
        urlProject: "proj",
      }),
    ).toBeNull();
  });

  it("redirects a legacy /task/<tid> URL to the canonical path", () => {
    expect(
      canonicalTaskRedirect({
        tid: 7,
        taskWorkspace: "ws",
        taskProject: "proj",
        urlWorkspace: null,
        urlProject: null,
      }),
    ).toBe("/ws/proj/task/7");
  });

  it("redirects a URL naming the wrong scope to the correct path", () => {
    expect(
      canonicalTaskRedirect({
        tid: 7,
        taskWorkspace: "ws",
        taskProject: "proj",
        urlWorkspace: "bogus-ws",
        urlProject: "bogus-proj",
      }),
    ).toBe("/ws/proj/task/7");
  });

  it("returns null when the task's workspace cannot be resolved", () => {
    expect(
      canonicalTaskRedirect({
        tid: 7,
        taskWorkspace: null,
        taskProject: "proj",
        urlWorkspace: "ws",
        urlProject: "proj",
      }),
    ).toBeNull();
  });

  it("returns null when the task's project cannot be resolved", () => {
    expect(
      canonicalTaskRedirect({
        tid: 7,
        taskWorkspace: "ws",
        taskProject: null,
        urlWorkspace: "ws",
        urlProject: "proj",
      }),
    ).toBeNull();
  });

  it("returns null for a project name containing '/' whose URL segment is already decoded", () => {
    expect(
      canonicalTaskRedirect({
        tid: 7,
        taskWorkspace: "ws",
        taskProject: "a/b",
        urlWorkspace: "ws",
        urlProject: "a/b",
      }),
    ).toBeNull();
  });

  it("is a fixed point for a project name containing ':' (loop guard)", () => {
    expect(
      canonicalTaskRedirect({
        tid: 7,
        taskWorkspace: "ws",
        taskProject: "a:b",
        urlWorkspace: "ws",
        urlProject: "a/b",
      }),
    ).toBeNull();
  });
});
