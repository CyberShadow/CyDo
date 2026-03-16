import { h } from "preact";
import { useRef, useEffect, useState, useCallback } from "preact/hooks";
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
  onUndo: (tid: number, afterUuid: string) => void;
  onUndoConfirm: (
    tid: number,
    revertConversation: boolean,
    revertFiles: boolean,
  ) => void;
  onUndoDismiss: (tid: number) => void;
  onClearInputDraft: (tid: number) => void;
  onSaveDraft?: (tid: number, draft: string) => void;
  theme: Theme;
  onToggleTheme: () => void;
  onToggleSidebar: () => void;
  onSetArchived?: (tid: number, archived: boolean) => void;
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
  onUndo,
  onUndoConfirm,
  onUndoDismiss,
  onClearInputDraft,
  onSaveDraft,
  theme,
  onToggleTheme,
  onToggleSidebar,
  onSetArchived,
}: Props) {
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const insertTextRef = useRef<((text: string) => void) | null>(null);
  const resumeRef = useRef<HTMLButtonElement>(null);

  // Auto-focus input box or resume button when session becomes active.
  // Skip on touch devices to avoid opening the virtual keyboard.
  useEffect(() => {
    if (!isActive) return;
    if (matchMedia("(pointer: coarse)").matches) return;
    if (task.resumable) {
      resumeRef.current?.focus();
    } else {
      inputRef.current?.focus();
    }
  }, [isActive, task.resumable]);

  const handleSaveDraft = useCallback(
    (draft: string) => onSaveDraft?.(task.tid, draft),
    [onSaveDraft, task.tid],
  );

  const quoteSelection = () => {
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed) return false;
    const anchor =
      sel.anchorNode instanceof Element
        ? sel.anchorNode
        : sel.anchorNode?.parentElement;
    if (!anchor?.closest(".message-list")) return false;
    const quote = new MarkdownQuote();
    const text = quote.quotedText;
    if (text) {
      insertTextRef.current?.(text);
      sel.removeAllRanges();
      return true;
    }
    return false;
  };

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
        if (quoteSelection()) {
          e.preventDefault();
          return;
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
        onToggleSidebar={onToggleSidebar}
        archived={task.archived}
        onSetArchived={
          onSetArchived
            ? () => onSetArchived(task.tid, !task.archived)
            : undefined
        }
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
          onUndo={onUndo}
          forkableUuids={task.forkableUuids}
        />
      )}
      {task.undoPending && task.undoPending.messagesRemoved >= 0 && (
        <UndoConfirmDialog
          messagesRemoved={task.undoPending.messagesRemoved}
          onConfirm={(rc, rf) => onUndoConfirm(task.tid, rc, rf)}
          onDismiss={() => onUndoDismiss(task.tid)}
        />
      )}
      <QuoteSelectionButton isActive={isActive} onQuote={quoteSelection} />
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
          inputDraft={task.inputDraft}
          onInputDraftConsumed={() => onClearInputDraft(task.tid)}
          serverDraft={task.serverDraft}
          onSaveDraft={onSaveDraft ? handleSaveDraft : undefined}
          inputRef={inputRef}
          insertTextRef={insertTextRef}
          suggestions={task.suggestions}
        />
      )}
    </>
  );
}

function QuoteSelectionButton({
  isActive,
  onQuote,
}: {
  isActive: boolean;
  onQuote: () => boolean;
}) {
  const [pos, setPos] = useState<{ x: number; y: number } | null>(null);
  const [isMobile, setIsMobile] = useState(false);

  useEffect(() => {
    const mql = window.matchMedia("(hover: hover) and (pointer: fine)");
    setIsMobile(!mql.matches);
    const handler = (e: MediaQueryListEvent) => setIsMobile(!e.matches);
    mql.addEventListener("change", handler);
    return () => mql.removeEventListener("change", handler);
  }, []);

  useEffect(() => {
    if (!isMobile || !isActive) {
      setPos(null);
      return;
    }
    const update = () => {
      const sel = window.getSelection();
      if (!sel || sel.isCollapsed || sel.rangeCount === 0) {
        setPos(null);
        return;
      }
      const anchor =
        sel.anchorNode instanceof Element
          ? sel.anchorNode
          : sel.anchorNode?.parentElement;
      if (!anchor?.closest(".message-list")) {
        setPos(null);
        return;
      }
      const rect = sel.getRangeAt(0).getBoundingClientRect();
      setPos({
        x: rect.left + rect.width / 2,
        y: rect.bottom,
      });
    };

    document.addEventListener("selectionchange", update);
    return () => document.removeEventListener("selectionchange", update);
  }, [isMobile, isActive]);

  if (!pos) return null;

  return (
    <button
      class="quote-selection-btn"
      style={{ left: `${pos.x}px`, top: `${pos.y}px` }}
      onPointerDown={(e: PointerEvent) => e.preventDefault()}
      onClick={() => {
        onQuote();
        setPos(null);
      }}
    >
      Quote
    </button>
  );
}

function UndoConfirmDialog({
  messagesRemoved,
  onConfirm,
  onDismiss,
}: {
  messagesRemoved: number;
  onConfirm: (revertConversation: boolean, revertFiles: boolean) => void;
  onDismiss: () => void;
}) {
  const [revertConversation, setRevertConversation] = useState(true);
  const [revertFiles, setRevertFiles] = useState(true);
  const neitherSelected = !revertConversation && !revertFiles;

  return (
    <div class="undo-overlay" onClick={onDismiss}>
      <div class="undo-dialog" onClick={(e) => e.stopPropagation()}>
        <div class="undo-dialog-header">Undo to this point?</div>
        {messagesRemoved > 0 && (
          <div class="undo-dialog-count">
            {messagesRemoved} message{messagesRemoved !== 1 ? "s" : ""} will be
            removed.
          </div>
        )}
        <div class="undo-dialog-options">
          <label>
            <input
              type="checkbox"
              checked={revertConversation}
              onChange={() => setRevertConversation(!revertConversation)}
            />{" "}
            Revert conversation history
          </label>
          <label>
            <input
              type="checkbox"
              checked={revertFiles}
              onChange={() => setRevertFiles(!revertFiles)}
            />{" "}
            Revert file changes
          </label>
        </div>
        <div class="undo-dialog-actions">
          <button class="btn" onClick={onDismiss}>
            Cancel
          </button>
          <button
            class="btn btn-undo"
            disabled={neitherSelected}
            onClick={() => onConfirm(revertConversation, revertFiles)}
          >
            Undo
          </button>
        </div>
      </div>
    </div>
  );
}
