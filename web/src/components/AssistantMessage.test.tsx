import { describe, expect, it } from "vitest";
import renderToString from "preact-render-to-string";
import { reduceMessage } from "../sessionReducer";
import { makeTaskState } from "../types";
import { TaskDiagnosticView } from "./TaskDiagnosticView";
import { DevModeContext } from "../devMode";
import type { Block, DisplayMessage } from "../types";
import { AssistantMessage } from "./AssistantMessage";

function renderAssistantMessage(message: DisplayMessage, block: Block): string {
  return renderToString(
    <DevModeContext.Provider value={false}>
      <AssistantMessage
        message={message}
        resolvedBlocks={[block]}
        onViewFile={() => {}}
        semanticSelectors={false}
      />
    </DevModeContext.Provider>,
  );
}

describe("AssistantMessage diagnostic blocks", () => {
  it("renders the diagnostic subject and Markdown body with warning styling", () => {
    const html = renderAssistantMessage(
      {
        id: "diagnostic-msg-1",
        type: "assistant",
        content: [],
        blockIds: ["diagnostic-1"],
        streaming: false,
        nextCreationOrder: 1,
      },
      {
        itemId: "diagnostic-1",
        type: "diagnostic",
        severity: "warning",
        subject: "Agent error (retrying)",
        text: "Try **again** shortly.",
        completed: true,
        creationOrder: 0,
      },
    );

    expect(html).toContain("warning-block");
    expect(html).toContain("Agent error (retrying)");
    expect(html).toContain("Try <strong>again</strong> shortly.");
  });

  it.each([
    ["info", "info", "Agent notice", "system-status-message"],
    ["notice", "info", "Agent notice", "system-status-message"],
    ["warning", "warning", "Agent notice", "warning-block"],
    ["suggestion", "warning", "Agent suggestion", "warning-block"],
  ] as const)(
    "renders Claude %s with the expected notice style",
    (_level, severity, subject, style) => {
      const html = renderToString(
        <TaskDiagnosticView
          severity={severity}
          subject={subject}
          body="Informational content"
        />,
      );
      expect(html).toMatch(new RegExp(`class="(?:[^"]* )?${style}(?: |")`));
      expect(html).not.toMatch(
        /class="(?:[^"]* )?(?:system-message|error-block)(?: |")/,
      );
    },
  );

  it("renders the captured stdout-only failure live and after replay", () => {
    const notice = {
      type: "agent/notice",
      severity: "error",
      subject: "SessionStart:startup failed (exit code 1)",
      body: "",
      stdout: "probe-stdout-only",
      collapsible: true,
    } as const;
    const live = { ...notice, output: "probe-stdout-only" };
    const history = {
      ...notice,
      stderr: "Failed with non-blocking status code: No stderr output",
    };

    for (const event of [live, history]) {
      const state = reduceMessage(makeTaskState(1), event);
      const message = state.messages[0]!;
      const html = renderToString(
        <TaskDiagnosticView {...message.diagnostic!} body="" />,
      );
      expect(html).toContain("<div>stdout</div><pre>probe-stdout-only</pre>");
      expect(html).not.toContain("<div>output</div>");
      if (event === history)
        expect(html).toContain(
          "<div>stderr</div><pre>Failed with non-blocking status code: No stderr output</pre>",
        );
      else expect(html).not.toContain("<div>stderr</div>");
    }
  });

  it("renders each long hook stream in its own labeled block inside the disclosure", () => {
    const stdout = "line 1\nline 2\nline 3\nline 4\nline 5\n**line 6**";
    const html = renderAssistantMessage(
      {
        id: "hook-message",
        type: "assistant",
        content: [],
        blockIds: ["hook-notice"],
      },
      {
        itemId: "hook-notice",
        type: "diagnostic",
        severity: "error",
        subject: "SessionStart:startup failed (exit code 1)",
        text: "",
        hookOutput: {
          stdout,
          stderr: "failure detail",
          output: "hook diagnostic",
        },
        completed: true,
        creationOrder: 0,
      },
    );

    expect(html).toContain("SessionStart:startup failed (exit code 1)");
    const details = html.match(
      /<details class="result-details"><summary>Hook output<\/summary>([\s\S]*?)<\/details>/,
    )?.[1];
    expect(details).toContain(`<div>stdout</div><pre>${stdout}</pre>`);
    expect(details).toContain("<div>stderr</div><pre>failure detail</pre>");
    expect(details).toContain("<div>output</div><pre>hook diagnostic</pre>");
  });

  it("keeps equal stdout and stderr blocks while omitting duplicate output", () => {
    const html = renderToString(
      <TaskDiagnosticView
        severity="error"
        subject="Hook failed"
        body=""
        hookOutput={{
          stdout: "same text",
          stderr: "same text",
          output: "same text",
        }}
      />,
    );
    expect(html).toContain("<div>stdout</div><pre>same text</pre>");
    expect(html).toContain("<div>stderr</div><pre>same text</pre>");
    expect(html).not.toContain("<div>output</div>");
  });
});

it("renders command output as literal aligned assistant text", () => {
  const text =
    "\n**literal**  [label](https://example.invalid)\nkey          value";
  const state = reduceMessage(makeTaskState(1), {
    type: "agent/command_output",
    text,
  });
  const message = state.messages[0]!;
  const html = renderAssistantMessage(
    message,
    state.blocks.get(message.blockIds![0]!)!,
  );
  expect(html).toContain('class="message assistant-message"');
  expect(html).toContain(
    '<pre class="text-content command-output"><span>\n**literal**  [label](https://example.invalid)\nkey          value</span></pre>',
  );
  expect(html).not.toMatch(/<(?:strong|a)\b/);
});

describe("AssistantMessage thinking blocks", () => {
  const message: DisplayMessage = {
    id: "thinking-msg-1",
    type: "assistant",
    content: [],
    blockIds: ["thinking-1"],
    streaming: false,
    nextCreationOrder: 1,
  };
  const thinking: Block = {
    itemId: "thinking-1",
    type: "thinking",
    text: "Checking the **fixture**.",
    completed: true,
    creationOrder: 0,
  };

  it("renders narration as thinking with a summary badge", () => {
    const html = renderAssistantMessage(message, {
      ...thinking,
      narration: true,
    });

    expect(html).toContain('data-testid="assistant-narration"');
    expect(html).toContain("thinking-text");
    expect(html).toContain("Checking the <strong>fixture</strong>.");
    expect(html).toContain('class="meta-badge summary"');
  });

  it("renders other thinking without the badge", () => {
    const html = renderAssistantMessage(message, thinking);

    expect(html).toContain("thinking-text");
    expect(html).not.toContain("assistant-narration");
    expect(html).not.toContain("meta-badge");
  });
});
