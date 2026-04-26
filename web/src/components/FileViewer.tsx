import * as preact from "preact";
import { Fragment } from "preact";
import type { CSSProperties, PointerEventHandler } from "preact";
import { memo } from "preact/compat";
import { useMemo, useRef, useState } from "preact/hooks";
import { applyPatch, structuredPatch } from "diff";
import closeIcon from "../icons/close.svg?raw";
import type { Block, FileEdit, TrackedFile } from "../types";
import { useHighlight, langFromPath, renderTokens } from "../highlight";
import { PatchView, parsePatchHunksFromText } from "./ToolCall";
import type { PatchHunk } from "./ToolCall";
import { composeHunks } from "../lib/composeHunks";
import { Markdown } from "./Markdown";
import { CopyButton } from "./CopyButton";

// ---------------------------------------------------------------------------
// SourceContent types and helpers
// ---------------------------------------------------------------------------

/** A contiguous block of known file content at a known position. */
interface SourceFragment {
  startLine: number; // 1-indexed
  lines: string[]; // raw content lines (no diff prefix)
}

/** A view of file content as positioned fragments.
 *  `complete: true` means fragments cover the entire file.
 *  `complete: false` means there may be unknown content before/between/after
 *  fragments — gap indicators should be shown. */
interface SourceContent {
  fragments: SourceFragment[];
  complete: boolean;
}

function contentToSource(content: string): SourceContent {
  return {
    fragments: [{ startLine: 1, lines: content.split("\n") }],
    complete: true,
  };
}

function hunksToSource(hunks: PatchHunk[]): SourceContent {
  const fragments: SourceFragment[] = [];
  for (const hunk of hunks) {
    const lines: string[] = [];
    for (const line of hunk.lines) {
      if (line[0] === " " || line[0] === "+") lines.push(line.slice(1));
    }
    if (lines.length > 0) fragments.push({ startLine: hunk.newStart, lines });
  }
  return { fragments, complete: false };
}

function hunksToOldSource(hunks: PatchHunk[]): SourceContent {
  const fragments: SourceFragment[] = [];
  for (const hunk of hunks) {
    const lines: string[] = [];
    for (const line of hunk.lines) {
      if (line[0] === " " || line[0] === "-") lines.push(line.slice(1));
    }
    if (lines.length > 0) fragments.push({ startLine: hunk.oldStart, lines });
  }
  return { fragments, complete: false };
}

function sourceToContent(source: SourceContent): string | null {
  if (!source.complete) return null;
  if (source.fragments.length !== 1) return null;
  return source.fragments[0]!.lines.join("\n");
}

function computeHunksFromStrings(oldStr: string, newStr: string): PatchHunk[] {
  if (oldStr === newStr) return [];
  const patch = structuredPatch("", "", oldStr, newStr, undefined, undefined, {
    context: 3,
  });
  return patch.hunks as PatchHunk[];
}

// ---------------------------------------------------------------------------
// On-demand content resolution
// ---------------------------------------------------------------------------

/** Resolved file content for a single edit, computed on-demand. */
interface ResolvedEdit {
  sourceAfter: SourceContent;
  sourceBefore: SourceContent;
  patchHunks: PatchHunk[];
  isDeleted?: boolean;
}

function getBlockForEdit(
  edit: FileEdit,
  blocks: Map<string, Block>,
  itemIdMap: Map<string, string>,
): Block | null {
  const blockKey = itemIdMap.get(edit.toolUseId) ?? edit.toolUseId;
  return blocks.get(blockKey) ?? null;
}

function applyTrackedPatch(content: string, patchText: string): string | null {
  const directPatch = applyPatch(content, patchText);
  if (typeof directPatch === "string" && directPatch !== content) {
    return directPatch;
  }

  const unifiedPatch = toUnifiedPatch(patchText);
  if (!unifiedPatch) {
    return typeof directPatch === "string" ? directPatch : null;
  }

  const fallbackPatch = applyPatch(content, unifiedPatch);
  return typeof fallbackPatch === "string"
    ? fallbackPatch
    : typeof directPatch === "string"
      ? directPatch
      : null;
}

/** Resolve the content for a single FileEdit by looking up the tool_use block
 *  directly from the flat block store.  This avoids storing full file contents
 *  in the reducer — content is only computed when the viewer is actually rendering. */
function resolveEditContent(
  edit: FileEdit,
  currentContent: string | null,
  blocks: Map<string, Block>,
  itemIdMap: Map<string, string>,
): ResolvedEdit | null {
  const block = getBlockForEdit(edit, blocks, itemIdMap);
  const input = (block?.input ?? {}) as Record<string, unknown>;
  const tr = (block?.result?.toolResult ?? {}) as Record<string, unknown>;
  const originalFile =
    typeof tr.originalFile === "string" ? tr.originalFile : null;
  const trStructuredPatch = Array.isArray(tr.structuredPatch)
    ? (tr.structuredPatch as PatchHunk[])
    : undefined;

  if (edit.payload?.mode === "full_content") {
    if (edit.op === "delete") {
      const beforeStr = currentContent ?? originalFile ?? edit.payload.content;
      const afterStr = "";
      const hunks =
        trStructuredPatch ?? computeHunksFromStrings(beforeStr, afterStr);
      return {
        sourceBefore: contentToSource(beforeStr),
        sourceAfter: contentToSource(afterStr),
        patchHunks: hunks,
        isDeleted: true,
      };
    }
    const beforeStr = currentContent ?? originalFile ?? "";
    const afterStr = edit.payload.content;
    const hunks =
      trStructuredPatch ?? computeHunksFromStrings(beforeStr, afterStr);
    return {
      sourceBefore: contentToSource(beforeStr),
      sourceAfter: contentToSource(afterStr),
      patchHunks: hunks,
    };
  }

  if (edit.payload?.mode === "patch_text") {
    const contentBefore = currentContent ?? originalFile;
    if (contentBefore == null) {
      // No original content available (e.g. Codex fileChange without originalFile).
      // Parse the patch text into structured hunks for partial rendering.
      const hunks = parsePatchHunksFromText(edit.payload.patchText);
      if (!hunks?.length) return null;
      return {
        sourceBefore: hunksToOldSource(hunks),
        sourceAfter: hunksToSource(hunks),
        patchHunks: hunks,
        isDeleted: edit.op === "delete",
      };
    }
    const contentAfter = applyTrackedPatch(
      contentBefore,
      edit.payload.patchText,
    );
    if (contentAfter == null) return null;
    const hunks =
      trStructuredPatch ??
      parsePatchHunksFromText(edit.payload.patchText) ??
      computeHunksFromStrings(contentBefore, contentAfter);
    return {
      sourceBefore: contentToSource(contentBefore),
      sourceAfter: contentToSource(contentAfter),
      patchHunks: hunks,
    };
  }

  if (!block) return null;

  if (edit.type === "edit") {
    const contentBefore = currentContent ?? originalFile;
    if (contentBefore == null) return null;
    const oldString =
      typeof input.old_string === "string" ? input.old_string : "";
    const newString =
      typeof input.new_string === "string" ? input.new_string : "";
    let contentAfter: string;
    if (input.replace_all) {
      contentAfter = contentBefore.split(oldString).join(newString);
    } else {
      const idx = contentBefore.indexOf(oldString);
      if (idx >= 0) {
        contentAfter =
          contentBefore.slice(0, idx) +
          newString +
          contentBefore.slice(idx + oldString.length);
      } else {
        contentAfter = contentBefore;
      }
    }
    const hunks =
      trStructuredPatch ?? computeHunksFromStrings(contentBefore, contentAfter);
    return {
      sourceBefore: contentToSource(contentBefore),
      sourceAfter: contentToSource(contentAfter),
      patchHunks: hunks,
    };
  }

  const contentAfter = typeof input.content === "string" ? input.content : null;
  if (contentAfter == null) return null;
  const beforeStr = currentContent ?? originalFile ?? "";
  const hunks =
    trStructuredPatch ?? computeHunksFromStrings(beforeStr, contentAfter);
  return {
    sourceBefore: contentToSource(beforeStr),
    sourceAfter: contentToSource(contentAfter),
    patchHunks: hunks,
  };
}

interface ResolvedFileContent {
  originalSource: SourceContent;
  currentSource: SourceContent;
  resolved: Map<number, ResolvedEdit>;
  isDeleted: boolean;
  deletedSource: SourceContent | null;
}

function toUnifiedPatch(patchText: string): string | null {
  const lines = patchText.split("\n");
  if (lines.length === 0) return null;
  const header = lines[0]!;
  if (!header.startsWith("*** Update File: ")) return null;
  const path = header.slice("*** Update File: ".length).trim();
  if (!path) return null;

  // Parse hunks to get proper line numbers; bare @@ headers (no numbers) are
  // not accepted by the diff library's applyPatch, so we rebuild them.
  const hunks = parsePatchHunksFromText(patchText);
  if (hunks && hunks.length > 0) {
    const hunkParts = hunks.map(
      (h) =>
        `@@ -${h.oldStart},${h.oldLines} +${h.newStart},${h.newLines} @@\n${h.lines.join("\n")}`,
    );
    return `--- a/${path}\n+++ b/${path}\n${hunkParts.join("\n")}\n`;
  }

  const bodyLines: string[] = [];
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i]!;
    if (
      line.startsWith("*** Begin Patch") ||
      line.startsWith("*** End Patch")
    ) {
      continue;
    }
    bodyLines.push(line);
  }
  const body = bodyLines.join("\n");
  return `--- a/${path}\n+++ b/${path}\n${body}\n`;
}

/** Resolve all edits for a file and return the current (latest) content. */
function resolveFileContent(
  file: TrackedFile,
  blocks: Map<string, Block>,
  itemIdMap: Map<string, string>,
): ResolvedFileContent | null {
  const resolved = new Map<number, ResolvedEdit>();
  let currentContent: string | null = null; // for chaining resolveEditContent
  let currentSource: SourceContent | null = null; // for display
  let originalSource: SourceContent | null = null;
  let isDeleted = false;
  let deletedSource: SourceContent | null = null;
  let hasApplied = false;

  for (let i = 0; i < file.edits.length; i++) {
    const edit = file.edits[i]!;
    if (edit.status === "cancelled") continue;
    const r = resolveEditContent(edit, currentContent, blocks, itemIdMap);
    if (!r) continue;
    resolved.set(i, r);
    if (edit.status !== "applied") continue;
    hasApplied = true;

    currentSource = r.sourceAfter;
    // Only chain full content forward; partial edits don't break prior chain
    const newContent = sourceToContent(r.sourceAfter);
    if (newContent != null) {
      if (originalSource == null) originalSource = r.sourceBefore;
      currentContent = newContent;
    }
    isDeleted = !!r.isDeleted;
    deletedSource = r.isDeleted ? r.sourceBefore : null;
  }

  if (!hasApplied) {
    for (let i = file.edits.length - 1; i >= 0; i--) {
      const r = resolved.get(i);
      if (!r) continue;
      currentSource = r.sourceAfter;
      const newContent = sourceToContent(r.sourceAfter);
      if (newContent != null) {
        if (originalSource == null) originalSource = r.sourceBefore;
      }
      isDeleted = !!r.isDeleted;
      deletedSource = r.isDeleted ? r.sourceBefore : null;
      break;
    }
  }

  if (currentSource == null) {
    if (resolved.size === 0) return null;
    currentSource = contentToSource("");
  }

  return {
    originalSource: originalSource ?? contentToSource(""),
    currentSource,
    resolved,
    isDeleted,
    deletedSource,
  };
}

function composeResolvedHunksThrough(
  file: TrackedFile,
  resolvedEdits: Map<number, ResolvedEdit>,
  endIdx: number,
): PatchHunk[] | null {
  let cumulative: PatchHunk[] = [];
  for (let i = 0; i <= endIdx; i++) {
    const r = resolvedEdits.get(i);
    if (!r?.patchHunks.length) continue;
    if (file.edits[i]?.status === "cancelled") continue;
    cumulative = composeHunks(cumulative, r.patchHunks);
  }
  return cumulative.length === 0 ? null : cumulative;
}

function collectedSourceThrough(
  source: SourceContent,
  file: TrackedFile,
  resolvedEdits: Map<number, ResolvedEdit>,
  endIdx: number,
): SourceContent {
  if (source.complete) return source;
  const cumulative = composeResolvedHunksThrough(file, resolvedEdits, endIdx);
  return cumulative ? hunksToSource(cumulative) : source;
}

function computeDiffstatFromHunks(hunks: PatchHunk[]): {
  added: number;
  removed: number;
} {
  let added = 0;
  let removed = 0;
  for (const hunk of hunks) {
    for (const line of hunk.lines) {
      if (line[0] === "+") added++;
      else if (line[0] === "-") removed++;
    }
  }
  return { added, removed };
}

// ---------------------------------------------------------------------------
// Props
// ---------------------------------------------------------------------------

type ViewMode = "source" | "diff" | "cumulative" | "rendered";

interface FileViewerProps {
  trackedFiles: Map<string, TrackedFile>;
  blocks: Map<string, Block>;
  selectedFile: string | null;
  selectedEditIndex: number | null;
  viewMode: ViewMode;
  height: number;
  itemIdMap: Map<string, string>;
  onSelectFile: (path: string) => void;
  onSelectEdit: (index: number | null) => void;
  onChangeViewMode: (mode: ViewMode) => void;
  onClose: () => void;
  onResize: (height: number) => void;
  onScrollToToolCall: (toolUseId: string) => void;
}

// ---------------------------------------------------------------------------
// File tree
// ---------------------------------------------------------------------------

interface TreeNode {
  label: string;
  fullPath: string;
  isLeaf: boolean;
  children: TreeNode[];
}

function buildFileTree(paths: string[]): TreeNode[] {
  interface RawNode {
    children: Map<string, RawNode>;
    filePath?: string;
  }

  const root: RawNode = { children: new Map() };

  for (const path of paths) {
    const parts = path.split("/").filter(Boolean);
    let node = root;
    for (let i = 0; i < parts.length; i++) {
      const part = parts[i]!;
      if (!node.children.has(part)) {
        node.children.set(part, { children: new Map() });
      }
      node = node.children.get(part)!;
      if (i === parts.length - 1) {
        node.filePath = path;
      }
    }
  }

  function convertLeaf(node: RawNode, label: string): TreeNode {
    const childNodes: TreeNode[] = [];
    for (const [childLabel, childNode] of node.children) {
      childNodes.push(convertCoalescing(childNode, childLabel));
    }
    childNodes.sort((a, b) => {
      if (!a.isLeaf && b.isLeaf) return -1;
      if (a.isLeaf && !b.isLeaf) return 1;
      return a.label.localeCompare(b.label);
    });
    return {
      label,
      fullPath: node.filePath ?? "",
      isLeaf: !!node.filePath && node.children.size === 0,
      children: childNodes,
    };
  }

  function convertCoalescing(node: RawNode, label: string): TreeNode {
    if (node.filePath && node.children.size === 0) {
      return { label, fullPath: node.filePath, isLeaf: true, children: [] };
    }
    // Single-child non-leaf: coalesce
    if (node.children.size === 1 && !node.filePath) {
      const [childLabel, childNode] = [...node.children.entries()][0]!;
      const merged = convertCoalescing(childNode, childLabel);
      return { ...merged, label: `${label}/${merged.label}` };
    }
    return convertLeaf(node, label);
  }

  const rootChildren: TreeNode[] = [];
  for (const [childLabel, childNode] of root.children) {
    rootChildren.push(convertCoalescing(childNode, childLabel));
  }
  rootChildren.sort((a, b) => {
    if (!a.isLeaf && b.isLeaf) return -1;
    if (a.isLeaf && !b.isLeaf) return 1;
    return a.label.localeCompare(b.label);
  });
  return rootChildren;
}

function FileTreeNode({
  node,
  depth,
  selectedFile,
  onSelectFile,
}: {
  node: TreeNode;
  depth: number;
  selectedFile: string | null;
  onSelectFile: (path: string) => void;
}) {
  const [expanded, setExpanded] = useState(true);

  if (node.isLeaf) {
    return (
      <div
        class={`file-tree-item${
          selectedFile === node.fullPath ? " selected" : ""
        }`}
        style={{ "--depth": depth } as CSSProperties}
        onClick={() => {
          onSelectFile(node.fullPath);
        }}
        title={node.fullPath}
      >
        {node.label}
      </div>
    );
  }

  return (
    <Fragment>
      <div
        class="file-tree-item directory"
        style={{ "--depth": depth } as CSSProperties}
        onClick={() => {
          setExpanded(!expanded);
        }}
      >
        {expanded ? "\u25BE" : "\u25B8"} {node.label}
      </div>
      {expanded &&
        node.children.map((child, i) => (
          <FileTreeNode
            key={i}
            node={child}
            depth={depth + 1}
            selectedFile={selectedFile}
            onSelectFile={onSelectFile}
          />
        ))}
    </Fragment>
  );
}

// ---------------------------------------------------------------------------
// Content viewer
// ---------------------------------------------------------------------------

function gapElement(
  key: string,
  gapStart: number,
  gapEnd: number,
  gutterWidth: string,
) {
  return (
    <div key={key} class="source-gap">
      <span class="source-gutter" style={{ minWidth: gutterWidth }}>
        {gapStart === gapEnd ? `${gapStart}` : `${gapStart}-${gapEnd}`}
      </span>
      <span class="source-gap-label">
        ⋮ {gapEnd - gapStart + 1} lines not available
      </span>
    </div>
  );
}

function FragmentSourceView({
  source,
  filePath,
}: {
  source: SourceContent;
  filePath: string;
}) {
  const { fragments, complete } = source;

  if (fragments.length === 0) {
    return (
      <div class="file-viewer-empty">
        Source content not available for this edit.
      </div>
    );
  }

  // Concatenate all fragment lines for syntax highlighting
  const allLines: string[] = [];
  for (const frag of fragments) {
    allLines.push(...frag.lines);
  }
  const text = allLines.join("\n");
  const lang = langFromPath(filePath);
  const tokenLines = useHighlight(text, lang);

  // Compute max line number for gutter width
  let maxLineNum = 0;
  for (const frag of fragments) {
    maxLineNum = Math.max(maxLineNum, frag.startLine + frag.lines.length - 1);
  }
  const gutterWidth = `${String(maxLineNum).length}ch`;

  const elements: preact.JSX.Element[] = [];
  let tokenIdx = 0;
  let prevEnd = 0; // end line of previous fragment (0 = none)

  for (let fi = 0; fi < fragments.length; fi++) {
    const frag = fragments[fi]!;

    // Gap indicator before this fragment
    if (fi === 0 && frag.startLine > 1) {
      elements.push(
        gapElement(`gap-start`, 1, frag.startLine - 1, gutterWidth),
      );
    } else if (fi > 0 && frag.startLine > prevEnd + 1) {
      elements.push(
        gapElement(`gap-${fi}`, prevEnd + 1, frag.startLine - 1, gutterWidth),
      );
    }

    // Render fragment lines
    for (let li = 0; li < frag.lines.length; li++) {
      const lineNum = frag.startLine + li;
      const idx = tokenIdx++;
      elements.push(
        <div key={`${fi}-${lineNum}`} class="source-line">
          <span class="source-gutter" style={{ minWidth: gutterWidth }}>
            {lineNum}
          </span>
          {tokenLines?.[idx] ? renderTokens(tokenLines[idx]) : frag.lines[li]}
        </div>,
      );
    }

    prevEnd = frag.startLine + frag.lines.length - 1;
  }

  // Trailing gap indicator when content is incomplete
  if (!complete) {
    elements.push(
      <div key="gap-end" class="source-gap">
        <span class="source-gutter" style={{ minWidth: gutterWidth }} />
        <span class="source-gap-label">⋮</span>
      </div>,
    );
  }

  return (
    <div class="code-pre-wrap">
      {complete && <CopyButton text={text} />}
      <pre class="file-viewer-source">{elements}</pre>
    </div>
  );
}

function FragmentMarkdownView({
  source,
  filePath,
}: {
  source: SourceContent;
  filePath: string;
}) {
  const { fragments, complete } = source;

  if (fragments.length === 0) {
    return (
      <div class="file-viewer-empty">
        Rendered content not available for this edit.
      </div>
    );
  }

  const isMarkdown = /\.(md|mdx)$/i.test(filePath);
  if (!isMarkdown) {
    return <FragmentSourceView source={source} filePath={filePath} />;
  }

  // Full content: single Markdown render (no gaps)
  if (complete && fragments.length === 1) {
    return (
      <Markdown text={fragments[0]!.lines.join("\n")} class="text-content" />
    );
  }

  // Partial: render each fragment through Markdown with gap indicators
  const elements: preact.JSX.Element[] = [];
  let prevEnd = 0;

  for (let fi = 0; fi < fragments.length; fi++) {
    const frag = fragments[fi]!;

    if (fi === 0 && frag.startLine > 1) {
      elements.push(
        <div key="gap-start" class="source-gap">
          ⋮ Lines 1-{frag.startLine - 1} not available
        </div>,
      );
    } else if (fi > 0 && frag.startLine > prevEnd + 1) {
      elements.push(
        <div key={`gap-${fi}`} class="source-gap">
          ⋮ {frag.startLine - prevEnd - 1} lines not available
        </div>,
      );
    }

    elements.push(
      <Markdown
        key={`md-${fi}`}
        text={frag.lines.join("\n")}
        class="text-content"
      />,
    );
    prevEnd = frag.startLine + frag.lines.length - 1;
  }

  // Trailing gap indicator when content is incomplete
  if (!complete) {
    elements.push(
      <div key="gap-end" class="source-gap">
        ⋮
      </div>,
    );
  }

  return <>{elements}</>;
}

const ContentViewer = memo(function ContentViewer({
  filePath,
  displaySource,
  diffHunks,
  cumulativeHunks,
  isDeleted,
  viewMode,
  onChangeViewMode,
}: {
  filePath: string;
  displaySource: SourceContent;
  diffHunks: PatchHunk[] | null;
  cumulativeHunks: PatchHunk[] | null;
  isDeleted: boolean;
  viewMode: ViewMode;
  onChangeViewMode: (mode: ViewMode) => void;
}) {
  const isMarkdown = /\.(md|mdx)$/i.test(filePath);

  return (
    <div class="content-viewer">
      <div class="content-viewer-tabs">
        <button
          class={viewMode === "source" ? "active" : ""}
          onClick={() => {
            onChangeViewMode("source");
          }}
        >
          Source
        </button>
        <button
          class={viewMode === "diff" ? "active" : ""}
          onClick={() => {
            onChangeViewMode("diff");
          }}
        >
          Diff
        </button>
        <button
          class={viewMode === "cumulative" ? "active" : ""}
          onClick={() => {
            onChangeViewMode("cumulative");
          }}
        >
          Cumulative
        </button>
        {isMarkdown && (
          <button
            class={viewMode === "rendered" ? "active" : ""}
            onClick={() => {
              onChangeViewMode("rendered");
            }}
          >
            Rendered
          </button>
        )}
      </div>
      <div class="content-viewer-body">
        {isDeleted && (
          <div class="file-viewer-empty">File deleted in this change.</div>
        )}
        {viewMode === "source" && (
          <FragmentSourceView source={displaySource} filePath={filePath} />
        )}
        {viewMode === "diff" && diffHunks && diffHunks.length > 0 && (
          <PatchView hunks={diffHunks} filePath={filePath} />
        )}
        {viewMode === "diff" && (!diffHunks || diffHunks.length === 0) && (
          <div class="file-viewer-empty">No diff available for this edit.</div>
        )}
        {viewMode === "cumulative" &&
          cumulativeHunks &&
          cumulativeHunks.length > 0 && (
            <PatchView hunks={cumulativeHunks} filePath={filePath} />
          )}
        {viewMode === "cumulative" &&
          (!cumulativeHunks || cumulativeHunks.length === 0) && (
            <div class="file-viewer-empty">No cumulative changes.</div>
          )}
        {viewMode === "rendered" && (
          <FragmentMarkdownView source={displaySource} filePath={filePath} />
        )}
      </div>
    </div>
  );
});

// ---------------------------------------------------------------------------
// Edit history
// ---------------------------------------------------------------------------

function EditHistory({
  file,
  resolvedEdits,
  selectedEditIndex,
  onSelectEdit,
  onScrollToToolCall,
}: {
  file: TrackedFile;
  resolvedEdits: Map<number, ResolvedEdit>;
  selectedEditIndex: number | null;
  onSelectEdit: (index: number | null) => void;
  onScrollToToolCall: (toolUseId: string) => void;
}) {
  return (
    <div class="edit-history">
      {file.edits.map((edit, i) => {
        const r = resolvedEdits.get(i);
        let diffstat: { added: number; removed: number } | null = null;
        if (r && r.patchHunks.length > 0) {
          diffstat = computeDiffstatFromHunks(r.patchHunks);
        }
        const label =
          edit.op === "delete"
            ? "Delete"
            : edit.op === "add"
              ? "Add"
              : edit.op === "update"
                ? "Patch"
                : edit.type === "edit"
                  ? "Edit"
                  : "Write";
        return (
          <div
            key={i}
            class={`edit-history-item${
              selectedEditIndex === i ? " selected" : ""
            }${edit.status ? ` ${edit.status}` : ""}`}
            onClick={() => {
              const deselecting = selectedEditIndex === i;
              onSelectEdit(deselecting ? null : i);
              if (!deselecting) onScrollToToolCall(edit.toolUseId);
            }}
          >
            <span class="edit-history-num">#{i + 1}</span>
            <span class="edit-type">{label}</span>
            {edit.status && <span class="edit-status">{edit.status}</span>}
            {diffstat && (
              <span class="edit-diffstat">
                {diffstat.added > 0 && (
                  <span class="diffstat-added">+{diffstat.added}</span>
                )}
                {diffstat.removed > 0 && (
                  <span class="diffstat-removed">-{diffstat.removed}</span>
                )}
              </span>
            )}
          </div>
        );
      })}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Main FileViewer component
// ---------------------------------------------------------------------------

export function FileViewer({
  trackedFiles,
  blocks,
  selectedFile,
  selectedEditIndex,
  viewMode,
  height,
  itemIdMap,
  onSelectFile,
  onSelectEdit,
  onChangeViewMode,
  onClose,
  onResize,
  onScrollToToolCall,
}: FileViewerProps) {
  const paths = [...trackedFiles.keys()];
  const treeNodes = buildFileTree(paths);
  const file = selectedFile ? trackedFiles.get(selectedFile) : null;
  const containerRef = useRef<HTMLDivElement>(null);

  // Resolve file content on-demand — only computed when the viewer is open
  // and a file is selected.  useMemo ensures we don't recompute on every render
  // unless the file or messages actually change.
  const resolved = useMemo(
    () => (file ? resolveFileContent(file, blocks, itemIdMap) : null),
    [file, blocks, itemIdMap],
  );
  const selectedResolvedEdit =
    file && resolved && selectedEditIndex != null
      ? (resolved.resolved.get(selectedEditIndex) ?? null)
      : null;
  let latestResolvedEdit: ResolvedEdit | null = null;
  if (file && resolved) {
    for (let i = file.edits.length - 1; i >= 0; i--) {
      const edit = resolved.resolved.get(i);
      if (edit) {
        latestResolvedEdit = edit;
        break;
      }
    }
  }

  const selectedDisplaySource: SourceContent | null = selectedResolvedEdit
    ? selectedResolvedEdit.isDeleted
      ? selectedResolvedEdit.sourceBefore
      : selectedResolvedEdit.sourceAfter
    : null;

  // Compute displaySource for Source/Rendered tabs
  const displaySource: SourceContent = selectedDisplaySource
    ? selectedDisplaySource.complete
      ? selectedDisplaySource
      : file && resolved && selectedEditIndex != null
        ? collectedSourceThrough(
            selectedDisplaySource,
            file,
            resolved.resolved,
            selectedEditIndex,
          )
        : { fragments: [], complete: true }
    : resolved
      ? resolved.isDeleted
        ? (resolved.deletedSource ?? resolved.originalSource)
        : file
          ? collectedSourceThrough(
              resolved.currentSource,
              file,
              resolved.resolved,
              file.edits.length - 1,
            )
          : resolved.currentSource
      : { fragments: [], complete: true };

  // Compute diffHunks for Diff tab
  const diffEdit = selectedResolvedEdit ?? latestResolvedEdit;
  const diffHunks = diffEdit?.patchHunks ?? null;

  // Compute cumulativeHunks for Cumulative tab — always via composeHunks
  const cumulativeHunks = useMemo(() => {
    if (!file || !resolved) return null;
    const endIdx = selectedEditIndex ?? file.edits.length - 1;
    return composeResolvedHunksThrough(file, resolved.resolved, endIdx);
  }, [file, resolved, selectedEditIndex]);

  const handlePointerDown = (e: PointerEvent) => {
    e.preventDefault();
    const startY = e.clientY;
    const startHeight = height;
    const onMove = (e: PointerEvent) => {
      const newHeight = Math.max(100, startHeight + (e.clientY - startY));
      if (containerRef.current) {
        containerRef.current.style.height = `${newHeight}px`;
      }
    };
    const onUp = (e: PointerEvent) => {
      document.removeEventListener("pointermove", onMove);
      document.removeEventListener("pointerup", onUp);
      const finalHeight = Math.max(100, startHeight + (e.clientY - startY));
      onResize(finalHeight);
    };
    document.addEventListener("pointermove", onMove);
    document.addEventListener("pointerup", onUp);
  };

  return (
    <div
      ref={containerRef}
      class="file-viewer"
      style={{ height: `${height}px` }}
    >
      <div class="file-viewer-header">
        <span>Files</span>
        <button class="file-viewer-close" onClick={onClose} title="Close">
          <span
            class="action-icon"
            dangerouslySetInnerHTML={{ __html: closeIcon }}
          />
        </button>
      </div>
      <div class="file-viewer-content">
        <div class="file-tree">
          {treeNodes.map((node, i) => (
            <FileTreeNode
              key={i}
              node={node}
              depth={0}
              selectedFile={selectedFile}
              onSelectFile={onSelectFile}
            />
          ))}
        </div>
        {file && resolved ? (
          <>
            <ContentViewer
              filePath={file.path}
              displaySource={displaySource}
              diffHunks={diffHunks}
              cumulativeHunks={cumulativeHunks}
              isDeleted={
                selectedResolvedEdit
                  ? !!selectedResolvedEdit.isDeleted
                  : resolved.isDeleted
              }
              viewMode={viewMode}
              onChangeViewMode={onChangeViewMode}
            />
            <EditHistory
              file={file}
              resolvedEdits={resolved.resolved}
              selectedEditIndex={selectedEditIndex}
              onSelectEdit={onSelectEdit}
              onScrollToToolCall={onScrollToToolCall}
            />
          </>
        ) : (
          <div class="content-viewer">
            <div class="file-viewer-empty">
              Select a file to view its content
            </div>
          </div>
        )}
      </div>
      <div
        class="resize-handle"
        onPointerDown={handlePointerDown as PointerEventHandler<HTMLDivElement>}
      />
    </div>
  );
}
