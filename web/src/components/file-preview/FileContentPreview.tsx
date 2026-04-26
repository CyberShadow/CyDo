import { h, Fragment } from "preact";
import { useHighlight, langFromPath, renderTokens } from "../../highlight";
import { detectRenderableFormat } from "../../lib/fileFormats";
import { CodePre } from "../CopyButton";
import { Markdown } from "../Markdown";
import { SourceRenderedToggle } from "./SourceRenderedToggle";

/** Render an array of token lines (no trailing newline). */
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

/** Inline SVG rendered from raw SVG content string. */
export function SvgPreview({ content }: { content: string }) {
  const dataUri = `data:image/svg+xml,${encodeURIComponent(content.trim())}`;
  return (
    <div class="tool-result-images">
      <img src={dataUri} alt="SVG preview" class="tool-result-image" />
    </div>
  );
}

export function FileContentPreview({
  filePath,
  content,
  defaultSource = false,
}: {
  filePath?: string;
  content: string;
  defaultSource?: boolean;
}) {
  const format = detectRenderableFormat(filePath, content);
  const lang = filePath ? langFromPath(filePath) : null;
  const codeTokens = useHighlight(content, format === "markdown" ? null : lang);

  const sourceView = (
    <CodePre class="write-content" copyText={content}>
      {codeTokens ? renderTokenLines(codeTokens) : content}
    </CodePre>
  );

  if (format === "markdown") {
    return <Markdown text={content} class="write-content-markdown" />;
  }

  if (format === "svg") {
    return (
      <SourceRenderedToggle
        defaultSource={defaultSource}
        sourceView={sourceView}
        renderedView={<SvgPreview content={content} />}
      />
    );
  }

  return sourceView;
}
