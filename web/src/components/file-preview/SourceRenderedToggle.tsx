import { h } from "preact";
import { useState } from "preact/hooks";
import { sourceOnIcon, sourceOffIcon } from "../Markdown";

export function SourceRenderedToggle({
  defaultSource,
  sourceView,
  renderedView,
}: {
  defaultSource: boolean;
  sourceView: h.JSX.Element;
  renderedView: h.JSX.Element;
}) {
  const [showSource, setShowSource] = useState(defaultSource);
  return (
    <div class="markdown-diff-wrap">
      <button
        class="markdown-toggle-btn"
        onClick={() => {
          setShowSource(!showSource);
        }}
        title={showSource ? "Show rendered" : "Show source"}
      >
        <span
          class="action-icon"
          dangerouslySetInnerHTML={{
            __html: showSource ? sourceOnIcon : sourceOffIcon,
          }}
        />
      </button>
      {showSource ? sourceView : renderedView}
    </div>
  );
}
