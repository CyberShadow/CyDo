import { h } from "preact";
import { useSessionManager } from "./useSessionManager";
import { SystemBanner } from "./components/SystemBanner";
import { MessageList } from "./components/MessageList";
import { InputBox } from "./components/InputBox";
import { Sidebar } from "./components/Sidebar";

export function App() {
  const {
    sessions, activeSessionId, setActiveSessionId,
    connected, send, interrupt, newSession, resume,
    sidebarSessions,
  } = useSessionManager();

  const active = activeSessionId !== null ? sessions.get(activeSessionId) ?? null : null;

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
      <SystemBanner
        sessionInfo={active?.sessionInfo ?? null}
        connected={connected}
        totalCost={active?.totalCost ?? 0}
        isProcessing={active?.isProcessing ?? false}
      />
      <MessageList
        messages={active?.messages ?? []}
        streamingBlocks={active?.streamingBlocks ?? []}
        isProcessing={active?.isProcessing ?? false}
      />
      {active?.resumable ? (
        <div class="resume-bar">
          <button class="btn btn-resume" onClick={resume}>
            Resume Session
          </button>
        </div>
      ) : (
        <InputBox
          onSend={send}
          onInterrupt={interrupt}
          isProcessing={active?.isProcessing ?? false}
          disabled={!connected}
        />
      )}
    </div>
  );
}
