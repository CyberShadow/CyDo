import { Language, Parser } from "web-tree-sitter";

type TreeSitterGrammar = "bash";

export type TreeSitterAssets =
  | Readonly<{
      kind: "urls";
      runtime: string;
      languages: Readonly<Record<TreeSitterGrammar, string>>;
    }>
  | Readonly<{
      kind: "bytes";
      loadRuntime(): Promise<Uint8Array>;
      loadLanguage(grammar: TreeSitterGrammar): Promise<Uint8Array>;
    }>;

const WASM_MAGIC = [0, 0x61, 0x73, 0x6d];
const languages = new Map<TreeSitterGrammar, Promise<Language>>();
let configuredAssets: TreeSitterAssets | undefined;
let initialization: Promise<void> | undefined;
let runtimeBytes: Promise<Uint8Array> | undefined;

export function configureTreeSitterAssets(assets: TreeSitterAssets): void {
  if (configuredAssets !== undefined)
    throw new Error("Tree-sitter assets are already configured");
  configuredAssets = assets;
}

export function requireTreeSitterAssets(): TreeSitterAssets {
  if (configuredAssets === undefined)
    throw new Error("Tree-sitter assets are not configured");
  return configuredAssets;
}

export function loadTreeSitterLanguage(
  grammar: TreeSitterGrammar,
): Promise<Language> {
  const assets = requireTreeSitterAssets();
  const cached = languages.get(grammar);
  if (cached !== undefined) return cached;
  const pending = loadLanguage(assets, grammar);
  languages.set(grammar, pending);
  return pending;
}

async function loadLanguage(
  assets: TreeSitterAssets,
  grammar: TreeSitterGrammar,
): Promise<Language> {
  if (assets.kind === "urls") {
    initialization ??= Parser.init({
      locateFile(fileName: string): string {
        if (fileName !== "web-tree-sitter.wasm")
          throw new Error(`unexpected Tree-sitter runtime file: ${fileName}`);
        return assets.runtime;
      },
    });
    await initialization;
    return Language.load(assets.languages[grammar]);
  }

  runtimeBytes ??= assets.loadRuntime();
  const [runtime, bytes] = await Promise.all([
    runtimeBytes,
    assets.loadLanguage(grammar),
  ]);
  assertWasmMagic(runtime);
  assertWasmMagic(bytes);
  await (initialization ??= Parser.init({ wasmBinary: runtime }));
  return Language.load(bytes);
}

function assertWasmMagic(bytes: Uint8Array): void {
  for (let i = 0; i < WASM_MAGIC.length; i++) {
    if (bytes[i] !== WASM_MAGIC[i])
      throw new Error("invalid Tree-sitter WASM magic");
  }
}
