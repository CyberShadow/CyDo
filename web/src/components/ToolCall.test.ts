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
      if (command.startsWith("cat > /tmp/a/output.svg <<'EOF'")) {
        const writeResult: ShellSemanticResult = {
          ok: true,
          value: {
            kind: "write",
            commandName: "cat",
            command,
            filePath: "/tmp/a/output.svg",
            writeMode: "overwrite",
            heredoc: {
              delimiter: "EOF",
              quoted: true,
              commandLine: "cat > /tmp/a/output.svg <<'EOF'",
              content: "<svg></svg>",
              terminator: "EOF",
            },
            segments: [
              {
                kind: "command-header",
                text: "cat > /tmp/a/output.svg <<'EOF'",
              },
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

function renderBashInput(input: Record<string, unknown>): string {
  return renderToString(
    h(ToolCall, {
      name: "Bash",
      driver: "claude",
      toolUseId: "tool-1",
      input,
      result: undefined,
    }),
  );
}

function renderCodexFileChangeInput(
  changes: Array<Record<string, unknown>>,
): string {
  return renderToString(
    h(ToolCall, {
      name: "fileChange",
      agentType: "codex",
      toolUseId: "tool-fc1",
      input: { changes },
      result: undefined,
    }),
  );
}

describe("claude/Bash subtitle badges", () => {
  it("renders description only — no badge", () => {
    const html = renderBashInput({ command: "ls", description: "list files" });
    expect(html).toContain("list files");
    expect(html).not.toContain("tool-subtitle-tag");
  });

  it("renders background badge when run_in_background is true", () => {
    const html = renderBashInput({
      command: "ls",
      description: "list files",
      run_in_background: true,
    });
    expect(html).toContain("list files");
    expect(html).toContain("tool-subtitle-tag");
    expect(html).toContain("background");
  });

  it("renders timeout in seconds when >= 1000ms", () => {
    const html = renderBashInput({
      command: "ls",
      description: "list files",
      timeout: 900000,
    });
    expect(html).toContain("900s");
    expect(html).not.toContain("900000ms");
  });

  it("renders timeout in ms when < 1000ms", () => {
    const html = renderBashInput({
      command: "ls",
      description: "list files",
      timeout: 250,
    });
    expect(html).toContain("250ms");
  });

  it("renders both badges together", () => {
    const html = renderBashInput({
      command: "ls",
      description: "list files",
      run_in_background: true,
      timeout: 900000,
    });
    expect(html).toContain("background");
    expect(html).toContain("900s");
  });

  it("does not render run_in_background or timeout in KV body list", () => {
    const html = renderBashInput({
      command: "ls",
      description: "list files",
      run_in_background: true,
      timeout: 900000,
    });
    expect(html).not.toContain(">run_in_background<");
    expect(html).not.toContain(">timeout<");
  });
});

describe("codex/fileChange path copy buttons", () => {
  it("renders one copy button for single-file path subtitle", () => {
    const html = renderCodexFileChangeInput([
      { op: "add", path: "src/main.ts", content: "" },
    ]);

    const copyButtonCount = (html.match(/class="btn-copy"/g) ?? []).length;
    expect(copyButtonCount).toBe(1);
    expect(html).toContain("tool-path-wrap");
  });

  it("renders one copy button per known path in multi-file rows", () => {
    const html = renderCodexFileChangeInput([
      { op: "add", path: "src/a.ts" },
      { op: "add", path: "src/b.ts" },
      { op: "delete" },
    ]);

    const copyButtonCount = (html.match(/class="btn-copy"/g) ?? []).length;
    expect(copyButtonCount).toBe(2);
    expect(html).toContain("(unknown file)");
  });
});

function renderShellInput(command: string): string {
  return renderToString(
    h(ToolCall, {
      name: "commandExecution",
      driver: "codex",
      input: { command },
      result: undefined,
    }),
  );
}

function renderCydoTaskInput(
  tasks: Array<Record<string, unknown>>,
  spawnedTids?: Map<number, number>,
  getTaskHref?: (id: string) => string,
): string {
  return renderToString(
    h(ToolCall, {
      name: "Task",
      toolServer: "cydo",
      driver: "claude",
      toolUseId: "tool-t1",
      input: { tasks },
      result: undefined,
      spawnedTids,
      getTaskHref,
    }),
  );
}

function renderCydoTaskResult(
  taskItems: Array<Record<string, unknown>>,
  getTaskHref?: (id: string) => string,
): string {
  return renderToString(
    h(ToolCall, {
      name: "Task",
      toolServer: "cydo",
      driver: "claude",
      toolUseId: "tool-t1",
      input: { tasks: taskItems },
      result: {
        toolUseId: "tool-t1",
        content: [],
        isError: false,
        // parseCydoTaskResultPayload recognises {tasks:[...]} in toolResult
        toolResult: { tasks: taskItems },
      },
      getTaskHref,
    }),
  );
}

describe("cydo:Task ToolCall Open task link", () => {
  const getHref = (id: string) => `/task/${id}`;

  it("renders Open task link when spawnedTids has entry for spec", () => {
    const html = renderCydoTaskInput(
      [{ task_type: "research", description: "ping", prompt: "ping" }],
      new Map([[0, 42]]),
      getHref,
    );
    expect(html).toContain('data-testid="cydo-task-spec-open"');
    expect(html).toContain('href="/task/42"');
    expect(html).toContain("Open task");
  });

  it("does not render link when spawnedTids is empty", () => {
    const html = renderCydoTaskInput(
      [{ task_type: "research", description: "ping", prompt: "ping" }],
      new Map(),
      getHref,
    );
    expect(html).not.toContain('data-testid="cydo-task-spec-open"');
  });

  it("does not render link when getTaskHref is absent", () => {
    const html = renderCydoTaskInput(
      [{ task_type: "research", description: "ping", prompt: "ping" }],
      new Map([[0, 42]]),
      undefined,
    );
    expect(html).not.toContain('data-testid="cydo-task-spec-open"');
  });

  it("only renders link for spec with matching childTid (multi-spec)", () => {
    const html = renderCydoTaskInput(
      [
        { task_type: "research", description: "ping0", prompt: "p0" },
        { task_type: "implement", description: "ping1", prompt: "p1" },
      ],
      new Map([[1, 99]]),
      getHref,
    );
    // Only spec index 1 has a link — href for task 99 appears once
    expect(html).toContain('href="/task/99"');
    const hrefCount = (html.match(/href="\/task\//g) ?? []).length;
    expect(hrefCount).toBe(1);
  });

  it("result-side renders Open task link from tid in result payload", () => {
    const html = renderCydoTaskResult(
      [
        {
          task_type: "research",
          description: "ping",
          tid: 99,
          status: "complete",
        },
      ],
      getHref,
    );
    expect(html).toContain('data-testid="cydo-task-spec-open"');
    expect(html).toContain('href="/task/99"');
  });

  it("result-side does not render link when getTaskHref is absent", () => {
    const html = renderCydoTaskResult(
      [
        {
          task_type: "research",
          description: "ping",
          tid: 99,
          status: "complete",
        },
      ],
      undefined,
    );
    expect(html).not.toContain('data-testid="cydo-task-spec-open"');
  });
});

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

  it("renders svg heredoc source tree blocks without spacer rows", () => {
    const html = renderShellInput(
      "cat > /tmp/a/output.svg <<'EOF'\n<svg></svg>\nEOF",
    );
    expect(html).toContain("source-tree-blocks");
    expect(html).toContain("source-tree-block-start");
    expect(html).toContain("source-tree-block-end");
    expect(html).toContain('title="Show source"');
    expect(html).toContain('alt="SVG preview"');
  });
});
