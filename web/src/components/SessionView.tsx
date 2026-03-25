import { memo } from "preact/compat";
import { useRef, useEffect, useState, useCallback } from "preact/hooks";
import { MarkdownQuote } from "../vendor/quote-selection";
import type { TaskState } from "../types";
import type { Theme } from "../useTheme";
import { SystemBanner } from "./SystemBanner";
import { MessageList } from "./MessageList";
import { InputBox } from "./InputBox";
import { AskUserForm } from "./AskUserForm";
import { FileViewer } from "./FileViewer";

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
  onAskUserResponse: (tid: number, content: string) => void;
  theme: Theme;
  onToggleTheme: () => void;
  onToggleSidebar: () => void;
  onSetArchived?: (tid: number, archived: boolean) => void;
  onEditMessage?: (tid: number, uuid: string, content: string) => void;
}

function SessionViewInner({
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
  onAskUserResponse,
  theme,
  onToggleTheme,
  onToggleSidebar,
  onSetArchived,
  onEditMessage,
}: Props) {
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const insertTextRef = useRef<((text: string) => void) | null>(null);
  const pasteTextRef = useRef<((text: string) => void) | null>(null);
  const resumeRef = useRef<HTMLButtonElement>(null);

  const [fileViewerState, setFileViewerState] = useState<{
    open: boolean;
    selectedFile: string | null;
    selectedEditIndex: number | null;
    viewMode: "source" | "diff" | "cumulative" | "rendered";
    height: number;
  } | null>(null);

  const openFileViewer = useCallback((filePath: string) => {
    setFileViewerState((prev) => ({
      open: true,
      selectedFile: filePath,
      selectedEditIndex: null,
      viewMode:
        prev?.viewMode ??
        (/\.(md|mdx)$/i.test(filePath) ? "rendered" : "source"),
      height: prev?.height ?? 300,
    }));
  }, []);

  const closeFileViewer = useCallback(() => {
    setFileViewerState(null);
  }, []);

  const scrollToToolCall = useCallback((toolUseId: string) => {
    const el = document.getElementById(`tool-${toolUseId}`);
    el?.scrollIntoView({ behavior: "smooth", block: "center" });
  }, []);

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
    if (!anchor?.closest(".message-list, .file-viewer")) return false;
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
    return () => {
      document.removeEventListener("keydown", handler);
    };
  }, [isActive]);

  useEffect(() => {
    if (!isActive) return;
    const handler = (e: ClipboardEvent) => {
      const target = e.target;
      if (
        target instanceof HTMLTextAreaElement ||
        target instanceof HTMLInputElement
      )
        return;
      const text = e.clipboardData?.getData("text");
      if (!text) return;
      e.preventDefault();
      pasteTextRef.current?.(text);
    };
    document.addEventListener("paste", handler);
    return () => {
      document.removeEventListener("paste", handler);
    };
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
            ? () => {
                onSetArchived(task.tid, !task.archived);
              }
            : undefined
        }
      />
      {fileViewerState && (
        <FileViewer
          trackedFiles={task.trackedFiles}
          messages={task.messages}
          selectedFile={fileViewerState.selectedFile}
          selectedEditIndex={fileViewerState.selectedEditIndex}
          viewMode={fileViewerState.viewMode}
          height={fileViewerState.height}
          onSelectFile={(path) => {
            setFileViewerState((s) =>
              s ? { ...s, selectedFile: path, selectedEditIndex: null } : s,
            );
          }}
          onSelectEdit={(idx) => {
            setFileViewerState((s) =>
              s ? { ...s, selectedEditIndex: idx } : s,
            );
          }}
          onChangeViewMode={(mode) => {
            setFileViewerState((s) => (s ? { ...s, viewMode: mode } : s));
          }}
          onClose={closeFileViewer}
          onResize={(h) => {
            setFileViewerState((s) => (s ? { ...s, height: h } : s));
          }}
          onScrollToToolCall={scrollToToolCall}
        />
      )}
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
          onEditMessage={!task.alive ? onEditMessage : undefined}
          forkableUuids={task.forkableUuids}
          onViewFile={openFileViewer}
        />
      )}
      {task.undoPending && task.undoPending.messagesRemoved >= 0 && (
        <UndoConfirmDialog
          messagesRemoved={task.undoPending.messagesRemoved}
          supportsFileRevert={task.sessionInfo?.supports_file_revert !== false}
          onConfirm={(rc, rf) => {
            onUndoConfirm(task.tid, rc, rf);
          }}
          onDismiss={() => {
            onUndoDismiss(task.tid);
          }}
        />
      )}
      <QuoteSelectionButton isActive={isActive} onQuote={quoteSelection} />
      {task.resumable ? (
        <div class="resume-bar">
          {task.error && (
            <span class="session-failed-label">
              Session failed: {task.error}
            </span>
          )}
          <button ref={resumeRef} class="btn btn-resume" onClick={onResume}>
            Resume Session
          </button>
        </div>
      ) : task.error && !task.alive ? (
        <div class="resume-bar">
          <span class="session-failed-label">Session failed: {task.error}</span>
        </div>
      ) : task.pendingAskUser ? (
        <AskUserForm
          questions={task.pendingAskUser.questions}
          onSubmit={(answers) => {
            onAskUserResponse(task.tid, JSON.stringify({ answers }));
          }}
          onAbort={() => {
            onAskUserResponse(
              task.tid,
              JSON.stringify({ error: "User refused to answer questions" }),
            );
          }}
        />
      ) : (
        <InputBox
          onSend={onSend}
          onInterrupt={onInterrupt}
          isProcessing={task.isProcessing}
          disabled={!connected}
          sessionId={task.tid}
          inputDraft={task.inputDraft}
          onInputDraftConsumed={() => {
            onClearInputDraft(task.tid);
          }}
          serverDraft={task.serverDraft}
          onSaveDraft={onSaveDraft ? handleSaveDraft : undefined}
          inputRef={inputRef}
          insertTextRef={insertTextRef}
          pasteTextRef={pasteTextRef}
          suggestions={task.suggestions}
        />
      )}
    </>
  );
}

export const SessionView = memo(SessionViewInner);

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
    const handler = (e: MediaQueryListEvent) => {
      setIsMobile(!e.matches);
    };
    mql.addEventListener("change", handler);
    return () => {
      mql.removeEventListener("change", handler);
    };
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
      if (!anchor?.closest(".message-list, .file-viewer")) {
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
    return () => {
      document.removeEventListener("selectionchange", update);
    };
  }, [isMobile, isActive]);

  if (!pos) return null;

  return (
    <button
      class="quote-selection-btn"
      style={{ left: `${pos.x}px`, top: `${pos.y}px` }}
      onPointerDown={(e: PointerEvent) => {
        e.preventDefault();
      }}
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
  supportsFileRevert,
  onConfirm,
  onDismiss,
}: {
  messagesRemoved: number;
  supportsFileRevert: boolean;
  onConfirm: (revertConversation: boolean, revertFiles: boolean) => void;
  onDismiss: () => void;
}) {
  const [revertConversation, setRevertConversation] = useState(true);
  const [revertFiles, setRevertFiles] = useState(supportsFileRevert);
  const neitherSelected = !revertConversation && !revertFiles;

  return (
    <div class="undo-overlay" onClick={onDismiss}>
      <div
        class="undo-dialog"
        onClick={(e) => {
          e.stopPropagation();
        }}
      >
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
              onChange={() => {
                setRevertConversation(!revertConversation);
              }}
            />{" "}
            Revert conversation history
          </label>
          <label>
            <input
              type="checkbox"
              checked={revertFiles}
              disabled={!supportsFileRevert}
              onChange={() => {
                setRevertFiles(!revertFiles);
              }}
            />{" "}
            Revert file changes
            {!supportsFileRevert && " (not supported for this agent type)"}
          </label>
        </div>
        <div class="undo-dialog-actions">
          <button class="btn" onClick={onDismiss}>
            Cancel
          </button>
          <button
            class="btn btn-undo"
            disabled={neitherSelected}
            onClick={() => {
              onConfirm(revertConversation, revertFiles);
            }}
          >
            Undo
          </button>
        </div>
      </div>
    </div>
  );
}
