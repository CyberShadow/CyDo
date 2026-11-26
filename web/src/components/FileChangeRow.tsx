import viewFileIcon from "../icons/view-file.svg?raw";
import {
  langFromPath,
  renderHighlightedSource,
  useHighlight,
} from "../highlight";
import {
  getApplyPatchFileChanges,
  type NormalizedFileChange,
} from "../lib/fileChanges";
import {
  detectRenderableFormat,
  isMarkdownPath,
  isSvgPath,
  looksLikeSvg,
} from "../lib/fileFormats";
import { looksLikePatchText, type PatchHunk } from "../lib/patches";
import { CodePre } from "./CopyButton";
import { DiffView, HunkDiffView } from "./diff/DiffView";
import { FileContentPreview } from "./file-preview/FileContentPreview";
import { MarkdownDiffPreview } from "./file-preview/MarkdownDiffPreview";
import { SourceRenderedToggle } from "./file-preview/SourceRenderedToggle";
import { SvgDiffPreview } from "./file-preview/SvgDiffPreview";
import { PathDisplay } from "./PathDisplay";

function deriveHunkTextPair(
  hunks: PatchHunk[] | undefined,
): { oldText: string; newText: string } | null {
  if (!hunks || hunks.length === 0) return null;
  const oldLines: string[] = [];
  const newLines: string[] = [];
  for (const hunk of hunks) {
    for (const line of hunk.lines) {
      const prefix = line[0];
      const content = line.slice(1);
      if (prefix === " " || prefix === "-") oldLines.push(content);
      if (prefix === " " || prefix === "+") newLines.push(content);
    }
  }
  if (oldLines.length === 0 && newLines.length === 0) return null;
  return { oldText: oldLines.join("\n"), newText: newLines.join("\n") };
}

function hasSufficientPatchContextForRenderedPreview(
  hunks: PatchHunk[] | undefined,
): boolean {
  if (!hunks || hunks.length === 0) return false;
  const first = hunks[0]!;
  if (first.oldStart !== 1 || first.newStart !== 1) return false;

  let expectedOldStart = 1;
  let expectedNewStart = 1;
  let sawContextLine = false;
  for (const hunk of hunks) {
    if (
      hunk.oldStart !== expectedOldStart ||
      hunk.newStart !== expectedNewStart
    ) {
      return false;
    }
    for (const line of hunk.lines) {
      if (line.startsWith(" ")) {
        sawContextLine = true;
        break;
      }
    }
    expectedOldStart += Math.max(hunk.oldLines, 1);
    expectedNewStart += Math.max(hunk.newLines, 1);
  }
  return sawContextLine;
}

function ChangePatchFallback({ change }: { change: NormalizedFileChange }) {
  const patchText = change.patchText ?? "";
  const tokens = useHighlight(patchText, "diff");
  return (
    <CodePre class="write-content" copyText={patchText}>
      {renderHighlightedSource(patchText, tokens)}
    </CodePre>
  );
}

function ApplyPatchFallback({ patchText }: { patchText: string }) {
  const patchTokens = useHighlight(patchText, "diff");
  return (
    <CodePre class="write-content" copyText={patchText}>
      {renderHighlightedSource(patchText, patchTokens)}
    </CodePre>
  );
}

export function ViewFileButton({
  path,
  onViewFile,
}: {
  path: string;
  onViewFile: (filePath: string) => void;
}) {
  return (
    <button
      class="tool-view-file"
      onClick={(e) => {
        e.stopPropagation();
        onViewFile(path);
      }}
      title="View file"
    >
      <span
        class="action-icon"
        dangerouslySetInnerHTML={{ __html: viewFileIcon }}
      />
    </button>
  );
}

export function FileChangeRow({
  change,
  showMeta,
  preservePatchSource = false,
  onViewFile,
}: {
  change: NormalizedFileChange;
  showMeta: boolean;
  preservePatchSource?: boolean;
  onViewFile?: (filePath: string) => void;
}) {
  const path = change.path ?? undefined;
  const renderableContentFormat = detectRenderableFormat(path, change.content);
  const canRenderAddedContent =
    change.op === "add" &&
    typeof change.content === "string" &&
    renderableContentFormat != null;
  const patchTextPair = deriveHunkTextPair(change.patchHunks);
  const hasRenderablePatchContext = hasSufficientPatchContextForRenderedPreview(
    change.patchHunks,
  );
  const canRenderPatchMarkdown =
    isMarkdownPath(path) &&
    patchTextPair != null &&
    (patchTextPair.oldText.length > 0 || patchTextPair.newText.length > 0) &&
    hasRenderablePatchContext;
  const canRenderPatchSvg =
    isSvgPath(path) &&
    patchTextPair != null &&
    looksLikeSvg(patchTextPair.oldText) &&
    looksLikeSvg(patchTextPair.newText) &&
    hasRenderablePatchContext;
  const canRenderDiffMarkdown =
    typeof change.oldText === "string" &&
    typeof change.newText === "string" &&
    isMarkdownPath(path);
  const canRenderDiffSvg =
    typeof change.oldText === "string" &&
    typeof change.newText === "string" &&
    isSvgPath(path);
  const contentText = change.content ?? "";
  const contentLang = looksLikePatchText(contentText)
    ? "diff"
    : path
      ? langFromPath(path)
      : null;
  const contentTokens = useHighlight(contentText, contentLang);
  const shouldSuppressContentFallback =
    preservePatchSource && typeof change.patchText === "string";

  return (
    <div class="filechange-change">
      {showMeta && (
        <div class="tool-input-field filechange-meta">
          <span class="tool-subtitle-tag">{change.label}</span>
          <FileChangePathDisplay path={change.path} />
          {change.path && onViewFile && (
            <ViewFileButton path={change.path} onViewFile={onViewFile} />
          )}
        </div>
      )}
      {canRenderAddedContent &&
      preservePatchSource &&
      typeof change.patchText === "string" ? (
        <SourceRenderedToggle
          defaultSource={false}
          sourceView={<ChangePatchFallback change={change} />}
          renderedView={
            <FileContentPreview
              filePath={path}
              content={change.content ?? ""}
              defaultSource={false}
            />
          }
        />
      ) : canRenderAddedContent ? (
        <FileContentPreview
          filePath={path}
          content={change.content ?? ""}
          defaultSource={false}
        />
      ) : null}
      {!canRenderAddedContent && canRenderDiffMarkdown && (
        <MarkdownDiffPreview
          oldText={change.oldText ?? ""}
          newText={change.newText ?? ""}
          filePath={path}
          defaultSource={true}
        />
      )}
      {!canRenderAddedContent && canRenderDiffSvg && (
        <SvgDiffPreview
          oldText={change.oldText ?? ""}
          newText={change.newText ?? ""}
          filePath={path}
          defaultSource={true}
        />
      )}
      {!canRenderAddedContent &&
        !canRenderDiffMarkdown &&
        !canRenderDiffSvg &&
        typeof change.oldText === "string" &&
        typeof change.newText === "string" && (
          <DiffView
            oldStr={change.oldText}
            newStr={change.newText}
            filePath={path}
          />
        )}
      {!canRenderAddedContent && canRenderPatchMarkdown && (
        <MarkdownDiffPreview
          oldText={patchTextPair.oldText}
          newText={patchTextPair.newText}
          filePath={path}
          sourceText={preservePatchSource ? change.patchText : undefined}
          defaultSource={true}
        />
      )}
      {!canRenderAddedContent && canRenderPatchSvg && (
        <SvgDiffPreview
          oldText={patchTextPair.oldText}
          newText={patchTextPair.newText}
          filePath={path}
          sourceText={preservePatchSource ? change.patchText : undefined}
          defaultSource={true}
        />
      )}
      {!canRenderAddedContent &&
        !canRenderPatchMarkdown &&
        !canRenderPatchSvg &&
        !preservePatchSource &&
        change.patchHunks &&
        change.patchHunks.length > 0 && (
          <HunkDiffView hunks={change.patchHunks} filePath={path} />
        )}
      {!canRenderAddedContent &&
        !canRenderPatchMarkdown &&
        !canRenderPatchSvg &&
        typeof change.patchText === "string" &&
        (preservePatchSource ||
          !change.patchHunks ||
          change.patchHunks.length === 0) && (
          <ChangePatchFallback change={change} />
        )}
      {!canRenderAddedContent &&
        typeof change.content === "string" &&
        typeof change.oldText !== "string" &&
        !canRenderDiffMarkdown &&
        !canRenderDiffSvg &&
        !canRenderPatchMarkdown &&
        !canRenderPatchSvg &&
        !shouldSuppressContentFallback &&
        renderableContentFormat != null && (
          <FileContentPreview
            filePath={path}
            content={change.content}
            defaultSource={false}
          />
        )}
      {!canRenderAddedContent &&
        typeof change.content === "string" &&
        typeof change.oldText !== "string" &&
        renderableContentFormat == null &&
        !canRenderDiffMarkdown &&
        !canRenderDiffSvg &&
        !canRenderPatchMarkdown &&
        !canRenderPatchSvg &&
        !shouldSuppressContentFallback && (
          <CodePre class="write-content" copyText={change.content}>
            {renderHighlightedSource(change.content, contentTokens)}
          </CodePre>
        )}
    </div>
  );
}

export function FileChangePathDisplay({
  path,
}: {
  path: string | null | undefined;
}) {
  if (!path) return <span class="tool-subtitle-path">(unknown file)</span>;
  return <PathDisplay path={path} />;
}

export function ApplyPatchChanges({
  patchText,
  alwaysShowMeta,
}: {
  patchText: string;
  alwaysShowMeta: boolean;
}) {
  const changes = getApplyPatchFileChanges({ input: patchText });
  if (changes.length === 0) return <ApplyPatchFallback patchText={patchText} />;
  const showMeta = alwaysShowMeta || changes.length > 1;
  return (
    <div class="filechange-list">
      {changes.map((change, i) => (
        <FileChangeRow
          key={i}
          change={change}
          showMeta={showMeta}
          preservePatchSource={true}
        />
      ))}
    </div>
  );
}
