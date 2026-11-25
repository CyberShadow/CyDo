import type { TreeSitterAssets } from "../lib/treeSitterRuntime";

const processLike = (
  globalThis as typeof globalThis & {
    process: {
      cwd(): string;
      getBuiltinModule(name: string): unknown;
    };
  }
).process;

const modules = `${processLike.cwd()}/node_modules`;

export const installedTreeSitterUrls = {
  kind: "urls",
  runtime: `${modules}/web-tree-sitter/web-tree-sitter.wasm`,
  languages: {
    bash: `${modules}/tree-sitter-bash/tree-sitter-bash.wasm`,
  },
} satisfies Extract<TreeSitterAssets, { kind: "urls" }>;

async function readWasm(path: string): Promise<Uint8Array> {
  const fs = processLike.getBuiltinModule("node:fs/promises") as {
    readFile(path: string): Promise<Uint8Array>;
  };
  return new Uint8Array(await fs.readFile(path));
}

export const installedTreeSitterBytes = {
  kind: "bytes",
  loadRuntime: () => readWasm(installedTreeSitterUrls.runtime),
  loadLanguage: (grammar) =>
    readWasm(installedTreeSitterUrls.languages[grammar]),
} satisfies Extract<TreeSitterAssets, { kind: "bytes" }>;
