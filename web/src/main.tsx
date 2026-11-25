import { options, render } from "preact";
import { LocationProvider } from "preact-iso";
import "./styles.css";
import { App } from "./app";
import { installShellParserE2eBridge } from "./e2e";
import { loadParsedShellDocument, preloadShellParser } from "./lib/shellParser";
import { configureTreeSitterAssets } from "./lib/treeSitterRuntime";
import { treeSitterAssets } from "./treeSitterAssets";

configureTreeSitterAssets(treeSitterAssets);
preloadShellParser();
installShellParserE2eBridge(loadParsedShellDocument);

if (import.meta.env.DEV) await import("preact/debug");

// Exposed for e2e test instrumentation; see tests/e2e/rerender-stability.spec.ts
(window as unknown as { __preactOptions: typeof options }).__preactOptions =
  options;

render(
  <LocationProvider>
    <App />
  </LocationProvider>,
  document.getElementById("app")!,
);
