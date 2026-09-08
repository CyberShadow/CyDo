import { Buffer } from "node:buffer";
import { createHash } from "node:crypto";
import { readFileSync, readdirSync, realpathSync } from "node:fs";
import { isAbsolute, relative, resolve, sep, win32 } from "node:path";
import type { Page } from "@playwright/test";

const FIXTURE_ENV = "CYDO_EXPORT_CDN_FIXTURES";
const EXPECTED_MANIFEST_ENV = "CYDO_EXPORT_CDN_EXPECTED_MANIFEST";
const WASM_MAGIC = Buffer.from([0, 0x61, 0x73, 0x6d]);
const RECORD_KEYS = ["contentType", "file", "integrity"];

type FixtureContentType = "application/javascript" | "application/wasm";

type FixtureManifestRecord = {
  contentType: FixtureContentType;
  file: string;
  integrity: string;
};

type FixtureManifest = {
  urls: Record<string, FixtureManifestRecord>;
};

export type ExportCdnFixture = FixtureManifestRecord & {
  bytes: Buffer;
  url: string;
};

export type ExportCdnFixtures = {
  records: ExportCdnFixture[];
  byUrl: Map<string, ExportCdnFixture>;
};

export type ExportCdnRouteAction =
  | {
      action: "abort-jsdelivr";
      errorCode: "blockedbyclient";
      url: string;
    }
  | {
      action: "fulfill-unpkg";
      file: string;
      url: string;
    }
  | {
      action: "abort-unexpected";
      errorCode: "failed";
      url: string;
    };

export type ExportCdnRouteState = {
  actions: ExportCdnRouteAction[];
  attempts: string[];
  unexpectedHttps: string[];
};

function fail(message: string): never {
  throw new Error(`export CDN e2e fixture: ${message}`);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function requireExactKeys(
  value: Record<string, unknown>,
  keys: string[],
  description: string,
): void {
  const actualKeys = Object.keys(value).sort();
  const expectedKeys = [...keys].sort();
  if (JSON.stringify(actualKeys) !== JSON.stringify(expectedKeys)) {
    fail(
      `${description} must have exactly the keys ${expectedKeys.join(", ")}; got ${actualKeys.join(", ")}`,
    );
  }
}

function sha384(bytes: Buffer): string {
  return `sha384-${createHash("sha384").update(bytes).digest("base64")}`;
}

function isOutside(root: string, target: string): boolean {
  const path = relative(root, target);
  return path === ".." || path.startsWith(`..${sep}`) || isAbsolute(path);
}

function readManifest(manifestPath: string, description: string): unknown {
  let text: string;
  try {
    text = readFileSync(manifestPath, "utf8");
  } catch (error) {
    fail(`cannot read ${description} at ${manifestPath}: ${error}`);
  }

  try {
    return JSON.parse(text) as unknown;
  } catch (error) {
    fail(`cannot parse ${description} at ${manifestPath}: ${error}`);
  }
}

function validateUrl(url: string): void {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    fail(`fixture URL is not absolute HTTPS: ${url}`);
  }
  if (parsed.protocol !== "https:" || parsed.hostname.length === 0) {
    fail(`fixture URL is not absolute HTTPS: ${url}`);
  }
}

function readFixtureManifest(
  manifestPath: string,
  description: string,
): FixtureManifest {
  const manifest = readManifest(manifestPath, description);
  if (!isRecord(manifest)) fail(`${description} must be an object`);
  requireExactKeys(manifest, ["urls"], description);
  if (!isRecord(manifest.urls)) fail(`${description}.urls must be an object`);

  const entries = Object.entries(manifest.urls);
  if (entries.length === 0) fail(`${description}.urls must not be empty`);
  const sortedUrls = entries.map(([url]) => url).sort();
  if (
    JSON.stringify(entries.map(([url]) => url)) !== JSON.stringify(sortedUrls)
  ) {
    fail(`${description}.urls must be sorted by URL`);
  }

  const urls: Record<string, FixtureManifestRecord> = {};
  for (const [url, value] of entries) {
    validateUrl(url);
    if (!isRecord(value)) {
      fail(`fixture URL record for ${url} must be an object`);
    }
    requireExactKeys(value, RECORD_KEYS, `fixture URL record for ${url}`);

    const file = value.file;
    const integrity = value.integrity;
    const contentType = value.contentType;
    if (typeof file !== "string") {
      fail(`fixture URL record for ${url} has a non-string file`);
    }
    if (typeof integrity !== "string") {
      fail(`fixture URL record for ${url} has a non-string integrity`);
    }
    if (
      contentType !== "application/javascript" &&
      contentType !== "application/wasm"
    ) {
      fail(`fixture file ${file} has an unexpected content type`);
    }
    urls[url] = { file, integrity, contentType };
  }

  return { urls };
}

function requireExpectedFixtureManifest(
  actual: FixtureManifest,
  expected: FixtureManifest,
): void {
  const actualUrls = Object.keys(actual.urls);
  const expectedUrls = Object.keys(expected.urls);
  if (JSON.stringify(actualUrls) !== JSON.stringify(expectedUrls)) {
    const missing = expectedUrls.filter((url) => !(url in actual.urls));
    const orphaned = actualUrls.filter((url) => !(url in expected.urls));
    fail(
      `fixture URL records differ from expected manifest: missing ${missing.join(", ") || "none"}; orphaned ${orphaned.join(", ") || "none"}`,
    );
  }

  for (const url of actualUrls) {
    const actualRecord = actual.urls[url];
    const expectedRecord = expected.urls[url];
    if (
      !expectedRecord ||
      actualRecord.file !== expectedRecord.file ||
      actualRecord.integrity !== expectedRecord.integrity ||
      actualRecord.contentType !== expectedRecord.contentType
    ) {
      fail(`fixture URL record for ${url} differs from expected manifest`);
    }
  }
}

function validateFixturePath(fixtureRoot: string, file: string): string {
  if (
    !file.startsWith("files/") ||
    isAbsolute(file) ||
    win32.isAbsolute(file) ||
    file.split(/[\\/]/).includes("..")
  ) {
    fail(`fixture file path is unsafe: ${file}`);
  }

  const target = resolve(fixtureRoot, file);
  if (isOutside(fixtureRoot, target)) {
    fail(`fixture file path escapes the root: ${file}`);
  }

  return target;
}

function readFixtureBytes(
  fixtureRoot: string,
  file: string,
  integrity: string,
  contentType: FixtureContentType,
): Buffer {
  const target = validateFixturePath(fixtureRoot, file);
  const realRoot = realpathSync(fixtureRoot);
  const realTarget = realpathSync(target);
  if (isOutside(realRoot, realTarget)) {
    fail(`fixture file path escapes the root through a symlink: ${file}`);
  }

  let bytes: Buffer;
  try {
    bytes = readFileSync(target);
  } catch (error) {
    fail(`fixture file ${file} is missing: ${error}`);
  }

  if (
    contentType === "application/wasm" &&
    !bytes.subarray(0, WASM_MAGIC.length).equals(WASM_MAGIC)
  ) {
    fail(`fixture file ${file} does not have the WASM magic header`);
  }
  if (integrity !== sha384(bytes)) {
    fail(`fixture file ${file} does not match its integrity record`);
  }
  return bytes;
}

function fixtureFiles(root: string): string[] {
  const files: string[] = [];
  const visit = (directory: string, prefix: string): void => {
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

/**
 * Load the build-provided export CDN fixtures without deriving package names
 * or versions from their URLs. Manifest insertion order is retained in
 * `records`; `byUrl` uses each URL string exactly as written in the manifest.
 */
export function readExportCdnFixtures(): ExportCdnFixtures {
  const fixtureRootValue = process.env[FIXTURE_ENV];
  if (!fixtureRootValue) fail(`${FIXTURE_ENV} is required`);
  const expectedManifestValue = process.env[EXPECTED_MANIFEST_ENV];
  if (!expectedManifestValue) fail(`${EXPECTED_MANIFEST_ENV} is required`);

  const fixtureRoot = resolve(fixtureRootValue);
  const actual = readFixtureManifest(
    resolve(fixtureRoot, "manifest.json"),
    "fixture manifest",
  );
  const expected = readFixtureManifest(
    resolve(expectedManifestValue),
    "expected fixture manifest",
  );
  requireExpectedFixtureManifest(actual, expected);

  const records: ExportCdnFixture[] = [];
  const byUrl = new Map<string, ExportCdnFixture>();
  const enumeratedFiles = new Set<string>();
  for (const [url, { file, integrity, contentType }] of Object.entries(
    actual.urls,
  )) {
    const bytes = readFixtureBytes(fixtureRoot, file, integrity, contentType);
    const record: ExportCdnFixture = {
      url,
      file,
      integrity,
      contentType,
      bytes,
    };
    records.push(record);
    byUrl.set(url, record);
    enumeratedFiles.add(file);
  }

  const expectedFiles = ["manifest.json", ...enumeratedFiles].sort();
  const actualFiles = fixtureFiles(fixtureRoot);
  if (JSON.stringify(actualFiles) !== JSON.stringify(expectedFiles)) {
    fail(
      `fixture output files differ from its manifest: expected ${expectedFiles.join(", ")}; got ${actualFiles.join(", ")}`,
    );
  }

  return { records, byUrl };
}

/**
 * Route the export document's CDN requests against the exact fixture URLs.
 * jsDelivr is intentionally blocked so the browser exercises the unpkg
 * fallback. Every other HTTPS request is recorded and aborted as unexpected.
 */
export async function installExportCdnRoutes(
  page: Page,
  fixtures: ExportCdnFixtures,
): Promise<ExportCdnRouteState> {
  const state: ExportCdnRouteState = {
    actions: [],
    attempts: [],
    unexpectedHttps: [],
  };

  await page.route("**/*", async (route) => {
    const requestUrl = route.request().url();
    const parsedUrl = new URL(requestUrl);
    if (parsedUrl.protocol !== "https:") {
      await route.continue();
      return;
    }

    state.attempts.push(requestUrl);
    const fixture = fixtures.byUrl.get(requestUrl);
    if (fixture && parsedUrl.origin === "https://cdn.jsdelivr.net") {
      state.actions.push({
        action: "abort-jsdelivr",
        errorCode: "blockedbyclient",
        url: requestUrl,
      });
      await route.abort("blockedbyclient");
      return;
    }
    if (fixture && parsedUrl.origin === "https://unpkg.com") {
      state.actions.push({
        action: "fulfill-unpkg",
        file: fixture.file,
        url: requestUrl,
      });
      await route.fulfill({
        body: fixture.bytes,
        headers: {
          "access-control-allow-origin": "*",
          "cache-control": "no-store",
          "content-type": fixture.contentType,
        },
        status: 200,
      });
      return;
    }

    state.unexpectedHttps.push(requestUrl);
    state.actions.push({
      action: "abort-unexpected",
      errorCode: "failed",
      url: requestUrl,
    });
    await route.abort("failed");
  });

  return state;
}
