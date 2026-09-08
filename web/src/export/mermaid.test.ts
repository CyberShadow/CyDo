import { afterEach, describe, expect, it, vi } from "vitest";

const jsdelivrRoot = {
  url: "https://cdn.jsdelivr.net/npm/mermaid@1.0.0/dist/mermaid.esm.min.mjs",
  integrity: "sha384-jsdelivr-root",
};
const unpkgRoot = {
  url: "https://unpkg.com/mermaid@1.0.0/dist/mermaid.esm.min.mjs",
  integrity: "sha384-unpkg-root",
};

async function importMermaid(loader: ReturnType<typeof vi.fn>) {
  vi.resetModules();
  vi.doMock("virtual:cydo-export-cdn", () => ({
    mermaidRoots: [jsdelivrRoot, unpkgRoot],
  }));
  vi.doMock("./cdnLoader", () => ({ importModuleWithFallback: loader }));
  return import("./mermaid");
}

afterEach(() => {
  vi.doUnmock("virtual:cydo-export-cdn");
  vi.doUnmock("./cdnLoader");
  vi.resetModules();
  vi.restoreAllMocks();
});

describe("export Mermaid adapter", () => {
  it("delegates initialize and render through the selected primary root", async () => {
    const api = {
      initialize: vi.fn().mockReturnValue("initialized"),
      render: vi.fn().mockResolvedValue({ svg: "<svg />" }),
    };
    const loader = vi
      .fn()
      .mockResolvedValue({ module: { default: api }, candidate: jsdelivrRoot });
    const mermaid = (await importMermaid(loader)).default;

    await expect(mermaid.initialize({ theme: "dark" })).resolves.toBe(
      "initialized",
    );
    await expect(mermaid.render("diagram-id", "graph TD")).resolves.toEqual({
      svg: "<svg />",
    });

    expect(loader).toHaveBeenCalledWith("mermaid-root", [
      jsdelivrRoot,
      unpkgRoot,
    ]);
    expect(api.initialize).toHaveBeenCalledWith({ theme: "dark" });
    expect(api.render).toHaveBeenCalledWith("diagram-id", "graph TD");
  });

  it("uses the selected secondary root after loader fallback", async () => {
    const api = {
      initialize: vi.fn(),
      render: vi.fn().mockResolvedValue({ svg: "<svg />" }),
    };
    const loader = vi
      .fn()
      .mockResolvedValue({ module: { default: api }, candidate: unpkgRoot });
    const mermaid = (await importMermaid(loader)).default;

    await mermaid.render("fallback-id", "graph TD");

    expect(loader).toHaveBeenCalledWith("mermaid-root", [
      jsdelivrRoot,
      unpkgRoot,
    ]);
    expect(api.render).toHaveBeenCalledWith("fallback-id", "graph TD");
  });

  it("lets aggregate root exhaustion reach Mermaid's caller", async () => {
    const failure = new AggregateError(
      [new Error("jsdelivr unavailable"), new Error("unpkg unavailable")],
      "failed to import mermaid-root from CDN candidates",
    );
    const loader = vi.fn().mockRejectedValue(failure);
    const mermaid = (await importMermaid(loader)).default;

    await expect(mermaid.render("failed-id", "graph TD")).rejects.toBe(failure);
  });
});
