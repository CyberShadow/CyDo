import { h } from "preact";
import { useSessionManager } from "./useSessionManager";
import { InputBox } from "./components/InputBox";
import { Sidebar } from "./components/Sidebar";
import { SessionView } from "./components/SessionView";

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
    sidebarSessions,
  } = useSessionManager();

  const active =
    activeSessionId !== null ? (sessions.get(activeSessionId) ?? null) : null;

  if (sessions.size === 0) {
    // Welcome screen — no sessions yet
    return (
      <div class="app welcome">
        <div class="welcome-box">
          <h1 class="welcome-title">CyDo</h1>
          <p class="welcome-subtitle">Multi-agent orchestration system</p>
          <InputBox
            onSend={send}
            onInterrupt={interrupt}
            isProcessing={false}
            disabled={!connected}
            sessionId={0}
          />
        </div>
      </div>
    );
  }

  return (
    <div class="app has-sidebar">
      <Sidebar
        sessions={sidebarSessions}
        activeSessionId={activeSessionId}
        onSelectSession={setActiveSessionId}
        onNewSession={newSession}
      />
      {active && (
        <SessionView
          session={active}
          connected={connected}
          onSend={send}
          onInterrupt={interrupt}
          onResume={resume}
        />
      )}
    </div>
  );
}
