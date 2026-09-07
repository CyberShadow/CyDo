import { afterEach, describe, expect, it, vi } from "vitest";
import { fetchBytesWithFallback } from "./exportCdn";

const originalFetch = globalThis.fetch;

afterEach(() => {
  vi.unstubAllGlobals();
  globalThis.fetch = originalFetch;
  vi.restoreAllMocks();
});

function validWasmResponse(marker = 1): Response {
  return new Response(new Uint8Array([0, 0x61, 0x73, 0x6d, marker]));
}

describe("fetchBytesWithFallback", () => {
  it("uses each candidate's exact URL and integrity options, stopping on success", async () => {
    const candidates = [
      {
        url: "https://primary.example/runtime.wasm",
        integrity: "sha384-primary",
      },
      {
        url: "https://secondary.example/runtime.wasm",
        integrity: "sha384-secondary",
      },
      {
        url: "https://tertiary.example/runtime.wasm",
        integrity: "sha384-tertiary",
      },
    ] as const;
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValue(validWasmResponse());
    vi.stubGlobal("fetch", fetchMock);

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
      {
        url: "https://primary.example/runtime.wasm",
        integrity: "sha384-primary",
      },
      {
        url: "https://secondary.example/runtime.wasm",
        integrity: "sha384-secondary",
      },
      {
        url: "https://tertiary.example/runtime.wasm",
        integrity: "sha384-tertiary",
      },
    ] as const;
    const primaryFailure = new Error("primary unavailable");
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockRejectedValueOnce(primaryFailure)
      .mockResolvedValueOnce(validWasmResponse(2));
    vi.stubGlobal("fetch", fetchMock);

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
      {
        url: "https://primary.example/runtime.wasm",
        integrity: "sha384-primary",
      },
      {
        url: "https://secondary.example/runtime.wasm",
        integrity: "sha384-secondary",
      },
    ] as const;
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(new Response(null, { status: 503 }))
      .mockResolvedValueOnce(validWasmResponse());
    vi.stubGlobal("fetch", fetchMock);

    await expect(
      fetchBytesWithFallback(candidates, "runtime.wasm"),
    ).resolves.toEqual(new Uint8Array([0, 0x61, 0x73, 0x6d, 1]));

    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("falls back after an invalid WASM magic header", async () => {
    const candidates = [
      {
        url: "https://primary.example/runtime.wasm",
        integrity: "sha384-primary",
      },
      {
        url: "https://secondary.example/runtime.wasm",
        integrity: "sha384-secondary",
      },
    ] as const;
    const invalidResponse = new Response(new Uint8Array([1, 2, 3, 4]));
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(invalidResponse)
      .mockResolvedValueOnce(validWasmResponse());
    vi.stubGlobal("fetch", fetchMock);

    await expect(
      fetchBytesWithFallback(candidates, "runtime.wasm"),
    ).resolves.toEqual(new Uint8Array([0, 0x61, 0x73, 0x6d, 1]));

    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("falls back when reading a response body fails", async () => {
    const candidates = [
      {
        url: "https://primary.example/runtime.wasm",
        integrity: "sha384-primary",
      },
      {
        url: "https://secondary.example/runtime.wasm",
        integrity: "sha384-secondary",
      },
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

    await expect(
      fetchBytesWithFallback(candidates, "runtime.wasm"),
    ).resolves.toEqual(new Uint8Array([0, 0x61, 0x73, 0x6d, 1]));

    expect(arrayBuffer).toHaveBeenCalledTimes(1);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("reports all failures in candidate order without an extra fetch", async () => {
    const candidates = [
      {
        url: "https://primary.example/runtime.wasm",
        integrity: "sha384-primary",
      },
      {
        url: "https://secondary.example/runtime.wasm",
        integrity: "sha384-secondary",
      },
      {
        url: "https://tertiary.example/runtime.wasm",
        integrity: "sha384-tertiary",
      },
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
