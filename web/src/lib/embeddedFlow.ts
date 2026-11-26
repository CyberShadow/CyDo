import type { FlowDocument } from "./contentFlow";
import {
  getCachedParsedShellDocument,
  loadParsedShellDocument,
  type ParseResult,
} from "./shellParser";
import { shellFlowDocument } from "./shellSourceTree";

export type EmbeddedLanguage = "bash";

type EmbeddedAnalyzer = {
  peek(text: string): FlowDocument | null | undefined;
  load(text: string): Promise<FlowDocument | null>;
};

function parsedShellFlow(parsed: ParseResult): FlowDocument | null {
  if (!parsed.ok) return null;
  const flow = shellFlowDocument(parsed.document);
  return "ok" in flow ? null : flow;
}

const registry: Record<EmbeddedLanguage, EmbeddedAnalyzer> = {
  bash: {
    peek(text) {
      const parsed = getCachedParsedShellDocument(text);
      return parsed === undefined ? undefined : parsedShellFlow(parsed);
    },
    load(text) {
      return loadParsedShellDocument(text).then(parsedShellFlow, () => null);
    },
  },
};

export function analyzeEmbedded(
  language: EmbeddedLanguage,
  text: string,
): Promise<FlowDocument | null> {
  return registry[language].load(text);
}

export function getCachedEmbeddedAnalysis(
  language: EmbeddedLanguage,
  text: string,
): FlowDocument | null | undefined {
  return registry[language].peek(text);
}
