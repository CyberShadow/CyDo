import { memo } from "preact/compat";
import { useCallback, useEffect, useMemo, useRef } from "preact/hooks";
import type { TypeInfo } from "../useSessionManager";
import { ensureIconStyles } from "./TaskTypeIcon";
import { isPlainLeftClick } from "../utils";
import relSubtaskIcon from "../icons/rel-subtask.svg?raw";
import relForkIcon from "../icons/rel-fork.svg?raw";
import relUndoBackupIcon from "../icons/rel-undo-backup.svg?raw";
import relContinuationIcon from "../icons/rel-continuation.svg?raw";
import cydoIcon from "../icons/cydo.svg?raw";

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
      return `.relation-icon-${CSS.escape(
        name,
      )}{mask-image:${uri};-webkit-mask-image:${uri}}`;
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
  lastActive?: number;
  isProcessing: boolean;
  title?: string;
  parentTid?: number;
  relationType?: string;
  status?: string;
  archived?: boolean;
  archiving?: boolean;
  isArchiveNode?: boolean;
  taskType?: string;
  hasPendingQuestion?: boolean;
  hasMessages?: boolean;
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

  // Handle importable roots — group under "Import" node
  const importableRoots = tree.filter((n) => n.task.status === "importable");
  if (importableRoots.length > 0) {
    // Separate archive/group nodes from non-importable regular tasks
    const groupNodes = tree.filter((n) => n.task.isArchiveNode);
    const regularNonImportable = tree.filter(
      (n) => !n.task.isArchiveNode && n.task.status !== "importable",
    );
    // Sort importable by lastActive descending (newest first)
    importableRoots.sort(
      (a, b) => (b.task.lastActive ?? 0) - (a.task.lastActive ?? 0),
    );
    const importRoot: TreeNode = {
      id: "import",
      task: {
        tid: 0,
        alive: false,
        resumable: false,
        isProcessing: false,
        title: "Import",
        status: "completed",
        isArchiveNode: true,
      },
      children: importableRoots,
    };
    // Array order (sidebar renders reversed):
    //   [groupNodes..., importRoot, regularNonImportable...]
    // After .reverse(): regularNonImportable (top), importRoot (middle), groupNodes (bottom)
    tree = [...groupNodes, importRoot, ...regularNonImportable];
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
  archiving: boolean;
}

export function computeStatusClass(t: SidebarTask): string {
  if (t.isProcessing) return t.status === "waiting" ? "waiting" : "processing";
  if (t.alive) return "alive";
  if (t.status === "failed") return "failed";
  if (t.resumable) return "resumable";
  if (t.status === "importable") return "importable";
  if (t.status === "completed") return "completed";
  if (t.status === "pending" && !t.hasMessages) return "draft";
  return "";
}

function flattenTree(
  tree: TreeNode[],
  activeTaskId: string | null,
  taskTypes: TypeInfo[],
): FlatItem[] {
  const items: FlatItem[] = [];

  function walk(node: TreeNode, depth: number, guides: number) {
    const t = node.task;

    if (t.isArchiveNode) {
      const groupLabel =
        t.title === "Import"
          ? `Import (${node.children.length})`
          : `Archive (${node.children.length})`;
      items.push({
        id: node.id,
        tid: t.tid,
        depth,
        guides,
        statusClass: "",
        title: groupLabel,
        isArchive: true,
        hasPendingQuestion: false,
        archiving: false,
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
      archiving: !!t.archiving,
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
  archiving,
  href,
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
  archiving: boolean;
  href: string;
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
      <a
        href={href}
        class={`sidebar-item sidebar-archive-node${isActive ? " active" : ""}${
          depth === 0 ? " top-level" : ""
        }`}
        data-tid={id}
        onClick={(e: MouseEvent) => {
          if (!isPlainLeftClick(e)) return;
          onSelect(id);
        }}
      >
        {treeConnectors}
        <span
          class={`task-type-icon ${
            title.startsWith("Import")
              ? "task-type-icon-import"
              : "task-type-icon-archive"
          }`}
        />
        <span class="sidebar-label">{title}</span>
      </a>
    );
  }

  return (
    <a
      href={href}
      class={`sidebar-item${isActive ? " active" : ""}${
        hasPendingQuestion ? " asking" : hasAttention ? " attention" : ""
      }${depth === 0 ? " top-level" : ""}`}
      data-tid={id}
      onClick={(e: MouseEvent) => {
        if (e.altKey && onArchive) {
          e.preventDefault();
          onArchive(parseInt(id, 10));
          return;
        }
        if (!isPlainLeftClick(e)) return;
        onSelect(id);
      }}
    >
      {treeConnectors}
      {archiving ? (
        <span class="task-type-icon spinner" />
      ) : hasPendingQuestion ? (
        <span class="task-type-icon task-type-icon-question asking" />
      ) : hasAttention ? (
        <span class="task-type-icon task-type-icon-check alive" />
      ) : iconName ? (
        <span
          class={`task-type-icon task-type-icon-${iconName}${
            statusClass ? ` ${statusClass}` : ""
          }`}
        />
      ) : (
        <span
          class={`task-type-icon task-type-icon-dot${
            statusClass ? ` ${statusClass}` : ""
          }`}
        />
      )}
      <span
        class={`sidebar-label${statusClass === "draft" ? " draft-label" : ""}`}
        title={title}
      >
        {title}
      </span>
    </a>
  );
});

// --- Sidebar component ---

interface Props {
  tasks: SidebarTask[];
  activeTaskId: string | null;
  attention: Set<number>;
  onSelectTask: (id: string) => void;
  onNewTask: () => void;
  newTaskHref: string;
  showBackButton?: boolean;
  onBack?: () => void;
  backHref?: string;
  projectName?: string;
  projectHref?: string;
  getTaskHref: (id: string) => string;
  taskTypes: TypeInfo[];
  visible?: boolean;
  onOpenSearch?: () => void;
  onArchive?: (tid: number) => void;
  hasGlobalAttention?: boolean;
}

export const Sidebar = memo(function Sidebar({
  tasks,
  activeTaskId,
  attention,
  onSelectTask,
  onNewTask,
  newTaskHref,
  showBackButton,
  onBack,
  backHref,
  projectName,
  projectHref,
  getTaskHref,
  taskTypes,
  visible,
  onOpenSearch,
  onArchive,
  hasGlobalAttention,
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
          {showBackButton && onBack && backHref && (
            <a href={backHref} class="sidebar-back-btn" title="Home">
              <span
                class="action-icon"
                dangerouslySetInnerHTML={{ __html: cydoIcon }}
              />
              {hasGlobalAttention && <span class="home-attention-dot" />}
            </a>
          )}
        </div>
        {projectHref ? (
          <a
            href={projectHref}
            class="sidebar-title"
            title={projectName || "Tasks"}
            onClick={(e: MouseEvent) => {
              if (!isPlainLeftClick(e)) return;
              onNewTask();
            }}
          >
            {(() => {
              const name = projectName || "Tasks";
              const slash = name.lastIndexOf("/");
              if (slash === -1) return name;
              return (
                <>
                  <span class="sidebar-title-prefix">
                    {name.slice(0, slash)}
                  </span>
                  <span class="sidebar-title-leaf">
                    /{name.slice(slash + 1)}
                  </span>
                </>
              );
            })()}
          </a>
        ) : (
          <span class="sidebar-title" title={projectName || "Tasks"}>
            {(() => {
              const name = projectName || "Tasks";
              const slash = name.lastIndexOf("/");
              if (slash === -1) return name;
              return (
                <>
                  <span class="sidebar-title-prefix">
                    {name.slice(0, slash)}
                  </span>
                  <span class="sidebar-title-leaf">
                    /{name.slice(slash + 1)}
                  </span>
                </>
              );
            })()}
          </span>
        )}
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
        <a
          href={newTaskHref}
          class={`sidebar-item sidebar-new-task${
            activeTaskId === null ? " active" : ""
          }`}
          title="New Task (Ctrl+Shift+O)"
          onClick={(e: MouseEvent) => {
            if (!isPlainLeftClick(e)) return;
            onNewTask();
          }}
        >
          <span class="task-type-icon task-type-icon-plus" />
          <span class="sidebar-label">New Task</span>
        </a>
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
              archiving={item.archiving}
              href={getTaskHref(item.id)}
              onSelect={handleSelect}
              onArchive={handleArchive}
            />
          ))
          .reverse()}
      </div>
    </div>
  );
});
