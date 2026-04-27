// Stub for shiki in the export build — syntax highlighting is disabled
// to keep the single-file HTML small.

export type ThemedToken = { content: string; color?: string };
export type BundledLanguage = string;
export type Highlighter = never;

export function createHighlighter(): Promise<never> {
  return new Promise(() => {});
}
