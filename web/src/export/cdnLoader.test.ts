import { afterEach, describe, expect, it, vi } from "vitest";

const originalFetch = globalThis.fetch;

afterEach(() => {
  vi.unstubAllGlobals();
  globalThis.fetch = originalFetch;
  vi.restoreAllMocks();
});

function candidate(url: string, integrity = "sha384-test") {
  return { url, integrity };
}

function validWasmResponse(marker = 1): Response {
  return new Response(new Uint8Array([0, 0x61, 0x73, 0x6d, marker]));
}

function dataModule(source: string) {
  return `data:text/javascript,${encodeURIComponent(source)}`;
}

async function freshLoader() {
  vi.resetModules();
  return import("./cdnLoader");
}

describe("fetchBytesWithFallback", () => {
  it("uses each candidate's exact URL and integrity options, stopping on success", async () => {
    const candidates = [
      candidate("https://primary.example/runtime.wasm", "sha384-primary"),
      candidate("https://secondary.example/runtime.wasm", "sha384-secondary"),
      candidate("https://tertiary.example/runtime.wasm", "sha384-tertiary"),
    ] as const;
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValue(validWasmResponse());
    vi.stubGlobal("fetch", fetchMock);
    const { fetchBytesWithFallback } = await freshLoader();

    await expect(
      fetchBytesWithFallback(candidates, "runtime.wasm"),
    ).resolves.toEqual(new Uint8Array([0, 0x61, 0x73, 0x6d, 1]));

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock).toHaveBeenNthCalledWith(1, candidates[0].url, {
      integrity: candidates[0].integrity,
    });
  });

  it("falls back from a primary fetch failure to a secondary success", async () => {
    const candidates = [
      candidate("https://primary.example/runtime.wasm", "sha384-primary"),
      candidate("https://secondary.example/runtime.wasm", "sha384-secondary"),
      candidate("https://tertiary.example/runtime.wasm", "sha384-tertiary"),
    ] as const;
    const primaryFailure = new Error("primary unavailable");
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockRejectedValueOnce(primaryFailure)
      .mockResolvedValueOnce(validWasmResponse(2));
    vi.stubGlobal("fetch", fetchMock);
    const { fetchBytesWithFallback } = await freshLoader();

    await expect(
      fetchBytesWithFallback(candidates, "runtime.wasm"),
    ).resolves.toEqual(new Uint8Array([0, 0x61, 0x73, 0x6d, 2]));

    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(fetchMock).toHaveBeenNthCalledWith(1, candidates[0].url, {
      integrity: candidates[0].integrity,
    });
    expect(fetchMock).toHaveBeenNthCalledWith(2, candidates[1].url, {
      integrity: candidates[1].integrity,
    });
  });

  it("falls back after a non-2xx response", async () => {
    const candidates = [
      candidate("https://primary.example/runtime.wasm", "sha384-primary"),
      candidate("https://secondary.example/runtime.wasm", "sha384-secondary"),
    ] as const;
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(new Response(null, { status: 503 }))
      .mockResolvedValueOnce(validWasmResponse());
    vi.stubGlobal("fetch", fetchMock);
    const { fetchBytesWithFallback } = await freshLoader();

    await expect(
      fetchBytesWithFallback(candidates, "runtime.wasm"),
    ).resolves.toEqual(new Uint8Array([0, 0x61, 0x73, 0x6d, 1]));

    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("falls back after an invalid WASM magic header", async () => {
    const candidates = [
      candidate("https://primary.example/runtime.wasm", "sha384-primary"),
      candidate("https://secondary.example/runtime.wasm", "sha384-secondary"),
    ] as const;
    const invalidResponse = new Response(new Uint8Array([1, 2, 3, 4]));
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(invalidResponse)
      .mockResolvedValueOnce(validWasmResponse());
    vi.stubGlobal("fetch", fetchMock);
    const { fetchBytesWithFallback } = await freshLoader();

    await expect(
      fetchBytesWithFallback(candidates, "runtime.wasm"),
    ).resolves.toEqual(new Uint8Array([0, 0x61, 0x73, 0x6d, 1]));

    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("falls back when reading a response body fails", async () => {
    const candidates = [
      candidate("https://primary.example/runtime.wasm", "sha384-primary"),
      candidate("https://secondary.example/runtime.wasm", "sha384-secondary"),
    ] as const;
    const bodyFailure = new Error("body read failed");
    const arrayBuffer = vi
      .fn<typeof Response.prototype.arrayBuffer>()
      .mockRejectedValue(bodyFailure);
    const bodyFailureResponse = {
      ok: true,
      status: 200,
      arrayBuffer,
    } as unknown as Response;
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(bodyFailureResponse)
      .mockResolvedValueOnce(validWasmResponse());
    vi.stubGlobal("fetch", fetchMock);
    const { fetchBytesWithFallback } = await freshLoader();

    await expect(
      fetchBytesWithFallback(candidates, "runtime.wasm"),
    ).resolves.toEqual(new Uint8Array([0, 0x61, 0x73, 0x6d, 1]));

    expect(arrayBuffer).toHaveBeenCalledTimes(1);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("reports all failures in candidate order without an extra fetch", async () => {
    const candidates = [
      candidate("https://primary.example/runtime.wasm", "sha384-primary"),
      candidate("https://secondary.example/runtime.wasm", "sha384-secondary"),
      candidate("https://tertiary.example/runtime.wasm", "sha384-tertiary"),
    ] as const;
    const primaryFailure = new Error("primary unavailable");
    const bodyFailure = new Error("body read failed");
    const bodyFailureResponse = {
      ok: true,
      status: 200,
      arrayBuffer: vi
        .fn<typeof Response.prototype.arrayBuffer>()
        .mockRejectedValue(bodyFailure),
    } as unknown as Response;
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockRejectedValueOnce(primaryFailure)
      .mockResolvedValueOnce(new Response(null, { status: 404 }))
      .mockResolvedValueOnce(bodyFailureResponse);
    vi.stubGlobal("fetch", fetchMock);
    const { fetchBytesWithFallback } = await freshLoader();

    let failure: unknown;
    try {
      await fetchBytesWithFallback(candidates, "runtime.wasm");
    } catch (error: unknown) {
      failure = error;
    }

    expect(failure).toBeInstanceOf(AggregateError);
    if (!(failure instanceof AggregateError))
      throw new Error("expected an AggregateError");

    expect(failure.errors).toHaveLength(3);
    expect(failure.errors[0]).toBe(primaryFailure);
    expect(failure.errors[1]).toEqual(
      new Error(
        "runtime.wasm candidate https://secondary.example/runtime.wasm returned HTTP 404",
      ),
    );
    expect(failure.errors[2]).toBe(bodyFailure);
    expect(fetchMock).toHaveBeenCalledTimes(3);
    expect(fetchMock).toHaveBeenNthCalledWith(1, candidates[0].url, {
      integrity: candidates[0].integrity,
    });
    expect(fetchMock).toHaveBeenNthCalledWith(2, candidates[1].url, {
      integrity: candidates[1].integrity,
    });
    expect(fetchMock).toHaveBeenNthCalledWith(3, candidates[2].url, {
      integrity: candidates[2].integrity,
    });
  });
});

describe("importModuleWithFallback", () => {
  it("uses direct ordered imports without fetch and returns the selected candidate", async () => {
    const primary = candidate(dataModule('throw new Error("primary failed")'));
    const secondary = candidate(dataModule('export const host = "secondary"'));
    const fetchMock = vi.fn<typeof fetch>();
    vi.stubGlobal("fetch", fetchMock);
    const { importModuleWithFallback } = await freshLoader();

    const loaded = await importModuleWithFallback<{ host: string }>(
      "ordered-root",
      [primary, secondary],
    );

    expect(loaded.candidate).toBe(secondary);
    expect(loaded.module.host).toBe("secondary");
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("falls through after a transitive root import rejects", async () => {
    const rejectedDependency = dataModule(
      'throw new Error("transitive failed")',
    );
    const primary = candidate(
      dataModule(`import ${JSON.stringify(rejectedDependency)};`),
    );
    const secondary = candidate(dataModule('export const host = "secondary"'));
    const { importModuleWithFallback } = await freshLoader();

    const loaded = await importModuleWithFallback<{ host: string }>(
      "transitive-root",
      [primary, secondary],
    );

    expect(loaded.candidate).toBe(secondary);
    expect(loaded.module.host).toBe("secondary");
  });

  it("reports exhausted import failures in candidate order", async () => {
    const first = candidate(dataModule('throw new Error("first failure")'));
    const second = candidate(dataModule('throw new Error("second failure")'));
    const { importModuleWithFallback } = await freshLoader();

    let failure: unknown;
    try {
      await importModuleWithFallback("exhausted-root", [first, second]);
    } catch (error: unknown) {
      failure = error;
    }

    expect(failure).toBeInstanceOf(AggregateError);
    if (!(failure instanceof AggregateError))
      throw new Error("expected an AggregateError");

    expect(failure.errors).toHaveLength(2);
    expect(failure.errors.map(String)).toEqual([
      "Error: first failure",
      "Error: second failure",
    ]);
  });

  it("caches only a successful selection for a dependency key", async () => {
    const primary = candidate(dataModule('throw new Error("primary failed")'));
    const secondary = candidate(dataModule('export const marker = "cached"'));
    const impossible = candidate(
      dataModule('throw new Error("must not import")'),
    );
    const { importModuleWithFallback } = await freshLoader();

    const first = await importModuleWithFallback<{ marker: string }>(
      "cached-root",
      [primary, secondary],
    );
    const second = await importModuleWithFallback<{ marker: string }>(
      "cached-root",
      [impossible],
    );

    expect(second).toBe(first);
    expect(second.candidate).toBe(secondary);
    expect(second.module.marker).toBe("cached");
  });

  it("does not cache a failed import chain", async () => {
    const failed = candidate(dataModule('throw new Error("retry later")'));
    const recovered = candidate(
      dataModule('export const marker = "recovered"'),
    );
    const { importModuleWithFallback } = await freshLoader();

    await expect(
      importModuleWithFallback("retry-root", [failed]),
    ).rejects.toBeInstanceOf(AggregateError);
    await expect(
      importModuleWithFallback<{ marker: string }>("retry-root", [recovered]),
    ).resolves.toMatchObject({
      candidate: recovered,
      module: { marker: "recovered" },
    });
  });
});
