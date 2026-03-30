import { memo } from "preact/compat";
import {
  useRef,
  useEffect,
  useLayoutEffect,
  useState,
  useCallback,
} from "preact/hooks";
import { MarkdownQuote } from "../vendor/quote-selection";
import type { TaskState } from "../types";
import type { Theme } from "../useTheme";
import type {
  ImageAttachment,
  EntryPointInfo,
  AgentTypeInfo,
} from "../useSessionManager";
import { SystemBanner } from "./SystemBanner";
import { MessageList } from "./MessageList";
import { InputBox } from "./InputBox";
import { SessionConfig } from "./SessionConfig";
import { AgentPicker } from "./AgentPicker";
import { AskUserForm } from "./AskUserForm";
import { FileViewer } from "./FileViewer";

interface Props {
  task: TaskState;
  connected: boolean;
  isActive: boolean;
  onSend: (
    text: string,
    images?: ImageAttachment[],
    taskType?: string,
    agentType?: string,
  ) => void;
  onInterrupt: () => void;
  onStop: () => void;
  onCloseStdin: () => void;
  onResume: () => void;
  onPromote?: (tid: number) => void;
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
  onSetTaskType?: (tid: number, taskType: string) => void;
  onSetAgentType?: (tid: number, agentType: string) => void;
  onAskUserResponse: (tid: number, content: string) => void;
  theme: Theme;
  onToggleTheme: () => void;
  onToggleSidebar: () => void;
  onSetArchived?: (tid: number, archived: boolean) => void;
  onEditMessage?: (tid: number, uuid: string, content: string) => void;
  entryPoints?: EntryPointInfo[];
  agentTypes?: AgentTypeInfo[];
  defaultAgentType?: string;
  onContentStart?: (taskType: string) => void;
  onContentEnd?: () => void;
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
  onPromote,
  onFork,
  onUndo,
  onUndoConfirm,
  onUndoDismiss,
  onClearInputDraft,
  onSaveDraft,
  onSetTaskType,
  onSetAgentType,
  onAskUserResponse,
  theme,
  onToggleTheme,
  onToggleSidebar,
  onSetArchived,
  onEditMessage,
  entryPoints,
  agentTypes,
  defaultAgentType,
  onContentStart,
  onContentEnd,
}: Props) {
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const insertTextRef = useRef<((text: string) => void) | null>(null);
  const pasteTextRef = useRef<((text: string) => void) | null>(null);
  const resumeRef = useRef<HTMLButtonElement>(null);

  const isDraft =
    task.status === "pending" &&
    task.messages.length === 0 &&
    !task.isProcessing;

  // Task type picker state (only used in draft mode)
  // Initialize with entry point name matching the task's type, or the first entry point
  const initialEntryPoint =
    entryPoints?.find((e) => e.task_type === task.taskType)?.name ??
    entryPoints?.[0]?.name ??
    "agentic";
  const [selectedEntryPoint, setSelectedEntryPoint] =
    useState(initialEntryPoint);
  const taskTypePickerRef = useRef<HTMLDivElement>(null);

  // Agent picker state (only used in draft mode)
  const [selectedAgent, setSelectedAgent] = useState(task.agentType ?? "");

  const focusTaskTypePicker = useCallback(() => {
    taskTypePickerRef.current?.focus();
  }, []);

  const handleTaskTypeChange = useCallback(
    (taskType: string) => {
      setSelectedEntryPoint(taskType);
      if (isDraft && task.tid > 0) {
        // Pass the resolved task type name (not the entry point name)
        const ep = entryPoints?.find((e) => e.name === taskType);
        onSetTaskType?.(task.tid, ep?.task_type ?? taskType);
      }
    },
    [isDraft, task.tid, onSetTaskType, entryPoints],
  );

  const handleAgentChange = useCallback(
    (agentType: string) => {
      setSelectedAgent(agentType);
      if (isDraft && task.tid > 0) onSetAgentType?.(task.tid, agentType);
    },
    [isDraft, task.tid, onSetAgentType],
  );

  const handleSend = useCallback(
    (text: string, images?: ImageAttachment[]) => {
      if (isDraft) {
        onSend(
          text,
          images,
          selectedEntryPoint,
          selectedAgent || defaultAgentType || "claude",
        );
      } else {
        onSend(text, images);
      }
    },
    [onSend, isDraft, selectedEntryPoint, selectedAgent, defaultAgentType],
  );

  const handlePromote = useCallback(() => {
    onPromote?.(task.tid);
  }, [onPromote, task.tid]);

  const handleContentStart = useCallback(() => {
    onContentStart?.(selectedEntryPoint);
  }, [onContentStart, selectedEntryPoint]);

  const [fileViewerState, setFileViewerState] = useState<{
    open: boolean;
    selectedFile: string | null;
    selectedEditIndex: number | null;
    viewMode: "source" | "diff" | "cumulative" | "rendered";
    height: number;
  } | null>(null);

  const openFileViewer = useCallback(
    (filePath: string) => {
      const cwd = task.sessionInfo?.cwd;
      const absolutePath =
        !task.trackedFiles.has(filePath) &&
        !filePath.startsWith("/") &&
        cwd &&
        task.trackedFiles.has(`${cwd}/${filePath}`)
          ? `${cwd}/${filePath}`
          : filePath;
      const tracked = task.trackedFiles.get(absolutePath);
      setFileViewerState((prev) => ({
        open: true,
        selectedFile: absolutePath,
        selectedEditIndex:
          tracked && tracked.edits.length > 0 ? tracked.edits.length - 1 : null,
        viewMode:
          prev?.viewMode ??
          (/\.(md|mdx)$/i.test(absolutePath) ? "rendered" : "source"),
        height: prev?.height ?? 300,
      }));
    },
    [task.sessionInfo?.cwd, task.trackedFiles],
  );

  const closeFileViewer = useCallback(() => {
    setFileViewerState(null);
  }, []);

  useEffect(() => {
    if (!fileViewerState?.selectedFile) return;
    if (task.trackedFiles.has(fileViewerState.selectedFile)) return;
    setFileViewerState(null);
  }, [fileViewerState?.selectedFile, task.trackedFiles]);

  const scrollToToolCall = useCallback((toolUseId: string) => {
    const el = document.getElementById(`tool-${toolUseId}`);
    el?.scrollIntoView({ behavior: "smooth", block: "center" });
  }, []);

  // Auto-focus input box, resume button, or task type picker when session becomes active.
  // Skip on touch devices to avoid opening the virtual keyboard.
  useEffect(() => {
    if (!isActive) return;
    if (matchMedia("(pointer: coarse)").matches) return;
    if (isDraft) {
      taskTypePickerRef.current?.focus();
    } else if (task.resumable || task.status === "importable") {
      resumeRef.current?.focus();
    } else {
      inputRef.current?.focus();
    }
  }, [isActive, task.resumable, task.status, isDraft]);

  const handleSaveDraft = useCallback(
    (draft: string) => onSaveDraft?.(task.tid, draft),
    [onSaveDraft, task.tid],
  );

  const handleSetArchived = useCallback(() => {
    onSetArchived?.(task.tid, !task.archived);
  }, [onSetArchived, task.tid, task.archived]);

  const handleSelectFile = useCallback((path: string) => {
    setFileViewerState((s) =>
      s ? { ...s, selectedFile: path, selectedEditIndex: null } : s,
    );
  }, []);

  const handleSelectEdit = useCallback((idx: number | null) => {
    setFileViewerState((s) => (s ? { ...s, selectedEditIndex: idx } : s));
  }, []);

  const handleChangeViewMode = useCallback(
    (mode: "source" | "diff" | "cumulative" | "rendered") => {
      setFileViewerState((s) => (s ? { ...s, viewMode: mode } : s));
    },
    [],
  );

  const handleResize = useCallback((h: number) => {
    setFileViewerState((s) => (s ? { ...s, height: h } : s));
  }, []);

  const handleSessionConfigFocus = useCallback(() => {
    inputRef.current?.focus();
  }, []);

  const handleInputDraftConsumed = useCallback(() => {
    onClearInputDraft(task.tid);
  }, [onClearInputDraft, task.tid]);

  const handleUndoConfirm = useCallback(
    (rc: boolean, rf: boolean) => {
      onUndoConfirm(task.tid, rc, rf);
    },
    [onUndoConfirm, task.tid],
  );

  const handleUndoDismiss = useCallback(() => {
    onUndoDismiss(task.tid);
  }, [onUndoDismiss, task.tid]);

  const handleAskUserSubmit = useCallback(
    (answers: Record<string, string>) => {
      onAskUserResponse(task.tid, JSON.stringify({ answers }));
    },
    [onAskUserResponse, task.tid],
  );

  const handleAskUserAbort = useCallback(() => {
    onAskUserResponse(
      task.tid,
      JSON.stringify({ error: "User refused to answer questions" }),
    );
  }, [onAskUserResponse, task.tid]);

  const quoteSelection = useCallback(() => {
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
  }, []);

  useLayoutEffect(() => {
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

  useLayoutEffect(() => {
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
        onSetArchived={onSetArchived ? handleSetArchived : undefined}
      />
      {fileViewerState && (
        <FileViewer
          trackedFiles={task.trackedFiles}
          blocks={task.blocks}
          selectedFile={fileViewerState.selectedFile}
          selectedEditIndex={fileViewerState.selectedEditIndex}
          viewMode={fileViewerState.viewMode}
          height={fileViewerState.height}
          onSelectFile={handleSelectFile}
          onSelectEdit={handleSelectEdit}
          onChangeViewMode={handleChangeViewMode}
          onClose={closeFileViewer}
          onResize={handleResize}
          onScrollToToolCall={scrollToToolCall}
        />
      )}
      {!task.historyLoaded ? (
        <div class="session-loading">
          <span>Loading session…</span>
        </div>
      ) : task.messages.length === 0 && !task.isProcessing ? (
        isDraft && entryPoints ? (
          <div class="message-list welcome-prompt">
            <div class="session-empty-inner">
              <div class="welcome-page-header">
                <svg
                  class="welcome-logo"
                  viewBox="0 0 16 16"
                  fill="none"
                  stroke-width="2"
                  stroke-linecap="round"
                >
                  <path
                    style={{ stroke: "var(--success)" }}
                    d="M5.5 12L10.5 4L13 8l-2.5 4"
                  />
                  <path
                    style={{ stroke: "var(--processing)" }}
                    d="M5.5 4L3 8l2.5 4"
                  />
                </svg>
                <h1>CyDo</h1>
              </div>
              <SessionConfig
                entryPoints={entryPoints}
                selected={selectedEntryPoint}
                onTaskTypeChange={handleTaskTypeChange}
                pickerRef={taskTypePickerRef}
                onConfirm={handleSessionConfigFocus}
                onType={handleSessionConfigFocus}
              />
              <AgentPicker
                agentTypes={agentTypes || []}
                selected={selectedAgent || defaultAgentType || "claude"}
                onChange={handleAgentChange}
              />
              <InputBox
                onSend={handleSend}
                onInterrupt={onInterrupt}
                isProcessing={task.isProcessing}
                disabled={false}
                sessionId={task.tid}
                inputDraft={task.inputDraft}
                onInputDraftConsumed={handleInputDraftConsumed}
                serverDraft={task.serverDraft}
                onSaveDraft={
                  task.tid > 0 && onSaveDraft ? handleSaveDraft : undefined
                }
                inputRef={inputRef}
                insertTextRef={insertTextRef}
                pasteTextRef={pasteTextRef}
                onEscape={focusTaskTypePicker}
                suggestions={task.suggestions}
                onContentStart={handleContentStart}
                onContentEnd={onContentEnd}
              />
            </div>
          </div>
        ) : (
          <div class="message-list welcome-prompt">
            <div class="welcome-box">
              <h1 class="welcome-title">CyDo</h1>
              <p class="welcome-subtitle">Multi-agent orchestration system</p>
            </div>
          </div>
        )
      ) : (
        <MessageList
          sessionId={task.tid}
          messages={task.messages}
          blocks={task.blocks}
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
          onConfirm={handleUndoConfirm}
          onDismiss={handleUndoDismiss}
        />
      )}
      <QuoteSelectionButton isActive={isActive} onQuote={quoteSelection} />
      {task.status === "importable" ? (
        <div class="resume-bar">
          <button
            ref={resumeRef}
            class="btn btn-resume"
            onClick={handlePromote}
          >
            Import Session
          </button>
        </div>
      ) : task.resumable ? (
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
          onSubmit={handleAskUserSubmit}
          onAbort={handleAskUserAbort}
        />
      ) : isDraft && entryPoints ? null : (
        <InputBox
          onSend={handleSend}
          onInterrupt={onInterrupt}
          isProcessing={task.isProcessing}
          disabled={!connected}
          sessionId={task.tid}
          inputDraft={task.inputDraft}
          onInputDraftConsumed={handleInputDraftConsumed}
          serverDraft={task.serverDraft}
          onSaveDraft={
            task.tid > 0 && onSaveDraft ? handleSaveDraft : undefined
          }
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
