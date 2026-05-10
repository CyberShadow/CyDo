import { describe, expect, it } from "vitest";
import { h } from "preact";
import renderToString from "preact-render-to-string";
import { SemanticShellOutput } from "./SemanticShellOutput";
import type { OutputPlan } from "../lib/outputPlan";

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

  // nl is excluded from FILE_PREVIEW_PRODUCERS because its output carries
  // line-number prefixes ("    1\t…") that are not part of the source file.
  // Rendering nl output as a file preview would corrupt the content.
  // Using an SVG file here so the two paths produce distinguishable DOM:
  // preview would render an <img> element; the non-preview path renders XML code.
  it("nl output does NOT get file content preview — SVG is not rendered as image", () => {
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
    expect(html).toContain('data-testid="semantic-shell-block-nl-0"');
    expect(html).not.toContain('alt="SVG preview"');
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
