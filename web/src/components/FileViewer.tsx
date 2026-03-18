import { h, Fragment } from "preact";
import { useState } from "preact/hooks";
import type { TrackedFile } from "../types";
import { useHighlight, langFromPath, renderTokens } from "../highlight";
import { DiffView } from "./ToolCall";
import { Markdown } from "./Markdown";

interface FileViewerProps {
  trackedFiles: Map<string, TrackedFile>;
  selectedFile: string | null;
  selectedEditIndex: number | null;
  viewMode: "source" | "diff" | "rendered";
  height: number;
  onSelectFile: (path: string) => void;
  onSelectEdit: (index: number | null) => void;
  onChangeViewMode: (mode: "source" | "diff" | "rendered") => void;
  onClose: () => void;
  onResize: (height: number) => void;
  onScrollToMessage: (messageId: string) => void;
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
      const part = parts[i];
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
      const [childLabel, childNode] = [...node.children.entries()][0];
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
        class={`file-tree-item${selectedFile === node.fullPath ? " selected" : ""}`}
        style={{ "--depth": depth } as any}
        onClick={() => onSelectFile(node.fullPath)}
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
        style={{ "--depth": depth } as any}
        onClick={() => setExpanded(!expanded)}
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
  return (
    <pre class="file-viewer-source">
      {tokenLines
        ? tokenLines.map((line, i) => (
            <Fragment key={i}>
              {i > 0 && "\n"}
              {renderTokens(line)}
            </Fragment>
          ))
        : content}
    </pre>
  );
}

function ContentViewer({
  file,
  selectedEditIndex,
  viewMode,
  onChangeViewMode,
}: {
  file: TrackedFile;
  selectedEditIndex: number | null;
  viewMode: "source" | "diff" | "rendered";
  onChangeViewMode: (mode: "source" | "diff" | "rendered") => void;
}) {
  const isMarkdown = /\.(md|mdx)$/i.test(file.path);
  const edit = selectedEditIndex != null ? file.edits[selectedEditIndex] : null;
  const content = edit ? edit.contentAfter : file.currentContent;

  // Diff content: from edit or last two edits
  let diffOld = "";
  let diffNew = "";
  if (viewMode === "diff") {
    if (edit) {
      diffOld = edit.contentBefore ?? "";
      diffNew = edit.contentAfter;
    } else if (file.edits.length >= 2) {
      const last = file.edits[file.edits.length - 1];
      diffOld = last.contentBefore ?? "";
      diffNew = last.contentAfter;
    } else if (file.edits.length === 1) {
      diffOld = file.edits[0].contentBefore ?? "";
      diffNew = file.edits[0].contentAfter;
    }
  }

  return (
    <div class="content-viewer">
      <div class="content-viewer-tabs">
        <button
          class={viewMode === "source" ? "active" : ""}
          onClick={() => onChangeViewMode("source")}
        >
          Source
        </button>
        <button
          class={viewMode === "diff" ? "active" : ""}
          onClick={() => onChangeViewMode("diff")}
        >
          Diff
        </button>
        {isMarkdown && (
          <button
            class={viewMode === "rendered" ? "active" : ""}
            onClick={() => onChangeViewMode("rendered")}
          >
            Rendered
          </button>
        )}
      </div>
      <div class="content-viewer-body">
        {viewMode === "source" && (
          <SourceView content={content} filePath={file.path} />
        )}
        {viewMode === "diff" && (
          <DiffView oldStr={diffOld} newStr={diffNew} filePath={file.path} />
        )}
        {viewMode === "rendered" && isMarkdown && (
          <Markdown text={content} class="text-content" />
        )}
        {viewMode === "rendered" && !isMarkdown && (
          <SourceView content={content} filePath={file.path} />
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Edit history
// ---------------------------------------------------------------------------

function EditHistory({
  file,
  selectedEditIndex,
  onSelectEdit,
  onScrollToMessage,
}: {
  file: TrackedFile;
  selectedEditIndex: number | null;
  onSelectEdit: (index: number | null) => void;
  onScrollToMessage: (messageId: string) => void;
}) {
  return (
    <div class="edit-history">
      {file.edits.map((edit, i) => (
        <div
          key={i}
          class={`edit-history-item${selectedEditIndex === i ? " selected" : ""}`}
          onClick={() => {
            const deselecting = selectedEditIndex === i;
            onSelectEdit(deselecting ? null : i);
            if (!deselecting) onScrollToMessage(edit.messageId);
          }}
        >
          <span class="edit-history-num">#{i + 1}</span>
          <span class="edit-type">
            {edit.type === "edit" ? "Edit" : "Write"}
          </span>
        </div>
      ))}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Main FileViewer component
// ---------------------------------------------------------------------------

export function FileViewer({
  trackedFiles,
  selectedFile,
  selectedEditIndex,
  viewMode,
  height,
  onSelectFile,
  onSelectEdit,
  onChangeViewMode,
  onClose,
  onResize,
  onScrollToMessage,
}: FileViewerProps) {
  const paths = [...trackedFiles.keys()];
  const treeNodes = buildFileTree(paths);
  const file = selectedFile ? trackedFiles.get(selectedFile) : null;

  const handlePointerDown = (e: PointerEvent) => {
    e.preventDefault();
    const startY = e.clientY;
    const startHeight = height;
    const onMove = (e: PointerEvent) => {
      const delta = e.clientY - startY;
      onResize(Math.max(100, startHeight + delta));
    };
    const onUp = () => {
      document.removeEventListener("pointermove", onMove);
      document.removeEventListener("pointerup", onUp);
    };
    document.addEventListener("pointermove", onMove);
    document.addEventListener("pointerup", onUp);
  };

  return (
    <div class="file-viewer" style={{ height: `${height}px` }}>
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
        {file ? (
          <>
            <ContentViewer
              file={file}
              selectedEditIndex={selectedEditIndex}
              viewMode={viewMode}
              onChangeViewMode={onChangeViewMode}
            />
            <EditHistory
              file={file}
              selectedEditIndex={selectedEditIndex}
              onSelectEdit={onSelectEdit}
              onScrollToMessage={onScrollToMessage}
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
      <div class="resize-handle" onPointerDown={handlePointerDown as any} />
    </div>
  );
}
