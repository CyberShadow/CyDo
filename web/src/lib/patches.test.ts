import { describe, expect, it } from "vitest";
import {
  parseApplyPatchSections,
  parsePatchHunksFromText,
  parsePatchTextFromInput,
  toUnifiedPatch,
} from "./patches";

describe("patches", () => {
  it("extracts patch text from supported input keys", () => {
    expect(parsePatchTextFromInput({ input: "a" })).toBe("a");
    expect(parsePatchTextFromInput({ patchText: "b" })).toBe("b");
    expect(parsePatchTextFromInput({ patch: "c" })).toBe("c");
    expect(parsePatchTextFromInput({ diff: "d" })).toBe("d");
    expect(parsePatchTextFromInput({})).toBeNull();
  });

  it("parses multi-file apply_patch sections with add/update/delete ops", () => {
    const patchText = [
      "*** Begin Patch",
      "*** Add File: docs/new.md",
      "+# New doc",
      "+",
      "+Body",
      "*** Update File: docs/existing.md",
      "@@ -1,2 +1,2 @@",
      "-old line",
      "+new line",
      " keep",
      "*** Delete File: docs/removed.md",
      "*** End Patch",
      "",
    ].join("\n");

    const sections = parseApplyPatchSections(patchText);
    expect(sections).toHaveLength(3);
    expect(sections[0]).toMatchObject({
      path: "docs/new.md",
      op: "add",
      addedContent: "# New doc\n\nBody",
    });
    expect(sections[1]).toMatchObject({
      path: "docs/existing.md",
      op: "update",
    });
    expect(sections[2]).toMatchObject({
      path: "docs/removed.md",
      op: "delete",
    });
  });

  it("keeps per-file patch text for markdown updates", () => {
    const patchText = [
      "*** Begin Patch",
      "*** Update File: docs/one.md",
      "@@ -1 +1 @@",
      "-old one",
      "+new one",
      "*** Update File: docs/two.md",
      "@@ -1 +1 @@",
      "-old two",
      "+new two",
      "*** End Patch",
      "",
    ].join("\n");

    const sections = parseApplyPatchSections(patchText);
    expect(sections).toHaveLength(2);
    expect(sections[0]?.patchText).toContain("docs/one.md");
    expect(sections[0]?.patchText).not.toContain("docs/two.md");
    expect(sections[1]?.patchText).toContain("docs/two.md");
    expect(parsePatchHunksFromText(sections[0]!.patchText)).not.toBeNull();
    expect(parsePatchHunksFromText(sections[1]!.patchText)).not.toBeNull();
  });

  it("preserves literal a/ prefixes in Begin Patch file paths", () => {
    const patchText = [
      "*** Begin Patch",
      "*** Update File: a/docs/readme.md",
      "@@ -1 +1 @@",
      "-old",
      "+new",
      "*** End Patch",
      "",
    ].join("\n");

    const sections = parseApplyPatchSections(patchText);
    expect(sections).toHaveLength(1);
    expect(sections[0]?.path).toBe("a/docs/readme.md");
  });

  it("converts single update apply_patch section to unified diff", () => {
    const patchText = [
      "*** Update File: src/app.ts",
      "@@ -1,1 +1,1 @@",
      "-const a = 1;",
      "+const a = 2;",
      "",
    ].join("\n");
    const unified = toUnifiedPatch(patchText);
    expect(unified).toContain("--- a/src/app.ts");
    expect(unified).toContain("+++ b/src/app.ts");
    expect(unified).toContain("@@ -1,1 +1,1 @@");
  });

  it("strips timestamp suffixes from unified diff file headers", () => {
    const patchText = [
      "--- a/docs/readme.md\t2026-04-26 00:00:00 +0000",
      "+++ b/docs/readme.md\t2026-04-26 00:00:00 +0000",
      "@@ -1 +1 @@",
      "-old",
      "+new",
      "",
    ].join("\n");

    const sections = parseApplyPatchSections(patchText);
    expect(sections).toHaveLength(1);
    expect(sections[0]).toMatchObject({
      path: "docs/readme.md",
      op: "update",
    });
  });

  it("strips space-separated timestamps from unified diff file headers", () => {
    const patchText = [
      "--- a/docs/readme.md 2026-04-26 00:00:00 +0000",
      "+++ b/docs/readme.md 2026-04-26 00:00:00 +0000",
      "@@ -1 +1 @@",
      "-old",
      "+new",
      "",
    ].join("\n");

    const sections = parseApplyPatchSections(patchText);
    expect(sections).toHaveLength(1);
    expect(sections[0]).toMatchObject({
      path: "docs/readme.md",
      op: "update",
    });
  });

  it("keeps date-like filename suffixes in unified diff headers", () => {
    const patchText = [
      "--- a/reports/build 2026-04-26",
      "+++ b/reports/build 2026-04-26",
      "@@ -1 +1 @@",
      "-old",
      "+new",
      "",
    ].join("\n");

    const sections = parseApplyPatchSections(patchText);
    expect(sections).toHaveLength(1);
    expect(sections[0]).toMatchObject({
      path: "reports/build 2026-04-26",
      op: "update",
    });
  });

  it("does not split section on removed lines that start with three dashes", () => {
    const patchText = [
      "--- a/docs/readme.md",
      "+++ b/docs/readme.md",
      "@@ -1,2 +1,2 @@",
      "---- heading",
      "+### heading",
      " context",
      "",
    ].join("\n");

    const sections = parseApplyPatchSections(patchText);
    expect(sections).toHaveLength(1);
    expect(sections[0]?.path).toBe("docs/readme.md");
    const hunks = parsePatchHunksFromText(sections[0]!.patchText);
    expect(hunks).not.toBeNull();
    expect(hunks?.[0]?.lines).toContain("---- heading");
    expect(hunks?.[0]?.lines).toContain("+### heading");
  });

  it("parses non-git multi-file unified diff headers as separate sections", () => {
    const patchText = [
      "--- docs/one.md",
      "+++ docs/one.md",
      "@@ -1 +1 @@",
      "-old one",
      "+new one",
      "--- docs/two.md",
      "+++ docs/two.md",
      "@@ -1 +1 @@",
      "-old two",
      "+new two",
      "",
    ].join("\n");

    const sections = parseApplyPatchSections(patchText);
    expect(sections).toHaveLength(2);
    expect(sections[0]).toMatchObject({ path: "docs/one.md", op: "update" });
    expect(sections[1]).toMatchObject({ path: "docs/two.md", op: "update" });
  });

  it("parses old/new-labeled non-git multi-file unified diffs as separate sections", () => {
    const patchText = [
      "--- old/docs/one.md",
      "+++ new/docs/one.md",
      "@@ -1 +1 @@",
      "-old one",
      "+new one",
      "--- old/docs/two.md",
      "+++ new/docs/two.md",
      "@@ -1 +1 @@",
      "-old two",
      "+new two",
      "",
    ].join("\n");

    const sections = parseApplyPatchSections(patchText);
    expect(sections).toHaveLength(2);
    expect(sections[0]).toMatchObject({
      path: "new/docs/one.md",
      op: "update",
    });
    expect(sections[1]).toMatchObject({
      path: "new/docs/two.md",
      op: "update",
    });
  });

  it("keeps removed line content that serializes as exactly '--- '", () => {
    const patchText = [
      "--- a/docs/readme.md",
      "+++ b/docs/readme.md",
      "@@ -1,2 +1,2 @@",
      "-title",
      "--- ",
      "+title",
      "+content",
      "",
    ].join("\n");

    const hunks = parsePatchHunksFromText(patchText);
    expect(hunks).not.toBeNull();
    expect(hunks?.[0]?.lines).toContain("--- ");
    expect(hunks?.[0]?.lines).toContain("+content");
  });

  it("does not split unified section on header-like hunk payload lines", () => {
    const patchText = [
      "--- a/docs/readme.md",
      "+++ b/docs/readme.md",
      "@@ -1 +1 @@",
      "--- a",
      "+++ b",
      "",
    ].join("\n");

    const sections = parseApplyPatchSections(patchText);
    expect(sections).toHaveLength(1);
    expect(sections[0]?.path).toBe("docs/readme.md");
    const hunks = parsePatchHunksFromText(sections[0]!.patchText);
    expect(hunks).not.toBeNull();
    expect(hunks?.[0]?.lines).toContain("--- a");
    expect(hunks?.[0]?.lines).toContain("+++ b");
  });

  it("rejects matched hunks with unexpected trailing payload", () => {
    const patchText = [
      "--- a/docs/readme.md",
      "+++ b/docs/readme.md",
      "@@ -1,1 +1,1 @@",
      "-old",
      "+new",
      "*unexpected trailing payload",
      "",
    ].join("\n");

    expect(parsePatchHunksFromText(patchText)).toBeNull();
  });

  it("rejects matched hunks with header-like trailing payload", () => {
    const patchText = [
      "--- a/docs/readme.md",
      "+++ b/docs/readme.md",
      "@@ -1,1 +1,1 @@",
      "-old",
      "+new",
      "--- sneaky trailing payload",
      "",
    ].join("\n");

    expect(parsePatchHunksFromText(patchText)).toBeNull();
  });

  it("does not treat fake trailing header pairs as a new section", () => {
    const patchText = [
      "--- a/docs/readme.md",
      "+++ b/docs/readme.md",
      "@@ -1,1 +1,1 @@",
      "-old",
      "+new",
      "--- fake trailing payload",
      "+++ fake trailing payload",
      "",
    ].join("\n");

    expect(parsePatchHunksFromText(patchText)).toBeNull();
    const sections = parseApplyPatchSections(patchText);
    expect(sections).toHaveLength(1);
    expect(sections[0]).toMatchObject({
      path: "docs/readme.md",
      op: "update",
    });
  });

  it("does not treat non-timestamp tab headers as new unified sections", () => {
    const patchText = [
      "--- a/docs/readme.md",
      "+++ b/docs/readme.md",
      "@@ -1,1 +1,1 @@",
      "-old",
      "+new",
      "--- fake\tpayload",
      "+++ fake\tpayload",
      "",
    ].join("\n");

    expect(parsePatchHunksFromText(patchText)).toBeNull();
    const sections = parseApplyPatchSections(patchText);
    expect(sections).toHaveLength(1);
    expect(sections[0]).toMatchObject({
      path: "docs/readme.md",
      op: "update",
    });
    expect(sections[0]?.patchText).not.toContain("--- fake\tpayload");
  });
});
