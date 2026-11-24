import type { ComponentChildren } from "preact";
import { useHighlight, renderHighlightedSource } from "../../highlight";
import { CodePre } from "../CopyButton";
import { SourceRenderedToggle } from "../file-preview/SourceRenderedToggle";

export function DiffWithToggle({
  children,
  rawText,
  rawLanguage = "diff",
  defaultSource = false,
}: {
  children: ComponentChildren;
  rawText: string;
  rawLanguage?: string;
  defaultSource?: boolean;
}) {
  const tokens = useHighlight(rawText, rawLanguage);
  return (
    <SourceRenderedToggle
      defaultSource={defaultSource}
      sourceView={
        <CodePre class="write-content" copyText={rawText}>
          {renderHighlightedSource(rawText, tokens)}
        </CodePre>
      }
      renderedView={<>{children}</>}
    />
  );
}
