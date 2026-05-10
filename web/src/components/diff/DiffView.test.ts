import { describe, expect, it } from "vitest";
import { pairRemovedAddedLines } from "./DiffView";

describe("pairRemovedAddedLines", () => {
  it("returns empty array for empty inputs", () => {
    expect(pairRemovedAddedLines([], [])).toEqual([]);
  });

  it("returns empty array when removed is empty", () => {
    expect(pairRemovedAddedLines([], ["a", "b"])).toEqual([]);
  });

  it("returns empty array when added is empty", () => {
    expect(pairRemovedAddedLines(["a", "b"], [])).toEqual([]);
  });

  it("returns added.length pairs when removed is longer", () => {
    const result = pairRemovedAddedLines(
      ["line1", "line2", "line3"],
      ["line1", "line2"],
    );
    expect(result).toHaveLength(2);
  });

  it("returns removed.length pairs when added is longer", () => {
    const result = pairRemovedAddedLines(
      ["line1", "line2"],
      ["line1", "line2", "line3"],
    );
    expect(result).toHaveLength(2);
  });

  it("marks similar pairs as similar: true", () => {
    // "foo bar" vs "foo baz" — only the last word differs, high similarity
    const result = pairRemovedAddedLines(["foo bar"], ["foo baz"]);
    expect(result).toHaveLength(1);
    expect(result[0]!.similar).toBe(true);
  });

  it("marks dissimilar pairs as similar: false", () => {
    // "abc" vs "xyz" — no shared characters, Dice coefficient = 0
    const result = pairRemovedAddedLines(["abc"], ["xyz"]);
    expect(result).toHaveLength(1);
    expect(result[0]!.similar).toBe(false);
  });

  it("result entries contain the word diff changes array", () => {
    const result = pairRemovedAddedLines(["hello world"], ["hello there"]);
    expect(result).toHaveLength(1);
    expect(Array.isArray(result[0]!.changes)).toBe(true);
    expect(result[0]!.changes.length).toBeGreaterThan(0);
  });

  it("threshold boundary: pair just above 0.4 is similar", () => {
    // "aaaa bbbb" vs "aaaa cccc" — 4 shared chars out of 8+8=16 total,
    // Dice = 2*4/(8+8) = 0.5 > 0.4
    const result = pairRemovedAddedLines(["aaaa bbbb"], ["aaaa cccc"]);
    expect(result[0]!.similar).toBe(true);
  });

  it("threshold boundary: fully dissimilar pair is not similar", () => {
    // "aaaa" vs "bbbb" — Dice = 0 < 0.4
    const result = pairRemovedAddedLines(["aaaa"], ["bbbb"]);
    expect(result[0]!.similar).toBe(false);
  });
});
