import { defineConfig } from "vite";
import preact from "@preact/preset-vite";
import { viteSingleFile } from "vite-plugin-singlefile";
import path from "path";
import type { Plugin } from "vite";
import { generateRuntimeManifest } from "./scripts/export-cdn-manifest.mjs";
import { exportWasmFallbackGuard } from "./scripts/export-wasm-fallback-guard.mjs";

const exportCdnModule = "virtual:cydo-export-cdn";
const resolvedExportCdnModule = `\0${exportCdnModule}`;

function exportCdnManifestPlugin(): Plugin {
  return {
    name: "cydo-export-cdn-manifest",
    resolveId(id) {
      return id === exportCdnModule ? resolvedExportCdnModule : undefined;
    },
    load(id) {
      if (id !== resolvedExportCdnModule) return undefined;
      const manifest = generateRuntimeManifest({ projectRoot: __dirname });
      return `export const treeSitterRuntime = ${JSON.stringify(manifest.treeSitterRuntime)};\nexport const treeSitterBash = ${JSON.stringify(manifest.treeSitterBash)};\n`;
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
      shiki: path.resolve(__dirname, "src/shiki-cdn.ts"),
      mermaid: path.resolve(__dirname, "src/mermaid-cdn.ts"),
    },
  },
  build: {
    outDir: "dist-export",
    rollupOptions: {
      input: "export.html",
    },
  },
});
