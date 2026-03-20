import {
  createHighlighter,
  type ThemedToken,
  type BundledLanguage,
} from "shiki";
import type { Highlighter } from "shiki";
import { h, Fragment } from "preact";
import { useState, useEffect } from "preact/hooks";
import { useCurrentTheme } from "./useTheme";

export type { ThemedToken };

let highlighterPromise: Promise<Highlighter> | null = null;

const EXT_TO_LANG: Record<string, string> = {
  ".ts": "typescript",
  ".tsx": "tsx",
  ".js": "javascript",
  ".jsx": "jsx",
  ".mjs": "javascript",
  ".cjs": "javascript",
  ".mts": "typescript",
  ".cts": "typescript",
  ".py": "python",
  ".rs": "rust",
  ".go": "go",
  ".d": "d",
  ".c": "c",
  ".cpp": "cpp",
  ".cc": "cpp",
  ".cxx": "cpp",
  ".h": "c",
  ".hpp": "cpp",
  ".hxx": "cpp",
  ".java": "java",
  ".kt": "kotlin",
  ".rb": "ruby",
  ".sh": "bash",
  ".bash": "bash",
  ".zsh": "bash",
  ".css": "css",
  ".scss": "scss",
  ".less": "less",
  ".html": "html",
  ".htm": "html",
  ".vue": "vue",
  ".svelte": "svelte",
  ".json": "json",
  ".jsonc": "jsonc",
  ".yaml": "yaml",
  ".yml": "yaml",
  ".toml": "toml",
  ".md": "markdown",
  ".mdx": "mdx",
  ".sql": "sql",
  ".xml": "xml",
  ".svg": "xml",
  ".nix": "nix",
  ".zig": "zig",
  ".lua": "lua",
  ".vim": "viml",
  ".ex": "elixir",
  ".exs": "elixir",
  ".erl": "erlang",
  ".hs": "haskell",
  ".ml": "ocaml",
  ".php": "php",
  ".swift": "swift",
  ".cs": "csharp",
  ".fs": "fsharp",
  ".r": "r",
  ".R": "r",
  ".pl": "perl",
  ".clj": "clojure",
  ".scala": "scala",
  ".proto": "protobuf",
  ".graphql": "graphql",
  ".gql": "graphql",
  ".ini": "ini",
  ".diff": "diff",
  ".patch": "diff",
  ".prisma": "prisma",
};

const FILENAME_TO_LANG: Record<string, string> = {
  Dockerfile: "dockerfile",
  Makefile: "makefile",
  "CMakeLists.txt": "cmake",
};

export function langFromPath(filePath: string): string | null {
  const basename = filePath.split("/").pop() || "";
  if (FILENAME_TO_LANG[basename]) return FILENAME_TO_LANG[basename];
  const dot = basename.lastIndexOf(".");
  if (dot === -1) return null;
  const ext = basename.slice(dot);
  return EXT_TO_LANG[ext] || EXT_TO_LANG[ext.toLowerCase()] || null;
}

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
  const hl = await getHighlighter();
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
    tokenize(code, lang, shikiTheme).then((t) => {
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
