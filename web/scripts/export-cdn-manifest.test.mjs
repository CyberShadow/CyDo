import { createHash } from "node:crypto";
import {
  copyFileSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import {
  generateFixtureManifest,
  generateRuntimeManifest,
  validateExportCdnFixtures,
  writeExportCdnFixtures,
} from "./export-cdn-manifest.mjs";

const webRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
const lockfilePath = join(webRoot, "package-lock.json");
const nodeModulesPath = join(webRoot, "node_modules");
const hosts = [
  "https://cdn.jsdelivr.net/npm",
  "https://unpkg.com",
  "https://esm.sh",
];
const artifacts = [
  {
    exportName: "treeSitterRuntime",
    packageName: "web-tree-sitter",
    fileName: "web-tree-sitter.wasm",
    fixtureFile: "files/web-tree-sitter/web-tree-sitter.wasm",
  },
  {
    exportName: "treeSitterBash",
    packageName: "tree-sitter-bash",
    fileName: "tree-sitter-bash.wasm",
    fixtureFile: "files/tree-sitter-bash/tree-sitter-bash.wasm",
  },
];

const temporaryRoots = [];

afterEach(() => {
  for (const root of temporaryRoots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

function readLockfile() {
  return JSON.parse(readFileSync(lockfilePath, "utf8"));
}

function installedArtifact(artifact) {
  const lockfile = readLockfile();
  const version = lockfile.packages[""].dependencies[artifact.packageName];
  const lockedVersion =
    lockfile.packages[`node_modules/${artifact.packageName}`].version;
  const packageRoot = join(nodeModulesPath, artifact.packageName);
  const bytes = readFileSync(join(packageRoot, artifact.fileName));
  const integrity = `sha384-${createHash("sha384")
    .update(bytes)
    .digest("base64")}`;

  expect(version).toBe(lockedVersion);
  expect(
    JSON.parse(readFileSync(join(packageRoot, "package.json"))).version,
  ).toBe(lockedVersion);

  return {
    ...artifact,
    version: lockedVersion,
    bytes,
    integrity,
  };
}

function cdnUrl(artifact, host) {
  return `${host}/${artifact.packageName}@${artifact.version}/${artifact.fileName}`;
}

function temporaryDirectory() {
  const root = mkdtempSync(join(tmpdir(), "cydo-export-cdn-manifest-"));
  temporaryRoots.push(root);
  return root;
}

function copiedInputs() {
  const root = temporaryDirectory();
  const copiedNodeModulesPath = join(root, "node_modules");
  copyFileSync(lockfilePath, join(root, "package-lock.json"));

  for (const artifact of artifacts) {
    const sourcePackageRoot = join(nodeModulesPath, artifact.packageName);
    const copiedPackageRoot = join(copiedNodeModulesPath, artifact.packageName);
    mkdirSync(copiedPackageRoot, { recursive: true });
    copyFileSync(
      join(sourcePackageRoot, "package.json"),
      join(copiedPackageRoot, "package.json"),
    );
    copyFileSync(
      join(sourcePackageRoot, artifact.fileName),
      join(copiedPackageRoot, artifact.fileName),
    );
  }

  return {
    projectRoot: root,
    lockfilePath: join(root, "package-lock.json"),
    nodeModulesPath: copiedNodeModulesPath,
  };
}

describe("export CDN manifest", () => {
  it("matches the lockfile and installed WASM bytes in both manifests", () => {
    const installed = artifacts.map(installedArtifact);
    const runtime = generateRuntimeManifest({ projectRoot: webRoot });
    const fixture = generateFixtureManifest({ projectRoot: webRoot });

    expect(Object.keys(runtime)).toEqual(
      artifacts.map(({ exportName }) => exportName),
    );
    for (const artifact of installed) {
      const candidates = runtime[artifact.exportName];
      expect(candidates.map(({ url }) => url)).toEqual(
        hosts.map((host) => cdnUrl(artifact, host)),
      );
      expect(candidates.map(({ integrity }) => integrity)).toEqual(
        Array(3).fill(artifact.integrity),
      );
      for (const candidate of candidates) {
        expect(Object.keys(candidate)).toEqual(["url", "integrity"]);
      }
    }

    const expectedFixtureUrls = [hosts[0], hosts[2], hosts[1]].flatMap((host) =>
      [installed[1], installed[0]].map((artifact) => cdnUrl(artifact, host)),
    );
    expect(Object.keys(fixture.urls)).toEqual(expectedFixtureUrls);
    expect(Object.keys(fixture.urls)).toHaveLength(6);
    for (const artifact of installed) {
      const records = hosts.map((host) => fixture.urls[cdnUrl(artifact, host)]);
      expect(records.map(({ file }) => file)).toEqual(
        Array(3).fill(artifact.fixtureFile),
      );
      expect(records.map(({ integrity }) => integrity)).toEqual(
        Array(3).fill(artifact.integrity),
      );
      expect(records.map(({ contentType }) => contentType)).toEqual(
        Array(3).fill("application/wasm"),
      );
      for (const record of records) {
        expect(Object.keys(record).sort()).toEqual([
          "contentType",
          "file",
          "integrity",
        ]);
        expect(record.file.startsWith("files/")).toBe(true);
        expect(record.file.split("/")).not.toContain("..");
      }
    }

    const fixtureRoot = temporaryDirectory();
    writeExportCdnFixtures({ fixtureRoot, projectRoot: webRoot });
    expect(validateExportCdnFixtures(fixtureRoot)).toBeUndefined();
    expect(
      JSON.parse(readFileSync(join(fixtureRoot, "manifest.json"), "utf8")),
    ).toEqual(fixture);
    for (const artifact of installed) {
      expect(readFileSync(join(fixtureRoot, artifact.fixtureFile))).toEqual(
        artifact.bytes,
      );
    }
  }, 30_000);

  it("produces byte-identical output for repeated runs", () => {
    const firstRoot = temporaryDirectory();
    const secondRoot = temporaryDirectory();
    writeExportCdnFixtures({ fixtureRoot: firstRoot, projectRoot: webRoot });
    writeExportCdnFixtures({ fixtureRoot: secondRoot, projectRoot: webRoot });

    expect(readFileSync(join(firstRoot, "manifest.json"))).toEqual(
      readFileSync(join(secondRoot, "manifest.json")),
    );
    expect(
      JSON.stringify(generateRuntimeManifest({ projectRoot: webRoot })),
    ).toBe(JSON.stringify(generateRuntimeManifest({ projectRoot: webRoot })));
  });

  it("fails fast when an isolated installed package version drifts", () => {
    const inputs = copiedInputs();
    const packageJsonPath = join(
      inputs.nodeModulesPath,
      "web-tree-sitter",
      "package.json",
    );
    const packageJson = JSON.parse(readFileSync(packageJsonPath, "utf8"));
    packageJson.version = "0.0.0";
    writeFileSync(packageJsonPath, `${JSON.stringify(packageJson)}\n`);

    expect(() => generateRuntimeManifest(inputs)).toThrow(
      "web-tree-sitter installed version 0.0.0 does not equal locked version 0.27.0",
    );
  });

  it("fails fast when an isolated required WASM file is missing", () => {
    const inputs = copiedInputs();
    rmSync(
      join(inputs.nodeModulesPath, "web-tree-sitter", "web-tree-sitter.wasm"),
    );

    expect(() => generateFixtureManifest(inputs)).toThrow(
      "cannot read web-tree-sitter WASM",
    );
  });

  it("rejects fixture records with unsafe relative paths", () => {
    const fixtureRoot = temporaryDirectory();
    writeExportCdnFixtures({ fixtureRoot, projectRoot: webRoot });
    const manifestPath = join(fixtureRoot, "manifest.json");
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    const firstUrl = Object.keys(manifest.urls)[0];
    manifest.urls[firstUrl].file = "../outside.wasm";
    writeFileSync(manifestPath, `${JSON.stringify(manifest)}\n`);

    expect(() => validateExportCdnFixtures(fixtureRoot)).toThrow(
      "fixture file path is unsafe: ../outside.wasm",
    );
  });
});
