export {};

import type { ParseResult } from "./lib/shellParser";

type ShellParserBridge = (source: string) => Promise<ParseResult>;

declare global {
  interface Window {
    __cydoE2e?: {
      fork?: (tid: number, anchor: string) => void;
      undo?: (
        tid: number,
        anchor: string,
        dryRun: boolean,
        revertConversation: boolean,
        revertFiles: boolean,
      ) => void;
      parseShell?: ShellParserBridge;
    };
  }
}

export function installShellParserE2eBridge(
  loadParsedShellDocument: ShellParserBridge,
): void {
  if (window.__cydoE2e === undefined) return;
  window.__cydoE2e.parseShell = loadParsedShellDocument;
}
