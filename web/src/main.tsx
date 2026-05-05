import { options, render } from "preact";
import { LocationProvider } from "preact-iso";
import "./styles.css";
import { App } from "./app";

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
