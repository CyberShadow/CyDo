import { h } from "preact";
import { useRef, useEffect, useState } from "preact/hooks";
import type { TaskState } from "../types";
import type { TaskTypeInfo } from "../useSessionManager";
import type { Theme } from "../useTheme";
import { SystemBanner } from "./SystemBanner";
import { MessageList } from "./MessageList";
import { InputBox } from "./InputBox";
import { SessionConfig } from "./SessionConfig";

interface Props {
  task: TaskState;
  connected: boolean;
  isActive: boolean;
  onSend: (text: string, taskType?: string) => void;
  onInterrupt: () => void;
  onStop: () => void;
  onCloseStdin: () => void;
  onResume: () => void;
  onFork: (tid: number, afterUuid: string) => void;
  theme: Theme;
  onToggleTheme: () => void;
  taskTypes: TaskTypeInfo[];
}

export function SessionView({
  task,
  connected,
  isActive,
  onSend,
  onInterrupt,
  onStop,
  onCloseStdin,
  onResume,
  onFork,
  theme,
  onToggleTheme,
  taskTypes,
}: Props) {
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const [selectedTaskType, setSelectedTaskType] = useState("conversation");

  useEffect(() => {
    if (!isActive) return;
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
  }, [isActive]);

  return (
    <>
      <SystemBanner
        sessionInfo={task.sessionInfo}
        connected={connected}
        totalCost={task.totalCost}
        isProcessing={task.isProcessing}
        alive={task.alive}
        theme={theme}
        onToggleTheme={onToggleTheme}
        onStop={onStop}
        onCloseStdin={onCloseStdin}
      />
      {!task.historyLoaded ? (
        <div class="session-loading">
          <span>Loading session…</span>
        </div>
      ) : task.messages.length === 0 && !task.isProcessing ? (
        <div class="message-list welcome-prompt">
          <div class="welcome-box">
            <h1 class="welcome-title">CyDo</h1>
            <p class="welcome-subtitle">Multi-agent orchestration system</p>
            <SessionConfig
              taskTypes={taskTypes}
              selected={selectedTaskType || taskTypes[0]?.name || ""}
              onTaskTypeChange={setSelectedTaskType}
            />
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
          onSend={(text: string) => {
            // Pass task type on first message (when welcome screen is showing)
            if (task.messages.length === 0 && !task.isProcessing) {
              onSend(text, selectedTaskType || taskTypes[0]?.name);
            } else {
              onSend(text);
            }
          }}
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
