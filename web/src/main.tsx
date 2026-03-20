import "preact/debug";
import { render } from "preact";
import { LocationProvider } from "preact-iso";
import "./styles.css";
import { App } from "./app";

render(
  <LocationProvider>
    <App />
  </LocationProvider>,
  document.getElementById("app")!,
);
