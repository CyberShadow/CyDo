import { Parser, type Node } from "web-tree-sitter";
import { loadTreeSitterLanguage } from "./treeSitterRuntime";

let initialization: Promise<Parser> | undefined;

async function initializeParser(): Promise<Parser> {
  const language = await loadTreeSitterLanguage("javascript");
  const parser = new Parser();
  parser.setLanguage(language);
  return parser;
}

export async function withJavaScriptTree<T>(
  source: string,
  analyze: (root: Node) => T,
): Promise<T> {
  const parser = await (initialization ??= initializeParser());
  const tree = parser.parse(source);
  if (tree === null) throw new Error("JavaScript parser returned no tree");
  try {
    return analyze(tree.rootNode);
  } finally {
    tree.delete();
  }
}
