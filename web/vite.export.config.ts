import { defineConfig } from "vite";
import preact from "@preact/preset-vite";
import { viteSingleFile } from "vite-plugin-singlefile";
import path from "path";
import type { Plugin } from "vite";
import { generateExportCdnSnapshot } from "./scripts/export-cdn-manifest.mjs";
import { exportWasmFallbackGuard } from "./scripts/export-wasm-fallback-guard.mjs";

const exportCdnModule = "virtual:cydo-export-cdn";
const resolvedExportCdnModule = `\0${exportCdnModule}`;

type ExportCdnSnapshot = Awaited<ReturnType<typeof generateExportCdnSnapshot>>;

export function exportCdnManifestPlugin(
  createSnapshot: () => Promise<ExportCdnSnapshot> = () =>
    generateExportCdnSnapshot({ projectRoot: __dirname }),
): Plugin {
  let snapshot: Promise<ExportCdnSnapshot> | undefined;

  const getSnapshot = () => {
    if (!snapshot) snapshot = createSnapshot();
    return snapshot;
  };

  return {
    name: "cydo-export-cdn-manifest",
    resolveId(id) {
      return id === exportCdnModule ? resolvedExportCdnModule : undefined;
    },
    async load(id) {
      if (id !== resolvedExportCdnModule) return undefined;
      const { runtimeManifest } = await getSnapshot();
      return `export const treeSitterRuntime = ${JSON.stringify(runtimeManifest.treeSitterRuntime)};\nexport const treeSitterBash = ${JSON.stringify(runtimeManifest.treeSitterBash)};\nexport const treeSitterJavaScript = ${JSON.stringify(runtimeManifest.treeSitterJavaScript)};\nexport const shikiRoots = ${JSON.stringify(runtimeManifest.shikiRoots)};\nexport const mermaidRoots = ${JSON.stringify(runtimeManifest.mermaidRoots)};\nexport const shikiLanguages = ${JSON.stringify(runtimeManifest.shikiLanguages)};\n`;
    },
    async transformIndexHtml() {
      return [
        {
          tag: "script",
          attrs: { type: "importmap" },
          children: JSON.stringify((await getSnapshot()).importMap),
          injectTo: "head-prepend",
        },
      ];
    },
  };
}

export default defineConfig({
  plugins: [
    preact(),
    exportCdnManifestPlugin(),
    exportWasmFallbackGuard(),
    viteSingleFile(),
  ],
  resolve: {
    alias: {
      shiki: path.resolve(__dirname, "src/export/shiki.ts"),
      mermaid: path.resolve(__dirname, "src/export/mermaid.ts"),
    },
  },
  build: {
    outDir: "dist-export",
    rollupOptions: {
      input: "export.html",
    },
  },
});
