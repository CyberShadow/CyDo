import { memo } from "preact/compat";
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "preact/hooks";
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

export function shouldHandleSidebarAltArchive(
  altKey: boolean,
  hasArchiveHandler: boolean,
  archiving: boolean,
): boolean {
  return altKey && hasArchiveHandler && !archiving;
}

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

function TreeConnectors({
  depth,
  guides,
  relationType,
}: {
  depth: number;
  guides: number;
  relationType?: string;
}) {
  if (depth === 0) return null;
  return (
    <span class="tree-connectors">
      {Array.from({ length: depth - 1 }, (_, i) => (
        <TreeGuide key={i} hasLine={(guides & (1 << i)) !== 0} />
      ))}
      <TreeJunction
        isLast={(guides & (1 << (depth - 1))) === 0}
        relationType={relationType}
      />
    </span>
  );
}

export interface SidebarTask {
  tid: number;
  alive: boolean;
  canStop: boolean;
  resumable: boolean;
  isProcessing: boolean;
  stdinClosed?: boolean;
  title?: string;
  parentTid?: number;
  childCount: number;
  relationType?: string;
  status?: string;
  archived?: boolean;
  archiving?: boolean;
  isArchiveNode?: boolean;
  taskType?: string;
  hasPendingQuestion?: boolean;
  hasMessages?: boolean;
  /// activity timestamp used by the recency ordering; falls back to creation
  lastActive?: number;
}

interface TreeNode {
  id: string;
  task: SidebarTask;
  children: TreeNode[];
  knownChildCount: number;
}

export function flatTaskOrder(
  tasks: SidebarTask[],
  sortByRecency = false,
): string[] {
  const ids: string[] = [];
  function walk(nodes: TreeNode[]) {
    for (const n of nodes) {
      ids.push(n.id);
      walk(n.children);
    }
  }
  walk(buildTree(tasks, sortByRecency));
  return ids;
}

/**
 * Recency of a node: its own activity, or its most recently active descendant,
 * whichever is later. A parent therefore rises when work happens anywhere
 * beneath it, at any depth, without the hierarchy itself changing.
 */
function subtreeRecency(node: TreeNode): number {
  let newest = node.task.lastActive ?? 0;
  for (const child of node.children)
    newest = Math.max(newest, subtreeRecency(child));
  return newest;
}

/**
 * Order every level by recency, newest first. Siblings re-sort among
 * themselves; nothing is reparented. Group nodes (Archive, Import) carry no
 * activity of their own, so they are left to the caller to place.
 */
function sortNodesByRecency(nodes: TreeNode[]): TreeNode[] {
  return nodes
    .map((node) => ({ ...node, children: sortNodesByRecency(node.children) }))
    .sort((a, b) => subtreeRecency(b) - subtreeRecency(a));
}

function insertArchiveNodes(
  nodes: TreeNode[],
  archiveLast: boolean,
): TreeNode[] {
  return nodes.map((node) => {
    const processed = insertArchiveNodes(node.children, archiveLast);
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
        canStop: false,
        resumable: false,
        isProcessing: false,
        title: "Archive",
        childCount: 0,
        status: "completed",
        isArchiveNode: true,
      },
      children: archived,
      knownChildCount: 0,
    };
    return {
      ...node,
      children: archiveLast
        ? [...active, archiveNode]
        : [archiveNode, ...active],
    };
  });
}

export function buildTree(
  tasks: SidebarTask[],
  sortByRecency = false,
): TreeNode[] {
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
    return list.map((t) => {
      const children = childMap.get(t.tid) || [];
      return {
        id: String(t.tid),
        task: t,
        children: toNodes(children),
        knownChildCount: children.length,
      };
    });
  }

  let tree = toNodes(roots);
  // Recency ordering happens before the group nodes are inserted, so Archive
  // and Import (which have no activity of their own) keep their fixed places.
  if (sortByRecency) tree = sortNodesByRecency(tree);
  tree = insertArchiveNodes(tree, sortByRecency);

  // Handle archived roots
  const archivedRoots = tree.filter((n) => n.task.archived);
  const activeRoots = tree.filter((n) => !n.task.archived);
  if (archivedRoots.length > 0) {
    const archiveRoot: TreeNode = {
      id: "archive",
      task: {
        tid: 0,
        alive: false,
        canStop: false,
        resumable: false,
        isProcessing: false,
        title: "Archive",
        childCount: 0,
        status: "completed",
        isArchiveNode: true,
      },
      children: archivedRoots,
      knownChildCount: 0,
    };
    tree = sortByRecency
      ? [...activeRoots, archiveRoot]
      : [archiveRoot, ...activeRoots];
  }

  // Handle importable roots — group under "Import" node
  const importableRoots = tree.filter((n) => n.task.status === "importable");
  if (importableRoots.length > 0) {
    // Separate archive/group nodes from non-importable regular tasks
    const groupNodes = tree.filter((n) => n.task.isArchiveNode);
    const regularNonImportable = tree.filter(
      (n) => !n.task.isArchiveNode && n.task.status !== "importable",
    );
    const importRoot: TreeNode = {
      id: "import",
      task: {
        tid: 0,
        alive: false,
        canStop: false,
        resumable: false,
        isProcessing: false,
        title: "Import",
        childCount: 0,
        status: "completed",
        isArchiveNode: true,
      },
      children: importableRoots,
      knownChildCount: 0,
    };
    // The list's two reversals (.reverse() in the JSX and the column-reverse on
    // .sidebar-list) cancel, so array order is display order, top to bottom.
    tree = sortByRecency
      ? [...regularNonImportable, ...groupNodes, importRoot]
      : [...groupNodes, importRoot, ...regularNonImportable];
  }

  return tree;
}

function hasDescendant(node: TreeNode, id: string): boolean {
  for (const c of node.children) {
    if (c.id === id || hasDescendant(c, id)) return true;
  }
  return false;
}

type EdgeGlow = "none" | "attention" | "asking";

// --- Flattened data item for memoized rendering ---

interface OrdinaryFlatItem {
  kind: "ordinary";
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
  // Collapsed "(X subtasks)" summary row: selecting it navigates to this
  // task id (the parent), and attention aggregates over these hidden tids.
  selectId?: string;
  attentionTids?: number[];
}

interface LoadingFlatItem {
  kind: "loading";
  key: string;
  depth: number;
  guides: number;
}

export type FlatItem = OrdinaryFlatItem | LoadingFlatItem;

export function computeStatusClass(t: {
  isProcessing: boolean;
  alive: boolean;
  stdinClosed?: boolean;
  resumable: boolean;
  status?: string;
  hasMessages?: boolean;
}): string {
  if (t.isProcessing) return t.status === "waiting" ? "waiting" : "processing";
  if (t.alive && t.stdinClosed) return "ending";
  if (t.alive) return "alive";
  if (t.status === "failed") return "failed";
  if (t.resumable) return "resumable";
  if (t.status === "importable") return "importable";
  if (t.status === "completed") return "completed";
  if (t.status === "pending" && !t.hasMessages) return "draft";
  return "";
}

function collectTasks(node: TreeNode, skipArchived: boolean): SidebarTask[] {
  const out: SidebarTask[] = [];
  function walk(n: TreeNode) {
    if (n.task.isArchiveNode) {
      if (skipArchived) return;
    } else {
      out.push(n.task);
    }
    for (const c of n.children) walk(c);
  }
  walk(node);
  return out;
}

// Statuses safe to fold away: finished work and never-started tasks.
// Anything in flight (alive, processing, waiting, asking, interrupted) is not.
function isCollapsible(t: SidebarTask): boolean {
  return (
    t.status === "completed" || t.status === "failed" || t.status === "pending"
  );
}

function hasIncompleteChildren(node: TreeNode, tasksLoading: boolean): boolean {
  return tasksLoading && node.task.childCount > node.knownChildCount;
}

function subtreeCollapsible(node: TreeNode, tasksLoading: boolean): boolean {
  if (node.task.isArchiveNode) return true;
  return (
    !hasIncompleteChildren(node, tasksLoading) &&
    isCollapsible(node.task) &&
    node.children.every((child) => subtreeCollapsible(child, tasksLoading))
  );
}

export function flattenTree(
  tree: TreeNode[],
  activeTaskId: string | null,
  taskTypes: TypeInfo[],
  tasksLoading: boolean,
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
        kind: "ordinary",
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
      kind: "ordinary",
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

    const hasLoadingChild = hasIncompleteChildren(node, tasksLoading);

    // Collapse the leading run of fully-collapsible subtrees into one summary
    // row, unless the parent itself is selected or the selection is inside
    // that run. Children with running work always stay visible.
    let collapsed: TreeNode[] = [];
    if (node.id !== activeTaskId) {
      let end = 0;
      while (
        end < node.children.length &&
        subtreeCollapsible(node.children[end]!, tasksLoading)
      )
        end++;
      const prefix = node.children.slice(0, end);
      const selectionInPrefix =
        activeTaskId !== null &&
        prefix.some(
          (c) => c.id === activeTaskId || hasDescendant(c, activeTaskId),
        );
      const realCount = prefix.filter((c) => !c.task.isArchiveNode).length;
      if (realCount >= 2 && !selectionInPrefix) collapsed = prefix;
    }
    if (collapsed.length > 0) {
      const hidden = collapsed.flatMap((c) => collectTasks(c, false));
      // Color the summary icon by the hidden tasks' shared status, gray when
      // mixed. Archived tasks don't vote: they stay hidden even on expand.
      const statuses = new Set(
        collapsed
          .flatMap((c) => collectTasks(c, true))
          .map((h) => computeStatusClass(h)),
      );
      const isLast =
        collapsed.length === node.children.length && !hasLoadingChild;
      items.push({
        kind: "ordinary",
        id: `subtasks:${t.tid}`,
        selectId: node.id,
        tid: t.tid,
        depth: depth + 1,
        guides: isLast ? guides : guides | (1 << depth),
        statusClass: statuses.size === 1 ? [...statuses][0]! : "",
        title: `(${collapsed.filter((c) => !c.task.isArchiveNode).length} subtasks)`,
        iconName: "subtasks",
        isArchive: false,
        hasPendingQuestion: hidden.some((h) => h.hasPendingQuestion),
        archiving: false,
        attentionTids: hidden.map((h) => h.tid),
      });
    }
    for (let i = collapsed.length; i < node.children.length; i++) {
      const isLast = i === node.children.length - 1 && !hasLoadingChild;
      walk(
        node.children[i]!,
        depth + 1,
        isLast ? guides : guides | (1 << depth),
      );
    }
    if (hasLoadingChild) {
      items.push({
        kind: "loading",
        key: `loading:${node.id}`,
        depth: depth + 1,
        guides,
      });
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
  selectId,
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
  selectId?: string;
  onSelect: (id: string) => void;
  onArchive?: (tid: number) => void;
}) {
  const treeConnectors = (
    <TreeConnectors
      depth={depth}
      guides={guides}
      relationType={isArchive ? undefined : relationType}
    />
  );

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
      }${depth === 0 ? " top-level" : ""}${
        selectId !== undefined ? " sidebar-subtasks-summary" : ""
      }`}
      data-tid={id}
      onClick={(e: MouseEvent) => {
        if (
          selectId === undefined &&
          shouldHandleSidebarAltArchive(e.altKey, !!onArchive, archiving)
        ) {
          e.preventDefault();
          onArchive?.(parseInt(id, 10));
          return;
        }
        if (!isPlainLeftClick(e)) return;
        onSelect(selectId ?? id);
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
  tasksLoading: boolean;
  activeTaskId: string | null;
  attention: Set<number>;
  onSelectTask: (id: string) => void;
  onNewTask?: () => void;
  newTaskHref?: string;
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
  sortByRecency?: boolean;
}

export const Sidebar = memo(function Sidebar({
  tasks,
  tasksLoading,
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
  sortByRecency = false,
}: Props) {
  const tree = useMemo(
    () => buildTree(tasks, sortByRecency),
    [tasks, sortByRecency],
  );
  const flatItems = useMemo(
    () => flattenTree(tree, activeTaskId, taskTypes, tasksLoading),
    [tree, activeTaskId, taskTypes, tasksLoading],
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

  // Recency mode puts the newest tasks and the New Task row at the visual top,
  // but column-reverse rests the scroll at the visual bottom, so open at the
  // top instead. The last DOM child is the top-most one; scrollIntoView avoids
  // the sign conventions browsers use for scrollTop in reversed containers.
  // Opening happens on mount, each time the list finishes loading (the first
  // load, and every reconnect, which empties and refills it) and each time
  // the sidebar becomes visible on mobile. Keyed on the load completing
  // rather than on the list having content, since the list arrives in packets
  // and a reconnect never toggles visibility. Runs before the active-item
  // effect below so that one still wins when the active task sits off-screen.
  const openScrollRanRef = useRef(false);
  const prevTasksLoadingRef = useRef(tasksLoading);
  const prevOpenVisibleRef = useRef(visible);
  const prevSortByRecencyRef = useRef(sortByRecency);
  useEffect(() => {
    const firstRun = !openScrollRanRef.current;
    const finishedLoading = prevTasksLoadingRef.current && !tasksLoading;
    const becameVisible = prevOpenVisibleRef.current === false && visible;
    const switchedToRecency = !prevSortByRecencyRef.current && sortByRecency;
    openScrollRanRef.current = true;
    prevTasksLoadingRef.current = tasksLoading;
    prevOpenVisibleRef.current = visible;
    prevSortByRecencyRef.current = sortByRecency;
    if (!sortByRecency || !visible || tasksLoading) return;
    if (!firstRun && !finishedLoading && !becameVisible && !switchedToRecency)
      return;
    listRef.current?.lastElementChild?.scrollIntoView({ block: "nearest" });
  }, [sortByRecency, visible, tasksLoading]);

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

  // Track off-screen attention/asking items for edge glow indicators.
  const [glowAbove, setGlowAbove] = useState<EdgeGlow>("none");
  const [glowBelow, setGlowBelow] = useState<EdgeGlow>("none");

  useEffect(() => {
    const container = listRef.current;
    if (!container) return;

    const attentionEls = container.querySelectorAll<HTMLElement>(
      ".sidebar-item.attention, .sidebar-item.asking",
    );

    if (attentionEls.length === 0) {
      setGlowAbove("none");
      setGlowBelow("none");
      return;
    }

    type EntryState = {
      above: boolean;
      isAsking: boolean;
      isIntersecting: boolean;
    };
    const stateMap = new Map<Element, EntryState>();

    const updateGlow = () => {
      let above: EdgeGlow = "none";
      let below: EdgeGlow = "none";
      for (const [, s] of stateMap) {
        if (s.isIntersecting) continue;
        if (s.above) {
          if (s.isAsking) above = "asking";
          else if (above === "none") above = "attention";
        } else {
          if (s.isAsking) below = "asking";
          else if (below === "none") below = "attention";
        }
      }
      setGlowAbove(above);
      setGlowBelow(below);
    };

    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          const isAsking = entry.target.classList.contains("asking");
          let above = false;
          if (!entry.isIntersecting && entry.rootBounds) {
            // Compare actual pixel positions: above means item's bottom edge
            // is above the container's top edge.
            above = entry.boundingClientRect.bottom < entry.rootBounds.top + 1;
          }
          stateMap.set(entry.target, {
            isIntersecting: entry.isIntersecting,
            above,
            isAsking,
          });
        }
        updateGlow();
      },
      { root: container, threshold: 0 },
    );

    for (const el of attentionEls) {
      stateMap.set(el, {
        isIntersecting: true,
        above: false,
        isAsking: el.classList.contains("asking"),
      });
      observer.observe(el);
    }

    return () => {
      observer.disconnect();
    };
  }, [flatItems, attention]);

  const newTaskRow = onNewTask && (
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
  );

  return (
    <div class="sidebar">
      <div class="sidebar-header">
        <div class="sidebar-header-left">
          {showBackButton && onBack && backHref && (
            <a
              href={backHref}
              class={`sidebar-back-btn${hasGlobalAttention ? " has-attention" : ""}`}
              title={
                hasGlobalAttention
                  ? "Home — sessions need attention (Ctrl+Shift+H)"
                  : "Home (Ctrl+Shift+H)"
              }
            >
              {hasGlobalAttention ? (
                <span class="task-type-icon task-type-icon-check alive" />
              ) : (
                <span
                  class="action-icon"
                  dangerouslySetInnerHTML={{ __html: cydoIcon }}
                />
              )}
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
              onNewTask?.();
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
      <div
        class="sidebar-list-wrapper"
        data-glow-above={glowAbove === "none" ? undefined : glowAbove}
        data-glow-below={glowBelow === "none" ? undefined : glowBelow}
      >
        <div class="sidebar-list" ref={listRef}>
          {/* .sidebar-list is column-reverse, so the first child renders last:
              New Task sits at the bottom by default, and above everything in
              recency mode where the newest things belong at the top. */}
          {!sortByRecency && newTaskRow}
          {flatItems
            .map((item) => {
              if (item.kind === "loading") {
                return (
                  <div key={item.key} class="sidebar-loading-item">
                    <TreeConnectors depth={item.depth} guides={item.guides} />
                    <span class="sidebar-loading-label">(loading…)</span>
                  </div>
                );
              }
              return (
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
                  hasAttention={
                    item.attentionTids
                      ? item.attentionTids.some((tid) => attention.has(tid))
                      : attention.has(item.tid)
                  }
                  hasPendingQuestion={item.hasPendingQuestion}
                  archiving={item.archiving}
                  href={getTaskHref(item.selectId ?? item.id)}
                  selectId={item.selectId}
                  onSelect={handleSelect}
                  onArchive={handleArchive}
                />
              );
            })
            .reverse()}
          {sortByRecency && newTaskRow}
        </div>
      </div>
    </div>
  );
});
