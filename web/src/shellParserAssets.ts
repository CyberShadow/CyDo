import bashLanguage from "tree-sitter-bash/tree-sitter-bash.wasm?url";
import runtime from "web-tree-sitter/web-tree-sitter.wasm?url";
import type { ShellParserAssets } from "./lib/shellParser";

export const shellParserAssets: ShellParserAssets = {
  kind: "urls",
  runtime,
  bashLanguage,
};
