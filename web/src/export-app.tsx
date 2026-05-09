import { useCallback, useState } from "preact/hooks";
import { useExportedTaskManager } from "./useExportedTaskManager";
import { useTheme, ThemeContext } from "./useTheme";
import { Sidebar } from "./components/Sidebar";
import { SessionView } from "./components/SessionView";

const noop = () => {
  // no-op for read-only export
};

export function ExportApp() {
  const {
    activeTaskId,
    setActiveTaskId,
    sidebarTasks,
    typeInfo,
    getTaskHref,
    getByTid,
    exportLoadError,
  } = useExportedTaskManager();

  const { theme, toggleTheme } = useTheme();
  const [sidebarOpen, setSidebarOpen] = useState(false);

  const activeTid = activeTaskId !== null ? parseInt(activeTaskId, 10) : NaN;
  const active = !isNaN(activeTid) ? (getByTid(activeTid) ?? null) : null;

  const handleSidebarSelect = useCallback(
    (id: string) => {
      setActiveTaskId(id);
      setSidebarOpen(false);
    },
    [setActiveTaskId],
  );

  const handleCloseSidebar = useCallback(() => {
    setSidebarOpen(false);
  }, []);

  const handleToggleSidebar = useCallback(() => {
    setSidebarOpen((v) => !v);
  }, []);

  return (
    <ThemeContext.Provider value={theme}>
      <div class={`app has-sidebar${sidebarOpen ? " sidebar-open" : ""}`}>
        {sidebarOpen && (
          <div class="sidebar-backdrop" onClick={handleCloseSidebar} />
        )}
        <Sidebar
          tasks={sidebarTasks}
          activeTaskId={activeTaskId}
          attention={new Set()}
          onSelectTask={handleSidebarSelect}
          showBackButton={false}
          getTaskHref={getTaskHref}
          taskTypes={typeInfo}
          visible={sidebarOpen}
        />
        {active ? (
          <SessionView
            task={active}
            connected={false}
            isActive={true}
            onSend={noop}
            onInterrupt={noop}
            onStop={noop}
            onCloseStdin={noop}
            onResume={noop}
            onFork={noop}
            onUndo={noop}
            onUndoConfirm={noop}
            onUndoDismiss={noop}
            onClearInputDraft={noop}
            onAskUserResponse={noop}
            onPermissionPromptResponse={noop}
            theme={theme}
            onToggleTheme={toggleTheme}
            onToggleSidebar={handleToggleSidebar}
            exportMode={true}
            getTaskHref={getTaskHref}
          />
        ) : (
          <div class="session-empty">
            <div class="session-empty-inner">
              {exportLoadError ? (
                <>
                  <span>Failed to load exported task data</span>
                  <details>
                    <summary>Details</summary>
                    <pre>{exportLoadError}</pre>
                  </details>
                </>
              ) : (
                <span>Select a task from the sidebar</span>
              )}
            </div>
          </div>
        )}
      </div>
    </ThemeContext.Provider>
  );
}
