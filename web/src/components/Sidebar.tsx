import { h } from "preact";
import { useMemo } from "preact/hooks";

export interface SidebarSession {
  sid: number;
  alive: boolean;
  resumable: boolean;
  isProcessing: boolean;
  title?: string;
  parentSid?: number;
  relationType?: string;
}

interface TreeNode {
  session: SidebarSession;
  children: TreeNode[];
}

function buildTree(sessions: SidebarSession[]): TreeNode[] {
  const sidSet = new Set(sessions.map((s) => s.sid));
  const childMap = new Map<number, SidebarSession[]>();
  const roots: SidebarSession[] = [];

  for (const s of sessions) {
    if (s.parentSid && sidSet.has(s.parentSid)) {
      const children = childMap.get(s.parentSid) || [];
      children.push(s);
      childMap.set(s.parentSid, children);
    } else {
      roots.push(s);
    }
  }

  function toNodes(list: SidebarSession[]): TreeNode[] {
    return list.map((s) => ({
      session: s,
      children: toNodes(childMap.get(s.sid) || []),
    }));
  }

  return toNodes(roots);
}

function renderNode(
  node: TreeNode,
  depth: number,
  activeSessionId: number | null,
  attention: Set<number>,
  onSelectSession: (sid: number) => void,
): h.JSX.Element[] {
  const s = node.session;
  const elements: h.JSX.Element[] = [];

  elements.push(
    <div
      key={s.sid}
      class={`sidebar-item${s.sid === activeSessionId ? " active" : ""}${attention.has(s.sid) ? " attention" : ""}`}
      style={depth > 0 ? { paddingLeft: `${8 + depth * 16}px` } : undefined}
      onClick={() => onSelectSession(s.sid)}
    >
      {depth > 0 && (
        <span class="sidebar-relation-icon" title={s.relationType || "child"}>
          ↳
        </span>
      )}
      {attention.has(s.sid) ? (
        <span class="sidebar-dot check">&#x2713;</span>
      ) : (
        <span
          class={`sidebar-dot${s.alive ? " alive" : s.resumable ? " resumable" : ""}`}
        />
      )}
      <span class="sidebar-label" title={s.title || `Session ${s.sid}`}>
        {s.title || `Session ${s.sid}`}
      </span>
    </div>,
  );

  for (const child of node.children) {
    elements.push(
      ...renderNode(
        child,
        depth + 1,
        activeSessionId,
        attention,
        onSelectSession,
      ),
    );
  }

  return elements;
}

interface Props {
  sessions: SidebarSession[];
  activeSessionId: number | null;
  attention: Set<number>;
  onSelectSession: (sid: number) => void;
  onNewSession: () => void;
  showBackButton?: boolean;
  onBack?: () => void;
  projectName?: string;
}

export function Sidebar({
  sessions,
  activeSessionId,
  attention,
  onSelectSession,
  onNewSession,
  showBackButton,
  onBack,
  projectName,
}: Props) {
  const tree = useMemo(() => buildTree(sessions), [sessions]);

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
        <span class="sidebar-title">{projectName || "Sessions"}</span>
        <button
          class="sidebar-new-btn"
          onClick={onNewSession}
          title="New session"
        >
          +
        </button>
      </div>
      <div class="sidebar-list">
        {tree.flatMap((node) =>
          renderNode(node, 0, activeSessionId, attention, onSelectSession),
        )}
      </div>
    </div>
  );
}
