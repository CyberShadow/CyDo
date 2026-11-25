// @vitest-environment jsdom
import { act } from "preact/test-utils";
import { ownedRoots } from "../test-support/preactAct";
import { describe, expect, it, vi } from "vitest";
import renderToString from "preact-render-to-string";
import { makeTaskState, type TaskState } from "../types";
import { createOrdinaryDraftStore } from "../ordinaryDraftStore";
import type { AgentUsageMessage } from "../protocol";

vi.hoisted(() => {
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
    }
  },
);
