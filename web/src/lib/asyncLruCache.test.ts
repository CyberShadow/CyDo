import { describe, expect, it, vi } from "vitest";
import { AsyncLruCache } from "./asyncLruCache";

describe("AsyncLruCache", () => {
  it("shares an in-flight computation for the same key", async () => {
    const cache = new AsyncLruCache<string>(2);
    const compute = vi.fn(() => Promise.resolve("result"));

    const first = cache.load("key", compute);
    const second = cache.load("key", compute);

    expect(second).toBe(first);
    expect(compute).toHaveBeenCalledTimes(1);
    expect(cache.peek("key")).toBeUndefined();
    await expect(first).resolves.toBe("result");
    expect(cache.peek("key")).toBe("result");
  });

  it.each(["peek", "load"] as const)(
    "promotes a settled entry on %s",
    async (access) => {
      const cache = new AsyncLruCache<string>(2);
      await cache.load("first", () => Promise.resolve("first result"));
      await cache.load("second", () => Promise.resolve("second result"));

      if (access === "peek") {
        expect(cache.peek("first")).toBe("first result");
      } else {
        const compute = vi.fn(() => Promise.resolve("replacement"));
        await expect(cache.load("first", compute)).resolves.toBe(
          "first result",
        );
        expect(compute).not.toHaveBeenCalled();
      }
      await cache.load("third", () => Promise.resolve("third result"));

      expect(cache.peek("second")).toBeUndefined();
      expect(cache.peek("first")).toBe("first result");
      expect(cache.peek("third")).toBe("third result");
    },
  );

  it("counts only settled entries toward capacity", async () => {
    const cache = new AsyncLruCache<string>(1);
    let resolve!: (result: string) => void;
    const promise = new Promise<string>((resolvePromise) => {
      resolve = resolvePromise;
    });
    const pending = cache.load("pending", () => promise);
    await cache.load("settled", () => Promise.resolve("settled result"));

    const replacement = vi.fn(() => Promise.resolve("replacement"));
    expect(cache.load("pending", replacement)).toBe(pending);
    expect(replacement).not.toHaveBeenCalled();
    expect(cache.peek("settled")).toBe("settled result");

    resolve("pending result");
    await pending;

    expect(cache.peek("pending")).toBeUndefined();
    expect(cache.peek("settled")).toBe("settled result");
  });

  it("retries a computation after rejection", async () => {
    const cache = new AsyncLruCache<string>(1);
    const error = new Error("computation failed");

    await expect(cache.load("key", () => Promise.reject(error))).rejects.toBe(
      error,
    );

    await expect(
      cache.load("key", () => Promise.resolve("retried")),
    ).resolves.toBe("retried");
    expect(cache.peek("key")).toBe("retried");
  });
});
