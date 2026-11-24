import {
  createHighlighter,
  type ThemedToken,
  type BundledLanguage,
} from "shiki";
import type { Highlighter } from "shiki";
import { h, Fragment } from "preact";
import { useState, useEffect } from "preact/hooks";
import { langFromPath } from "./highlightLanguages.mjs";
import { useCurrentTheme } from "./useTheme";
import { splitOutputRows } from "./lib/outputPlan";

export type { ThemedToken };

let highlighterPromise: Promise<Highlighter> | null = null;

export { langFromPath };

export type ShikiTheme = "github-dark" | "github-light";

function getHighlighter(): Promise<Highlighter> {
  if (!highlighterPromise) {
    highlighterPromise = createHighlighter({
      themes: ["github-dark", "github-light"],
      langs: [],
    });
  }
  return highlighterPromise;
}

const loadedLangs = new Set<string>();

export async function tokenize(
  code: string,
  lang: string,
  theme: ShikiTheme = "github-dark",
): Promise<ThemedToken[][] | null> {
  let hl: Highlighter;
  try {
    hl = await getHighlighter();
  } catch (error) {
    console.warn("Shiki: failed to create highlighter", error);
    return null;
  }
  if (!loadedLangs.has(lang)) {
    try {
      await hl.loadLanguage(lang as Parameters<Highlighter["loadLanguage"]>[0]);
      loadedLangs.add(lang);
    } catch (e) {
      console.warn(`Shiki: failed to load language "${lang}"`, e);
      return null;
    }
  }
  const result = hl.codeToTokens(code, {
    lang: lang as BundledLanguage,
    theme,
  });
  return result.tokens;
}

export function useHighlight(
  code: string | null | undefined,
  lang: string | null | undefined,
): ThemedToken[][] | null {
  const appTheme = useCurrentTheme();
  const shikiTheme: ShikiTheme =
    appTheme === "light" ? "github-light" : "github-dark";
  const [highlighted, setHighlighted] = useState<{
    code: string;
    lang: string;
    theme: ShikiTheme;
    tokens: ThemedToken[][] | null;
  } | null>(null);

  useEffect(() => {
    if (!code || !lang) return;
    let cancelled = false;
    setHighlighted(null);
    void tokenize(code, lang, shikiTheme).then((tokens) => {
      if (!cancelled) setHighlighted({ code, lang, theme: shikiTheme, tokens });
    });
    return () => {
      cancelled = true;
    };
  }, [code, lang, shikiTheme]);

  return highlighted?.code === code &&
    highlighted?.lang === lang &&
    highlighted?.theme === shikiTheme
    ? highlighted.tokens
    : null;
}

export function renderTokens(tokens: ThemedToken[]): h.JSX.Element {
  return h(
    Fragment,
    null,
    tokens.map((t, i) =>
      h("span", { key: i, style: { color: t.color } }, t.content),
    ),
  );
}

export function highlightRowAt(
  tokens: ThemedToken[][] | null,
  index: number,
  source: string,
): ThemedToken[] | null {
  if (!tokens) return null;
  const row = tokens[index];
  if (!row || row.map((token) => token.content).join("") !== source) {
    throw new Error("Highlight token rows do not match source rows");
  }
  return row;
}

export function renderHighlightedRow(
  tokens: ThemedToken[][] | null,
  index: number,
  source: string,
): h.JSX.Element | string {
  const row = highlightRowAt(tokens, index, source);
  return row ? renderTokens(row) : source;
}

function assertHighlightRowCount(
  rowCount: number,
  tokens: ThemedToken[][],
): void {
  if (rowCount !== tokens.length) {
    throw new Error("Highlight token rows do not match source rows");
  }
}

export function useHighlightRows(
  rows: readonly string[],
  lang: string | null,
): ThemedToken[][] | null {
  // This buffer is for tokenization only. CRLF keeps a payload CR intact.
  const tokens = useHighlight(rows.join("\r\n"), lang);
  if (tokens) assertHighlightRowCount(rows.length, tokens);
  return tokens;
}

export function highlightedSourceRows(source: string, tokens: ThemedToken[][]) {
  const rows = Array.from(splitOutputRows(source));
  // Shiki includes an empty last row for empty or newline-terminated source.
  if (source === "" || source.endsWith("\n")) {
    rows.push({ text: "", terminator: "" });
  }
  assertHighlightRowCount(rows.length, tokens);
  rows.forEach(({ text }, index) => highlightRowAt(tokens, index, text));
  return rows;
}

export function renderHighlightedSource(
  source: string,
  tokens: ThemedToken[][] | null,
): h.JSX.Element | string {
  if (!tokens) return source;

  const rows = highlightedSourceRows(source, tokens);

  return h(
    Fragment,
    null,
    rows.map(({ terminator }, index) =>
      h(Fragment, { key: index }, renderTokens(tokens[index]!), terminator),
    ),
  );
}
