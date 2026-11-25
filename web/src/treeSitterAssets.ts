import bashLanguage from "tree-sitter-bash/tree-sitter-bash.wasm?url";
import runtime from "web-tree-sitter/web-tree-sitter.wasm?url";
import type { TreeSitterAssets } from "./lib/treeSitterRuntime";

export const treeSitterAssets: TreeSitterAssets = {
  kind: "urls",
  runtime,
  languages: { bash: bashLanguage },
};
