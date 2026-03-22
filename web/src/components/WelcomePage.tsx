import { useState } from "preact/hooks"
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
}

export function WelcomePage({
  workspaces,
  tasks,
  attention,
  onSelectTask,
  onNavigateToProject,
  taskTypes,
}: Props) {
  const [filter, setFilter] = useState("")

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

  const filterLower = filter.toLowerCase()

  const filteredUngrouped = filterLower
    ? ungrouped.filter(t => (t.title || `Task ${t.tid}`).toLowerCase().includes(filterLower))
    : ungrouped

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
        class={`task-type-icon task-type-icon-dot${statusClass ? ` ${statusClass}` : ""}`}
      />
    );
  }

  return (
    <div class="welcome-page">
      <header class="welcome-page-header">
        <h1>CyDo</h1>
      </header>
      <div class="welcome-filter-row">
        <input
          class="welcome-filter-input"
          type="text"
          placeholder="Filter projects..."
          value={filter}
          onInput={(e) => { setFilter((e.target as HTMLInputElement).value) }}
        />
        {filter && (
          <button class="welcome-filter-clear" onClick={() => { setFilter("") }}>
            ×
          </button>
        )}
      </div>
      {workspaces.map((ws) => {
        const filteredProjects = filterLower
          ? ws.projects.filter(p => p.name.toLowerCase().includes(filterLower))
          : ws.projects
        if (filteredProjects.length === 0) return null
        const sortedProjects = [...filteredProjects].sort((a, b) => {
          const aKey = `${ws.name}:${a.path}`;
          const bKey = `${ws.name}:${b.path}`;
          const aTasks = tasksByProject.get(aKey) || [];
          const bTasks = tasksByProject.get(bKey) || [];

          const aActive = aTasks.some(t => t.isProcessing || t.alive);
          const bActive = bTasks.some(t => t.isProcessing || t.alive);
          if (aActive !== bActive) return aActive ? -1 : 1;

          const aMaxTid = aTasks.length > 0 ? Math.max(...aTasks.map(t => t.tid)) : -1;
          const bMaxTid = bTasks.length > 0 ? Math.max(...bTasks.map(t => t.tid)) : -1;
          if (aMaxTid !== bMaxTid) return bMaxTid - aMaxTid;

          return a.name.localeCompare(b.name);
        })
        return (
          <section class="workspace-group" key={ws.name}>
            <h2 class="workspace-group-title">{ws.name}</h2>
            <div class="project-cards">
              {sortedProjects.map((proj) => {
                const key = `${ws.name}:${proj.path}`;
                const projTasks = (tasksByProject.get(key) || []).sort(
                  (a, b) => b.tid - a.tid,
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
                        {proj.name}
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
                            class={`sidebar-item${attention.has(t.tid) ? " attention" : ""}`}
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
        )
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
                    class={`sidebar-item${attention.has(t.tid) ? " attention" : ""}`}
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
