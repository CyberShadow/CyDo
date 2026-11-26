import { AsyncLruCache } from "./asyncLruCache";
import { analyzeCodeModeCell } from "./codeModeFlow";
import { resolveFlowLanguage, type FlowDocument } from "./contentFlow";
import { withJavaScriptTree } from "./javascriptParser";
import {
  getCachedParsedShellDocument,
  loadParsedShellDocument,
  type ParseResult,
} from "./shellParser";
import { shellFlowDocument } from "./shellSourceTree";

export type EmbeddedLanguage = "bash" | "codex-code-mode";

type EmbeddedAnalyzer = {
  peek(text: string): FlowDocument | null | undefined;
  load(text: string): Promise<FlowDocument | null>;
};

function parsedShellFlow(parsed: ParseResult): FlowDocument | null {
  if (!parsed.ok) return null;
  const flow = shellFlowDocument(parsed.document);
  return "ok" in flow ? null : flow;
}

const codeModeCache = new AsyncLruCache<FlowDocument>(8);

async function loadCodeModeCell(text: string): Promise<FlowDocument> {
  const document = await withJavaScriptTree(text, (root) =>
    analyzeCodeModeCell(root, text),
  );
  const sources = await Promise.all(
    document.sources.map(async (source) => {
      const { language } = resolveFlowLanguage(source.sinks);
      if (!Object.hasOwn(registry, language)) return source;
      const child = await analyzeEmbedded(
        language as EmbeddedLanguage,
        source.value.text,
      );
      return { ...source, child };
    }),
  );
  return { ...document, sources };
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
  "codex-code-mode": {
    peek(text) {
      return codeModeCache.peek(text);
    },
    load(text) {
      return codeModeCache.load(text, () => loadCodeModeCell(text));
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
