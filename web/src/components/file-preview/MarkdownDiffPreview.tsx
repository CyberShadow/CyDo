import { h, Fragment } from "preact";
import { useMemo } from "preact/hooks";
import HtmlDiff from "htmldiff-js";
import { marked } from "marked";
import { sanitizeHtml } from "../../sanitize";
import { useHighlight, renderTokens } from "../../highlight";
import { DiffView } from "../diff/DiffView";
import { CodePre } from "../CopyButton";
import { SourceRenderedToggle } from "./SourceRenderedToggle";

function renderTokenLines(
  tokens: ReturnType<typeof useHighlight>,
): h.JSX.Element {
  if (!tokens) return <></>;
  return (
    <Fragment>
      {tokens.map((line, index) => (
        <Fragment key={index}>
          {index > 0 && "\n"}
          {renderTokens(line)}
        </Fragment>
      ))}
    </Fragment>
  );
}

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
            {patchTokens ? renderTokenLines(patchTokens) : sourceText}
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
