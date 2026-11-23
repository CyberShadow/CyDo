import { assert, beforeAll, describe, expect, it } from "vitest";
import { h } from "preact";
import renderToString from "preact-render-to-string";
import {
  hasSemanticShellOutput,
  SemanticShellOutput,
} from "./SemanticShellOutput";
import { derivePlan } from "../lib/commandStep";
import type { OutputPlan } from "../lib/outputPlan";
import { configureShellParserAssets } from "../lib/shellParser";
import { parseShellSemantic } from "../lib/shellSemantic";

const processLike = (
  globalThis as typeof globalThis & {
    process: { getBuiltinModule(name: string): unknown };
  }
).process;

beforeAll(async () => {
  const fs = processLike.getBuiltinModule("node:fs/promises") as {
    readFile(path: URL): Promise<Uint8Array>;
  };
  const [runtime, bashLanguage] = await Promise.all([
    fs.readFile(
      new URL(
        "../../node_modules/web-tree-sitter/web-tree-sitter.wasm",
        import.meta.url,
      ),
    ),
    fs.readFile(
      new URL(
        "../../node_modules/tree-sitter-bash/tree-sitter-bash.wasm",
        import.meta.url,
      ),
    ),
  ]);
  configureShellParserAssets({
    kind: "bytes",
    loadRuntime: () => Promise.resolve(new Uint8Array(runtime)),
    loadBashLanguage: () => Promise.resolve(new Uint8Array(bashLanguage)),
  });
});

function renderSemantic(stdout: string, outputPlan: OutputPlan): string {
  return renderToString(
    h(SemanticShellOutput, {
      stdout,
      outputPlan,
    }),
  );
}

describe("SemanticShellOutput renderable readback rendering", () => {
  it("renders complete from-cursor+end-of-output svg readback as preview with source toggle", () => {
    const stdout = '<svg xmlns="http://www.w3.org/2000/svg"></svg>\n';
    const outputPlan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "sed-output",
          source: {
            stepIndex: 0,
            producerName: "sed",
            filePath: "/tmp/cydo-heredoc-render.svg",
          },
          format: { kind: "content", language: "xml" },
          location: {
            kind: "from-cursor",
            end: { kind: "end-of-output", requiresComplete: true },
            validator: "non-empty",
          },
        },
      ],
    };

    const html = renderSemantic(stdout, outputPlan);
    expect(html).toContain('data-testid="semantic-shell-block-sed-output"');
    expect(html).toContain('alt="SVG preview"');
    expect(html).toContain('title="Show source"');
  });

  it("renders trailing ls+sed svg readback block as preview", () => {
    const stdout = [
      "-rw-r--r-- 1 user group 40 Jan 01 00:00 /tmp/cydo-heredoc-render.svg\n",
      '<svg xmlns="http://www.w3.org/2000/svg"></svg>\n',
    ].join("");
    const outputPlan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "listing",
          source: {
            stepIndex: 0,
            producerName: "ls",
            filePath: "/tmp/cydo-heredoc-render.svg",
          },
          format: { kind: "content", language: "shell-output" },
          location: {
            kind: "from-cursor",
            end: { kind: "line-count", count: 1 },
            validator: "non-empty",
          },
        },
        {
          id: "sed-output",
          source: {
            stepIndex: 1,
            producerName: "sed",
            filePath: "/tmp/cydo-heredoc-render.svg",
          },
          format: { kind: "content", language: "xml" },
          location: {
            kind: "from-cursor",
            end: { kind: "end-of-output", requiresComplete: true },
            validator: "non-empty",
          },
        },
      ],
    };

    const html = renderSemantic(stdout, outputPlan);
    expect(html).toContain('data-testid="semantic-shell-block-listing"');
    expect(html).toContain('data-testid="semantic-shell-block-sed-output"');
    expect(html).toContain('alt="SVG preview"');
  });

  it("renders mixed markdown and trailing svg readbacks from structured list", () => {
    const stdout = [
      "# Heredoc Markdown Fixture\n\n",
      "This file was written by a shell heredoc.\n",
      "\n--- svg ---\n",
      '<svg xmlns="http://www.w3.org/2000/svg"></svg>\n',
    ].join("");
    const outputPlan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "sed-0",
          source: {
            stepIndex: 0,
            producerName: "sed",
            filePath: "/tmp/cydo-heredoc-render.md",
          },
          format: { kind: "content", language: "markdown" },
          location: {
            kind: "from-cursor",
            end: { kind: "before-block", blockId: "printf-1" },
            validator: "non-empty",
          },
        },
        {
          id: "printf-1",
          source: { stepIndex: 1, producerName: "printf" },
          format: { kind: "content", language: "shell-output" },
          location: {
            kind: "unique-literal",
            text: "\n--- svg ---\n",
            include: "self",
          },
        },
        {
          id: "sed-2",
          source: {
            stepIndex: 2,
            producerName: "sed",
            filePath: "/tmp/cydo-heredoc-render.svg",
          },
          format: { kind: "content", language: "xml" },
          location: {
            kind: "from-cursor",
            end: { kind: "end-of-output", requiresComplete: true },
            validator: "non-empty",
          },
        },
      ],
    };

    const html = renderSemantic(stdout, outputPlan);
    expect(html).toContain('data-testid="semantic-shell-block-sed-0"');
    expect(html).toContain("<h1");
    expect(html).toContain("Heredoc Markdown Fixture");
    expect(html).toContain('data-testid="semantic-shell-block-printf-1"');
    expect(html).toContain("--- svg ---");
    expect(html).toContain('data-testid="semantic-shell-block-sed-2"');
    expect(html).toContain('alt="SVG preview"');
  });

  it("routes complete markdown readback through file content preview", () => {
    const stdout = "# Readback\n\n- item\n";
    const outputPlan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "sed-output",
          source: {
            stepIndex: 0,
            producerName: "sed",
            filePath: "/tmp/cydo-heredoc-render.md",
          },
          format: { kind: "content", language: "markdown" },
          location: {
            kind: "from-cursor",
            end: { kind: "end-of-output", requiresComplete: true },
            validator: "non-empty",
          },
        },
      ],
    };

    const html = renderSemantic(stdout, outputPlan);
    expect(html).toContain('data-testid="semantic-shell-block-sed-output"');
    expect(html).toContain("<h1");
    expect(html).toContain("Readback");
    expect(html).not.toContain("<pre");
  });

  it("keeps partial svg output as source-highlighted fallback", () => {
    const stdout = "<svg>\n";
    const outputPlan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "sed-output",
          source: {
            stepIndex: 0,
            producerName: "sed",
            filePath: "/tmp/cydo-heredoc-render.svg",
          },
          format: { kind: "content", language: "xml" },
          location: {
            kind: "from-cursor",
            end: { kind: "line-count", count: 1 },
            validator: "non-empty",
          },
        },
      ],
    };

    const html = renderSemantic(stdout, outputPlan);
    expect(html).toContain('data-testid="semantic-shell-block-sed-output"');
    expect(html).not.toContain('alt="SVG preview"');
    expect(html).toContain("&lt;svg>");
  });
});

const SVG_CONTENT =
  '<svg xmlns="http://www.w3.org/2000/svg"><circle r="10"/></svg>\n';

describe("SemanticShellOutput file-preview gate for cat/head/tail/nl producers", () => {
  // Discriminating signals used in this describe block:
  //   markdown file → "write-content-markdown" class (FileContentPreview path)
  //                   vs "text-content" class (StructuredContent fallback path).
  //   SVG file      → alt="SVG preview" present (FileContentPreview) vs absent
  //                   (StructuredContent renders XML as highlighted code instead).

  it("routes cat README.md output through file content preview (markdown rendered)", () => {
    const stdout = "# Hello\n\n- item\n";
    const outputPlan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "cat-0",
          source: {
            stepIndex: 0,
            producerName: "cat",
            filePath: "/repo/README.md",
          },
          format: { kind: "content", language: "markdown" },
          location: {
            kind: "from-cursor",
            end: { kind: "end-of-output", requiresComplete: true },
            validator: "non-empty",
          },
        },
      ],
    };

    const html = renderSemantic(stdout, outputPlan);
    expect(html).toContain('data-testid="semantic-shell-block-cat-0"');
    // "write-content-markdown" is the class used exclusively by FileContentPreview;
    // the StructuredContent fallback markdown path uses "text-content" instead.
    expect(html).toContain("write-content-markdown");
    expect(html).not.toContain("text-content");
  });

  it("routes head output of an SVG file through file content preview", () => {
    const outputPlan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "head-0",
          source: {
            stepIndex: 0,
            producerName: "head",
            filePath: "/repo/banner.svg",
          },
          format: { kind: "content", language: "xml" },
          location: {
            kind: "from-cursor",
            end: { kind: "end-of-output", requiresComplete: true },
            validator: "non-empty",
          },
        },
      ],
    };

    const html = renderSemantic(SVG_CONTENT, outputPlan);
    expect(html).toContain('data-testid="semantic-shell-block-head-0"');
    // File-preview path renders SVG as an image; the fallback would render XML
    // as highlighted code with no img element.
    expect(html).toContain('alt="SVG preview"');
  });

  it("routes tail output of an SVG file through file content preview", () => {
    const outputPlan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "tail-0",
          source: {
            stepIndex: 0,
            producerName: "tail",
            filePath: "/repo/banner.svg",
          },
          format: { kind: "content", language: "xml" },
          location: {
            kind: "from-cursor",
            end: { kind: "end-of-output", requiresComplete: true },
            validator: "non-empty",
          },
        },
      ],
    };

    const html = renderSemantic(SVG_CONTENT, outputPlan);
    expect(html).toContain('data-testid="semantic-shell-block-tail-0"');
    expect(html).toContain('alt="SVG preview"');
  });

  it("sed from-cursor end-of-output still routes through file content preview (regression)", () => {
    const stdout = "# Readback\n\n- item\n";
    const outputPlan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "sed-output",
          source: {
            stepIndex: 0,
            producerName: "sed",
            filePath: "/tmp/cydo-heredoc-render.md",
          },
          format: { kind: "content", language: "markdown" },
          location: {
            kind: "from-cursor",
            end: { kind: "end-of-output", requiresComplete: true },
            validator: "non-empty",
          },
        },
      ],
    };

    const html = renderSemantic(stdout, outputPlan);
    expect(html).toContain('data-testid="semantic-shell-block-sed-output"');
    expect(html).toContain("write-content-markdown");
    expect(html).not.toContain("text-content");
  });

  it("renders an nl-format SVG block as numbered source", () => {
    const outputPlan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "nl-0",
          source: {
            stepIndex: 0,
            producerName: "nl",
            filePath: "/repo/banner.svg",
          },
          format: {
            kind: "nl-line-number-prefixed",
            width: 6,
            separator: "\t",
            format: { kind: "content", language: "xml" },
          },
          location: {
            kind: "from-cursor",
            end: { kind: "end-of-output", requiresComplete: true },
            validator: "non-empty",
          },
        },
      ],
    };

    const html = renderSemantic(`     1\t${SVG_CONTENT}`, outputPlan);
    expect(html).toContain('data-testid="semantic-shell-block-nl-0"');
    expect(html).not.toContain('alt="SVG preview"');
  });

  it("renders numbered SVG output as source after slicing it with sed", async () => {
    const result = await parseShellSemantic("nl -ba /tmp/x.svg | sed -n 1,20p");
    assert(result.ok && result.value.steps);
    const outputPlan = derivePlan(result.value.steps);
    assert(outputPlan);

    const html = renderSemantic(`     1\t${SVG_CONTENT}`, outputPlan);
    expect(html).not.toContain('alt="SVG preview"');
    expect(html).toContain(
      'data-testid="semantic-shell-line-prefix" class="line-number">     1\t</span>',
    );
    expect(html).toContain("&lt;svg");
  });

  it.each(["sed -n 1,20p", "head -n 1"])(
    "keeps a numbered git-object SVG out of file preview after %s",
    async (slice) => {
      const result = await parseShellSemantic(
        `git show HEAD:x.svg | nl -ba | ${slice}`,
      );
      assert(result.ok && result.value.steps);
      expect(result.value.commandName).toBe("git");
      const outputPlan = derivePlan(result.value.steps);
      assert(outputPlan);

      const html = renderSemantic(`     1	${SVG_CONTENT}`, outputPlan);
      expect(html).toContain('data-testid="semantic-shell-block-nl-0"');
      expect(html).not.toContain('alt="SVG preview"');
    },
  );

  it.each([
    ["nl x.d", "       \n", "       ", 1],
    ["nl -w 2 -s 'é' x.md", "    \n    \n", "    ", 2],
    ["nl ./page.d", "\n", "", 1],
  ])(
    "uses gutter rendering for whitespace-only GNU nl output from %s",
    async (command, stdout, prefix, count) => {
      const result = await parseShellSemantic(command);
      assert(result.ok && result.value.steps);
      const outputPlan = derivePlan(result.value.steps);
      assert(outputPlan);
      const html = renderSemantic(stdout, outputPlan);
      expect(html).toContain('data-testid="semantic-shell-block-nl-0"');
      const prefixes = html.match(
        /data-testid="semantic-shell-line-prefix" class="line-number"> *<\/span>/g,
      );
      expect(prefixes).toEqual(
        Array<string>(count).fill(
          `data-testid="semantic-shell-line-prefix" class="line-number">${prefix}</span>`,
        ),
      );
    },
  );

  it("leaves a lone CR outside the numbered output renderer", async () => {
    const result = await parseShellSemantic("nl x.d");
    assert(result.ok && result.value.steps);
    const outputPlan = derivePlan(result.value.steps);
    assert(outputPlan);
    expect(renderSemantic("\r", outputPlan)).toBe("");
  });

  it("renders a derived numbered markdown plan as literal text", async () => {
    const result = await parseShellSemantic("nl -ba /repo/README.md");
    assert(result.ok && result.value.steps);
    const outputPlan = derivePlan(result.value.steps);
    assert(outputPlan);
    const html = renderSemantic("     1\t# Title\n     2\tbody\n", outputPlan);
    expect(html).toContain('data-testid="semantic-shell-block-nl-0"');
    expect(html).toContain(
      'data-testid="semantic-shell-line-prefix" class="line-number">     1\t</span>',
    );
    expect(html).toContain(
      'data-testid="semantic-shell-line-prefix" class="line-number">     2\t</span>',
    );
    expect(html).toContain("# Title");
    expect(html).not.toContain("text-content");
  });

  // Same SVG probe for an unfamiliar producer.
  it("unknown producer does not get file content preview — SVG is not rendered as image", () => {
    const outputPlan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "unknown-0",
          source: {
            stepIndex: 0,
            producerName: "zcat",
            filePath: "/repo/banner.svg",
          },
          format: { kind: "content", language: "xml" },
          location: {
            kind: "from-cursor",
            end: { kind: "end-of-output", requiresComplete: true },
            validator: "non-empty",
          },
        },
      ],
    };

    const html = renderSemantic(SVG_CONTENT, outputPlan);
    expect(html).toContain('data-testid="semantic-shell-block-unknown-0"');
    expect(html).not.toContain('alt="SVG preview"');
  });
});

describe("SemanticShellOutput numbered search context", () => {
  async function reportedSearchPlan(): Promise<OutputPlan> {
    const result = await parseShellSemantic(
      'cd /mnt/local/moved/home/vladimir/work/.cydo/tasks/39201/worktree && grep -n "backfillHistoryBoundary" -B3 -A60 source/cydo/workflow/history/pipeline.d | sed -n 1,150p',
    );
    assert(result.ok && result.value.steps);
    const outputPlan = derivePlan(result.value.steps);
    assert(outputPlan);
    return outputPlan;
  }

  it("renders search output starting inside a context group", async () => {
    const outputPlan = await reportedSearchPlan();
    const stdout = [
      "58-    }",
      "59-",
      "60-    // Restore the history boundary.",
      "61:    void backfillHistoryBoundary(ref Ledger l) {",
      "62-        auto b = l.boundary;",
      "--",
      "140:    backfillHistoryBoundary(ledger);",
      "141-}",
      "",
    ].join("\n");

    const html = renderSemantic(stdout, outputPlan);
    expect(html).toContain('data-testid="semantic-shell-output-search"');
    expect(html).toContain('data-testid="semantic-shell-block-rg-results"');
    expect(html).not.toContain("semantic-shell-raw");
    for (const prefix of ["58-", "61:", "140:"]) {
      expect(html).toContain(
        `data-testid="semantic-shell-line-prefix" class="line-number">${prefix}</span>`,
      );
    }
    expect(
      html.match(/<span class="search-group-separator">--<\/span>/g),
    ).toHaveLength(1);
  });

  it("falls back to raw output when a row has no valid search prefix", async () => {
    const outputPlan = await reportedSearchPlan();
    const stdout =
      "58-    }\ninvalid row\n140:    backfillHistoryBoundary(ledger);\n";

    expect(hasSemanticShellOutput(stdout, outputPlan)).toBe(false);
    expect(renderSemantic(stdout, outputPlan)).toBe("");
  });
});
