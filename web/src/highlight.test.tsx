/** @vitest-environment jsdom */

import { h, render } from "preact";
import { act } from "preact/test-utils";
import { afterEach, describe, expect, it, vi } from "vitest";

const shiki = vi.hoisted(() => ({
  createHighlighter: vi.fn(),
}));

vi.mock("shiki", () => ({
  createHighlighter: shiki.createHighlighter,
}));

type Deferred<Value> = {
  promise: Promise<Value>;
  resolve: (value: Value) => void;
};

function deferred<Value>(): Deferred<Value> {
  let resolve: (value: Value) => void;
  const promise = new Promise<Value>((resolvePromise) => {
    resolve = resolvePromise;
  });
  return { promise, resolve: resolve! };
}

function tokenLines(code: string) {
  return [[{ content: code }]];
}

async function importHighlight() {
  vi.resetModules();
  return import("./highlight");
}

async function flushPromises(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}

afterEach(() => {
  shiki.createHighlighter.mockReset();
  vi.restoreAllMocks();
});

describe("highlighting failures", () => {
  it("returns null when highlighter creation rejects", async () => {
    const failure = new Error("Shiki could not initialize");
    shiki.createHighlighter.mockRejectedValueOnce(failure);
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const { tokenize } = await importHighlight();

    await expect(tokenize("const value = 1", "typescript")).resolves.toBe(null);
    expect(shiki.createHighlighter).toHaveBeenCalledTimes(1);
    expect(warn).toHaveBeenCalledWith(
      "Shiki: failed to create highlighter",
      failure,
    );
  });

  it("returns null when language loading rejects", async () => {
    const failure = new Error("typescript module unavailable");
    const highlighter = {
      loadLanguage: vi.fn().mockRejectedValueOnce(failure),
      codeToTokens: vi.fn(),
    };
    shiki.createHighlighter.mockResolvedValueOnce(highlighter);
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const { tokenize } = await importHighlight();

    await expect(tokenize("const value = 1", "typescript")).resolves.toBe(null);
    expect(highlighter.loadLanguage).toHaveBeenCalledWith("typescript");
    expect(highlighter.codeToTokens).not.toHaveBeenCalled();
    expect(warn).toHaveBeenCalledWith(
      'Shiki: failed to load language "typescript"',
      failure,
    );
  });

  it("leaves tokenization errors observable", async () => {
    const failure = new Error("invalid Shiki token stream");
    const highlighter = {
      loadLanguage: vi.fn().mockResolvedValue(undefined),
      codeToTokens: vi.fn(() => {
        throw failure;
      }),
    };
    shiki.createHighlighter.mockResolvedValueOnce(highlighter);
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const { tokenize } = await importHighlight();

    await expect(tokenize("const value = 1", "typescript")).rejects.toBe(
      failure,
    );
    expect(warn).not.toHaveBeenCalled();
  });
});

describe("useHighlight", () => {
  it("does not let a superseded completion replace newer tokens", async () => {
    const shownLanguage = deferred<undefined>();
    const oldLanguage = deferred<undefined>();
    const newLanguage = deferred<undefined>();
    const highlighter = {
      loadLanguage: vi.fn((language: string) => {
        if (language === "shown") return shownLanguage.promise;
        if (language === "old") return oldLanguage.promise;
        if (language === "new") return newLanguage.promise;
        throw new Error(`unexpected language ${language}`);
      }),
      codeToTokens: vi.fn((code: string) => ({ tokens: tokenLines(code) })),
    };
    shiki.createHighlighter.mockResolvedValueOnce(highlighter);
    const { useHighlight } = await importHighlight();
    const container = document.createElement("div");
    document.body.appendChild(container);
    let tokens: ReturnType<typeof useHighlight> = null;

    function Probe({ code, lang }: { code: string; lang: string }) {
      tokens = useHighlight(code, lang);
      return null;
    }

    try {
      await act(async () => {
        render(h(Probe, { code: "shown code", lang: "shown" }), container);
        await flushPromises();
      });
      expect(highlighter.loadLanguage).toHaveBeenCalledWith("shown");

      await act(async () => {
        shownLanguage.resolve(undefined);
        await flushPromises();
      });
      expect(tokens).toEqual(tokenLines("shown code"));

      await act(async () => {
        render(h(Probe, { code: "old code", lang: "old" }), container);
        await flushPromises();
      });
      expect(highlighter.loadLanguage).toHaveBeenCalledWith("old");
      expect(tokens).toBeNull();

      await act(async () => {
        render(h(Probe, { code: "new code", lang: "new" }), container);
        await flushPromises();
      });
      expect(highlighter.loadLanguage).toHaveBeenCalledWith("new");

      await act(async () => {
        newLanguage.resolve(undefined);
        await flushPromises();
      });
      expect(tokens).toEqual(tokenLines("new code"));

      await act(async () => {
        oldLanguage.resolve(undefined);
        await flushPromises();
      });
      expect(tokens).toEqual(tokenLines("new code"));
    } finally {
      await act(() => {
        render(null, container);
      });
      container.remove();
    }
  });

  it("does not render a completion after unmount", async () => {
    const language = deferred<undefined>();
    const highlighter = {
      loadLanguage: vi.fn(() => language.promise),
      codeToTokens: vi.fn((code: string) => ({ tokens: tokenLines(code) })),
    };
    shiki.createHighlighter.mockResolvedValueOnce(highlighter);
    const { useHighlight } = await importHighlight();
    const container = document.createElement("div");
    document.body.appendChild(container);
    const renders: Array<ReturnType<typeof useHighlight>> = [];

    function Probe() {
      const tokens = useHighlight("unmounted code", "typescript");
      renders.push(tokens);
      return null;
    }

    try {
      await act(async () => {
        render(h(Probe, {}), container);
        await flushPromises();
      });
      expect(highlighter.loadLanguage).toHaveBeenCalledWith("typescript");

      await act(() => {
        render(null, container);
      });
      const renderCountAtUnmount = renders.length;

      await act(async () => {
        language.resolve(undefined);
        await flushPromises();
      });
      expect(renders).toHaveLength(renderCountAtUnmount);
    } finally {
      await act(() => {
        render(null, container);
      });
      container.remove();
    }
  });
});
