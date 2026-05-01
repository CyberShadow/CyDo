import { describe, expect, it } from "vitest";
import {
  type OutputPlan,
  segmentOutput,
  type SegmentedOutputPiece,
} from "./shellOutputPlan";

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

describe("shellOutputPlan", () => {
  it("round-trips output plan through JSON", () => {
    const plan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "listing",
          source: { commandIndex: 0, commandName: "ls", filePath: "README.md" },
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
          id: "header",
          format: { kind: "content", language: "shell-output" },
          location: {
            kind: "from-cursor",
            end: { kind: "line-count", count: 1 },
            validator: "non-empty",
          },
        },
        {
          id: "body",
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

  it("supports whole-output spans and validator success", () => {
    const stdout = "alpha\nbeta\n";
    const plan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "all",
          format: { kind: "content", language: "text" },
          location: { kind: "whole-output", validator: "non-empty" },
        },
      ],
    };
    const segmented = segmentOutput(stdout, plan, { kind: "complete" });
    expect(segmented.pieces).toEqual([
      {
        kind: "structured",
        blockId: "all",
        start: 0,
        end: stdout.length,
        format: { kind: "content", language: "text" },
      },
    ]);
    assertCoverage(stdout, segmented.pieces);
  });

  it("preserves source metadata on structured pieces", () => {
    const stdout = "<svg></svg>\n";
    const plan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "sed-output",
          source: {
            commandIndex: 0,
            commandName: "sed",
            filePath: "/tmp/cydo-heredoc-render.svg",
          },
          format: { kind: "content", language: "xml" },
          location: { kind: "whole-output", validator: "non-empty" },
        },
      ],
    };

    const segmented = segmentOutput(stdout, plan, { kind: "complete" });
    expect(segmented.pieces).toEqual([
      {
        kind: "structured",
        blockId: "sed-output",
        start: 0,
        end: stdout.length,
        format: { kind: "content", language: "xml" },
        source: {
          commandIndex: 0,
          commandName: "sed",
          filePath: "/tmp/cydo-heredoc-render.svg",
        },
      },
    ]);
  });

  it("falls back locally when whole-output validator fails", () => {
    const stdout = "   \n\t";
    const plan: OutputPlan = {
      version: 1,
      blocks: [
        {
          id: "all",
          format: { kind: "content", language: "text" },
          location: { kind: "whole-output", validator: "non-empty" },
        },
      ],
    };
    const segmented = segmentOutput(stdout, plan, { kind: "complete" });
    expect(segmented.pieces).toEqual([
      {
        kind: "raw",
        start: 0,
        end: stdout.length,
        reason: "fallback:anchor",
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
          id: "all",
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
          id: "sep",
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
          id: "part-a",
          format: { kind: "content", language: "text" },
          location: {
            kind: "from-cursor",
            end: { kind: "before-block", blockId: "sep" },
            validator: "non-empty",
          },
        },
        {
          id: "sep",
          format: { kind: "content", language: "shell-output" },
          location: { kind: "unique-literal", text: "---\n", include: "self" },
        },
        {
          id: "part-b",
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
          id: "rg-head",
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
            validator: "rg-line-number-prefixed",
          },
        },
        {
          id: "rest",
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
      blockId: "rest",
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
          id: "all",
          format: { kind: "content", language: "text" },
          location: { kind: "whole-output" },
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
