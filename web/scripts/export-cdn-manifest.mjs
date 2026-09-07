import { createHash } from "node:crypto";
import {
  copyFileSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  writeFileSync,
} from "node:fs";
import { fileURLToPath } from "node:url";
import { isAbsolute, relative, resolve } from "node:path";

const defaultProjectRoot = fileURLToPath(new URL("..", import.meta.url));

const hosts = [
  {
    prefix: "https://cdn.jsdelivr.net/npm",
  },
  {
    prefix: "https://unpkg.com",
  },
  {
    prefix: "https://esm.sh",
  },
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

function fail(message) {
  throw new Error(`export CDN manifest: ${message}`);
}

function sha384(bytes) {
  return createHash("sha384").update(bytes).digest("base64");
}

function sri(bytes) {
  return `sha384-${sha384(bytes)}`;
}

function pathsFor(options = {}) {
  const projectRoot = resolve(options.projectRoot ?? defaultProjectRoot);
  return {
    projectRoot,
    lockfilePath: resolve(
      options.lockfilePath ?? resolve(projectRoot, "package-lock.json"),
    ),
    nodeModulesPath: resolve(
      options.nodeModulesPath ?? resolve(projectRoot, "node_modules"),
    ),
  };
}

function readJson(path, description) {
  let text;
  try {
    text = readFileSync(path, "utf8");
  } catch (error) {
    fail(`cannot read ${description} at ${path}: ${error.message}`);
  }

  try {
    return JSON.parse(text);
  } catch (error) {
    fail(`cannot parse ${description} at ${path}: ${error.message}`);
  }
}

function collectArtifacts(options = {}) {
  const { lockfilePath, nodeModulesPath } = pathsFor(options);
  const lockfile = readJson(lockfilePath, "package-lock.json");
  const rootPackage = lockfile.packages?.[""];
  if (!rootPackage) fail(`package-lock.json has no root package entry`);

  return artifacts.map((artifact) => {
    const requestedVersion = rootPackage.dependencies?.[artifact.packageName];
    if (!requestedVersion) {
      fail(
        `package-lock.json does not select ${artifact.packageName} as a production dependency`,
      );
    }

    const lockPackage =
      lockfile.packages?.[`node_modules/${artifact.packageName}`];
    if (!lockPackage?.version) {
      fail(
        `package-lock.json has no installed entry for ${artifact.packageName}`,
      );
    }
    if (requestedVersion !== lockPackage.version) {
      fail(
        `${artifact.packageName} root version ${requestedVersion} does not equal locked version ${lockPackage.version}`,
      );
    }

    const packageRoot = resolve(nodeModulesPath, artifact.packageName);
    const packageJsonPath = resolve(packageRoot, "package.json");
    const installedPackage = readJson(
      packageJsonPath,
      `${artifact.packageName} package.json`,
    );
    if (installedPackage.version !== lockPackage.version) {
      fail(
        `${artifact.packageName} installed version ${installedPackage.version} does not equal locked version ${lockPackage.version}`,
      );
    }

    const filePath = resolve(packageRoot, artifact.fileName);
    let bytes;
    try {
      bytes = readFileSync(filePath);
    } catch (error) {
      fail(
        `cannot read ${artifact.packageName} WASM at ${filePath}: ${error.message}`,
      );
    }

    const integrity = sri(bytes);
    const urls = hosts.map(
      ({ prefix }) =>
        `${prefix}/${artifact.packageName}@${lockPackage.version}/${artifact.fileName}`,
    );
    const candidates = urls.map((url) => ({ url, integrity }));

    return {
      ...artifact,
      version: lockPackage.version,
      filePath,
      bytes,
      integrity,
      candidates,
    };
  });
}

function runtimeManifest(collected) {
  return Object.fromEntries(
    collected.map((artifact) => [artifact.exportName, artifact.candidates]),
  );
}

function fixtureManifest(collected) {
  const urls = Object.fromEntries(
    collected
      .flatMap((artifact) =>
        artifact.candidates.map(({ url, integrity }) => [
          url,
          {
            file: artifact.fixtureFile,
            integrity,
            contentType: "application/wasm",
          },
        ]),
      )
      .sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0)),
  );
  return { urls };
}

export function generateRuntimeManifest(options = {}) {
  return runtimeManifest(collectArtifacts(options));
}

export function generateFixtureManifest(options = {}) {
  return fixtureManifest(collectArtifacts(options));
}

export function writeExportCdnFixtures({ fixtureRoot, ...options }) {
  if (!fixtureRoot) fail("fixture root is required");
  const collected = collectArtifacts(options);
  const outputRoot = resolve(fixtureRoot);
  mkdirSync(outputRoot, { recursive: true });

  for (const artifact of collected) {
    const outputPath = resolve(outputRoot, artifact.fixtureFile);
    mkdirSync(resolve(outputPath, ".."), { recursive: true });
    copyFileSync(artifact.filePath, outputPath);
  }

  writeFileSync(
    resolve(outputRoot, "manifest.json"),
    `${JSON.stringify(fixtureManifest(collected), null, 2)}\n`,
  );
}

function fixtureFiles(root) {
  const files = [];
  const visit = (directory, prefix) => {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const entryPath = resolve(directory, entry.name);
      const entryPrefix = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.isDirectory()) visit(entryPath, entryPrefix);
      else if (entry.isFile()) files.push(entryPrefix);
      else fail(`fixture contains unsupported filesystem entry ${entryPrefix}`);
    }
  };
  visit(root, "");
  return files.sort();
}

export function validateExportCdnFixtures(fixtureRoot) {
  if (!fixtureRoot) fail("fixture root is required");
  const root = resolve(fixtureRoot);
  const manifest = readJson(resolve(root, "manifest.json"), "fixture manifest");
  const urls = manifest.urls;
  if (!urls || typeof urls !== "object" || Array.isArray(urls)) {
    fail("fixture manifest has no URL object");
  }
  const records = Object.values(urls);
  if (records.length !== 6)
    fail(`fixture manifest has ${records.length} URL records, expected 6`);

  const files = new Set();
  for (const record of records) {
    if (!record || typeof record !== "object")
      fail("fixture URL record is not an object");
    const file = record.file;
    if (
      typeof file !== "string" ||
      !file.startsWith("files/") ||
      isAbsolute(file) ||
      file.split("/").includes("..")
    ) {
      fail(`fixture file path is unsafe: ${file}`);
    }
    if (record.contentType !== "application/wasm") {
      fail(`fixture file ${file} has an unexpected content type`);
    }
    const target = resolve(root, file);
    const escaped = relative(root, target).startsWith("..");
    if (escaped) fail(`fixture file path escapes the root: ${file}`);
    let bytes;
    try {
      bytes = readFileSync(target);
    } catch (error) {
      fail(`fixture file ${file} is missing: ${error.message}`);
    }
    if (record.integrity !== sri(bytes)) {
      fail(`fixture file ${file} does not match its integrity record`);
    }
    files.add(file);
  }

  if (files.size !== 2)
    fail(`fixture manifest enumerates ${files.size} files, expected 2`);
  const expectedArtifactFiles = artifacts
    .map(({ fixtureFile }) => fixtureFile)
    .sort();
  const actualArtifactFiles = [...files].sort();
  if (
    JSON.stringify(actualArtifactFiles) !==
    JSON.stringify(expectedArtifactFiles)
  ) {
    fail(
      `fixture manifest enumerates unexpected files: ${actualArtifactFiles.join(", ")}`,
    );
  }
  const expectedFiles = ["manifest.json", ...expectedArtifactFiles].sort();
  const actualFiles = fixtureFiles(root);
  if (JSON.stringify(actualFiles) !== JSON.stringify(expectedFiles)) {
    fail(
      `fixture output files differ from its manifest: expected ${expectedFiles.join(", ")}; got ${actualFiles.join(", ")}`,
    );
  }
}

function argumentValue(args, name) {
  const index = args.indexOf(name);
  return index === -1 ? undefined : args[index + 1];
}

function main() {
  const args = process.argv.slice(2);
  const fixtureRoot = argumentValue(args, "--fixture-root");
  const validateRoot = argumentValue(args, "--validate-fixture");
  if (fixtureRoot && validateRoot) fail("choose one fixture operation");
  if (fixtureRoot) {
    writeExportCdnFixtures({ fixtureRoot });
    return;
  }
  if (validateRoot) {
    validateExportCdnFixtures(validateRoot);
    return;
  }
  process.stdout.write(
    `${JSON.stringify(generateRuntimeManifest(), null, 2)}\n`,
  );
}

if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  main();
}
