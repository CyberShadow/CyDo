import { h } from "preact";
import { useMemo } from "preact/hooks";

export interface SidebarTask {
  tid: number;
  alive: boolean;
  resumable: boolean;
  isProcessing: boolean;
  title?: string;
  parentTid?: number;
  relationType?: string;
  status?: string;
}

interface TreeNode {
  task: SidebarTask;
  children: TreeNode[];
}

export function flatTaskOrder(tasks: SidebarTask[]): number[] {
  const tids: number[] = [];
  function walk(nodes: TreeNode[]) {
    for (const n of nodes) {
      tids.push(n.task.tid);
      walk(n.children);
    }
  }
  walk(buildTree(tasks));
  return tids;
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
      task: t,
      children: toNodes(childMap.get(t.tid) || []),
    }));
  }

  return toNodes(roots);
}

function renderNode(
  node: TreeNode,
  depth: number,
  activeTaskId: number | null,
  attention: Set<number>,
  onSelectTask: (tid: number) => void,
): h.JSX.Element[] {
  const t = node.task;
  const elements: h.JSX.Element[] = [];

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
      key={t.tid}
      class={`sidebar-item${t.tid === activeTaskId ? " active" : ""}${attention.has(t.tid) ? " attention" : ""}`}
      data-tid={t.tid}
      style={depth > 0 ? { paddingLeft: `${8 + depth * 16}px` } : undefined}
      onClick={() => onSelectTask(t.tid)}
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
  activeTaskId: number | null;
  attention: Set<number>;
  onSelectTask: (tid: number) => void;
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
        <button class="sidebar-new-btn" onClick={onNewTask} title="New task">
          +
        </button>
      </div>
      <div class="sidebar-list">
        {tree.flatMap((node) =>
          renderNode(node, 0, activeTaskId, attention, onSelectTask),
        )}
      </div>
    </div>
  );
}
