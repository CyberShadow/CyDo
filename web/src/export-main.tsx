import { render } from "preact";
import "./styles.css";
import { ExportApp } from "./export-app";
import { installShellParserE2eBridge } from "./e2e";
import {
  configureShellParserAssets,
  loadParsedShellDocument,
  preloadShellParser,
} from "./lib/shellParser";
import { exportShellParserAssets } from "./exportShellParserAssets";

configureShellParserAssets(exportShellParserAssets);
preloadShellParser();
installShellParserE2eBridge(loadParsedShellDocument);

render(<ExportApp />, document.getElementById("app")!);
