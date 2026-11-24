import { describe, expect, it } from "vitest";
import {
  type OutputPlan,
  parseNlOutputRow,
  splitOutputRows,
  parseNumberedOutputRow,
  type SpanValidatorId,
  segmentOutput,
  type SegmentedOutputPiece,
} from "./outputPlan";

function assertCoverage(stdout: string, pieces: SegmentedOutputPiece[]) {
  expect(pieces.length).toBeGreaterThan(0);
  let cursor = 0;
  for (const piece of pieces) {
    expect(piece.start).toBe(cursor);
    expect(piece.end).toBeGreaterThanOrEqual(piece.start);
    cursor = piece.end;
  }
  expect(cursor).toBe(stdout.length);
}

it("consumes CR only as part of CRLF", () => {
  expect(Array.from(splitOutputRows("x\ry\r\n--\r"))).toEqual([
    { text: "x\ry", terminator: "\r\n" },
    { text: "--\r", terminator: "" },
  ]);
  expect(Array.from(splitOutputRows("\r"))).toEqual([
    { text: "\r", terminator: "" },
  ]);
});

describe("nl output rows", () => {
  it.each([
    ["     1\ta", "     1\t", "a"],
    ["     2\t", "     2\t", ""],
    ["       ", "       ", ""],
    ["       H", "       ", "H"],
    ["", "", ""],
    ["1234567\tx", "1234567\t", "x"],
  ])("parses %j with the default gutter", (line, prefix, text) => {
    expect(parseNlOutputRow(line, { width: 6, separator: "\t" })).toEqual({
      prefix,
      text,
    });
  });

  it.each(["    1\ta", "1\ta", "     1 a", "      a", "x"])(
    "rejects %j with the default gutter",
    (line) => {
      expect(parseNlOutputRow(line, { width: 6, separator: "\t" })).toBeNull();
    },
  );

  it("validates custom width and separator", () => {
    const options = { width: 2, separator: ": " };
    expect(parseNlOutputRow(" 1: a", options)).toEqual({
      prefix: " 1: ",
      text: "a",
    });
    expect(parseNlOutputRow("    ", options)).toEqual({
      prefix: "    ",
      text: "",
    });
    expect(parseNlOutputRow(" 1:a", options)).toBeNull();
  });

  it("uses GNU's byte width for the unnumbered padding", () => {
    const options = { width: 2, separator: "界" };
    expect(parseNlOutputRow("     H", options)).toEqual({
      prefix: "     ",
      text: "H",
    });
    expect(parseNlOutputRow(" 1界a", options)).toEqual({
      prefix: " 1界",
      text: "a",
    });
  });

  it("rejects a short field even for a width above the string size limit", () => {
    expect(
      parseNlOutputRow("     1\ta", {
        width: Number.MAX_SAFE_INTEGER,
        separator: "\t",
      }),
    ).toBeNull();
  });

  it.each([
    ["     1\ta\r\n       H\n\n     2\t\n", "structured"],
    ["     1\ta\nno gutter\n", "raw"],
    ["", "raw"],
    ["\r", "raw"],
  ])("segments %j as %s", (stdout, kind) => {
    const plan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "0",
          format: {
            kind: "nl-line-number-prefixed",
            width: 6,
            separator: "\t",
            format: { kind: "content", language: "text" },
          },
          location: {
            kind: "from-cursor",
            end: { kind: "end-of-output", requiresComplete: true },
          },
        },
      ],
    };
    expect(
      segmentOutput(stdout, plan, { kind: "complete" }).pieces,
    ).toMatchObject([{ kind, start: 0, end: stdout.length }]);
  });
});

describe("parseNumberedOutputRow", () => {
  it.each([
    [
      "12:a:b",
      {
        kind: "numbered",
        lineNumber: 12,
        delimiter: ":",
        prefix: "12:",
        text: "a:b",
      },
    ],
    [
      "13-foo: bar",
      {
        kind: "numbered",
        lineNumber: 13,
        delimiter: "-",
        prefix: "13-",
        text: "foo: bar",
      },
    ],
    [
      "13-left\rright\u2028above\u2029below",
      {
        kind: "numbered",
        lineNumber: 13,
        delimiter: "-",
        prefix: "13-",
        text: "left\rright\u2028above\u2029below",
      },
    ],
    ["13-multiple\nrows", null],
    [
      "1:x\r",
      {
        kind: "numbered",
        lineNumber: 1,
        delimiter: ":",
        prefix: "1:",
        text: "x\r",
      },
    ],
    ["--\r", null],
    ["--", { kind: "group-separator" }],
    ["-- x", null],
    ["--5", null],
    ["x:1", null],
    [":1", null],
    ["", null],
  ])("parses %j", (row, expected) => {
    expect(parseNumberedOutputRow(row)).toEqual(expected);
  });
});

describe("numbered output span validation", () => {
  it.each<[SpanValidatorId, string, "structured" | "raw"]>([
    ["line-number-prefixed-with-context", "1:x\n--\r", "raw"],
    ["line-number-prefixed-with-context", "1:x\r", "structured"],
    ["colon-line-number-prefixed", "12:p\r", "structured"],
    [
      "line-number-prefixed-with-context",
      "58-okay\r\n61:matched\r",
      "structured",
    ],
    [
      "colon-line-number-prefixed",
      "12:left\rright\u2028above\u2029below\n",
      "structured",
    ],
    [
      "line-number-prefixed-with-context",
      "1:x\n2-left\rright\u2028above\u2029below\n",
      "structured",
    ],
    ["line-number-prefixed-with-context", "12-a\n--\n20:b\n--\n", "structured"],
    ["line-number-prefixed-with-context", "12-a\nfoo\n", "raw"],
    ["colon-line-number-prefixed", "11:match\n12-x\n", "raw"],
    ["colon-line-number-prefixed", "11:match\n--\n", "raw"],
  ])("%s classifies %j as %s", (validator, stdout, kind) => {
    const plan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "0",
          format: {
            kind: "individual-lines",
            format: {
              kind: "line-number-prefixed",
              format: { kind: "content", language: "text" },
            },
          },
          location: {
            kind: "from-cursor",
            end: { kind: "end-of-output", requiresComplete: true },
            validator,
          },
        },
      ],
    };
    expect(
      segmentOutput(stdout, plan, { kind: "complete" }).pieces,
    ).toMatchObject([{ kind, start: 0, end: stdout.length }]);
  });
});

describe("outputPlan", () => {
  it("round-trips output plan through JSON", () => {
    const plan: OutputPlan = {
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
      ],
    };
    expect(JSON.parse(JSON.stringify(plan))).toEqual(plan);
  });

  it("pieces always cover stdout exactly once in order", () => {
    const stdout = "header\nline one\nline two\n";
    const plan: OutputPlan = {
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
          format: { kind: "content", language: "text" },
          location: {
            kind: "from-cursor",
            end: { kind: "end-of-output", requiresComplete: true },
            validator: "non-empty",
          },
        },
      ],
    };
    const segmented = segmentOutput(stdout, plan, { kind: "complete" });
    assertCoverage(stdout, segmented.pieces);
  });

  it("supports from-cursor + end-of-output spans and validator success", () => {
    const stdout = "alpha\nbeta\n";
    const plan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "0",
          format: { kind: "content", language: "text" },
          location: {
            kind: "from-cursor",
            end: { kind: "end-of-output", requiresComplete: true },
            validator: "non-empty",
          },
        },
      ],
    };
    const segmented = segmentOutput(stdout, plan, { kind: "complete" });
    expect(segmented.pieces).toEqual([
      {
        kind: "structured",
        blockId: "0",
        start: 0,
        end: stdout.length,
        format: { kind: "content", language: "text" },
      },
    ]);
    assertCoverage(stdout, segmented.pieces);
  });

  it("segments a document block with its format and extent", () => {
    const stdout = "<svg></svg>\n";
    const plan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "0",
          document: { filePath: "page.svg", preview: true },
          format: { kind: "content", language: "xml" },
          location: {
            kind: "from-cursor",
            end: { kind: "end-of-output", requiresComplete: true },
            validator: "non-empty",
          },
        },
      ],
    };

    const segmented = segmentOutput(stdout, plan, { kind: "complete" });
    expect(segmented.pieces).toEqual([
      {
        kind: "structured",
        blockId: "0",
        start: 0,
        end: stdout.length,
        format: { kind: "content", language: "xml" },
      },
    ]);
  });

  it("falls back locally when end-of-output validator fails", () => {
    const stdout = "   \n\t";
    const plan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "0",
          format: { kind: "content", language: "text" },
          location: {
            kind: "from-cursor",
            end: { kind: "end-of-output", requiresComplete: true },
            validator: "non-empty",
          },
        },
      ],
    };
    const segmented = segmentOutput(stdout, plan, { kind: "complete" });
    expect(segmented.pieces).toEqual([
      {
        kind: "raw",
        start: 0,
        end: stdout.length,
        reason: "fallback:from-cursor",
      },
    ]);
    assertCoverage(stdout, segmented.pieces);
  });

  it("handles line-count ranges with and without trailing newline", () => {
    const withNl = "a\nb\nc\n";
    const noNl = "a\nb\nc";
    const plan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "0",
          format: { kind: "content", language: "text" },
          location: {
            kind: "from-cursor",
            end: { kind: "line-count", count: 3 },
            validator: "non-empty",
          },
        },
      ],
    };
    const s1 = segmentOutput(withNl, plan, { kind: "complete" });
    expect(withNl.slice(s1.pieces[0]!.start, s1.pieces[0]!.end)).toBe(withNl);
    assertCoverage(withNl, s1.pieces);

    const s2 = segmentOutput(noNl, plan, { kind: "complete" });
    expect(noNl.slice(s2.pieces[0]!.start, s2.pieces[0]!.end)).toBe(noNl);
    assertCoverage(noNl, s2.pieces);
  });

  it("supports unique-literal anchors and falls back on duplicate/missing", () => {
    const plan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "0",
          format: { kind: "content", language: "shell-output" },
          location: { kind: "unique-literal", text: "---", include: "self" },
        },
      ],
    };

    const ok = segmentOutput("x\n---\ny\n", plan, { kind: "complete" });
    expect(ok.pieces.find((p) => p.kind === "structured")).toBeDefined();
    assertCoverage("x\n---\ny\n", ok.pieces);

    const dup = segmentOutput("---\n---\n", plan, { kind: "complete" });
    expect(dup.pieces).toEqual([
      { kind: "raw", start: 0, end: 8, reason: "trailing-raw" },
    ]);
    assertCoverage("---\n---\n", dup.pieces);

    const miss = segmentOutput("no separator\n", plan, { kind: "complete" });
    expect(miss.pieces).toEqual([
      { kind: "raw", start: 0, end: 13, reason: "trailing-raw" },
    ]);
    assertCoverage("no separator\n", miss.pieces);
  });

  it("resolves before-block anchors when available and falls back when missing", () => {
    const okStdout = "line one\n---\nline two\n";
    const okPlan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "0",
          format: { kind: "content", language: "text" },
          location: {
            kind: "from-cursor",
            end: { kind: "before-block", blockId: "1" },
            validator: "non-empty",
          },
        },
        {
          id: "1",
          format: { kind: "content", language: "shell-output" },
          location: { kind: "unique-literal", text: "---\n", include: "self" },
        },
        {
          id: "2",
          format: { kind: "content", language: "text" },
          location: {
            kind: "from-cursor",
            end: { kind: "end-of-output", requiresComplete: true },
            validator: "non-empty",
          },
        },
      ],
    };
    const ok = segmentOutput(okStdout, okPlan, { kind: "complete" });
    expect(ok.pieces.filter((p) => p.kind === "structured")).toHaveLength(3);
    assertCoverage(okStdout, ok.pieces);

    const bad = segmentOutput(
      "line one\nline two\n",
      {
        ...okPlan,
        blocks: [
          okPlan.blocks[0]!,
          {
            ...okPlan.blocks[1]!,
            location: {
              kind: "unique-literal",
              text: "MISSING",
              include: "self",
            },
          },
          okPlan.blocks[2]!,
        ],
      },
      { kind: "complete" },
    );
    expect(bad.pieces[0]).toMatchObject({
      kind: "raw",
      start: 0,
      reason: "fallback:from-cursor",
    });
    assertCoverage("line one\nline two\n", bad.pieces);
  });

  it("does local raw fallback on validator failure", () => {
    const stdout = "oops\n12:ok\n";
    const plan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "0",
          format: {
            kind: "individual-lines",
            format: {
              kind: "line-number-prefixed",
              format: { kind: "content", language: "typescript" },
            },
          },
          location: {
            kind: "from-cursor",
            end: { kind: "line-count", count: 1 },
            validator: "colon-line-number-prefixed",
          },
        },
        {
          id: "1",
          format: { kind: "content", language: "shell-output" },
          location: {
            kind: "from-cursor",
            end: { kind: "end-of-output", requiresComplete: true },
            validator: "non-empty",
          },
        },
      ],
    };
    const segmented = segmentOutput(stdout, plan, { kind: "complete" });
    expect(segmented.pieces[0]).toEqual({
      kind: "raw",
      start: 0,
      end: 5,
      reason: "fallback:from-cursor",
    });
    expect(segmented.pieces[1]).toMatchObject({
      kind: "structured",
      blockId: "1",
      start: 5,
      end: stdout.length,
    });
    assertCoverage(stdout, segmented.pieces);
  });

  it("returns full raw output in streaming mode", () => {
    const stdout = "alpha\nbeta\n";
    const plan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "0",
          format: { kind: "content", language: "text" },
          location: {
            kind: "from-cursor",
            end: { kind: "end-of-output", requiresComplete: true },
          },
        },
      ],
    };
    const segmented = segmentOutput(stdout, plan, {
      kind: "streaming",
      strategy: "stable-prefix",
    });
    expect(segmented.pieces).toEqual([
      {
        kind: "raw",
        start: 0,
        end: stdout.length,
        reason: "mode:streaming:stable-prefix",
      },
    ]);
    expect(segmented.copyText).toBe(stdout);
    assertCoverage(stdout, segmented.pieces);
  });
});
