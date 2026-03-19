import { h, type FunctionComponent } from "preact";
import { memo } from "preact/compat";
import { useMemo, useState } from "preact/hooks";
import { marked } from "marked";
import { useHighlight, renderTokens } from "../highlight";
import { sanitizeHtml } from "../sanitize";

marked.setOptions({
  breaks: true,
  gfm: true,
});

interface Props {
  text: string;
  class?: string;
}

export const Markdown: FunctionComponent<Props> = memo(
  ({ text, class: className }: Props) => {
    const [showRaw, setShowRaw] = useState(false);
    if (!text) return null;
    const html = useMemo(
      () => sanitizeHtml(marked.parse(text, { async: false }) as string),
      [text],
    );
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
          <div
            class={`markdown ${className ?? ""}`}
            dangerouslySetInnerHTML={{ __html: html }}
          />
        )}
      </div>
    );
  },
);
