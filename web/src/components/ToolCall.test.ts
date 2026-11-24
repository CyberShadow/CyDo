// @vitest-environment jsdom
import {
  afterEach,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from "vitest";
import { h } from "preact";
import { act } from "preact/test-utils";
import renderToString from "preact-render-to-string";
import {
  parseShellSemantic,
  type ShellSemanticResult,
} from "../lib/shellSemantic";
import * as shellParser from "../lib/shellParser";
import type { ParseResult } from "../lib/shellParser";
import { configureShellParserAssets } from "../lib/shellParser";
import { loadParsedShellDocument } from "../lib/shellParser";
import type { ToolResult } from "../types";
import { actPoll, ownedRoots } from "../test-support/preactAct";
import bashEditDiff from "../testFixtures/claude-bash-edit-diff.json";
import {
  ToolCall,
  formatCydoTaskResultItem,
  getCydoTaskResultItems,
} from "./ToolCall";

type FsPromisesLike = {
  readFile(path: URL): Promise<Uint8Array>;
};

const processLike = (
  globalThis as typeof globalThis & {
    process: {
      getBuiltinModule(name: string): unknown;
      cwd(): string;
    };
  }
).process;

beforeAll(async () => {
  const fs = processLike.getBuiltinModule("node:fs/promises") as FsPromisesLike;
  const [runtime, bashLanguage] = await Promise.all([
    fs.readFile(
      new URL(
        `file://${processLike.cwd()}/node_modules/web-tree-sitter/web-tree-sitter.wasm`,
      ),
    ),
    fs.readFile(
      new URL(
        `file://${processLike.cwd()}/node_modules/tree-sitter-bash/tree-sitter-bash.wasm`,
      ),
    ),
  ]);
  configureShellParserAssets({
    kind: "bytes",
    loadRuntime: () => Promise.resolve(new Uint8Array(runtime)),
    loadBashLanguage: () => Promise.resolve(new Uint8Array(bashLanguage)),
  });
});

afterEach(() => {
  vi.restoreAllMocks();
});

function deferred<T>(): {
  promise: Promise<T>;
  resolve(value: T): void;
  reject(reason: unknown): void;
} {
  let resolvePromise!: (value: T) => void;
  let rejectPromise!: (reason: unknown) => void;
  const promise = new Promise<T>((resolve, reject) => {
    resolvePromise = resolve;
    rejectPromise = reject;
  });
  return {
    promise,
    resolve: resolvePromise,
    reject: rejectPromise,
  };
}

function successfulParse(source: string): ParseResult {
  return {
    ok: true,
    document: {
      source,
      program: {
        kind: "program",
        span: { start: 0, end: source.length },
        children: [],
        boundaries: [],
      },
      commands: [],
      redirects: [],
      embeddedInvocations: [],
      diagnostics: [],
    },
  };
}

let useRealShellSemantic = false;

vi.mock("../lib/shellSemantic", async () => {
  const actual = await vi.importActual<typeof import("../lib/shellSemantic")>(
    "../lib/shellSemantic",
  );
  return {
    ...actual,
    useShellSemantic(command: string | null | undefined) {
      const real = actual.useShellSemantic(
        useRealShellSemantic ? (command ?? null) : null,
      );
      if (useRealShellSemantic) return real;
      if (!command) return null;
      if (command.startsWith("cat > README.md <<EOF")) {
        const writeResult: ShellSemanticResult = {
          ok: true,
          value: {
            kind: "write",
            commandName: "cat",
            command,
            filePath: "README.md",
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
      if (command.startsWith("git log -p")) {
        const diffResult: ShellSemanticResult = {
          ok: true,
          value: {
            kind: "diff",
            commandName: "git",
            command,
            subcommand: "log",
          },
        };
        return diffResult;
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

function renderClaudeBashEditDiff(): string {
  return renderToString(
    h(ToolCall, {
      name: "Bash",
      driver: "claude",
      toolUseId: "bash-edit-diff-1",
      input: { command: "git diff" },
      result: makeResult({ toolResult: { bashEditDiff } }),
      onViewFile: () => {},
    }),
  );
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
      driver: "codex",
      toolUseId: "tool-fc1",
      input: { changes },
      result: undefined,
    }),
  );
}

describe("claude/Bash subtitle badges", () => {
  it("renders each included Bash edit diff as an openable file row", () => {
    const html = renderClaudeBashEditDiff();

    expect(html.match(/class="filechange-change"/g)).toHaveLength(2);
    expect(html.match(/class="tool-view-file"/g)).toHaveLength(2);
    expect(html).toContain("impexp.d");
    expect(html).toContain("paths.d");
    expect(html).toContain("SerializedState");
    expect(html).not.toContain("unknown-result-fields");
    expect(html).not.toContain("bashEditDiff");
  });

  it("shows Bash availability and omitted-file metadata", () => {
    const render = (bashEditDiff: unknown) =>
      renderToString(
        h(ToolCall, {
          name: "Bash",
          driver: "claude",
          input: { command: "true" },
          result: makeResult({ toolResult: { bashEditDiff } }),
          onViewFile: () => {},
        }),
      );
    const unavailable = {
      ...bashEditDiff,
      unavailable: true,
      moreFiles: 2,
      changedFiles: [
        ...bashEditDiff.files.map((file) => file.filePath),
        "/omitted",
      ],
    };
    expect(render(unavailable)).toContain("2 more changed files not shown");
    expect(render(unavailable)).toContain("diff may be incomplete");
    expect(render(unavailable)).toContain("omitted");
    const omittedOnly = render({
      files: [],
      moreFiles: 2,
      changedFiles: ["/omitted"],
      unavailable: true,
    });
    expect(omittedOnly).toContain("2 more changed files not shown");
    expect(omittedOnly).toContain("omitted");
    expect(omittedOnly).toContain("diff may be incomplete");
    expect(
      render({ ...bashEditDiff, unavailable: true, moreFiles: 0 }),
    ).toContain("diff may be incomplete");
    expect(
      render({ files: [], moreFiles: 0, unavailable: true }),
    ).not.toContain("diff may be incomplete");
    expect(render({ files: [], moreFiles: 0, skipped: true })).not.toContain(
      "filechange-list",
    );
  });

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

async function renderShellInput(command: string): Promise<string> {
  await loadParsedShellDocument(command);
  return renderToString(
    h(ToolCall, {
      name: "commandExecution",
      driver: "codex",
      input: { command },
      result: undefined,
    }),
  );
}

describe("codex/commandExecution command fidelity", () => {
  it("keeps a compound command when its completed action only describes the read", () => {
    const command =
      "sh -c \"wc -l /tmp/output.md && sed -n '1,520p' /tmp/output.md\"";
    const html = renderToString(
      h(ToolCall, {
        name: "commandExecution",
        driver: "codex",
        toolUseId: "tool-command-1",
        input: { command },
        result: makeResult({
          isError: false,
          toolResult: {
            status: "completed",
            exitCode: 0,
            commandActions: [
              {
                type: "read",
                command: "sed -n '1,520p' /tmp/output.md",
              },
            ],
          },
        }),
      }),
    );

    expect(html).toContain("wc -l");
    expect(html).toContain("sed -n");
  });
});

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

function renderCydoAskUserQuestionResult(
  questions: Array<Record<string, unknown>>,
  resultText: string,
): string {
  return renderToString(
    h(ToolCall, {
      name: "AskUserQuestion",
      toolServer: "cydo",
      driver: "claude",
      toolUseId: "tool-q1",
      input: { questions },
      result: {
        toolUseId: "tool-q1",
        content: [{ type: "text", text: resultText }],
        isError: false,
        toolResult: [{ type: "text", text: resultText }],
      },
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

describe("cydo:AskUserQuestion result rendering", () => {
  it("highlights answered choices whose labels contain commas", () => {
    const q1 =
      "final_summaries (5 writers) and distilled_trade_ideas (6 writers) share one table via a discriminator column. To make 'wipe partition + insert' safe, which way?";
    const a1 =
      "Split one-table-per-asset. Also please add migration code. (I don't think we have a migration system so probably just an imperative migration.)";
    const q2 =
      "This is a multi-asset architectural refactor with several genuine design forks. How do you want to proceed?";
    const a2 = "Design doc first (Recommended)";
    const q3 =
      "hierarchy_nodes/edges is one graph built by 4 assets and read by ~14. It cannot cleanly be one-asset-one-table. How should it be treated?";
    const a3 = "Keep as shared accumulator, delete by level";
    const resultText = `User has answered your questions: "${q1}"="${a1}". "${q2}"="${a2}". "${q3}"="${a3}".`;

    const html = renderCydoAskUserQuestionResult(
      [
        {
          header: "Shared",
          question: q1,
          options: [
            {
              label: a1,
              description: "Split the result storage by asset.",
            },
            {
              label: "Keep shared table",
              description: "Keep discriminator-based writes.",
            },
          ],
        },
        {
          header: "Plan",
          question: q2,
          options: [
            {
              label: a2,
              description: "Write the design before implementation.",
            },
            {
              label: "Implement directly",
              description: "Start with code changes.",
            },
          ],
        },
        {
          header: "Cleanup",
          question: q3,
          options: [
            {
              label: "Delete by level",
              description: "Track state independently for each level.",
            },
            {
              label: a3,
              description:
                "Reuse a shared accumulator while pruning level data.",
            },
          ],
        },
      ],
      resultText,
    );

    expect(html).toMatch(
      /class="ask-option ask-option-selected"><div class="ask-option-label">Split one-table-per-asset\. Also please add migration code\./,
    );
    expect(html).toMatch(
      /class="ask-option ask-option-selected"><div class="ask-option-label">Keep as shared accumulator, delete by level<\/div>/,
    );
    expect((html.match(/ask-option-selected/g) ?? []).length).toBe(3);
  });
});

describe("ToolCall shell source tree rendering", () => {
  it("keeps semantic-shell-write selector while rendering heredoc write via source tree view", async () => {
    const html = await renderShellInput("cat > README.md <<EOF\n# Title\nEOF");
    expect(html).toContain('data-testid="semantic-shell-write"');
    expect(html).toContain('data-testid="source-tree-input"');
  });

  it("keeps semantic-shell-script selector while rendering heredoc script via source tree view", async () => {
    const html = await renderShellInput("python - <<'PY'\nprint(\"hi\")\nPY");
    expect(html).toContain('data-testid="semantic-shell-script"');
    expect(html).toContain('data-testid="source-tree-input"');
  });

  it("preserves wrapper selector for wrapper source tree rendering", async () => {
    const html = await renderShellInput("zsh -lc 'cat README.md'");
    expect(html).toContain('data-testid="semantic-shell-wrapper-input"');
    expect(html).toContain('data-testid="source-tree-input"');
  });

  it("renders svg heredoc source tree blocks without spacer rows", async () => {
    const html = await renderShellInput(
      "cat > /tmp/a/output.svg <<'EOF'\n<svg></svg>\nEOF",
    );
    expect(html).toContain("source-tree-blocks");
    expect(html).toContain("source-tree-block-start");
    expect(html).toContain("source-tree-block-end");
    expect(html).toContain('title="Show source"');
    expect(html).toContain('alt="SVG preview"');
  });

  it("renders git log patch output with commit headers as a structured diff", () => {
    const output = [
      "commit abc123",
      "Author: Test <test@test>",
      "",
      "    init",
      "",
      "diff --git a/README.md b/README.md",
      "new file mode 100644",
      "index 0000000..9daeafb",
      "--- /dev/null",
      "+++ b/README.md",
      "@@ -0,0 +1 @@",
      "+test",
      "",
    ].join("\n");
    const result = makeResult(
      {
        isError: false,
        toolResult: {
          status: "completed",
          exitCode: 0,
          command: "git log -p -1 --no-color -- README.md",
        },
      },
      [{ type: "text", text: output }],
    );

    const html = renderToString(
      h(ToolCall, {
        name: "commandExecution",
        driver: "codex",
        input: { command: "git log -p -1 --no-color -- README.md" },
        result,
      }),
    );

    expect(html).toContain('data-testid="semantic-shell-diff"');
    expect(html).toContain("diff-view");
    expect(html).toContain('title="Show source"');
  });
});

describe("ToolCall numbered shell output", () => {
  const roots = ownedRoots();
  beforeEach(() => {
    useRealShellSemantic = true;
  });
  afterEach(() => {
    useRealShellSemantic = false;
  });
  const svg = '<svg xmlns="http://www.w3.org/2000/svg"></svg>\n';
  const numberedSvg = `     1\t${svg}`;

  async function mountResult(
    command: string,
    result: ToolResult,
    driver: "claude" | "codex" = "claude",
  ): Promise<HTMLDivElement> {
    const root = roots.create();
    await act(() => {
      roots.render(
        h(ToolCall, {
          name: driver === "claude" ? "Bash" : "commandExecution",
          driver,
          toolUseId: result.toolUseId,
          input: { command },
          result,
        }),
        root,
      );
    });
    await act(async () => {
      await parseShellSemantic(command);
    });
    if (!root.querySelector(".tool-result-container")) {
      await act(() => {
        root.querySelector<HTMLElement>(".tool-result-header")!.click();
      });
    }
    return root;
  }

  function expectNoPreview(root: HTMLElement): void {
    expect(
      root.querySelector(
        '[alt="SVG preview"], [title="Show rendered"], [title="Show source"]',
      ),
    ).toBeNull();
  }

  it.each([
    "git show HEAD:x.svg | nl -ba | sed -n 1,20p",
    "git show HEAD:x.svg | nl -ba | head -n 1",
  ])("renders numbering without preview for %s", async (command) => {
    const root = await mountResult(
      command,
      makeResult({ toolResult: { stdout: numberedSvg } }),
    );
    expect(
      root.querySelector('[data-testid="semantic-shell-block-nl-0"]'),
    ).not.toBeNull();
    expect(
      root.querySelector('[data-testid="semantic-shell-line-prefix"]')
        ?.textContent,
    ).toBe("     1\t");
    expectNoPreview(root);
  });

  it("keeps all stdout plain when an accepted plan's anchor appears twice", async () => {
    const stdout = `${numberedSvg}     2\t<!-- done -->\n<!-- done -->\n`;
    const root = await mountResult(
      "cat x.svg | nl -ba && echo '<!-- done -->'",
      makeResult({ toolResult: { stdout } }),
    );
    expect(
      root.querySelector('[data-testid="semantic-shell-output"]'),
    ).toBeNull();
    expect(root.querySelector("pre.tool-result")?.textContent).toBe(stdout);
    expectNoPreview(root);
  });

  it.each(["claude", "codex"] as const)(
    "preserves %s stdout on an error",
    async (driver) => {
      const toolResult =
        driver === "claude"
          ? { stdout: numberedSvg, stderr: "boom" }
          : { aggregatedOutput: numberedSvg };
      const root = await mountResult(
        "nl -ba x.svg",
        makeResult({ toolResult, isError: true }),
        driver,
      );
      expect(root.querySelector("pre.tool-result.error")?.textContent).toBe(
        numberedSvg,
      );
      if (driver === "claude") expect(root.textContent).toContain("boom");
      expectNoPreview(root);
    },
  );

  it.each(["nl -ba x.md", "head -2 x.md | nl -ba"])(
    "renders numbered markdown as text for %s",
    async (command) => {
      const root = await mountResult(
        command,
        makeResult({
          toolResult: { stdout: "     1\t# Title\n     2\tbody\n" },
        }),
      );
      const block = root.querySelector(
        '[data-testid="semantic-shell-block-nl-0"]',
      );
      expect(
        block?.querySelectorAll('[data-testid="semantic-shell-line-prefix"]'),
      ).toHaveLength(2);
      expect(block?.textContent).toContain("# Title");
      expect(block?.querySelector(".text-content, h1")).toBeNull();
      expectNoPreview(root);
    },
  );

  it.each([
    ["a payload CR before CRLF", "     1\talpha\r\r\n     2\tbeta\n"],
    ["CRLF file rows", "     1\tmodule probe;\r\n     2\tint x;\r\n"],
    [
      "a lone CR and U+2028",
      "     1\talpha\rinner\u2028separator\n     2\tbeta\n",
    ],
  ])("preserves %s after nl highlighting resolves", async (_name, stdout) => {
    const root = await mountResult(
      "nl -ba s.d",
      makeResult({ toolResult: { stdout } }),
    );
    const block = root.querySelector(
      '[data-testid="semantic-shell-block-nl-0"]',
    );
    expect(block).not.toBeNull();
    await vi.waitFor(async () => {
      await act(async () => {});
      expect(block?.querySelector("span[style*='color']")).not.toBeNull();
    });
    expect(block?.querySelector("pre")?.textContent).toBe(stdout);
  });

  it.each(["grep", "rg"])(
    "preserves %s context CRLF after highlighting resolves",
    async (tool) => {
      const stdout = "1-int a;\r\n2:int hit;\r\n--\n5-int c;\r\n6:int hit;\r\n";
      const root = await mountResult(
        `${tool} -n -B1 hit cr.d`,
        makeResult({ toolResult: { stdout } }),
      );
      const block = root.querySelector(
        '[data-testid="semantic-shell-block-rg-results"]',
      );
      expect(block?.querySelector(".search-group-separator")).not.toBeNull();
      await vi.waitFor(async () => {
        await act(async () => {});
        expect(block?.querySelector("span[style*='color']")).not.toBeNull();
      });
      expect(block?.querySelector("pre")?.textContent).toBe(stdout);
    },
  );

  it("renders a malformed separator ending in CR as raw stdout", async () => {
    const stdout = "1:x\n--\r";
    const root = await mountResult(
      "grep -n -B1 x cr.d",
      makeResult({ toolResult: { stdout } }),
    );
    expect(
      root.querySelector('[data-testid="semantic-shell-block-rg-results"]'),
    ).toBeNull();
    expect(root.querySelector(".search-group-separator")).toBeNull();
    expect(root.querySelector("pre.tool-result")?.textContent).toBe(stdout);
  });

  it("preserves an unterminated search row's payload CR after highlighting", async () => {
    const stdout = "1:x\r";
    const root = await mountResult(
      "grep -n -B1 x cr.d",
      makeResult({ toolResult: { stdout } }),
    );
    const block = root.querySelector(
      '[data-testid="semantic-shell-block-rg-results"]',
    );
    expect(block).not.toBeNull();
    await vi.waitFor(async () => {
      await act(async () => {});
      expect(block?.querySelector("span[style*='color']")).not.toBeNull();
    });
    expect(block?.querySelector("pre")?.textContent).toBe(stdout);
  });

  it.each(["cat -n x.svg", "nl -ba x.svg"])(
    "renders direct numbered SVG stdout without a preview for %s",
    async (command) => {
      const root = await mountResult(
        command,
        makeResult({ toolResult: { stdout: numberedSvg } }),
      );
      expect(
        root.querySelector(".tool-result-container pre")?.textContent,
      ).toBe(numberedSvg);
      expectNoPreview(root);
    },
  );

  it("renders unclassified numbered SVG stdout without a preview", async () => {
    const stdout =
      '     1\t<svg xmlns="http://www.w3.org/2000/svg">\n' +
      '     2\t  <rect width="10" height="10"/>\n' +
      "     3\t</svg>\n";
    const root = await mountResult(
      "nl -ba x.svg | tail | head -3",
      makeResult({ toolResult: { stdout } }),
    );
    expect(
      root.querySelector('[data-testid="semantic-shell-output"]'),
    ).toBeNull();
    expect(root.querySelector("pre.tool-result")?.textContent).toBe(stdout);
    expectNoPreview(root);
  });

  it("offers a preview for verbatim SVG", async () => {
    const root = await mountResult(
      "cat x.svg",
      makeResult({ toolResult: { stdout: svg } }),
    );
    expect(
      root.querySelector('[title="Show source"], [title="Show rendered"]'),
    ).not.toBeNull();
  });

  it("keeps the read renderer for an unnumbered git object", async () => {
    const root = await mountResult(
      "git show HEAD:x.svg",
      makeResult({ toolResult: { stdout: svg } }),
    );
    expect(
      root.querySelector('[data-testid="semantic-shell-read"]'),
    ).not.toBeNull();
  });

  it("offers an SVG preview through generic rendering for a rejected command", async () => {
    const root = await mountResult(
      "cat README.md | rev",
      makeResult({ toolResult: { stdout: svg } }),
    );
    expect(
      root.querySelector('[data-testid="semantic-shell-output"]'),
    ).toBeNull();
    expect(
      root.querySelector('[data-testid="semantic-shell-read"]'),
    ).toBeNull();
    expect(root.querySelector("pre.tool-result")?.textContent).toBe(svg);
    expect(root.querySelector('[title="Show rendered"]')).not.toBeNull();
  });
});

describe("ToolCall Copilot view output", () => {
  const roots = ownedRoots();

  it("preserves mixed line endings in highlighted numbered TypeScript", async () => {
    const content = "1. const a = 1;\r\n2. const b =\r 2;\n3. const c = 3;\r";
    const result = makeResult({}, content);
    const root = roots.create();
    await act(() => {
      roots.render(
        h(ToolCall, {
          name: "view",
          driver: "copilot",
          toolUseId: result.toolUseId,
          input: { path: "example.ts" },
          result,
        }),
        root,
      );
    });
    if (!root.querySelector("pre.tool-result")) {
      await act(() => {
        root.querySelector<HTMLElement>(".tool-result-header")!.click();
      });
    }
    await actPoll({
      description: "highlighted Copilot view output",
      ready: () =>
        root.querySelector("pre.tool-result span[style*='color']") !== null,
    });
    expect(root.querySelector("pre.tool-result")?.textContent).toBe(content);
  });
});

describe("ToolCall asynchronous shell source tree", () => {
  const roots = ownedRoots();

  function mountedShellInput(root: HTMLDivElement, command: string): void {
    roots.render(
      h(ToolCall, {
        name: "Bash",
        driver: "claude",
        toolUseId: "tool-mounted-shell",
        input: { command },
        result: undefined,
      }),
      root,
    );
  }

  it("keeps uncached commands raw and highlighted while parsing", async () => {
    const command = "printf pending-shell-source-tree";
    const pending = deferred<ParseResult>();
    const load = vi
      .spyOn(shellParser, "loadParsedShellDocument")
      .mockReturnValue(pending.promise);
    const root = roots.create();

    await act(() => {
      mountedShellInput(root, command);
    });
    expect(load).toHaveBeenCalledWith(command);
    expect(root.querySelector('[data-testid="source-tree-input"]')).toBeNull();
    expect(root.querySelector(".write-content")?.textContent).toContain(
      command,
    );

    await act(async () => {
      pending.resolve(successfulParse(command));
      await pending.promise;
    });
    load.mockRestore();
  });

  it("switches from raw fallback to a structured tree after parsing", async () => {
    const command = "python3 -c 'print(ready)'";
    const root = roots.create();

    await act(() => {
      mountedShellInput(root, command);
    });
    expect(root.querySelector(".write-content")).not.toBeNull();
    expect(root.querySelector('[data-testid="source-tree-input"]')).toBeNull();

    await act(async () => {
      await loadParsedShellDocument(command);
    });
    expect(
      root.querySelector('[data-testid="source-tree-input"]'),
    ).not.toBeNull();
  });

  it("keeps typed parser failures usable as raw command text", async () => {
    const command = "cat <<EOF\nunclosed";
    const root = roots.create();

    await act(async () => {
      mountedShellInput(root, command);
      await loadParsedShellDocument(command);
    });
    expect(root.querySelector('[data-testid="source-tree-input"]')).toBeNull();
    expect(root.querySelector(".write-content")?.textContent).toContain(
      command,
    );
  });

  it("renders a settled-cache remount as structured on its first render", async () => {
    const command = "python3 -c 'print(cache-hit)'";
    const originalLoad = shellParser.loadParsedShellDocument;
    let firstLoad: Promise<ParseResult> | undefined;
    const load = vi
      .spyOn(shellParser, "loadParsedShellDocument")
      .mockImplementation((source) => {
        const result = originalLoad(source);
        firstLoad = result;
        return result;
      });

    const root = roots.create();
    await act(() => {
      mountedShellInput(root, command);
    });
    expect(firstLoad).toBeDefined();
    if (!firstLoad) return;
    await act(async () => {
      await firstLoad;
    });
    expect(
      root.querySelector('[data-testid="source-tree-input"]'),
    ).not.toBeNull();

    await act(() => {
      roots.render(null, root);
      mountedShellInput(root, command);
      expect(load).toHaveBeenCalledTimes(1);
      expect(
        root.querySelector('[data-testid="source-tree-input"]'),
      ).not.toBeNull();
    });
  });

  it("ignores a stale completion when the command changes", async () => {
    const first = "printf stale-command";
    const second = "printf current-command";
    const firstPending = deferred<ParseResult>();
    const secondPending = deferred<ParseResult>();
    const load = vi
      .spyOn(shellParser, "loadParsedShellDocument")
      .mockImplementation((command) =>
        command === first ? firstPending.promise : secondPending.promise,
      );
    const root = roots.create();

    await act(() => {
      mountedShellInput(root, first);
    });
    await act(() => {
      mountedShellInput(root, second);
    });

    await act(async () => {
      firstPending.resolve(successfulParse(first));
      await firstPending.promise;
    });
    expect(root.querySelector('[data-testid="source-tree-input"]')).toBeNull();
    expect(root.querySelector(".write-content")?.textContent).toContain(second);

    await act(async () => {
      secondPending.resolve(successfulParse(second));
      await secondPending.promise;
    });
    expect(
      root.querySelector('[data-testid="source-tree-input"]'),
    ).not.toBeNull();
    expect(root.textContent).toContain(second);
    expect(root.textContent).not.toContain(first);
    load.mockRestore();
  });

  it("preserves semantic write, script, and wrapper selectors when ready", async () => {
    const cases = [
      ["cat > README.md <<EOF\n# Title\nEOF", "semantic-shell-write"],
      ["python - <<'PY'\nprint(\"hi\")\nPY", "semantic-shell-script"],
      ["zsh -lc 'cat README.md'", "semantic-shell-wrapper-input"],
    ] as const;

    for (const [command, selector] of cases) {
      const root = roots.create();
      await act(async () => {
        await loadParsedShellDocument(command);
        mountedShellInput(root, command);
        expect(
          root.querySelector(`[data-testid="${selector}"]`),
        ).not.toBeNull();
      });
    }
  });

  it("renders CRLF heredoc prefix, rich body, and suffix as separate blocks", async () => {
    const command = "python3 - <<EOF\r\nprint(1)\r\nEOF";
    const raw = renderToString(
      h(ToolCall, {
        name: "Bash",
        driver: "claude",
        toolUseId: "tool-crlf-raw",
        input: { command },
        result: undefined,
      }),
    );
    expect(raw).toContain("print(1)\r\nEOF");

    const root = roots.create();
    await act(async () => {
      await loadParsedShellDocument(command);
      roots.render(
        h(ToolCall, {
          name: "Bash",
          driver: "claude",
          toolUseId: "tool-crlf-ready",
          input: { command },
          result: undefined,
        }),
        root,
      );
    });
    const blocks = root.querySelectorAll("pre.write-content.source-tree-block");
    expect(blocks).toHaveLength(3);
    expect(blocks[0]?.textContent).toContain("python3 - <<EOF");
    expect(blocks[1]?.textContent).toBe("print(1)");
    expect(blocks[2]?.textContent).toBe("\r\nEOF");
  });

  it("preserves mixed line endings and escaped quotes in highlighted Bash input", async () => {
    // The backslash keeps the bare CR inside the parser's quoted word.
    const command =
      'python3 -c "print(\\"first\\")\r\nprint(\\"second\\")\nprint(\\\r\\"third\\")"';
    const root = roots.create();
    await act(async () => {
      await loadParsedShellDocument(command);
      mountedShellInput(root, command);
    });
    expect(
      root.querySelector('[data-testid="source-projected-inline"]'),
    ).not.toBeNull();
    await actPoll({
      description: "decoded Python strings projected across the CRLF",
      ready: () => {
        const spans = root.querySelectorAll(
          '[data-testid="source-projected-inline"] span[style*="color"]',
        );
        const renderedStrings = Array.from(spans, (span) => span.textContent);
        return (
          renderedStrings.includes('\\"first\\"') &&
          renderedStrings.includes('\\"second\\"')
        );
      },
    });
    const blocks = root.querySelectorAll("pre.write-content.source-tree-block");
    expect(Array.from(blocks, (block) => block.textContent).join("")).toBe(
      command,
    );
  });

  it("keeps nested adapter failures raw without leaking valid siblings", async () => {
    const commands = [
      "bash -c 'zsh -lc \"cat $HOME/README.md\"'",
      "bash -c 'zsh -lc \"cat $HOME/README.md\"' && python3 -c 'print(1)'",
    ];
    for (const command of commands) {
      const root = roots.create();
      const load = vi.spyOn(shellParser, "loadParsedShellDocument");
      await act(async () => {
        mountedShellInput(root, command);
        await loadParsedShellDocument(command);
      });
      expect(load).toHaveBeenCalledTimes(1);
      expect(
        root.querySelector('[data-testid="source-tree-input"]'),
      ).toBeNull();
      expect(
        root.querySelector('[data-testid="source-projected-inline"]'),
      ).toBeNull();
      expect(root.querySelector(".write-content")?.textContent).toContain(
        command,
      );

      await act(() => {
        roots.render(null, root);
        mountedShellInput(root, command);
        expect(load).toHaveBeenCalledTimes(1);
        expect(
          root.querySelector('[data-testid="source-tree-input"]'),
        ).toBeNull();
        expect(
          root.querySelector('[data-testid="source-projected-inline"]'),
        ).toBeNull();
        expect(root.querySelector(".write-content")?.textContent).toContain(
          command,
        );
      });
      load.mockRestore();
    }
  });
});

function renderClaudeToolInput(
  name: string,
  input: Record<string, unknown>,
  result?: ToolResult,
): string {
  return renderToString(
    h(ToolCall, {
      name,
      driver: "claude",
      toolUseId: "tool-1",
      input,
      result,
    }),
  );
}

describe("claude/TaskCreate rendering", () => {
  it("renders subject, description, activeForm, and task id badge", () => {
    const result: ToolResult = {
      toolUseId: "tool-1",
      content: "",
      isError: false,
      toolResult: { task: { id: "1", subject: "X" } },
    };
    const html = renderClaudeToolInput(
      "TaskCreate",
      { subject: "X", description: "Y", activeForm: "Z" },
      result,
    );
    expect(html).toContain("X");
    expect(html).toContain("Y");
    expect(html).toContain("Z");
    expect(html).toContain("#1");
  });
});

describe("claude/TaskUpdate rendering", () => {
  it("renders taskId, in-progress glyph, and todo-in_progress class", () => {
    const html = renderClaudeToolInput("TaskUpdate", {
      taskId: "1",
      status: "in_progress",
    });
    expect(html).toContain("#1");
    expect(html).toContain("▶");
    expect(html).toContain("todo-in_progress");
  });

  it("renders (deleted) label and no status glyph for deleted status", () => {
    const html = renderClaudeToolInput("TaskUpdate", {
      taskId: "1",
      status: "deleted",
    });
    expect(html).toContain("#1");
    expect(html).toContain("(deleted)");
    expect(html).not.toContain("todo-status");
  });

  it("renders extra fields via generic key/value layout", () => {
    const html = renderClaudeToolInput("TaskUpdate", {
      taskId: "1",
      status: "completed",
      subject: "new subject",
      owner: "alice",
    });
    expect(html).toContain("#1");
    expect(html).toContain("new subject");
    expect(html).toContain("alice");
  });
});

describe("claude/TaskList result rendering", () => {
  it("renders one todo-item per task with correct status classes", () => {
    const result: ToolResult = {
      toolUseId: "tool-1",
      content: "",
      isError: false,
      toolResult: {
        tasks: [
          { id: "1", subject: "Alpha", status: "pending" },
          { id: "2", subject: "Beta", status: "in_progress" },
          { id: "3", subject: "Gamma", status: "completed" },
        ],
      },
    };
    const html = renderClaudeToolInput("TaskList", {}, result);
    const todoItemCount = (html.match(/class="todo-item/g) ?? []).length;
    expect(todoItemCount).toBe(3);
    expect(html).toContain("todo-pending");
    expect(html).toContain("todo-in_progress");
    expect(html).toContain("todo-completed");
    expect(html).toContain("Alpha");
    expect(html).toContain("Beta");
    expect(html).toContain("Gamma");
  });
});

describe("claude/TaskGet result rendering", () => {
  it("renders task as todo-item with description when task is present", () => {
    const result: ToolResult = {
      toolUseId: "tool-1",
      content: "",
      isError: false,
      toolResult: {
        task: {
          id: "5",
          subject: "My Task",
          description: "Do the thing",
          status: "in_progress",
        },
      },
    };
    const html = renderClaudeToolInput("TaskGet", { taskId: "5" }, result);
    expect(html).toContain("todo-item");
    expect(html).toContain("My Task");
    expect(html).toContain("Do the thing");
  });

  it("falls back to generic rendering when task is null", () => {
    const result: ToolResult = {
      toolUseId: "tool-1",
      content: "",
      isError: false,
      toolResult: { task: null },
    };
    const html = renderClaudeToolInput("TaskGet", { taskId: "5" }, result);
    expect(html).not.toContain("todo-item");
  });
});

describe("MCP tool headers", () => {
  function renderMcpTool(toolServer: string): string {
    return renderToString(
      h(ToolCall, {
        name: "search_fetch",
        driver: "claude",
        toolServer,
        toolUseId: "mcp-1",
        input: { query: "x" },
      }),
    );
  }

  it("names the MCP server a tool comes from", () => {
    expect(renderMcpTool("kagi")).toContain(
      '<span title="MCP server kagi" class="tool-server">kagi</span>',
    );
  });

  it("marks CyDo's own tools with its logo instead", () => {
    const html = renderMcpTool("cydo");
    expect(html).not.toContain("tool-server");
    expect(html).toContain("cydo-tool-logo");
  });
});
