import { describe, expect, it } from "vitest";
import {
  fileEditPayloadFromNormalizedChange,
  getApplyPatchFileChanges,
  parseCodexFileChanges,
} from "./fileChanges";

describe("fileChanges", () => {
  it("parses codex fileChange rows with path and file_path aliases", () => {
    const input = {
      changes: [
        { path: "docs/one.md", kind: { type: "add" }, diff: "# One" },
        {
          file_path: "docs/two.md",
          kind: { type: "update" },
          diff: "@@ -1 +1 @@\n-old\n+new",
        },
      ],
    };
    const parsed = parseCodexFileChanges(input);
    expect(parsed.unparsed).toHaveLength(0);
    expect(parsed.changes).toHaveLength(2);
    expect(parsed.changes[0]).toMatchObject({ path: "docs/one.md", op: "add" });
    expect(parsed.changes[1]).toMatchObject({
      path: "docs/two.md",
      op: "update",
    });
  });

  it("maps add/update/delete kind.type values", () => {
    const input = {
      changes: [
        { path: "a.txt", kind: { type: "add" }, diff: "new" },
        {
          path: "b.txt",
          kind: { type: "update" },
          diff: "@@ -1 +1 @@\n-old\n+new",
        },
        { path: "c.txt", kind: { type: "delete" }, diff: "old" },
      ],
    };
    const parsed = parseCodexFileChanges(input);
    expect(parsed.changes.map((c) => c.op)).toEqual([
      "add",
      "update",
      "delete",
    ]);
  });

  it("builds file edit payloads for add/update/delete normalized changes", () => {
    expect(
      fileEditPayloadFromNormalizedChange({
        path: "docs/new.md",
        op: "add",
        label: "Add",
        content: "# hello",
        raw: {},
      }),
    ).toEqual({ mode: "full_content", content: "# hello" });

    expect(
      fileEditPayloadFromNormalizedChange({
        path: "docs/old.md",
        op: "delete",
        label: "Delete",
        content: "old text",
        raw: {},
      }),
    ).toEqual({ mode: "full_content", content: "old text" });

    expect(
      fileEditPayloadFromNormalizedChange({
        path: "docs/update.md",
        op: "update",
        label: "Patch",
        patchText: "@@ -1 +1 @@\n-old\n+new",
        raw: {},
      }),
    ).toEqual({ mode: "patch_text", patchText: "@@ -1 +1 @@\n-old\n+new" });
  });

  it("normalizes apply_patch sections into per-file file changes", () => {
    const input = {
      input: [
        "*** Begin Patch",
        "*** Add File: docs/new.md",
        "+# New",
        "*** Update File: docs/existing.md",
        "@@ -1 +1 @@",
        "-old",
        "+new",
        "*** Delete File: docs/removed.md",
        "*** End Patch",
        "",
      ].join("\n"),
    };
    const changes = getApplyPatchFileChanges(input);
    expect(changes).toHaveLength(3);
    expect(changes[0]).toMatchObject({
      path: "docs/new.md",
      op: "add",
      content: "# New",
    });
    expect(changes[1]).toMatchObject({
      path: "docs/existing.md",
      op: "update",
    });
    expect(changes[2]).toMatchObject({
      path: "docs/removed.md",
      op: "delete",
      content: "",
    });
  });
});
