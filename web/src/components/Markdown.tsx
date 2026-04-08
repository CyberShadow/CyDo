import { type FunctionComponent } from "preact";
import { memo } from "preact/compat";
import { useMemo, useRef, useState } from "preact/hooks";
import { createIncremarkParser } from "@incremark/core";
import type { IncremarkParser } from "@incremark/core";
import { useHighlight, renderTokens } from "../highlight";
import { MdastRenderer } from "./MdastRenderer";
import { CodePre } from "./CopyButton";
import sourceOnIcon from "../icons/source-on.svg?raw";
import sourceOffIcon from "../icons/source-off.svg?raw";
export { sourceOnIcon, sourceOffIcon };

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
      } as Parameters<typeof createIncremarkParser>[0]);
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
          onClick={() => {
            setShowRaw(!showRaw);
          }}
          title={showRaw ? "Show rendered" : "Show source"}
        >
          <span
            class="action-icon"
            dangerouslySetInnerHTML={{
              __html: showRaw ? sourceOnIcon : sourceOffIcon,
            }}
          />
        </button>
        {showRaw ? (
          <CodePre class="markdown-source" copyText={text}>
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
          </CodePre>
        ) : (
          <div class={`markdown ${className ?? ""}`}>
            <MdastRenderer ast={ast} />
          </div>
        )}
      </div>
    );
  },
);
