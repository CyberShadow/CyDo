import { useEffect, useState } from "preact/hooks";
import { buildFlowSourceTree } from "./lib/contentFlow";
import {
  analyzeEmbedded,
  getCachedEmbeddedAnalysis,
  type EmbeddedLanguage,
} from "./lib/embeddedFlow";
import type { SourceNode } from "./lib/sourceTree";

type SourceTreeState = {
  text: string | null;
  tree: SourceNode | null;
};

function cachedSourceTree(
  language: EmbeddedLanguage,
  text: string | null,
): SourceNode | null {
  if (text === null) return null;
  const cached = getCachedEmbeddedAnalysis(language, text);
  return cached == null ? null : buildFlowSourceTree(cached);
}

export function useSourceTree(
  language: EmbeddedLanguage,
  text: string | null,
): SourceNode | null {
  const [state, setState] = useState<SourceTreeState>(() => ({
    text,
    tree: cachedSourceTree(language, text),
  }));

  useEffect(() => {
    if (text === null) {
      setState({ text, tree: null });
      return;
    }
    const cached = getCachedEmbeddedAnalysis(language, text);
    if (cached !== undefined) {
      setState({
        text,
        tree: cached === null ? null : buildFlowSourceTree(cached),
      });
      return;
    }

    let active = true;
    void analyzeEmbedded(language, text).then(
      (flow) => {
        if (active) {
          setState({
            text,
            tree: flow === null ? null : buildFlowSourceTree(flow),
          });
        }
      },
      () => {
        if (active) setState({ text, tree: null });
      },
    );
    return () => {
      active = false;
    };
  }, [language, text]);

  if (state.text === text) return state.tree;
  return cachedSourceTree(language, text);
}
