import { vi } from "vitest";

// Unit tests run real tokenization without Shiki's 500 ms wall-clock cutoff per line.
vi.mock(import("shiki"), async (importOriginal) => {
  const shiki = await importOriginal();
  const createHighlighter: typeof shiki.createHighlighter = async (options) => {
    const highlighter = await shiki.createHighlighter(options);
    return {
      ...highlighter,
      codeToTokens: (code, options) =>
        highlighter.codeToTokens(code, { ...options, tokenizeTimeLimit: 0 }),
    };
  };
  return { ...shiki, createHighlighter };
});
