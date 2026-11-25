import { useHighlight, renderHighlightedSource } from "../../highlight";
import {
  parseApplyPatchSections,
  parsePatchHunksFromText,
} from "../../lib/patches";
import { ResultPre } from "../ResultPre";
import { HunkDiffView } from "./DiffView";
import { DiffWithToggle } from "./DiffWithToggle";

function extractStructuredDiffText(content: string): string {
  const gitDiffStart = content.search(/^diff --git /m);
  if (gitDiffStart >= 0) return content.slice(gitDiffStart);
  return content;
}

export function DiffResult({ content }: { content: string }) {
  const tokens = useHighlight(content, "diff");
  const structuredContent = extractStructuredDiffText(content);
  const sections = parseApplyPatchSections(structuredContent);

  if (sections.length > 0) {
    const showMeta = sections.length > 1;
    return (
      <DiffWithToggle rawText={content}>
        <div class="filechange-list">
          {sections.map((section, i) => {
            const hunks = parsePatchHunksFromText(section.patchText);
            if (!hunks || hunks.length === 0) return null;
            return (
              <div key={i} class="filechange-change">
                {showMeta && (
                  <div class="tool-input-field filechange-meta">
                    <span class="tool-subtitle-tag">{section.op}</span>
                    <span class="tool-subtitle-path">{section.path}</span>
                  </div>
                )}
                <HunkDiffView hunks={hunks} filePath={section.path} />
              </div>
            );
          })}
        </div>
      </DiffWithToggle>
    );
  }

  const hunks = parsePatchHunksFromText(structuredContent);
  if (hunks && hunks.length > 0) {
    return (
      <DiffWithToggle rawText={content}>
        <HunkDiffView hunks={hunks} />
      </DiffWithToggle>
    );
  }

  return (
    <ResultPre content={content}>
      {renderHighlightedSource(content, tokens)}
    </ResultPre>
  );
}
