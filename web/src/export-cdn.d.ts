declare module "virtual:cydo-export-cdn" {
  export type CdnCandidate = Readonly<{
    url: string;
    integrity: string;
  }>;

  export const treeSitterRuntime: readonly [CdnCandidate, ...CdnCandidate[]];
  export const treeSitterBash: readonly [CdnCandidate, ...CdnCandidate[]];
  export const shikiRoots: readonly [CdnCandidate, CdnCandidate];
  export const mermaidRoots: readonly [CdnCandidate, CdnCandidate];
  export const shikiLanguages: Readonly<
    Record<
      string,
      Readonly<{
        jsdelivr: CdnCandidate;
        unpkg: CdnCandidate;
      }>
    >
  >;
}
