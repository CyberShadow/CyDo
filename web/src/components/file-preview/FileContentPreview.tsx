import {
  useHighlight,
  renderHighlightedSource,
  langFromPath,
} from "../../highlight";
import { detectRenderableFormat } from "../../lib/fileFormats";
import { CodePre } from "../CopyButton";
import { Markdown } from "../Markdown";
import { SourceRenderedToggle } from "./SourceRenderedToggle";

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
  sourceContent,
  defaultSource = false,
}: {
  filePath?: string;
  content: string;
  sourceContent?: string;
  defaultSource?: boolean;
}) {
  const format = detectRenderableFormat(filePath, content);
  const lang = filePath ? langFromPath(filePath) : null;
  const sourceText = sourceContent ?? content;
  const sourceLang = format === "markdown" ? "markdown" : lang;
  const codeTokens = useHighlight(sourceText, sourceLang);

  const sourceView = (
    <CodePre class="write-content" copyText={sourceText}>
      {renderHighlightedSource(sourceText, codeTokens)}
    </CodePre>
  );

  if (format === "markdown") {
    return (
      <SourceRenderedToggle
        defaultSource={defaultSource}
        sourceView={sourceView}
        renderedView={
          <Markdown
            text={content}
            class="write-content-markdown"
            enableSourceToggle={false}
          />
        }
      />
    );
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
