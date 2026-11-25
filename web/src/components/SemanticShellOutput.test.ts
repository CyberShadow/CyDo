import { assert, beforeAll, describe, expect, it } from "vitest";
import { h } from "preact";
import renderToString from "preact-render-to-string";
import {
  hasSemanticShellOutput,
  SemanticShellOutput,
} from "./SemanticShellOutput";
import { shellOutputView } from "../lib/shellOutput";
import type { OutputPlan } from "../lib/outputPlan";
import { configureTreeSitterAssets } from "../lib/treeSitterRuntime";
import { installedTreeSitterBytes } from "../test-support/treeSitterAssets";
import { parseShellSemantic } from "../lib/shellSemantic";

beforeAll(() => {
  configureTreeSitterAssets(installedTreeSitterBytes);
});

function renderSemantic(
  stdout: string,
  outputPlan: OutputPlan,
  search = false,
): string {
  return renderToString(
    h(SemanticShellOutput, {
      stdout,
      outputPlan,
      search,
    }),
  );
}

it("falls back when a literal overlaps the final numbered row", async () => {
  const result = await parseShellSemantic("cat -n b.py && printf 'aa'");
  assert(result.ok && result.value.kind === "output");
  const view = shellOutputView(result.value.output);
  assert(view.ok && view.value.kind === "plan");

  const stdout = "     1\taaa";
  expect(hasSemanticShellOutput(stdout, view.value.plan)).toBe(false);
  expect(renderSemantic(stdout, view.value.plan)).toBe("");
});

describe("SemanticShellOutput renderable readback rendering", () => {
  it("renders complete from-cursor+end-of-output svg readback as preview with source toggle", () => {
    const stdout = '<svg xmlns="http://www.w3.org/2000/svg"></svg>\n';
    const outputPlan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "0",
          document: { filePath: "/tmp/cydo-heredoc-render.svg", preview: true },
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
    expect(html).toContain('data-testid="semantic-shell-block-0"');
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
          id: "0",
          format: { kind: "content", language: "shell-output" },
          location: {
            kind: "from-cursor",
            end: { kind: "line-count", count: 1 },
            validator: "non-empty",
          },
        },
        {
          id: "1",
          document: { filePath: "/tmp/cydo-heredoc-render.svg", preview: true },
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
    expect(html).toContain('data-testid="semantic-shell-block-0"');
    expect(html).toContain('data-testid="semantic-shell-block-1"');
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
          id: "0",
          document: { filePath: "/tmp/cydo-heredoc-render.md", preview: false },
          format: { kind: "content", language: "markdown" },
          location: {
            kind: "from-cursor",
            end: { kind: "before-block", blockId: "1" },
            validator: "non-empty",
          },
        },
        {
          id: "1",
          format: { kind: "content", language: "shell-output" },
          location: {
            kind: "unique-literal",
            text: "\n--- svg ---\n",
            include: "self",
          },
        },
        {
          id: "2",
          document: { filePath: "/tmp/cydo-heredoc-render.svg", preview: true },
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
    expect(html).toContain('data-testid="semantic-shell-block-0"');
    expect(html).toContain("<h1");
    expect(html).toContain("Heredoc Markdown Fixture");
    expect(html).toContain('data-testid="semantic-shell-block-1"');
    expect(html).toContain("--- svg ---");
    expect(html).toContain('data-testid="semantic-shell-block-2"');
    expect(html).toContain('alt="SVG preview"');
  });

  it("routes complete markdown readback through file content preview", () => {
    const stdout = "# Readback\n\n- item\n";
    const outputPlan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "0",
          document: { filePath: "/tmp/cydo-heredoc-render.md", preview: true },
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
    expect(html).toContain('data-testid="semantic-shell-block-0"');
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
          id: "0",
          document: {
            filePath: "/tmp/cydo-heredoc-render.svg",
            preview: false,
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
    expect(html).toContain('data-testid="semantic-shell-block-0"');
    expect(html).not.toContain('alt="SVG preview"');
    expect(html).toContain("&lt;svg>");
  });
});

const SVG_CONTENT =
  '<svg xmlns="http://www.w3.org/2000/svg"><circle r="10"/></svg>\n';

describe("SemanticShellOutput document and numbered rendering", () => {
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
          id: "0",
          document: { filePath: "/repo/README.md", preview: true },
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
    expect(html).toContain('data-testid="semantic-shell-block-0"');
    // "write-content-markdown" is the class used exclusively by FileContentPreview;
    // the StructuredContent fallback markdown path uses "text-content" instead.
    expect(html).toContain("write-content-markdown");
    expect(html).not.toContain("text-content");
  });

  it("renders unpositioned Markdown rows as source", async () => {
    const result = await parseShellSemantic("tail x.md | head -2");
    assert(result.ok && result.value.kind === "output");
    const view = shellOutputView(result.value.output);
    assert(view.ok && view.value.kind === "plan");

    const html = renderSemantic("# T\nbody\n", view.value.plan);
    expect(html).toContain('data-testid="semantic-shell-block-0"');
    expect(html).toContain("# T");
    expect(html).not.toContain("semantic-shell-raw");
    expect(html).not.toContain("text-content");
    expect(html).not.toContain("<h1");
    expect(html).not.toContain('title="Show rendered"');
    expect(html).not.toContain('title="Show source"');
  });

  it("renders unpositioned SVG rows as one source block", async () => {
    const result = await parseShellSemantic("tail x.svg | head -2");
    assert(result.ok && result.value.kind === "output");
    const view = shellOutputView(result.value.output);
    assert(view.ok && view.value.kind === "plan");

    const html = renderSemantic(SVG_CONTENT, view.value.plan);
    expect(html).not.toContain('alt="SVG preview"');
    expect(
      html.match(/data-testid="semantic-shell-block-[^"]+"/g),
    ).toHaveLength(1);
    expect(html).not.toContain("semantic-shell-raw");
    expect(html).toContain("&lt;svg");
  });

  it("renders concatenated D files in one source block", async () => {
    const result = await parseShellSemantic("cat a.d b.d");
    assert(result.ok && result.value.kind === "output");
    const view = shellOutputView(result.value.output);
    assert(view.ok && view.value.kind === "plan");

    const stdout = "module a;\nvoid f() {}\nmodule b;\n";
    const html = renderSemantic(stdout, view.value.plan);
    expect(html.match(/data-testid="semantic-shell-block-0"/g)).toHaveLength(1);
    expect(html).toContain(stdout);
    expect(html).not.toContain("semantic-shell-raw");
  });

  it("renders concatenated SVG files in one source block without a preview", async () => {
    const result = await parseShellSemantic("cat a.svg b.svg");
    assert(result.ok && result.value.kind === "output");
    const view = shellOutputView(result.value.output);
    assert(view.ok && view.value.kind === "plan");

    const stdout = `${SVG_CONTENT}\n${SVG_CONTENT}\n`;
    const html = renderSemantic(stdout, view.value.plan);
    expect(html.match(/data-testid="semantic-shell-block-0"/g)).toHaveLength(1);
    expect(html).not.toContain("semantic-shell-raw");
    expect(html).not.toContain('alt="SVG preview"');
    expect(html).toContain("&lt;svg");
  });

  it("renders concatenated Markdown files as source", async () => {
    const result = await parseShellSemantic("cat a.md b.md");
    assert(result.ok && result.value.kind === "output");
    const view = shellOutputView(result.value.output);
    assert(view.ok && view.value.kind === "plan");

    const stdout = "# A\n# B\n";
    const html = renderSemantic(stdout, view.value.plan);
    expect(html).toContain('data-testid="semantic-shell-block-0"');
    expect(html).toContain(stdout);
    expect(html).not.toContain("text-content");
    expect(html).not.toContain("<h1");
  });

  it("routes head output of an SVG file through file content preview", () => {
    const outputPlan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "0",
          document: { filePath: "/repo/banner.svg", preview: true },
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
    expect(html).toContain('data-testid="semantic-shell-block-0"');
    // File-preview path renders SVG as an image; the fallback would render XML
    // as highlighted code with no img element.
    expect(html).toContain('alt="SVG preview"');
  });

  it("routes tail output of an SVG file through file content preview", () => {
    const outputPlan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "0",
          document: { filePath: "/repo/banner.svg", preview: true },
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
    expect(html).toContain('data-testid="semantic-shell-block-0"');
    expect(html).toContain('alt="SVG preview"');
  });

  it("sed from-cursor end-of-output still routes through file content preview (regression)", () => {
    const stdout = "# Readback\n\n- item\n";
    const outputPlan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "0",
          document: { filePath: "/tmp/cydo-heredoc-render.md", preview: true },
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
    expect(html).toContain('data-testid="semantic-shell-block-0"');
    expect(html).toContain("write-content-markdown");
    expect(html).not.toContain("text-content");
  });

  it("renders an nl-format SVG block as numbered source", () => {
    const outputPlan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "0",
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
    expect(html).toContain('data-testid="semantic-shell-block-0"');
    expect(html).not.toContain('alt="SVG preview"');
  });

  it("renders numbered SVG output as source after slicing it with sed", async () => {
    const result = await parseShellSemantic("nl -ba /tmp/x.svg | sed -n 1,20p");
    assert(result.ok && result.value.kind === "output");
    const view = shellOutputView(result.value.output);
    assert(view.ok && view.value.kind === "plan");
    const outputPlan = view.value.plan;

    const html = renderSemantic(`     1\t${SVG_CONTENT}`, outputPlan);
    expect(html).not.toContain('alt="SVG preview"');
    expect(html).toContain(
      'data-testid="semantic-shell-line-prefix" class="line-number">     1\t</span>',
    );
    expect(html).toContain("&lt;svg");
  });

  it("renders two line prefixes when nl numbers a sed range", async () => {
    const result = await parseShellSemantic("sed -n 10,20p x.d | nl");
    assert(result.ok && result.value.kind === "output");
    const view = shellOutputView(result.value.output);
    assert(view.ok && view.value.kind === "plan");

    const html = renderSemantic("     1\tint x;\n     2\t}\n", view.value.plan);
    expect(
      html.match(/<span data-testid="semantic-shell-line-prefix"/g),
    ).toHaveLength(2);
  });

  it.each(["sed -n 1,20p", "head -n 1"])(
    "keeps a numbered git-object SVG out of file preview after %s",
    async (slice) => {
      const result = await parseShellSemantic(
        `git show HEAD:x.svg | nl -ba | ${slice}`,
      );
      assert(result.ok && result.value.kind === "output");
      const view = shellOutputView(result.value.output);
      assert(view.ok && view.value.kind === "plan");
      const outputPlan = view.value.plan;

      const html = renderSemantic(`     1	${SVG_CONTENT}`, outputPlan);
      expect(html).toContain('data-testid="semantic-shell-block-0"');
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
      assert(result.ok && result.value.kind === "output");
      const view = shellOutputView(result.value.output);
      assert(view.ok && view.value.kind === "plan");
      const outputPlan = view.value.plan;
      const html = renderSemantic(stdout, outputPlan);
      expect(html).toContain('data-testid="semantic-shell-block-0"');
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
    assert(result.ok && result.value.kind === "output");
    const view = shellOutputView(result.value.output);
    assert(view.ok && view.value.kind === "plan");
    const outputPlan = view.value.plan;
    expect(renderSemantic("\r", outputPlan)).toBe("");
  });

  it("renders a derived numbered markdown plan as literal text", async () => {
    const result = await parseShellSemantic("nl -ba /repo/README.md");
    assert(result.ok && result.value.kind === "output");
    const view = shellOutputView(result.value.output);
    assert(view.ok && view.value.kind === "plan");
    const outputPlan = view.value.plan;
    const html = renderSemantic("     1\t# Title\n     2\tbody\n", outputPlan);
    expect(html).toContain('data-testid="semantic-shell-block-0"');
    expect(html).toContain(
      'data-testid="semantic-shell-line-prefix" class="line-number">     1\t</span>',
    );
    expect(html).toContain(
      'data-testid="semantic-shell-line-prefix" class="line-number">     2\t</span>',
    );
    expect(html).toContain("# Title");
    expect(html).not.toContain("text-content");
  });

  it("renders SVG content without a document as source", () => {
    const outputPlan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "0",
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
    expect(html).toContain('data-testid="semantic-shell-block-0"');
    expect(html).not.toContain('alt="SVG preview"');
  });
});

it("renders adjacent searches as one numbered search result", async () => {
  const result = await parseShellSemantic("grep -n x a.d && grep -n y b.d");
  assert(result.ok && result.value.kind === "output");
  const view = shellOutputView(result.value.output);
  assert(view.ok && view.value.kind === "plan");

  const html = renderSemantic("3:x\n7:y\n", view.value.plan, view.value.search);
  expect(html).toContain('data-testid="semantic-shell-output-search"');
  expect(html).not.toContain("semantic-shell-raw");
  expect(
    html.match(
      /data-testid="semantic-shell-line-prefix" class="line-number">[^<]*<\/span>/g,
    ),
  ).toEqual([
    'data-testid="semantic-shell-line-prefix" class="line-number">3:</span>',
    'data-testid="semantic-shell-line-prefix" class="line-number">7:</span>',
  ]);
});

describe("SemanticShellOutput numbered search context", () => {
  async function reportedSearchView() {
    const result = await parseShellSemantic(
      'cd /mnt/local/moved/home/vladimir/work/.cydo/tasks/39201/worktree && grep -n "backfillHistoryBoundary" -B3 -A60 source/cydo/workflow/history/pipeline.d | sed -n 1,150p',
    );
    assert(result.ok && result.value.kind === "output");
    const view = shellOutputView(result.value.output);
    assert(view.ok && view.value.kind === "plan");
    return view.value;
  }

  it("renders search output starting inside a context group", async () => {
    const { plan: outputPlan, search } = await reportedSearchView();
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

    const html = renderSemantic(stdout, outputPlan, search);
    expect(html).toContain('data-testid="semantic-shell-output-search"');
    expect(html).toContain('data-testid="semantic-shell-block-0"');
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
    const { plan: outputPlan, search } = await reportedSearchView();
    const stdout =
      "58-    }\ninvalid row\n140:    backfillHistoryBoundary(ledger);\n";

    expect(hasSemanticShellOutput(stdout, outputPlan)).toBe(false);
    expect(renderSemantic(stdout, outputPlan, search)).toBe("");
  });
});
