import { h } from "preact";
import type { TaskState } from "../types";
import type { WorkspaceInfo } from "../useSessionManager";

interface Props {
  workspaces: WorkspaceInfo[];
  tasks: Map<number, TaskState>;
  attention: Set<number>;
  onSelectTask: (tid: number) => void;
  onNavigateToProject: (workspace: string, projectName: string) => void;
}

export function WelcomePage({
  workspaces,
  tasks,
  attention,
  onSelectTask,
  onNavigateToProject,
}: Props) {
  // Group tasks by workspace+projectPath
  const tasksByProject = new Map<string, TaskState[]>();
  for (const t of tasks.values()) {
    const key = `${t.workspace || ""}:${t.projectPath || ""}`;
    const list = tasksByProject.get(key) || [];
    list.push(t);
    tasksByProject.set(key, list);
  }

  // Check for ungrouped tasks (no workspace/projectPath)
  const ungrouped = (tasksByProject.get(":") || []).sort(
    (a, b) => b.tid - a.tid,
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
              const projTasks = (tasksByProject.get(key) || []).sort(
                (a, b) => b.tid - a.tid,
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
                      onClick={() => onNavigateToProject(ws.name, proj.name)}
                      title="New task"
                    >
                      +
                    </button>
                  </div>
                  <div class="project-card-sessions">
                    {projTasks.length === 0 ? (
                      <div class="project-card-empty">No tasks yet</div>
                    ) : (
                      projTasks.map((t) => (
                        <div
                          key={t.tid}
                          class={`sidebar-item${attention.has(t.tid) ? " attention" : ""}`}
                          onClick={() => onSelectTask(t.tid)}
                        >
                          {attention.has(t.tid) ? (
                            <span class="sidebar-dot check">&#x2713;</span>
                          ) : (
                            <span
                              class={`sidebar-dot${t.alive ? " alive" : t.resumable ? " resumable" : ""}`}
                            />
                          )}
                          <span
                            class="sidebar-label"
                            title={t.title || `Task ${t.tid}`}
                          >
                            {t.title || `Task ${t.tid}`}
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
                <span class="project-card-title">Legacy tasks</span>
              </div>
              <div class="project-card-sessions">
                {ungrouped.map((t) => (
                  <div
                    key={t.tid}
                    class={`sidebar-item${attention.has(t.tid) ? " attention" : ""}`}
                    onClick={() => onSelectTask(t.tid)}
                  >
                    {attention.has(t.tid) ? (
                      <span class="sidebar-dot check">&#x2713;</span>
                    ) : (
                      <span
                        class={`sidebar-dot${t.alive ? " alive" : t.resumable ? " resumable" : ""}`}
                      />
                    )}
                    <span
                      class="sidebar-label"
                      title={t.title || `Task ${t.tid}`}
                    >
                      {t.title || `Task ${t.tid}`}
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
