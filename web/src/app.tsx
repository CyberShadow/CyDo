import { h } from "preact";
import { useCallback, useEffect, useRef, useState } from "preact/hooks";
import { useTaskManager } from "./useSessionManager";
import { useNotifications } from "./useNotifications";
import { useTheme, ThemeContext } from "./useTheme";
import { InputBox } from "./components/InputBox";
import { SessionConfig } from "./components/SessionConfig";
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
    taskTypes,
    activeWorkspace,
    activeProject,
    navigateHome,
    navigateToProject,
  } = useTaskManager();

  const { theme, toggleTheme } = useTheme();
  const attention = useNotifications(activeTaskId, tasks, dismissAttention);
  const [showSearch, setShowSearch] = useState(false);

  const active =
    activeTaskId !== null ? (tasks.get(activeTaskId) ?? null) : null;

  useEffect(() => {
    document.title = active?.title ? `${active.title} — CyDo` : "CyDo";
  }, [active?.title]);

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
        // Re-focus the input box or resume button after dismissing search
        requestAnimationFrame(() => {
          const input = document.querySelector(
            ".input-textarea",
          ) as HTMLElement;
          const resume = document.querySelector(".btn-resume") as HTMLElement;
          (input ?? resume)?.focus();
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

  // Navigate to the "new task" view (project page with no tid)
  const handleNewTask = useCallback(() => {
    if (activeWorkspace && activeProject) {
      navigateToProject(activeWorkspace, activeProject);
    } else {
      navigateHome();
    }
  }, [activeWorkspace, activeProject, navigateToProject, navigateHome]);

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
        let next: number | undefined;
        for (let i = 1; i <= len; i++) {
          const candidate =
            order[((idx === -1 ? 0 : idx) + dir * i + len) % len];
          if (attention.has(candidate)) {
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
        const visual: (number | null)[] = [...order, null];
        const idx = visual.indexOf(activeTaskId);
        const dir = e.key === "ArrowUp" ? -1 : 1;
        const nextIdx = (idx + dir + visual.length) % visual.length;
        const next = visual[nextIdx];
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
    return () => document.removeEventListener("keydown", handler);
  }, [sidebarTasks, activeTaskId, setActiveTaskId, attention, handleNewTask]);

  const [selectedTaskType, setSelectedTaskType] = useState("conversation");
  const newTaskInputRef = useRef<HTMLTextAreaElement>(null);

  const focusNewTaskInput = useCallback(() => {
    newTaskInputRef.current?.focus();
  }, []);

  // Type anywhere to focus the new-task input (mirrors SessionView behavior)
  useEffect(() => {
    if (active || !connected) return;
    const handler = (e: KeyboardEvent) => {
      const target = e.target;
      if (
        target instanceof HTMLTextAreaElement ||
        target instanceof HTMLInputElement
      )
        return;
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      if (e.key.length !== 1) return;
      newTaskInputRef.current?.focus();
    };
    document.addEventListener("keydown", handler);
    return () => document.removeEventListener("keydown", handler);
  }, [active, connected]);

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
        {Array.from(tasks.values())
          .filter((t) => t.historyLoaded || t.tid === activeTaskId)
          .map((task) => {
            const isActive = task.tid === activeTaskId;
            return (
              <div
                key={task.tid}
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
                  onFork={fork}
                  theme={theme}
                  onToggleTheme={toggleTheme}
                />
              </div>
            );
          })}
        {!active &&
          (!connected ? (
            <div class="session-empty no-sidebar">
              <div class="session-empty-inner">
                <span>Connecting…</span>
              </div>
            </div>
          ) : (
            <div class="session-empty">
              <div class="session-empty-inner">
                <h1 class="welcome-title">CyDo</h1>
                <p class="welcome-subtitle">Multi-agent orchestration system</p>
                <SessionConfig
                  taskTypes={taskTypes}
                  selected={selectedTaskType}
                  onTaskTypeChange={(t: string) => {
                    setSelectedTaskType(t);
                    focusNewTaskInput();
                  }}
                />
                <InputBox
                  inputRef={newTaskInputRef}
                  onSend={(text: string) =>
                    send(text, selectedTaskType || taskTypes[0]?.name)
                  }
                  onInterrupt={interrupt}
                  isProcessing={false}
                  disabled={false}
                  sessionId={0}
                />
              </div>
            </div>
          ))}
        {searchPopup}
      </div>
    </ThemeContext.Provider>
  );
}
