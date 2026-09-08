import {
  chmodSync,
  cpSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { expect, test } from "@playwright/test";
import type { Page, Response } from "@playwright/test";

import {
  installExportCdnRoutes,
  readExportCdnFixtures,
  resolveExportCdnFixturePaths,
} from "./export-cdn-fixtures";

const FIXTURE_ENV = "CYDO_EXPORT_CDN_FIXTURES";
const EXPECTED_MANIFEST_ENV = "CYDO_EXPORT_CDN_EXPECTED_MANIFEST";

let originalFixtureRoot: string | undefined;
let originalExpectedManifest: string | undefined;
let writableParent: string | undefined;

type FixtureManifest = {
  urls: Record<string, unknown>;
};

type ExportCdnFixture = ReturnType<
  typeof readExportCdnFixtures
>["records"][number];

type ExportCdnRouteAction = {
  action: string;
  computedIntegrity?: string;
  expectedIntegrity?: string;
  file?: string;
  url: string;
};

type ExportCdnRouteState = {
  actions: ExportCdnRouteAction[];
  requests: string[];
  unexpectedHttps: string[];
};

function restoreEnvironment(name: string, value: string | undefined): void {
  if (value === undefined) delete process.env[name];
  else process.env[name] = value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function fixtureManifestPath(): string {
  const { fixtureRoot, expectedManifestPath: expectedManifest } =
    resolveExportCdnFixturePaths();

  const manifestPath = join(fixtureRoot, "manifest.json");
  if (resolve(manifestPath) === resolve(expectedManifest)) {
    throw new Error(
      `${EXPECTED_MANIFEST_ENV} must remain separate from the mutable fixture manifest`,
    );
  }
  return manifestPath;
}

test.beforeEach(() => {
  const { fixtureRoot, expectedManifestPath } = resolveExportCdnFixturePaths();

  originalFixtureRoot = process.env[FIXTURE_ENV];
  originalExpectedManifest = process.env[EXPECTED_MANIFEST_ENV];
  writableParent = mkdtempSync(join(tmpdir(), "cydo-export-cdn-fixtures-"));
  const writableFixtureRoot = join(writableParent, "fixture");
  cpSync(fixtureRoot, writableFixtureRoot, { recursive: true });
  chmodSync(writableFixtureRoot, 0o755);
  chmodSync(join(writableFixtureRoot, "manifest.json"), 0o644);
  process.env[FIXTURE_ENV] = writableFixtureRoot;
  process.env[EXPECTED_MANIFEST_ENV] = expectedManifestPath;
});

test.afterEach(() => {
  restoreEnvironment(FIXTURE_ENV, originalFixtureRoot);
  restoreEnvironment(EXPECTED_MANIFEST_ENV, originalExpectedManifest);
  if (writableParent) rmSync(writableParent, { recursive: true, force: true });
  originalFixtureRoot = undefined;
  originalExpectedManifest = undefined;
  writableParent = undefined;
});

function readFixtureManifest(path: string): FixtureManifest {
  const manifest = JSON.parse(readFileSync(path, "utf8")) as unknown;
  if (!isRecord(manifest) || !isRecord(manifest.urls)) {
    throw new Error("export CDN test fixture manifest must have a urls object");
  }
  return { urls: manifest.urls };
}

function writeFixtureManifest(
  path: string,
  urls: Record<string, unknown>,
): void {
  writeFileSync(path, `${JSON.stringify({ urls }, null, 2)}\n`, "utf8");
}

function expectRejectedManifest(
  mutate: (urls: Record<string, unknown>) => Record<string, unknown>,
): void {
  const path = fixtureManifestPath();
  const original = readFileSync(path);
  try {
    const { urls } = readFixtureManifest(path);
    expect(() => readExportCdnFixtures()).not.toThrow();
    writeFixtureManifest(path, mutate(urls));
    expect(() => readExportCdnFixtures()).toThrow();
  } finally {
    writeFileSync(path, original);
  }
}

function fileForRecord(record: unknown): string | undefined {
  if (!isRecord(record) || typeof record.file !== "string") return undefined;
  return record.file;
}

function sha384(bytes: Buffer): string {
  return `sha384-${createHash("sha384").update(bytes).digest("base64")}`;
}

function hostFor(record: ExportCdnFixture): string {
  return new URL(record.url).hostname;
}

function requireFixture(
  fixtures: ReturnType<typeof readExportCdnFixtures>,
  predicate: (record: ExportCdnFixture) => boolean,
  description: string,
): ExportCdnFixture {
  const record = fixtures.records.find(predicate);
  if (!record) {
    throw new Error(`export CDN test fixture must contain ${description}`);
  }
  return record;
}

function fixtureRecordsForPrecedence(
  fixtures: ReturnType<typeof readExportCdnFixtures>,
): {
  defaultFulfill: ExportCdnFixture;
  hostAbort: ExportCdnFixture;
  urlTamper: ExportCdnFixture;
} {
  for (const urlTamper of fixtures.records) {
    const host = hostFor(urlTamper);
    const sameHost = fixtures.records.filter(
      (record) => hostFor(record) === host,
    );
    const hostAbort = sameHost.find((record) => record.url !== urlTamper.url);
    const defaultFulfill = fixtures.records.find(
      (record) => hostFor(record) !== host,
    );
    if (hostAbort && defaultFulfill) {
      return { defaultFulfill, hostAbort, urlTamper };
    }
  }
  throw new Error(
    "export CDN test fixture must contain two URLs on one host and a URL on another host",
  );
}

// route.fulfill()'s "cache-control: no-store" header (required by the export
// CDN fixture headers) makes Chromium discard the response body before
// Playwright's response.body() (a CDP getResponseBody call) can retrieve it,
// hanging that call indefinitely. Read the body inside the page instead,
// where the fetch() consumer already has the bytes.
async function fetchFixture(
  page: Page,
  url: string,
): Promise<{ bytes: Buffer; response: Response }> {
  const [response, result] = await Promise.all([
    page.waitForResponse((candidate) => candidate.url() === url),
    page.evaluate(async (requestUrl) => {
      const fetched = await fetch(requestUrl);
      const body = new Uint8Array(await fetched.arrayBuffer());
      let binary = "";
      for (const byte of body) binary += String.fromCharCode(byte);
      return { base64: btoa(binary), ok: fetched.ok, status: fetched.status };
    }, url),
  ]);
  expect({ ok: result.ok, status: result.status }).toEqual({
    ok: true,
    status: 200,
  });
  return { bytes: Buffer.from(result.base64, "base64"), response };
}

async function expectFetchToAbort(page: Page, url: string): Promise<void> {
  const result = await page.evaluate(async (requestUrl) => {
    try {
      await fetch(requestUrl);
      return "fulfilled";
    } catch {
      return "rejected";
    }
  }, url);
  expect(result).toBe("rejected");
}

function expectFixtureResponse(
  response: Response,
  fixture: ExportCdnFixture,
): void {
  expect(response.status()).toBe(200);
  expect(response.headers()).toMatchObject({
    "access-control-allow-origin": "*",
    "cache-control": "no-store",
    "content-type": fixture.contentType,
  });
}

function actionFor(
  state: ExportCdnRouteState,
  url: string,
): ExportCdnRouteAction {
  const matching = state.actions.filter((action) => action.url === url);
  expect(matching).toHaveLength(1);
  return matching[0]!;
}

test(
  "reads generated export CDN fixture records",
  { tag: "@claude-only" },
  () => {
    const fixtures = readExportCdnFixtures();

    expect(fixtures.records.length).toBeGreaterThan(0);
    for (const record of fixtures.records) {
      expect(record.url).toMatch(/^https:\/\//);
      expect(record.bytes.length).toBeGreaterThan(0);
      expect(fixtures.byUrl.get(record.url)).toBe(record);
    }
  },
);

test(
  "routes known URLs by exact URL, host, and default policy in request order",
  { tag: "@claude-only" },
  async ({ page }) => {
    const fixtures = readExportCdnFixtures();
    const { defaultFulfill, hostAbort, urlTamper } =
      fixtureRecordsForPrecedence(fixtures);
    const state = await installExportCdnRoutes(page, fixtures, {
      defaultAction: "fulfill",
      hostActions: { [hostFor(urlTamper)]: "abort" },
      urlActions: { [urlTamper.url]: "tamper" },
    });

    const tampered = await fetchFixture(page, urlTamper.url);
    await expectFetchToAbort(page, hostAbort.url);
    const fulfilled = await fetchFixture(page, defaultFulfill.url);

    expectFixtureResponse(tampered.response, urlTamper);
    expectFixtureResponse(fulfilled.response, defaultFulfill);
    expect(state.requests).toEqual([
      urlTamper.url,
      hostAbort.url,
      defaultFulfill.url,
    ]);
    expect(state.actions).toHaveLength(state.requests.length);
    expect(state.actions.map((action) => action.url)).toEqual(state.requests);
    expect(state.unexpectedHttps).toEqual([]);
    expect(actionFor(state, urlTamper.url)).toMatchObject({
      action: "tamper",
      file: urlTamper.file,
      url: urlTamper.url,
    });
    expect(actionFor(state, hostAbort.url)).toMatchObject({
      action: "abort",
      file: hostAbort.file,
      url: hostAbort.url,
    });
    expect(actionFor(state, defaultFulfill.url)).toMatchObject({
      action: "fulfill",
      file: defaultFulfill.file,
      url: defaultFulfill.url,
    });
  },
);

test(
  "fulfills JavaScript and WASM fixtures with their response headers",
  { tag: "@claude-only" },
  async ({ page }) => {
    const fixtures = readExportCdnFixtures();
    const javascript = requireFixture(
      fixtures,
      (record) => record.contentType === "application/javascript",
      "a JavaScript fixture URL",
    );
    const wasm = requireFixture(
      fixtures,
      (record) => record.contentType === "application/wasm",
      "a WASM fixture URL",
    );
    const state = await installExportCdnRoutes(page, fixtures, {
      defaultAction: "fulfill",
    });

    const javascriptResponse = await fetchFixture(page, javascript.url);
    const wasmResponse = await fetchFixture(page, wasm.url);

    expectFixtureResponse(javascriptResponse.response, javascript);
    expectFixtureResponse(wasmResponse.response, wasm);
    expect(javascriptResponse.bytes).toEqual(javascript.bytes);
    expect(wasmResponse.bytes).toEqual(wasm.bytes);
    expect(state.requests).toEqual([javascript.url, wasm.url]);
    expect(state.actions.map((action) => action.url)).toEqual(state.requests);
    expect(actionFor(state, javascript.url)).toMatchObject({
      action: "fulfill",
      file: javascript.file,
      url: javascript.url,
    });
    expect(actionFor(state, wasm.url)).toMatchObject({
      action: "fulfill",
      file: wasm.file,
      url: wasm.url,
    });
  },
);

test(
  "tampers a copied fixture response and records its changed integrity",
  { tag: "@claude-only" },
  async ({ page }) => {
    const fixtures = readExportCdnFixtures();
    const fixture = requireFixture(
      fixtures,
      (record) => record.bytes.length > 0,
      "a non-empty fixture URL",
    );
    const originalBytes = Buffer.from(fixture.bytes);
    const state = await installExportCdnRoutes(page, fixtures, {
      defaultAction: "tamper",
    });

    const { bytes: responseBytes, response } = await fetchFixture(
      page,
      fixture.url,
    );

    expectFixtureResponse(response, fixture);
    expect(sha384(originalBytes)).toBe(fixture.integrity);
    expect(responseBytes).not.toEqual(originalBytes);
    expect(sha384(responseBytes)).not.toBe(fixture.integrity);
    expect(actionFor(state, fixture.url)).toMatchObject({
      action: "tamper",
      computedIntegrity: sha384(responseBytes),
      expectedIntegrity: fixture.integrity,
      file: fixture.file,
      url: fixture.url,
    });
    expect(fixture.bytes).toEqual(originalBytes);
    expect(fixtures.byUrl.get(fixture.url)?.bytes).toEqual(originalBytes);
  },
);

test(
  "aborts and separately records unknown HTTPS requests",
  { tag: "@claude-only" },
  async ({ page }) => {
    const fixtures = readExportCdnFixtures();
    const unknownUrl = new URL(
      `/cydo-export-cdn-unexpected-${fixtures.records.length}.mjs`,
      "https://cydo-export-cdn-unexpected.invalid",
    ).href;
    expect(fixtures.byUrl.has(unknownUrl)).toBe(false);
    const state = await installExportCdnRoutes(page, fixtures, {
      defaultAction: "fulfill",
    });

    await expectFetchToAbort(page, unknownUrl);

    expect(state.requests).toEqual([unknownUrl]);
    expect(state.unexpectedHttps).toEqual([unknownUrl]);
    expect(state.actions).toHaveLength(1);
    expect(state.actions[0]).toMatchObject({ url: unknownUrl });
    expect(actionFor(state, unknownUrl).action).toContain("abort");
  },
);

test(
  "rejects a missing host URL when another host still references its fixture file",
  { tag: "@claude-only" },
  () => {
    expectRejectedManifest((urls) => {
      const entries = Object.entries(urls);
      const omitted = entries.find(([url, record]) => {
        const file = fileForRecord(record);
        if (!file) return false;
        const hostname = new URL(url).hostname;
        return entries.some(
          ([otherUrl, otherRecord]) =>
            otherUrl !== url &&
            new URL(otherUrl).hostname !== hostname &&
            fileForRecord(otherRecord) === file,
        );
      });
      if (!omitted)
        throw new Error(
          "export CDN test fixture must contain host URLs sharing one fixture file",
        );

      const [omittedUrl] = omitted;
      return Object.fromEntries(entries.filter(([url]) => url !== omittedUrl));
    });
  },
);

test(
  "rejects a sorted orphan URL that reuses a valid fixture record",
  { tag: "@claude-only" },
  () => {
    expectRejectedManifest((urls) => {
      const source = Object.entries(urls)[0];
      if (!source)
        throw new Error("export CDN test fixture must contain a URL");

      const [sourceUrl, sourceRecord] = source;
      const orphan = new URL(sourceUrl);
      orphan.searchParams.append("cydo-export-cdn-fixture-orphan", "1");
      const orphanUrl = orphan.href;
      if (orphanUrl in urls)
        throw new Error(
          "export CDN test orphan URL unexpectedly already exists",
        );

      return Object.fromEntries(
        [...Object.entries(urls), [orphanUrl, sourceRecord]].sort(
          ([left], [right]) => (left < right ? -1 : left > right ? 1 : 0),
        ),
      );
    });
  },
);
