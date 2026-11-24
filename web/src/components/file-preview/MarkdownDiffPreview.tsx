import { useMemo } from "preact/hooks";
import HtmlDiff from "htmldiff-js";
import { marked } from "marked";
import { sanitizeHtml } from "../../sanitize";
import { useHighlight, renderHighlightedSource } from "../../highlight";
import { DiffView } from "../diff/DiffView";
import { CodePre } from "../CopyButton";
import { SourceRenderedToggle } from "./SourceRenderedToggle";

export function MarkdownDiffPreview({
  oldText,
  newText,
  filePath,
  sourceText,
  defaultSource = true,
}: {
  oldText: string;
  newText: string;
  filePath?: string;
  sourceText?: string;
  defaultSource?: boolean;
}) {
  const diffHtml = useMemo(() => {
    const oldHtml = marked.parse(oldText, { async: false });
    const newHtml = marked.parse(newText, { async: false });
    return sanitizeHtml(HtmlDiff.execute(oldHtml, newHtml));
  }, [oldText, newText]);

  const patchTokens = useHighlight(sourceText ?? "", "diff");

  return (
    <SourceRenderedToggle
      defaultSource={defaultSource}
      sourceView={
        sourceText != null ? (
          <CodePre class="write-content" copyText={sourceText}>
            {renderHighlightedSource(sourceText, patchTokens)}
          </CodePre>
        ) : (
          <DiffView oldStr={oldText} newStr={newText} filePath={filePath} />
        )
      }
      renderedView={
        <div
          class="markdown markdown-diff"
          dangerouslySetInnerHTML={{ __html: diffHtml }}
        />
      }
    />
  );
}
