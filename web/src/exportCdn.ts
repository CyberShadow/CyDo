import type { CdnCandidate } from "virtual:cydo-export-cdn";

type NonEmptyCandidates = readonly [CdnCandidate, ...CdnCandidate[]];

const WASM_MAGIC = [0, 0x61, 0x73, 0x6d];

export async function fetchBytesWithFallback(
  candidates: NonEmptyCandidates,
  assetLabel: string,
): Promise<Uint8Array> {
  const failures: unknown[] = [];

  for (const candidate of candidates) {
    try {
      const response = await fetch(candidate.url, {
        integrity: candidate.integrity,
      });
      if (!response.ok)
        throw new Error(
          `${assetLabel} candidate ${candidate.url} returned HTTP ${response.status}`,
        );

      const bytes = new Uint8Array(await response.arrayBuffer());
      for (let index = 0; index < WASM_MAGIC.length; index++) {
        if (bytes[index] !== WASM_MAGIC[index])
          throw new Error(
            `${assetLabel} candidate ${candidate.url} returned invalid WASM magic`,
          );
      }
      return bytes;
    } catch (error: unknown) {
      failures.push(error);
    }
  }

  throw new AggregateError(
    failures,
    `failed to load ${assetLabel} from CDN candidates`,
  );
}
