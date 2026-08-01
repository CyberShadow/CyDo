import { describe, expect, it } from "vitest";
import renderToString from "preact-render-to-string";
import { MessageList } from "./MessageList";
import { DevModeContext } from "../devMode";
import type { DisplayMessage } from "../types";
import type { AgnosticEvent } from "../protocol";

describe("MessageList parse-error rendering", () => {
  it("derives user actions from one matching replacement boundary", () => {
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
        historyOperations={{ fork: { user: "jsonl" }, undo: { user: "jsonl" } }}
        blocks={new Map()}
        isProcessing={false}
        bandStatus=""
        onUndo={() => {}}
      />,
    );
    expect(html).toContain("undo-btn");
    expect(html).toContain('aria-label="Undo to this point"');
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

  it("derives assistant actions from a turn-stop boundary", () => {
    const assistant: DisplayMessage = {
      id: "a",
      type: "assistant",
      content: [],
      seq: 9,
    };
    const html = renderToString(
      <MessageList
        taskTid={1}
        messages={[assistant]}
        replacementEvents={
          new Map([
            [
              9,
              {
                type: "turn/stop",
                history_boundary: { anchor: "line:9", kind: "agent_turn" },
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
    expect(html).toContain("fork-btn");
    expect(html).toContain("undo-btn");
    expect(html).toContain('title="Fork session after this point"');
    expect(html).toContain(
      'aria-label="Undo this response and later history, retaining its prompt"',
    );
  });

  it("uses the file-revert undo icon only for a checkpoint boundary", () => {
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
          historyOperations={{ fork: {}, undo: { user: "jsonl" } }}
          blocks={new Map()}
          isProcessing={false}
          bandStatus=""
          onUndo={() => {}}
        />,
      );

    expect(render()).toContain('aria-label="Undo to this point"');
    expect(render()).not.toContain('d="M11 3h3v3"');
    expect(render("checkpoint")).toContain(
      'aria-label="Undo to this point (file checkpoint available)"',
    );
    expect(render("checkpoint")).toContain('d="M11 3h3v3"');
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
      fork: { user?: "jsonl" };
      undo: { user?: "jsonl" };
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
    expect(render({ fork: { user: "jsonl" }, undo: {} })).toContain("fork-btn");
    expect(render({ fork: { user: "jsonl" }, undo: {} })).not.toContain(
      "undo-btn",
    );
    expect(render({ fork: {}, undo: { user: "jsonl" } })).toContain("undo-btn");
    expect(render({ fork: {}, undo: { user: "jsonl" } })).not.toContain(
      "fork-btn",
    );
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

  it("hides unknown system subtype parse errors outside dev mode", () => {
    const parseError: DisplayMessage = {
      id: "msg-1",
      type: "system",
      subtype: "parse_error",
      content: [
        {
          type: "text",
          text: 'Unknown system subtype: thinking_tokens\n{"type":"system","subtype":"thinking_tokens"}',
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

    expect(normalHtml).not.toContain("Unknown system subtype: thinking_tokens");
    expect(devHtml).toContain("Unknown system subtype: thinking_tokens");
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
        isProcessing={false}
        bandStatus=""
        onEditMessage={() => {}}
      />,
    );

    expect(html).toContain("Nudge");
    expect(html).toContain('title="Edit message"');
  });
});
