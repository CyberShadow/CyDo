import { defineConfig } from "vite";
import preact from "@preact/preset-vite";
import { viteSingleFile } from "vite-plugin-singlefile";
import path from "path";

export default defineConfig({
  plugins: [preact(), viteSingleFile()],
  resolve: {
    alias: {
      shiki: path.resolve(__dirname, "src/shiki-stub.ts"),
    },
  },
  build: {
    outDir: "dist-export",
    rollupOptions: {
      input: "export.html",
    },
  },
});
