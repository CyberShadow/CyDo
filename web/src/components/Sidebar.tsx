import { memo } from "preact/compat";
import { useCallback, useEffect, useMemo, useRef } from "preact/hooks";
import type { TaskTypeInfo } from "../useSessionManager";
import { ensureIconStyles } from "./TaskTypeIcon";
import relSubtaskIcon from "../icons/rel-subtask.svg?raw";
import relForkIcon from "../icons/rel-fork.svg?raw";
import relUndoBackupIcon from "../icons/rel-undo-backup.svg?raw";
import relContinuationIcon from "../icons/rel-continuation.svg?raw";

const relationIcons: Record<string, string> = {
  subtask: relSubtaskIcon,
  fork: relForkIcon,
  "undo-backup": relUndoBackupIcon,
  continuation: relContinuationIcon,
};

function toMaskUri(raw: string): string {
  const mask = raw.replace(/currentColor/g, "black");
  return `url("data:image/svg+xml,${encodeURIComponent(mask)}")`;
}

let relationStylesInjected = false;
function ensureRelationIconStyles() {
  if (relationStylesInjected) return;
  relationStylesInjected = true;
  const rules = Object.entries(relationIcons)
    .map(([name, raw]) => {
      const uri = toMaskUri(raw);
      return `.relation-icon-${CSS.escape(name)}{mask-image:${uri};-webkit-mask-image:${uri}}`;
    })
    .join("\n");
  const style = document.createElement("style");
  style.textContent = rules;
  document.head.appendChild(style);
}

const ROW_HEIGHT = 31;
const COL_WIDTH = 20;
const LINE_X = 8;
const JUNCTION_Y = ROW_HEIGHT / 2;

function TreeGuide({ hasLine }: { hasLine: boolean }) {
  return (
    <svg
      viewBox={`0 0 ${COL_WIDTH} ${ROW_HEIGHT}`}
      width={COL_WIDTH}
      height={ROW_HEIGHT}
    >
      {hasLine && (
        <line
          x1={LINE_X + 0.5}
          y1={0}
          x2={LINE_X + 0.5}
          y2={ROW_HEIGHT}
          stroke="var(--border)"
          stroke-width={1}
        />
      )}
    </svg>
  );
}

function TreeJunction({
  isLast,
  relationType,
}: {
  isLast: boolean;
  relationType?: string;
}) {
  const hasIcon = relationType != null && relationType in relationIcons;
  return (
    <span
      style={{
        position: "relative",
        width: COL_WIDTH,
        height: ROW_HEIGHT,
        flexShrink: 0,
      }}
    >
      <svg
        viewBox={`0 0 ${COL_WIDTH} ${ROW_HEIGHT}`}
        width={COL_WIDTH}
        height={ROW_HEIGHT}
        style={{ position: "absolute", top: 0, left: 0 }}
      >
        <line
          x1={LINE_X + 0.5}
          y1={0}
          x2={LINE_X + 0.5}
          y2={isLast ? JUNCTION_Y : ROW_HEIGHT}
          stroke="var(--border)"
          stroke-width={1}
        />
        <line
          x1={LINE_X + 0.5}
          y1={JUNCTION_Y}
          x2={COL_WIDTH}
          y2={JUNCTION_Y}
          stroke="var(--border)"
          stroke-width={1}
        />
      </svg>
      {hasIcon && (
        <span
          class={`relation-icon relation-icon-${relationType}`}
          style={{
            position: "absolute",
            left: LINE_X - 7,
            top: "50%",
            transform: "translateY(-50%)",
          }}
          title={relationType}
        />
      )}
    </span>
  );
}

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
  hasPendingQuestion?: boolean;
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

// --- Flattened data item for memoized rendering ---

interface FlatItem {
  id: string;
  tid: number;
  depth: number;
  guides: number; // bitmask: bit i set = vertical line at depth i
  relationType?: string;
  statusClass: string;
  title: string;
  iconName?: string;
  isArchive: boolean;
  hasPendingQuestion: boolean;
}

function computeStatusClass(t: SidebarTask): string {
  if (t.isProcessing) return t.status === "waiting" ? "waiting" : "processing";
  if (t.alive) return "alive";
  if (t.status === "failed") return "failed";
  if (t.resumable) return "resumable";
  if (t.status === "completed") return "completed";
  return "";
}

function flattenTree(
  tree: TreeNode[],
  activeTaskId: string | null,
  taskTypes: TaskTypeInfo[],
): FlatItem[] {
  const items: FlatItem[] = [];

  function walk(node: TreeNode, depth: number, guides: number) {
    const t = node.task;

    if (t.isArchiveNode) {
      items.push({
        id: node.id,
        tid: t.tid,
        depth,
        guides,
        statusClass: "",
        title: `Archive (${node.children.length})`,
        isArchive: true,
        hasPendingQuestion: false,
      });
      const isExpanded =
        node.id === activeTaskId ||
        (activeTaskId !== null && hasDescendant(node, activeTaskId));
      if (isExpanded) {
        for (let i = 0; i < node.children.length; i++) {
          const isLast = i === node.children.length - 1;
          walk(
            node.children[i]!,
            depth + 1,
            isLast ? guides : guides | (1 << depth),
          );
        }
      }
      return;
    }

    const typeInfo = taskTypes.find((tt) => tt.name === t.taskType);
    items.push({
      id: node.id,
      tid: t.tid,
      depth,
      guides,
      relationType: t.relationType,
      statusClass: computeStatusClass(t),
      title: t.title || `Task ${t.tid}`,
      iconName: typeInfo?.icon ?? t.taskType,
      isArchive: false,
      hasPendingQuestion: !!t.hasPendingQuestion,
    });

    for (let i = 0; i < node.children.length; i++) {
      const isLast = i === node.children.length - 1;
      walk(
        node.children[i]!,
        depth + 1,
        isLast ? guides : guides | (1 << depth),
      );
    }
  }

  for (const node of tree) walk(node, 0, 0);
  return items;
}

// --- Memoized sidebar item ---

const SidebarItem = memo(function SidebarItem({
  id,
  depth,
  guides,
  relationType,
  statusClass,
  title,
  iconName,
  isArchive,
  isActive,
  hasAttention,
  hasPendingQuestion,
  onSelect,
  onArchive,
}: {
  id: string;
  depth: number;
  guides: number;
  relationType?: string;
  statusClass: string;
  title: string;
  iconName?: string;
  isArchive: boolean;
  isActive: boolean;
  hasAttention: boolean;
  hasPendingQuestion: boolean;
  onSelect: (id: string) => void;
  onArchive?: (tid: number) => void;
}) {
  const treeConnectors =
    depth > 0 ? (
      <span class="tree-connectors">
        {Array.from({ length: depth - 1 }, (_, i) => (
          <TreeGuide key={i} hasLine={(guides & (1 << i)) !== 0} />
        ))}
        <TreeJunction
          isLast={(guides & (1 << (depth - 1))) === 0}
          relationType={isArchive ? undefined : relationType}
        />
      </span>
    ) : null;

  if (isArchive) {
    return (
      <div
        class={`sidebar-item sidebar-archive-node${isActive ? " active" : ""}${depth === 0 ? " top-level" : ""}`}
        data-tid={id}
        onClick={() => {
          onSelect(id);
        }}
      >
        {treeConnectors}
        <span class="task-type-icon task-type-icon-archive" />
        <span class="sidebar-label">{title}</span>
      </div>
    );
  }

  return (
    <div
      class={`sidebar-item${isActive ? " active" : ""}${hasPendingQuestion ? " asking" : hasAttention ? " attention" : ""}${depth === 0 ? " top-level" : ""}`}
      data-tid={id}
      onClick={(e: MouseEvent) => {
        if (e.altKey && onArchive) {
          e.preventDefault();
          onArchive(parseInt(id, 10));
        } else {
          onSelect(id);
        }
      }}
    >
      {treeConnectors}
      {hasPendingQuestion ? (
        <span class="task-type-icon task-type-icon-question asking" />
      ) : hasAttention ? (
        <span class="task-type-icon task-type-icon-check alive" />
      ) : iconName ? (
        <span
          class={`task-type-icon task-type-icon-${iconName}${statusClass ? ` ${statusClass}` : ""}`}
        />
      ) : (
        <span
          class={`task-type-icon task-type-icon-dot${statusClass ? ` ${statusClass}` : ""}`}
        />
      )}
      <span class="sidebar-label" title={title}>
        {title}
      </span>
    </div>
  );
});

// --- Sidebar component ---

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
  visible?: boolean;
  onOpenSearch?: () => void;
  onArchive?: (tid: number) => void;
}

export const Sidebar = memo(function Sidebar({
  tasks,
  activeTaskId,
  attention,
  onSelectTask,
  onNewTask,
  showBackButton,
  onBack,
  projectName,
  taskTypes,
  visible,
  onOpenSearch,
  onArchive,
}: Props) {
  const tree = useMemo(() => buildTree(tasks), [tasks]);
  const flatItems = useMemo(
    () => flattenTree(tree, activeTaskId, taskTypes),
    [tree, activeTaskId, taskTypes],
  );
  const listRef = useRef<HTMLDivElement>(null);

  // Stable callback via ref — survives parent re-renders
  const onSelectRef = useRef(onSelectTask);
  onSelectRef.current = onSelectTask;
  const handleSelect = useCallback((id: string) => {
    onSelectRef.current(id);
  }, []);

  const onArchiveRef = useRef(onArchive);
  onArchiveRef.current = onArchive;
  const handleArchive = useCallback((tid: number) => {
    onArchiveRef.current?.(tid);
  }, []);

  // Ensure icon styles are injected once
  ensureIconStyles();
  ensureRelationIconStyles();

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
    return () => {
      observer.disconnect();
    };
  }, [activeTaskId]);

  // Scroll to active item when sidebar becomes visible (mobile hamburger).
  const prevVisible = useRef(visible);
  useEffect(() => {
    const wasHidden = prevVisible.current === false;
    prevVisible.current = visible;
    if (!visible || !wasHidden || activeTaskId === null) return;
    listRef.current
      ?.querySelector(`.sidebar-item[data-tid="${activeTaskId}"]`)
      ?.scrollIntoView({ block: "nearest" });
  }, [visible, activeTaskId]);

  return (
    <div class="sidebar">
      <div class="sidebar-header">
        <div class="sidebar-header-left">
          {showBackButton && onBack && (
            <button
              class="sidebar-back-btn"
              onClick={onBack}
              title="Back to home"
            >
              ←
            </button>
          )}
        </div>
        <span class="sidebar-title" title={projectName || "Tasks"}>
          {(() => {
            const name = projectName || "Tasks";
            const slash = name.lastIndexOf("/");
            if (slash === -1) return name;
            return <><span class="sidebar-title-prefix">{name.slice(0, slash)}</span><span class="sidebar-title-leaf">/{name.slice(slash + 1)}</span></>;
          })()}
        </span>
        <div class="sidebar-header-right">
          {onOpenSearch && (
            <button
              class="sidebar-search-btn"
              onClick={onOpenSearch}
              title="Search (Ctrl+K)"
            >
              <svg
                width="14"
                height="14"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2.5"
                stroke-linecap="round"
                stroke-linejoin="round"
              >
                <circle cx="11" cy="11" r="8" />
                <line x1="21" y1="21" x2="16.65" y2="16.65" />
              </svg>
            </button>
          )}
        </div>
      </div>
      <div class="sidebar-list" ref={listRef}>
        <div
          class={`sidebar-item sidebar-new-task${activeTaskId === null ? " active" : ""}`}
          onClick={onNewTask}
        >
          <span class="task-type-icon task-type-icon-plus" />
          <span class="sidebar-label">New Task</span>
        </div>
        {flatItems
          .map((item) => (
            <SidebarItem
              key={item.id}
              id={item.id}
              depth={item.depth}
              guides={item.guides}
              relationType={item.relationType}
              statusClass={item.statusClass}
              title={item.title}
              iconName={item.iconName}
              isArchive={item.isArchive}
              isActive={item.id === activeTaskId}
              hasAttention={attention.has(item.tid)}
              hasPendingQuestion={item.hasPendingQuestion}
              onSelect={handleSelect}
              onArchive={handleArchive}
            />
          ))
          .reverse()}
      </div>
    </div>
  );
});
