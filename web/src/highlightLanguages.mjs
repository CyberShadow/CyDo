export const EXT_TO_LANG = Object.freeze({
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
});

export const FILENAME_TO_LANG = Object.freeze({
  Dockerfile: "dockerfile",
  Makefile: "makefile",
  "CMakeLists.txt": "cmake",
});

export const supportedHighlightLanguages = Object.freeze(
  [
    ...new Set([
      ...Object.values(EXT_TO_LANG),
      ...Object.values(FILENAME_TO_LANG),
    ]),
  ].sort(),
);

export function langFromPath(filePath) {
  const basename = filePath.split("/").pop() || "";
  if (FILENAME_TO_LANG[basename]) return FILENAME_TO_LANG[basename];
  const dot = basename.lastIndexOf(".");
  if (dot === -1) return null;
  const ext = basename.slice(dot);
  return EXT_TO_LANG[ext] || EXT_TO_LANG[ext.toLowerCase()] || null;
}
