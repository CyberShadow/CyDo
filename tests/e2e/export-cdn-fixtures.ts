import { createHash } from "node:crypto";
import { Buffer } from "node:buffer";
import { readFileSync, realpathSync } from "node:fs";
import { isAbsolute, relative, resolve, sep, win32 } from "node:path";
import type { Page } from "@playwright/test";

const FIXTURE_ENV = "CYDO_EXPORT_CDN_FIXTURES";
const EXPECTED_URL_COUNT = 6;
const WASM_MAGIC = Buffer.from([0, 0x61, 0x73, 0x6d]);
const RECORD_KEYS = ["contentType", "file", "integrity"];

type FixtureManifestRecord = {
  contentType: "application/wasm";
  file: string;
  integrity: string;
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

function readManifest(fixtureRoot: string): unknown {
  const manifestPath = resolve(fixtureRoot, "manifest.json");
  let text: string;
  try {
    text = readFileSync(manifestPath, "utf8");
  } catch (error) {
    fail(`cannot read manifest.json at ${manifestPath}: ${error}`);
  }

  try {
    return JSON.parse(text) as unknown;
  } catch (error) {
    fail(`cannot parse manifest.json at ${manifestPath}: ${error}`);
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

  if (!bytes.subarray(0, WASM_MAGIC.length).equals(WASM_MAGIC)) {
    fail(`fixture file ${file} does not have the WASM magic header`);
  }
  if (integrity !== sha384(bytes)) {
    fail(`fixture file ${file} does not match its integrity record`);
  }
  return bytes;
}

/**
 * Load the build-provided export CDN fixtures without deriving package names
 * or versions from their URLs. Manifest insertion order is retained in
 * `records`; `byUrl` uses each URL string exactly as written in the manifest.
 */
export function readExportCdnFixtures(): ExportCdnFixtures {
  const fixtureRootValue = process.env[FIXTURE_ENV];
  if (!fixtureRootValue) fail(`${FIXTURE_ENV} is required`);

  const fixtureRoot = resolve(fixtureRootValue);
  const manifest = readManifest(fixtureRoot);
  if (!isRecord(manifest)) fail("manifest must be an object");
  requireExactKeys(manifest, ["urls"], "manifest");

  const urls = manifest.urls;
  if (!isRecord(urls)) fail("manifest.urls must be an object");

  const entries = Object.entries(urls);
  if (entries.length !== EXPECTED_URL_COUNT) {
    fail(
      `manifest.urls has ${entries.length} URL records, expected ${EXPECTED_URL_COUNT}`,
    );
  }

  const records: ExportCdnFixture[] = [];
  const byUrl = new Map<string, ExportCdnFixture>();
  for (const [url, value] of entries) {
    validateUrl(url);
    if (!isRecord(value))
      fail(`fixture URL record for ${url} must be an object`);
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
    if (contentType !== "application/wasm") {
      fail(`fixture file ${file} has an unexpected content type`);
    }

    const bytes = readFixtureBytes(fixtureRoot, file, integrity);
    const record: ExportCdnFixture = {
      url,
      file,
      integrity,
      contentType,
      bytes,
    };
    records.push(record);
    byUrl.set(url, record);
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
