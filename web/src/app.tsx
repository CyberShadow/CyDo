import { ThemeToggle } from "./components/ThemeToggle";
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
import { SystemBanner } from "./components/SystemBanner";
import { WelcomePage } from "./components/WelcomePage";
import { RefreshWorkspacesButton } from "./components/RefreshWorkspacesButton";
import { SearchPopup } from "./components/SearchPopup";
import { ErrorBoundary } from "./components/ErrorBoundary";
import { Toast } from "./components/Toast";
import { createdByLink } from "./createdByLink";
import { subtaskResultParent } from "./subtaskResultParent";
import {
  createControlledImageStore,
  resetControlledImageStore,
} from "./controlledImageStore";
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
    getActiveTaskId,
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
    unsendMessage,
    approveRetry,
    undoConfirm,
    undoDismiss,
    dismissAttention,
    clearInputDraft,
    ordinaryDraftStore,
    setTaskTitle,
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
    ui,
    heicConversion,
    getHeicConversion,
    navigateHome,
    navigateToProject,
    getProjectHref,
    getTaskHref,
    getByTid,
    refreshWorkspaces,
    scanState,
  } = useTaskManager(addToast, controlledImageStore);
  const browserTaskId = getActiveTaskId();
  const tasksLoading = connected && !tasksLoaded;
  const continuationPredecessors = useMemo(() => {
    const predecessors = new Set<number>();
    for (const task of tasks.values()) {
      if (task.relationType === "continuation" && task.parentTid) {
        predecessors.add(task.parentTid);
      }
    }
    return predecessors;
  }, [tasks]);
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
  useLayoutEffect(() => {
    if (!connected) {
      setShowSearch(false);
      return;
    }

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
  }, [connected]);

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
      tasksLoaded={tasksLoaded}
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
            <ThemeToggle corner theme={theme} onToggle={toggleTheme} />
            {connected ? (
              <WelcomePage
                workspaces={workspaces}
                tasks={tasks}
                tasksLoaded={tasksLoaded}
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
      const order = flatTaskOrder(sidebarTasks, ui.sidebar);
      const visual =
        ui.sidebar?.order === "newest_first"
          ? [null, ...order]
          : [...order, null];
      const idx = visual.indexOf(activeTaskId);
      const len = visual.length;
      const dir = e.key === "ArrowUp" ? -1 : 1;
      if (e.shiftKey) {
        // Jump to next/prev task with attention, wrapping around.
        let next: string | undefined;
        for (let i = 1; i <= len; i++) {
          const candidate =
            visual[((idx === -1 ? 0 : idx) + dir * i + len) % len];
          if (candidate != null && attention.has(Number(candidate))) {
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
        const next = visual[(idx + dir + len) % len] ?? null;
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
    ui.sidebar,
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

  const placeholderContent = activeTaskId?.startsWith("archive") ? (
    <span class="archive-placeholder">Archived tasks</span>
  ) : activeTaskId === "import" ? (
    <div class="import-placeholder">
      <span class="archive-placeholder">Importable sessions</span>
      <RefreshWorkspacesButton
        onClick={refreshWorkspaces}
        scanState={scanState}
        label="Rescan for importable sessions"
      />
    </div>
  ) : tasksLoaded && activeTaskId !== null && active === null ? (
    <>
      <span>Task {activeTaskId} not found</span>
      <a href="/">Go to home</a>
    </>
  ) : (
    <span>Loading task…</span>
  );

  const placeholderBar = (
    <SystemBanner
      connected={connected}
      tasksLoading={tasksLoading}
      theme={theme}
      onToggleTheme={toggleTheme}
      onToggleSidebar={toggleSidebar}
      hasGlobalAttention={attention.size > 0}
    />
  );

  return (
    <DevModeContext.Provider value={devMode}>
      <ThemeContext.Provider value={theme}>
        <div class={`app has-sidebar${sidebarOpen ? " sidebar-open" : ""}`}>
          {sidebarOpen && (
            <div class="sidebar-backdrop" onClick={handleCloseSidebar} />
          )}
          <Sidebar
            tasks={sidebarTasks}
            tasksLoading={tasksLoading}
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
            onOpenSearch={connected ? handleOpenSearch : undefined}
            onArchive={handleSidebarArchive}
            hasGlobalAttention={hasOtherProjectAttention}
            claudeUsage={
              active?.usageProfile ? agentUsage[active.usageProfile] : undefined
            }
            ui={ui}
          />
          {connected ? (
            <>
              {draftView && (
                <div key={draftView.viewKey} style={{ display: "contents" }}>
                  <DraftSessionView
                    heicConversion={heicConversion}
                    getHeicConversion={getHeicConversion}
                    draftView={draftView}
                    createdBy={createdByLink(
                      draftView.kind === "resolved" &&
                        draftView.remoteTid !== null
                        ? getByTid(draftView.remoteTid)
                        : undefined,
                      getByTid,
                      getTaskHref,
                    )}
                    connected={connected}
                    tasksLoading={tasksLoading}
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
                    String(t.tid) === browserTaskId
                  );
                })
                .map((task) => {
                  if (task.tid === null) {
                    throw new Error("Task pane requires a numeric tid");
                  }
                  const isActive =
                    String(task.tid) === activeTaskId ||
                    String(task.tid) === browserTaskId;
                  const resultParentTid = tasksLoaded
                    ? subtaskResultParent(
                        {
                          tid: task.tid,
                          status: task.status,
                          parentTid: task.parentTid,
                          relationType: task.relationType,
                        },
                        continuationPredecessors,
                        getByTid,
                      )
                    : undefined;
                  const agent = agents.find(
                    ({ name }) =>
                      name === (task.agentName || task.sessionInfo?.agent_name),
                  );
                  return (
                    <div
                      key={task.uuid}
                      data-tid={task.tid}
                      style={{ display: isActive ? "contents" : "none" }}
                    >
                      <SessionView
                        addToast={addToast}
                        heicConversion={heicConversion}
                        getHeicConversion={getHeicConversion}
                        task={task}
                        createdBy={createdByLink(task, getByTid, getTaskHref)}
                        connected={connected}
                        tasksLoading={tasksLoading}
                        isActive={isActive}
                        onSend={send}
                        onInterrupt={interrupt}
                        onStop={stop}
                        onCloseStdin={closeStdin}
                        onResume={resume}
                        onPromote={promote}
                        onFork={fork}
                        onUndo={undoPreview}
                        onUnsend={unsendMessage}
                        onApproveRetry={approveRetry}
                        onUndoConfirm={undoConfirm}
                        onUndoDismiss={undoDismiss}
                        onClearInputDraft={clearInputDraft}
                        ordinaryDraftStore={ordinaryDraftStore}
                        onSaveDraft={saveDraft}
                        theme={theme}
                        onToggleTheme={toggleTheme}
                        onToggleSidebar={toggleSidebar}
                        hasGlobalAttention={attention.size > 0}
                        onSetTaskTitle={setTaskTitle}
                        onSetArchived={setArchived}
                        onAskUserResponse={sendAskUserResponse}
                        onPermissionPromptResponse={
                          sendPermissionPromptResponse
                        }
                        onEditMessage={editMessage}
                        onEditRawEvent={editRawEvent}
                        agentDisplayName={agent?.display_name ?? agent?.driver}
                        getTaskHref={getTaskHref}
                        subtaskEnd={
                          resultParentTid === undefined
                            ? undefined
                            : {
                                parentHref: getTaskHref(
                                  String(resultParentTid),
                                ),
                                parentTitle: getByTid(resultParentTid)?.title,
                                failed: task.status === "failed",
                              }
                        }
                      />
                    </div>
                  );
                })}
              {!draftView && !activeTaskPaneRenderable && (
                <>
                  {placeholderBar}
                  <div class="session-empty">
                    <div class="session-empty-inner">{placeholderContent}</div>
                  </div>
                </>
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
            </>
          ) : (
            placeholderBar
          )}
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
    <div class="modal-overlay" onClick={onDismiss}>
      <div
        class="modal-dialog command-error-dialog"
        onClick={(e) => {
          e.stopPropagation();
        }}
      >
        <div class="modal-dialog-header">Command failed</div>
        <div class="command-error-message">{message}</div>
        <div class="modal-dialog-actions">
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
