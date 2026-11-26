import {
  existsSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { JSDOM } from "jsdom";
import { build } from "vite";
import { afterEach, describe, expect, it, vi } from "vitest";
import exportConfig, { exportCdnManifestPlugin } from "../vite.export.config";
import { generateExportCdnSnapshot } from "./export-cdn-manifest.mjs";

const webRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
const temporaryRoots = [];
const allowedExportOutputPaths = new Set([
  "apple-touch-icon.png",
  "export.html",
  "favicon.svg",
  "icon-192.png",
  "icon-512.png",
  "manifest.json",
]);

afterEach(() => {
  for (const root of temporaryRoots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

function temporaryBuildRoot() {
  const root = mkdtempSync(join(tmpdir(), "cydo-export-vite-test-"));
  temporaryRoots.push(root);
  return root;
}

function exportOutputPaths(root, relativePath = "") {
  return readdirSync(join(root, relativePath), { withFileTypes: true }).flatMap(
    (entry) => {
      const path = join(relativePath, entry.name);
      return entry.isDirectory()
        ? [path, ...exportOutputPaths(root, path)]
        : [path];
    },
  );
}

function configuredPluginsWith(plugin, beforeSingleFilePlugin) {
  if (!Array.isArray(exportConfig.plugins)) {
    throw new Error("export Vite config must declare its plugins as an array");
  }

  let replacements = 0;
  let singleFilePlugins = 0;
  const plugins = exportConfig.plugins.flatMap((configured) => {
    if (
      configured !== null &&
      typeof configured === "object" &&
      !Array.isArray(configured) &&
      "name" in configured &&
      configured.name === plugin.name
    ) {
      replacements++;
      return [plugin];
    }
    if (
      configured !== null &&
      typeof configured === "object" &&
      !Array.isArray(configured) &&
      "name" in configured &&
      configured.name === "vite:singlefile"
    ) {
      singleFilePlugins++;
      return [beforeSingleFilePlugin, configured];
    }
    return [configured];
  });

  expect(replacements).toBe(1);
  expect(singleFilePlugins).toBe(1);
  return plugins;
}

describe("export CDN Vite configuration", () => {
  it("memoizes one supplied snapshot across virtual-module and HTML hooks", async () => {
    const snapshot = await generateExportCdnSnapshot({ projectRoot: webRoot });
    const createSnapshot = vi.fn(async () => snapshot);
    const plugin = exportCdnManifestPlugin(createSnapshot);

    expect(createSnapshot).not.toHaveBeenCalled();

    if (typeof plugin.resolveId !== "function") {
      throw new Error("export CDN plugin must resolve its virtual module");
    }
    const virtualId = "\0virtual:cydo-export-cdn";
    expect(await plugin.resolveId("virtual:cydo-export-cdn")).toBe(virtualId);

    if (typeof plugin.load !== "function") {
      throw new Error("export CDN plugin must load its virtual module");
    }
    const [source, tags] = await Promise.all([
      plugin.load(virtualId),
      plugin.transformIndexHtml(),
    ]);
    expect(source).not.toContain("export default");
    expect(source).not.toContain(webRoot);
    expect(source).not.toContain("node_modules/");
    expect(source.trim().split("\n")).toHaveLength(5);
    const declarations = Array.from(
      source.matchAll(/^export const (\w+) = (.+);$/gm),
      ([, name, value]) => ({ name, value: JSON.parse(value) }),
    );

    expect(declarations.map(({ name }) => name)).toEqual([
      "treeSitterRuntime",
      "treeSitterBash",
      "shikiRoots",
      "mermaidRoots",
      "shikiLanguages",
    ]);
    expect(declarations.map(({ value }) => value)).toEqual([
      snapshot.runtimeManifest.treeSitterRuntime,
      snapshot.runtimeManifest.treeSitterBash,
      snapshot.runtimeManifest.shikiRoots,
      snapshot.runtimeManifest.mermaidRoots,
      snapshot.runtimeManifest.shikiLanguages,
    ]);

    expect(tags).toEqual([
      {
        tag: "script",
        attrs: { type: "importmap" },
        children: JSON.stringify(snapshot.importMap),
        injectTo: "head-prepend",
      },
    ]);
    expect(createSnapshot).toHaveBeenCalledTimes(1);
  });

  it("builds the supplied import map before every module script", async () => {
    const snapshot = await generateExportCdnSnapshot({ projectRoot: webRoot });
    const createSnapshot = vi.fn(async () => snapshot);
    const buildRoot = temporaryBuildRoot();
    const outDir = join(buildRoot, "dist-export");
    const bundledModuleIds = new Set();
    const moduleAuditPlugin = {
      name: "cydo-export-cdn-module-audit",
      generateBundle(_options, bundle) {
        for (const entry of Object.values(bundle)) {
          if (entry.type !== "chunk") continue;
          for (const moduleId of Object.keys(entry.modules)) {
            bundledModuleIds.add(moduleId);
          }
        }
      },
    };

    expect(Object.keys(snapshot.importMap.scopes)).toEqual([
      "https://cdn.jsdelivr.net/npm/",
      "https://unpkg.com/",
    ]);
    const javascriptUrls = Object.entries(snapshot.fixtureManifest.urls)
      .filter(([, record]) => record.contentType === "application/javascript")
      .map(([url]) => url);
    expect(Object.keys(snapshot.importMap.integrity)).toEqual(javascriptUrls);
    for (const url of javascriptUrls) {
      const record = snapshot.fixtureManifest.urls[url];
      expect(record).toBeDefined();
      expect(snapshot.importMap.integrity[url]).toBe(record.integrity);
      expect(snapshot.importMap.integrity[url]).toMatch(
        /^sha384-[A-Za-z0-9+/]+={0,2}$/,
      );
    }

    if (!exportConfig.build) {
      throw new Error("export Vite config must declare build options");
    }
    await build({
      ...exportConfig,
      configFile: false,
      root: webRoot,
      cacheDir: join(buildRoot, "vite-cache"),
      logLevel: "silent",
      plugins: configuredPluginsWith(
        exportCdnManifestPlugin(createSnapshot),
        moduleAuditPlugin,
      ),
      build: {
        ...exportConfig.build,
        outDir,
        emptyOutDir: true,
      },
    });

    expect(createSnapshot).toHaveBeenCalledTimes(1);
    const outputPaths = exportOutputPaths(outDir).sort();
    expect(outputPaths).toContain("export.html");
    expect(
      outputPaths.every((path) => allowedExportOutputPaths.has(path)),
    ).toBe(true);
    expect(outputPaths.filter((path) => path.endsWith(".html"))).toEqual([
      "export.html",
    ]);
    expect(outputPaths.some((path) => /\.(?:css|js|wasm)$/.test(path))).toBe(
      false,
    );
    expect(
      outputPaths.some((path) =>
        path
          .split(/[\\/]/)
          .some((segment) => ["files", "vendor"].includes(segment)),
      ),
    ).toBe(false);
    const html = readFileSync(join(outDir, "export.html"), "utf8");
    const document = new JSDOM(html).window.document;
    const importMaps = document.querySelectorAll('script[type="importmap"]');
    const moduleScripts = document.querySelectorAll('script[type="module"]');

    expect(importMaps).toHaveLength(1);
    expect(moduleScripts.length).toBeGreaterThan(0);
    expect(JSON.parse(importMaps[0].textContent)).toEqual(snapshot.importMap);
    const scripts = Array.from(document.querySelectorAll("script"));
    const importMapPosition = scripts.indexOf(importMaps[0]);
    for (const moduleScript of moduleScripts) {
      expect(importMapPosition).toBeLessThan(scripts.indexOf(moduleScript));
    }

    const wasmUrls = [
      ...snapshot.runtimeManifest.treeSitterRuntime,
      ...snapshot.runtimeManifest.treeSitterBash,
    ].map(({ url }) => url);
    expect(Object.keys(snapshot.importMap.integrity)).not.toEqual(
      expect.arrayContaining(wasmUrls),
    );
    expect(html).not.toContain("/+esm");
    expect(html).not.toContain("data:application/wasm");
    expect(html).not.toContain("createObjectURL(");
    expect(html).not.toContain("node_modules/");
    expect(html).not.toContain("files/@shikijs");
    expect(importMaps[0].textContent).not.toContain(webRoot);
    expect(importMaps[0].textContent).not.toContain("node_modules/");

    const emittedEsmUrls = Array.from(
      html.matchAll(/https:\/\/esm\.sh\/[^"'\\\s]+/g),
      ([url]) => url,
    ).sort();
    const expectedEsmUrls = wasmUrls
      .filter((url) => url.startsWith("https://esm.sh/"))
      .sort();
    expect(emittedEsmUrls).toEqual(expectedEsmUrls);

    const capturedModuleIds = [...bundledModuleIds];
    expect(capturedModuleIds).toEqual(
      expect.arrayContaining([
        join(webRoot, "src/export/shiki.ts"),
        join(webRoot, "src/export/mermaid.ts"),
      ]),
    );
    expect(
      capturedModuleIds.some((id) => id.includes("/node_modules/shiki/")),
    ).toBe(false);
    expect(
      capturedModuleIds.some((id) => id.includes("/node_modules/mermaid/")),
    ).toBe(false);
  });

  it("keeps the export shell generated and removes superseded CDN adapters", () => {
    const template = readFileSync(join(webRoot, "export.html"), "utf8");
    const document = new JSDOM(template).window.document;

    expect(document.querySelectorAll('script[type="importmap"]')).toHaveLength(
      0,
    );
    expect(document.querySelectorAll("#app")).toHaveLength(1);
    expect(
      document.querySelectorAll(
        'script#cydo-export-data[type="application/json"]',
      ),
    ).toHaveLength(1);
    expect(
      document.querySelectorAll(
        'script[type="module"][src="/src/export-main.tsx"]',
      ),
    ).toHaveLength(1);
    expect(template).not.toMatch(
      /https:\/\/(?:cdn\.jsdelivr\.net\/npm|unpkg\.com|esm\.sh)\//,
    );
    expect(template).not.toMatch(/\b(?:shiki|mermaid)@\d/);
    expect(template).not.toMatch(/\bsha(?:256|384|512)-/);

    for (const supersededPath of [
      "src/exportCdn.ts",
      "src/shiki-cdn.ts",
      "src/mermaid-cdn.ts",
    ]) {
      expect(existsSync(join(webRoot, supersededPath))).toBe(false);
    }
  });
});
