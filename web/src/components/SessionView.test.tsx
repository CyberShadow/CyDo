// @vitest-environment jsdom
import { act } from "preact/test-utils";
import { ownedRoots } from "../test-support/preactAct";
import { describe, expect, it, vi } from "vitest";
import renderToString from "preact-render-to-string";
import { reduceMessage } from "../sessionReducer";
import { resetTaskForHistoryReplay } from "../historyReplayReset";
import { makeTaskState, type TaskState } from "../types";
import { createOrdinaryDraftStore } from "../ordinaryDraftStore";
import type { AgentUsageMessage } from "../protocol";

vi.hoisted(() => {
  vi.stubGlobal(
    "IntersectionObserver",
    class {
      observe() {}
      disconnect() {}
    },
  );
  vi.stubGlobal("CSS", { supports: () => false });
  vi.stubGlobal("matchMedia", () => ({
    matches: true,
    addEventListener() {},
    removeEventListener() {},
  }));
});

import { SessionView, UndoConfirmDialog } from "./SessionView";

const roots = ownedRoots();

function session(
  undoPending: TaskState["undoPending"],
  state: Partial<TaskState> = {},
  exportMode = false,
  agentUsage?: Record<string, AgentUsageMessage>,
) {
  return (
    <SessionView
      task={{ ...makeTaskState(7), undoPending, ...state }}
      agentUsage={agentUsage}
      connected={true}
      tasksLoading={false}
      isActive={true}
      exportMode={exportMode}
      onSend={() => {}}
      onInterrupt={() => {}}
      onStop={() => {}}
      onCloseStdin={() => {}}
      onResume={() => {}}
      onFork={() => {}}
      onUndo={() => {}}
      onUndoConfirm={() => {}}
      onUndoDismiss={() => {}}
      onEditMessage={() => {}}
      onEditRawEvent={() => {}}
      onClearInputDraft={() => {}}
      ordinaryDraftStore={createOrdinaryDraftStore()}
      onAskUserResponse={() => {}}
      onPermissionPromptResponse={() => {}}
      theme="dark"
      onToggleTheme={() => {}}
      onToggleSidebar={() => {}}
    />
  );
}

function renderSession(
  undoPending: TaskState["undoPending"],
  state: Partial<TaskState> = {},
  agentUsage?: Record<string, AgentUsageMessage>,
) {
  return renderToString(session(undoPending, state, false, agentUsage));
}

describe("SessionView usage", () => {
  const usage = (profile: string, utilization: number): AgentUsageMessage => ({
    type: "agent_usage",
    profile,
    updated_at: 1,
    limits: { five_hour: { utilization } },
  });
  const profile = "/profiles/work";
  const agentUsage = {
    claude: usage("claude", 71),
    [profile]: usage(profile, 42),
  };

  it("shows usage only for the task's matching profile", () => {
    const html = renderSession(null, { usageProfile: profile }, agentUsage);

    expect(html).toContain('class="banner-usage-value">42%</span>');
    expect(html).not.toContain('class="banner-usage-value">71%</span>');
  });

  it("omits the usage widget for a task without a profile", () => {
    expect(renderSession(null, {}, agentUsage)).not.toContain("banner-usage");
  });
});

it("keeps raw inspection but hides history mutations on import offers", () => {
  const state: Partial<TaskState> = {
    historyLoaded: true,
    messages: [
      { id: "prompt", type: "user", content: [], seq: 1, rawSource: {} },
    ],
    replacementEvents: new Map([
      [
        1,
        {
          type: "item/started",
          item_id: "prompt",
          item_type: "user_message",
          history_boundary: { anchor: "before:turn", kind: "user" },
        },
      ],
    ]),
    historyOperations: {
      fork: { first_user: "jsonl" },
      undo: { first_user: "jsonl" },
      edit_message: true,
      edit_raw_event: true,
    },
  };
  const imported = renderSession(null, { ...state, status: "completed" });
  const offer = renderSession(null, { ...state, status: "importable" });

  for (const action of ["fork-btn", "undo-btn", "Edit message"]) {
    expect(imported).toContain(action);
    expect(offer).not.toContain(action);
  }
  expect(offer).toContain("View source");
});

describe("UndoConfirmDialog", () => {
  const render = (props: Partial<Parameters<typeof UndoConfirmDialog>[0]>) =>
    renderToString(
      <UndoConfirmDialog
        messagesRemoved={1}
        countUnit="history_entries"
        canRevertFiles={false}
        retainsPrompt={false}
        supportsFileRevert={true}
        onConfirm={() => {}}
        onDismiss={() => {}}
        {...props}
      />,
    );

  it("enables and checks file revert only for the selected checkpoint", () => {
    const html = render({ canRevertFiles: true });
    expect(html).toContain("checked");
    expect(html).not.toContain("disabled");
  });

  it("explains unavailable file revert for each selected point", () => {
    expect(render({ retainsPrompt: true })).toContain(
      "this response has no file checkpoint",
    );
    expect(render({})).toContain(
      "this point has no file checkpoint and cannot restore files",
    );
    expect(render({ supportsFileRevert: false })).toContain(
      "not supported for this agent type",
    );
  });
});

describe("SessionView undo pending", () => {
  it("hides a requesting undo", () => {
    const html = renderSession({
      anchor: "boundary-7",
      kind: "requesting",
      canRevertFiles: false,
      retainsPrompt: false,
    });

    expect(html).not.toContain("undo-dialog");
    expect(html).not.toContain("undo-dialog-count");
  });

  it("explains that undoing a user target removes it and restores its prompt", () => {
    const html = renderSession({
      anchor: "boundary-7",
      kind: "history_entries",
      messagesRemoved: 1,
      canRevertFiles: false,
      retainsPrompt: false,
    });

    expect(html).toContain("undo-dialog");
    expect(html).not.toContain("Undo to this point?");
    expect(html).toContain("This message and later history will be removed.");
    expect(html).toContain("Its prompt will return to the composer.");
    expect(html).toContain("1 message will be removed.");
  });

  it("describes a native Codex preview as whole turns and retains its prompt", () => {
    const html = renderSession({
      anchor: "boundary-7",
      kind: "codex_turns",
      messagesRemoved: 2,
      canRevertFiles: false,
      retainsPrompt: true,
    });

    expect(html).toContain("undo-dialog");
    expect(html).not.toContain("Undo to this point?");
    expect(html).toContain("This response and later history will be removed.");
    expect(html).toContain("The preceding prompt will remain.");
    expect(html).toContain("2 whole turns will be removed.");
  });
});

it.each([
  ["an exported session", true, "/w/report.md", "/w/app.d"],
  ["a session with an empty cwd", false, "report.md", "app.d"],
] as const)(
  "renders assistant local embeds inert in %s",
  async (_name, exported, report, source) => {
    const previousObserver = globalThis.IntersectionObserver;
    vi.stubGlobal(
      "IntersectionObserver",
      class {
        constructor(
          private readonly callback: (
            entries: { isIntersecting: boolean }[],
          ) => void,
        ) {}

        observe() {
          this.callback([{ isIntersecting: true }]);
        }
        disconnect() {}
      },
    );
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockImplementation(() => new Promise(() => {}));
    const root = roots.create();

    try {
      await act(() => {
        roots.render(
          session(
            null,
            {
              historyLoaded: true,
              status: "completed",
              sessionInfo: {
                sessionId: "sid",
                model: "claude-sonnet",
                version: "1.0.0",
                cwd: exported ? "/w" : "",
                tools: [],
                permission_mode: "default",
                supports_file_revert: false,
              },
              messages: [
                {
                  id: "reply",
                  type: "assistant",
                  content: [],
                  blockIds: ["text"],
                },
              ],
              blocks: new Map([
                [
                  "text",
                  {
                    itemId: "text",
                    type: "text",
                    text: `![Local report](${report}) [Source](${source})`,
                    completed: true,
                    creationOrder: 0,
                  },
                ],
              ]),
            },
            exported,
          ),
          root,
        );
      });

      const markdown = root.querySelector(".assistant-message .markdown")!;
      expect(
        Array.from(
          markdown.querySelectorAll("span.local-file-link-inert"),
          (span) => span.textContent,
        ),
      ).toEqual(["Local report", "Source"]);
      expect(markdown.querySelector("a, img, button, figure")).toBeNull();
      expect(fetchMock).not.toHaveBeenCalled();
    } finally {
      fetchMock.mockRestore();
      vi.stubGlobal("IntersectionObserver", previousObserver);
    }
  },
);

describe("SessionView linked files", () => {
  const report = "/w/report.md";
  const notes = "/w/notes.md";

  function linkedSession() {
    const task = makeTaskState(7, false, false, undefined, true);
    task.status = "completed";
    task.messages = [
      { id: "reply", type: "assistant", content: [], blockIds: ["text"] },
    ];
    task.blocks.set("text", {
      itemId: "text",
      type: "text",
      text: `[Report](${report}) [Notes](${notes})`,
      completed: true,
      creationOrder: 0,
    });
    return task;
  }

  async function click(root: HTMLElement, selector: string) {
    await act(() => {
      const button = root.querySelector<HTMLButtonElement>(selector);
      expect(button).not.toBeNull();
      button!.click();
    });
  }

  function openLink(root: HTMLElement, path: string) {
    return click(root, `button[aria-label="Open ${path} in the file viewer"]`);
  }

  function selectedPath(root: HTMLElement) {
    return root
      .querySelector(".file-tree-item.selected")
      ?.getAttribute("title");
  }

  it("opens a link in Live and keeps its tree entry when reopened via another link", async () => {
    const root = roots.create();
    const task = linkedSession();
    roots.render(session(null, task), root);
    await openLink(root, report);
    expect(selectedPath(root)).toBe(report);
    expect(
      root.querySelector(".content-viewer-tabs .active")?.textContent,
    ).toBe("Live");

    await click(root, ".file-viewer-close");
    expect(root.querySelector(".file-viewer")).toBeNull();

    await openLink(root, notes);
    expect(selectedPath(root)).toBe(notes);
    expect(
      root.querySelectorAll(`.file-tree-item[title="${report}"]`),
    ).toHaveLength(1);
  });

  it("opens a relative Markdown link in the same entry as a tracked edit", async () => {
    const root = roots.create();
    let task = reduceMessage(linkedSession(), {
      type: "session/init",
      model: "claude-sonnet",
      agent_version: "1.0.0",
      session_id: "sid",
      cwd: "/w",
      tools: [],
      permission_mode: "default",
      agent: "claude",
      supports_file_revert: false,
    });
    task = reduceMessage(task, {
      type: "item/started",
      item_type: "tool_use",
      item_id: "write-report",
      name: "Write",
      input: { file_path: "./docs/report.md", content: "# Report" },
    });
    task = reduceMessage(task, {
      type: "item/result",
      item_id: "write-report",
      content: [],
    });
    task = reduceMessage(task, {
      type: "item/started",
      item_type: "text",
      item_id: "link-report",
      text: "[Report](docs/report.md)",
    });
    roots.render(session(null, task), root);

    const path = "/w/docs/report.md";
    await click(root, 'button[title="View file"]');
    expect(selectedPath(root)).toBe(path);
    await openLink(root, path);
    expect(selectedPath(root)).toBe(path);
    expect(root.querySelectorAll(".file-tree-item")).toHaveLength(1);
    expect(
      Array.from(
        root.querySelectorAll(".content-viewer-tabs button"),
        (tab) => tab.textContent,
      ),
    ).toEqual(["Source", "Diff", "Cumulative", "Rendered", "Live"]);
    expect(
      root.querySelector(".content-viewer-tabs .active")?.textContent,
    ).toBe("Live");
  });

  it("keeps edit-derived views available without Live in an exported session", async () => {
    const root = roots.create();
    const initial = { ...linkedSession(), driver: "claude" as const };
    let task = reduceMessage(initial, {
      type: "item/started",
      item_type: "tool_use",
      item_id: "write-export",
      name: "Write",
      input: { file_path: report, content: "# Exported edit" },
    });
    task = reduceMessage(task, {
      type: "item/result",
      item_id: "write-export",
      content: [],
    });

    const fetchMock = vi.spyOn(globalThis, "fetch");
    try {
      roots.render(session(null, task, true), root);
      await click(root, 'button[title="View file"]');
      expect(selectedPath(root)).toBe(report);
      expect(
        Array.from(
          root.querySelectorAll(".content-viewer-tabs button"),
          (tab) => tab.textContent,
        ),
      ).toEqual(["Source", "Diff", "Cumulative", "Rendered"]);
      expect(root.querySelector(".edit-history")).not.toBeNull();
      expect(fetchMock).not.toHaveBeenCalled();
    } finally {
      fetchMock.mockRestore();
    }
  });

  it("keeps a linked selection open when replay clears its tracked entry", async () => {
    const root = roots.create();
    const task = linkedSession();
    task.trackedFiles.set(report, {
      path: report,
      edits: [
        {
          toolUseId: "write",
          messageId: "reply",
          filePath: report,
          type: "write",
          op: "add",
          status: "applied",
          source: "claude-tool",
          payload: { mode: "full_content", content: "# Original edit" },
        },
      ],
    });
    roots.render(session(null, task), root);
    await openLink(root, report);
    expect(selectedPath(root)).toBe(report);

    roots.render(session(null, resetTaskForHistoryReplay(task, 1)), root);
    expect(selectedPath(root)).toBe(report);
    expect(
      root.querySelector(".content-viewer-tabs .active")?.textContent,
    ).toBe("Live");
  });
});
