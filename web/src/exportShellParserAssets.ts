import { treeSitterBash, treeSitterRuntime } from "virtual:cydo-export-cdn";
import { fetchBytesWithFallback } from "./export/cdnLoader";
import type { ShellParserAssets } from "./lib/shellParser";

export const exportShellParserAssets: ShellParserAssets = {
  kind: "bytes",
  loadRuntime: () =>
    fetchBytesWithFallback(treeSitterRuntime, "web-tree-sitter.wasm"),
  loadBashLanguage: () =>
    fetchBytesWithFallback(treeSitterBash, "tree-sitter-bash.wasm"),
};
