import {
  chmodSync,
  cpSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { expect, test } from "@playwright/test";

import { readExportCdnFixtures } from "./export-cdn-fixtures";

const FIXTURE_ENV = "CYDO_EXPORT_CDN_FIXTURES";
const EXPECTED_MANIFEST_ENV = "CYDO_EXPORT_CDN_EXPECTED_MANIFEST";

let originalFixtureRoot: string | undefined;
let writableParent: string | undefined;

type FixtureManifest = {
  urls: Record<string, unknown>;
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function fixtureManifestPath(): string {
  const fixtureRoot = process.env[FIXTURE_ENV];
  const expectedManifest = process.env[EXPECTED_MANIFEST_ENV];
  if (!fixtureRoot) throw new Error(`${FIXTURE_ENV} is required for this test`);
  if (!expectedManifest)
    throw new Error(`${EXPECTED_MANIFEST_ENV} is required for this test`);

  const manifestPath = join(fixtureRoot, "manifest.json");
  if (resolve(manifestPath) === resolve(expectedManifest)) {
    throw new Error(
      `${EXPECTED_MANIFEST_ENV} must remain separate from the mutable fixture manifest`,
    );
  }
  return manifestPath;
}

test.beforeEach(() => {
  const fixtureRoot = process.env[FIXTURE_ENV];
  const expectedManifest = process.env[EXPECTED_MANIFEST_ENV];
  if (!fixtureRoot) throw new Error(`${FIXTURE_ENV} is required for this test`);
  if (!expectedManifest)
    throw new Error(`${EXPECTED_MANIFEST_ENV} is required for this test`);

  originalFixtureRoot = fixtureRoot;
  writableParent = mkdtempSync(join(tmpdir(), "cydo-export-cdn-fixtures-"));
  const writableFixtureRoot = join(writableParent, "fixture");
  cpSync(fixtureRoot, writableFixtureRoot, { recursive: true });
  chmodSync(writableFixtureRoot, 0o755);
  chmodSync(join(writableFixtureRoot, "manifest.json"), 0o644);
  process.env[FIXTURE_ENV] = writableFixtureRoot;
});

test.afterEach(() => {
  process.env[FIXTURE_ENV] = originalFixtureRoot;
  if (writableParent) rmSync(writableParent, { recursive: true, force: true });
  originalFixtureRoot = undefined;
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
