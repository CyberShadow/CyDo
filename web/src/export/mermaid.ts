import { mermaidRoots } from "virtual:cydo-export-cdn";
import { importModuleWithFallback } from "./cdnLoader";

type MermaidApi = {
  initialize(...args: unknown[]): unknown;
  render(...args: unknown[]): unknown;
};

type MermaidModule = {
  default: MermaidApi;
};

async function getMermaid() {
  const loaded = await importModuleWithFallback<MermaidModule>(
    "mermaid-root",
    mermaidRoots,
  );
  return loaded.module.default;
}

export default {
  initialize: (...args: unknown[]) =>
    getMermaid().then((mermaid) => mermaid.initialize(...args)),
  render: (...args: unknown[]) =>
    getMermaid().then((mermaid) => mermaid.render(...args)),
};
