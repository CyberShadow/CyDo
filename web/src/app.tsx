import { h } from "preact";
import { useEffect } from "preact/hooks";
import { useSessionManager } from "./useSessionManager";
import { useNotifications } from "./useNotifications";
import { useTheme, ThemeContext } from "./useTheme";
import { InputBox } from "./components/InputBox";
import { Sidebar } from "./components/Sidebar";
import { SessionView } from "./components/SessionView";
import { WelcomePage } from "./components/WelcomePage";

export function App() {
  const {
    sessions,
    activeSessionId,
    setActiveSessionId,
    connected,
    send,
    interrupt,
    newSession,
    resume,
    fork,
    sidebarSessions,
    workspaces,
    activeWorkspace,
    activeProject,
    navigateHome,
    navigateToProject,
  } = useSessionManager();

  const { theme, toggleTheme } = useTheme();
  const attention = useNotifications(activeSessionId);

  const active =
    activeSessionId !== null ? (sessions.get(activeSessionId) ?? null) : null;

  useEffect(() => {
    document.title = active?.title ? `${active.title} — CyDo` : "CyDo";
  }, [active?.title]);

  // Welcome page: no workspace selected (on /)
  if (activeWorkspace === null && activeSessionId === null) {
    return (
      <ThemeContext.Provider value={theme}>
        <div class="app welcome-page-container">
          <WelcomePage
            workspaces={workspaces}
            sessions={sessions}
            attention={attention}
            onNewSession={newSession}
            onSelectSession={setActiveSessionId}
            onNavigateToProject={navigateToProject}
          />
        </div>
      </ThemeContext.Provider>
    );
  }

  // Project view with sidebar
  const handleNewSession = () => {
    if (activeWorkspace && activeProject) {
      // Find the absolute project path
      const ws = workspaces.find((w) => w.name === activeWorkspace);
      const proj = ws?.projects.find((p) => p.name === activeProject);
      newSession(activeWorkspace, proj?.path || "");
    } else {
      newSession();
    }
  };

  return (
    <ThemeContext.Provider value={theme}>
      <div class="app has-sidebar">
        <Sidebar
          sessions={sidebarSessions}
          activeSessionId={activeSessionId}
          attention={attention}
          onSelectSession={setActiveSessionId}
          onNewSession={handleNewSession}
          showBackButton={true}
          onBack={navigateHome}
          projectName={activeProject || undefined}
        />
        {active ? (
          <SessionView
            session={active}
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
              <p>Select a session or create a new one</p>
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
