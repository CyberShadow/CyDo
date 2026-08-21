import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "preact/hooks";
import { Router, Route } from "preact-iso";
import { parseTaskId, useTaskManager } from "./useSessionManager";
import { useNotifications } from "./useNotifications";
import { useToast } from "./useToast";
import { useErrorCapture } from "./useErrorOverlay";
import { useTheme, ThemeContext } from "./useTheme";
import { DevModeContext } from "./devMode";
import { Sidebar, flatTaskOrder } from "./components/Sidebar";
import { DraftSessionView, SessionView } from "./components/SessionView";
import { WelcomePage } from "./components/WelcomePage";
import { SearchPopup } from "./components/SearchPopup";
import { ErrorBoundary } from "./components/ErrorBoundary";
import { Toast } from "./components/Toast";
import {
  createControlledImageStore,
  resetControlledImageStore,
} from "./components/InputBox";
import "./e2e";

function shortProjectName(projectName: string): string {
  const slash = projectName.lastIndexOf("/");
  return slash === -1 ? projectName : projectName.slice(slash + 1);
}

function AppContent() {
  const [controlledImageStore] = useState(createControlledImageStore);
  const { toasts, addToast, dismissToast, clearToasts } = useToast();
  const {
    tasks,
    activeTaskId,
    activeTaskIdRef,
    setActiveTaskId,
    connected,
    tasksLoaded,
    send,
    interrupt,
    stop,
    closeStdin,
    resume,
    promote,
    fork,
    undo,
    undoPreview,
    undoConfirm,
    undoDismiss,
    dismissAttention,
    clearInputDraft,
    setArchived,
    saveDraft,
    sendAskUserResponse,
    sendPermissionPromptResponse,
    editMessage,
    editRawEvent,
    draftView,
    sidebarTasks,
    workspaces,
    entryPoints,
    typeInfo,
    agents,
    defaultAgent,
    activeWorkspace,
    activeProject,
    notices,
    localNotices,
    agentUsage,
    serverError,
    dismissServerError,
    devMode,
    historyWindowStep,
    loadMoreHistory,
    navigateHome,
    navigateToProject,
    getProjectHref,
    getTaskHref,
    getByTid,
    refreshWorkspaces,
    scanState,
  } = useTaskManager(addToast);
  const previousConnectedRef = useRef(connected);
  useLayoutEffect(() => {
    const wasConnected = previousConnectedRef.current;
    previousConnectedRef.current = connected;
    if (wasConnected && !connected) {
      resetControlledImageStore(controlledImageStore);
    }
  }, [connected, controlledImageStore]);
  useEffect(() => {
    if (!window.__cydoE2e) return;
    window.__cydoE2e.fork = fork;
    window.__cydoE2e.undo = undo;
    return () => {
      delete window.__cydoE2e?.fork;
      delete window.__cydoE2e?.undo;
    };
  }, [fork, undo]);
  const mergedNotices = useMemo(
    () => ({ ...notices, ...localNotices }),
    [notices, localNotices],
  );

  const { theme, toggleTheme } = useTheme();
  const attention = useNotifications(
    activeTaskId,
    tasks,
    dismissAttention,
    getByTid,
  );
  useErrorCapture(addToast);

  const effectiveDefaultAgent = useMemo(() => {
    const ws = workspaces.find((w) => w.name === activeWorkspace);
    return ws?.default_agent || defaultAgent;
  }, [workspaces, activeWorkspace, defaultAgent]);
  const [showSearch, setShowSearch] = useState(false);
  const [sidebarOpen, setSidebarOpen] = useState(false);

  const toggleSidebar = useCallback(() => {
    setSidebarOpen((v) => !v);
  }, []);

  const activeTid = parseTaskId(activeTaskId);
  const active = activeTid !== null ? (getByTid(activeTid) ?? null) : null;
  const activeTaskPaneRenderable =
    active !== null &&
    !(
      active.status === "pending" &&
      active.messages.length === 0 &&
      !active.isProcessing
    ) &&
    !(draftView?.kind === "resolved" && draftView.remoteTid === active.tid);

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
    if ("setAppBadge" in navigator) {
      // App badge is optional and may be blocked by browser/OS policy.
      void navigator.setAppBadge(count).catch(() => {});
    }
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
                notices={mergedNotices}
                onSelectTask={handleSearchSelect}
                onNavigateToProject={navigateToProject}
                getProjectHref={getProjectHref}
                getTaskHref={getTaskHref}
                onRefreshWorkspaces={refreshWorkspaces}
                scanState={scanState}
              />
            ) : (
              <div class="connection-overlay">
                <span>Connecting…</span>
              </div>
            )}
            {searchPopup}
            {serverError && (
              <CommandErrorDialog
                message={serverError.message}
                onDismiss={dismissServerError}
              />
            )}
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
        if (active && active.tid !== null) {
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
          closeStdin(active.uuid);
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
  // Ctrl+Shift+H: go to home page
  // Ctrl+Shift+O: new task
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.shiftKey && e.key === "H") {
        e.preventDefault();
        navigateHome();
        return;
      }
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
  }, [
    sidebarTasks,
    activeTaskId,
    setActiveTaskId,
    attention,
    handleNewTask,
    navigateHome,
  ]);

  const handleCloseSidebar = useCallback(() => {
    setSidebarOpen(false);
  }, []);

  const handleOpenSearch = useCallback(() => {
    setShowSearch(true);
  }, []);

  const handleSidebarArchive = useCallback(
    (tid: number) => {
      const task = getByTid(tid);
      if (task) setArchived(tid, !task.archived);
    },
    [getByTid, setArchived],
  );

  const handleSidebarSelect = useCallback(() => {
    setSidebarOpen(false);
  }, []);

  const handleSidebarNewTask = useCallback(() => {
    setSidebarOpen(false);
  }, []);

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
          {draftView && (
            <div key={draftView.viewKey} style={{ display: "contents" }}>
              <DraftSessionView
                draftView={draftView}
                connected={connected}
                entryPoints={entryPoints}
                agents={agents}
                defaultAgent={effectiveDefaultAgent}
                notices={mergedNotices}
                theme={theme}
                onToggleTheme={toggleTheme}
                onToggleSidebar={toggleSidebar}
                hasGlobalAttention={attention.size > 0}
                imageStore={controlledImageStore}
              />
            </div>
          )}
          {Array.from(tasks.values())
            .filter((t) => {
              if (
                draftView?.kind === "resolved" &&
                draftView.remoteTid === t.tid
              )
                return false;
              if (
                t.status === "pending" &&
                t.messages.length === 0 &&
                !t.isProcessing
              )
                return false;
              return (
                t.everLoaded ||
                t.historyLoaded ||
                String(t.tid) === activeTaskId ||
                String(t.tid) === activeTaskIdRef.current
              );
            })
            .map((task) => {
              if (task.tid === null) {
                throw new Error("Task pane requires a numeric tid");
              }
              const isActive =
                String(task.tid) === activeTaskId ||
                String(task.tid) === activeTaskIdRef.current;
              return (
                <div
                  key={task.uuid}
                  data-tid={task.tid}
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
                    theme={theme}
                    onToggleTheme={toggleTheme}
                    onToggleSidebar={toggleSidebar}
                    hasGlobalAttention={attention.size > 0}
                    onSetArchived={setArchived}
                    onAskUserResponse={sendAskUserResponse}
                    onPermissionPromptResponse={sendPermissionPromptResponse}
                    onEditMessage={editMessage}
                    onEditRawEvent={editRawEvent}
                    defaultAgent={effectiveDefaultAgent}
                    agentUsage={agentUsage}
                    historyWindowStep={historyWindowStep}
                    onLoadMoreHistory={loadMoreHistory}
                    getTaskHref={getTaskHref}
                  />
                </div>
              );
            })}
          {!draftView &&
            !activeTaskPaneRenderable &&
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
            ) : tasksLoaded && activeTaskId !== null && active === null ? (
              <div class="session-empty">
                <div class="session-empty-inner">
                  <span>Task {activeTaskId} not found</span>
                  <a href="/">Go to home</a>
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
          {serverError && (
            <CommandErrorDialog
              message={serverError.message}
              onDismiss={dismissServerError}
            />
          )}
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

function CommandErrorDialog({
  message,
  onDismiss,
}: {
  message: string;
  onDismiss: () => void;
}) {
  return (
    <div class="undo-overlay" onClick={onDismiss}>
      <div
        class="undo-dialog command-error-dialog"
        onClick={(e) => {
          e.stopPropagation();
        }}
      >
        <div class="undo-dialog-header">Command failed</div>
        <div class="command-error-message">{message}</div>
        <div class="undo-dialog-actions">
          <button class="btn" onClick={onDismiss}>
            Dismiss
          </button>
        </div>
      </div>
    </div>
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
        <Route path="/archive/:parentTid" component={AppContent} />
        <Route path="/archive" component={AppContent} />
        <Route path="/:workspace/:project" component={AppContent} />
        <Route path="/import" component={AppContent} />
        <Route path="/" component={AppContent} />
        <Route default component={NotFound} />
      </Router>
    </ErrorBoundary>
  );
}
