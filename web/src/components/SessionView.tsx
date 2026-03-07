import { h } from "preact";
import { useRef, useEffect } from "preact/hooks";
import type { TaskState } from "../types";
import type { Theme } from "../useTheme";
import { SystemBanner } from "./SystemBanner";
import { MessageList } from "./MessageList";
import { InputBox } from "./InputBox";

interface Props {
  task: TaskState;
  connected: boolean;
  onSend: (text: string) => void;
  onInterrupt: () => void;
  onResume: () => void;
  onFork: (tid: number, afterUuid: string) => void;
  theme: Theme;
  onToggleTheme: () => void;
}

export function SessionView({
  task,
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

  if (!task.historyLoaded) {
    return (
      <div class="session-loading">
        <span>Loading session…</span>
      </div>
    );
  }

  return (
    <>
      <SystemBanner
        sessionInfo={task.sessionInfo}
        connected={connected}
        totalCost={task.totalCost}
        isProcessing={task.isProcessing}
        theme={theme}
        onToggleTheme={onToggleTheme}
      />
      {task.messages.length === 0 && !task.isProcessing ? (
        <div class="message-list welcome-prompt">
          <div class="welcome-box">
            <h1 class="welcome-title">CyDo</h1>
            <p class="welcome-subtitle">Multi-agent orchestration system</p>
          </div>
        </div>
      ) : (
        <MessageList
          sessionId={task.tid}
          messages={task.messages}
          isProcessing={task.isProcessing}
          onFork={onFork}
          forkableUuids={task.forkableUuids}
        />
      )}
      {task.resumable ? (
        <div class="resume-bar">
          <button class="btn btn-resume" onClick={onResume}>
            Resume Session
          </button>
        </div>
      ) : (
        <InputBox
          onSend={onSend}
          onInterrupt={onInterrupt}
          isProcessing={task.isProcessing}
          disabled={!connected}
          sessionId={task.tid}
          preReloadDrafts={task.preReloadDrafts}
          inputRef={inputRef}
        />
      )}
    </>
  );
}
