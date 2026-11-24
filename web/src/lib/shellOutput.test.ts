import { assert, describe, expect, it } from "vitest";
import { derivePlan, shellOutputView } from "./shellOutput";
import type { FileOrigin, OutputSegment, RowsSegment } from "./shellOutput";

const nl = {
  kind: "nl",
  width: 6,
  separator: "\t",
  startsAtOne: true,
  lastRowMayBeUnterminated: false,
} as const;
const grep = { kind: "grep", context: false } as const;
const summary = { kind: "summary-line" } as const;
const separator = { kind: "literal", text: "\n--- sep ---\n" } as const;
const diff = { kind: "diff" } as const;

function rows(
  filePath = "a.md",
  numbering: RowsSegment["numbering"] = null,
  origin: FileOrigin["kind"] = "worktree",
): RowsSegment {
  return {
    kind: "rows",
    source: {
      kind: "file",
      origin: { kind: origin, filePath },
      range: { type: "all" },
    },
    numbering,
  };
}

function blocks(output: OutputSegment[]) {
  const result = derivePlan(output);
  assert(result.ok);
  return result.value.blocks;
}

describe("shellOutputView", () => {
  it("uses a dedicated view for a diff", () => {
    expect(shellOutputView([diff])).toEqual({
      ok: true,
      value: { kind: "diff" },
    });
  });

  it("uses a dedicated view for unnumbered Git object rows", () => {
    expect(shellOutputView([rows("a.md", null, "git-object")])).toEqual({
      ok: true,
      value: { kind: "git-object", filePath: "a.md" },
    });
  });

  it("plans numbered Git object rows", () => {
    expect(shellOutputView([rows("a.md", nl, "git-object")])).toMatchObject({
      ok: true,
      value: { kind: "plan" },
    });
  });

  it.each([
    { numbering: grep, search: true },
    { numbering: nl, search: false },
    { numbering: null, search: false },
  ])(
    "sets search to $search for numbering $numbering",
    ({ numbering, search }) => {
      expect(
        shellOutputView([separator, rows("a.md", numbering)]),
      ).toMatchObject({
        ok: true,
        value: { kind: "plan", search },
      });
    },
  );
});

describe("derivePlan", () => {
  it("anchors rows before a literal and reads the final rows to completion", () => {
    expect(blocks([rows(), separator, rows("b.md")])).toEqual([
      {
        id: "0",
        document: { filePath: "a.md", preview: false },
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
          text: separator.text,
          include: "self",
        },
      },
      {
        id: "2",
        document: { filePath: "b.md", preview: true },
        format: { kind: "content", language: "markdown" },
        location: {
          kind: "from-cursor",
          end: { kind: "end-of-output", requiresComplete: true },
          validator: "non-empty",
        },
      },
    ]);
  });

  it("allocates one nonempty line for a summary before rows", () => {
    const [first, second] = blocks([summary, rows()]);
    expect(first).toEqual({
      id: "0",
      format: { kind: "content", language: "shell-output" },
      location: {
        kind: "from-cursor",
        end: { kind: "line-count", count: 1 },
        validator: "non-empty",
      },
    });
    expect(second?.document).toEqual({ filePath: "a.md", preview: true });
  });

  it.each([nl, grep])("omits document metadata for $kind rows", (numbering) => {
    expect(blocks([rows("a.md", numbering)])[0]).not.toHaveProperty("document");
  });

  it("combines adjacent same-language rows into one block", () => {
    expect(blocks([rows(), rows("b.md")])).toEqual([
      {
        id: "0",
        format: { kind: "content", language: "markdown" },
        location: {
          kind: "from-cursor",
          end: { kind: "end-of-output", requiresComplete: true },
          validator: "non-empty",
        },
      },
    ]);
  });

  it("rejects adjacent search rows", () => {
    expect(derivePlan([rows("a.d", grep), rows("b.d", grep)])).toEqual({
      ok: false,
      reason: "search output cannot be concatenated with other search output",
    });
  });

  it.each([
    { description: "empty output", output: [] },
    { description: "rows followed by a summary", output: [rows(), summary] },
    {
      description: "duplicate literals",
      output: [separator, rows(), separator],
    },
  ])("rejects $description", ({ output }) => {
    expect(derivePlan(output)).toEqual({
      ok: false,
      reason: "shell output steps do not define an unambiguous output plan",
    });
  });

  it.each([
    { description: "a lone diff", output: [diff] },
    { description: "a diff after rows", output: [rows(), diff] },
    {
      description: "a diff after duplicate literals",
      output: [separator, separator, diff],
    },
  ])("throws when asked to plan $description", ({ output }) => {
    expect(() => derivePlan(output)).toThrow(
      "Diff output requires its own view",
    );
  });
});
