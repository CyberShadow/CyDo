import { h } from "preact";
import { useRef, useEffect } from "preact/hooks";
import type { SessionState } from "../types";
import type { Theme } from "../useTheme";
import { SystemBanner } from "./SystemBanner";
import { MessageList } from "./MessageList";
import { InputBox } from "./InputBox";

interface Props {
  session: SessionState;
  connected: boolean;
  onSend: (text: string) => void;
  onInterrupt: () => void;
  onResume: () => void;
  onFork: (sid: number, afterUuid: string) => void;
  theme: Theme;
  onToggleTheme: () => void;
}

export function SessionView({
  session,
  connected,
  onSend,
  onInterrupt,
  onResume,
  onFork,
  theme,
  onToggleTheme,
}: Props) {
  const inputRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      const target = e.target;
      if (
        target instanceof HTMLTextAreaElement ||
        target instanceof HTMLInputElement
      )
        return;
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      if (e.key.length !== 1) return;

      inputRef.current?.focus();
    };
    document.addEventListener("keydown", handler);
    return () => document.removeEventListener("keydown", handler);
  }, []);

  if (!session.historyLoaded) {
    return (
      <div class="session-loading">
        <span>Loading session…</span>
      </div>
    );
  }

  return (
    <>
      <SystemBanner
        sessionInfo={session.sessionInfo}
        connected={connected}
        totalCost={session.totalCost}
        isProcessing={session.isProcessing}
        theme={theme}
        onToggleTheme={onToggleTheme}
      />
      {session.messages.length === 0 && !session.isProcessing ? (
        <div class="message-list welcome-prompt">
          <div class="welcome-box">
            <h1 class="welcome-title">CyDo</h1>
            <p class="welcome-subtitle">Multi-agent orchestration system</p>
          </div>
        </div>
      ) : (
        <MessageList
          sessionId={session.sid}
          messages={session.messages}
          isProcessing={session.isProcessing}
          onFork={onFork}
          forkableUuids={session.forkableUuids}
        />
      )}
      {session.resumable ? (
        <div class="resume-bar">
          <button class="btn btn-resume" onClick={onResume}>
            Resume Session
          </button>
        </div>
      ) : (
        <InputBox
          onSend={onSend}
          onInterrupt={onInterrupt}
          isProcessing={session.isProcessing}
          disabled={!connected}
          sessionId={session.sid}
          preReloadDrafts={session.preReloadDrafts}
          inputRef={inputRef}
        />
      )}
    </>
  );
}
