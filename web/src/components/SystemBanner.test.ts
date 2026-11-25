/** @vitest-environment jsdom */

import { h, options } from "preact";
import { act } from "preact/test-utils";
import { describe, expect, it, vi } from "vitest";
import { ownedRoots } from "../test-support/preactAct";
import { reduceMessage } from "../sessionReducer";
import { makeTaskState } from "../types";
import styles from "../styles.css?inline";
import {
  isCompactingStatus,
  normalizeSessionStatus,
  SystemBanner,
} from "./SystemBanner";
describe("SystemBanner status helpers", () => {
  it("recognizes codex compacting status strings", () => {
    expect(isCompactingStatus("compacting")).toBe(true);
    expect(isCompactingStatus("Compacting context...")).toBe(true);
  });

  it("does not treat non-compacting statuses as compacting", () => {
    expect(isCompactingStatus("requesting")).toBe(false);
    expect(isCompactingStatus("compacted")).toBe(false);
  });

  it("normalizes empty status strings to null", () => {
    expect(normalizeSessionStatus("")).toBeNull();
    expect(normalizeSessionStatus("   ")).toBeNull();
    expect(normalizeSessionStatus("requesting")).toBe("requesting");
  });
});

describe("task bar", () => {
  const roots = ownedRoots();
  const defaults = {
    connected: true,
    tasksLoading: false,
    theme: "dark",
    onToggleTheme: () => {},
  } as const;
  const bar = (props: Partial<Parameters<typeof SystemBanner>[0]> = {}) =>
    h(SystemBanner, { ...defaults, ...props });

  it.each([
    [false, true, "disconnected", "Disconnected"],
    [true, true, "loading", "Loading…"],
    [true, false, "connected", "Claude Code"],
  ] as const)(
    "exposes connection state %s/%s without connection or processing text",
    (connected, tasksLoading, connection, tooltip) => {
      const root = roots.create();
      roots.render(
        bar({
          connected,
          tasksLoading,
          tid: 42,
          title: "Review task",
          agentName: "claude",
          agentDisplayName: "Claude Code",
        }),
        root,
      );

      const taskBar = root.querySelector(".task-bar")!;
      expect(taskBar.getAttribute("data-connection")).toBe(connection);
      expect(taskBar.querySelector(".task-bar-title")?.textContent).toBe(
        "Review task",
      );
      const agent = taskBar.querySelector(".task-bar-agent")!;
      expect(agent.getAttribute("title")).toBe(tooltip);
      expect(agent.textContent).toBe("claude");
      expect(taskBar.textContent).not.toMatch(
        /CyDo|disconnected|connected|loading|processing|ending/i,
      );
      expect(taskBar.lastElementChild?.matches(".theme-toggle")).toBe(true);
    },
  );

  it.each(["claude", "codex", "copilot"] as const)(
    "marks the agent chip with the %s driver",
    (agentDriver) => {
      const root = roots.create();
      const agent = { agentName: "reviewer", agentDriver };
      roots.render(bar(agent), root);

      const chip = root.querySelector(".task-bar-agent");
      expect(chip?.textContent).toBe("reviewer");
      expect(chip?.getAttribute("data-driver")).toBe(agentDriver);
    },
  );

  it("uses the exported lifecycle slot and keeps the theme toggle last", () => {
    const root = roots.create();
    roots.render(
      bar({ exportMode: true, alive: true, canStop: true, connected: false }),
      root,
    );

    const taskBar = root.querySelector(".task-bar")!;
    expect(taskBar.hasAttribute("data-connection")).toBe(false);
    expect(taskBar.querySelector(".task-bar-exported")?.textContent).toBe(
      "Exported",
    );
    expect(
      taskBar.querySelector(
        ".btn-banner-end, .btn-banner-stop, .btn-banner-resume, .btn-banner-archive",
      ),
    ).toBeNull();
    expect(taskBar.lastElementChild?.matches(".theme-toggle")).toBe(true);
  });

  it.each([
    [true, ["End", "Kill"]],
    [false, ["Resume", "Archive"]],
  ] as const)("shows lifecycle actions when alive is %s", (alive, actions) => {
    const root = roots.create();
    roots.render(
      bar({
        alive,
        canStop: true,
        resumable: true,
        onResume: vi.fn(),
        onSetArchived: vi.fn(),
      }),
      root,
    );
    expect(
      Array.from(
        root.querySelectorAll('button[class^="btn-banner-"]'),
        (button) => button.textContent,
      ),
    ).toEqual(actions);
  });

  it("copies the bare task number", async () => {
    const root = roots.create();
    const writeText = vi.fn().mockResolvedValue(undefined);
    const clipboard = Object.getOwnPropertyDescriptor(navigator, "clipboard");
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText },
    });
    try {
      roots.render(bar({ tid: 42 }), root);
      const id = root.querySelector<HTMLButtonElement>(".task-bar-id")!;
      expect(id.textContent).toBe("#42");
      await act(() => {
        id.click();
      });
      expect(writeText).toHaveBeenCalledWith("42");
    } finally {
      if (clipboard) Object.defineProperty(navigator, "clipboard", clipboard);
      else Reflect.deleteProperty(navigator, "clipboard");
    }
  });

  it("uses an ellipsis for the title and retains its full tooltip", () => {
    const root = roots.create();
    roots.render(bar({ title: "A long task title" }), root);
    const title = root.querySelector(".task-bar-title");
    expect(title?.textContent).toBe("A long task title");
    expect(title?.getAttribute("title")).toBe("A long task title");
    expect(styles).toMatch(
      /\.task-bar-title\s*\{[^}]*text-overflow:\s*ellipsis/,
    );
  });

  it("shows an actionable file count only when files are tracked", async () => {
    const root = roots.create();
    const onToggleFiles = vi.fn();
    roots.render(bar({ onToggleFiles }), root);
    expect(root.querySelector(".task-bar-files")).toBeNull();

    roots.render(bar({ trackedFileCount: 2, onToggleFiles }), root);
    const files = root.querySelector<HTMLButtonElement>(
      '[aria-label="Files 2"]',
    )!;
    await act(() => {
      files.click();
    });
    expect(onToggleFiles).toHaveBeenCalledOnce();
  });

  it("uses an SVG icon in the Files button", () => {
    const root = roots.create();
    roots.render(bar({ trackedFileCount: 2 }), root);

    const files = root.querySelector('[aria-label="Files 2"]');
    expect(files?.querySelector(".action-icon svg")).toBeTruthy();
    expect(files?.textContent).not.toContain("⎘");
  });

  it("opens task details and closes them on Escape", async () => {
    const root = roots.create();
    roots.render(bar({ tid: 42 }), root);
    const toggle = root.querySelector<HTMLButtonElement>(
      ".task-bar-panel-toggle",
    )!;
    expect(root.querySelector(".task-panel")).toBeNull();
    await act(() => {
      toggle.click();
    });
    expect(toggle.getAttribute("aria-expanded")).toBe("true");
    expect(root.querySelector(".task-panel")).not.toBeNull();
    await act(() => {
      document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }));
    });
    expect(toggle.getAttribute("aria-expanded")).toBe("false");
    expect(root.querySelector(".task-panel")).toBeNull();
  });

  it.each([
    new MouseEvent("click", { bubbles: true }),
    new KeyboardEvent("keydown", { key: "Escape", bubbles: true }),
  ])("closes on %s before passive effects run", async (event) => {
    const root = roots.create();
    roots.render(bar({ tid: 42 }), root);
    const toggle = root.querySelector<HTMLButtonElement>(
      ".task-bar-panel-toggle",
    )!;

    await act(() => {
      const schedule = Object.getOwnPropertyDescriptor(
        options,
        "debounceRendering",
      )!;
      options.debounceRendering = (flush) => {
        flush();
      };
      try {
        toggle.click();
        expect(root.querySelector(".task-panel")).not.toBeNull();
        document.body.dispatchEvent(event);
        expect(root.querySelector(".task-panel")).toBeNull();
      } finally {
        Object.defineProperty(options, "debounceRendering", schedule);
      }
    });
  });

  it.each([
    [".task-bar-files", "onToggleFiles"],
    [".theme-toggle", "onToggleTheme"],
  ] as const)(
    "closes when %s is clicked and still runs its action",
    async (selector, prop) => {
      const root = roots.create();
      const action = vi.fn();
      roots.render(bar({ tid: 42, trackedFileCount: 1, [prop]: action }), root);
      const toggle = root.querySelector<HTMLButtonElement>(
        ".task-bar-panel-toggle",
      )!;
      await act(() => {
        toggle.click();
      });
      expect(root.querySelector(".task-panel")).not.toBeNull();

      await act(() => {
        root.querySelector<HTMLButtonElement>(selector)!.click();
      });
      expect(root.querySelector(".task-panel")).toBeNull();
      expect(action).toHaveBeenCalledOnce();
    },
  );

  it("updates the open panel with details from the latest session init", async () => {
    const root = roots.create();
    const init = {
      type: "session/init",
      agent: "claude",
      model: "sonnet",
      agent_version: "1.0.0",
      session_id: "session-42",
      cwd: "/worktree",
      permission_mode: "acceptEdits",
      tools: ["Read"],
      mcp_servers: [{ name: "project-mcp", status: "connected" }],
      supports_file_revert: false,
    } as const;
    const first = reduceMessage(makeTaskState(42), {
      ...init,
      tools: [...init.tools],
      mcp_servers: [...init.mcp_servers],
    });
    const props = { tid: 42, taskType: "implement", cost: 0.25 };
    roots.render(bar({ ...props, sessionInfo: first.sessionInfo }), root);
    await act(() => {
      root.querySelector<HTMLButtonElement>(".task-bar-panel-toggle")!.click();
    });
    const panel = root.querySelector(".task-panel")!;
    expect(panel.textContent).toContain("implement");
    expect(panel.textContent).toContain("$0.2500");
    const session = panel.querySelector("details")!;
    expect(session.querySelector("summary")?.textContent).toBe("Session");
    for (const value of [
      "session-42",
      "1.0.0",
      "/worktree",
      "acceptEdits",
      "Read",
      "project-mcp",
    ]) {
      expect(session.textContent).toContain(value);
    }

    const second = reduceMessage(first, {
      ...init,
      agent_version: "2.0.0",
      tools: [],
      mcp_servers: [],
    });
    roots.render(bar({ ...props, sessionInfo: second.sessionInfo }), root);
    expect(panel.querySelector("details")?.textContent).toContain("2.0.0");
    expect(panel.querySelector("details")?.textContent).not.toContain("1.0.0");
  });
});
