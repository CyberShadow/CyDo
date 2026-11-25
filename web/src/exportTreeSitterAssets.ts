import { treeSitterBash, treeSitterRuntime } from "virtual:cydo-export-cdn";
import { fetchBytesWithFallback } from "./export/cdnLoader";
import type { TreeSitterAssets } from "./lib/treeSitterRuntime";

export const exportTreeSitterAssets: TreeSitterAssets = {
  kind: "bytes",
  loadRuntime: () =>
    fetchBytesWithFallback(treeSitterRuntime, "web-tree-sitter.wasm"),
  loadLanguage: () =>
    fetchBytesWithFallback(treeSitterBash, "tree-sitter-bash.wasm"),
};
