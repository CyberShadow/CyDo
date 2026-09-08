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
  const [tokens, setTokens] = useState<ThemedToken[][] | null>(null);

  useEffect(() => {
    if (!code || !lang) {
      setTokens(null);
      return;
    }
    let cancelled = false;
    setTokens(null);
    void tokenize(code, lang, shikiTheme).then((t) => {
      if (!cancelled) setTokens(t);
    });
    return () => {
      cancelled = true;
    };
  }, [code, lang, shikiTheme]);

  return tokens;
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
