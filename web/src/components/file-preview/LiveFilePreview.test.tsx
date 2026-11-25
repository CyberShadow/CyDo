// @vitest-environment jsdom
import { act } from "preact/test-utils";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { actPoll, ownedRoots } from "../../test-support/preactAct";
import { LocalFileContext } from "../LocalFileContext";
import { LiveFilePreview } from "./LiveFilePreview";

describe("LiveFilePreview", () => {
  const roots = ownedRoots();
  let notifyIntersection: (entries: { isIntersecting: boolean }[]) => void;
  const observe = vi.fn();

  beforeEach(() => {
    observe.mockClear();
    vi.stubGlobal(
      "IntersectionObserver",
      class {
        constructor(callback: typeof notifyIntersection) {
          notifyIntersection = callback;
        }

        observe = observe;
        disconnect() {}
      },
    );
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  function stubFetch() {
    const fetchMock = vi.fn<typeof fetch>();
    vi.stubGlobal("fetch", fetchMock);
    return fetchMock;
  }

  async function mountPreview(path: string, withContext = true) {
    const root = roots.create();
    await act(() => {
      roots.render(
        <LocalFileContext.Provider
          value={
            withContext ? { tid: 7, baseDir: null, ancestorPaths: [] } : null
          }
        >
          <LiveFilePreview path={path} />
        </LocalFileContext.Provider>,
        root,
      );
    });
    return root;
  }

  function reportIntersection(isIntersecting = true) {
    return act(() => {
      notifyIntersection([{ isIntersecting }]);
    });
  }

  it.each([
    ["/image.png", false],
    ["image.png", true],
  ] as const)(
    "does not observe or fetch %s with context=%s when live access is unavailable",
    async (path, withContext) => {
      const fetchMock = stubFetch();
      const root = await mountPreview(path, withContext);
      expect(root.childElementCount).toBe(0);
      expect(observe).not.toHaveBeenCalled();
      expect(fetchMock).not.toHaveBeenCalled();
    },
  );

  it("renders a PNG response inline as a data URL", async () => {
    const bytes = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]);
    const response = new Response(bytes, {
      headers: { "Content-Type": "image/png" },
    });
    // FileReader in jsdom requires a Blob from its own realm.
    vi.spyOn(response, "blob").mockResolvedValue(
      new Blob([bytes], { type: "image/png" }),
    );
    stubFetch().mockResolvedValue(response);

    const root = await mountPreview("/x/a.png");
    await reportIntersection();
    await actPoll({
      description: "inline PNG preview",
      ready: () => root.querySelector("img.tool-result-image") !== null,
    });
    expect(
      root.querySelector("img.tool-result-image")?.getAttribute("src"),
    ).toBe("data:image/png;base64,iVBORw0KGgo=");
  });

  it("renders Markdown as a heading by default", async () => {
    stubFetch().mockResolvedValue(new Response("# Preview heading"));
    const root = await mountPreview("/x/a.md");
    await reportIntersection();
    await actPoll({
      description: "rendered Markdown heading",
      ready: () => root.querySelector("h1") !== null,
    });
    expect(root.querySelector("h1")?.textContent).toBe("Preview heading");
  });

  it("renders a Git patch as added and removed rows", async () => {
    const patch = [
      "diff --git a/example.txt b/example.txt",
      "--- a/example.txt",
      "+++ b/example.txt",
      "@@ -1 +1 @@",
      "-old value",
      "+new value",
      "",
    ].join("\n");
    stubFetch().mockResolvedValue(new Response(patch));
    const root = await mountPreview("/x/a.diff");
    await reportIntersection();
    await actPoll({
      description: "structured diff rows",
      ready: () => root.querySelector(".diff-added") !== null,
    });
    expect(root.querySelector(".diff-removed")?.textContent).toContain(
      "old value",
    );
    expect(root.querySelector(".diff-added")?.textContent).toContain(
      "new value",
    );
  });

  it("renders syntax-highlighted TypeScript source", async () => {
    const source = "const count: number = 7;";
    stubFetch().mockResolvedValue(new Response(source));
    const root = await mountPreview("/x/a.ts");
    await reportIntersection();
    await actPoll({
      description: "highlighted TypeScript source",
      ready: () => root.querySelector("pre span[style*='color']") !== null,
    });
    expect(root.querySelector("pre")?.textContent).toBe(source);
  });

  it("displays the response body when the file is unavailable", async () => {
    stubFetch().mockResolvedValue(new Response("gone", { status: 422 }));
    const root = await mountPreview("/x/a.txt");
    await reportIntersection();
    await actPoll({
      description: "unavailable response reason",
      ready: () => root.textContent.includes("Unavailable: gone"),
    });
  });

  it("displays an unavailable message when fetch rejects", async () => {
    stubFetch().mockRejectedValue(new Error("network offline"));
    const root = await mountPreview("/x/a.txt");
    await reportIntersection();
    await actPoll({
      description: "unavailable network error",
      ready: () => root.textContent.includes("Unavailable: network offline"),
    });
  });

  it("requests the file by task ID and encoded path", async () => {
    const fetchMock = stubFetch().mockResolvedValue(new Response("preview"));
    await mountPreview("/x/a & b.txt");
    await reportIntersection();

    expect(fetchMock.mock.calls[0]?.[0]).toBe(
      "/api/live-file?tid=7&path=%2Fx%2Fa%20%26%20b.txt",
    );
  });

  it("fetches once when the preview first enters the viewport", async () => {
    const fetchMock = stubFetch().mockResolvedValue(new Response("preview"));
    const root = await mountPreview("/x/a.txt");

    expect(root.textContent).toContain("Loading…");
    expect(observe).toHaveBeenCalledOnce();
    expect(fetchMock).not.toHaveBeenCalled();
    await reportIntersection(false);
    expect(fetchMock).not.toHaveBeenCalled();

    await reportIntersection();
    await reportIntersection();
    expect(fetchMock).toHaveBeenCalledOnce();
  });

  it("aborts an in-flight fetch when the preview unmounts", async () => {
    const fetchMock = stubFetch().mockReturnValue(new Promise(() => {}));
    const root = await mountPreview("/x/a.txt");
    await reportIntersection();

    const signal = fetchMock.mock.calls[0]?.[1]?.signal;
    expect(signal?.aborted).toBe(false);

    await act(() => {
      roots.render(null, root);
    });

    expect(signal?.aborted).toBe(true);
  });
});
