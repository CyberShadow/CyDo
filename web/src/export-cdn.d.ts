declare module "virtual:cydo-export-cdn" {
  export type CdnCandidate = Readonly<{
    url: string;
    integrity: string;
  }>;

  export const treeSitterRuntime: readonly [CdnCandidate, ...CdnCandidate[]];
  export const treeSitterBash: readonly [CdnCandidate, ...CdnCandidate[]];
}
