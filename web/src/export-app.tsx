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
    tasks,
    activeTaskId,
    setActiveTaskId,
    sidebarTasks,
    typeInfo,
    getTaskHref,
  } = useExportedTaskManager();

  const { theme, toggleTheme } = useTheme();
  const [sidebarOpen, setSidebarOpen] = useState(false);

  const activeTid = activeTaskId !== null ? parseInt(activeTaskId, 10) : NaN;
  const active = !isNaN(activeTid) ? (tasks.get(activeTid) ?? null) : null;

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
          onNewTask={noop}
          newTaskHref="#"
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
          />
        ) : (
          <div class="session-empty">
            <div class="session-empty-inner">
              <span>Select a task from the sidebar</span>
            </div>
          </div>
        )}
      </div>
    </ThemeContext.Provider>
  );
}
