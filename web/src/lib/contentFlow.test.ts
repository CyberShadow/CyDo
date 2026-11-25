import { describe, expect, it } from "vitest";
import {
  buildFlowSourceTree,
  resolveFlowLanguage,
  type FlowSink,
  type FlowSource,
} from "./contentFlow";
import { projectDescendantSpan } from "./sourceTree";

function file(
  path: string,
  mode: "overwrite" | "append" = "overwrite",
): FlowSink {
  return { kind: "file", path, mode };
}

describe("resolveFlowLanguage", () => {
  it.each<{
    name: string;
    sinks: FlowSink[];
    language: string;
    filePath?: string;
  }>([
    {
      name: "a single typed file",
      sinks: [file("doc.md")],
      language: "markdown",
      filePath: "doc.md",
    },
    {
      name: "a program",
      sinks: [{ kind: "program", language: "python", channel: "stdin" }],
      language: "python",
    },
    { name: "discard", sinks: [{ kind: "discard" }], language: "text" },
    {
      name: "tool output",
      sinks: [{ kind: "tool-output" }],
      language: "text",
    },
    { name: "an unknown sink", sinks: [{ kind: "unknown" }], language: "text" },
    {
      name: "different files with the same language",
      sinks: [file("a.md"), file("b.md")],
      language: "markdown",
    },
    {
      name: "files with conflicting languages",
      sinks: [file("a.md"), file("b.py")],
      language: "text",
    },
    {
      name: "an untyped file alongside a typed file",
      sinks: [file("log.txt"), file("doc.md")],
      language: "markdown",
      filePath: "doc.md",
    },
    {
      name: "the same path twice",
      sinks: [file("doc.md"), file("doc.md", "append")],
      language: "markdown",
      filePath: "doc.md",
    },
    {
      name: "a program and a file with the same language",
      sinks: [
        file("main.py"),
        { kind: "program", language: "python", channel: "argv" },
      ],
      language: "python",
    },
  ])("resolves $name", ({ sinks, language, filePath }) => {
    expect(resolveFlowLanguage(sinks)).toEqual({
      language,
      document: filePath === undefined ? null : { filePath },
    });
  });
});

function literal(start: number, text: string, language: string): FlowSource {
  return {
    span: { start, end: start + text.length },
    layout: "inline",
    origin: { language: "bash", construct: "command-wrapper-payload" },
    value: {
      text,
      projection: {
        points: [
          { child: 0, parent: 0 },
          { child: text.length, parent: text.length },
        ],
      },
    },
    sinks: [{ kind: "program", language, channel: "argv" }],
    child: null,
  };
}

describe("buildFlowSourceTree", () => {
  it("selects the widest source at a shared start and skips later overlaps", () => {
    const tree = buildFlowSourceTree({
      language: "bash",
      text: "0123456789",
      sources: [
        literal(7, "7", "json"),
        literal(1, "12", "python"),
        literal(3, "3456", "python"),
        literal(1, "1234", "markdown"),
      ],
    });

    expect(tree.segments).toMatchObject([
      { kind: "text", span: { start: 0, end: 1 } },
      {
        kind: "embed",
        span: { start: 1, end: 5 },
        content: { language: "markdown", text: "1234" },
      },
      { kind: "text", span: { start: 5, end: 7 } },
      {
        kind: "embed",
        span: { start: 7, end: 8 },
        content: { language: "json", text: "7" },
      },
      { kind: "text", span: { start: 8, end: 10 } },
    ]);
  });

  it("projects a nested decoded span back through both enclosing literals", () => {
    const shellText = String.raw`x\ny`;
    const tree = buildFlowSourceTree({
      language: "javascript",
      text: String.raw`run(x\\ny)`,
      sources: [
        {
          ...literal(4, shellText, "bash"),
          span: { start: 4, end: 9 },
          origin: { language: "javascript", construct: "string-literal" },
          value: {
            text: shellText,
            projection: {
              points: [
                { child: 0, parent: 0 },
                { child: 1, parent: 1 },
                { child: 2, parent: 3 },
                { child: 4, parent: 5 },
              ],
            },
          },
          child: {
            language: "bash",
            text: shellText,
            sources: [
              {
                ...literal(1, "\n", "python"),
                span: { start: 1, end: 3 },
                value: {
                  text: "\n",
                  projection: {
                    points: [
                      { child: 0, parent: 0 },
                      { child: 1, parent: 2 },
                    ],
                  },
                },
              },
            ],
          },
        },
      ],
    });

    expect(tree.segments[1]).toMatchObject({
      kind: "embed",
      content: {
        language: "bash",
        text: shellText,
        segments: [
          { kind: "text", span: { start: 0, end: 1 } },
          {
            kind: "embed",
            span: { start: 1, end: 3 },
            content: { language: "python", text: "\n" },
          },
          { kind: "text", span: { start: 3, end: 4 } },
        ],
      },
    });
    expect(projectDescendantSpan(tree, [1, 1], { start: 0, end: 1 })).toEqual({
      start: 5,
      end: 8,
    });
  });

  it.each([
    { layout: "block", language: "markdown", presentation: "rich" },
    { layout: "inline", language: "markdown", presentation: "inline" },
    { layout: "block", language: "bash", presentation: "inline" },
    { layout: "block", language: "text", presentation: "inline" },
  ] as const)(
    "renders $layout $language content as $presentation",
    ({ layout, language, presentation }) => {
      const text = "# Title\n";
      const tree = buildFlowSourceTree({
        language: "bash",
        text,
        sources: [{ ...literal(0, text, language), layout }],
      });

      expect(tree.segments).toHaveLength(1);
      const segment = tree.segments[0];
      expect(segment).toMatchObject({ kind: "embed", content: { language } });
      expect(
        segment?.kind === "embed" && (segment.presentation?.kind ?? "inline"),
      ).toBe(presentation);
    },
  );
});
