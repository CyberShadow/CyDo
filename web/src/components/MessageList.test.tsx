/** @vitest-environment jsdom */

import { describe, expect, it, vi } from "vitest";
import { render } from "preact";
import { act } from "preact/test-utils";
import renderToString from "preact-render-to-string";
import { MessageList } from "./MessageList";
import { DevModeContext } from "../devMode";
import { makeTaskState, type DisplayMessage, type TaskState } from "../types";
import { reduceMessage } from "../sessionReducer";
import type { AgnosticEvent } from "../protocol";

describe("MessageList history editing", () => {
  it.each([{ edit_message: true }, { edit_raw_event: true }])(
    "gates edit controls independently for %j",
    async (editing) => {
      const root = document.createElement("div");
      const rawEvent = { type: "user", rawText: "original history entry" };
      const fetchRaw = vi
        .spyOn(globalThis, "fetch")
        .mockResolvedValue(Response.json(rawEvent));
      try {
        await act(() => {
          render(
            <MessageList
              taskTid={1}
              messages={[
                {
                  id: "user",
                  type: "user",
                  uuid: "user-uuid",
                  seq: 7,
                  content: [{ type: "text", text: "hello" }],
                  rawSource: { type: "item/started" },
                },
              ]}
              historyOperations={{ fork: {}, undo: {}, ...editing }}
              replacementEvents={new Map()}
              blocks={new Map()}
              isProcessing={false}
              bandStatus=""
              onEditMessage={() => {}}
              onEditRawEvent={() => {}}
            />,
            root,
          );
        });
        expect
          .soft(root.querySelector('[title="Edit message"]') !== null)
          .toBe(editing.edit_message === true);

        await act(() => {
          root
            .querySelector<HTMLButtonElement>('[title="View source"]')!
            .click();
        });
        await act(() => {
          root.querySelector<HTMLElement>(".source-event-header")!.click();
        });
        await act(() => {
          [...root.querySelectorAll("button")]
            .find((button) => button.textContent === "Raw")!
            .click();
        });
        await vi.waitFor(() => {
          expect(root.querySelector(".source-view pre")?.textContent).toContain(
            rawEvent.rawText,
          );
        });
        expect(root.querySelector('[title="Edit raw event"]') !== null).toBe(
          editing.edit_raw_event === true,
        );
      } finally {
        await act(() => {
          render(null, root);
        });
        fetchRaw.mockRestore();
      }
    },
  );
});

describe("MessageList parse-error rendering", () => {
  it("gives a multipart user message one wrapper and action/source owner", () => {
    const message: DisplayMessage = {
      id: "multipart-user",
      type: "user",
      content: [
        { type: "text", text: "first entry" },
        { type: "text", text: "second entry" },
      ],
      rawSource: { type: "user" },
      uuid: "user-uuid",
    };
    const html = renderToString(
      <MessageList
        taskTid={1}
        messages={[message]}
        replacementEvents={new Map()}
        blocks={new Map()}
        isProcessing={false}
        bandStatus=""
        onFork={() => {}}
        onUndo={() => {}}
      />,
    );

    expect(html.match(/class="message-wrapper/g)).toHaveLength(1);
    expect(html.match(/class="message-actions"/g)).toHaveLength(1);
    expect(html.match(/view-source-btn/g)).toHaveLength(1);
    expect(html.match(/class="message user-message(?:[^"]*)"/g)).toHaveLength(
      1,
    );
    expect(html.match(/class="user-content-item"/g)).toHaveLength(2);
  });

  it("renders nested multipart users as the same sequence of child boxes", () => {
    const html = renderToString(
      <MessageList
        taskTid={1}
        messages={[
          {
            id: "assistant",
            type: "assistant",
            content: [],
            blockIds: ["task-tool"],
          },
          {
            id: "nested-user",
            type: "user",
            parentToolUseId: "task-tool",
            content: [
              { type: "text", text: "nested first" },
              { type: "text", text: "nested second" },
            ],
          },
        ]}
        replacementEvents={new Map()}
        blocks={
          new Map([
            [
              "task-tool",
              {
                itemId: "task-tool",
                type: "tool_use" as const,
                name: "Task",
                text: "",
                input: {},
                completed: true,
                creationOrder: 0,
              },
            ],
          ])
        }
        isProcessing={false}
        bandStatus=""
      />,
    );

    expect(html).toContain("sub-agent-messages");
    expect(html.match(/class="message user-message(?:[^"]*)"/g)).toHaveLength(
      1,
    );
    expect(html.match(/class="user-content-item"/g)).toHaveLength(2);
    expect(html.indexOf("nested first")).toBeLessThan(
      html.indexOf("nested second"),
    );
  });

  it("puts user undo before the message and fork after it", () => {
    const user: DisplayMessage = { id: "u", type: "user", content: [], seq: 7 };
    const replacementEvents: Map<number, AgnosticEvent> = new Map([
      [
        7,
        {
          type: "item/started",
          item_type: "user_message",
          item_id: "",
          history_boundary: { anchor: "anchor", kind: "user" },
        },
      ],
    ]);
    const html = renderToString(
      <MessageList
        taskTid={1}
        messages={[user]}
        replacementEvents={replacementEvents}
        historyOperations={{
          fork: { first_user: "jsonl" },
          undo: { first_user: "jsonl" },
        }}
        blocks={new Map()}
        isProcessing={false}
        bandStatus=""
        onFork={() => {}}
        onUndo={() => {}}
      />,
    );
    const bottomRow = html.indexOf("message-actions-bottom");
    expect(bottomRow).toBeGreaterThan(0);
    expect(html.slice(0, bottomRow)).toContain("undo-btn");
    expect(html.slice(bottomRow)).toContain("fork-btn");
    expect(html.slice(bottomRow)).not.toContain("undo-btn");
    expect(html).toContain(
      'title="Undo this message and later history, restoring its prompt to the composer"',
    );
    expect(html).toContain(
      'aria-label="Undo this message and later history, restoring its prompt to the composer"',
    );
    expect(html).toContain('<svg xmlns="http://www.w3.org/2000/svg"');
    const noIdentity = renderToString(
      <MessageList
        taskTid={1}
        messages={[user]}
        replacementEvents={new Map()}
        blocks={new Map()}
        isProcessing={false}
        bandStatus=""
        onUndo={() => {}}
      />,
    );
    expect(noIdentity).not.toContain("undo-btn");
  });

  it("puts assistant undo before the response and fork after it", () => {
    const assistant: DisplayMessage = {
      id: "a",
      type: "assistant",
      content: [],
      seq: 9,
    };
    const render = (checkpointUuid?: string) =>
      renderToString(
        <MessageList
          taskTid={1}
          messages={[assistant]}
          replacementEvents={
            new Map([
              [
                9,
                {
                  type: "turn/stop",
                  history_boundary: {
                    anchor: "line:9",
                    kind: "agent_turn",
                    checkpoint_uuid: checkpointUuid,
                  },
                },
              ],
            ])
          }
          historyOperations={{
            fork: { agent_turn: "jsonl" },
            undo: { agent_turn: "jsonl" },
          }}
          blocks={new Map()}
          isProcessing={false}
          bandStatus=""
          onFork={() => {}}
          onUndo={() => {}}
        />,
      );
    const html = render();
    const bottomRow = html.indexOf("message-actions-bottom");
    expect(bottomRow).toBeGreaterThan(0);
    expect(html.slice(0, bottomRow)).toContain("undo-btn");
    expect(html.slice(bottomRow)).toContain("fork-btn");
    expect(html.slice(bottomRow)).not.toContain("undo-btn");
    expect(html).toContain('title="Fork session after this point"');
    expect(html).toContain(
      'title="Undo this response and later history, retaining its prompt"',
    );
    expect(html).toContain(
      'aria-label="Undo this response and later history, retaining its prompt"',
    );
    const checkpoint = render("checkpoint");
    expect(checkpoint).toContain(
      'title="Undo this response and later history, retaining its prompt (file checkpoint available)"',
    );
    expect(checkpoint).toContain(
      'aria-label="Undo this response and later history, retaining its prompt (file checkpoint available)"',
    );
  });

  it("uses checkpoint-specific user undo labels and icon only at checkpoints", () => {
    const message: DisplayMessage = {
      id: "u",
      type: "user",
      content: [],
      seq: 1,
    };
    const render = (checkpoint_uuid?: string) =>
      renderToString(
        <MessageList
          taskTid={1}
          messages={[message]}
          replacementEvents={
            new Map([
              [
                1,
                {
                  type: "item/started",
                  item_type: "user_message",
                  item_id: "",
                  history_boundary: {
                    anchor: "anchor",
                    kind: "user",
                    checkpoint_uuid,
                  },
                },
              ],
            ])
          }
          historyOperations={{ fork: {}, undo: { first_user: "jsonl" } }}
          blocks={new Map()}
          isProcessing={false}
          bandStatus=""
          onUndo={() => {}}
        />,
      );

    const regular = render();
    expect(regular).toContain(
      'title="Undo this message and later history, restoring its prompt to the composer"',
    );
    expect(regular).toContain(
      'aria-label="Undo this message and later history, restoring its prompt to the composer"',
    );
    expect(regular).not.toContain('d="M11 3h3v3"');
    const checkpoint = render("checkpoint");
    expect(checkpoint).toContain(
      'title="Undo this message and later history, restoring its prompt to the composer (file checkpoint available)"',
    );
    expect(checkpoint).toContain(
      'aria-label="Undo this message and later history, restoring its prompt to the composer (file checkpoint available)"',
    );
    expect(checkpoint).toContain('d="M11 3h3v3"');
  });

  it("keeps fork and undo policy entries independent", () => {
    const message: DisplayMessage = {
      id: "u",
      type: "user",
      content: [],
      seq: 1,
    };
    const replacementEvents = new Map<number, AgnosticEvent>([
      [
        1,
        {
          type: "item/started",
          item_type: "user_message",
          item_id: "",
          history_boundary: { anchor: "a", kind: "user" },
        },
      ],
    ]);
    const render = (historyOperations: {
      fork: { first_user?: "jsonl" };
      undo: { first_user?: "jsonl" };
    }) =>
      renderToString(
        <MessageList
          taskTid={1}
          messages={[message]}
          replacementEvents={replacementEvents}
          historyOperations={historyOperations}
          blocks={new Map()}
          isProcessing={false}
          bandStatus=""
          onFork={() => {}}
          onUndo={() => {}}
        />,
      );
    expect(render({ fork: { first_user: "jsonl" }, undo: {} })).toContain(
      "fork-btn",
    );
    expect(render({ fork: { first_user: "jsonl" }, undo: {} })).not.toContain(
      "undo-btn",
    );
    expect(render({ fork: {}, undo: { first_user: "jsonl" } })).toContain(
      "undo-btn",
    );
    expect(render({ fork: {}, undo: { first_user: "jsonl" } })).not.toContain(
      "fork-btn",
    );
  });

  it.each([
    { firstHasAnchor: true, firstIsMeta: false },
    { firstHasAnchor: false, firstIsMeta: false },
    { firstHasAnchor: false, firstIsMeta: true },
  ])(
    "classifies first-user actions with anchor=$firstHasAnchor and meta=$firstIsMeta",
    ({ firstHasAnchor, firstIsMeta }) => {
      const messages: DisplayMessage[] = [
        {
          id: "u1",
          type: "user",
          content: [{ type: "text", text: "opening message" }],
          seq: 1,
          isMeta: firstIsMeta,
        },
        {
          id: "u2",
          type: "user",
          content: [{ type: "text", text: "selected prompt" }],
          seq: 2,
        },
        {
          id: "u3",
          type: "user",
          content: [{ type: "text", text: "later prompt" }],
          seq: 3,
        },
      ];
      const userStarted = (anchor: string): AgnosticEvent => ({
        type: "item/started",
        item_type: "user_message",
        item_id: "",
        history_boundary: { anchor, kind: "user" },
      });
      const root = document.createElement("div");
      root.innerHTML = renderToString(
        <MessageList
          taskTid={1}
          messages={messages}
          replacementEvents={
            new Map([
              ...(firstHasAnchor ? [[1, userStarted("a1")] as const] : []),
              [2, userStarted("a2")],
              [3, userStarted("a3")],
            ])
          }
          historyOperations={{
            fork: { first_user: "jsonl", user: "jsonl" },
            undo: { user: "jsonl" },
          }}
          blocks={new Map()}
          isProcessing={false}
          bandStatus=""
          onFork={() => {}}
          onUndo={() => {}}
        />,
      );
      const wrappers = [...root.querySelectorAll(".message-wrapper")];
      expect(
        wrappers.map((wrapper) => [
          wrapper.querySelectorAll(".fork-btn").length,
          wrapper.querySelectorAll(".undo-btn").length,
        ]),
      ).toEqual([
        [firstHasAnchor ? 1 : 0, 0],
        [1, firstIsMeta ? 0 : 1],
        [1, 1],
      ]);
    },
  );

  it("withholds a Codex fork at the first anchored prompt", () => {
    const anchors = ["before:first", "before:later"];
    const messages: DisplayMessage[] = anchors.map((anchor, index) => ({
      id: anchor,
      type: "user",
      content: [{ type: "text", text: anchor }],
      seq: index + 1,
    }));
    const replacementEvents = new Map<number, AgnosticEvent>(
      anchors.map((anchor, index) => [
        index + 1,
        {
          type: "item/started",
          item_id: anchor,
          item_type: "user_message",
          history_boundary: { anchor, kind: "user" },
        },
      ]),
    );
    const root = document.createElement("div");
    root.innerHTML = renderToString(
      <MessageList
        taskTid={1}
        messages={messages}
        replacementEvents={replacementEvents}
        historyOperations={{ fork: { user: "codex_native" }, undo: {} }}
        blocks={new Map()}
        isProcessing={false}
        bandStatus=""
        onFork={() => {}}
      />,
    );

    const [first, later] = root.querySelectorAll(".message-wrapper");
    expect(first?.querySelectorAll(".fork-btn")).toHaveLength(0);
    expect(later?.querySelectorAll(".fork-btn")).toHaveLength(1);
    expect(
      later?.querySelector(".fork-btn")?.getAttribute("data-fork-anchor"),
    ).toBe(anchors[1]);
  });

  it("renders undo without fork or checkpoint for a provisional user boundary", () => {
    const message: DisplayMessage = {
      id: "queued",
      type: "user",
      content: [],
      seq: 12,
      pending: true,
    };
    const html = renderToString(
      <MessageList
        taskTid={1}
        messages={[message]}
        replacementEvents={
          new Map([
            [
              12,
              {
                type: "item/started",
                item_type: "user_message",
                item_id: "enqueue-12",
                pending: true,
                history_boundary: {
                  anchor: "enqueue-12",
                  kind: "provisional_user",
                },
              },
            ],
          ])
        }
        historyOperations={{ fork: {}, undo: { provisional_user: "jsonl" } }}
        blocks={new Map()}
        isProcessing={false}
        bandStatus=""
        onFork={() => {}}
        onUndo={() => {}}
      />,
    );
    expect(html).toContain("undo-btn");
    expect(html).not.toContain("fork-btn");
    expect(html).not.toContain('d="M11 3h3v3"');
  });

  it("does not render actions for a nested boundary-looking message", () => {
    const nested: DisplayMessage = {
      id: "nested",
      type: "user",
      content: [],
      seq: 1,
      parentToolUseId: "tool",
    };
    const html = renderToString(
      <MessageList
        taskTid={1}
        messages={[nested]}
        replacementEvents={
          new Map([
            [
              1,
              {
                type: "item/started",
                item_type: "user_message",
                item_id: "",
                history_boundary: { anchor: "a", kind: "user" },
              },
            ],
          ])
        }
        historyOperations={{ fork: { user: "jsonl" }, undo: { user: "jsonl" } }}
        blocks={new Map()}
        isProcessing={false}
        bandStatus=""
        onFork={() => {}}
        onUndo={() => {}}
      />,
    );
    expect(html).not.toContain("undo-btn");
    expect(html).not.toContain("fork-btn");
  });

  it("shows parse_error system messages in normal mode", () => {
    const parseError: DisplayMessage = {
      id: "msg-1",
      type: "system",
      subtype: "parse_error",
      content: [
        {
          type: "text",
          text: 'Unknown message type: future_protocol\n{"type":"future_protocol"}',
        },
      ],
    };

    const html = renderToString(
      <MessageList
        taskTid={1}
        messages={[parseError]}
        blocks={new Map()}
        replacementEvents={new Map()}
        isProcessing={false}
        bandStatus=""
      />,
    );

    expect(html).toContain("Unknown message type: future_protocol");
    expect(html).toContain("<summary>Details</summary>");
  });

  it("hides unrecognized agent data outside dev mode", () => {
    const headline =
      "Unrecognized agent data: unknown system subtype: future_system";
    const parseError: DisplayMessage = {
      id: "msg-1",
      type: "system",
      subtype: "parse_error",
      content: [
        {
          type: "text",
          text: headline,
        },
      ],
    };

    const normalHtml = renderToString(
      <DevModeContext.Provider value={false}>
        <MessageList
          taskTid={1}
          messages={[parseError]}
          blocks={new Map()}
          replacementEvents={new Map()}
          isProcessing={false}
          bandStatus=""
        />
      </DevModeContext.Provider>,
    );
    const devHtml = renderToString(
      <DevModeContext.Provider value={true}>
        <MessageList
          taskTid={1}
          messages={[parseError]}
          blocks={new Map()}
          replacementEvents={new Map()}
          isProcessing={false}
          bandStatus=""
        />
      </DevModeContext.Provider>,
    );

    expect(normalHtml).not.toContain(headline);
    expect(devHtml).toContain(headline);
  });
});

describe("MessageList metadata rendering", () => {
  const metadata: DisplayMessage = {
    id: "metadata-1",
    type: "system",
    subtype: "metadata",
    content: [],
    rawSource: { type: "session/metadata", model: "gpt-5.6-sol" },
  };

  it("omits metadata records entirely outside dev mode", () => {
    const html = renderToString(
      <DevModeContext.Provider value={false}>
        <MessageList
          taskTid={1}
          messages={[metadata]}
          blocks={new Map()}
          replacementEvents={new Map()}
          isProcessing={false}
          bandStatus=""
        />
      </DevModeContext.Provider>,
    );

    expect(html).not.toContain("msg-metadata-1");
    expect(html).not.toContain("view-source-btn");
    expect(html).not.toContain("Session metadata");
  });

  it("renders metadata records with their source viewer in dev mode", () => {
    const html = renderToString(
      <DevModeContext.Provider value={true}>
        <MessageList
          taskTid={1}
          messages={[metadata]}
          blocks={new Map()}
          replacementEvents={new Map()}
          isProcessing={false}
          bandStatus=""
        />
      </DevModeContext.Provider>,
    );

    expect(html).toContain("msg-metadata-1");
    expect(html).toContain("Session metadata");
    expect(html).toContain("view-source-btn");
  });
});

describe("MessageList task diagnostics", () => {
  it("renders equivalent top-level and in-turn diagnostics with the shared view", () => {
    const payload = {
      severity: "warning" as const,
      subject: "Agent error (retrying)",
      body: "Try **again** shortly.",
    };
    const html = renderToString(
      <MessageList
        taskTid={1}
        messages={[
          {
            id: "top-level-diagnostic",
            type: "diagnostic",
            content: [{ type: "text", text: payload.body }],
            diagnostic: {
              severity: payload.severity,
              subject: payload.subject,
            },
          },
          {
            id: "assistant-diagnostic",
            type: "assistant",
            content: [],
            blockIds: ["in-turn-diagnostic"],
            streaming: false,
            nextCreationOrder: 1,
          },
        ]}
        blocks={
          new Map([
            [
              "in-turn-diagnostic",
              {
                itemId: "in-turn-diagnostic",
                type: "diagnostic" as const,
                severity: payload.severity,
                subject: payload.subject,
                text: payload.body,
                completed: true,
                creationOrder: 0,
              },
            ],
          ])
        }
        replacementEvents={new Map()}
        isProcessing={false}
        bandStatus=""
      />,
    );

    expect(html.match(/warning-block/g)).toHaveLength(4);
    expect(html.match(/Agent error \(retrying\)/g)).toHaveLength(2);
    expect(html.match(/Try <strong>again<\/strong> shortly\./g)).toHaveLength(
      2,
    );
  });

  it("renders error diagnostics as markdown blocks without user controls", () => {
    const diagnostic: DisplayMessage = {
      id: "diagnostic-1",
      type: "diagnostic",
      content: [{ type: "text", text: "**The session is unavailable.**" }],
      diagnostic: {
        severity: "error",
        subject: "Failed to resume session",
      },
    };

    const html = renderToString(
      <MessageList
        taskTid={1}
        messages={[diagnostic]}
        blocks={new Map()}
        replacementEvents={new Map()}
        historyOperations={{ fork: {}, undo: {}, edit_message: true }}
        isProcessing={false}
        bandStatus=""
        onEditMessage={() => {}}
        onUndo={() => {}}
      />,
    );

    expect(html).toContain("diagnostic-message diagnostic-error");
    expect(html).toContain("error-block");
    expect(html).toContain("Failed to resume session");
    expect(html).toContain("<strong>The session is unavailable.</strong>");
    expect(html).not.toContain("system-user-message");
    expect(html).not.toContain('title="Edit message"');
    expect(html).not.toContain('title="Undo from here"');
  });

  it("renders warning diagnostics as markdown blocks", () => {
    const diagnostic: DisplayMessage = {
      id: "diagnostic-warning-1",
      type: "diagnostic",
      content: [
        {
          type: "text",
          text: "- The latest turn could not be loaded.\n- Try reloading the task.",
        },
      ],
      diagnostic: { severity: "warning", subject: "History is incomplete" },
    };
    const html = renderToString(
      <MessageList
        taskTid={1}
        messages={[diagnostic]}
        blocks={new Map()}
        replacementEvents={new Map()}
        isProcessing={false}
        bandStatus=""
      />,
    );
    expect(html).toContain("diagnostic-message diagnostic-warning");
    expect(html).toContain("warning-block");
    expect(html).toContain("History is incomplete");
    expect(html).toContain("<ul>");
    expect(html).toContain("The latest turn could not be loaded.");
  });

  it("renders attachments inside a session-start framed message", () => {
    const framed: DisplayMessage = {
      id: "cydo-start-1",
      uuid: "start-uuid-1",
      type: "user",
      isMeta: true,
      content: [
        { type: "text", text: "SYSTEM rendered prompt body" },
        { type: "image", data: "aGVsbG8=", media_type: "image/png" },
      ],
      cydoMeta: {
        label: "Session start: blank",
        vars: { task_description: "what is in this picture?" },
        bodyVar: "task_description",
      },
    };

    const html = renderToString(
      <MessageList
        taskTid={1}
        messages={[framed]}
        blocks={new Map()}
        replacementEvents={new Map()}
        isProcessing={false}
        bandStatus=""
      />,
    );

    // the framed view must keep the attachment visible, not just the text:
    // losing it on replay made a briefly-shown image vanish from the task
    expect(html).toContain("user-image");
    expect(html).toContain("data:image/png;base64,aGVsbG8=");
    expect(html).toContain("what is in this picture?");
    // attachment above the prompt, matching plain user messages
    expect(html.indexOf("data:image/png")).toBeLessThan(
      html.indexOf("what is in this picture?"),
    );
  });

  it("keeps a metadata-bearing CyDo nudge editable", () => {
    const nudge: DisplayMessage = {
      id: "cydo-nudge-1",
      uuid: "nudge-uuid-1",
      type: "user",
      isMeta: true,
      content: [{ type: "text", text: "Please continue." }],
      cydoMeta: { label: "Nudge", severity: "info" },
    };

    const html = renderToString(
      <MessageList
        taskTid={1}
        messages={[nudge]}
        blocks={new Map()}
        replacementEvents={new Map()}
        historyOperations={{ fork: {}, undo: {}, edit_message: true }}
        isProcessing={false}
        bandStatus=""
        onEditMessage={() => {}}
      />,
    );

    expect(html).toContain("Nudge");
    expect(html).toContain('title="Edit message"');
  });

  it("renders a copy button in the actions row for user messages", () => {
    const user: DisplayMessage = {
      id: "u",
      type: "user",
      content: [{ type: "text", text: "hello there" }],
    };
    const html = renderToString(
      <MessageList
        taskTid={1}
        messages={[user]}
        blocks={new Map()}
        replacementEvents={new Map()}
        isProcessing={false}
        bandStatus=""
      />,
    );
    expect(html).toContain("btn-copy");
  });

  it("renders copy buttons for a wrapped message body and full text", () => {
    const wrapped: DisplayMessage = {
      id: "s",
      type: "user",
      content: [{ type: "text", text: "[SYSTEM]...hello there...[/SYSTEM]" }],
      cydoMeta: {
        label: "Session start: direct",
        vars: { task_description: "hello there" },
        bodyVar: "task_description",
      },
    };
    const html = renderToString(
      <MessageList
        taskTid={1}
        messages={[wrapped]}
        blocks={new Map()}
        replacementEvents={new Map()}
        isProcessing={false}
        bandStatus=""
      />,
    );
    const bodyCopies = html.match(/btn-copy/g) ?? [];
    // One button beside the body, one on the "Full message" pre block.
    expect(bodyCopies.length).toBeGreaterThanOrEqual(2);
    expect(html).toContain("system-user-body");
    expect(html).toContain("code-pre-wrap");
  });

  it("renders no copy button for image-only user messages", () => {
    const user: DisplayMessage = {
      id: "u",
      type: "user",
      content: [
        { type: "image", data: "aGk=", media_type: "image/png" } as never,
      ],
    };
    const html = renderToString(
      <MessageList
        taskTid={1}
        messages={[user]}
        blocks={new Map()}
        replacementEvents={new Map()}
        isProcessing={false}
        bandStatus=""
      />,
    );
    expect(html).not.toContain("btn-copy");
  });
});

describe("MessageList turn results", () => {
  function renderResult(
    resultData: Partial<NonNullable<DisplayMessage["resultData"]>>,
  ) {
    return renderToString(
      <MessageList
        taskTid={1}
        messages={[
          {
            id: "result",
            type: "result",
            content: [],
            resultData: {
              subtype: "error_during_execution",
              isError: true,
              numTurns: 1,
              durationMs: 0,
              totalCostUsd: 0,
              usage: { input_tokens: 0, output_tokens: 0 },
              ...resultData,
            },
          },
        ]}
        replacementEvents={new Map()}
        blocks={new Map()}
        isProcessing={false}
        bandStatus=""
      />,
    );
  }

  it("shows a turn the user stopped as a neutral divider, not a failure", () => {
    const html = renderResult({ endReason: "interrupted" });
    expect(html).toContain("result-divider result-interrupted");
    expect(html).not.toContain("result-error");
    expect(html).not.toContain("Session Failed");
  });

  it("expands a failed turn with the reason it stopped", () => {
    const html = renderResult({ endReason: "context_limit" });
    expect(html).toContain("result-message result-error");
    expect(html).toContain("Context limit reached");
  });

  it("keeps the generic headline for unnamed failures", () => {
    expect(renderResult({})).toContain("Session Failed");
  });
});

describe("MessageList approval reconciliation", () => {
  it.each([
    { scenario: "Claude replay", streaming: false, replay: true },
    {
      scenario: "Claude replay that moves the row",
      streaming: true,
      replay: true,
    },
    { scenario: "live nonce echo", streaming: false, replay: false },
  ])(
    "keeps an opened approval expanded after $scenario",
    async ({ streaming, replay }) => {
      const label = "Approve and retry";
      const permission =
        'Permission granted for this exact command only, as one whole string: "echo AUTO_MODE_FLAG blocked".';
      const content = [
        {
          type: "text" as const,
          text: `[SYSTEM: ${label}]\n\n${permission}\n\n[/SYSTEM]`,
        },
      ];
      const assistant: DisplayMessage = {
        id: "streaming-assistant",
        type: "assistant",
        content: [],
        streaming: true,
      };
      const pending: TaskState = {
        ...makeTaskState(1),
        msgIdCounter: 1,
        messages: [
          ...(streaming ? [assistant] : []),
          {
            id: "pending-1",
            type: "user",
            content,
            cydoMeta: { label },
            nonce: replay ? undefined : "n1",
            pending: true,
            isProvisional: true,
            ackState: 3,
          },
        ],
      };
      const root = document.createElement("div");
      const show = (state: TaskState) =>
        act(() => {
          render(
            <MessageList
              taskTid={1}
              messages={state.messages}
              replacementEvents={state.replacementEvents}
              blocks={state.blocks}
              isProcessing={false}
              bandStatus=""
            />,
            root,
          );
        });
      const expanded = () => root.querySelector(".system-user-expanded");

      try {
        await show(pending);
        await act(() => {
          root
            .querySelector<HTMLElement>(".system-user-message.pending")!
            .click();
        });
        expect(expanded()?.textContent ?? "").toContain(permission);

        const before = expanded();
        const echo = {
          type: "item/started" as const,
          item_id: "native-user",
          item_type: "user_message",
          content,
          ...(replay ? { is_replay: true } : { correlation_id: "n1" }),
          uuid: "native-approval",
          meta: { label },
        };
        const echoed = reduceMessage(pending, echo, 20);
        expect(echoed.messages[0]).toMatchObject({
          uuid: "native-approval",
          seq: 20,
        });
        if (streaming) expect(echoed.messages[1]).toBe(assistant);
        await show(echoed);

        expect(expanded()?.textContent ?? "").toContain(permission);
        expect(expanded()).toBe(before);
      } finally {
        await act(() => {
          render(null, root);
        });
      }
    },
  );
});
