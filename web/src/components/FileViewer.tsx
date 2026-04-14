import * as preact from "preact";
import { Fragment } from "preact";
import type { CSSProperties, PointerEventHandler } from "preact";
import { memo } from "preact/compat";
import { useMemo, useRef, useState } from "preact/hooks";
import { applyPatch, structuredPatch } from "diff";
import closeIcon from "../icons/close.svg?raw";
import type { Block, FileEdit, TrackedFile } from "../types";
import { useHighlight, langFromPath, renderTokens } from "../highlight";
import type { ThemedToken } from "../highlight";
import { DiffView, PatchView, parsePatchHunksFromText } from "./ToolCall";
import type { PatchHunk } from "./ToolCall";
import { composeHunks } from "../lib/composeHunks";
import { Markdown } from "./Markdown";
import { CopyButton } from "./CopyButton";

// ---------------------------------------------------------------------------
// On-demand content resolution
// ---------------------------------------------------------------------------

/** Resolved file content for a single edit, computed on-demand. */
interface ResolvedEdit {
  contentBefore: string | null;
  /** null when only patch hunks available (no full content) */
  contentAfter: string | null;
  structuredPatch?: PatchHunk[];
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
  const structuredPatch = Array.isArray(tr.structuredPatch)
    ? (tr.structuredPatch as PatchHunk[])
    : undefined;

  if (edit.payload?.mode === "full_content") {
    if (edit.op === "delete") {
      return {
        contentBefore: currentContent ?? originalFile ?? edit.payload.content,
        contentAfter: "",
        isDeleted: true,
        structuredPatch,
      };
    }
    return {
      contentBefore: currentContent ?? originalFile ?? "",
      contentAfter: edit.payload.content,
      structuredPatch,
    };
  }
  if (edit.payload?.mode === "patch_text") {
    const contentBefore = currentContent ?? originalFile;
    if (contentBefore == null) {
      // No original content available (e.g. Codex fileChange without originalFile).
      // Parse the patch text into structured hunks for partial rendering.
      const hunks = parsePatchHunksFromText(edit.payload.patchText);
      if (hunks && hunks.length > 0) {
        return {
          contentBefore: null,
          contentAfter: null,
          structuredPatch: hunks,
          isDeleted: edit.op === "delete",
        };
      }
      return null;
    }
    const contentAfter = applyTrackedPatch(
      contentBefore,
      edit.payload.patchText,
    );
    if (contentAfter == null) return null;
    return {
      contentBefore,
      contentAfter,
      structuredPatch,
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
    return { contentBefore, contentAfter, structuredPatch };
  }

  const contentAfter = typeof input.content === "string" ? input.content : null;
  if (contentAfter == null) return null;
  return {
    contentBefore: currentContent ?? originalFile ?? "",
    contentAfter,
    structuredPatch,
  };
}

interface ResolvedFileContent {
  /** Content before any edits (first edit's contentBefore, or "" for new files). */
  originalContent: string;
  currentContent: string;
  resolved: Map<number, ResolvedEdit>;
  isDeleted: boolean;
  deletedContent: string | null;
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
  let currentContent: string | null = null;
  let originalContent: string | null = null;
  let isDeleted = false;
  let deletedContent: string | null = null;
  let hasApplied = false;

  for (let i = 0; i < file.edits.length; i++) {
    const edit = file.edits[i]!;
    if (edit.status === "cancelled") continue;
    const r = resolveEditContent(edit, currentContent, blocks, itemIdMap);
    if (!r) continue;
    resolved.set(i, r);
    if (edit.status !== "applied") continue;
    hasApplied = true;
    if (r.contentAfter != null) {
      if (originalContent == null) originalContent = r.contentBefore ?? "";
      currentContent = r.contentAfter;
    }
    isDeleted = !!r.isDeleted;
    deletedContent = r.isDeleted ? (r.contentBefore ?? "") : null;
  }

  if (!hasApplied) {
    for (let i = file.edits.length - 1; i >= 0; i--) {
      const r = resolved.get(i);
      if (!r) continue;
      if (r.contentAfter != null) {
        currentContent = r.contentAfter;
        if (originalContent == null) originalContent = r.contentBefore ?? "";
      }
      isDeleted = !!r.isDeleted;
      deletedContent = r.isDeleted ? (r.contentBefore ?? "") : null;
      break;
    }
  }

  if (currentContent == null) {
    if (resolved.size === 0) return null;
    currentContent = "";
  }
  return {
    originalContent: originalContent ?? "",
    currentContent,
    resolved,
    isDeleted,
    deletedContent,
  };
}

/** Compute line-level diffstat between two strings. */
function computeDiffstat(
  oldStr: string,
  newStr: string,
): { added: number; removed: number } {
  const oldLines = oldStr.split("\n");
  const newLines = newStr.split("\n");
  // Simple line diff: count lines present in new but not old (added) and vice versa.
  // For accuracy we use a set-based approach on indexed lines, but a proper diff
  // would be better.  For a quick stat, compare line counts after a longest-common-
  // subsequence style estimate.  We'll use the simple heuristic: run through both
  // and count net changes.
  const oldSet = new Map<string, number>();
  for (const line of oldLines) oldSet.set(line, (oldSet.get(line) ?? 0) + 1);
  let kept = 0;
  for (const line of newLines) {
    const c = oldSet.get(line);
    if (c && c > 0) {
      oldSet.set(line, c - 1);
      kept++;
    }
  }
  return {
    added: newLines.length - kept,
    removed: oldLines.length - kept,
  };
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

function SourceView({
  content,
  filePath,
}: {
  content: string;
  filePath: string;
}) {
  const lang = langFromPath(filePath);
  const tokenLines = useHighlight(content, lang);
  const renderLines = tokenLines ?? content.split("\n");
  const gutterWidth = `${String(renderLines.length).length}ch`;
  return (
    <div class="code-pre-wrap">
      <CopyButton text={content} />
      <pre class="file-viewer-source">
        {renderLines.map((line, i) => (
          <div key={i} class="source-line">
            <span class="source-gutter" style={{ minWidth: gutterWidth }}>
              {i + 1}
            </span>
            {tokenLines ? renderTokens(line as ThemedToken[]) : line}
          </div>
        ))}
      </pre>
    </div>
  );
}

function CumulativeDiff({
  oldStr,
  newStr,
  filePath,
}: {
  oldStr: string;
  newStr: string;
  filePath: string;
}) {
  const patch = useMemo(
    () =>
      structuredPatch("", "", oldStr, newStr, undefined, undefined, {
        context: 3,
      }),
    [oldStr, newStr],
  );
  return <PatchView hunks={patch.hunks as PatchHunk[]} filePath={filePath} />;
}

function PartialSourceView({
  hunks,
  filePath,
}: {
  hunks: PatchHunk[];
  filePath: string;
}) {
  // Extract the "new" side content from all hunks for syntax highlighting.
  const newLines: string[] = [];
  for (const hunk of hunks) {
    for (const line of hunk.lines) {
      const prefix = line[0];
      if (prefix === " " || prefix === "+") {
        newLines.push(line.slice(1));
      }
    }
  }
  const newText = newLines.join("\n");
  const lang = langFromPath(filePath);
  const tokenLines = useHighlight(newText, lang);

  // Compute max line number for gutter width
  let maxLineNum = 0;
  for (const hunk of hunks) {
    maxLineNum = Math.max(maxLineNum, hunk.newStart + hunk.newLines);
  }
  const gutterWidth = `${String(maxLineNum).length}ch`;

  const elements: preact.JSX.Element[] = [];
  let tokenIdx = 0;
  let prevHunkEnd = 0; // track end of previous hunk to detect gaps

  for (let hi = 0; hi < hunks.length; hi++) {
    const hunk = hunks[hi]!;

    // Gap indicator between non-contiguous hunks
    if (hi > 0 && hunk.newStart > prevHunkEnd + 1) {
      const gapStart = prevHunkEnd + 1;
      const gapEnd = hunk.newStart - 1;
      elements.push(
        <div key={`gap-${hi}`} class="source-gap">
          <span class="source-gutter" style={{ minWidth: gutterWidth }}>
            {gapStart === gapEnd ? `${gapStart}` : `${gapStart}-${gapEnd}`}
          </span>
          <span class="source-gap-label">
            ⋮ {gapEnd - gapStart + 1} lines not available
          </span>
        </div>,
      );
    }

    // Render hunk lines (new side only: context + added)
    let lineNum = hunk.newStart;
    for (const line of hunk.lines) {
      const prefix = line[0];
      if (prefix === "-") continue; // skip removed lines in source view

      const isAdded = prefix === "+";
      const idx = tokenIdx++;
      const num = lineNum++;
      elements.push(
        <div
          key={`${hi}-${num}`}
          class={`source-line${isAdded ? " source-line-added" : ""}`}
        >
          <span class="source-gutter" style={{ minWidth: gutterWidth }}>
            {num}
          </span>
          {tokenLines?.[idx] ? renderTokens(tokenLines[idx]) : line.slice(1)}
        </div>,
      );
    }

    prevHunkEnd = hunk.newStart + hunk.newLines - 1;
  }

  // Gap indicator if first hunk doesn't start at line 1
  if (hunks.length > 0 && hunks[0]!.newStart > 1) {
    elements.unshift(
      <div key="gap-start" class="source-gap">
        <span class="source-gutter" style={{ minWidth: gutterWidth }}>
          1-{hunks[0]!.newStart - 1}
        </span>
        <span class="source-gap-label">
          ⋮ {hunks[0]!.newStart - 1} lines not available
        </span>
      </div>,
    );
  }

  return (
    <div class="code-pre-wrap">
      <pre class="file-viewer-source">{elements}</pre>
    </div>
  );
}

function CumulativeHunkView({
  hunks,
  filePath,
}: {
  hunks: PatchHunk[];
  filePath: string;
}) {
  return <PatchView hunks={hunks} filePath={filePath} />;
}

const ContentViewer = memo(function ContentViewer({
  filePath,
  currentContent,
  originalContent,
  resolvedEdit,
  diffEdit,
  cumulativeContent,
  cumulativeHunks,
  isDeleted,
  deletedContent,
  viewMode,
  onChangeViewMode,
}: {
  filePath: string;
  currentContent: string;
  /** Content before any edits (for cumulative diff baseline). */
  originalContent: string;
  /** Resolved content for the selected edit (null when no edit selected). */
  resolvedEdit: ResolvedEdit | null;
  /** Resolved content for diff view — falls back to last edit when none selected. */
  diffEdit: ResolvedEdit | null;
  /** Content after applying edits up to and including the selected one (null when only hunks available). */
  cumulativeContent: string | null;
  /** Merged cumulative hunks when full content unavailable. */
  cumulativeHunks: PatchHunk[] | null;
  isDeleted: boolean;
  deletedContent: string | null;
  viewMode: ViewMode;
  onChangeViewMode: (mode: ViewMode) => void;
}) {
  const isMarkdown = /\.(md|mdx)$/i.test(filePath);
  const content: string | null = resolvedEdit
    ? resolvedEdit.isDeleted
      ? (resolvedEdit.contentBefore ?? "")
      : resolvedEdit.contentAfter
    : isDeleted
      ? (deletedContent ?? originalContent)
      : currentContent;

  // Hunks for partial rendering when full content unavailable
  const partialHunks =
    content == null ? (resolvedEdit?.structuredPatch ?? null) : null;

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
        {(resolvedEdit?.isDeleted || (!resolvedEdit && isDeleted)) && (
          <div class="file-viewer-empty">File deleted in this change.</div>
        )}
        {viewMode === "source" && content != null && (
          <SourceView content={content} filePath={filePath} />
        )}
        {viewMode === "source" && content == null && partialHunks && (
          <PartialSourceView hunks={partialHunks} filePath={filePath} />
        )}
        {viewMode === "source" && content == null && !partialHunks && (
          <div class="file-viewer-empty">
            Source content not available for this edit.
          </div>
        )}
        {viewMode === "diff" && diffEdit?.structuredPatch?.length ? (
          <PatchView hunks={diffEdit.structuredPatch} filePath={filePath} />
        ) : (
          viewMode === "diff" &&
          diffEdit && (
            <DiffView
              oldStr={diffEdit.contentBefore ?? ""}
              newStr={diffEdit.contentAfter ?? ""}
              filePath={filePath}
            />
          )
        )}
        {viewMode === "diff" && !diffEdit && (
          <div class="file-viewer-empty">No diff available for this edit.</div>
        )}
        {viewMode === "cumulative" && cumulativeContent != null && (
          <CumulativeDiff
            oldStr={originalContent}
            newStr={cumulativeContent}
            filePath={filePath}
          />
        )}
        {viewMode === "cumulative" &&
          cumulativeContent == null &&
          cumulativeHunks && (
            <CumulativeHunkView hunks={cumulativeHunks} filePath={filePath} />
          )}
        {viewMode === "cumulative" &&
          cumulativeContent == null &&
          !cumulativeHunks && (
            <div class="file-viewer-empty">
              Cumulative diff not available — original file content unknown.
            </div>
          )}
        {viewMode === "rendered" && isMarkdown && content != null && (
          <Markdown text={content} class="text-content" />
        )}
        {viewMode === "rendered" && !isMarkdown && content != null && (
          <SourceView content={content} filePath={filePath} />
        )}
        {viewMode === "rendered" && content == null && partialHunks && (
          <PartialSourceView hunks={partialHunks} filePath={filePath} />
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
        if (r) {
          if (r.contentBefore != null && r.contentAfter != null) {
            diffstat = computeDiffstat(r.contentBefore, r.contentAfter);
          } else if (r.structuredPatch?.length) {
            diffstat = computeDiffstatFromHunks(r.structuredPatch);
          }
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
  // cumulativeContent: null when full content is unavailable (triggers hunk-based view)
  const cumulativeContent: string | null =
    selectedResolvedEdit != null
      ? selectedResolvedEdit.contentAfter
      : resolved?.currentContent || null;

  // Build cumulative hunks from all resolved edits' structuredPatch arrays.
  // Only computed when cumulativeContent is unavailable.
  const cumulativeHunks = useMemo(() => {
    if (!file || !resolved) return null;
    if (cumulativeContent != null) return null;

    let cumulative: PatchHunk[] = [];
    const endIdx = selectedEditIndex ?? file.edits.length - 1;
    for (let i = 0; i <= endIdx; i++) {
      const r = resolved.resolved.get(i);
      if (!r?.structuredPatch?.length) continue;
      if (file.edits[i]?.status === "cancelled") continue;
      cumulative = composeHunks(cumulative, r.structuredPatch);
    }
    if (cumulative.length === 0) return null;
    return cumulative;
  }, [file, resolved, cumulativeContent, selectedEditIndex]);

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
              currentContent={resolved.currentContent}
              originalContent={resolved.originalContent}
              resolvedEdit={selectedResolvedEdit}
              diffEdit={selectedResolvedEdit ?? latestResolvedEdit}
              cumulativeContent={cumulativeContent}
              cumulativeHunks={cumulativeHunks}
              viewMode={viewMode}
              isDeleted={resolved.isDeleted}
              deletedContent={resolved.deletedContent}
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
