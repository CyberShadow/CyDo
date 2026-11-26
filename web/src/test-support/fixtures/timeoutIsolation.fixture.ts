import { expect, it, vi } from "vitest";

it("times out", async () => {
  await new Promise<void>(() => {});
});

it("stubs a global", () => {
  const fetch = vi.fn();
  vi.stubGlobal("fetch", fetch);
  try {
    expect(globalThis.fetch).toBe(fetch);
  } finally {
    vi.unstubAllGlobals();
  }
});

it("runs a plain test", () => {
  expect(true).toBe(true);
});
