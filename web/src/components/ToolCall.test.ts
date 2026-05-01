import { describe, expect, it, vi } from "vitest";
import { h } from "preact";
import renderToString from "preact-render-to-string";
import type { ShellSemanticResult } from "../lib/shellSemantic";
import type { ToolResult } from "../types";
import {
  ToolCall,
  formatCydoTaskResultItem,
  getCydoTaskResultItems,
} from "./ToolCall";

vi.mock("../lib/shellSemantic", async () => {
  const actual = await vi.importActual<typeof import("../lib/shellSemantic")>(
    "../lib/shellSemantic",
  );
  return {
    ...actual,
    useShellSemantic: (command: string | null | undefined) => {
      if (!command) return null;
      if (command.startsWith("cat > README.md <<EOF")) {
        const writeResult: ShellSemanticResult = {
          ok: true,
          value: {
            kind: "write",
            commandName: "cat",
            command,
            filePath: "README.md",
            writeMode: "overwrite",
            heredoc: {
              delimiter: "EOF",
              quoted: false,
              commandLine: "cat > README.md <<EOF",
              content: "# Title",
              terminator: "EOF",
            },
            segments: [
              { kind: "command-header", text: "cat > README.md <<EOF" },
            ],
          },
        };
        return writeResult;
      }
      if (command.startsWith("python - <<'PY'")) {
        const scriptResult: ShellSemanticResult = {
          ok: true,
          value: {
            kind: "script-exec",
            commandName: "python",
            command,
            language: "python",
            scriptSource: {
              type: "heredoc",
              delimiter: "PY",
              quoted: true,
              content: 'print("hi")',
              terminator: "PY",
              commandLine: "python - <<'PY'",
            },
            segments: [{ kind: "command-header", text: "python - <<'PY'" }],
          },
        };
        return scriptResult;
      }
      return null;
    },
  };
});

function makeResult(
  overrides: Partial<ToolResult>,
  content: ToolResult["content"] = "",
): ToolResult {
  return {
    toolUseId: "tool-1",
    content,
    ...overrides,
  };
}

describe("CyDo task result helpers", () => {
  it("prefers structured tool results over content text", () => {
    const items = getCydoTaskResultItems(
      makeResult(
        {
          toolResult: {
            tasks: [{ status: "success", tid: 2, summary: "from-tool-result" }],
          },
        },
        "not json",
      ),
    );

    expect(items).toEqual([
      { status: "success", tid: 2, summary: "from-tool-result" },
    ]);
  });

  it("accepts question results directly from toolResult", () => {
    const items = getCydoTaskResultItems(
      makeResult(
        {
          toolResult: {
            status: "question",
            tid: 2,
            qid: 1,
            message: "what approach should I use?",
          },
        },
        "",
      ),
    );

    expect(items).toEqual([
      {
        status: "question",
        tid: 2,
        qid: 1,
        message: "what approach should I use?",
      },
    ]);
  });

  it("unwraps structuredContent wrappers in toolResult", () => {
    const items = getCydoTaskResultItems(
      makeResult(
        {
          toolResult: {
            content:
              '{"status":"question","tid":2,"qid":1,"message":"what approach should I use?"}',
            structuredContent: {
              status: "question",
              tid: 2,
              qid: 1,
              message: "what approach should I use?",
            },
          },
        },
        "",
      ),
    );

    expect(items).toEqual([
      {
        status: "question",
        tid: 2,
        qid: 1,
        message: "what approach should I use?",
      },
    ]);
  });

  it("falls back to outer JSON text when structured data is absent", () => {
    const items = getCydoTaskResultItems(
      makeResult({}, [
        {
          type: "text",
          text: '{"tasks":[{"status":"success","tid":2,"summary":"from-text"}]}',
        },
      ]),
    );

    expect(items).toEqual([
      { status: "success", tid: 2, summary: "from-text" },
    ]);
  });

  it("falls back to text when toolResult is only a content wrapper", () => {
    const items = getCydoTaskResultItems(
      makeResult(
        {
          toolResult: {
            content:
              '{"tasks":[{"status":"success","tid":2,"summary":"from-wrapper-content"}]}',
          },
        },
        [
          {
            type: "text",
            text: '{"tasks":[{"status":"success","tid":2,"summary":"from-result-content"}]}',
          },
        ],
      ),
    );

    expect(items).toEqual([
      { status: "success", tid: 2, summary: "from-result-content" },
    ]);
  });

  it("keeps nested JSON-looking summary text literal", () => {
    const item = formatCydoTaskResultItem({
      status: "success",
      tid: 2,
      summary: '{"qid":3,"message":"**Summary**\\n\\nHello"}',
    });

    expect(item.text).toBe('{"qid":3,"message":"**Summary**\\n\\nHello"}');
  });

  it("renders structured errors through the typed path", () => {
    const item = formatCydoTaskResultItem({
      status: "error",
      tid: 2,
      error: "task failed",
      summary: "task failed",
    });

    expect(item.text).toBe("task failed");
    expect(item.fields).toMatchObject({ status: "error", tid: 2 });
  });
});

function renderShellInput(command: string): string {
  return renderToString(
    h(ToolCall, {
      name: "commandExecution",
      agentType: "codex",
      input: { command },
      result: undefined,
    }),
  );
}

describe("ToolCall shell source tree rendering", () => {
  it("keeps semantic-shell-write selector while rendering heredoc write via source tree view", () => {
    const html = renderShellInput("cat > README.md <<EOF\n# Title\nEOF");
    expect(html).toContain('data-testid="semantic-shell-write"');
    expect(html).toContain('data-testid="source-tree-input"');
  });

  it("keeps semantic-shell-script selector while rendering heredoc script via source tree view", () => {
    const html = renderShellInput("python - <<'PY'\nprint(\"hi\")\nPY");
    expect(html).toContain('data-testid="semantic-shell-script"');
    expect(html).toContain('data-testid="source-tree-input"');
  });

  it("preserves wrapper selector for wrapper source tree rendering", () => {
    const html = renderShellInput("zsh -lc 'cat README.md'");
    expect(html).toContain('data-testid="semantic-shell-wrapper-input"');
    expect(html).toContain('data-testid="source-tree-input"');
  });
});
