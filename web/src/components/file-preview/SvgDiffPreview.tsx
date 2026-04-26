import { useMemo } from "preact/hooks";
import { DiffView } from "../diff/DiffView";
import { CodePre } from "../CopyButton";
import { SvgPreview } from "./FileContentPreview";
import { SourceRenderedToggle } from "./SourceRenderedToggle";

export function SvgDiffPreview({
  oldText,
  newText,
  filePath,
  originalFile,
  sourceText,
  defaultSource = true,
}: {
  oldText: string;
  newText: string;
  filePath?: string;
  originalFile?: string | null;
  sourceText?: string;
  defaultSource?: boolean;
}) {
  const fullBefore = originalFile ?? oldText;
  const fullAfter = useMemo(() => {
    if (!originalFile) return newText;
    const index = originalFile.indexOf(oldText);
    if (index < 0) return newText;
    return (
      originalFile.slice(0, index) +
      newText +
      originalFile.slice(index + oldText.length)
    );
  }, [originalFile, oldText, newText]);

  return (
    <SourceRenderedToggle
      defaultSource={defaultSource}
      sourceView={
        sourceText != null ? (
          <CodePre class="write-content" copyText={sourceText}>
            {sourceText}
          </CodePre>
        ) : (
          <DiffView
            oldStr={oldText}
            newStr={newText}
            filePath={filePath ?? "diff.svg"}
          />
        )
      }
      renderedView={
        <div class="svg-diff-preview">
          <div class="svg-diff-side">
            <div class="svg-diff-label">Before</div>
            <SvgPreview content={fullBefore} />
          </div>
          <div class="svg-diff-side">
            <div class="svg-diff-label">After</div>
            <SvgPreview content={fullAfter} />
          </div>
        </div>
      }
    />
  );
}
