import { render } from "preact";
import "./styles.css";
import { ExportApp } from "./export-app";
import { installShellParserE2eBridge } from "./e2e";
import { loadParsedShellDocument, preloadShellParser } from "./lib/shellParser";
import { configureTreeSitterAssets } from "./lib/treeSitterRuntime";
import { exportTreeSitterAssets } from "./exportTreeSitterAssets";

configureTreeSitterAssets(exportTreeSitterAssets);
preloadShellParser();
installShellParserE2eBridge(loadParsedShellDocument);

render(<ExportApp />, document.getElementById("app")!);
