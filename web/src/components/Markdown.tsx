import { type FunctionComponent } from "preact";
import { memo } from "preact/compat";
import { useMemo, useRef, useState } from "preact/hooks";
import { createIncremarkParser } from "@incremark/core";
import type { IncremarkParser, Root } from "@incremark/core";
import { useHighlight, renderTokens } from "../highlight";
import { MdastRenderer } from "./MdastRenderer";

interface Props {
  text: string;
  class?: string;
}

export const Markdown: FunctionComponent<Props> = memo(
  ({ text, class: className }: Props) => {
    const [showRaw, setShowRaw] = useState(false);
    if (!text) return null;

    const parserRef = useRef<IncremarkParser | null>(null);
    if (!parserRef.current) {
      parserRef.current = createIncremarkParser({
        gfm: true,
        breaks: true,
      } as any);
    }

    const prevTextRef = useRef("");

    const ast = useMemo(() => {
      const parser = parserRef.current!;
      if (text.startsWith(prevTextRef.current)) {
        // Incremental append — only parse the new delta
        const delta = text.slice(prevTextRef.current.length);
        if (delta) {
          const update = parser.append(delta);
          prevTextRef.current = text;
          return update.ast;
        }
        // No new content — return cached AST
        return parser.getAst();
      } else {
        // Full re-render (text changed non-incrementally)
        parser.reset();
        const update = parser.append(text);
        prevTextRef.current = text;
        return update.ast;
      }
    }, [text]);

    const tokens = useHighlight(showRaw ? text : null, "markdown");

    return (
      <div class={`markdown-wrap ${showRaw ? "markdown-raw" : ""}`}>
        <button
          class="markdown-toggle-btn"
          onClick={() => setShowRaw(!showRaw)}
          title={showRaw ? "Show rendered" : "Show source"}
        >
          {showRaw ? "◉" : "◎"}
        </button>
        {showRaw ? (
          <pre class="markdown-source">
            <code>
              {tokens
                ? tokens.map((line, i) => (
                    <span key={i}>
                      {renderTokens(line)}
                      {"\n"}
                    </span>
                  ))
                : text}
            </code>
          </pre>
        ) : (
          <div class={`markdown ${className ?? ""}`}>
            <MdastRenderer ast={ast} />
          </div>
        )}
      </div>
    );
  },
);
