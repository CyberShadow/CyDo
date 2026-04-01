import { useEffect, useMemo, useRef, useState } from "preact/hooks";
import type { TaskState } from "../types";
import type { WorkspaceInfo, TypeInfo } from "../useSessionManager";
import { TaskTypeIcon, hasTaskTypeIcon } from "./TaskTypeIcon";

interface Props {
  workspaces: WorkspaceInfo[];
  tasks: Map<number, TaskState>;
  attention: Set<number>;
  onSelectTask: (tid: number) => void;
  onNavigateToProject: (workspace: string, projectName: string) => void;
  getProjectHref: (workspace: string, projectName: string) => string;
  getTaskHref: (id: string) => string;
  taskTypes: TypeInfo[];
  authEnabled: boolean;
  onRefreshWorkspaces: () => void;
}

function isPlainLeftClick(e: MouseEvent): boolean {
  return (
    e.button === 0 &&
    !e.defaultPrevented &&
    !e.metaKey &&
    !e.ctrlKey &&
    !e.shiftKey &&
    !e.altKey
  );
}

function openInNewTab(href: string): void {
  window.open(href, "_blank", "noopener");
}

export function WelcomePage({
  workspaces,
  tasks,
  attention,
  onSelectTask,
  onNavigateToProject,
  getProjectHref,
  getTaskHref,
  taskTypes,
  authEnabled,
  onRefreshWorkspaces,
}: Props) {
  const [filter, setFilter] = useState("");
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const filterRef = useRef<HTMLInputElement>(null);
  const filterLower = filter.toLowerCase();

  function toggleCollapsed(name: string) {
    setCollapsed((prev) => {
      const next = new Set(prev);
      if (next.has(name)) next.delete(name);
      else next.add(name);
      return next;
    });
  }

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

  const { filteredWorkspaces, filteredUngrouped } = useMemo(() => {
    const tasksByProject = new Map<string, TaskState[]>();
    for (const t of tasks.values()) {
      if (t.parentTid) continue;
      const key = `${t.workspace || ""}:${t.projectPath || ""}`;
      const list = tasksByProject.get(key);
      if (list) list.push(t);
      else tasksByProject.set(key, [t]);
    }

    const projectStats = new Map<
      string,
      { tasks: TaskState[]; active: boolean; maxLastActive: number }
    >();
    for (const [key, projectTasks] of tasksByProject) {
      projectTasks.sort(
        (a, b) => (b.lastActive ?? 0) - (a.lastActive ?? 0) || b.tid - a.tid,
      );
      let active = false;
      let maxLastActive = 0;
      for (const task of projectTasks) {
        if (!active && (task.isProcessing || task.alive)) active = true;
        const lastActive = task.lastActive ?? 0;
        if (lastActive > maxLastActive) maxLastActive = lastActive;
      }
      projectStats.set(key, { tasks: projectTasks, active, maxLastActive });
    }

    const filteredWorkspaces = workspaces
      .map((ws) => {
        const matchingProjects = (
          filterLower
            ? ws.projects.filter((p) =>
                p.name.toLowerCase().includes(filterLower),
              )
            : ws.projects
        )
          .map((project) => ({
            project,
            ...(projectStats.get(`${ws.name}:${project.path}`) || {
              tasks: [],
              active: false,
              maxLastActive: 0,
            }),
          }))
          .sort((a, b) => {
            if (a.active !== b.active) return a.active ? -1 : 1;
            if (a.maxLastActive !== b.maxLastActive) {
              return b.maxLastActive - a.maxLastActive;
            }
            return a.project.name.localeCompare(b.project.name);
          });

        return { workspace: ws, projects: matchingProjects };
      })
      .filter((ws) => ws.projects.length > 0);

    const ungrouped = projectStats.get(":")?.tasks || [];
    const filteredUngrouped = filterLower
      ? ungrouped.filter((t) =>
          (t.title || `Task ${t.tid}`).toLowerCase().includes(filterLower),
        )
      : ungrouped;

    return { filteredWorkspaces, filteredUngrouped };
  }, [workspaces, tasks, filterLower]);

  function handleFilterKeyDown(e: KeyboardEvent) {
    if (e.key === "Enter") {
      const firstWorkspace = filteredWorkspaces[0];
      const firstProject = firstWorkspace?.projects[0];
      if (firstWorkspace && firstProject) {
        onNavigateToProject(
          firstWorkspace.workspace.name,
          firstProject.project.name,
        );
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

  function handleProjectNewTaskClick(
    e: MouseEvent,
    workspace: string,
    projectName: string,
  ) {
    const href = getProjectHref(workspace, projectName);
    if (e.metaKey || e.ctrlKey) {
      e.preventDefault();
      openInNewTab(href);
      return;
    }
    if (!isPlainLeftClick(e)) return;
    e.preventDefault();
    onNavigateToProject(workspace, projectName);
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
      {filteredWorkspaces.map(({ workspace: ws, projects }) => {
        const isCollapsed = collapsed.has(ws.name);
        return (
          <section class="workspace-group" key={ws.name}>
            <h2
              class="workspace-group-title"
              onClick={() => {
                toggleCollapsed(ws.name);
              }}
            >
              <span class="workspace-group-chevron">
                {isCollapsed ? "▶" : "▼"}
              </span>
              {ws.name}
            </h2>
            {!isCollapsed && (
              <div class="project-cards">
                {projects.map(({ project: proj, tasks: projTasks }) => {
                  return (
                    <div class="project-card" key={proj.path}>
                      <div class="project-card-header">
                        <a
                          href={getProjectHref(ws.name, proj.name)}
                          class="project-card-title"
                          title={proj.name}
                          onClick={(e: MouseEvent) => {
                            if (!isPlainLeftClick(e)) return;
                            e.preventDefault();
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
                        </a>
                        <button
                          class="sidebar-new-btn"
                          onClick={(e: MouseEvent) => {
                            handleProjectNewTaskClick(e, ws.name, proj.name);
                          }}
                          onAuxClick={(e: MouseEvent) => {
                            if (e.button !== 1) return;
                            e.preventDefault();
                            openInNewTab(getProjectHref(ws.name, proj.name));
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
                            <a
                              key={t.tid}
                              href={getTaskHref(String(t.tid))}
                              class={`sidebar-item${
                                attention.has(t.tid) ? " attention" : ""
                              }`}
                              onClick={(e: MouseEvent) => {
                                if (!isPlainLeftClick(e)) return;
                                e.preventDefault();
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
                            </a>
                          ))
                        )}
                      </div>
                    </div>
                  );
                })}
              </div>
            )}
          </section>
        );
      })}
      {filteredUngrouped.length > 0 && (
        <section class="workspace-group">
          <h2
            class="workspace-group-title"
            onClick={() => {
              toggleCollapsed("Ungrouped");
            }}
          >
            <span class="workspace-group-chevron">
              {collapsed.has("Ungrouped") ? "▶" : "▼"}
            </span>
            Ungrouped
          </h2>
          {!collapsed.has("Ungrouped") && (
            <div class="project-cards">
              <div class="project-card">
                <div class="project-card-header">
                  <span class="project-card-title">Legacy tasks</span>
                </div>
                <div class="project-card-sessions">
                  {filteredUngrouped.map((t) => (
                    <a
                      key={t.tid}
                      href={getTaskHref(String(t.tid))}
                      class={`sidebar-item${
                        attention.has(t.tid) ? " attention" : ""
                      }`}
                      onClick={(e: MouseEvent) => {
                        if (!isPlainLeftClick(e)) return;
                        e.preventDefault();
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
                    </a>
                  ))}
                </div>
              </div>
            </div>
          )}
        </section>
      )}
    </div>
  );
}
