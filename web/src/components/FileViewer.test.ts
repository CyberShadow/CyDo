import { describe, expect, it } from "vitest";
import { applyPatch } from "diff";
import type { Block, TrackedFile } from "../types";
import bashEditDiff from "../testFixtures/claude-bash-edit-diff.json";
import { composeResolvedHunksThrough, resolveFileContent } from "./FileViewer";

const insertion = {
  oldStart: 1,
  oldLines: 0,
  newStart: 2,
  newLines: 1,
  lines: ["+inserted"],
};

function resolve(hunks = [insertion], base: string | null = "first\nsecond\n") {
  const file: TrackedFile = {
    path: "/workspace/example.txt",
    edits: [
      {
        toolUseId: "bash",
        messageId: "message",
        filePath: "/workspace/example.txt",
        type: "edit",
        op: "update",
        status: "applied",
        source: "claude-bashEditDiff",
        payload: { mode: "hunks", hunks },
      },
    ],
  };
  const blocks = new Map<string, Block>([
    [
      "bash",
      {
        itemId: "bash",
        type: "tool_use",
        text: "",
        completed: true,
        creationOrder: 0,
        result: {
          toolUseId: "bash",
          content: "",
          toolResult: base == null ? {} : { originalFile: base },
        },
      },
    ],
  ]);
  return resolveFileContent(file, blocks, new Map());
}

describe("Bash structured hunk resolution", () => {
  it("renders exact primary fixture sparse old and new fragments without changing raw hunks", () => {
    const hunks = bashEditDiff.files[0]!.hunks;
    const resolved = resolve(hunks, null);

    expect(resolved?.currentSource.fragments).toEqual(
      expect.arrayContaining([
        {
          startLine: 15,
          lines: [
            "",
            "import ae.sys.data;",
            "import ae.sys.datamm;",
            "import ae.utils.json;",
            "",
            "import btrfs.c.ioctl : btrfs_ioctl_fs_info_args;",
            "",
          ],
        },
        {
          startLine: 91,
          lines: [
            "// JSON format",
            "// ============================================================================",
            "",
            "/// Serialized",
            "struct SerializedState",
            "{",
            "\tbool expert;",
            "\t@JSONOptional bool physical;",
            "\tstring fsPath;",
            '\t@JSONOptional string fsid;  /// UUID formatted as "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"',
            "\tulong totalSize;",
            "\tBrowserPath* root;",
            "}",
            "",
          ],
        },
      ]),
    );
    expect(resolved?.resolved.get(0)?.sourceBefore.fragments).toEqual(
      expect.arrayContaining([
        {
          startLine: 15,
          lines: [
            "",
            "import ae.sys.data;",
            "import ae.sys.datamm;",
            "import ae.utils.serialization.json;",
            "",
            "import btrfs.c.ioctl : btrfs_ioctl_fs_info_args;",
            "",
          ],
        },
        {
          startLine: 91,
          lines: [
            "// JSON format",
            "// ============================================================================",
            "",
            "/// Serialized import state",
            "struct ImportedSerializedState",
            "{",
            "\tbool expert;",
            "\t@JSONOptional bool physical;",
            "\tstring fsPath;",
            '\t@JSONOptional string fsid;  /// UUID formatted as "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"',
            "\tulong totalSize;",
            "\tBrowserPath.SerializedForm root;",
            "}",
            "",
            "/// Serialized export state",
            "struct ExportedSerializedState",
            "{",
            "\tbool expert;",
            "\t@JSONOptional bool physical;",
            "\tstring fsPath;",
            '\t@JSONOptional string fsid;  /// UUID formatted as "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"',
            "\tulong totalSize;",
            "\tBrowserPath* root;",
            "}",
            "",
          ],
        },
      ]),
    );
    expect(resolved?.resolved.get(0)?.patchHunks).toEqual(hunks);
  });

  it("resolves Write, Edit, and Bash hunks completely and composes them through the original content", () => {
    const file: TrackedFile = {
      path: "/workspace/ordered.txt",
      edits: [
        {
          toolUseId: "write",
          messageId: "message",
          filePath: "/workspace/ordered.txt",
          type: "write",
          op: "add",
          status: "applied",
          source: "claude-tool",
          payload: { mode: "full_content", content: "one\ntwo\n" },
        },
        {
          toolUseId: "edit",
          messageId: "message",
          filePath: "/workspace/ordered.txt",
          type: "edit",
          op: "update",
          status: "applied",
          source: "claude-tool",
        },
        {
          toolUseId: "bash",
          messageId: "message",
          filePath: "/workspace/ordered.txt",
          type: "edit",
          op: "update",
          status: "applied",
          source: "claude-bashEditDiff",
          payload: {
            mode: "hunks",
            hunks: [
              {
                oldStart: 1,
                oldLines: 2,
                newStart: 1,
                newLines: 2,
                lines: [" one", "-TWO", "+three", " "],
              },
            ],
          },
        },
      ],
    };
    const blocks = new Map<string, Block>([
      [
        "write",
        {
          itemId: "write",
          type: "tool_use",
          text: "",
          completed: true,
          creationOrder: 0,
          input: { content: "one\ntwo\n" },
        },
      ],
      [
        "edit",
        {
          itemId: "edit",
          type: "tool_use",
          text: "",
          completed: true,
          creationOrder: 1,
          input: { old_string: "two", new_string: "TWO" },
        },
      ],
      [
        "bash",
        {
          itemId: "bash",
          type: "tool_use",
          text: "",
          completed: true,
          creationOrder: 2,
        },
      ],
    ]);
    const resolved = resolveFileContent(file, blocks, new Map());

    expect(
      resolved?.resolved.get(2)?.sourceBefore.fragments[0]?.lines.join("\n"),
    ).toBe("one\nTWO\n");
    expect(resolved?.currentSource.fragments[0]?.lines.join("\n")).toBe(
      "one\nthree\n",
    );
    const cumulative = composeResolvedHunksThrough(
      file,
      resolved!.resolved,
      2,
    )!;
    expect(
      applyPatch("", {
        oldFileName: "",
        newFileName: "",
        oldHeader: undefined,
        newHeader: undefined,
        hunks: cumulative,
      }),
    ).toBe("one\nthree\n");
  });

  it("preserves EOF markers when applying Bash hunks", () => {
    const resolved = resolve(
      [
        {
          oldStart: 1,
          oldLines: 1,
          newStart: 1,
          newLines: 1,
          lines: [
            "-old",
            "\\ No newline at end of file",
            "+new",
            "\\ No newline at end of file",
          ],
        },
      ],
      "old",
    );

    expect(resolved?.currentSource.fragments[0]?.lines.join("\n")).toBe("new");
  });
  it("adapts zero-count coordinates without mutating the tracked hunk", () => {
    const hunks = [{ ...insertion, lines: [...insertion.lines] }];
    const resolved = resolve(hunks);

    expect(resolved?.currentSource.fragments[0]?.lines).toEqual([
      "first",
      "inserted",
      "second",
      "",
    ]);
    expect(hunks).toEqual([insertion]);
  });

  it("applies creation, insertion, and deletion coordinates", () => {
    expect(
      resolve(
        [
          {
            oldStart: 0,
            oldLines: 0,
            newStart: 1,
            newLines: 1,
            lines: ["+new"],
          },
        ],
        "",
      )?.currentSource.fragments[0]?.lines.join("\n"),
    ).toBe("new\n");
    expect(
      resolve(
        [
          {
            oldStart: 1,
            oldLines: 0,
            newStart: 2,
            newLines: 1,
            lines: ["+middle"],
          },
        ],
        "first\nlast\n",
      )?.currentSource.fragments[0]?.lines.join("\n"),
    ).toBe("first\nmiddle\nlast\n");
    expect(
      resolve(
        [
          {
            oldStart: 2,
            oldLines: 1,
            newStart: 2,
            newLines: 0,
            lines: ["-last"],
          },
        ],
        "first\nlast\n",
      )?.currentSource.fragments[0]?.lines.join("\n"),
    ).toBe("first\n");
  });

  it("retains an unresolved result when a complete base cannot apply", () => {
    expect(
      resolve(
        [
          {
            oldStart: 1,
            oldLines: 1,
            newStart: 1,
            newLines: 1,
            lines: ["-first", "+changed"],
          },
        ],
        "unrelated\n",
      ),
    ).toBeNull();
  });
});
