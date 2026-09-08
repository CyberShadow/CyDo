import { createHash } from "node:crypto";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  statSync,
  writeFileSync,
} from "node:fs";
import {
  dirname,
  extname,
  isAbsolute,
  relative,
  resolve,
  sep,
} from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { ImportType, initSync, parse } from "es-module-lexer";
import { legacy, resolve as resolveExports } from "resolve.exports";
import { supportedHighlightLanguages } from "../src/highlightLanguages.mjs";

const defaultProjectRoot = fileURLToPath(new URL("..", import.meta.url));

const rawHosts = [
  {
    name: "jsdelivr",
    scope: "https://cdn.jsdelivr.net/npm/",
  },
  {
    name: "unpkg",
    scope: "https://unpkg.com/",
  },
];

const wasmHosts = [
  ...rawHosts,
  {
    name: "esm",
    scope: "https://esm.sh/",
  },
];

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
];

const resolveExportOptions = {
  browser: true,
  conditions: ["browser", "import", "default"],
};

function fail(message) {
  throw new Error(`export CDN manifest: ${message}`);
}

function compare(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function hasExactKeys(value, expectedKeys) {
  if (!isRecord(value)) return false;
  return (
    JSON.stringify(Object.keys(value).sort(compare)) ===
    JSON.stringify([...expectedKeys].sort(compare))
  );
}

function sortedObject(entries) {
  return Object.fromEntries(
    [...entries].sort(([left], [right]) => compare(left, right)),
  );
}

function toPosix(path) {
  return path.split(sep).join("/");
}

function isOutside(root, target) {
  const path = relative(root, target);
  return path === ".." || path.startsWith(`..${sep}`) || isAbsolute(path);
}

function sha384(bytes) {
  return createHash("sha384").update(bytes).digest("base64");
}

function sri(bytes) {
  return `sha384-${sha384(bytes)}`;
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

function readBytes(path, description) {
  try {
    return readFileSync(path);
  } catch (error) {
    fail(`cannot read ${description} at ${path}: ${error.message}`);
  }
}

function realPath(path, description) {
  try {
    return realpathSync(path);
  } catch (error) {
    fail(`cannot resolve ${description} at ${path}: ${error.message}`);
  }
}

function pathsFor(options = {}) {
  const projectRoot = resolve(options.projectRoot ?? defaultProjectRoot);
  const lockfilePath = resolve(projectRoot, "package-lock.json");
  const nodeModulesPath = resolve(projectRoot, "node_modules");
  const sourceLanguages =
    options.supportedLanguages ?? supportedHighlightLanguages;
  if (
    !sourceLanguages ||
    typeof sourceLanguages[Symbol.iterator] !== "function"
  ) {
    fail("supported languages must be an iterable collection");
  }
  const languages = [...new Set(sourceLanguages)];
  if (
    languages.some(
      (language) => typeof language !== "string" || language === "",
    )
  ) {
    fail("supported languages must contain only non-empty strings");
  }
  languages.sort(compare);

  return { projectRoot, lockfilePath, nodeModulesPath, languages };
}

function packageUrl(host, packageName, version, relativePath) {
  return `${host.scope}${packageName}@${version}/${relativePath}`;
}

function candidate(urlEntry) {
  return {
    url: urlEntry.url,
    integrity: urlEntry.integrity,
  };
}

function hostsFor(asset) {
  return asset.contentType === "application/wasm" ? wasmHosts : rawHosts;
}

function fixturePathFor(asset) {
  const packageParts = asset.package.name.split("/");
  const scoped = asset.package.name.startsWith("@");
  if (
    (scoped && packageParts.length !== 2) ||
    (!scoped && packageParts.length !== 1)
  ) {
    fail(`cannot create a safe fixture path for ${asset.package.name}`);
  }
  const finalPackagePart = packageParts.at(-1);
  const fixturePackageParts = [
    ...packageParts.slice(0, -1),
    asset.contentType === "application/wasm"
      ? finalPackagePart
      : `${finalPackagePart}@${asset.package.version}`,
  ];
  const pathParts = [...fixturePackageParts, ...asset.relativePath.split("/")];
  if (pathParts.some((part) => !/^[A-Za-z0-9._@+\-]+$/.test(part))) {
    fail(
      `cannot create a safe fixture path for ${asset.package.name}/${asset.relativePath}`,
    );
  }
  return `files/${pathParts.join("/")}`;
}

function packageSpecifier(specifier) {
  if (specifier.startsWith("@")) {
    const slash = specifier.indexOf("/");
    const secondSlash = specifier.indexOf("/", slash + 1);
    if (slash === -1 || secondSlash === -1) {
      return { packageName: specifier, subpath: "" };
    }
    return {
      packageName: specifier.slice(0, secondSlash),
      subpath: specifier.slice(secondSlash),
    };
  }

  const slash = specifier.indexOf("/");
  return slash === -1
    ? { packageName: specifier, subpath: "" }
    : {
        packageName: specifier.slice(0, slash),
        subpath: specifier.slice(slash),
      };
}

function isRelativeSpecifier(specifier) {
  return specifier.startsWith("./") || specifier.startsWith("../");
}

function isUrlSpecifier(specifier) {
  return /^[A-Za-z][A-Za-z0-9+.-]*:/.test(specifier);
}

class SnapshotBuilder {
  constructor(paths) {
    this.paths = paths;
    this.lockfile = readJson(paths.lockfilePath, "package-lock.json");
    this.rootPackage = this.lockfile.packages?.[""];
    if (!this.rootPackage) fail("package-lock.json has no root package entry");
    if (!this.lockfile.packages || typeof this.lockfile.packages !== "object") {
      fail("package-lock.json has no installed package entries");
    }

    this.nodeModulesRealPath = realPath(paths.nodeModulesPath, "node_modules");
    let nodeModulesStats;
    try {
      nodeModulesStats = statSync(this.nodeModulesRealPath);
    } catch (error) {
      fail(
        `cannot inspect node_modules at ${this.nodeModulesRealPath}: ${error.message}`,
      );
    }
    if (!nodeModulesStats.isDirectory()) {
      fail(`node_modules at ${this.nodeModulesRealPath} is not a directory`);
    }
    this.packages = new Map();
    this.assets = new Map();
    this.fixturePaths = new Map();
    this.specifierMappings = new Map();
    this.urlEntries = new Map();
  }

  requireRootDependency(packageName) {
    if (!this.rootPackage.dependencies?.[packageName]) {
      fail(
        `package-lock.json root does not declare ${packageName} as a dependency`,
      );
    }
  }

  packageAt(packageName, packageRoot) {
    const root = resolve(packageRoot);
    if (isOutside(this.paths.nodeModulesPath, root)) {
      fail(`package root for ${packageName} escapes node_modules: ${root}`);
    }

    const cached = this.packages.get(root);
    if (cached) {
      if (cached.name !== packageName) {
        fail(
          `ambiguous package ownership at ${root}: ${cached.name} and ${packageName}`,
        );
      }
      return cached;
    }

    const realRoot = realPath(root, `${packageName} package root`);
    if (isOutside(this.nodeModulesRealPath, realRoot)) {
      fail(
        `package root for ${packageName} escapes node_modules through a symlink: ${root}`,
      );
    }

    const lockRelativePath = toPosix(
      relative(this.paths.nodeModulesPath, root),
    );
    if (!lockRelativePath || lockRelativePath.split("/").includes("..")) {
      fail(`cannot determine lockfile ownership for ${packageName} at ${root}`);
    }
    const lockEntry =
      this.lockfile.packages[`node_modules/${lockRelativePath}`];
    if (!lockEntry?.version) {
      fail(
        `package-lock.json has no installed entry for ${packageName} at ${lockRelativePath}`,
      );
    }

    const packageJsonPath = resolve(root, "package.json");
    if (isOutside(root, packageJsonPath)) {
      fail(`package.json path for ${packageName} escapes its package root`);
    }
    const packageJsonRealPath = realPath(
      packageJsonPath,
      `${packageName} package.json`,
    );
    if (isOutside(realRoot, packageJsonRealPath)) {
      fail(
        `package.json for ${packageName} escapes its package root through a symlink`,
      );
    }
    const manifest = readJson(packageJsonPath, `${packageName} package.json`);
    if (manifest.name !== packageName) {
      fail(
        `package at ${root} declares ${manifest.name}, expected ${packageName}`,
      );
    }
    if (manifest.version !== lockEntry.version) {
      fail(
        `${packageName} installed version ${manifest.version} does not equal locked version ${lockEntry.version}`,
      );
    }

    const packageInfo = {
      name: packageName,
      root,
      realRoot,
      lockRelativePath,
      version: lockEntry.version,
      manifest,
    };
    this.packages.set(root, packageInfo);
    return packageInfo;
  }

  findPackage(packageName, fromPath = this.paths.projectRoot) {
    let directory = resolve(fromPath);
    try {
      if (statSync(directory).isFile()) directory = dirname(directory);
    } catch {
      directory = dirname(directory);
    }

    while (!isOutside(this.paths.projectRoot, directory)) {
      const packageRoot = resolve(directory, "node_modules", packageName);
      if (
        !isOutside(this.paths.nodeModulesPath, packageRoot) &&
        existsSync(packageRoot)
      ) {
        return this.packageAt(packageName, packageRoot);
      }
      const parent = dirname(directory);
      if (parent === directory) break;
      directory = parent;
    }

    const packageRoot = resolve(this.paths.nodeModulesPath, packageName);
    if (existsSync(packageRoot))
      return this.packageAt(packageName, packageRoot);
    fail(`cannot resolve installed package ${packageName} from ${fromPath}`);
  }

  assetForFile(packageInfo, filePath, contentType, description) {
    const resolvedPath = resolve(filePath);
    if (isOutside(packageInfo.root, resolvedPath)) {
      fail(
        `${description} escapes ${packageInfo.name}'s package root: ${resolvedPath}`,
      );
    }

    let entry;
    try {
      entry = lstatSync(resolvedPath);
    } catch (error) {
      fail(`missing ${description} at ${resolvedPath}: ${error.message}`);
    }
    if (!entry.isFile() && !entry.isSymbolicLink()) {
      fail(`${description} at ${resolvedPath} is not a file`);
    }

    const realFilePath = realPath(resolvedPath, description);
    if (isOutside(packageInfo.realRoot, realFilePath)) {
      fail(
        `${description} escapes ${packageInfo.name}'s package root through a symlink: ${resolvedPath}`,
      );
    }
    let stats;
    try {
      stats = statSync(realFilePath);
    } catch (error) {
      fail(
        `cannot inspect ${description} at ${resolvedPath}: ${error.message}`,
      );
    }
    if (!stats.isFile())
      fail(`${description} at ${resolvedPath} is not a regular file`);

    const relativePath = toPosix(relative(packageInfo.root, resolvedPath));
    if (
      !relativePath ||
      isAbsolute(relativePath) ||
      relativePath.split("/").some((part) => part === ".." || part === "")
    ) {
      fail(`cannot determine a safe package-relative path for ${description}`);
    }

    const existing = this.assets.get(realFilePath);
    if (existing) {
      if (
        existing.package.root !== packageInfo.root ||
        existing.relativePath !== relativePath ||
        existing.contentType !== contentType
      ) {
        fail(`ambiguous package ownership for ${resolvedPath}`);
      }
      return existing;
    }

    const asset = {
      package: packageInfo,
      filePath: resolvedPath,
      realFilePath,
      relativePath,
      contentType,
      bytes: readBytes(resolvedPath, description),
    };
    asset.integrity = sri(asset.bytes);
    asset.fixtureFile = fixturePathFor(asset);
    this.assets.set(realFilePath, asset);
    return asset;
  }

  registerFixturePath(asset) {
    const existing = this.fixturePaths.get(asset.fixtureFile);
    if (
      existing &&
      (existing.realFilePath !== asset.realFilePath ||
        existing.integrity !== asset.integrity ||
        existing.contentType !== asset.contentType)
    ) {
      fail(`conflicting fixture path mapping for ${asset.fixtureFile}`);
    }
    this.fixturePaths.set(asset.fixtureFile, asset);
  }

  registerAssetUrl(asset, host) {
    const url = packageUrl(
      host,
      asset.package.name,
      asset.package.version,
      asset.relativePath,
    );
    let parsed;
    try {
      parsed = new URL(url);
    } catch {
      fail(`generated URL is not absolute HTTPS: ${url}`);
    }
    if (parsed.protocol !== "https:" || parsed.hostname.length === 0) {
      fail(`generated URL is not absolute HTTPS: ${url}`);
    }

    const entry = {
      url,
      asset,
      realFilePath: asset.realFilePath,
      integrity: asset.integrity,
      fixtureFile: asset.fixtureFile,
      contentType: asset.contentType,
    };
    const existing = this.urlEntries.get(url);
    if (existing) {
      if (
        existing.realFilePath !== entry.realFilePath ||
        existing.integrity !== entry.integrity ||
        existing.fixtureFile !== entry.fixtureFile ||
        existing.contentType !== entry.contentType
      ) {
        fail(`conflicting URL mapping for ${url}`);
      }
      return existing;
    }

    this.urlEntries.set(url, entry);
    return entry;
  }

  registerAssetUrls(assets) {
    for (const asset of assets) {
      for (const host of hostsFor(asset)) {
        this.registerAssetUrl(asset, host);
      }
    }
  }

  urlForAsset(asset, host) {
    const url = packageUrl(
      host,
      asset.package.name,
      asset.package.version,
      asset.relativePath,
    );
    const entry = this.urlEntries.get(url);
    if (!entry) fail(`missing URL mapping for ${url}`);
    if (
      entry.realFilePath !== asset.realFilePath ||
      entry.integrity !== asset.integrity ||
      entry.fixtureFile !== asset.fixtureFile ||
      entry.contentType !== asset.contentType
    ) {
      fail(`conflicting URL mapping for ${url}`);
    }
    return entry;
  }

  moduleForPackagePath(packageInfo, packageRelativePath, description) {
    if (
      typeof packageRelativePath !== "string" ||
      !packageRelativePath.startsWith("./") ||
      packageRelativePath.includes("\\")
    ) {
      fail(
        `invalid package export path ${packageRelativePath} for ${description}`,
      );
    }
    const filePath = resolve(packageInfo.root, packageRelativePath);
    const extension = extname(filePath);
    if (extension !== ".js" && extension !== ".mjs") {
      fail(
        `reachable module ${packageInfo.name}/${packageRelativePath} is not JavaScript`,
      );
    }
    return this.assetForFile(
      packageInfo,
      filePath,
      "application/javascript",
      description,
    );
  }

  wasmForPackagePath(packageInfo, packageRelativePath, description) {
    if (!packageRelativePath.endsWith(".wasm")) {
      fail(`${description} does not name a WASM file: ${packageRelativePath}`);
    }
    return this.assetForFile(
      packageInfo,
      resolve(packageInfo.root, packageRelativePath),
      "application/wasm",
      description,
    );
  }

  addSpecifierMapping(specifier, target) {
    const targetKey =
      target.kind === "asset"
        ? `asset:${target.asset.realFilePath}`
        : `prefix:${target.package.root}/${target.relativePath}`;
    const existing = this.specifierMappings.get(specifier);
    if (existing) {
      if (existing.targetKey !== targetKey) {
        fail(`conflicting URL mapping for specifier ${specifier}`);
      }
      return;
    }
    this.specifierMappings.set(specifier, { ...target, targetKey });
  }

  addPackagePrefix(specifier, packageInfo, packageRelativePath) {
    if (!specifier.endsWith("/") || !packageRelativePath.endsWith("/")) {
      fail(`package prefix mapping must end in a slash: ${specifier}`);
    }
    const target = resolve(packageInfo.root, packageRelativePath);
    if (isOutside(packageInfo.root, target)) {
      fail(`package prefix ${specifier} escapes ${packageInfo.name}`);
    }
    const realTarget = realPath(target, `package prefix ${specifier}`);
    if (isOutside(packageInfo.realRoot, realTarget)) {
      fail(
        `package prefix ${specifier} escapes ${packageInfo.name} through a symlink`,
      );
    }
    if (!statSync(realTarget).isDirectory()) {
      fail(`package prefix ${specifier} does not target a directory`);
    }
    this.addSpecifierMapping(specifier, {
      kind: "prefix",
      package: packageInfo,
      relativePath: packageRelativePath,
    });
  }

  resolvePackageTarget(packageInfo, specifier, description) {
    let candidates;
    if (packageInfo.manifest.exports) {
      try {
        candidates = resolveExports(
          packageInfo.manifest,
          specifier,
          resolveExportOptions,
        );
      } catch (error) {
        fail(
          `cannot resolve ${specifier} from ${description}: ${error.message}`,
        );
      }
      if (!candidates) {
        fail(`cannot resolve ${specifier} from ${description}`);
      }
    } else {
      const legacyTarget = legacy(packageInfo.manifest, {
        fields: ["browser", "module", "main"],
      });
      if (typeof legacyTarget !== "string") {
        fail(`cannot resolve ${specifier} from ${description}`);
      }
      candidates = [legacyTarget];
    }

    if (
      !Array.isArray(candidates) ||
      candidates.length !== 1 ||
      typeof candidates[0] !== "string"
    ) {
      fail(`ambiguous export resolution for ${specifier} from ${description}`);
    }
    return this.moduleForPackagePath(
      packageInfo,
      candidates[0],
      `module ${specifier}`,
    );
  }

  resolveBareSpecifier(specifier, importer) {
    const { packageName } = packageSpecifier(specifier);
    if (!packageName || packageName === ".") {
      fail(`invalid bare specifier ${specifier}`);
    }
    const packageInfo = this.findPackage(packageName, importer?.filePath);
    const asset = this.resolvePackageTarget(
      packageInfo,
      specifier,
      importer ? importer.filePath : "the graph seed",
    );
    this.addSpecifierMapping(specifier, { kind: "asset", asset });
    return asset;
  }

  resolvePackageImport(specifier, importer) {
    let candidates;
    try {
      candidates = resolveExports(
        importer.package.manifest,
        specifier,
        resolveExportOptions,
      );
    } catch (error) {
      fail(
        `cannot resolve ${specifier} from ${importer.filePath}: ${error.message}`,
      );
    }
    if (
      !Array.isArray(candidates) ||
      candidates.length !== 1 ||
      typeof candidates[0] !== "string"
    ) {
      fail(
        `ambiguous package import resolution for ${specifier} from ${importer.filePath}`,
      );
    }

    const target = candidates[0];
    const asset = target.startsWith("./")
      ? this.moduleForPackagePath(
          importer.package,
          target,
          `module ${specifier}`,
        )
      : this.resolveBareSpecifier(target, importer);
    this.addSpecifierMapping(specifier, { kind: "asset", asset });
    return asset;
  }

  resolveRelativeSpecifier(specifier, importer) {
    const filePath = resolve(dirname(importer.filePath), specifier);
    if (isOutside(importer.package.root, filePath)) {
      fail(
        `relative import ${specifier} from ${importer.filePath} escapes its package root`,
      );
    }
    const extension = extname(filePath);
    if (extension !== ".js" && extension !== ".mjs") {
      fail(
        `reachable module ${specifier} from ${importer.filePath} is not JavaScript`,
      );
    }
    return this.assetForFile(
      importer.package,
      filePath,
      "application/javascript",
      `module ${specifier} imported by ${importer.filePath}`,
    );
  }

  resolveSpecifier(specifier, importer) {
    if (isRelativeSpecifier(specifier)) {
      return this.resolveRelativeSpecifier(specifier, importer);
    }
    if (specifier.startsWith("/")) {
      fail(
        `root-relative import ${specifier} from ${importer.filePath} is not supported`,
      );
    }
    if (isUrlSpecifier(specifier)) {
      fail(
        `external URL import ${specifier} from ${importer.filePath} is not supported`,
      );
    }
    if (specifier.startsWith("#"))
      return this.resolvePackageImport(specifier, importer);
    return this.resolveBareSpecifier(specifier, importer);
  }

  shikiRegistryFile(shikiPackage, relativePath) {
    const filePath = resolve(shikiPackage.root, relativePath);
    if (isOutside(shikiPackage.root, filePath)) {
      fail(`Shiki registry ${relativePath} escapes its package root`);
    }
    const realFilePath = realPath(filePath, `Shiki registry ${relativePath}`);
    if (isOutside(shikiPackage.realRoot, realFilePath)) {
      fail(
        `Shiki registry ${relativePath} escapes its package root through a symlink`,
      );
    }
    let stats;
    try {
      stats = statSync(realFilePath);
    } catch (error) {
      fail(`cannot inspect Shiki registry ${relativePath}: ${error.message}`);
    }
    if (!stats.isFile()) {
      fail(`Shiki registry ${relativePath} is not a regular file`);
    }
    return realFilePath;
  }

  async loadShikiRegistries(shikiPackage) {
    const languageRegistryPath = this.shikiRegistryFile(
      shikiPackage,
      "dist/langs.mjs",
    );
    const themeRegistryPath = this.shikiRegistryFile(
      shikiPackage,
      "dist/themes.mjs",
    );
    const [languageRegistry, themeRegistry] = await Promise.all([
      import(pathToFileURL(languageRegistryPath).href),
      import(pathToFileURL(themeRegistryPath).href),
    ]);
    return {
      languageInfos: languageRegistry.bundledLanguagesInfo,
      themeInfos: themeRegistry.bundledThemesInfo,
    };
  }

  selectedRegistration(infos, value, kind) {
    const matches = infos.filter(
      (info) =>
        info &&
        typeof info.id === "string" &&
        (info.id === value || info.aliases?.includes(value)),
    );
    if (matches.length === 0) {
      fail(`Shiki ${kind} registry has no entry for ${value}`);
    }
    if (matches.length !== 1) {
      fail(`Shiki ${kind} registry has ambiguous entries for ${value}`);
    }
    return matches[0].id;
  }

  skipRegistryDynamicImport(
    asset,
    specifier,
    selectedLanguageSpecifiers,
    selectedThemeSpecifiers,
  ) {
    if (asset.package.name !== "shiki") return false;
    if (
      asset.relativePath === "dist/bundle-web.mjs" &&
      specifier.startsWith("@shikijs/langs/")
    ) {
      return !selectedLanguageSpecifiers.has(specifier);
    }
    if (
      asset.relativePath === "dist/themes.mjs" &&
      specifier.startsWith("@shikijs/themes/")
    ) {
      return !selectedThemeSpecifiers.has(specifier);
    }
    return false;
  }

  traverseGraph(seeds, selectedLanguageSpecifiers, selectedThemeSpecifiers) {
    const pending = [...seeds];
    const visited = new Set();

    while (pending.length > 0) {
      const asset = pending.pop();
      if (visited.has(asset.realFilePath)) continue;
      visited.add(asset.realFilePath);

      let imports;
      try {
        [imports] = parse(asset.bytes.toString("utf8"), asset.filePath);
      } catch (error) {
        fail(`cannot parse imports in ${asset.filePath}: ${error.message}`);
      }

      for (const entry of imports) {
        if (entry.t === ImportType.ImportMeta || entry.d === -2) continue;
        if (typeof entry.n !== "string") {
          fail(`non-literal dynamic import in ${asset.filePath}`);
        }
        if (
          entry.d !== -1 &&
          this.skipRegistryDynamicImport(
            asset,
            entry.n,
            selectedLanguageSpecifiers,
            selectedThemeSpecifiers,
          )
        ) {
          continue;
        }
        pending.push(this.resolveSpecifier(entry.n, asset));
      }
    }
  }

  async build() {
    initSync();

    const wasm = {};
    for (const artifact of wasmArtifacts) {
      this.requireRootDependency(artifact.packageName);
      const packageInfo = this.findPackage(artifact.packageName);
      const asset = this.wasmForPackagePath(
        packageInfo,
        `./${artifact.relativePath}`,
        `${artifact.packageName} WASM`,
      );
      wasm[artifact.exportName] = asset;
    }

    this.requireRootDependency("shiki");
    this.requireRootDependency("mermaid");
    const shikiPackage = this.findPackage("shiki");
    const mermaidPackage = this.findPackage("mermaid");
    const { languageInfos, themeInfos } =
      await this.loadShikiRegistries(shikiPackage);

    const shikiRoot = this.moduleForPackagePath(
      shikiPackage,
      "./dist/bundle-web.mjs",
      "Shiki root module",
    );
    const mermaidRoot = this.moduleForPackagePath(
      mermaidPackage,
      "./dist/mermaid.esm.min.mjs",
      "Mermaid root module",
    );

    const shikiLanguages = new Map();
    const selectedLanguageSpecifiers = new Set();
    for (const language of this.paths.languages) {
      const registration = this.selectedRegistration(
        languageInfos,
        language,
        "language",
      );
      const specifier = `@shikijs/langs/${registration}`;
      const asset = this.resolveBareSpecifier(specifier, shikiRoot);
      shikiLanguages.set(language, asset);
      selectedLanguageSpecifiers.add(specifier);
    }

    const selectedThemeSpecifiers = new Set();
    const themeAssets = [];
    for (const theme of ["github-light", "github-dark"]) {
      const registration = this.selectedRegistration(
        themeInfos,
        theme,
        "theme",
      );
      const specifier = `@shikijs/themes/${registration}`;
      themeAssets.push(this.resolveBareSpecifier(specifier, shikiRoot));
      selectedThemeSpecifiers.add(specifier);
    }

    const languagesPackage = this.findPackage(
      "@shikijs/langs",
      shikiRoot.filePath,
    );
    const themesPackage = this.findPackage(
      "@shikijs/themes",
      shikiRoot.filePath,
    );
    this.addPackagePrefix("@shikijs/langs/", languagesPackage, "dist/");
    this.addPackagePrefix("@shikijs/themes/", themesPackage, "dist/");

    this.traverseGraph(
      [shikiRoot, mermaidRoot, ...shikiLanguages.values(), ...themeAssets],
      selectedLanguageSpecifiers,
      selectedThemeSpecifiers,
    );

    const assets = [...this.assets.values()].sort((left, right) =>
      compare(
        `${left.package.name}/${left.relativePath}`,
        `${right.package.name}/${right.relativePath}`,
      ),
    );
    this.registerAssetUrls(assets);
    for (const asset of assets) {
      this.registerFixturePath(asset);
    }
    const urlEntries = [...this.urlEntries.values()].sort((left, right) =>
      compare(left.url, right.url),
    );
    const candidateFor = (asset, host) =>
      candidate(this.urlForAsset(asset, host));

    const runtimeManifest = {
      treeSitterRuntime: wasm.treeSitterRuntime
        ? wasmHosts.map((host) => candidateFor(wasm.treeSitterRuntime, host))
        : fail("missing tree-sitter runtime"),
      treeSitterBash: wasm.treeSitterBash
        ? wasmHosts.map((host) => candidateFor(wasm.treeSitterBash, host))
        : fail("missing tree-sitter Bash grammar"),
      shikiRoots: rawHosts.map((host) => candidateFor(shikiRoot, host)),
      mermaidRoots: rawHosts.map((host) => candidateFor(mermaidRoot, host)),
      shikiLanguages: sortedObject(
        [...shikiLanguages.entries()].map(([language, asset]) => [
          language,
          sortedObject(
            rawHosts.map((host) => [host.name, candidateFor(asset, host)]),
          ),
        ]),
      ),
    };

    const scopes = sortedObject(
      rawHosts.map((host) => [
        host.scope,
        sortedObject(
          [...this.specifierMappings.entries()].map(([specifier, mapping]) => [
            specifier,
            mapping.kind === "asset"
              ? this.urlForAsset(mapping.asset, host).url
              : packageUrl(
                  host,
                  mapping.package.name,
                  mapping.package.version,
                  mapping.relativePath,
                ),
          ]),
        ),
      ]),
    );
    const importMap = {
      imports: {},
      scopes,
      integrity: sortedObject(
        urlEntries
          .filter((entry) => entry.contentType === "application/javascript")
          .map((entry) => [entry.url, entry.integrity]),
      ),
    };

    const fixtureManifest = {
      urls: sortedObject(
        urlEntries.map((entry) => [
          entry.url,
          {
            file: entry.fixtureFile,
            integrity: entry.integrity,
            contentType: entry.contentType,
          },
        ]),
      ),
    };

    return { assets, urlEntries, runtimeManifest, importMap, fixtureManifest };
  }
}

async function createSnapshot(options = {}) {
  return await new SnapshotBuilder(pathsFor(options)).build();
}

function publicSnapshot(snapshot) {
  return {
    runtimeManifest: snapshot.runtimeManifest,
    importMap: snapshot.importMap,
    fixtureManifest: snapshot.fixtureManifest,
  };
}

export async function generateExportCdnSnapshot(options = {}) {
  return publicSnapshot(await createSnapshot(options));
}

function prepareFixtureRoot(fixtureRoot) {
  const outputRoot = resolve(fixtureRoot);
  let rootEntry;
  try {
    rootEntry = lstatSync(outputRoot);
  } catch (error) {
    if (error.code !== "ENOENT") {
      fail(`cannot inspect fixture root ${outputRoot}: ${error.message}`);
    }
    try {
      mkdirSync(outputRoot, { recursive: true });
      rootEntry = lstatSync(outputRoot);
    } catch (createError) {
      fail(`cannot create fixture root ${outputRoot}: ${createError.message}`);
    }
  }
  if (rootEntry.isSymbolicLink()) {
    fail(`fixture root is a symlink: ${outputRoot}`);
  }
  if (!rootEntry.isDirectory()) {
    fail(`fixture root is not a directory: ${outputRoot}`);
  }
  let entries;
  try {
    entries = readdirSync(outputRoot);
  } catch (error) {
    fail(`cannot read fixture root ${outputRoot}: ${error.message}`);
  }
  if (entries.length !== 0) {
    fail(`fixture root is not empty: ${outputRoot}`);
  }
  return { outputRoot, realOutputRoot: realPath(outputRoot, "fixture root") };
}

function outputPathForFixtureFile(outputRoot, realOutputRoot, fixtureFile) {
  const outputPath = resolve(outputRoot, fixtureFile);
  if (isOutside(outputRoot, outputPath)) {
    fail(`fixture output path escapes the root: ${fixtureFile}`);
  }
  const outputDirectory = dirname(outputPath);
  mkdirSync(outputDirectory, { recursive: true });
  const realOutputDirectory = realPath(
    outputDirectory,
    `fixture output directory for ${fixtureFile}`,
  );
  if (isOutside(realOutputRoot, realOutputDirectory)) {
    fail(
      `fixture output path escapes the root through a symlink: ${fixtureFile}`,
    );
  }
  return outputPath;
}

export async function writeExportCdnFixtures({
  fixtureRoot,
  projectRoot,
  supportedLanguages,
}) {
  if (!fixtureRoot) fail("fixture root is required");
  const snapshot = await createSnapshot({ projectRoot, supportedLanguages });
  const { outputRoot, realOutputRoot } = prepareFixtureRoot(fixtureRoot);

  const copiedFiles = new Map();
  for (const asset of snapshot.assets) {
    const existing = copiedFiles.get(asset.fixtureFile);
    if (existing && existing.realFilePath !== asset.realFilePath) {
      fail(`conflicting fixture file mapping for ${asset.fixtureFile}`);
    }
    if (existing) continue;
    const outputPath = outputPathForFixtureFile(
      outputRoot,
      realOutputRoot,
      asset.fixtureFile,
    );
    writeFileSync(outputPath, asset.bytes);
    copiedFiles.set(asset.fixtureFile, asset);
  }

  const manifestPath = resolve(outputRoot, "manifest.json");
  if (isOutside(outputRoot, manifestPath)) {
    fail("fixture manifest path escapes the root");
  }
  if (
    isOutside(realOutputRoot, realPath(dirname(manifestPath), "fixture root"))
  ) {
    fail("fixture manifest path escapes the root through a symlink");
  }
  writeFileSync(
    manifestPath,
    `${JSON.stringify(snapshot.fixtureManifest, null, 2)}\n`,
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
  return files.sort(compare);
}

function validateFixtureUrl(url) {
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    fail(`fixture URL is not absolute HTTPS: ${url}`);
  }
  if (parsed.protocol !== "https:" || parsed.hostname.length === 0) {
    fail(`fixture URL is not absolute HTTPS: ${url}`);
  }
}

function validateFixturePath(root, file) {
  if (
    typeof file !== "string" ||
    !file.startsWith("files/") ||
    isAbsolute(file) ||
    file.split(/[\\/]/).includes("..")
  ) {
    fail(`fixture file path is unsafe: ${file}`);
  }
  const target = resolve(root, file);
  if (isOutside(root, target))
    fail(`fixture file path escapes the root: ${file}`);
  return target;
}

export async function validateExportCdnFixtures(
  fixtureRoot,
  { projectRoot, supportedLanguages } = {},
) {
  if (!fixtureRoot) fail("fixture root is required");
  const root = resolve(fixtureRoot);
  const manifest = readJson(resolve(root, "manifest.json"), "fixture manifest");
  if (!manifest || typeof manifest !== "object" || Array.isArray(manifest)) {
    fail("fixture manifest is not an object");
  }
  const manifestKeys = Object.keys(manifest).sort(compare);
  if (JSON.stringify(manifestKeys) !== JSON.stringify(["urls"])) {
    fail(`fixture manifest has unexpected keys: ${manifestKeys.join(", ")}`);
  }
  const urls = manifest.urls;
  if (!urls || typeof urls !== "object" || Array.isArray(urls)) {
    fail("fixture manifest has no URL object");
  }

  const expected = (
    await createSnapshot({ projectRoot, supportedLanguages })
  ).fixtureManifest;
  const actualUrls = Object.keys(urls);
  const sortedUrls = [...actualUrls].sort(compare);
  if (JSON.stringify(actualUrls) !== JSON.stringify(sortedUrls)) {
    fail("fixture URL records are not sorted");
  }
  const expectedUrls = Object.keys(expected.urls);
  const enumeratedFiles = new Set();

  for (const url of actualUrls) {
    validateFixtureUrl(url);
    const record = urls[url];
    if (!record || typeof record !== "object" || Array.isArray(record)) {
      fail(`fixture URL record for ${url} is not an object`);
    }
    const recordKeys = Object.keys(record).sort(compare);
    const expectedRecordKeys = ["contentType", "file", "integrity"];
    if (JSON.stringify(recordKeys) !== JSON.stringify(expectedRecordKeys)) {
      fail(
        `fixture URL record for ${url} has unexpected keys: ${recordKeys.join(", ")}`,
      );
    }
    if (
      record.contentType !== "application/javascript" &&
      record.contentType !== "application/wasm"
    ) {
      fail(`fixture file ${record.file} has an unexpected content type`);
    }
    if (typeof record.integrity !== "string") {
      fail(`fixture URL record for ${url} has a non-string integrity`);
    }

    const target = validateFixturePath(root, record.file);
    const realRoot = realPath(root, "fixture root");
    const realTarget = realPath(target, `fixture file ${record.file}`);
    if (isOutside(realRoot, realTarget)) {
      fail(
        `fixture file path escapes the root through a symlink: ${record.file}`,
      );
    }
    let bytes;
    try {
      bytes = readFileSync(target);
    } catch (error) {
      fail(`fixture file ${record.file} is missing: ${error.message}`);
    }
    if (record.contentType === "application/wasm") {
      if (
        bytes[0] !== 0 ||
        bytes[1] !== 0x61 ||
        bytes[2] !== 0x73 ||
        bytes[3] !== 0x6d
      ) {
        fail(`fixture file ${record.file} does not have the WASM magic header`);
      }
    }
    if (record.integrity !== sri(bytes)) {
      fail(`fixture file ${record.file} does not match its integrity record`);
    }
    enumeratedFiles.add(record.file);
  }

  if (JSON.stringify(actualUrls) !== JSON.stringify(expectedUrls)) {
    const missing = expectedUrls.filter((url) => !Object.hasOwn(urls, url));
    const orphaned = actualUrls.filter(
      (url) => !Object.hasOwn(expected.urls, url),
    );
    fail(
      `fixture URL records differ from generated output: missing ${missing.join(", ") || "none"}; orphaned ${orphaned.join(", ") || "none"}`,
    );
  }
  for (const url of actualUrls) {
    const actual = urls[url];
    const expectedRecord = expected.urls[url];
    if (
      actual.file !== expectedRecord.file ||
      actual.integrity !== expectedRecord.integrity ||
      actual.contentType !== expectedRecord.contentType
    ) {
      fail(`fixture URL record for ${url} does not match generated output`);
    }
  }

  const expectedFiles = ["manifest.json", ...enumeratedFiles].sort(compare);
  const actualFiles = fixtureFiles(root);
  if (JSON.stringify(actualFiles) !== JSON.stringify(expectedFiles)) {
    fail(
      `fixture output files differ from its manifest: expected ${expectedFiles.join(", ")}; got ${actualFiles.join(", ")}`,
    );
  }
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length === 2 && args[0] === "--fixture-root") {
    const fixtureRoot = args[1];
    await writeExportCdnFixtures({ fixtureRoot });
    return;
  }
  if (args.length === 2 && args[0] === "--validate-fixture") {
    await validateExportCdnFixtures(args[1]);
    return;
  }
  fail("usage: export-cdn-manifest.mjs --fixture-root ROOT | --validate-fixture ROOT");
}

if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  void main();
}
