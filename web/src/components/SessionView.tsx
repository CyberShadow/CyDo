import { h } from "preact";
import { useRef, useEffect } from "preact/hooks";
import { MarkdownQuote } from "../vendor/quote-selection";
import type { TaskState } from "../types";
import type { Theme } from "../useTheme";
import { SystemBanner } from "./SystemBanner";
import { MessageList } from "./MessageList";
import { InputBox } from "./InputBox";

interface Props {
  task: TaskState;
  connected: boolean;
  isActive: boolean;
  onSend: (text: string) => void;
  onInterrupt: () => void;
  onStop: () => void;
  onCloseStdin: () => void;
  onResume: () => void;
  onFork: (tid: number, afterUuid: string) => void;
  theme: Theme;
  onToggleTheme: () => void;
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
}: Props) {
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const insertTextRef = useRef<((text: string) => void) | null>(null);
  const resumeRef = useRef<HTMLButtonElement>(null);

  // Auto-focus input box or resume button when session becomes active
  useEffect(() => {
    if (!isActive) return;
    if (task.resumable) {
      resumeRef.current?.focus();
    } else {
      inputRef.current?.focus();
    }
  }, [isActive, task.resumable]);

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

      // Quote-reply: press r with text selected inside the message list
      if (e.key === "r") {
        const sel = window.getSelection();
        if (sel && !sel.isCollapsed) {
          const anchor =
            sel.anchorNode instanceof Element
              ? sel.anchorNode
              : sel.anchorNode?.parentElement;
          if (anchor?.closest(".message-list")) {
            e.preventDefault();
            const quote = new MarkdownQuote();
            const text = quote.quotedText;
            if (text) {
              insertTextRef.current?.(text);
              sel.removeAllRanges();
            }
            return;
          }
        }
      }

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
        taskType={task.taskType}
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
          <button ref={resumeRef} class="btn btn-resume" onClick={onResume}>
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
          insertTextRef={insertTextRef}
        />
      )}
    </>
  );
}
