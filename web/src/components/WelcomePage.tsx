import { h } from "preact";
import type { SessionState } from "../types";
import type { WorkspaceInfo } from "../useSessionManager";

interface Props {
  workspaces: WorkspaceInfo[];
  sessions: Map<number, SessionState>;
  attention: Set<number>;
  onNewSession: (workspace: string, projectPath: string) => void;
  onSelectSession: (sid: number) => void;
  onNavigateToProject: (workspace: string, projectName: string) => void;
}

export function WelcomePage({
  workspaces,
  sessions,
  attention,
  onNewSession,
  onSelectSession,
  onNavigateToProject,
}: Props) {
  // Group sessions by workspace+projectPath
  const sessionsByProject = new Map<string, SessionState[]>();
  for (const s of sessions.values()) {
    const key = `${s.workspace || ""}:${s.projectPath || ""}`;
    const list = sessionsByProject.get(key) || [];
    list.push(s);
    sessionsByProject.set(key, list);
  }

  // Check for ungrouped sessions (no workspace/projectPath)
  const ungrouped = (sessionsByProject.get(":") || []).sort(
    (a, b) => b.sid - a.sid,
  );

  return (
    <div class="welcome-page">
      <header class="welcome-page-header">
        <h1>CyDo</h1>
      </header>
      {workspaces.map((ws) => (
        <section class="workspace-group" key={ws.name}>
          <h2 class="workspace-group-title">{ws.name}</h2>
          <div class="project-cards">
            {ws.projects.map((proj) => {
              const key = `${ws.name}:${proj.path}`;
              const projSessions = (sessionsByProject.get(key) || []).sort(
                (a, b) => b.sid - a.sid,
              );
              return (
                <div class="project-card" key={proj.path}>
                  <div class="project-card-header">
                    <span
                      class="project-card-title"
                      onClick={() => onNavigateToProject(ws.name, proj.name)}
                    >
                      {proj.name}
                    </span>
                    <button
                      class="sidebar-new-btn"
                      onClick={() => onNewSession(ws.name, proj.path)}
                      title="New session"
                    >
                      +
                    </button>
                  </div>
                  <div class="project-card-sessions">
                    {projSessions.length === 0 ? (
                      <div class="project-card-empty">No sessions yet</div>
                    ) : (
                      projSessions.map((s) => (
                        <div
                          key={s.sid}
                          class={`sidebar-item${attention.has(s.sid) ? " attention" : ""}`}
                          onClick={() => onSelectSession(s.sid)}
                        >
                          {attention.has(s.sid) ? (
                            <span class="sidebar-dot check">&#x2713;</span>
                          ) : (
                            <span
                              class={`sidebar-dot${s.alive ? " alive" : s.resumable ? " resumable" : ""}`}
                            />
                          )}
                          <span
                            class="sidebar-label"
                            title={s.title || `Session ${s.sid}`}
                          >
                            {s.title || `Session ${s.sid}`}
                          </span>
                        </div>
                      ))
                    )}
                  </div>
                </div>
              );
            })}
          </div>
        </section>
      ))}
      {ungrouped.length > 0 && (
        <section class="workspace-group">
          <h2 class="workspace-group-title">Ungrouped</h2>
          <div class="project-cards">
            <div class="project-card">
              <div class="project-card-header">
                <span class="project-card-title">Legacy sessions</span>
              </div>
              <div class="project-card-sessions">
                {ungrouped.map((s) => (
                  <div
                    key={s.sid}
                    class={`sidebar-item${attention.has(s.sid) ? " attention" : ""}`}
                    onClick={() => onSelectSession(s.sid)}
                  >
                    {attention.has(s.sid) ? (
                      <span class="sidebar-dot check">&#x2713;</span>
                    ) : (
                      <span
                        class={`sidebar-dot${s.alive ? " alive" : s.resumable ? " resumable" : ""}`}
                      />
                    )}
                    <span
                      class="sidebar-label"
                      title={s.title || `Session ${s.sid}`}
                    >
                      {s.title || `Session ${s.sid}`}
                    </span>
                  </div>
                ))}
              </div>
            </div>
          </div>
        </section>
      )}
    </div>
  );
}
