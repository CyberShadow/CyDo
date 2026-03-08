import { h } from "preact";
import { useEffect } from "preact/hooks";
import { useTaskManager } from "./useSessionManager";
import { useNotifications } from "./useNotifications";
import { useTheme, ThemeContext } from "./useTheme";
import { InputBox } from "./components/InputBox";
import { Sidebar } from "./components/Sidebar";
import { SessionView } from "./components/SessionView";
import { WelcomePage } from "./components/WelcomePage";

export function App() {
  const {
    tasks,
    activeTaskId,
    setActiveTaskId,
    connected,
    send,
    interrupt,
    newTask,
    resume,
    fork,
    dismissAttention,
    sidebarTasks,
    workspaces,
    activeWorkspace,
    activeProject,
    navigateHome,
    navigateToProject,
  } = useTaskManager();

  const { theme, toggleTheme } = useTheme();
  const attention = useNotifications(activeTaskId, dismissAttention);

  const active =
    activeTaskId !== null ? (tasks.get(activeTaskId) ?? null) : null;

  useEffect(() => {
    document.title = active?.title ? `${active.title} — CyDo` : "CyDo";
  }, [active?.title]);

  // Welcome page: no workspace selected (on /)
  if (activeWorkspace === null && activeTaskId === null) {
    return (
      <ThemeContext.Provider value={theme}>
        <div class="app welcome-page-container">
          <WelcomePage
            workspaces={workspaces}
            tasks={tasks}
            attention={attention}
            onNewTask={newTask}
            onSelectTask={setActiveTaskId}
            onNavigateToProject={navigateToProject}
          />
        </div>
      </ThemeContext.Provider>
    );
  }

  // Project view with sidebar
  const handleNewTask = () => {
    if (activeWorkspace && activeProject) {
      // Find the absolute project path
      const ws = workspaces.find((w) => w.name === activeWorkspace);
      const proj = ws?.projects.find((p) => p.name === activeProject);
      newTask(activeWorkspace, proj?.path || "");
    } else {
      newTask();
    }
  };

  return (
    <ThemeContext.Provider value={theme}>
      <div class="app has-sidebar">
        <Sidebar
          tasks={sidebarTasks}
          activeTaskId={activeTaskId}
          attention={attention}
          onSelectTask={setActiveTaskId}
          onNewTask={handleNewTask}
          showBackButton={true}
          onBack={navigateHome}
          projectName={activeProject || undefined}
        />
        {active ? (
          <SessionView
            task={active}
            connected={connected}
            onSend={send}
            onInterrupt={interrupt}
            onResume={resume}
            onFork={fork}
            theme={theme}
            onToggleTheme={toggleTheme}
          />
        ) : (
          <div class="session-empty">
            <div class="session-empty-inner">
              <p>Select a task or create a new one</p>
              <InputBox
                onSend={send}
                onInterrupt={interrupt}
                isProcessing={false}
                disabled={!connected}
                sessionId={0}
              />
            </div>
          </div>
        )}
      </div>
    </ThemeContext.Provider>
  );
}
