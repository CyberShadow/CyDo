import { describe, it, expect } from "vitest";
import { structuredPatch } from "diff";
import type { PatchHunk } from "../components/ToolCall";
import {
  hunksToOps,
  composeOps,
  opsToHunks,
  composeHunks,
} from "./composeHunks";
import type { Op } from "./composeHunks";

// ---------------------------------------------------------------------------
// hunksToOps
// ---------------------------------------------------------------------------

describe("hunksToOps", () => {
  it("empty input → empty output", () => {
    expect(hunksToOps([])).toEqual([]);
  });

  it("single hunk starting at line 1, no leading gap", () => {
    const hunks: PatchHunk[] = [
      {
        oldStart: 1,
        oldLines: 3,
        newStart: 1,
        newLines: 3,
        lines: [" a", "-old", "+new"],
      },
    ];
    expect(hunksToOps(hunks)).toEqual([
      { type: "ctx", content: "a" },
      { type: "del", content: "old" },
      { type: "ins", content: "new" },
    ]);
  });

  it("single hunk with leading gap", () => {
    const hunks: PatchHunk[] = [
      {
        oldStart: 3,
        oldLines: 2,
        newStart: 3,
        newLines: 2,
        lines: ["-x", "+y"],
      },
    ];
    expect(hunksToOps(hunks)).toEqual([
      { type: "gap", count: 2 },
      { type: "del", content: "x" },
      { type: "ins", content: "y" },
    ]);
  });

  it("multiple hunks with gaps between them", () => {
    const hunks: PatchHunk[] = [
      {
        oldStart: 1,
        oldLines: 1,
        newStart: 1,
        newLines: 1,
        lines: ["-a", "+b"],
      },
      {
        oldStart: 5,
        oldLines: 1,
        newStart: 5,
        newLines: 1,
        lines: ["-c", "+d"],
      },
    ];
    expect(hunksToOps(hunks)).toEqual([
      { type: "del", content: "a" },
      { type: "ins", content: "b" },
      { type: "gap", count: 3 }, // lines 2-4
      { type: "del", content: "c" },
      { type: "ins", content: "d" },
    ]);
  });

  it("pure insertion hunk (oldLines=0)", () => {
    const hunks: PatchHunk[] = [
      {
        oldStart: 2,
        oldLines: 0,
        newStart: 2,
        newLines: 1,
        lines: ["+inserted"],
      },
    ];
    // oldStart=2, oldLine starts at 1, gap = 2-1 = 1
    expect(hunksToOps(hunks)).toEqual([
      { type: "gap", count: 1 },
      { type: "ins", content: "inserted" },
    ]);
  });

  it("pure deletion hunk (newLines=0)", () => {
    const hunks: PatchHunk[] = [
      {
        oldStart: 1,
        oldLines: 2,
        newStart: 1,
        newLines: 0,
        lines: ["-line1", "-line2"],
      },
    ];
    expect(hunksToOps(hunks)).toEqual([
      { type: "del", content: "line1" },
      { type: "del", content: "line2" },
    ]);
  });
});

// ---------------------------------------------------------------------------
// composeOps — full composition table
// ---------------------------------------------------------------------------

describe("composeOps", () => {
  it("gap+gap → gap", () => {
    const ops1: Op[] = [{ type: "gap", count: 3 }];
    const ops2: Op[] = [{ type: "gap", count: 3 }];
    expect(composeOps(ops1, ops2)).toEqual([{ type: "gap", count: 3 }]);
  });

  it("gap+ctx → ctx (content from ops2)", () => {
    const ops1: Op[] = [{ type: "gap", count: 1 }];
    const ops2: Op[] = [{ type: "ctx", content: "x" }];
    expect(composeOps(ops1, ops2)).toEqual([{ type: "ctx", content: "x" }]);
  });

  it("gap+del → del (content from ops2)", () => {
    const ops1: Op[] = [{ type: "gap", count: 1 }];
    const ops2: Op[] = [{ type: "del", content: "x" }];
    expect(composeOps(ops1, ops2)).toEqual([{ type: "del", content: "x" }]);
  });

  it("ctx+gap → ctx (content from ops1)", () => {
    const ops1: Op[] = [{ type: "ctx", content: "x" }];
    const ops2: Op[] = [{ type: "gap", count: 1 }];
    expect(composeOps(ops1, ops2)).toEqual([{ type: "ctx", content: "x" }]);
  });

  it("ctx+ctx → ctx (content from ops1, original side)", () => {
    const ops1: Op[] = [{ type: "ctx", content: "orig" }];
    const ops2: Op[] = [{ type: "ctx", content: "inter" }];
    expect(composeOps(ops1, ops2)).toEqual([{ type: "ctx", content: "orig" }]);
  });

  it("ctx+del → del (content from ops1, original content)", () => {
    const ops1: Op[] = [{ type: "ctx", content: "orig" }];
    const ops2: Op[] = [{ type: "del", content: "inter" }];
    expect(composeOps(ops1, ops2)).toEqual([{ type: "del", content: "orig" }]);
  });

  it("ins+gap → ins (content from ops1)", () => {
    const ops1: Op[] = [{ type: "ins", content: "new" }];
    const ops2: Op[] = [{ type: "gap", count: 1 }];
    expect(composeOps(ops1, ops2)).toEqual([{ type: "ins", content: "new" }]);
  });

  it("ins+ctx → ins (content from ops1)", () => {
    const ops1: Op[] = [{ type: "ins", content: "new" }];
    const ops2: Op[] = [{ type: "ctx", content: "new" }];
    expect(composeOps(ops1, ops2)).toEqual([{ type: "ins", content: "new" }]);
  });

  it("ins+del → cancels out (nothing emitted)", () => {
    const ops1: Op[] = [{ type: "ins", content: "new" }];
    const ops2: Op[] = [{ type: "del", content: "new" }];
    expect(composeOps(ops1, ops2)).toEqual([]);
  });

  it("del pass-through: ops1 del → emitted directly", () => {
    const ops1: Op[] = [{ type: "del", content: "orig" }];
    const ops2: Op[] = [];
    expect(composeOps(ops1, ops2)).toEqual([{ type: "del", content: "orig" }]);
  });

  it("ins pass-through: ops2 ins → emitted directly", () => {
    const ops1: Op[] = [];
    const ops2: Op[] = [{ type: "ins", content: "final" }];
    expect(composeOps(ops1, ops2)).toEqual([{ type: "ins", content: "final" }]);
  });

  it("ops1 exhausted, ops2 ctx → ctx from ops2", () => {
    const ops1: Op[] = [];
    const ops2: Op[] = [{ type: "ctx", content: "x" }];
    expect(composeOps(ops1, ops2)).toEqual([{ type: "ctx", content: "x" }]);
  });

  it("ops2 exhausted, ops1 ins → ins from ops1", () => {
    const ops1: Op[] = [
      { type: "ctx", content: "c" },
      { type: "ins", content: "added" },
    ];
    const ops2: Op[] = [{ type: "ctx", content: "c" }];
    expect(composeOps(ops1, ops2)).toEqual([
      { type: "ctx", content: "c" },
      { type: "ins", content: "added" },
    ]);
  });

  it("gap splitting: ops1 gap(3) + ops2 gap(2) → gap(2) + remaining handled", () => {
    const ops1: Op[] = [{ type: "gap", count: 3 }];
    const ops2: Op[] = [
      { type: "gap", count: 2 },
      { type: "ctx", content: "c" },
    ];
    // gap(2) matches 2 from ops1 gap(3), remainder 1 from ops1 gap(3)
    // then ctx(c) matches remaining 1 from ops1 gap → ctx(c)
    expect(composeOps(ops1, ops2)).toEqual([
      { type: "gap", count: 2 },
      { type: "ctx", content: "c" },
    ]);
  });

  it("adjacent gaps in result are merged", () => {
    const ops1: Op[] = [
      { type: "gap", count: 2 },
      { type: "gap", count: 3 },
    ];
    const ops2: Op[] = [{ type: "gap", count: 5 }];
    // 2+3 from ops1 = 5, all gap+gap → gap
    expect(composeOps(ops1, ops2)).toEqual([{ type: "gap", count: 5 }]);
  });
});

// ---------------------------------------------------------------------------
// opsToHunks
// ---------------------------------------------------------------------------

describe("opsToHunks", () => {
  it("no changes → empty result", () => {
    const ops: Op[] = [
      { type: "ctx", content: "a" },
      { type: "ctx", content: "b" },
    ];
    expect(opsToHunks(ops)).toEqual([]);
  });

  it("single change with context", () => {
    const ops: Op[] = [
      { type: "ctx", content: "a" },
      { type: "del", content: "old" },
      { type: "ins", content: "new" },
      { type: "ctx", content: "b" },
    ];
    const result = opsToHunks(ops, 3);
    expect(result).toHaveLength(1);
    expect(result[0]).toMatchObject({
      oldStart: 1,
      newStart: 1,
      lines: [" a", "-old", "+new", " b"],
    });
  });

  it("two close changes merge into one hunk", () => {
    const ops: Op[] = [
      { type: "del", content: "a" },
      { type: "ins", content: "A" },
      { type: "ctx", content: "x" },
      { type: "ctx", content: "y" },
      { type: "del", content: "b" },
      { type: "ins", content: "B" },
    ];
    const result = opsToHunks(ops, 3);
    expect(result).toHaveLength(1);
    expect(result[0]!.lines).toEqual(["-a", "+A", " x", " y", "-b", "+B"]);
  });

  it("changes separated by gap → two separate hunks", () => {
    const ops: Op[] = [
      { type: "del", content: "a" },
      { type: "ins", content: "A" },
      { type: "gap", count: 100 },
      { type: "del", content: "b" },
      { type: "ins", content: "B" },
    ];
    const result = opsToHunks(ops, 3);
    expect(result).toHaveLength(2);
    expect(result[0]!.lines).toEqual(["-a", "+A"]);
    expect(result[1]!.lines).toEqual(["-b", "+B"]);
  });

  it("context clamped at boundaries", () => {
    // Change at line 1 — can't have context before it
    const ops: Op[] = [
      { type: "del", content: "first" },
      { type: "ins", content: "FIRST" },
      { type: "ctx", content: "second" },
    ];
    const result = opsToHunks(ops, 3);
    expect(result).toHaveLength(1);
    expect(result[0]!.oldStart).toBe(1);
    expect(result[0]!.newStart).toBe(1);
    expect(result[0]!.lines[0]).toBe("-first");
  });

  it("oldStart and newStart are correct", () => {
    const ops: Op[] = [
      { type: "gap", count: 4 },
      { type: "ctx", content: "ctx1" },
      { type: "del", content: "x" },
      { type: "ins", content: "y" },
    ];
    const result = opsToHunks(ops, 1);
    // gap=4 means lines 1-4 skipped. ctx1 is line 5, del/ins is line 6 (old), line 6 (new)
    expect(result[0]!.oldStart).toBe(5);
    expect(result[0]!.newStart).toBe(5);
    expect(result[0]!.lines).toEqual([" ctx1", "-x", "+y"]);
  });
});

// ---------------------------------------------------------------------------
// composeHunks — end-to-end integration tests
// ---------------------------------------------------------------------------

describe("composeHunks", () => {
  it("empty first → returns second unchanged", () => {
    const h2: PatchHunk[] = [
      {
        oldStart: 1,
        oldLines: 1,
        newStart: 1,
        newLines: 1,
        lines: ["-a", "+b"],
      },
    ];
    expect(composeHunks([], h2)).toEqual(h2);
  });

  it("empty second → returns first unchanged", () => {
    const h1: PatchHunk[] = [
      {
        oldStart: 1,
        oldLines: 1,
        newStart: 1,
        newLines: 1,
        lines: ["-a", "+b"],
      },
    ];
    expect(composeHunks(h1, [])).toEqual(h1);
  });

  it("Example 1: non-overlapping hunks → both changes visible", () => {
    // diff1: change line 3 old→new
    const hunks1: PatchHunk[] = [
      {
        oldStart: 1,
        oldLines: 5,
        newStart: 1,
        newLines: 5,
        lines: [" a", " b", "-old", "+new", " d", " e"],
      },
    ];
    // diff2: change line 7 foo→bar (gap of 4 from end of hunks1)
    const hunks2: PatchHunk[] = [
      {
        oldStart: 5,
        oldLines: 5,
        newStart: 5,
        newLines: 5,
        lines: [" e", " f", "-foo", "+bar", " i", " j"],
      },
    ];
    const result = composeHunks(hunks1, hunks2, 3);
    // Should contain both changes
    const allLines = result.flatMap((h) => h.lines);
    expect(allLines).toContain("-old");
    expect(allLines).toContain("+new");
    expect(allLines).toContain("-foo");
    expect(allLines).toContain("+bar");
  });

  it("Example 2: overlapping hunks (re-edit same line) → original→final directly", () => {
    // diff1: line 3 original→version1
    const hunks1: PatchHunk[] = [
      {
        oldStart: 1,
        oldLines: 5,
        newStart: 1,
        newLines: 5,
        lines: [" a", " b", "-original", "+version1", " d", " e"],
      },
    ];
    // diff2: line 3 version1→version2
    const hunks2: PatchHunk[] = [
      {
        oldStart: 1,
        oldLines: 5,
        newStart: 1,
        newLines: 5,
        lines: [" a", " b", "-version1", "+version2", " d", " e"],
      },
    ];
    const result = composeHunks(hunks1, hunks2, 3);
    const allLines = result.flatMap((h) => h.lines);
    // Should show original→version2 directly, NOT version1
    expect(allLines).toContain("-original");
    expect(allLines).toContain("+version2");
    expect(allLines).not.toContain("-version1");
    expect(allLines).not.toContain("+version1");
  });

  it("Example 3: insert-then-delete → cancels out (empty result)", () => {
    // diff1: insert "extra" after line 2
    const hunks1: PatchHunk[] = [
      {
        oldStart: 1,
        oldLines: 4,
        newStart: 1,
        newLines: 5,
        lines: [" a", " b", "+extra", " c", " d"],
      },
    ];
    // diff2: delete "extra" (line 3 in intermediate)
    const hunks2: PatchHunk[] = [
      {
        oldStart: 1,
        oldLines: 5,
        newStart: 1,
        newLines: 4,
        lines: [" a", " b", "-extra", " c", " d"],
      },
    ];
    const result = composeHunks(hunks1, hunks2, 3);
    expect(result).toEqual([]);
  });

  it("Example 4: diff2 inserts within diff1 gap → both changes in result", () => {
    // diff1: change line 2
    const hunks1: PatchHunk[] = [
      {
        oldStart: 1,
        oldLines: 3,
        newStart: 1,
        newLines: 3,
        lines: [" a", "-old", "+new", " c"],
      },
    ];
    // diff2: insert at line 5 (in the gap of diff1)
    const hunks2: PatchHunk[] = [
      {
        oldStart: 4,
        oldLines: 3,
        newStart: 4,
        newLines: 4,
        lines: [" d", "+extra", " e", " f"],
      },
    ];
    const result = composeHunks(hunks1, hunks2, 3);
    const allLines = result.flatMap((h) => h.lines);
    expect(allLines).toContain("-old");
    expect(allLines).toContain("+new");
    expect(allLines).toContain("+extra");
  });

  it("three-way composition (fold left over 3 edits)", () => {
    // edit1: a→b
    const h1: PatchHunk[] = [
      {
        oldStart: 1,
        oldLines: 1,
        newStart: 1,
        newLines: 1,
        lines: ["-a", "+b"],
      },
    ];
    // edit2: b→c
    const h2: PatchHunk[] = [
      {
        oldStart: 1,
        oldLines: 1,
        newStart: 1,
        newLines: 1,
        lines: ["-b", "+c"],
      },
    ];
    // edit3: c→d
    const h3: PatchHunk[] = [
      {
        oldStart: 1,
        oldLines: 1,
        newStart: 1,
        newLines: 1,
        lines: ["-c", "+d"],
      },
    ];
    const result = [h1, h2, h3].reduce<PatchHunk[]>(composeHunks, []);
    const allLines = result.flatMap((h) => h.lines);
    expect(allLines).toContain("-a");
    expect(allLines).toContain("+d");
    expect(allLines).not.toContain("+b");
    expect(allLines).not.toContain("+c");
  });

  it("one diff empty → returns other unchanged", () => {
    const h1: PatchHunk[] = [
      {
        oldStart: 1,
        oldLines: 1,
        newStart: 1,
        newLines: 1,
        lines: ["-x", "+y"],
      },
    ];
    expect(composeHunks([], h1)).toEqual(h1);
    expect(composeHunks(h1, [])).toEqual(h1);
  });
});

// ---------------------------------------------------------------------------
// Equivalence property: composeHunks matches structuredPatch for full content
// ---------------------------------------------------------------------------

describe("composeHunks equivalence property", () => {
  function makeHunks(oldStr: string, newStr: string): PatchHunk[] {
    const result = structuredPatch(
      "",
      "",
      oldStr,
      newStr,
      undefined,
      undefined,
      {
        context: 3,
      },
    );
    return result.hunks as PatchHunk[];
  }

  function getOldLines(hunks: PatchHunk[]): string[] {
    const lines: string[] = [];
    for (const h of hunks) {
      for (const l of h.lines) {
        if (l[0] === " " || l[0] === "-") lines.push(l.slice(1));
      }
    }
    return lines;
  }

  function getNewLines(hunks: PatchHunk[]): string[] {
    const lines: string[] = [];
    for (const h of hunks) {
      for (const l of h.lines) {
        if (l[0] === " " || l[0] === "+") lines.push(l.slice(1));
      }
    }
    return lines;
  }

  it("non-overlapping edits produce same net old/new lines", () => {
    const original = "line1\nline2\nline3\nline4\nline5\nline6\nline7\n";
    const intermediate = "line1\nLINE2\nline3\nline4\nline5\nline6\nline7\n";
    const final = "line1\nLINE2\nline3\nline4\nline5\nLINE6\nline7\n";

    const h1 = makeHunks(original, intermediate);
    const h2 = makeHunks(intermediate, final);
    const composed = composeHunks(h1, h2, 3);
    const expected = makeHunks(original, final);

    expect(getOldLines(composed)).toEqual(getOldLines(expected));
    expect(getNewLines(composed)).toEqual(getNewLines(expected));
  });

  it("re-editing same line: composed = original→final", () => {
    const original = "aaa\nbbb\nccc\n";
    const intermediate = "aaa\nBBB\nccc\n";
    const final = "aaa\nXXX\nccc\n";

    const h1 = makeHunks(original, intermediate);
    const h2 = makeHunks(intermediate, final);
    const composed = composeHunks(h1, h2, 3);
    const expected = makeHunks(original, final);

    expect(getOldLines(composed)).toEqual(getOldLines(expected));
    expect(getNewLines(composed)).toEqual(getNewLines(expected));
  });

  it("insert then delete same line → net empty diff", () => {
    const original = "aaa\nbbb\nccc\n";
    const intermediate = "aaa\nbbb\nINSERTED\nccc\n";
    const final = "aaa\nbbb\nccc\n"; // same as original

    const h1 = makeHunks(original, intermediate);
    const h2 = makeHunks(intermediate, final);
    const composed = composeHunks(h1, h2, 3);

    // Net effect: no change, so composed should be empty
    expect(composed).toEqual([]);
  });
});
