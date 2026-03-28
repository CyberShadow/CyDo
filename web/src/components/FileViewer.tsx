import { Fragment } from "preact";
import type { CSSProperties, PointerEventHandler } from "preact";
import { memo } from "preact/compat";
import { useMemo, useRef, useState } from "preact/hooks";
import { applyPatch, structuredPatch } from "diff";
import type { Block, FileEdit, TrackedFile } from "../types";
import { useHighlight, langFromPath, renderTokens } from "../highlight";
import type { ThemedToken } from "../highlight";
import { DiffView, PatchView } from "./ToolCall";
import type { PatchHunk } from "./ToolCall";
import { Markdown } from "./Markdown";
import { CopyButton } from "./CopyButton";

// ---------------------------------------------------------------------------
// On-demand content resolution
// ---------------------------------------------------------------------------

/** Resolved file content for a single edit, computed on-demand. */
interface ResolvedEdit {
  contentBefore: string | null;
  contentAfter: string;
  structuredPatch?: unknown[];
  patchText?: string;
  isDeleted?: boolean;
}

/** Resolve the content for a single FileEdit by looking up the tool_use block
 *  directly from the flat block store.  This avoids storing full file contents
 *  in the reducer — content is only computed when the viewer is actually rendering. */
function resolveEditContent(
  edit: FileEdit,
  blocks: Map<string, Block>,
): ResolvedEdit | null {
  if (edit.payload?.mode === "full_content") {
    if (edit.op === "delete") {
      return {
        contentBefore: edit.payload.content,
        contentAfter: "",
        isDeleted: true,
      };
    }
    return { contentBefore: null, contentAfter: edit.payload.content };
  }
  if (edit.payload?.mode === "patch_text") {
    return {
      contentBefore: null,
      contentAfter: "",
      patchText: edit.payload.patchText,
    };
  }

  // Look up the tool_use block directly by toolUseId (O(1)).
  const block = blocks.get(edit.toolUseId);
  if (!block) return null;

  const input = (block.input ?? {}) as Record<string, unknown>;
  const tr = (block.result?.toolResult ?? {}) as Record<string, unknown>;

  const originalFile =
    typeof tr.originalFile === "string" ? tr.originalFile : null;
  const structuredPatch = Array.isArray(tr.structuredPatch)
    ? tr.structuredPatch
    : undefined;

  if (edit.type === "edit") {
    if (originalFile == null) return null;
    const oldString =
      typeof input.old_string === "string" ? input.old_string : "";
    const newString =
      typeof input.new_string === "string" ? input.new_string : "";
    let contentAfter: string;
    if (input.replace_all) {
      contentAfter = originalFile.split(oldString).join(newString);
    } else {
      const idx = originalFile.indexOf(oldString);
      if (idx >= 0) {
        contentAfter =
          originalFile.slice(0, idx) +
          newString +
          originalFile.slice(idx + oldString.length);
      } else {
        contentAfter = originalFile;
      }
    }
    return { contentBefore: originalFile, contentAfter, structuredPatch };
  }

  const contentAfter = typeof input.content === "string" ? input.content : null;
  if (contentAfter == null) return null;
  return {
    contentBefore: originalFile,
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
    let r = resolveEditContent(edit, blocks);
    if (r) {
      resolved.set(i, r);
      if (edit.status !== "applied") continue;
      hasApplied = true;
      if (r.patchText) {
        if (currentContent != null) {
          const directPatch = applyPatch(currentContent, r.patchText);
          let patched: string | false = directPatch;
          if (directPatch === false || directPatch === currentContent) {
            const unifiedPatch = toUnifiedPatch(r.patchText);
            if (unifiedPatch) {
              const fallbackPatch = applyPatch(currentContent, unifiedPatch);
              if (
                typeof fallbackPatch === "string" &&
                fallbackPatch !== currentContent
              ) {
                patched = fallbackPatch;
              }
            }
          }
          if (typeof patched === "string") currentContent = patched;
        }
        continue;
      }
      if (r.isDeleted && currentContent != null && !r.contentBefore) {
        r = { ...r, contentBefore: currentContent };
        resolved.set(i, r);
      }
      if (originalContent == null) originalContent = r.contentBefore ?? "";
      currentContent = r.contentAfter;
      isDeleted = !!r.isDeleted;
      deletedContent = r.isDeleted ? (r.contentBefore ?? "") : null;
    }
  }

  if (!hasApplied) {
    for (let i = file.edits.length - 1; i >= 0; i--) {
      const r = resolved.get(i);
      if (!r || r.patchText) continue;
      currentContent = r.contentAfter;
      if (originalContent == null) originalContent = r.contentBefore ?? "";
      isDeleted = !!r.isDeleted;
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

const ContentViewer = memo(function ContentViewer({
  filePath,
  currentContent,
  originalContent,
  resolvedEdit,
  diffEdit,
  cumulativeContent,
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
  /** Content after applying edits up to and including the selected one (for cumulative diff). */
  cumulativeContent: string;
  isDeleted: boolean;
  deletedContent: string | null;
  viewMode: ViewMode;
  onChangeViewMode: (mode: ViewMode) => void;
}) {
  const isMarkdown = /\.(md|mdx)$/i.test(filePath);
  const content =
    resolvedEdit?.patchText != null
      ? resolvedEdit.patchText
      : resolvedEdit
        ? resolvedEdit.isDeleted
          ? (resolvedEdit.contentBefore ?? "")
          : resolvedEdit.contentAfter
        : isDeleted
          ? (deletedContent ?? originalContent)
          : currentContent;

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
        {viewMode === "source" && (
          <SourceView content={content} filePath={filePath} />
        )}
        {viewMode === "diff" && diffEdit?.patchText && (
          <SourceView
            content={diffEdit.patchText}
            filePath={`${filePath}.patch`}
          />
        )}
        {viewMode === "diff" && diffEdit?.structuredPatch?.length ? (
          <PatchView
            hunks={diffEdit.structuredPatch as PatchHunk[]}
            filePath={filePath}
          />
        ) : (
          viewMode === "diff" &&
          diffEdit &&
          !diffEdit.patchText && (
            <DiffView
              oldStr={diffEdit.contentBefore ?? ""}
              newStr={diffEdit.contentAfter}
              filePath={filePath}
            />
          )
        )}
        {viewMode === "cumulative" && (
          <CumulativeDiff
            oldStr={originalContent}
            newStr={cumulativeContent}
            filePath={filePath}
          />
        )}
        {viewMode === "rendered" && isMarkdown && (
          <Markdown text={content} class="text-content" />
        )}
        {viewMode === "rendered" && !isMarkdown && (
          <SourceView content={content} filePath={filePath} />
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
        if (r && !r.patchText) {
          diffstat = computeDiffstat(r.contentBefore ?? "", r.contentAfter);
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
    () => (file ? resolveFileContent(file, blocks) : null),
    [file, blocks],
  );
  const selectedResolvedEdit =
    file && resolved && selectedEditIndex != null
      ? (resolved.resolved.get(selectedEditIndex) ?? null)
      : null;
  const latestResolvedEdit =
    file && resolved
      ? (resolved.resolved.get(file.edits.length - 1) ?? null)
      : null;
  const cumulativeContent =
    selectedResolvedEdit?.contentAfter ?? resolved?.currentContent ?? "";

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
          ✕
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
