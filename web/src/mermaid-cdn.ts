// CDN-loading shim for mermaid in export builds.
// Diagrams show raw source until the CDN delivers, then render.
// If offline, raw source stays permanently.

/* eslint-disable @typescript-eslint/no-explicit-any, @typescript-eslint/no-unsafe-assignment, @typescript-eslint/no-unsafe-return, @typescript-eslint/no-unsafe-call, @typescript-eslint/no-unsafe-member-access */

const CDN_URL =
  "https://cdn.jsdelivr.net/npm/mermaid@11.13.0/dist/mermaid.esm.min.mjs";

let _mod: any = null;
async function getMod() {
  if (!_mod) {
    _mod = await import(/* @vite-ignore */ CDN_URL);
  }
  return _mod;
}

export default {
  initialize: (...a: any[]) => getMod().then((m) => m.default.initialize(...a)),
  render: (...a: any[]) => getMod().then((m) => m.default.render(...a)),
};
