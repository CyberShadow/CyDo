// @vitest-environment jsdom
import { act } from "preact/test-utils";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { actPoll, ownedRoots } from "../test-support/preactAct";
import { LocalFileContext } from "./LocalFileContext";
import { Markdown } from "./Markdown";
import { FileContentPreview } from "./file-preview/FileContentPreview";

const roots = ownedRoots();
const context = {
  tid: 7,
  baseDir: "/w",
  ancestorPaths: [],
  openInFileViewer() {},
};
const fetchMock = vi.fn<typeof fetch>();

beforeEach(() => {
  fetchMock.mockReset();
  vi.stubGlobal("fetch", fetchMock);
  vi.stubGlobal(
    "IntersectionObserver",
    class {
      constructor(
        private readonly callback: (
          entries: { isIntersecting: boolean }[],
        ) => void,
      ) {}

      observe() {
        this.callback([{ isIntersecting: true }]);
      }

      disconnect() {}
    },
  );
});

afterEach(() => {
  vi.unstubAllGlobals();
});

function markdown(text: string) {
  return (
    <LocalFileContext.Provider value={context}>
      <Markdown text={text} enableSourceToggle={false} />
    </LocalFileContext.Provider>
  );
}

async function mount(text: string) {
  const root = roots.create();
  await act(() => {
    roots.render(markdown(text), root);
  });
  return root;
}

function captions(root: ParentNode) {
  return Array.from(
    root.querySelectorAll(".local-file-expansion > figcaption"),
    (caption) => caption.textContent,
  );
}

function controls(root: ParentNode) {
  return Array.from(
    root.querySelectorAll<HTMLButtonElement>("button[aria-expanded]"),
  );
}

function click(button: HTMLButtonElement) {
  return act(() => {
    button.click();
  });
}

describe("Markdown local file layout", () => {
  beforeEach(() => {
    fetchMock.mockImplementation(() => new Promise(() => {}));
  });

  it("places local embed controls after an enclosing web link", async () => {
    const root = await mount(
      "[**![shot](/w/shot.png)**](https://example.org/).",
    );
    const paragraph = root.querySelector("p")!;
    const anchor = paragraph.querySelector("a")!;
    const buttons = anchor.nextElementSibling!;
    expect(anchor.href).toBe("https://example.org/");
    expect(anchor.textContent).toBe("shot");
    expect(paragraph.querySelector("a button")).toBeNull();
    expect(buttons.classList.contains("local-file-link-controls")).toBe(true);
    expect(
      buttons.querySelector(
        'button[aria-label="Open /w/shot.png in the file viewer"]',
      ),
    ).not.toBeNull();
    const [toggle] = controls(buttons);
    expect(toggle?.getAttribute("aria-expanded")).toBe("true");
    expect(captions(paragraph.nextElementSibling!)).toEqual(["/w/shot.png"]);

    await click(toggle!);
    expect(paragraph.nextElementSibling).toBeNull();
  });

  it("expands embeds and places manually opened links in document order after the paragraph", async () => {
    const root = await mount(
      "See [PNG link](/x/link.png) and ![Text embed](/x/embed.txt).",
    );
    const paragraph = root.querySelector("p")!;
    const panels = paragraph.nextElementSibling!;
    const buttons = controls(paragraph);
    expect(buttons).toHaveLength(2);
    const link = buttons[0]!;
    const embed = buttons[1]!;

    expect(paragraph.querySelector("a, figure")).toBeNull();
    expect(panels.classList.contains("local-file-expansions")).toBe(true);
    expect(link.getAttribute("aria-expanded")).toBe("false");
    expect(embed.getAttribute("aria-expanded")).toBe("true");
    expect(captions(panels)).toEqual(["/x/embed.txt"]);
    expect(fetchMock.mock.calls.map(([url]) => url)).toEqual([
      "/api/live-file?tid=7&path=%2Fx%2Fembed.txt",
    ]);

    await click(link);
    expect(link.getAttribute("aria-expanded")).toBe("true");
    expect(captions(panels)).toEqual(["/x/link.png", "/x/embed.txt"]);

    await click(embed);
    expect(embed.getAttribute("aria-expanded")).toBe("false");
    expect(captions(panels)).toEqual(["/x/link.png"]);
  });

  it.each([
    ["heading", "## ![file](/x/a.txt)", "h2"],
    ["table", "| File |\n| --- |\n| ![file](/x/a.txt) |\n", "table"],
    ["task item", "- [ ] ![file](/x/a.txt)", "li > label"],
  ])("places a preview after its %s host", async (_name, text, selector) => {
    const root = await mount(text);
    const host = root.querySelector(selector)!;
    expect(host.querySelector("figure")).toBeNull();
    expect(captions(host.nextElementSibling!)).toEqual(["/x/a.txt"]);
  });

  it("expands a task item link without changing its disabled checkbox", async () => {
    const root = await mount("- [ ] [file](/x/a.txt)");
    const label = root.querySelector("li > label")!;
    const checkbox = label.querySelector("input")!;
    expect(checkbox.disabled).toBe(true);
    expect(checkbox.checked).toBe(false);
    expect(label.nextElementSibling).toBeNull();

    await click(controls(label)[0]!);

    expect(captions(label.nextElementSibling!)).toEqual(["/x/a.txt"]);
    expect(checkbox.checked).toBe(false);
  });

  it("keeps each list preview in its own item and before its nested list", async () => {
    const root = await mount(
      "- outer ![first](/x/first.txt)\n  - nested ![second](/x/second.txt)",
    );
    const outer = root.querySelector(".markdown > ul > li")!;
    const outerPanels = outer.querySelector(":scope > p")!.nextElementSibling!;
    const nestedList = outerPanels.nextElementSibling!;

    expect(captions(outerPanels)).toEqual(["/x/first.txt"]);
    expect(nestedList.tagName).toBe("UL");
    expect(
      captions(nestedList.querySelector("li > p")!.nextElementSibling!),
    ).toEqual(["/x/second.txt"]);
  });

  it("discards overrides when Markdown replaces existing text", async () => {
    const root = await mount("[first](/w/first.md)");
    await click(controls(root)[0]!);
    expect(captions(root)).toEqual(["/w/first.md"]);

    await act(() => {
      roots.render(markdown("[second](/w/second.md)"), root);
    });

    expect(controls(root)[0]?.getAttribute("aria-expanded")).toBe("false");
    expect(captions(root)).toEqual([]);
  });

  it("preserves a preview opened before more Markdown streams in", async () => {
    const first = "[file](rel.png)\n\n";
    const root = await mount(first);
    await click(controls(root)[0]!);
    expect(fetchMock.mock.calls.map(([url]) => url)).toEqual([
      "/api/live-file?tid=7&path=%2Fw%2Frel.png",
    ]);

    await act(() => {
      roots.render(markdown(first + "Next paragraph."), root);
    });
    expect(root.textContent).toContain("Next paragraph.");
    expect(controls(root)[0]!.getAttribute("aria-expanded")).toBe("true");
    expect(captions(root)).toEqual(["/w/rel.png"]);
  });

  it("keeps a streamed embed collapsed when an enclosing link is completed", async () => {
    const first = "[![shot](/w/shot.png)]";
    const root = await mount(first);
    expect(captions(root)).toEqual(["/w/shot.png"]);
    await click(controls(root)[0]!);
    expect(captions(root)).toEqual([]);

    await act(() => {
      roots.render(markdown(first + "(/w/report.md)"), root);
    });

    expect(
      controls(root).map((button) => button.getAttribute("aria-label")),
    ).toEqual(["Expand /w/shot.png", "Expand /w/report.md"]);
    expect(captions(root)).toEqual([]);
    expect(fetchMock.mock.calls.map(([url]) => url)).toEqual([
      "/api/live-file?tid=7&path=%2Fw%2Fshot.png",
    ]);
  });

  it("does not transfer expansion when an append turns the earlier link into code", async () => {
    const first = "Example: `[a](/work/a)";
    const root = await mount(first);
    await click(controls(root)[0]!);
    expect(captions(root)).toEqual(["/work/a"]);

    await act(() => {
      roots.render(markdown(first + "` then [b](/work/b)"), root);
    });

    expect(root.querySelector("code")?.textContent).toBe("[a](/work/a)");
    expect(
      controls(root).map((button) => button.getAttribute("aria-label")),
    ).toEqual(["Expand /work/b"]);
    expect(captions(root)).toEqual([]);
    expect(fetchMock.mock.calls.map(([url]) => url)).toEqual([
      "/api/live-file?tid=7&path=%2Fwork%2Fa",
    ]);
  });

  it("keeps separate overrides for repeated links and embeds to the same path", async () => {
    const first = "[one](/w/same.md) [two](/w/same.md) ![embed](/w/same.md)";
    const root = await mount(first);
    await click(controls(root)[1]!);
    await click(controls(root)[2]!);

    await act(() => {
      roots.render(markdown(first + " [three](/w/same.md)"), root);
    });

    expect(
      controls(root).map((button) => button.getAttribute("aria-expanded")),
    ).toEqual(["false", "true", "false", "false"]);
    expect(captions(root)).toEqual(["/w/same.md"]);
  });

  it("renders local destinations inert without a provider and preserves web links", async () => {
    const root = roots.create();
    await act(() => {
      roots.render(
        <Markdown
          text="[Local link](/x/local.png) ![Local embed](/x/embed.png) [Web](https://example.org)"
          enableSourceToggle={false}
        />,
        root,
      );
    });

    expect(
      Array.from(
        root.querySelectorAll("span.local-file-link-inert"),
        (span) => span.textContent,
      ),
    ).toEqual(["Local link", "Local embed"]);
    const anchors = root.querySelectorAll("a");
    expect(anchors).toHaveLength(1);
    expect(anchors[0]!.getAttribute("href")).toBe("https://example.org");
    expect(anchors[0]!.target).toBe("_blank");
    expect(controls(root)).toHaveLength(0);
    expect(captions(root)).toEqual([]);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("leaves a relative embed inert when the session directory is unknown", async () => {
    const root = roots.create();
    await act(() => {
      roots.render(
        <LocalFileContext.Provider value={{ ...context, baseDir: null }}>
          <Markdown
            text="![Local embed](relative.md)"
            enableSourceToggle={false}
          />
        </LocalFileContext.Provider>,
        root,
      );
    });

    expect(root.querySelector("span.local-file-link-inert")?.textContent).toBe(
      "Local embed",
    );
    expect(root.querySelector("a, img, button, figure")).toBeNull();
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe("Markdown file previews", () => {
  it("leaves relative embeds inert in a relative document with no base", async () => {
    const root = roots.create();
    await act(() => {
      roots.render(
        <LocalFileContext.Provider value={{ ...context, baseDir: null }}>
          <FileContentPreview
            filePath="docs/a.md"
            content="![notes](notes.md)"
          />
        </LocalFileContext.Provider>,
        root,
      );
    });

    expect(root.querySelector(".local-file-link-inert")?.textContent).toBe(
      "notes",
    );
    expect(controls(root)).toHaveLength(0);
    expect(captions(root)).toEqual([]);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("resets a preview's Markdown link expansion when its document changes", async () => {
    fetchMock.mockImplementation(() => new Promise(() => {}));
    const root = roots.create();
    async function show(filePath: string, content: string) {
      await act(() => {
        roots.render(
          <LocalFileContext.Provider value={context}>
            <FileContentPreview filePath={filePath} content={content} />
          </LocalFileContext.Provider>,
          root,
        );
      });
    }
    await show("/w/a.md", "[open](other.md)");
    await click(controls(root)[0]!);
    expect(captions(root)).toEqual(["/w/other.md"]);

    await show("/w/b.md", "![self](b.md)");
    expect(controls(root)[0]?.getAttribute("aria-expanded")).toBe("false");
    expect(captions(root)).toEqual([]);
    expect(fetchMock.mock.calls.map(([url]) => url)).toEqual([
      "/api/live-file?tid=7&path=%2Fw%2Fother.md",
    ]);
  });

  it("resolves links against the previewed file's directory", async () => {
    fetchMock.mockResolvedValue(new Response("Image preview content"));
    const root = roots.create();
    await act(() => {
      roots.render(
        <LocalFileContext.Provider value={context}>
          <FileContentPreview
            filePath="/w/docs/a.md"
            content="[image](img/p.png)"
          />
        </LocalFileContext.Provider>,
        root,
      );
    });

    expect(fetchMock).not.toHaveBeenCalled();
    await click(controls(root)[0]!);
    expect(fetchMock.mock.calls.map(([url]) => url)).toEqual([
      "/api/live-file?tid=7&path=%2Fw%2Fdocs%2Fimg%2Fp.png",
    ]);
  });

  it("expands a self-embedded Markdown file one level and lets users open it again", async () => {
    fetchMock
      .mockResolvedValueOnce(new Response("![again](./a.md)"))
      .mockResolvedValueOnce(new Response("![again](./a.md)"))
      .mockResolvedValue(new Response("Unexpected recursive fetch"));
    const root = await mount("![first](/w/docs/a.md)");
    const request = "/api/live-file?tid=7&path=%2Fw%2Fdocs%2Fa.md";
    await actPoll({
      description: "the self-embedded file's expansion control",
      ready: () => controls(root).length >= 2,
    });

    expect(captions(root)).toEqual(["/w/docs/a.md"]);
    expect(fetchMock.mock.calls.map(([url]) => url)).toEqual([request]);
    const repeated = controls(root)[1]!;
    expect(repeated.getAttribute("aria-expanded")).toBe("false");

    await click(repeated);
    await actPoll({
      description: "the manually opened file's expansion control",
      ready: () => controls(root).length >= 3,
    });
    expect(captions(root)).toEqual(["/w/docs/a.md", "/w/docs/a.md"]);
    expect(fetchMock.mock.calls.map(([url]) => url)).toEqual([
      request,
      request,
    ]);
    expect(controls(root)[2]!.getAttribute("aria-expanded")).toBe("false");
  });
});
