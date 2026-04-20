import { useCallback, useEffect, useMemo, useState } from "preact/hooks";
import { Router, Route } from "preact-iso";
import { useTaskManager } from "./useSessionManager";
import { useNotifications } from "./useNotifications";
import { useToast } from "./useToast";
import { useErrorCapture } from "./useErrorOverlay";
import { useTheme, ThemeContext } from "./useTheme";
import { DevModeContext } from "./devMode";
import { Sidebar, flatTaskOrder } from "./components/Sidebar";
import { SessionView } from "./components/SessionView";
import { WelcomePage } from "./components/WelcomePage";
import { NoticeBar } from "./components/NoticeBar";
import { SearchPopup } from "./components/SearchPopup";
import { ErrorBoundary } from "./components/ErrorBoundary";
import { Toast } from "./components/Toast";

function shortProjectName(projectName: string): string {
  const slash = projectName.lastIndexOf("/");
  return slash === -1 ? projectName : projectName.slice(slash + 1);
}

function AppContent() {
  const { toasts, addToast, dismissToast, clearToasts } = useToast();
  const {
    tasks,
    activeTaskId,
    activeTaskIdRef,
    setActiveTaskId,
    connected,
    send,
    interrupt,
    stop,
    closeStdin,
    resume,
    promote,
    fork,
    undoPreview,
    undoConfirm,
    undoDismiss,
    dismissAttention,
    clearInputDraft,
    setArchived,
    saveDraft,
    setEntryPoint,
    setAgentType,
    sendAskUserResponse,
    sendPermissionPromptResponse,
    editMessage,
    editRawEvent,
    createDraftTask,
    deleteDraftTask,
    draftRenderKey,
    sidebarTasks,
    workspaces,
    entryPoints,
    typeInfo,
    agentTypes,
    defaultAgentType,
    defaultTaskType,
    activeWorkspace,
    activeProject,
    notices,
    devMode,
    navigateHome,
    navigateToProject,
    getProjectHref,
    getTaskHref,
    refreshWorkspaces,
    refreshingWorkspaces,
  } = useTaskManager(addToast);

  const { theme, toggleTheme } = useTheme();
  const attention = useNotifications(activeTaskId, tasks, dismissAttention);
  useErrorCapture(addToast);

  const effectiveDefaultAgent = useMemo(() => {
    const ws = workspaces.find((w) => w.name === activeWorkspace);
    return ws?.default_agent_type || defaultAgentType;
  }, [workspaces, activeWorkspace, defaultAgentType]);
  const effectiveDefaultTaskType = useMemo(() => {
    const ws = workspaces.find((w) => w.name === activeWorkspace);
    return ws?.default_task_type || defaultTaskType;
  }, [workspaces, activeWorkspace, defaultTaskType]);
  const [showSearch, setShowSearch] = useState(false);
  const [sidebarOpen, setSidebarOpen] = useState(false);

  const toggleSidebar = useCallback(() => {
    setSidebarOpen((v) => !v);
  }, []);

  const activeTid = activeTaskId !== null ? parseInt(activeTaskId, 10) : NaN;
  const active = !isNaN(activeTid) ? (tasks.get(activeTid) ?? null) : null;

  // Resolve active project path for attention scoping
  const activeProjectPath = useMemo(() => {
    if (!activeProject || !activeWorkspace) return null;
    const ws = workspaces.find((w) => w.name === activeWorkspace);
    return ws?.projects.find((p) => p.name === activeProject)?.path ?? null;
  }, [activeProject, activeWorkspace, workspaces]);

  // Attention outside the current project (for Home button)
  const hasOtherProjectAttention = useMemo(() => {
    if (!activeProjectPath) return false;
    for (const t of tasks.values()) {
      if (t.needsAttention && t.projectPath !== activeProjectPath) return true;
    }
    return false;
  }, [tasks, activeProjectPath, attention]);

  useEffect(() => {
    let count: number;
    if (activeProjectPath) {
      count = 0;
      for (const t of tasks.values()) {
        if (t.needsAttention && t.projectPath === activeProjectPath) count++;
      }
    } else {
      count = attention.size;
    }
    const prefix = count > 0 ? `(${count}) ` : "";
    const scopedTitle = active?.title
      ? active.title
      : activeTaskId === null && activeProject
        ? shortProjectName(activeProject)
        : null;
    document.title = scopedTitle
      ? `${prefix}${scopedTitle} — CyDo`
      : `${prefix}CyDo`;
    if ("setAppBadge" in navigator) void navigator.setAppBadge(count);
  }, [
    active?.title,
    activeProject,
    activeProjectPath,
    activeTaskId,
    attention.size,
    tasks,
  ]);

  // Ctrl+K: open search popup
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key === "k") {
        e.preventDefault();
        setShowSearch((v) => !v);
      }
    };
    document.addEventListener("keydown", handler);
    return () => {
      document.removeEventListener("keydown", handler);
    };
  }, []);

  const handleSearchSelect = useCallback(
    (tid: number) => {
      setActiveTaskId(String(tid));
    },
    [setActiveTaskId],
  );

  const handleSearchClose = useCallback(() => {
    setShowSearch(false);
    // Re-focus the input box or resume button after dismissing search
    requestAnimationFrame(() => {
      const input = document.querySelector(".input-textarea");
      const resume = document.querySelector(".btn-banner-resume");
      ((input ?? resume) as HTMLElement | null)?.focus();
    });
  }, []);

  const searchPopup = showSearch && (
    <SearchPopup
      tasks={tasks}
      taskTypes={typeInfo}
      onSelect={handleSearchSelect}
      onClose={handleSearchClose}
      getTaskHref={(tid) => getTaskHref(String(tid))}
    />
  );

  // Welcome page: no workspace selected (on /)
  if (activeWorkspace === null && activeTaskId === null) {
    return (
      <DevModeContext.Provider value={devMode}>
        <ThemeContext.Provider value={theme}>
          <div class="app welcome-page-container">
            {connected ? (
              <WelcomePage
                workspaces={workspaces}
                tasks={tasks}
                attention={attention}
                taskTypes={typeInfo}
                notices={notices}
                onSelectTask={handleSearchSelect}
                onNavigateToProject={navigateToProject}
                getProjectHref={getProjectHref}
                getTaskHref={getTaskHref}
                onRefreshWorkspaces={refreshWorkspaces}
                refreshingWorkspaces={refreshingWorkspaces}
              />
            ) : (
              <div class="connection-overlay">
                <span>Connecting…</span>
              </div>
            )}
            {searchPopup}
            <Toast
              toasts={toasts}
              onDismiss={dismissToast}
              onClearAll={clearToasts}
            />
          </div>
        </ThemeContext.Provider>
      </DevModeContext.Provider>
    );
  }

  // Navigate to the "new task" view (project page with no tid)
  // The useEffect in useTaskManager auto-creates a virtual draft when at project root
  const handleNewTask = useCallback(() => {
    if (activeWorkspace && activeProject) {
      navigateToProject(activeWorkspace, activeProject);
    } else {
      navigateHome();
    }
  }, [activeWorkspace, activeProject, navigateToProject, navigateHome]);

  // Ctrl+Shift+A: archive/unarchive active task
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.shiftKey && e.key === "A") {
        e.preventDefault();
        if (active) {
          setArchived(active.tid, !active.archived);
        }
      }
    };
    document.addEventListener("keydown", handler);
    return () => {
      document.removeEventListener("keydown", handler);
    };
  }, [active, setArchived]);

  // Ctrl+Shift+E: end session (close stdin)
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.shiftKey && e.key === "E") {
        e.preventDefault();
        if (active?.alive) {
          closeStdin();
        }
      }
    };
    document.addEventListener("keydown", handler);
    return () => {
      document.removeEventListener("keydown", handler);
    };
  }, [active, closeStdin]);

  // Alt+Up / Alt+Down: navigate between sidebar sessions (including New Task)
  // Alt+Shift+Up / Alt+Shift+Down: jump to next/prev session with attention
  // Ctrl+Shift+O: new task
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.shiftKey && e.key === "O") {
        e.preventDefault();
        handleNewTask();
        return;
      }
      if (!e.altKey || (e.key !== "ArrowUp" && e.key !== "ArrowDown")) return;
      const order = flatTaskOrder(sidebarTasks);
      if (e.shiftKey) {
        // Jump to next/prev task with attention, wrapping around
        if (order.length === 0) return;
        const idx = activeTaskId !== null ? order.indexOf(activeTaskId) : -1;
        const len = order.length;
        const dir = e.key === "ArrowUp" ? -1 : 1;
        let next: string | undefined;
        for (let i = 1; i <= len; i++) {
          const candidate =
            order[((idx === -1 ? 0 : idx) + dir * i + len) % len];
          if (attention.has(parseInt(candidate!, 10))) {
            next = candidate;
            break;
          }
        }
        if (next === undefined) return;
        setActiveTaskId(next);
        document
          .querySelector(`.sidebar-item[data-tid="${next}"]`)
          ?.scrollIntoView({ block: "nearest" });
      } else {
        // Visual order: tasks in flatTaskOrder, then New Task at bottom
        const visual: (string | null)[] = [...order, null];
        const idx = visual.indexOf(activeTaskId);
        const dir = e.key === "ArrowUp" ? -1 : 1;
        const nextIdx = (idx + dir + visual.length) % visual.length;
        const next = visual[nextIdx] ?? null;
        if (next !== null) {
          setActiveTaskId(next);
          document
            .querySelector(`.sidebar-item[data-tid="${next}"]`)
            ?.scrollIntoView({ block: "nearest" });
        } else {
          handleNewTask();
          document
            .querySelector(".sidebar-new-task")
            ?.scrollIntoView({ block: "nearest" });
        }
      }
      e.preventDefault();
    };
    document.addEventListener("keydown", handler);
    return () => {
      document.removeEventListener("keydown", handler);
    };
  }, [sidebarTasks, activeTaskId, setActiveTaskId, attention, handleNewTask]);

  const handleCloseSidebar = useCallback(() => {
    setSidebarOpen(false);
  }, []);

  const handleOpenSearch = useCallback(() => {
    setShowSearch(true);
  }, []);

  const handleSidebarArchive = useCallback(
    (tid: number) => {
      const task = tasks.get(tid);
      if (task) {
        setArchived(tid, !task.archived);
      }
    },
    [tasks, setArchived],
  );

  const handleDraftContentStart = useCallback(
    (entryPointName: string, agentType: string) => {
      createDraftTask(entryPointName, agentType);
    },
    [createDraftTask],
  );

  const handleSidebarSelect = useCallback(() => {
    setSidebarOpen(false);
  }, []);

  const handleSidebarNewTask = useCallback(() => {
    setSidebarOpen(false);
  }, []);

  const hasDraftView = activeTaskId === null && draftRenderKey !== null;

  return (
    <DevModeContext.Provider value={devMode}>
      <ThemeContext.Provider value={theme}>
        <div class={`app has-sidebar${sidebarOpen ? " sidebar-open" : ""}`}>
          {sidebarOpen && (
            <div class="sidebar-backdrop" onClick={handleCloseSidebar} />
          )}
          {!connected && (
            <div class="connection-overlay">
              <span>Connecting…</span>
            </div>
          )}
          <Sidebar
            tasks={sidebarTasks}
            activeTaskId={activeTaskId}
            attention={attention}
            onSelectTask={handleSidebarSelect}
            onNewTask={handleSidebarNewTask}
            newTaskHref={
              activeWorkspace && activeProject
                ? getProjectHref(activeWorkspace, activeProject)
                : "/"
            }
            showBackButton={true}
            onBack={navigateHome}
            backHref="/"
            projectName={activeProject || undefined}
            projectHref={
              activeWorkspace && activeProject
                ? getProjectHref(activeWorkspace, activeProject)
                : undefined
            }
            getTaskHref={getTaskHref}
            taskTypes={typeInfo}
            visible={sidebarOpen}
            onOpenSearch={handleOpenSearch}
            onArchive={handleSidebarArchive}
            hasGlobalAttention={hasOtherProjectAttention}
          />
          <NoticeBar notices={notices} />
          {Array.from(tasks.values())
            .filter((t) => {
              // Virtual drafts (tid=0) should only render in draft mode
              if (t.tid === 0) {
                return (
                  activeTaskId === null &&
                  draftRenderKey !== null &&
                  t.renderKey === draftRenderKey
                );
              }
              // Also keep real draft tasks visible while user is still at project root
              return (
                t.historyLoaded ||
                String(t.tid) === activeTaskId ||
                String(t.tid) === activeTaskIdRef.current ||
                (activeTaskId === null &&
                  draftRenderKey !== null &&
                  t.renderKey === draftRenderKey)
              );
            })
            .map((task) => {
              const isActive =
                String(task.tid) === activeTaskId ||
                String(task.tid) === activeTaskIdRef.current ||
                (activeTaskId === null &&
                  draftRenderKey !== null &&
                  task.renderKey === draftRenderKey);
              return (
                <div
                  key={task.renderKey ?? String(task.tid)}
                  style={{ display: isActive ? "contents" : "none" }}
                >
                  <SessionView
                    task={task}
                    connected={connected}
                    isActive={isActive}
                    onSend={send}
                    onInterrupt={interrupt}
                    onStop={stop}
                    onCloseStdin={closeStdin}
                    onResume={resume}
                    onPromote={promote}
                    onFork={fork}
                    onUndo={undoPreview}
                    onUndoConfirm={undoConfirm}
                    onUndoDismiss={undoDismiss}
                    onClearInputDraft={clearInputDraft}
                    onSaveDraft={saveDraft}
                    onSetEntryPoint={setEntryPoint}
                    onSetAgentType={setAgentType}
                    theme={theme}
                    onToggleTheme={toggleTheme}
                    onToggleSidebar={toggleSidebar}
                    hasGlobalAttention={attention.size > 0}
                    onSetArchived={setArchived}
                    onAskUserResponse={sendAskUserResponse}
                    onPermissionPromptResponse={sendPermissionPromptResponse}
                    onEditMessage={editMessage}
                    onEditRawEvent={editRawEvent}
                    entryPoints={
                      task.renderKey === draftRenderKey
                        ? entryPoints
                        : undefined
                    }
                    agentTypes={
                      task.renderKey === draftRenderKey ? agentTypes : undefined
                    }
                    defaultAgentType={
                      task.renderKey === draftRenderKey
                        ? effectiveDefaultAgent
                        : undefined
                    }
                    defaultTaskType={
                      task.renderKey === draftRenderKey
                        ? effectiveDefaultTaskType
                        : undefined
                    }
                    onContentStart={
                      task.renderKey === draftRenderKey
                        ? handleDraftContentStart
                        : undefined
                    }
                    onContentEnd={
                      task.renderKey === draftRenderKey
                        ? deleteDraftTask
                        : undefined
                    }
                  />
                </div>
              );
            })}
          {!active &&
            !hasDraftView &&
            (activeTaskId?.startsWith("archive") ? (
              <div class="session-empty">
                <div class="session-empty-inner">
                  <span class="archive-placeholder">Archived tasks</span>
                </div>
              </div>
            ) : activeTaskId === "import" ? (
              <div class="session-empty">
                <div class="session-empty-inner">
                  <span class="archive-placeholder">Importable sessions</span>
                </div>
              </div>
            ) : (
              <div class="session-empty">
                <div class="session-empty-inner">
                  <span>Loading task…</span>
                </div>
              </div>
            ))}
          {searchPopup}
          <Toast
            toasts={toasts}
            onDismiss={dismissToast}
            onClearAll={clearToasts}
          />
        </div>
      </ThemeContext.Provider>
    </DevModeContext.Provider>
  );
}

function NotFound() {
  return (
    <div class="not-found">
      <h1>Page not found</h1>
      <p>The URL you requested does not match any known route.</p>
      <a href="/">Go to home</a>
    </div>
  );
}

export function App() {
  return (
    <ErrorBoundary>
      <Router>
        <Route path="/task/:tid" component={AppContent} />
        <Route path="/:workspace/:project/task/:tid" component={AppContent} />
        <Route
          path="/:workspace/:project/archive/:parentTid"
          component={AppContent}
        />
        <Route path="/:workspace/:project/archive" component={AppContent} />
        <Route path="/:workspace/:project/import" component={AppContent} />
        <Route
          path="/:workspace/:project/session/:sid"
          component={AppContent}
        />
        <Route path="/:workspace/:project" component={AppContent} />
        <Route path="/archive/:parentTid" component={AppContent} />
        <Route path="/archive" component={AppContent} />
        <Route path="/import" component={AppContent} />
        <Route path="/" component={AppContent} />
        <Route default component={NotFound} />
      </Router>
    </ErrorBoundary>
  );
}
