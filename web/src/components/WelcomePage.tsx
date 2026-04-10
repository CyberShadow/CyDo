import { useEffect, useMemo, useRef, useState } from "preact/hooks";
import type { TaskState } from "../types";
import type { WorkspaceInfo, TypeInfo } from "../useSessionManager";
import type { Notice } from "../protocol";
import { TaskTypeIcon, hasTaskTypeIcon } from "./TaskTypeIcon";
import { computeStatusClass } from "./Sidebar";
import { isPlainLeftClick, relativeTime } from "../utils";
import { NoticeBar } from "./NoticeBar";

interface Props {
  workspaces: WorkspaceInfo[];
  tasks: Map<number, TaskState>;
  attention: Set<number>;
  onSelectTask: (tid: number) => void;
  onNavigateToProject: (workspace: string, projectName: string) => void;
  getProjectHref: (workspace: string, projectName: string) => string;
  getTaskHref: (id: string) => string;
  taskTypes: TypeInfo[];
  notices: Record<string, Notice>;
  onRefreshWorkspaces: () => void;
}

function Chevron({ open }: { open: boolean }) {
  return (
    <svg
      class="workspace-group-chevron"
      width="12"
      height="12"
      viewBox="0 0 12 12"
    >
      {open ? (
        <path d="M2 4L6 9L10 4" fill="currentColor" />
      ) : (
        <path d="M4 2L9 6L4 10" fill="currentColor" />
      )}
    </svg>
  );
}

function openInNewTab(href: string): void {
  window.open(href, "_blank", "noopener");
}

function ActiveSessions({
  tasks,
  filter,
  attention,
  taskTypes,
  workspaces,
  getTaskHref,
  onSelectTask,
  collapsed,
  onToggleCollapsed,
}: {
  tasks: Map<number, TaskState>;
  filter: string;
  attention: Set<number>;
  taskTypes: TypeInfo[];
  workspaces: WorkspaceInfo[];
  getTaskHref: (id: string) => string;
  onSelectTask: (tid: number) => void;
  collapsed: boolean;
  onToggleCollapsed: () => void;
}) {
  const filterLower = filter.toLowerCase();
  const activeTasks = useMemo(() => {
    const result: TaskState[] = [];
    for (const t of tasks.values()) {
      if (!t.alive && !t.isProcessing) continue;
      if (filterLower) {
        const title = (t.title || `Task ${t.tid}`).toLowerCase();
        const ws = (t.workspace || "").toLowerCase();
        const proj = (t.projectPath || "").toLowerCase();
        if (
          !title.includes(filterLower) &&
          !ws.includes(filterLower) &&
          !proj.includes(filterLower)
        )
          continue;
      }
      result.push(t);
    }
    result.sort((a, b) => (b.lastActive ?? 0) - (a.lastActive ?? 0));
    return result;
  }, [tasks, filterLower]);

  if (activeTasks.length === 0) return null;

  return (
    <section class="workspace-group">
      <h2 class="workspace-group-title" onClick={onToggleCollapsed}>
        <Chevron open={!collapsed} />
        Active Sessions ({activeTasks.length})
      </h2>
      {!collapsed && (
        <table class="active-sessions-table">
          <tbody>
            {activeTasks.map((t) => {
              const title = t.title || `Task ${t.tid}`;
              const statusClass = computeStatusClass(t);
              const projName =
                workspaces
                  .find((w) => w.name === t.workspace)
                  ?.projects.find((p) => p.path === t.projectPath)?.name ||
                t.projectPath ||
                "";
              return (
                <tr
                  key={t.tid}
                  class="active-sessions-row"
                  onClick={(e: MouseEvent) => {
                    if (!isPlainLeftClick(e)) return;
                    e.preventDefault();
                    onSelectTask(t.tid);
                  }}
                  onAuxClick={(e: MouseEvent) => {
                    if (e.button !== 1) return;
                    e.preventDefault();
                    openInNewTab(getTaskHref(String(t.tid)));
                  }}
                >
                  <td class="active-sessions-icon">
                    {attention.has(t.tid) ? (
                      <span class="task-type-icon task-type-icon-check alive" />
                    ) : hasTaskTypeIcon(t.taskType, taskTypes) ? (
                      <TaskTypeIcon
                        taskType={t.taskType}
                        taskTypes={taskTypes}
                        class={statusClass || undefined}
                      />
                    ) : (
                      <span
                        class={`task-type-icon task-type-icon-dot${statusClass ? ` ${statusClass}` : ""}`}
                      />
                    )}
                  </td>
                  <td class="active-sessions-title" title={title}>
                    {title}
                  </td>
                  <td class="active-sessions-workspace">{t.workspace || ""}</td>
                  <td class="active-sessions-project">{projName}</td>
                  <td class="active-sessions-time">
                    {relativeTime(t.lastActive ?? Date.now())}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </section>
  );
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
  notices,
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
    // Build path → workspace+project index from the workspaces list
    const pathToProjects = new Map<
      string,
      { wsName: string; project: (typeof workspaces)[0]["projects"][0] }[]
    >();
    for (const ws of workspaces) {
      for (const proj of ws.projects) {
        const list = pathToProjects.get(proj.path);
        if (list) list.push({ wsName: ws.name, project: proj });
        else
          pathToProjects.set(proj.path, [{ wsName: ws.name, project: proj }]);
      }
    }

    // Group tasks by wsName:projectPath key; a task can appear in multiple workspaces
    const tasksByProject = new Map<string, TaskState[]>();
    for (const t of tasks.values()) {
      if (t.parentTid) continue;
      const matches = t.projectPath
        ? pathToProjects.get(t.projectPath)
        : undefined;
      if (matches && matches.length > 0) {
        for (const m of matches) {
          const key = `${m.wsName}:${m.project.path}`;
          const list = tasksByProject.get(key);
          if (list) list.push(t);
          else tasksByProject.set(key, [t]);
        }
      } else {
        const key = ":";
        const list = tasksByProject.get(key);
        if (list) list.push(t);
        else tasksByProject.set(key, [t]);
      }
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
    const statusClass = computeStatusClass(t);
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
      <NoticeBar notices={notices} />
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
      <ActiveSessions
        tasks={tasks}
        filter={filter}
        attention={attention}
        taskTypes={taskTypes}
        workspaces={workspaces}
        getTaskHref={getTaskHref}
        onSelectTask={onSelectTask}
        collapsed={collapsed.has("Active Sessions")}
        onToggleCollapsed={() => {
          toggleCollapsed("Active Sessions");
        }}
      />
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
              <Chevron open={!isCollapsed} />
              {ws.name}
            </h2>
            {!isCollapsed && (
              <div class="project-cards">
                {projects.map(({ project: proj, tasks: projTasks }) => {
                  return (
                    <div
                      class={`project-card${proj.virtual ? " project-card-virtual" : ""}`}
                      key={proj.path}
                    >
                      <div class="project-card-header">
                        <a
                          href={getProjectHref(ws.name, proj.name)}
                          class="project-card-title"
                          title={proj.name}
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
                          disabled={proj.virtual && proj.exists === false}
                          onClick={(e: MouseEvent) => {
                            handleProjectNewTaskClick(e, ws.name, proj.name);
                          }}
                          onAuxClick={(e: MouseEvent) => {
                            if (e.button !== 1) return;
                            e.preventDefault();
                            openInNewTab(getProjectHref(ws.name, proj.name));
                          }}
                          title={
                            proj.virtual && proj.exists === false
                              ? "Project directory no longer exists"
                              : "New task"
                          }
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
            <Chevron open={!collapsed.has("Ungrouped")} />
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
