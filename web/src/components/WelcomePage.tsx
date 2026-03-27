import { useEffect, useRef, useState } from "preact/hooks";
import type { TaskState } from "../types";
import type { WorkspaceInfo, TaskTypeInfo } from "../useSessionManager";
import { TaskTypeIcon, hasTaskTypeIcon } from "./TaskTypeIcon";

interface Props {
  workspaces: WorkspaceInfo[];
  tasks: Map<number, TaskState>;
  attention: Set<number>;
  onSelectTask: (tid: number) => void;
  onNavigateToProject: (workspace: string, projectName: string) => void;
  taskTypes: TaskTypeInfo[];
  authEnabled: boolean;
  onRefreshWorkspaces: () => void;
}

export function WelcomePage({
  workspaces,
  tasks,
  attention,
  onSelectTask,
  onNavigateToProject,
  taskTypes,
  authEnabled,
  onRefreshWorkspaces,
}: Props) {
  const [filter, setFilter] = useState("");
  const filterRef = useRef<HTMLInputElement>(null);

  // Type anywhere to focus the filter input
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      const target = e.target;
      if (
        target instanceof HTMLTextAreaElement ||
        target instanceof HTMLInputElement
      )
        return;
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      if (e.key.length !== 1) return;
      filterRef.current?.focus();
    };
    document.addEventListener("keydown", handler);
    return () => {
      document.removeEventListener("keydown", handler);
    };
  }, []);

  // Group top-level tasks by workspace+projectPath
  const tasksByProject = new Map<string, TaskState[]>();
  for (const t of tasks.values()) {
    if (t.parentTid) continue;
    const key = `${t.workspace || ""}:${t.projectPath || ""}`;
    const list = tasksByProject.get(key) || [];
    list.push(t);
    tasksByProject.set(key, list);
  }

  // Check for ungrouped tasks (no workspace/projectPath)
  const ungrouped = (tasksByProject.get(":") || []).sort(
    (a, b) => (b.lastActive ?? 0) - (a.lastActive ?? 0) || b.tid - a.tid,
  );

  const filterLower = filter.toLowerCase();

  const filteredUngrouped = filterLower
    ? ungrouped.filter((t) =>
        (t.title || `Task ${t.tid}`).toLowerCase().includes(filterLower),
      )
    : ungrouped;

  function handleFilterKeyDown(e: KeyboardEvent) {
    if (e.key === "Enter") {
      for (const ws of workspaces) {
        const projs = filterLower
          ? ws.projects.filter((p) =>
              p.name.toLowerCase().includes(filterLower),
            )
          : ws.projects;
        if (projs.length > 0) {
          onNavigateToProject(ws.name, projs[0]!.name);
          return;
        }
      }
    }
  }

  function renderTaskDot(t: TaskState) {
    let statusClass = "";
    if (t.isProcessing)
      statusClass = t.status === "waiting" ? "waiting" : "processing";
    else if (t.alive) statusClass = "alive";
    else if (t.status === "failed") statusClass = "failed";
    else if (t.resumable) statusClass = "resumable";
    else if (t.status === "completed") statusClass = "completed";
    if (hasTaskTypeIcon(t.taskType, taskTypes)) {
      return (
        <TaskTypeIcon
          taskType={t.taskType}
          taskTypes={taskTypes}
          class={statusClass || undefined}
        />
      );
    }
    return (
      <span
        class={`task-type-icon task-type-icon-dot${
          statusClass ? ` ${statusClass}` : ""
        }`}
      />
    );
  }

  return (
    <div class="welcome-page">
      <header class="welcome-page-header">
        <svg
          class="welcome-logo"
          viewBox="0 0 16 16"
          fill="none"
          stroke-width="2"
          stroke-linecap="round"
        >
          <path
            style={{ stroke: "var(--success)" }}
            d="M5.5 12L10.5 4L13 8l-2.5 4"
          />
          <path style={{ stroke: "var(--processing)" }} d="M5.5 4L3 8l2.5 4" />
        </svg>
        <h1>CyDo</h1>
      </header>
      {!authEnabled && (
        <div class="auth-notice">
          <strong>Authentication is disabled.</strong> Anyone with network
          access to this server can view and control all agent sessions. Set{" "}
          <code>CYDO_AUTH_PASS</code> to a non-empty value to enable
          authentication, or leave it unset to auto-generate a password.
        </div>
      )}
      <div class="welcome-filter-row">
        <div class="welcome-filter-wrapper">
          <input
            ref={filterRef}
            class="welcome-filter-input"
            type="text"
            placeholder="Filter projects..."
            value={filter}
            onInput={(e) => {
              setFilter((e.target as HTMLInputElement).value);
            }}
            onKeyDown={handleFilterKeyDown}
          />
          {filter && (
            <button
              class="welcome-filter-clear"
              onClick={() => {
                setFilter("");
              }}
            >
              ×
            </button>
          )}
        </div>
        <button
          class="sidebar-new-btn refresh-workspaces-btn"
          onClick={onRefreshWorkspaces}
          title="Refresh project list"
        >
          ↻
        </button>
      </div>
      {workspaces.map((ws) => {
        const filteredProjects = filterLower
          ? ws.projects.filter((p) =>
              p.name.toLowerCase().includes(filterLower),
            )
          : ws.projects;
        if (filteredProjects.length === 0) return null;
        const sortedProjects = [...filteredProjects].sort((a, b) => {
          const aKey = `${ws.name}:${a.path}`;
          const bKey = `${ws.name}:${b.path}`;
          const aTasks = tasksByProject.get(aKey) || [];
          const bTasks = tasksByProject.get(bKey) || [];

          const aActive = aTasks.some((t) => t.isProcessing || t.alive);
          const bActive = bTasks.some((t) => t.isProcessing || t.alive);
          if (aActive !== bActive) return aActive ? -1 : 1;

          const aMaxTid =
            aTasks.length > 0 ? Math.max(...aTasks.map((t) => t.tid)) : -1;
          const bMaxTid =
            bTasks.length > 0 ? Math.max(...bTasks.map((t) => t.tid)) : -1;
          if (aMaxTid !== bMaxTid) return bMaxTid - aMaxTid;

          return a.name.localeCompare(b.name);
        });
        return (
          <section class="workspace-group" key={ws.name}>
            <h2 class="workspace-group-title">{ws.name}</h2>
            <div class="project-cards">
              {sortedProjects.map((proj) => {
                const key = `${ws.name}:${proj.path}`;
                const projTasks = (tasksByProject.get(key) || []).sort(
                  (a, b) =>
                    (b.lastActive ?? 0) - (a.lastActive ?? 0) || b.tid - a.tid,
                );
                return (
                  <div class="project-card" key={proj.path}>
                    <div class="project-card-header">
                      <span
                        class="project-card-title"
                        title={proj.name}
                        onClick={() => {
                          onNavigateToProject(ws.name, proj.name);
                        }}
                      >
                        {(() => {
                          const slash = proj.name.lastIndexOf("/");
                          if (slash === -1) return proj.name;
                          return (
                            <>
                              <span class="project-card-prefix">
                                {proj.name.slice(0, slash)}
                              </span>
                              <span class="project-card-leaf">
                                /{proj.name.slice(slash + 1)}
                              </span>
                            </>
                          );
                        })()}
                      </span>
                      <button
                        class="sidebar-new-btn"
                        onClick={() => {
                          onNavigateToProject(ws.name, proj.name);
                        }}
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
                            class={`sidebar-item${
                              attention.has(t.tid) ? " attention" : ""
                            }`}
                            onClick={() => {
                              onSelectTask(t.tid);
                            }}
                          >
                            {attention.has(t.tid) ? (
                              <span class="task-type-icon task-type-icon-check alive" />
                            ) : (
                              renderTaskDot(t)
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
        );
      })}
      {filteredUngrouped.length > 0 && (
        <section class="workspace-group">
          <h2 class="workspace-group-title">Ungrouped</h2>
          <div class="project-cards">
            <div class="project-card">
              <div class="project-card-header">
                <span class="project-card-title">Legacy tasks</span>
              </div>
              <div class="project-card-sessions">
                {filteredUngrouped.map((t) => (
                  <div
                    key={t.tid}
                    class={`sidebar-item${
                      attention.has(t.tid) ? " attention" : ""
                    }`}
                    onClick={() => {
                      onSelectTask(t.tid);
                    }}
                  >
                    {attention.has(t.tid) ? (
                      <span class="task-type-icon task-type-icon-check alive" />
                    ) : (
                      renderTaskDot(t)
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
