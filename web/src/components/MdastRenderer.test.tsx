/** @vitest-environment jsdom */

import { h, render } from "preact";
import { act } from "preact/test-utils";
import type { Root } from "mdast";
import { afterEach, describe, expect, it, vi } from "vitest";

const shiki = vi.hoisted(() => ({
  createHighlighter: vi.fn(),
}));
const mermaid = vi.hoisted(() => ({
  initialize: vi.fn(),
  render: vi.fn(),
}));

vi.mock("shiki", () => ({
  createHighlighter: shiki.createHighlighter,
}));
vi.mock("mermaid", () => ({
  default: mermaid,
}));

function ast(language: string, value: string): Root {
  return {
    type: "root",
    children: [{ type: "code", lang: language, value }],
  };
}

async function flushPromises() {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}

async function importRenderer() {
  vi.resetModules();
  return import("./MdastRenderer");
}

async function importRendererWithTheme() {
  vi.resetModules();
  const renderer = await import("./MdastRenderer");
  const { ThemeContext } = await import("../useTheme");
  return { ...renderer, ThemeContext };
}

afterEach(() => {
  shiki.createHighlighter.mockReset();
  mermaid.initialize.mockReset();
  mermaid.render.mockReset();
  vi.restoreAllMocks();
  vi.resetModules();
});

describe("MdastRenderer export fallback boundaries", () => {
  it("keeps raw code rendered when Shiki root loading is exhausted", async () => {
    const root = document.createElement("div");
    document.body.appendChild(root);
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    shiki.createHighlighter.mockRejectedValueOnce(
      new AggregateError([new Error("jsdelivr"), new Error("unpkg")]),
    );
    const { MdastRenderer } = await importRenderer();

    try {
      await act(async () => {
        render(h(MdastRenderer, { ast: ast("rust", "fn main() {}") }), root);
        await flushPromises();
      });

      const code = root.querySelector("pre.language-rust code");
      expect(code?.textContent).toBe("fn main() {}");
      expect(code?.querySelector("span[style]")).toBeNull();
      expect(warn).toHaveBeenCalledWith(
        "Shiki: failed to create highlighter",
        expect.any(AggregateError),
      );
    } finally {
      await act(() => {
        render(null, root);
      });
      root.remove();
    }
  });

  it("renders Mermaid source through its existing visible error boundary", async () => {
    const root = document.createElement("div");
    document.body.appendChild(root);
    const failure = new AggregateError(
      [new Error("jsdelivr"), new Error("unpkg")],
      "failed to import mermaid-root from CDN candidates",
    );
    mermaid.render.mockRejectedValueOnce(failure);
    const { MdastRenderer } = await importRenderer();

    try {
      await act(async () => {
        render(
          h(MdastRenderer, { ast: ast("mermaid", "graph TD; A-->B") }),
          root,
        );
        await flushPromises();
      });

      await vi.waitFor(() => {
        expect(mermaid.initialize).toHaveBeenCalledWith({
          startOnLoad: false,
          theme: "dark",
        });
        expect(mermaid.render).toHaveBeenCalledWith(
          expect.stringMatching(/^mermaid-/),
          "graph TD; A-->B",
        );
        expect(root.querySelector(".mermaid-error code")?.textContent).toBe(
          "graph TD; A-->B",
        );
        expect(root.querySelector(".mermaid-error-msg")?.textContent).toBe(
          "failed to import mermaid-root from CDN candidates",
        );
      });
    } finally {
      await act(() => {
        render(null, root);
      });
      root.remove();
    }
  });

  it("renders source without rendering when initial Mermaid initialization rejects", async () => {
    const root = document.createElement("div");
    document.body.appendChild(root);
    const failure = new AggregateError(
      [new Error("jsdelivr"), new Error("unpkg")],
      "failed to import mermaid-root from CDN candidates",
    );
    const unhandledRejection = vi.fn();
    window.addEventListener("unhandledrejection", unhandledRejection);
    mermaid.initialize.mockImplementationOnce(() => Promise.reject(failure));
    const { MdastRenderer } = await importRenderer();

    try {
      await act(async () => {
        render(
          h(MdastRenderer, { ast: ast("mermaid", "graph TD; A-->B") }),
          root,
        );
        await flushPromises();
      });

      await vi.waitFor(() => {
        expect(mermaid.initialize).toHaveBeenCalledWith({
          startOnLoad: false,
          theme: "dark",
        });
        expect(mermaid.render).not.toHaveBeenCalled();
        expect(root.querySelector(".mermaid-error code")?.textContent).toBe(
          "graph TD; A-->B",
        );
        expect(root.querySelector(".mermaid-error-msg")?.textContent).toBe(
          "failed to import mermaid-root from CDN candidates",
        );
      });
      expect(unhandledRejection).not.toHaveBeenCalled();
    } finally {
      window.removeEventListener("unhandledrejection", unhandledRejection);
      await act(() => {
        render(null, root);
      });
      root.remove();
    }
  });

  it("renders source without rendering when a Mermaid theme change initialization rejects", async () => {
    const root = document.createElement("div");
    document.body.appendChild(root);
    const failure = new AggregateError(
      [new Error("jsdelivr"), new Error("unpkg")],
      "failed to import mermaid-root from CDN candidates",
    );
    const unhandledRejection = vi.fn();
    window.addEventListener("unhandledrejection", unhandledRejection);
    mermaid.initialize
      .mockResolvedValueOnce(undefined)
      .mockImplementationOnce(() => Promise.reject(failure));
    mermaid.render.mockResolvedValueOnce({ svg: "<svg />" });
    const { MdastRenderer, ThemeContext } = await importRendererWithTheme();

    try {
      await act(async () => {
        render(
          h(
            ThemeContext.Provider,
            { value: "dark" },
            h(MdastRenderer, { ast: ast("mermaid", "graph TD; A-->B") }),
          ),
          root,
        );
        await flushPromises();
      });

      await vi.waitFor(() => {
        expect(mermaid.initialize).toHaveBeenCalledWith({
          startOnLoad: false,
          theme: "dark",
        });
        expect(mermaid.render).toHaveBeenCalledWith(
          expect.stringMatching(/^mermaid-/),
          "graph TD; A-->B",
        );
      });

      mermaid.render.mockClear();

      await act(async () => {
        render(
          h(
            ThemeContext.Provider,
            { value: "light" },
            h(MdastRenderer, { ast: ast("mermaid", "graph TD; A-->B") }),
          ),
          root,
        );
        await flushPromises();
      });

      await vi.waitFor(() => {
        expect(mermaid.initialize).toHaveBeenLastCalledWith({
          startOnLoad: false,
          theme: "default",
        });
        expect(mermaid.render).not.toHaveBeenCalled();
        expect(root.querySelector(".mermaid-error code")?.textContent).toBe(
          "graph TD; A-->B",
        );
        expect(root.querySelector(".mermaid-error-msg")?.textContent).toBe(
          "failed to import mermaid-root from CDN candidates",
        );
      });
      expect(unhandledRejection).not.toHaveBeenCalled();
    } finally {
      window.removeEventListener("unhandledrejection", unhandledRejection);
      await act(() => {
        render(null, root);
      });
      root.remove();
    }
  });
});
