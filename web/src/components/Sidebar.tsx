import { h } from "preact";
import { useEffect, useMemo, useRef } from "preact/hooks";
import type { TaskTypeInfo } from "../useSessionManager";

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
  taskType?: string;
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
  taskTypes: TaskTypeInfo[],
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
            taskTypes,
          ),
        );
      }
    }
    return elements;
  }

  // Status modifier for dot/icon
  let statusClass = "";
  if (t.isProcessing) statusClass = "processing";
  else if (t.alive) statusClass = "alive";
  else if (t.status === "failed") statusClass = "failed";
  else if (t.resumable) statusClass = "resumable";
  else if (t.status === "completed") statusClass = "completed";
  // pending = no extra class (gray)

  const typeInfo = taskTypes.find((tt) => tt.name === t.taskType);
  const icon = typeInfo?.icon;

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
      ) : icon ? (
        <span class={`sidebar-icon${statusClass ? ` ${statusClass}` : ""}`}>{icon}</span>
      ) : (
        <span class={`sidebar-dot${statusClass ? ` ${statusClass}` : ""}`} />
      )}
      <span class="sidebar-label" title={t.title || `Task ${t.tid}`}>
        {t.title || `Task ${t.tid}`}
      </span>
    </div>,
  );

  for (const child of node.children) {
    elements.push(
      ...renderNode(child, depth + 1, activeTaskId, attention, onSelectTask, taskTypes),
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
  taskTypes: TaskTypeInfo[];
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
  taskTypes,
}: Props) {
  const tree = useMemo(() => buildTree(tasks), [tasks]);
  const listRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (activeTaskId === null) return;
    const selector = `.sidebar-item[data-tid="${activeTaskId}"]`;

    // Try to scroll immediately (works when element already exists).
    const el = listRef.current?.querySelector(selector);
    if (el) {
      el.scrollIntoView({ block: "nearest" });
      return;
    }

    // Element doesn't exist yet (initial load). Watch for it to appear.
    if (!listRef.current) return;
    const observer = new MutationObserver(() => {
      const target = listRef.current?.querySelector(selector);
      if (target) {
        target.scrollIntoView({ block: "nearest" });
        observer.disconnect();
      }
    });
    observer.observe(listRef.current, { childList: true, subtree: true });
    return () => observer.disconnect();
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
      <div class="sidebar-list" ref={listRef}>
        <div
          class={`sidebar-item sidebar-new-task${activeTaskId === null ? " active" : ""}`}
          onClick={onNewTask}
        >
          <span class="sidebar-dot new">+</span>
          <span class="sidebar-label">New Task</span>
        </div>
        {tree
          .flatMap((node) =>
            renderNode(node, 0, activeTaskId, attention, onSelectTask, taskTypes),
          )
          .reverse()}
      </div>
    </div>
  );
}
