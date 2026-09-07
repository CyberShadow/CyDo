import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  exportWasmFallbackGuard,
  FALLBACK_SOURCE,
  GUARD_NAME,
  PINNED_VERSION,
  REPLACEMENT_SOURCE,
} from "./export-wasm-fallback-guard.mjs";

const temporaryRoots = [];

afterEach(() => {
  for (const root of temporaryRoots.splice(0))
    rmSync(root, { recursive: true, force: true });
});

function temporaryPackageRoot({
  version = PINNED_VERSION,
  runtimeSource = FALLBACK_SOURCE,
} = {}) {
  const root = mkdtempSync(join(tmpdir(), "cydo-export-wasm-guard-"));
  temporaryRoots.push(root);

  const packageRoot = join(root, "node_modules", "web-tree-sitter");
  mkdirSync(packageRoot, { recursive: true });
  writeFileSync(
    join(packageRoot, "package.json"),
    `${JSON.stringify({ version })}\n`,
  );
  writeFileSync(join(packageRoot, "web-tree-sitter.js"), runtimeSource);

  return {
    root,
    runtimePath: resolve(packageRoot, "web-tree-sitter.js"),
  };
}

function configuredGuard(root, plugins = []) {
  const guard = exportWasmFallbackGuard();
  guard.configResolved({
    root,
    plugins: [guard, ...plugins],
  });
  return guard;
}

describe("export WASM fallback guard", () => {
  it("matches the exact runtime target after removing an id query", () => {
    const { root, runtimePath } = temporaryPackageRoot();
    const guard = configuredGuard(root, [
      { name: "vite:asset-import-meta-url" },
    ]);
    const source = `before\n${FALLBACK_SOURCE}\nafter`;

    expect(guard.transform(source, `${runtimePath}?import&index=0`)).toBe(
      source.replace(FALLBACK_SOURCE, REPLACEMENT_SOURCE),
    );
  });

  it("passes through non-target runtime ids", () => {
    const { root, runtimePath } = temporaryPackageRoot();
    const guard = configuredGuard(root, [
      { name: "vite:asset-import-meta-url" },
    ]);

    expect(
      guard.transform(FALLBACK_SOURCE, `${runtimePath}.copy?import`),
    ).toBeUndefined();
  });

  it.each([
    ["missing", "export const runtime = true;", 0],
    ["duplicate", `${FALLBACK_SOURCE}\n${FALLBACK_SOURCE}`, 2],
  ])(
    "rejects an installed runtime with a %s fallback expression",
    (_label, runtimeSource, count) => {
      const { root } = temporaryPackageRoot({ runtimeSource });

      expect(() =>
        configuredGuard(root, [{ name: "vite:asset-import-meta-url" }]),
      ).toThrow(
        `${GUARD_NAME} expected exactly one ${PINNED_VERSION} fallback expression, got ${count}`,
      );
    },
  );

  it("rejects an installed runtime whose pinned version drifted", () => {
    const { root } = temporaryPackageRoot({ version: "0.27.1" });

    expect(() =>
      configuredGuard(root, [{ name: "vite:asset-import-meta-url" }]),
    ).toThrow(
      `${GUARD_NAME} expected web-tree-sitter ${PINNED_VERSION}, got 0.27.1`,
    );
  });

  it.each([
    ["missing", "export const runtime = true;", 0],
    ["duplicate", `${FALLBACK_SOURCE}\n${FALLBACK_SOURCE}`, 2],
  ])(
    "rejects a transformed runtime source with a %s fallback expression",
    (_label, source, count) => {
      const { root, runtimePath } = temporaryPackageRoot();
      const guard = configuredGuard(root, [
        { name: "vite:asset-import-meta-url" },
      ]);

      expect(() => guard.transform(source, runtimePath)).toThrow(
        `${GUARD_NAME} saw ${count} fallback expressions in ${runtimePath}`,
      );
    },
  );

  it("rejects an unexpected asset-plugin order", () => {
    const { root } = temporaryPackageRoot();
    const guard = exportWasmFallbackGuard();

    expect(() =>
      guard.configResolved({
        root,
        plugins: [{ name: "vite:asset-import-meta-url" }, guard],
      }),
    ).toThrow(
      `${GUARD_NAME} must be ordered before vite:asset-import-meta-url`,
    );
  });

  it("replaces the fallback exactly without adding a URL fallback", () => {
    const { root, runtimePath } = temporaryPackageRoot();
    const guard = configuredGuard(root, [
      { name: "vite:asset-import-meta-url" },
    ]);
    const source = `const locateWasm = () => {\n    ${FALLBACK_SOURCE}\n  };`;

    const transformed = guard.transform(source, runtimePath);

    expect(transformed).toBe(
      source.replace(FALLBACK_SOURCE, REPLACEMENT_SOURCE),
    );
    expect(transformed).not.toContain("new URL(");
    expect(transformed).toContain('if (wasmBinary) return "";');
    expect(transformed).toContain(
      'throw new Error("web-tree-sitter runtime requires wasmBinary");',
    );
  });

  it("accepts exactly one runtime transform during a build", () => {
    const { root, runtimePath } = temporaryPackageRoot();
    const guard = configuredGuard(root, [
      { name: "vite:asset-import-meta-url" },
    ]);

    guard.transform(FALLBACK_SOURCE, runtimePath);
    expect(() => guard.buildEnd()).not.toThrow();
  });

  it("rejects a second runtime transform during a build", () => {
    const { root, runtimePath } = temporaryPackageRoot();
    const guard = configuredGuard(root, [
      { name: "vite:asset-import-meta-url" },
    ]);

    guard.transform(FALLBACK_SOURCE, runtimePath);
    expect(() => guard.transform(FALLBACK_SOURCE, runtimePath)).toThrow(
      `${GUARD_NAME} transformed ${runtimePath} more than once during the export build`,
    );
    expect(() => guard.buildEnd()).toThrow(
      `${GUARD_NAME} transformed the runtime 2 times during the export build; expected exactly once`,
    );
  });

  it("requires one runtime transform before build end", () => {
    const { root } = temporaryPackageRoot();
    const guard = configuredGuard(root, [
      { name: "vite:asset-import-meta-url" },
    ]);

    expect(() => guard.buildEnd()).toThrow(
      `${GUARD_NAME} transformed the runtime 0 times during the export build; expected exactly once`,
    );
  });
});
