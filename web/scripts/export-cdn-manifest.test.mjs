import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { supportedHighlightLanguages } from "../src/highlightLanguages.mjs";
import {
  generateExportCdnSnapshot,
  validateExportCdnFixtures,
  writeExportCdnFixtures,
} from "./export-cdn-manifest.mjs";

const webRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
const actualInputs = {
  projectRoot: webRoot,
};
const actualNodeModulesPath = join(webRoot, "node_modules");
const exportCdnManifestScript = join(
  webRoot,
  "scripts",
  "export-cdn-manifest.mjs",
);
const rawScopes = ["https://cdn.jsdelivr.net/npm/", "https://unpkg.com/"];
const wasmScopes = [...rawScopes, "https://esm.sh/"];
const wasmArtifacts = [
  {
    exportName: "treeSitterRuntime",
    packageName: "web-tree-sitter",
    relativePath: "web-tree-sitter.wasm",
  },
  {
    exportName: "treeSitterBash",
    packageName: "tree-sitter-bash",
    relativePath: "tree-sitter-bash.wasm",
  },
  {
    exportName: "treeSitterJavaScript",
    packageName: "tree-sitter-javascript",
    relativePath: "tree-sitter-javascript.wasm",
  },
];
const temporaryRoots = [];

afterEach(() => {
  for (const root of temporaryRoots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

function compare(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

function sortedObject(entries) {
  return Object.fromEntries(
    [...entries].sort(([left], [right]) => compare(left, right)),
  );
}

function readJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function writeJson(path, value) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
}

function writeFile(path, contents) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, contents);
}

function temporaryDirectory() {
  const root = mkdtempSync(join(tmpdir(), "cydo-export-cdn-manifest-"));
  temporaryRoots.push(root);
  return root;
}

function integrity(bytes) {
  return `sha384-${createHash("sha384").update(bytes).digest("base64")}`;
}

function packageUrl(scope, packageName, version, relativePath) {
  return `${scope}${packageName}@${version}/${relativePath}`;
}

function expectSortedKeys(object) {
  const keys = Object.keys(object);
  expect(keys).toEqual([...keys].sort(compare));
}

function installedPackage(packageName) {
  const lockfile = readJson(join(webRoot, "package-lock.json"));
  const locked = lockfile.packages[`node_modules/${packageName}`];
  const manifest = readJson(
    join(actualNodeModulesPath, packageName, "package.json"),
  );

  expect(locked?.version).toEqual(manifest.version);
  return { version: manifest.version, manifest };
}

function createSyntheticInputs({
  languages = ["bash"],
  nestedNodeModules = false,
  shikiRootSource = "export {};\n",
  mermaidRootSource = "export {};\n",
  configure,
} = {}) {
  const temporaryRoot = temporaryDirectory();
  const projectRoot = nestedNodeModules
    ? join(temporaryRoot, "synthetic")
    : temporaryRoot;
  const nodeModulesPath = join(projectRoot, "node_modules");
  const lockfilePath = join(projectRoot, "package-lock.json");
  const rootDependencies = {
    "web-tree-sitter": "1.0.0",
    "tree-sitter-bash": "1.0.0",
    "tree-sitter-javascript": "1.0.0",
    shiki: "1.0.0",
    mermaid: "1.0.0",
  };
  const lockPackages = {};

  function packageRoot(location) {
    return join(nodeModulesPath, location);
  }

  function addPackage(
    location,
    { name = location, version = "1.0.0", manifest = {}, files = {} } = {},
  ) {
    const root = packageRoot(location);
    writeJson(join(root, "package.json"), { name, version, ...manifest });
    for (const [relativePath, contents] of Object.entries(files)) {
      writeFile(join(root, relativePath), contents);
    }
    lockPackages[`node_modules/${location}`] = { version };
    return root;
  }

  addPackage("web-tree-sitter", {
    files: { "web-tree-sitter.wasm": Buffer.from([0, 0x61, 0x73, 0x6d]) },
  });
  addPackage("tree-sitter-bash", {
    files: { "tree-sitter-bash.wasm": Buffer.from([0, 0x61, 0x73, 0x6d]) },
  });
  addPackage("tree-sitter-javascript", {
    files: { "tree-sitter-javascript.wasm": Buffer.from([0, 0x61, 0x73, 0x6d]) },
  });
  addPackage("shiki", {
    manifest: { exports: { ".": "./dist/bundle-web.mjs" } },
    files: {
      "dist/bundle-web.mjs": shikiRootSource,
      "dist/langs.mjs": `export const bundledLanguagesInfo = ${JSON.stringify(
        languages.map((id) => ({ id })),
      )};\n`,
      "dist/themes.mjs":
        'export const bundledThemesInfo = [{ id: "github-light" }, { id: "github-dark" }];\n',
    },
  });
  addPackage("mermaid", {
    files: { "dist/mermaid.esm.min.mjs": mermaidRootSource },
  });
  addPackage("@shikijs/langs", {
    manifest: {
      exports: Object.fromEntries(
        languages.map((language) => [
          `./${language}`,
          `./dist/${language}.mjs`,
        ]),
      ),
    },
    files: Object.fromEntries(
      languages.map((language) => [`dist/${language}.mjs`, "export {};\n"]),
    ),
  });
  addPackage("@shikijs/themes", {
    manifest: {
      exports: {
        "./github-light": "./dist/github-light.mjs",
        "./github-dark": "./dist/github-dark.mjs",
      },
    },
    files: {
      "dist/github-light.mjs": "export {};\n",
      "dist/github-dark.mjs": "export {};\n",
    },
  });

  configure?.({
    projectRoot,
    nodeModulesPath,
    packageRoot,
    addPackage,
    writeFile,
  });
  writeJson(lockfilePath, {
    lockfileVersion: 3,
    packages: {
      "": { dependencies: rootDependencies },
      ...lockPackages,
    },
  });

  return {
    projectRoot,
    supportedLanguages: languages,
  };
}

async function writtenSyntheticFixture() {
  const inputs = createSyntheticInputs();
  const fixtureRoot = temporaryDirectory();
  await writeExportCdnFixtures({ fixtureRoot, ...inputs });
  return {
    inputs,
    fixtureRoot,
    manifest: readJson(join(fixtureRoot, "manifest.json")),
  };
}

function writeFixtureManifest(fixtureRoot, manifest) {
  writeJson(join(fixtureRoot, "manifest.json"), manifest);
}

describe("export CDN manifest", () => {
  it("generates deterministic, sorted asynchronous API results", async () => {
    const first = await generateExportCdnSnapshot(actualInputs);
    const second = await generateExportCdnSnapshot(actualInputs);

    expect(second).toEqual(first);

    expect(Object.keys(first.runtimeManifest)).toEqual([
      "treeSitterRuntime",
      "treeSitterBash",
      "treeSitterJavaScript",
      "shikiRoots",
      "mermaidRoots",
      "shikiLanguages",
    ]);
    expectSortedKeys(first.runtimeManifest.shikiLanguages);
    expectSortedKeys(first.importMap.scopes);
    expectSortedKeys(first.importMap.integrity);
    expectSortedKeys(first.fixtureManifest.urls);
    for (const scope of Object.values(first.importMap.scopes)) {
      expectSortedKeys(scope);
    }
  });

  it("exposes asynchronous fixture operations", async () => {
    const fixtureRoot = temporaryDirectory();
    await expect(writeExportCdnFixtures({ fixtureRoot, ...actualInputs })).resolves.toBeUndefined();
    await expect(validateExportCdnFixtures(fixtureRoot, actualInputs)).resolves.toBeUndefined();
  });

  it("uses lockfile-installed bytes and preserves the WASM fallback order", async () => {
    const { runtimeManifest: runtime, fixtureManifest: fixture } =
      await generateExportCdnSnapshot(actualInputs);

    for (const artifact of wasmArtifacts) {
      const { version } = installedPackage(artifact.packageName);
      const bytes = readFileSync(
        join(
          actualNodeModulesPath,
          artifact.packageName,
          artifact.relativePath,
        ),
      );
      const candidates = runtime[artifact.exportName];

      expect(candidates.map(({ url }) => url)).toEqual(
        wasmScopes.map((scope) =>
          packageUrl(
            scope,
            artifact.packageName,
            version,
            artifact.relativePath,
          ),
        ),
      );
      expect(
        candidates.map(
          ({ integrity: candidateIntegrity }) => candidateIntegrity,
        ),
      ).toEqual(Array(wasmScopes.length).fill(integrity(bytes)));
      for (const candidate of candidates) {
        expect(Object.keys(candidate)).toEqual(["url", "integrity"]);
        expect(fixture.urls[candidate.url]?.file).toBe(
          `files/${artifact.packageName}/${artifact.relativePath}`,
        );
      }
    }
  });

  it("limits JavaScript assets to the two raw CDN hosts", async () => {
    const snapshot = await generateExportCdnSnapshot(actualInputs);
    const { runtimeManifest, importMap, fixtureManifest } = snapshot;

    for (const [packageName, relativePath, candidates] of [
      ["shiki", "dist/bundle-web.mjs", runtimeManifest.shikiRoots],
      ["mermaid", "dist/mermaid.esm.min.mjs", runtimeManifest.mermaidRoots],
    ]) {
      const { version } = installedPackage(packageName);
      expect(candidates.map(({ url }) => url)).toEqual(
        rawScopes.map((scope) =>
          packageUrl(scope, packageName, version, relativePath),
        ),
      );
    }

    expect(Object.keys(importMap.scopes)).toEqual(rawScopes);
    for (const candidates of Object.values(runtimeManifest.shikiLanguages)) {
      expect(Object.keys(candidates)).toEqual(["jsdelivr", "unpkg"]);
      for (const { url } of Object.values(candidates)) {
        expect(rawScopes.some((scope) => url.startsWith(scope))).toBe(true);
      }
    }
    for (const [url, record] of Object.entries(fixtureManifest.urls)) {
      if (record.contentType === "application/javascript") {
        expect(rawScopes.some((scope) => url.startsWith(scope))).toBe(true);
      }
    }
  });

  it("covers all supported languages, selected themes, Mermaid chunks, and descendants", async () => {
    const snapshot = await generateExportCdnSnapshot(actualInputs);
    const { runtimeManifest, importMap, fixtureManifest } = snapshot;
    const jsdelivrScope = importMap.scopes[rawScopes[0]];

    expect(Object.keys(runtimeManifest.shikiLanguages)).toEqual(
      supportedHighlightLanguages,
    );
    expect(jsdelivrScope["@shikijs/themes/github-light"]).toMatch(
      /^https:\/\/cdn\.jsdelivr\.net\/npm\/@shikijs\/themes@[^/]+\/dist\/github-light\.mjs$/,
    );
    expect(jsdelivrScope["@shikijs/themes/github-dark"]).toMatch(
      /^https:\/\/cdn\.jsdelivr\.net\/npm\/@shikijs\/themes@[^/]+\/dist\/github-dark\.mjs$/,
    );
    expect(jsdelivrScope["@shikijs/langs/"]).toMatch(
      /^https:\/\/cdn\.jsdelivr\.net\/npm\/@shikijs\/langs@[^/]+\/dist\/$/,
    );
    expect(jsdelivrScope["@shikijs/themes/"]).toMatch(
      /^https:\/\/cdn\.jsdelivr\.net\/npm\/@shikijs\/themes@[^/]+\/dist\/$/,
    );
    expect(jsdelivrScope["shiki/wasm"]).toMatch(
      /^https:\/\/cdn\.jsdelivr\.net\/npm\/shiki@[^/]+\/dist\/wasm\.mjs$/,
    );
    expect(jsdelivrScope["@shikijs/engine-oniguruma/wasm-inlined"]).toMatch(
      /^https:\/\/cdn\.jsdelivr\.net\/npm\/@shikijs\/engine-oniguruma@[^/]+\/dist\/wasm-inlined\.mjs$/,
    );
    expect(runtimeManifest.shikiLanguages.bash.jsdelivr.url).toMatch(
      /\/@shikijs\/langs@[^/]+\/dist\/shellscript\.mjs$/,
    );
    expect(jsdelivrScope["@shikijs/langs/rust"]).toMatch(
      /^https:\/\/cdn\.jsdelivr\.net\/npm\/@shikijs\/langs@[^/]+\/dist\/rust\.mjs$/,
    );
    expect(
      Object.keys(fixtureManifest.urls).some((url) =>
        /\/mermaid@[^/]+\/dist\/chunks\/mermaid\.esm\.min\//.test(url),
      ),
    ).toBe(true);
    expect(
      Object.keys(fixtureManifest.urls).some((url) =>
        /\/@shikijs\/langs@[^/]+\/dist\/markdown-nix\.mjs$/.test(url),
      ),
    ).toBe(true);
  });

  it("keeps runtime and import-map output independent of local filesystem paths", async () => {
    const snapshot = await generateExportCdnSnapshot(actualInputs);
    const output = JSON.stringify({
      runtimeManifest: snapshot.runtimeManifest,
      importMap: snapshot.importMap,
    });

    expect(output).not.toContain(actualInputs.projectRoot);
    expect(output).not.toContain(actualNodeModulesPath);
    expect(output).not.toContain("file:");
  });

  it("writes fixtures whose manifest integrity is recomputable from copied bytes", async () => {
    const { fixtureManifest: expected } =
      await generateExportCdnSnapshot(actualInputs);
    const fixtureRoot = temporaryDirectory();

    await writeExportCdnFixtures({ fixtureRoot, ...actualInputs });
    const manifest = readJson(join(fixtureRoot, "manifest.json"));

    expect(manifest).toEqual(expected);
    const fileIntegrity = new Map();
    for (const record of Object.values(manifest.urls)) {
      if (!fileIntegrity.has(record.file)) {
        fileIntegrity.set(
          record.file,
          integrity(readFileSync(join(fixtureRoot, record.file))),
        );
      }
      expect(record.integrity).toBe(fileIntegrity.get(record.file));
    }
    await expect(validateExportCdnFixtures(fixtureRoot, actualInputs)).resolves.toBeUndefined();
  });

  it("writes and validates fixtures through its CLI", async () => {
    const snapshot = await generateExportCdnSnapshot(actualInputs);
    const fixtureRoot = temporaryDirectory();
    const run = (args) =>
      spawnSync(process.execPath, [exportCdnManifestScript, ...args], {
        cwd: webRoot,
        encoding: "utf8",
        shell: false,
      });

    const write = run(["--fixture-root", fixtureRoot]);
    expect(write.status).toBe(0);
    expect(write.stdout).toBe("");
    expect(write.stderr).toBe("");
    expect(readFileSync(join(fixtureRoot, "manifest.json"), "utf8")).toBe(
      `${JSON.stringify(snapshot.fixtureManifest, null, 2)}\n`,
    );

    const validate = run(["--validate-fixture", fixtureRoot]);
    expect(validate.status).toBe(0);
    expect(validate.stdout).toBe("");
    expect(validate.stderr).toBe("");

    const invalid = run(["--unknown"]);
    expect(invalid.status).not.toBe(0);
    expect(invalid.stdout).toBe("");
    expect(invalid.stderr).toContain("export CDN manifest: usage:");
  });

  it("keeps colliding scoped package names in distinct fixture files", async () => {
    const firstPackage = "@a/b__c";
    const secondPackage = "@a__b/c";
    const firstSource = 'export const source = "first";\n';
    const secondSource = 'export const source = "second";\n';
    const inputs = createSyntheticInputs({
      shikiRootSource: `import "${firstPackage}";\n`,
      mermaidRootSource: `import "${secondPackage}";\n`,
      configure({ addPackage }) {
        for (const [packageName, source] of [
          [firstPackage, firstSource],
          [secondPackage, secondSource],
        ]) {
          addPackage(packageName, {
            manifest: { exports: { ".": "./dist/index.mjs" } },
            files: { "dist/index.mjs": source },
          });
        }
      },
    });
    const snapshot = await generateExportCdnSnapshot(inputs);
    const recordsFor = (packageName) =>
      rawScopes.map(
        (scope) =>
          snapshot.fixtureManifest.urls[
            packageUrl(scope, packageName, "1.0.0", "dist/index.mjs")
          ],
      );
    const firstRecords = recordsFor(firstPackage);
    const secondRecords = recordsFor(secondPackage);

    expect(snapshot.importMap.scopes[rawScopes[0]][firstPackage]).toBe(
      packageUrl(rawScopes[0], firstPackage, "1.0.0", "dist/index.mjs"),
    );
    expect(snapshot.importMap.scopes[rawScopes[0]][secondPackage]).toBe(
      packageUrl(rawScopes[0], secondPackage, "1.0.0", "dist/index.mjs"),
    );
    expect(firstRecords).toEqual(Array(rawScopes.length).fill(firstRecords[0]));
    expect(secondRecords).toEqual(
      Array(rawScopes.length).fill(secondRecords[0]),
    );
    expect(firstRecords[0]).toMatchObject({
      integrity: integrity(Buffer.from(firstSource)),
      contentType: "application/javascript",
    });
    expect(secondRecords[0]).toMatchObject({
      integrity: integrity(Buffer.from(secondSource)),
      contentType: "application/javascript",
    });
    expect(firstRecords[0].file).not.toBe(secondRecords[0].file);

    const fixtureRoot = temporaryDirectory();
    await writeExportCdnFixtures({ fixtureRoot, ...inputs });
    expect(readJson(join(fixtureRoot, "manifest.json"))).toEqual(
      snapshot.fixtureManifest,
    );
    expect(readFileSync(join(fixtureRoot, firstRecords[0].file), "utf8")).toBe(
      firstSource,
    );
    expect(readFileSync(join(fixtureRoot, secondRecords[0].file), "utf8")).toBe(
      secondSource,
    );
    await expect(validateExportCdnFixtures(fixtureRoot, inputs)).resolves.toBeUndefined();
  });

  it("retains missing and ambiguous requested-language diagnostics", async () => {
    const missing = createSyntheticInputs({
      configure({ packageRoot, writeFile: write }) {
        write(
          join(packageRoot("shiki"), "dist", "langs.mjs"),
          'export const bundledLanguagesInfo = [{ id: "other" }];\n',
        );
      },
    });
    const ambiguous = createSyntheticInputs({
      configure({ packageRoot, writeFile: write }) {
        write(
          join(packageRoot("shiki"), "dist", "langs.mjs"),
          'export const bundledLanguagesInfo = [{ id: "one", aliases: ["bash"] }, { id: "two", aliases: ["bash"] }];\n',
        );
      },
    });

    await expect(generateExportCdnSnapshot(missing)).rejects.toThrow(
      "Shiki language registry has no entry for bash",
    );
    await expect(generateExportCdnSnapshot(ambiguous)).rejects.toThrow(
      "Shiki language registry has ambiguous entries for bash",
    );
  });

  it("writes the bytes captured before a Shiki registry mutates a WASM source", async () => {
    const originalBytes = Buffer.from([0, 0x61, 0x73, 0x6d, 1]);
    const mutatedBytes = Buffer.from([0, 0x61, 0x73, 0x6d, 2]);
    const inputs = createSyntheticInputs({
      configure({ packageRoot, writeFile: write }) {
        const wasmPath = join(
          packageRoot("web-tree-sitter"),
          "web-tree-sitter.wasm",
        );
        write(wasmPath, originalBytes);
        write(
          join(packageRoot("shiki"), "dist", "langs.mjs"),
          [
            'import { writeFileSync } from "node:fs";',
            `writeFileSync(${JSON.stringify(wasmPath)}, new Uint8Array(${JSON.stringify([...mutatedBytes])}));`,
            'export const bundledLanguagesInfo = [{ id: "bash" }];',
            "",
          ].join("\n"),
        );
      },
    });
    const fixtureRoot = temporaryDirectory();

    await writeExportCdnFixtures({ fixtureRoot, ...inputs });

    const manifest = readJson(join(fixtureRoot, "manifest.json"));
    const record =
      manifest.urls[
        packageUrl(
          rawScopes[0],
          "web-tree-sitter",
          "1.0.0",
          "web-tree-sitter.wasm",
        )
      ];
    expect(
      readFileSync(
        join(join(inputs.projectRoot, "node_modules"), "web-tree-sitter", "web-tree-sitter.wasm"),
      ),
    ).toEqual(mutatedBytes);
    expect(readFileSync(join(fixtureRoot, record.file))).toEqual(originalBytes);
    expect(record.integrity).toBe(integrity(originalBytes));
    expect(record.integrity).not.toBe(integrity(mutatedBytes));
  });

  it("rejects installed package version drift", async () => {
    const inputs = createSyntheticInputs();
    const manifestPath = join(
      join(inputs.projectRoot, "node_modules"),
      "web-tree-sitter",
      "package.json",
    );
    const manifest = readJson(manifestPath);
    manifest.version = "0.0.0";
    writeJson(manifestPath, manifest);

    await expect(generateExportCdnSnapshot(inputs)).rejects.toThrow(
      "web-tree-sitter installed version 0.0.0 does not equal locked version 1.0.0",
    );
  });

  it("rejects a missing reachable module", async () => {
    const inputs = createSyntheticInputs({
      mermaidRootSource: 'import "./chunk.mjs";\n',
      configure({ packageRoot, writeFile: write }) {
        write(
          join(packageRoot("mermaid"), "dist", "chunk.mjs"),
          "export {};\n",
        );
      },
    });
    rmSync(join(join(inputs.projectRoot, "node_modules"), "mermaid", "dist", "chunk.mjs"));

    await expect(generateExportCdnSnapshot(inputs)).rejects.toThrow(
      "missing module ./chunk.mjs",
    );
  });

  it("rejects a configured language that is absent from Shiki's registry", async () => {
    const inputs = createSyntheticInputs();

    await expect(
      generateExportCdnSnapshot({
        ...inputs,
        supportedLanguages: ["invented"],
      }),
    ).rejects.toThrow("Shiki language registry has no entry for invented");
  });

  it("rejects non-literal dynamic imports in the reachable graph", async () => {
    const inputs = createSyntheticInputs({
      mermaidRootSource: 'const chunk = "./chunk.mjs"; import(chunk);\n',
    });

    await expect(generateExportCdnSnapshot(inputs)).rejects.toThrow(
      "non-literal dynamic import",
    );
  });

  it("rejects relative imports that escape their package", async () => {
    const inputs = createSyntheticInputs({
      mermaidRootSource: 'import "../../escape.mjs";\n',
    });

    await expect(generateExportCdnSnapshot(inputs)).rejects.toThrow(
      "relative import ../../escape.mjs",
    );
  });

  it("rejects reachable module symlinks that escape their package", async () => {
    const inputs = createSyntheticInputs({
      mermaidRootSource: 'import "./linked.mjs";\n',
      configure({ projectRoot, packageRoot, writeFile: write }) {
        const target = join(projectRoot, "outside.mjs");
        write(target, "export {};\n");
        symlinkSync(target, join(packageRoot("mermaid"), "dist", "linked.mjs"));
      },
    });

    await expect(generateExportCdnSnapshot(inputs)).rejects.toThrow(
      "escapes mermaid's package root through a symlink",
    );
  });

  it("rejects a specifier mapped to different nested package targets", async () => {
    const inputs = createSyntheticInputs({
      shikiRootSource: 'import "shared";\n',
      mermaidRootSource: 'import "shared";\n',
      configure({ addPackage }) {
        addPackage("shared", {
          manifest: { exports: { ".": "./dist/index.mjs" } },
          files: { "dist/index.mjs": "export {};\n" },
        });
        addPackage("shiki/node_modules/shared", {
          name: "shared",
          manifest: { exports: { ".": "./dist/index.mjs" } },
          files: { "dist/index.mjs": "export {};\n" },
        });
      },
    });

    await expect(generateExportCdnSnapshot(inputs)).rejects.toThrow(
      "conflicting URL mapping for specifier shared",
    );
  });

  it("rejects distinct package files that map to one raw CDN URL", async () => {
    const inputs = createSyntheticInputs({
      shikiRootSource: 'import "shared";\n',
      mermaidRootSource: 'import "shared/alias";\n',
      configure({ addPackage }) {
        const manifest = {
          exports: {
            ".": "./dist/index.mjs",
            "./alias": "./dist/index.mjs",
          },
        };
        addPackage("shiki/node_modules/shared", {
          name: "shared",
          manifest,
          files: { "dist/index.mjs": 'export const source = "shiki";\n' },
        });
        addPackage("mermaid/node_modules/shared", {
          name: "shared",
          manifest,
          files: { "dist/index.mjs": 'export const source = "mermaid";\n' },
        });
      },
    });

    const diagnostic =
      "conflicting URL mapping for https://cdn.jsdelivr.net/npm/shared@1.0.0/dist/index.mjs";
    await expect(generateExportCdnSnapshot(inputs)).rejects.toThrow(diagnostic);
    const fixtureRoot = temporaryDirectory();
    await expect(writeExportCdnFixtures({ fixtureRoot, ...inputs })).rejects.toThrow(
      diagnostic,
    );
    expect(readdirSync(fixtureRoot)).toEqual([]);
  });

  it("rejects a symlinked files directory before writing fixture bytes", async () => {
    const inputs = createSyntheticInputs();
    const parent = temporaryDirectory();
    const fixtureRoot = join(parent, "fixture");
    const externalDirectory = join(parent, "external-files");
    const sentinel = join(externalDirectory, "sentinel");
    mkdirSync(fixtureRoot);
    mkdirSync(externalDirectory);
    writeFile(sentinel, "unchanged\n");
    symlinkSync(externalDirectory, join(fixtureRoot, "files"));

    await expect(writeExportCdnFixtures({ fixtureRoot, ...inputs })).rejects.toThrow(
      "fixture root is not empty",
    );
    expect(readdirSync(externalDirectory)).toEqual(["sentinel"]);
    expect(readFileSync(sentinel, "utf8")).toBe("unchanged\n");
  });

  it("rejects a symlinked manifest before writing fixture contents", async () => {
    const inputs = createSyntheticInputs();
    const parent = temporaryDirectory();
    const fixtureRoot = join(parent, "fixture");
    const externalManifest = join(parent, "external-manifest.json");
    const contents = "unchanged\n";
    mkdirSync(fixtureRoot);
    writeFile(externalManifest, contents);
    symlinkSync(externalManifest, join(fixtureRoot, "manifest.json"));

    await expect(writeExportCdnFixtures({ fixtureRoot, ...inputs })).rejects.toThrow(
      "fixture root is not empty",
    );
    expect(readFileSync(externalManifest, "utf8")).toBe(contents);
  });

  it("rejects fixture manifests missing a generated URL", async () => {
    const { inputs, fixtureRoot, manifest } = await writtenSyntheticFixture();
    delete manifest.urls[Object.keys(manifest.urls)[0]];
    writeFixtureManifest(fixtureRoot, manifest);

    await expect(validateExportCdnFixtures(fixtureRoot, inputs)).rejects.toThrow(
      "fixture URL records differ from generated output: missing",
    );
  });

  it("rejects fixture manifests whose referenced file is missing", async () => {
    const { inputs, fixtureRoot, manifest } = await writtenSyntheticFixture();
    const record = manifest.urls[Object.keys(manifest.urls)[0]];
    rmSync(join(fixtureRoot, record.file));

    await expect(validateExportCdnFixtures(fixtureRoot, inputs)).rejects.toThrow(
      "cannot resolve fixture file",
    );
  });

  it("rejects fixture records whose file path escapes the fixture root", async () => {
    const { inputs, fixtureRoot, manifest } = await writtenSyntheticFixture();
    const wasmUrl = packageUrl(
      rawScopes[0],
      "web-tree-sitter",
      "1.0.0",
      "web-tree-sitter.wasm",
    );
    manifest.urls[wasmUrl].file = "../outside.wasm";
    writeFixtureManifest(fixtureRoot, manifest);

    await expect(validateExportCdnFixtures(fixtureRoot, inputs)).rejects.toThrow(
      "fixture file path is unsafe: ../outside.wasm",
    );
  });

  it("rejects fixture manifests whose integrity does not match their bytes", async () => {
    const { inputs, fixtureRoot, manifest } = await writtenSyntheticFixture();
    manifest.urls[Object.keys(manifest.urls)[0]].integrity =
      "sha384-not-the-file";
    writeFixtureManifest(fixtureRoot, manifest);

    await expect(validateExportCdnFixtures(fixtureRoot, inputs)).rejects.toThrow(
      "does not match its integrity record",
    );
  });

  it("rejects fixture files that the manifest does not enumerate", async () => {
    const { inputs, fixtureRoot } = await writtenSyntheticFixture();
    writeFile(join(fixtureRoot, "files", "unlisted.mjs"), "export {};\n");

    await expect(validateExportCdnFixtures(fixtureRoot, inputs)).rejects.toThrow(
      "fixture output files differ from its manifest",
    );
  });

  it("rejects orphan fixture URLs even when their records are internally valid", async () => {
    const { inputs, fixtureRoot, manifest } = await writtenSyntheticFixture();
    const firstUrl = Object.keys(manifest.urls)[0];
    manifest.urls = sortedObject([
      ...Object.entries(manifest.urls),
      ["https://zz.example.invalid/orphan.mjs", { ...manifest.urls[firstUrl] }],
    ]);
    writeFixtureManifest(fixtureRoot, manifest);

    await expect(validateExportCdnFixtures(fixtureRoot, inputs)).rejects.toThrow(
      "orphaned https://zz.example.invalid/orphan.mjs",
    );
  });
});
