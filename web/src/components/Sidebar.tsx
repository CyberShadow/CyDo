import { h } from "preact";

export interface SidebarSession {
  sid: number;
  alive: boolean;
  resumable: boolean;
  isProcessing: boolean;
  title?: string;
}

interface Props {
  sessions: SidebarSession[];
  activeSessionId: number | null;
  attention: Set<number>;
  onSelectSession: (sid: number) => void;
  onNewSession: () => void;
}

export function Sidebar({
  sessions,
  activeSessionId,
  attention,
  onSelectSession,
  onNewSession,
}: Props) {
  return (
    <div class="sidebar">
      <div class="sidebar-header">
        <span class="sidebar-title">Sessions</span>
        <button
          class="sidebar-new-btn"
          onClick={onNewSession}
          title="New session"
        >
          +
        </button>
      </div>
      <div class="sidebar-list">
        {sessions.map((s) => (
          <div
            key={s.sid}
            class={`sidebar-item${s.sid === activeSessionId ? " active" : ""}${attention.has(s.sid) ? " attention" : ""}`}
            onClick={() => onSelectSession(s.sid)}
          >
            <span
              class={`sidebar-dot${s.alive ? " alive" : s.resumable ? " resumable" : ""}`}
            />
            <span class="sidebar-label" title={s.title || `Session ${s.sid}`}>
              {s.title || `Session ${s.sid}`}
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}
