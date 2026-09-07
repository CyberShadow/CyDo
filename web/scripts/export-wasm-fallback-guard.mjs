import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const PINNED_VERSION = "0.27.0";
const FALLBACK_SOURCE =
  'return new URL("web-tree-sitter.wasm", import.meta.url).href;';
const REPLACEMENT_SOURCE =
  'if (wasmBinary) return "";\n    throw new Error("web-tree-sitter runtime requires wasmBinary");';
const GUARD_NAME = "cydo-export-wasm-fallback-guard";
const ASSET_PLUGIN_NAME = "vite:asset-import-meta-url";

function packagePaths(root) {
  const packageRoot = resolve(root, "node_modules/web-tree-sitter");
  return {
    packageJson: resolve(packageRoot, "package.json"),
    runtime: resolve(packageRoot, "web-tree-sitter.js"),
  };
}

function countOccurrences(source, value) {
  return source.split(value).length - 1;
}

function verifyInstalledRuntime(root) {
  const paths = packagePaths(root);
  const packageJson = JSON.parse(readFileSync(paths.packageJson, "utf8"));
  if (packageJson.version !== PINNED_VERSION) {
    throw new Error(
      `${GUARD_NAME} expected web-tree-sitter ${PINNED_VERSION}, got ${packageJson.version ?? "missing"}`,
    );
  }

  const source = readFileSync(paths.runtime, "utf8");
  const count = countOccurrences(source, FALLBACK_SOURCE);
  if (count !== 1) {
    throw new Error(
      `${GUARD_NAME} expected exactly one ${PINNED_VERSION} fallback expression, got ${count}`,
    );
  }
}

export function exportWasmFallbackGuard() {
  let runtimePath;
  let transformCount = 0;

  return {
    name: GUARD_NAME,
    enforce: "pre",
    configResolved(config) {
      runtimePath = packagePaths(config.root).runtime;
      verifyInstalledRuntime(config.root);

      const guardIndex = config.plugins.findIndex(
        (plugin) => plugin.name === GUARD_NAME,
      );
      const assetIndex = config.plugins.findIndex(
        (plugin) => plugin.name === ASSET_PLUGIN_NAME,
      );
      if (guardIndex === -1 || assetIndex === -1 || guardIndex >= assetIndex) {
        throw new Error(
          `${GUARD_NAME} must be ordered before ${ASSET_PLUGIN_NAME}`,
        );
      }
    },
    transform(code, id) {
      const cleanId = id.split("?")[0];
      if (cleanId !== runtimePath) return undefined;

      transformCount++;
      if (transformCount !== 1) {
        throw new Error(
          `${GUARD_NAME} transformed ${cleanId} more than once during the export build`,
        );
      }

      const count = countOccurrences(code, FALLBACK_SOURCE);
      if (count !== 1) {
        throw new Error(
          `${GUARD_NAME} saw ${count} fallback expressions in ${cleanId}`,
        );
      }
      return code.replace(FALLBACK_SOURCE, REPLACEMENT_SOURCE);
    },
    buildEnd() {
      if (transformCount !== 1) {
        throw new Error(
          `${GUARD_NAME} transformed the runtime ${transformCount} times during the export build; expected exactly once`,
        );
      }
    },
  };
}

export { FALLBACK_SOURCE, GUARD_NAME, PINNED_VERSION, REPLACEMENT_SOURCE };
