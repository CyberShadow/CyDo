import { afterEach, describe, expect, it, vi } from "vitest";

const jsdelivrRoot = {
  url: "https://cdn.jsdelivr.net/npm/shiki@1.0.0/dist/bundle-web.mjs",
  integrity: "sha384-jsdelivr-root",
};
const unpkgRoot = {
  url: "https://unpkg.com/shiki@1.0.0/dist/bundle-web.mjs",
  integrity: "sha384-unpkg-root",
};
const bashJsdelivr = {
  url: "https://cdn.jsdelivr.net/npm/@shikijs/langs@1.0.0/dist/shellscript.mjs",
  integrity: "sha384-jsdelivr-bash",
};
const bashUnpkg = {
  url: "https://unpkg.com/@shikijs/langs@1.0.0/dist/shellscript.mjs",
  integrity: "sha384-unpkg-bash",
};
const rustJsdelivr = {
  url: "https://cdn.jsdelivr.net/npm/@shikijs/langs@1.0.0/dist/rust.mjs",
  integrity: "sha384-jsdelivr-rust",
};
const rustUnpkg = {
  url: "https://unpkg.com/@shikijs/langs@1.0.0/dist/rust.mjs",
  integrity: "sha384-unpkg-rust",
};
const nixJsdelivr = {
  url: "https://cdn.jsdelivr.net/npm/@shikijs/langs@1.0.0/dist/nix.mjs",
  integrity: "sha384-jsdelivr-nix",
};
const nixUnpkg = {
  url: "https://unpkg.com/@shikijs/langs@1.0.0/dist/nix.mjs",
  integrity: "sha384-unpkg-nix",
};

const generatedRuntime = {
  shikiRoots: [jsdelivrRoot, unpkgRoot] as const,
  shikiLanguages: {
    bash: { jsdelivr: bashJsdelivr, unpkg: bashUnpkg },
    rust: { jsdelivr: rustJsdelivr, unpkg: rustUnpkg },
    nix: { jsdelivr: nixJsdelivr, unpkg: nixUnpkg },
  },
};

type FakeHighlighter = {
  loadLanguage: ReturnType<typeof vi.fn>;
};

function fakeHighlighter() {
  return {
    loadLanguage: vi.fn().mockResolvedValue(undefined),
  };
}

async function importShiki(loader: ReturnType<typeof vi.fn>) {
  vi.resetModules();
  vi.doMock("virtual:cydo-export-cdn", () => generatedRuntime);
  vi.doMock("./cdnLoader", () => ({ importModuleWithFallback: loader }));
  return import("./shiki");
}

afterEach(() => {
  vi.doUnmock("virtual:cydo-export-cdn");
  vi.doUnmock("./cdnLoader");
  vi.resetModules();
  vi.restoreAllMocks();
});

describe("export Shiki adapter", () => {
  it("uses the selected primary root and delegates bundled strings and registration objects", async () => {
    const highlighter = fakeHighlighter();
    const originalLoadLanguage = highlighter.loadLanguage;
    const rootModule = {
      bundledLanguages: { javascript: {} },
      createHighlighter: vi.fn().mockResolvedValue(highlighter),
    };
    const loader = vi
      .fn()
      .mockResolvedValueOnce({ module: rootModule, candidate: jsdelivrRoot });
    const shiki = await importShiki(loader);
    const registration = { name: "custom" };

    const created = (await shiki.createHighlighter({
      themes: [],
    })) as unknown as FakeHighlighter;
    await created.loadLanguage("javascript", registration);

    expect(loader).toHaveBeenCalledTimes(1);
    expect(loader).toHaveBeenCalledWith("shiki-root", [
      jsdelivrRoot,
      unpkgRoot,
    ]);
    expect(rootModule.createHighlighter).toHaveBeenCalledWith({ themes: [] });
    expect(originalLoadLanguage).toHaveBeenCalledWith(
      "javascript",
      registration,
    );
  });

  it("uses generated jsDelivr language candidates for a primary root", async () => {
    const highlighter = fakeHighlighter();
    const originalLoadLanguage = highlighter.loadLanguage;
    const rootModule = {
      bundledLanguages: {},
      createHighlighter: vi.fn().mockResolvedValue(highlighter),
    };
    const registration = { name: "rust registration" };
    const loader = vi
      .fn()
      .mockResolvedValueOnce({ module: rootModule, candidate: jsdelivrRoot })
      .mockResolvedValueOnce({
        module: { default: registration },
        candidate: rustJsdelivr,
      });
    const shiki = await importShiki(loader);

    const created =
      (await shiki.createHighlighter()) as unknown as FakeHighlighter;
    await created.loadLanguage("rust");

    expect(loader).toHaveBeenNthCalledWith(1, "shiki-root", [
      jsdelivrRoot,
      unpkgRoot,
    ]);
    expect(loader).toHaveBeenNthCalledWith(2, "shiki-language:jsdelivr:rust", [
      rustJsdelivr,
    ]);
    expect(originalLoadLanguage).toHaveBeenCalledWith(registration);
  });

  it("keeps all external language registrations on the secondary root host", async () => {
    const highlighter = fakeHighlighter();
    const originalLoadLanguage = highlighter.loadLanguage;
    const rootModule = {
      bundledLanguages: {},
      createHighlighter: vi.fn().mockResolvedValue(highlighter),
    };
    const rustRegistration = { name: "rust registration" };
    const nixRegistration = { name: "nix registration" };
    const loader = vi
      .fn()
      .mockResolvedValueOnce({ module: rootModule, candidate: unpkgRoot })
      .mockResolvedValueOnce({
        module: { default: rustRegistration },
        candidate: rustUnpkg,
      })
      .mockResolvedValueOnce({
        module: { default: nixRegistration },
        candidate: nixUnpkg,
      });
    const shiki = await importShiki(loader);

    const created =
      (await shiki.createHighlighter()) as unknown as FakeHighlighter;
    await created.loadLanguage("rust", "nix");

    expect(loader).toHaveBeenNthCalledWith(2, "shiki-language:unpkg:rust", [
      rustUnpkg,
    ]);
    expect(loader).toHaveBeenNthCalledWith(3, "shiki-language:unpkg:nix", [
      nixUnpkg,
    ]);
    expect(originalLoadLanguage).toHaveBeenCalledWith(
      rustRegistration,
      nixRegistration,
    );
  });

  it("uses the canonical bash key to select its generated shellscript registration", async () => {
    const highlighter = fakeHighlighter();
    const originalLoadLanguage = highlighter.loadLanguage;
    const rootModule = {
      bundledLanguages: {},
      createHighlighter: vi.fn().mockResolvedValue(highlighter),
    };
    const registration = { name: "shellscript registration" };
    const loader = vi
      .fn()
      .mockResolvedValueOnce({ module: rootModule, candidate: unpkgRoot })
      .mockResolvedValueOnce({
        module: { default: registration },
        candidate: bashUnpkg,
      });
    const shiki = await importShiki(loader);

    const created =
      (await shiki.createHighlighter()) as unknown as FakeHighlighter;
    await created.loadLanguage("bash");

    expect(bashUnpkg.url).toContain("/shellscript.mjs");
    expect(loader).toHaveBeenNthCalledWith(2, "shiki-language:unpkg:bash", [
      bashUnpkg,
    ]);
    expect(originalLoadLanguage).toHaveBeenCalledWith(registration);
  });

  it("rejects unknown string languages before attempting a language import", async () => {
    const highlighter = fakeHighlighter();
    const originalLoadLanguage = highlighter.loadLanguage;
    const rootModule = {
      bundledLanguages: {},
      createHighlighter: vi.fn().mockResolvedValue(highlighter),
    };
    const loader = vi
      .fn()
      .mockResolvedValueOnce({ module: rootModule, candidate: jsdelivrRoot });
    const shiki = await importShiki(loader);

    const created =
      (await shiki.createHighlighter()) as unknown as FakeHighlighter;
    await expect(created.loadLanguage("not-generated")).rejects.toThrow(
      "unknown Shiki language not-generated",
    );

    expect(loader).toHaveBeenCalledTimes(1);
    expect(originalLoadLanguage).not.toHaveBeenCalled();
  });
});
