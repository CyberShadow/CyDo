// @vitest-environment jsdom
import { render } from "preact";
import { useState } from "preact/hooks";
import { act } from "preact/test-utils";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { actPoll } from "../test-support/preactAct";
import { LocalFileContext } from "./LocalFileContext";
import type { Block, TrackedFile } from "../types";
import {
  FileViewer,
  fileViewerModeForSelection,
  type ViewMode,
} from "./FileViewer";

const path = "/workspace/live.md";
const access = {
  tid: 7,
  baseDir: "/workspace",
  ancestorPaths: [],
  openInFileViewer() {},
};
const linkedPaths: readonly string[] = [path];
const edited: TrackedFile = {
  path,
  edits: [
    {
      toolUseId: "write",
      messageId: "assistant-1",
      filePath: path,
      type: "write",
      op: "add",
      status: "applied",
      source: "claude-tool",
      payload: { mode: "full_content", content: "# Original edit" },
    },
  ],
};

function Viewer({
  file,
  linkedFiles,
  initialMode,
}: {
  file?: TrackedFile;
  linkedFiles: readonly string[];
  initialMode: ViewMode;
}) {
  const [viewMode, setViewMode] = useState(initialMode);
  return (
    <LocalFileContext.Provider value={access}>
      <FileViewer
        trackedFiles={new Map(file ? [[file.path, file]] : [])}
        linkedFiles={linkedFiles}
        blocks={
          new Map<string, Block>([
            [
              "write",
              {
                itemId: "write",
                type: "tool_use",
                text: "",
                completed: true,
                creationOrder: 0,
              },
            ],
          ])
        }
        selectedFile={file?.path ?? path}
        selectedEditIndex={null}
        viewMode={viewMode}
        height={400}
        itemIdMap={new Map()}
        onSelectFile={() => {}}
        onSelectEdit={() => {}}
        onChangeViewMode={setViewMode}
        onClose={() => {}}
        onResize={() => {}}
        onScrollToToolCall={() => {}}
      />
    </LocalFileContext.Provider>
  );
}

describe("FileViewer Live view", () => {
  let root: HTMLDivElement;
  const fetchPreview = vi.fn<typeof fetch>();

  beforeEach(() => {
    root = document.createElement("div");
    document.body.append(root);
    fetchPreview.mockReset();
    fetchPreview.mockImplementation(() =>
      Promise.resolve(new Response("# Live preview")),
    );
    vi.stubGlobal("fetch", fetchPreview);
    vi.stubGlobal(
      "IntersectionObserver",
      class {
        constructor(
          private callback: (entries: { isIntersecting: boolean }[]) => void,
        ) {}

        observe() {
          this.callback([{ isIntersecting: true }]);
        }

        disconnect() {}
      },
    );
  });

  afterEach(async () => {
    await act(() => {
      render(null, root);
    });
    root.remove();
    vi.unstubAllGlobals();
  });

  function tabs() {
    return Array.from(
      root.querySelectorAll<HTMLButtonElement>(".content-viewer-tabs button"),
    );
  }

  it("keeps a relative tracked key in the edit viewer without Live", async () => {
    const relative = "docs/report.md";
    const file = {
      ...edited,
      path: relative,
      edits: edited.edits.map((edit) => ({ ...edit, filePath: relative })),
    };
    await act(() => {
      render(<Viewer file={file} linkedFiles={[]} initialMode="live" />, root);
    });

    expect(tabs().map((tab) => tab.textContent)).toEqual([
      "Source",
      "Diff",
      "Cumulative",
      "Rendered",
    ]);
    expect(
      root.querySelector(".file-tree-item.selected")?.getAttribute("title"),
    ).toBe(relative);
    expect(
      root.querySelector(".content-viewer-tabs .active")?.textContent,
    ).toBe("Rendered");
    expect(root.querySelector(".edit-history")).not.toBeNull();
    expect(fetchPreview).not.toHaveBeenCalled();
  });

  it.each(["rendered", "live"] as const)(
    "collapses a cycle back to the selected document in %s view",
    async (initialMode) => {
      const content = "![cycle](cycle.md)";
      fetchPreview.mockImplementation((url) => {
        if (url === "/api/live-file?tid=7&path=%2Fworkspace%2Fcycle.md") {
          return Promise.resolve(new Response("![back](live.md)"));
        }
        return Promise.resolve(new Response(content));
      });
      const file = {
        ...edited,
        edits: edited.edits.map((edit) => ({
          ...edit,
          payload: { mode: "full_content" as const, content },
        })),
      };
      await act(() => {
        render(
          <Viewer file={file} linkedFiles={[]} initialMode={initialMode} />,
          root,
        );
      });

      const inner =
        '.content-viewer-body button[aria-label="Expand /workspace/live.md"]';
      await actPoll({
        description: "collapsed embed of the selected document",
        ready: () => root.querySelector(inner) !== null,
      });
      expect(root.querySelector(inner)?.getAttribute("aria-expanded")).toBe(
        "false",
      );
      expect(
        root.querySelectorAll(
          ".content-viewer-body figure.local-file-expansion",
        ),
      ).toHaveLength(1);
      expect(fetchPreview.mock.calls.map(([url]) => url)).toEqual([
        ...(initialMode === "live"
          ? ["/api/live-file?tid=7&path=%2Fworkspace%2Flive.md"]
          : []),
        "/api/live-file?tid=7&path=%2Fworkspace%2Fcycle.md",
      ]);
    },
  );

  it("resets Markdown expansion overrides when the selected document changes", async () => {
    async function show(path: string, content: string) {
      const file: TrackedFile = {
        path,
        edits: edited.edits.map((edit) => ({
          ...edit,
          filePath: path,
          payload: { mode: "full_content", content },
        })),
      };
      await act(() => {
        render(
          <Viewer file={file} linkedFiles={[]} initialMode="rendered" />,
          root,
        );
      });
    }

    await show("/workspace/a.md", "[open](other.md)");
    const expand = root.querySelector<HTMLButtonElement>(
      'button[aria-label="Expand /workspace/other.md"]',
    )!;
    await act(() => {
      expand.click();
    });
    expect(root.querySelector(".content-viewer-body figure")).not.toBeNull();

    await show("/workspace/b.md", "![self](b.md)");
    expect(
      root
        .querySelector('button[aria-label="Expand /workspace/b.md"]')
        ?.getAttribute("aria-expanded"),
    ).toBe("false");
    expect(root.querySelector(".content-viewer-body figure")).toBeNull();
    expect(fetchPreview.mock.calls.map(([url]) => url)).toEqual([
      "/api/live-file?tid=7&path=%2Fworkspace%2Fother.md",
    ]);
  });

  it("defaults to Live for an unlinked file with only a cancelled edit", async () => {
    const cancelled: TrackedFile = {
      ...edited,
      edits: edited.edits.map((edit) => ({ ...edit, status: "cancelled" })),
    };
    await act(() => {
      render(
        <Viewer file={cancelled} linkedFiles={[]} initialMode="rendered" />,
        root,
      );
    });

    expect(tabs().map((tab) => tab.textContent)).toEqual(["Live"]);
    expect(tabs()[0]?.classList.contains("active")).toBe(true);
    await actPoll({
      description: "live content for the tracked file",
      ready: () => root.querySelector(".content-viewer-body h1") !== null,
    });
    expect(root.querySelector(".content-viewer-body h1")?.textContent).toBe(
      "Live preview",
    );
    expect(fetchPreview).toHaveBeenCalledExactlyOnceWith(
      "/api/live-file?tid=7&path=%2Fworkspace%2Flive.md",
      expect.objectContaining({ cache: "no-store" }),
    );
  });

  it.each(["complete", "different fragment layout"] as const)(
    "resets a partial document's expansion overrides on a %s snapshot",
    async (snapshot) => {
      const link = "[open](other.md)";
      const unrelated = "[unrelated](unrelated.md)";
      const partialEdit = (
        startLine: number,
        text: string,
      ): TrackedFile["edits"][number] => ({
        ...edited.edits[0]!,
        type: "edit",
        op: "update",
        source: "claude-bashEditDiff",
        payload: {
          mode: "hunks",
          hunks: [
            {
              oldStart: startLine,
              oldLines: 1,
              newStart: startLine,
              newLines: 1,
              lines: ["-old", `+${text}`],
            },
          ],
        },
      });
      async function show(edits: TrackedFile["edits"]) {
        await act(() => {
          render(
            <Viewer
              file={{ ...edited, edits }}
              linkedFiles={[]}
              initialMode="rendered"
            />,
            root,
          );
        });
      }
      const first = partialEdit(5, link);
      await show([first]);
      expect(
        root.querySelector(".content-viewer-body .source-gap")?.textContent,
      ).toContain("Lines 1-4");
      await act(() => {
        root
          .querySelector<HTMLButtonElement>(
            'button[aria-label="Expand /workspace/other.md"]',
          )!
          .click();
      });
      expect(root.querySelector(".content-viewer-body figure")).not.toBeNull();

      if (snapshot === "complete") {
        await show([
          first,
          {
            ...edited.edits[0]!,
            payload: {
              mode: "full_content",
              content: `${unrelated}\n\nParagraph\n\n${link}`,
            },
          },
        ]);
        expect(
          root.querySelector(".content-viewer-body .source-gap"),
        ).toBeNull();
        expect(
          root
            .querySelector(
              'button[aria-label="Expand /workspace/unrelated.md"]',
            )
            ?.getAttribute("aria-expanded"),
        ).toBe("false");
      } else {
        await show([partialEdit(3, link)]);
        expect(
          root.querySelector(".content-viewer-body .source-gap")?.textContent,
        ).toContain("Lines 1-2");
      }
      expect(
        root
          .querySelector('button[aria-label="Expand /workspace/other.md"]')
          ?.getAttribute("aria-expanded"),
      ).toBe("false");
      expect(root.querySelector(".content-viewer-body figure")).toBeNull();
      expect(fetchPreview.mock.calls.map(([url]) => url)).toEqual([
        "/api/live-file?tid=7&path=%2Fworkspace%2Fother.md",
      ]);
    },
  );

  it("renders only the Live tab and preview for a file without edits", async () => {
    await act(() => {
      render(<Viewer linkedFiles={linkedPaths} initialMode="live" />, root);
    });

    expect(tabs().map((tab) => tab.textContent)).toEqual(["Live"]);
    expect(root.querySelector(".edit-history")).toBeNull();
    await actPoll({
      description: "rendered Live preview",
      ready: () => root.querySelector(".content-viewer-body h1") !== null,
    });
    expect(
      root.querySelector(".content-viewer-tabs > :not(button)"),
    ).toBeNull();
    expect(root.querySelector(".content-viewer-body h1")?.textContent).toBe(
      "Live preview",
    );
  });

  it.each([
    ["linked", linkedPaths],
    ["unlinked", []],
  ] as const)(
    "offers Live alongside edit tabs for a %s file",
    async (_, linkedFiles) => {
      await act(() => {
        render(
          <Viewer
            file={edited}
            linkedFiles={linkedFiles}
            initialMode="source"
          />,
          root,
        );
      });

      expect(tabs().map((tab) => tab.textContent)).toEqual([
        "Source",
        "Diff",
        "Cumulative",
        "Rendered",
        "Live",
      ]);
      expect(fetchPreview).not.toHaveBeenCalled();
      expect(root.querySelector(".edit-history")).not.toBeNull();

      await act(() => {
        tabs()
          .find((tab) => tab.textContent === "Live")!
          .click();
      });

      expect(fetchPreview).toHaveBeenCalledExactlyOnceWith(
        "/api/live-file?tid=7&path=%2Fworkspace%2Flive.md",
        expect.objectContaining({ cache: "no-store" }),
      );
      await actPoll({
        description: "rendered Live preview",
        ready: () => root.querySelector(".content-viewer-body h1") !== null,
      });
      expect(root.querySelector(".content-viewer-body h1")?.textContent).toBe(
        "Live preview",
      );
    },
  );
});

describe("fileViewerModeForSelection", () => {
  const modes = ["source", "diff", "cumulative", "rendered", "live"] as const;

  it.each([undefined, ...modes])(
    "selects Live for a file without edits from %s",
    (previous) => {
      expect(fileViewerModeForSelection(previous, path, false, true)).toBe(
        "live",
      );
    },
  );

  it.each([
    ["/workspace/edited.md", "rendered"],
    ["/workspace/edited.txt", "source"],
  ])("selects the default for %s without a previous mode", (nextPath, mode) => {
    expect(fileViewerModeForSelection(undefined, nextPath, true, true)).toBe(
      mode,
    );
  });

  it.each(modes)("preserves %s for a file with edits", (previous) => {
    expect(fileViewerModeForSelection(previous, path, true, true)).toBe(
      previous,
    );
  });
});
