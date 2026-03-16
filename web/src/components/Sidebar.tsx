import { h } from "preact";
import { useEffect, useMemo } from "preact/hooks";

export interface SidebarTask {
  tid: number;
  alive: boolean;
  resumable: boolean;
  isProcessing: boolean;
  title?: string;
  parentTid?: number;
  relationType?: string;
  status?: string;
  archived?: boolean;
  isArchiveNode?: boolean;
}

interface TreeNode {
  id: string;
  task: SidebarTask;
  children: TreeNode[];
}

export function flatTaskOrder(tasks: SidebarTask[]): string[] {
  const ids: string[] = [];
  function walk(nodes: TreeNode[]) {
    for (const n of nodes) {
      ids.push(n.id);
      walk(n.children);
    }
  }
  walk(buildTree(tasks));
  return ids;
}

function insertArchiveNodes(nodes: TreeNode[]): TreeNode[] {
  return nodes.map((node) => {
    const processed = insertArchiveNodes(node.children);
    const archived = processed.filter((c) => c.task.archived);
    const active = processed.filter((c) => !c.task.archived);
    if (archived.length === 0) {
      return { ...node, children: active };
    }
    const archiveNode: TreeNode = {
      id: `archive:${node.task.tid}`,
      task: {
        tid: 0,
        alive: false,
        resumable: false,
        isProcessing: false,
        title: "Archive",
        status: "completed",
        isArchiveNode: true,
      },
      children: archived,
    };
    return { ...node, children: [archiveNode, ...active] };
  });
}

function buildTree(tasks: SidebarTask[]): TreeNode[] {
  const tidSet = new Set(tasks.map((t) => t.tid));
  const childMap = new Map<number, SidebarTask[]>();
  const roots: SidebarTask[] = [];

  for (const t of tasks) {
    if (t.parentTid && tidSet.has(t.parentTid)) {
      const children = childMap.get(t.parentTid) || [];
      children.push(t);
      childMap.set(t.parentTid, children);
    } else {
      roots.push(t);
    }
  }

  function toNodes(list: SidebarTask[]): TreeNode[] {
    return list.map((t) => ({
      id: String(t.tid),
      task: t,
      children: toNodes(childMap.get(t.tid) || []),
    }));
  }

  let tree = toNodes(roots);
  tree = insertArchiveNodes(tree);

  // Handle archived roots
  const archivedRoots = tree.filter((n) => n.task.archived);
  const activeRoots = tree.filter((n) => !n.task.archived);
  if (archivedRoots.length > 0) {
    const archiveRoot: TreeNode = {
      id: "archive",
      task: {
        tid: 0,
        alive: false,
        resumable: false,
        isProcessing: false,
        title: "Archive",
        status: "completed",
        isArchiveNode: true,
      },
      children: archivedRoots,
    };
    tree = [archiveRoot, ...activeRoots];
  }

  return tree;
}

function hasDescendant(node: TreeNode, id: string): boolean {
  for (const c of node.children) {
    if (c.id === id || hasDescendant(c, id)) return true;
  }
  return false;
}

function renderNode(
  node: TreeNode,
  depth: number,
  activeTaskId: string | null,
  attention: Set<number>,
  onSelectTask: (id: string) => void,
): h.JSX.Element[] {
  const t = node.task;
  const elements: h.JSX.Element[] = [];

  if (t.isArchiveNode) {
    const isSelected = node.id === activeTaskId;
    const isExpanded =
      isSelected ||
      (activeTaskId !== null && hasDescendant(node, activeTaskId));
    elements.push(
      <div
        key={node.id}
        class={`sidebar-item sidebar-archive-node${isSelected ? " active" : ""}`}
        data-tid={node.id}
        style={depth > 0 ? { paddingLeft: `${8 + depth * 16}px` } : undefined}
        onClick={() => onSelectTask(node.id)}
      >
        <span class="sidebar-label">Archive ({node.children.length})</span>
      </div>,
    );
    if (isExpanded) {
      for (const child of node.children) {
        elements.push(
          ...renderNode(
            child,
            depth + 1,
            activeTaskId,
            attention,
            onSelectTask,
          ),
        );
      }
    }
    return elements;
  }

  // Status dot class based on task status
  let dotClass = "sidebar-dot";
  if (t.isProcessing) dotClass += " processing";
  else if (t.alive) dotClass += " alive";
  else if (t.status === "failed") dotClass += " failed";
  else if (t.resumable) dotClass += " resumable";
  else if (t.status === "completed") dotClass += " completed";
  // pending = no extra class (gray)

  elements.push(
    <div
      key={node.id}
      class={`sidebar-item${node.id === activeTaskId ? " active" : ""}${attention.has(t.tid) ? " attention" : ""}`}
      data-tid={node.id}
      style={depth > 0 ? { paddingLeft: `${8 + depth * 16}px` } : undefined}
      onClick={() => onSelectTask(node.id)}
    >
      {depth > 0 && (
        <span class="sidebar-relation-icon" title={t.relationType || "child"}>
          ↳
        </span>
      )}
      {attention.has(t.tid) ? (
        <span class="sidebar-dot check">&#x2713;</span>
      ) : (
        <span class={dotClass} />
      )}
      <span class="sidebar-label" title={t.title || `Task ${t.tid}`}>
        {t.title || `Task ${t.tid}`}
      </span>
    </div>,
  );

  for (const child of node.children) {
    elements.push(
      ...renderNode(child, depth + 1, activeTaskId, attention, onSelectTask),
    );
  }

  return elements;
}

interface Props {
  tasks: SidebarTask[];
  activeTaskId: string | null;
  attention: Set<number>;
  onSelectTask: (id: string) => void;
  onNewTask: () => void;
  showBackButton?: boolean;
  onBack?: () => void;
  projectName?: string;
}

export function Sidebar({
  tasks,
  activeTaskId,
  attention,
  onSelectTask,
  onNewTask,
  showBackButton,
  onBack,
  projectName,
}: Props) {
  const tree = useMemo(() => buildTree(tasks), [tasks]);

  useEffect(() => {
    if (activeTaskId === null) return;
    const el = document.querySelector(
      `.sidebar-item[data-tid="${activeTaskId}"]`,
    );
    if (el) {
      el.scrollIntoView({ block: "nearest" });
    } else {
      // Element may not exist yet on initial load; retry once after render.
      requestAnimationFrame(() =>
        document
          .querySelector(`.sidebar-item[data-tid="${activeTaskId}"]`)
          ?.scrollIntoView({ block: "nearest" }),
      );
    }
  }, [activeTaskId]);

  return (
    <div class="sidebar">
      <div class="sidebar-header">
        {showBackButton && onBack && (
          <button
            class="sidebar-back-btn"
            onClick={onBack}
            title="Back to home"
          >
            ←
          </button>
        )}
        <span class="sidebar-title">{projectName || "Tasks"}</span>
      </div>
      <div class="sidebar-list">
        <div
          class={`sidebar-item sidebar-new-task${activeTaskId === null ? " active" : ""}`}
          onClick={onNewTask}
        >
          <span class="sidebar-dot new">+</span>
          <span class="sidebar-label">New Task</span>
        </div>
        {tree
          .flatMap((node) =>
            renderNode(node, 0, activeTaskId, attention, onSelectTask),
          )
          .reverse()}
      </div>
    </div>
  );
}
