import { h } from "preact";
import { useEffect, useState } from "preact/hooks";
import { useTaskManager } from "./useSessionManager";
import { useNotifications } from "./useNotifications";
import { useTheme, ThemeContext } from "./useTheme";
import { InputBox } from "./components/InputBox";
import { Sidebar, flatTaskOrder } from "./components/Sidebar";
import { SessionView } from "./components/SessionView";
import { WelcomePage } from "./components/WelcomePage";
import { SearchPopup } from "./components/SearchPopup";

export function App() {
  const {
    tasks,
    activeTaskId,
    setActiveTaskId,
    connected,
    send,
    interrupt,
    stop,
    closeStdin,
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
  const [showSearch, setShowSearch] = useState(false);

  const active =
    activeTaskId !== null ? (tasks.get(activeTaskId) ?? null) : null;

  useEffect(() => {
    document.title = active?.title ? `${active.title} — CyDo` : "CyDo";
  }, [active?.title]);

  // Alt+Up / Alt+Down: navigate between sidebar sessions
  // Alt+Shift+Up / Alt+Shift+Down: jump to next/prev session with attention
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (!e.altKey || (e.key !== "ArrowUp" && e.key !== "ArrowDown")) return;
      const order = flatTaskOrder(sidebarTasks);
      if (order.length === 0) return;
      const idx = activeTaskId !== null ? order.indexOf(activeTaskId) : -1;
      let next: number | undefined;
      if (e.shiftKey) {
        // Jump to next/prev task with attention, wrapping around
        const len = order.length;
        const dir = e.key === "ArrowUp" ? -1 : 1;
        for (let i = 1; i <= len; i++) {
          const candidate =
            order[((idx === -1 ? 0 : idx) + dir * i + len) % len];
          if (attention.has(candidate)) {
            next = candidate;
            break;
          }
        }
        if (next === undefined) return;
      } else {
        next =
          e.key === "ArrowUp"
            ? idx <= 0
              ? order[order.length - 1]
              : order[idx - 1]
            : idx === -1 || idx >= order.length - 1
              ? order[0]
              : order[idx + 1];
      }
      setActiveTaskId(next);
      document
        .querySelector(`.sidebar-item[data-tid="${next}"]`)
        ?.scrollIntoView({ block: "nearest" });
      e.preventDefault();
    };
    document.addEventListener("keydown", handler);
    return () => document.removeEventListener("keydown", handler);
  }, [sidebarTasks, activeTaskId, setActiveTaskId, attention]);

  // Ctrl+K: open search popup
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key === "k") {
        e.preventDefault();
        setShowSearch((v) => !v);
      }
    };
    document.addEventListener("keydown", handler);
    return () => document.removeEventListener("keydown", handler);
  }, []);

  const searchPopup = showSearch && (
    <SearchPopup
      tasks={tasks}
      onSelect={setActiveTaskId}
      onClose={() => {
        setShowSearch(false);
        // Re-focus the input box after dismissing search
        requestAnimationFrame(() => {
          (document.querySelector(".input-textarea") as HTMLElement)?.focus();
        });
      }}
    />
  );

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
          {searchPopup}
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
            onStop={stop}
            onCloseStdin={closeStdin}
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
        {searchPopup}
      </div>
    </ThemeContext.Provider>
  );
}
