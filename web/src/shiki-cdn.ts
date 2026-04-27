// CDN-loading shim for shiki in export builds.
// Components show raw text until the CDN delivers, then re-render
// with syntax highlighting. If offline, raw text stays permanently.

/* eslint-disable @typescript-eslint/no-explicit-any, @typescript-eslint/no-unsafe-return, @typescript-eslint/no-unsafe-call, @typescript-eslint/no-unsafe-member-access */

export type ThemedToken = { content: string; color?: string };
export type BundledLanguage = string;
export type Highlighter = never;

const CDN_URL = "https://esm.sh/shiki@4.0.1";

export function createHighlighter(...args: unknown[]): Promise<never> {
  return import(/* @vite-ignore */ CDN_URL).then(
    (mod: any) => mod.createHighlighter(...args) as never,
  );
}
