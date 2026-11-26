import { normalizeFilePath } from "../lib/localFileLinks";
import { LocalFileContext } from "./LocalFileContext";
import type { CreatedByLink } from "../createdByLink";
import { memo } from "preact/compat";
import {
  useRef,
  useEffect,
  useLayoutEffect,
  useMemo,
  useState,
  useCallback,
} from "preact/hooks";
import { MarkdownQuote } from "../vendor/quote-selection";
import type { TaskState } from "../types";
import { permissionAwaitingAgent } from "../permissionHandoff";
import type { SubtaskEnd } from "../subtaskResultParent";
import type { ToastEntry } from "../useToast";
import type { Theme } from "../useTheme";
import type {
  ImageAttachment,
  EntryPointInfo,
  AgentInfo,
  DraftView,
} from "../useSessionManager";
import type { HeicConversionStatus, Notice } from "../protocol";
import type { OrdinaryDraftStore } from "../ordinaryDraftStore";
import { NoticeBar } from "./NoticeBar";
import { SystemBanner, normalizeSessionStatus } from "./SystemBanner";
import { deriveBandStatus } from "./StatusBand";
import { MessageList } from "./MessageList";
import { InputBox } from "./InputBox";
import type { ControlledImageStore } from "../controlledImageStore";
import { SessionConfig } from "./SessionConfig";
import { AgentPicker } from "./AgentPicker";
import { AskUserForm } from "./AskUserForm";
import { PermissionPromptForm } from "./PermissionPromptForm";
import { TaskOrigin } from "./TaskOrigin";
import {
  FileViewer,
  firstTreePath,
  fileViewerModeForSelection,
  type ViewMode,
} from "./FileViewer";
import { requestNotificationPermissionFromGesture } from "../useNotifications";
import { LogoBanner } from "./LogoBanner";

interface Props {
  task: TaskState;
  connected: boolean;
  tasksLoading: boolean;
  isActive: boolean;
  onSend: (uuid: string, text: string, images?: ImageAttachment[]) => void;
  onInterrupt: (uuid: string) => void;
  onStop: (uuid: string) => void;
  onCloseStdin: (uuid: string) => void;
  onResume: (uuid: string) => void;
  onPromote?: (tid: number) => void;
  onFork: (tid: number, anchor: string) => void;
  onUndo: (tid: number, anchor: string) => void;
  onUnsend?: (tid: number, nonce: string) => void;
  onApproveRetry?: (tid: number, toolName: string, input: unknown) => void;
  onUndoConfirm: (
    tid: number,
    revertConversation: boolean,
    revertFiles: boolean,
  ) => void;
  onUndoDismiss: (tid: number) => void;
  onClearInputDraft: (tid: number) => void;
  ordinaryDraftStore: OrdinaryDraftStore;
  onSaveDraft?: (tid: number, draft: string) => void;
  addToast?: (level: ToastEntry["level"], message: string) => void;
  onAskUserResponse: (tid: number, content: string) => void;
  onPermissionPromptResponse: (
    tid: number,
    toolUseId: string,
    content: string,
  ) => void;
  theme: Theme;
  onToggleTheme: () => void;
  onToggleSidebar: () => void;
  hasGlobalAttention?: boolean;
  onSetTaskTitle?: (tid: number, title: string) => void;
  onSetArchived?: (tid: number, archived: boolean) => void;
  onEditMessage?: (tid: number, uuid: string, content: string) => void;
  onEditRawEvent?: (tid: number, seq: number, content: string) => void;
  agentDisplayName?: string;
  exportMode?: boolean;
  getTaskHref?: (id: string) => string;
  subtaskEnd?: SubtaskEnd;
  createdBy?: CreatedByLink;
  heicConversion: HeicConversionStatus;
  getHeicConversion: () => HeicConversionStatus;
}

function SessionViewInner({
  task,
  connected,
  tasksLoading,
  isActive,
  onSend,
  onInterrupt,
  onStop,
  onCloseStdin,
  onResume,
  onPromote,
  onFork,
  onUndo,
  onUnsend,
  onApproveRetry,
  onUndoConfirm,
  onUndoDismiss,
  onClearInputDraft,
  ordinaryDraftStore,
  onSaveDraft,
  addToast,
  onAskUserResponse,
  onPermissionPromptResponse,
  theme,
  onToggleTheme,
  onToggleSidebar,
  hasGlobalAttention,
  onSetTaskTitle,
  onSetArchived,
  onEditMessage,
  onEditRawEvent,
  agentDisplayName,
  exportMode,
  getTaskHref,
  subtaskEnd,
  createdBy,
  heicConversion,
  getHeicConversion,
}: Props) {
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const insertTextRef = useRef<((text: string) => void) | null>(null);
  const pasteTextRef = useRef<((text: string) => void) | null>(null);
  const resumeRef = useRef<HTMLButtonElement>(null);

  const tid = task.tid as number;
  const canMutateHistory = task.status !== "importable";
  const handleSend = useCallback(
    (text: string, images?: ImageAttachment[]) => {
      requestNotificationPermissionFromGesture();
      onSend(task.uuid, text, images);
    },
    [onSend, task.uuid],
  );

  const handlePromote = useCallback(() => {
    onPromote?.(tid);
  }, [onPromote, tid]);

  const [fileViewerState, setFileViewerState] = useState<{
    open: boolean;
    selectedFile: string | null;
    selectedEditIndex: number | null;
    viewMode: ViewMode;
    height: number;
  } | null>(null);

  const [linkedFiles, setLinkedFiles] = useState<readonly string[]>([]);
  const trackedFilesRef = useRef(task.trackedFiles);
  const cwdRef = useRef(task.sessionInfo?.cwd);
  trackedFilesRef.current = task.trackedFiles;
  cwdRef.current = task.sessionInfo?.cwd;

  const openFileViewer = useCallback(
    (filePath: string, mode?: ViewMode) => {
      const cwd = cwdRef.current;
      const trackedFiles = trackedFilesRef.current;
      const absolutePath = trackedFiles.has(filePath)
        ? filePath
        : normalizeFilePath(filePath, cwd);
      const tracked = trackedFiles.get(absolutePath);
      setFileViewerState((prev) => ({
        open: true,
        selectedFile: absolutePath,
        selectedEditIndex:
          mode !== "cumulative" && tracked && tracked.edits.length > 0
            ? tracked.edits.length - 1
            : null,
        viewMode: fileViewerModeForSelection(
          mode ?? prev?.viewMode,
          absolutePath,
          tracked !== undefined,
          !exportMode && absolutePath.startsWith("/"),
        ),
        height: prev?.height ?? 300,
      }));
    },
    [exportMode],
  );

  const openLinkedFile = useCallback(
    (path: string) => {
      setLinkedFiles((files) =>
        files.includes(path) ? files : [...files, path],
      );
      openFileViewer(path, "live");
    },
    [openFileViewer],
  );

  const closeFileViewer = useCallback(() => {
    setFileViewerState(null);
  }, []);

  useEffect(() => {
    if (!fileViewerState?.selectedFile) return;
    if (
      task.trackedFiles.has(fileViewerState.selectedFile) ||
      linkedFiles.includes(fileViewerState.selectedFile)
    )
      return;
    setFileViewerState(null);
  }, [fileViewerState?.selectedFile, task.trackedFiles, linkedFiles]);

  const scrollToToolCall = useCallback((toolUseId: string) => {
    const el = document.getElementById(`tool-${toolUseId}`);
    el?.scrollIntoView({ behavior: "smooth", block: "center" });
  }, []);

  // Auto-focus input box, resume button, or entry-point picker when session
  // becomes active. Skip on touch devices to avoid opening the virtual keyboard.
  // Runs after every render while active so we can re-focus when the target
  // element first mounts (loading screen → ready) or when it gets swapped to a
  // different DOM node (e.g. default InputBox → welcome InputBox once
  // entryPoints arrives via the draft re-adoption effect). Tracking the actual
  // last-focused element (rather than a boolean) means we only refocus when
  // the target ref points at a *new* node, not on every render.
  const lastFocusTargetRef = useRef<HTMLElement | null>(null);
  useLayoutEffect(() => {
    if (!isActive) {
      lastFocusTargetRef.current = null;
      return;
    }
    if (matchMedia("(pointer: coarse)").matches) return;
    let target: HTMLElement | null;
    if (task.status === "importable") {
      target = resumeRef.current;
    } else {
      target = inputRef.current;
    }
    if (!target) return;
    if (target === lastFocusTargetRef.current) return;
    target.focus();
    lastFocusTargetRef.current = target;
  });

  const handleSaveDraft = useCallback(
    (draft: string) => onSaveDraft?.(tid, draft),
    [onSaveDraft, tid],
  );

  const handleSetArchived = useCallback(() => {
    onSetArchived?.(tid, !task.archived);
  }, [onSetArchived, tid, task.archived]);

  const handleSelectFile = useCallback((path: string) => {
    setFileViewerState((s) =>
      s ? { ...s, selectedFile: path, selectedEditIndex: null } : s,
    );
  }, []);

  const handleSelectEdit = useCallback((idx: number | null) => {
    setFileViewerState((s) => (s ? { ...s, selectedEditIndex: idx } : s));
  }, []);

  const handleChangeViewMode = useCallback((mode: ViewMode) => {
    setFileViewerState((s) => (s ? { ...s, viewMode: mode } : s));
  }, []);

  const handleResize = useCallback((h: number) => {
    setFileViewerState((s) => (s ? { ...s, height: h } : s));
  }, []);

  const handleInputDraftConsumed = useCallback(() => {
    onClearInputDraft(tid);
  }, [onClearInputDraft, tid]);

  const handleAskUserSubmit = useCallback(
    (answers: Record<string, string>) => {
      onAskUserResponse(tid, JSON.stringify({ answers }));
    },
    [onAskUserResponse, tid],
  );

  const handleAskUserAbort = useCallback(() => {
    onAskUserResponse(
      tid,
      JSON.stringify({ error: "User refused to answer questions" }),
    );
  }, [onAskUserResponse, tid]);

  const permission = task.pendingPermission ?? permissionAwaitingAgent(task);

  const handlePermissionAllow = (toolUseId: string) => {
    onPermissionPromptResponse(
      tid,
      toolUseId,
      JSON.stringify({ behavior: "allow" }),
    );
  };

  const handlePermissionDeny = (toolUseId: string, message?: string) => {
    onPermissionPromptResponse(
      tid,
      toolUseId,
      JSON.stringify({
        behavior: "deny",
        ...(message ? { message } : {}),
      }),
    );
  };

  const quoteSelection = useCallback(
    (event?: KeyboardEvent) => {
      const sel = window.getSelection();
      if (!sel || sel.isCollapsed) return false;
      const anchor =
        sel.anchorNode instanceof Element
          ? sel.anchorNode
          : sel.anchorNode?.parentElement;
      if (!anchor?.closest(".message-list, .file-viewer")) return false;
      const insertText = insertTextRef.current;
      if (!insertText) {
        if (permission) {
          addToast?.("info", "Click Deny to add a reason, then quote into it");
        } else if (task.pendingAskUser) {
          addToast?.("info", 'Open an "Other" answer to quote into it');
        } else {
          return false;
        }
        event?.preventDefault();
        return false;
      }
      insertText(new MarkdownQuote().quotedText);
      sel.removeAllRanges();
      event?.preventDefault();
      return true;
    },
    [addToast, permission, task.pendingAskUser],
  );

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
        quoteSelection(e);
        if (e.defaultPrevented) return;
      }

      if (e.key.length !== 1) return;
      inputRef.current?.focus();
    };
    document.addEventListener("keydown", handler);
    return () => {
      document.removeEventListener("keydown", handler);
    };
  }, [isActive, quoteSelection]);

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

  const toggleTaskChanges = () => {
    if (fileViewerState) {
      closeFileViewer();
    } else {
      const path = firstTreePath([...task.trackedFiles.keys()]);
      if (path !== undefined) openFileViewer(path, "cumulative");
    }
  };

  const baseDir = task.sessionInfo?.cwd || null;
  const fileAccess = useMemo(
    () => ({
      tid,
      baseDir,
      ancestorPaths: [],
      openInFileViewer: openLinkedFile,
    }),
    [tid, baseDir, openLinkedFile],
  );

  const view = (
    <>
      <SystemBanner
        tid={task.tid ?? undefined}
        title={task.title}
        agentName={
          task.agentName ||
          task.sessionInfo?.agent_name ||
          task.sessionInfo?.agent
        }
        agentDisplayName={agentDisplayName ?? task.sessionInfo?.agent}
        agentDriver={task.driver}
        sessionInfo={task.sessionInfo}
        entryPoint={task.entryPoint}
        createdAt={task.createdAt}
        lastActive={task.lastActive}
        trackedFileCount={task.trackedFiles.size}
        filesOpen={fileViewerState !== null}
        onToggleFiles={toggleTaskChanges}
        connected={connected}
        tasksLoading={tasksLoading}
        cost={task.totalCost}
        stdinClosed={task.stdinClosed}
        alive={task.alive}
        canStop={task.canStop}
        theme={theme}
        onToggleTheme={onToggleTheme}
        onStop={() => {
          onStop(task.uuid);
        }}
        onCloseStdin={() => {
          onCloseStdin(task.uuid);
        }}
        onSetTitle={
          onSetTaskTitle && !exportMode && canMutateHistory
            ? (title) => {
                onSetTaskTitle(tid, title);
              }
            : undefined
        }
        taskType={task.taskType}
        onToggleSidebar={onToggleSidebar}
        hasGlobalAttention={hasGlobalAttention}
        archived={task.archived}
        archiving={task.archiving}
        onSetArchived={onSetArchived ? handleSetArchived : undefined}
        resumable={task.resumable}
        onResume={() => {
          onResume(task.uuid);
        }}
        exportMode={exportMode}
      />
      {fileViewerState && (
        <FileViewer
          linkedFiles={linkedFiles}
          trackedFiles={task.trackedFiles}
          blocks={task.blocks}
          itemIdMap={task.itemIdMap}
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
          {task.historyTotal != null && task.historyTotal > 0 && (
            <div class="session-loading-progress">
              <div
                class="session-loading-bar"
                style={{
                  width: `${Math.min(100, ((task.historyReceived ?? 0) / task.historyTotal) * 100)}%`,
                }}
              />
            </div>
          )}
        </div>
      ) : task.messages.length === 0 &&
        !task.isProcessing &&
        subtaskEnd === undefined ? (
        <div class="welcome-prompt">
          <div class="welcome-box">
            <LogoBanner />
            <p class="welcome-subtitle">Multi-agent orchestration system</p>
          </div>
        </div>
      ) : (
        <MessageList
          taskTid={tid}
          createdBy={createdBy}
          messages={task.messages}
          replacementEvents={task.replacementEvents}
          historyOperations={task.historyOperations}
          blocks={task.blocks}
          isProcessing={task.isProcessing}
          bandStatus={deriveBandStatus(
            normalizeSessionStatus(task.sessionStatus),
            task.isProcessing,
            task.stdinClosed,
            task.alive,
          )}
          onFork={canMutateHistory ? onFork : undefined}
          onUndo={canMutateHistory ? onUndo : undefined}
          undoPending={canMutateHistory ? task.undoPending : null}
          onUndoConfirm={onUndoConfirm}
          onUndoDismiss={onUndoDismiss}
          onUnsend={
            task.alive && task.driver === "claude" ? onUnsend : undefined
          }
          onApproveRetry={task.alive ? onApproveRetry : undefined}
          onEditMessage={
            canMutateHistory && !task.alive ? onEditMessage : undefined
          }
          onEditRawEvent={
            canMutateHistory && !task.alive ? onEditRawEvent : undefined
          }
          onViewFile={openFileViewer}
          itemEnrichments={task.itemEnrichments}
          getTaskHref={getTaskHref}
          subtaskEnd={subtaskEnd}
        />
      )}
      {task.undoResult && (
        <div class="undo-result-banner">{task.undoResult}</div>
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
      ) : task.error && !task.alive && !task.resumable ? (
        <div class="resume-bar">
          <span class="session-failed-label">Session failed: {task.error}</span>
        </div>
      ) : permission ? (
        <PermissionPromptForm
          key={permission.toolUseId}
          insertTextRef={insertTextRef}
          toolName={permission.toolName}
          input={permission.input}
          reason={permission.reason}
          expiresAt={permission.expiresAt}
          sending={!task.pendingPermission}
          onAllow={() => {
            handlePermissionAllow(permission.toolUseId);
          }}
          onDeny={(message) => {
            handlePermissionDeny(permission.toolUseId, message);
          }}
        />
      ) : task.pendingAskUser ? (
        <AskUserForm
          questions={task.pendingAskUser.questions}
          insertTextRef={insertTextRef}
          onSubmit={handleAskUserSubmit}
          onAbort={handleAskUserAbort}
        />
      ) : exportMode ? null : (
        <>
          {task.resumable && task.error && (
            <div key="resumable-error" class="resume-bar">
              <span class="session-failed-label">
                Session failed: {task.error}
              </span>
            </div>
          )}
          <InputBox
            heicConversion={heicConversion}
            getHeicConversion={getHeicConversion}
            key="input-box"
            onSend={handleSend}
            onInterrupt={() => {
              onInterrupt(task.uuid);
            }}
            isProcessing={task.isProcessing}
            stdinClosed={task.stdinClosed}
            disabled={!connected}
            sessionId={task.uuid}
            inputDraft={task.inputDraft}
            onInputDraftConsumed={handleInputDraftConsumed}
            serverDraft={task.serverDraft}
            ordinaryDraftStore={ordinaryDraftStore}
            onSaveDraft={onSaveDraft ? handleSaveDraft : undefined}
            inputRef={inputRef}
            insertTextRef={insertTextRef}
            pasteTextRef={pasteTextRef}
            suggestions={task.suggestions}
          />
        </>
      )}
    </>
  );
  return exportMode ? (
    view
  ) : (
    <LocalFileContext.Provider value={fileAccess}>
      {view}
    </LocalFileContext.Provider>
  );
}

export const SessionView = memo(SessionViewInner);

interface DraftSessionViewProps {
  heicConversion: HeicConversionStatus;
  getHeicConversion: () => HeicConversionStatus;
  draftView: DraftView;
  connected: boolean;
  tasksLoading: boolean;
  entryPoints: EntryPointInfo[];
  agents: readonly AgentInfo[];
  defaultAgent: string;
  notices?: Record<string, Notice>;
  theme: Theme;
  onToggleTheme: () => void;
  onToggleSidebar: () => void;
  hasGlobalAttention?: boolean;
  imageStore?: ControlledImageStore;
  createdBy?: CreatedByLink;
}

export function DraftSessionView({
  heicConversion,
  getHeicConversion,
  draftView,
  connected,
  tasksLoading,
  entryPoints,
  agents,
  defaultAgent,
  notices,
  theme,
  onToggleTheme,
  onToggleSidebar,
  hasGlobalAttention,
  imageStore,
  createdBy,
}: DraftSessionViewProps) {
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const insertTextRef = useRef<((text: string) => void) | null>(null);
  const pasteTextRef = useRef<((text: string) => void) | null>(null);
  const entryPointPickerRef = useRef<HTMLDivElement>(null);
  const lastFocusTargetRef = useRef<HTMLElement | null>(null);
  const disabled = draftView.disabled;
  const configurationDisabled = disabled || !draftView.metadataReady;

  const focusInput = useCallback(() => {
    inputRef.current?.focus();
  }, []);
  const focusPicker = useCallback(() => {
    entryPointPickerRef.current?.focus();
  }, []);

  useLayoutEffect(() => {
    if (disabled || matchMedia("(pointer: coarse)").matches) {
      lastFocusTargetRef.current = null;
      return;
    }
    const target =
      draftView.text.trim() || configurationDisabled
        ? inputRef.current
        : entryPointPickerRef.current;
    if (!target || target === lastFocusTargetRef.current) return;
    target.focus();
    lastFocusTargetRef.current = target;
  }, [configurationDisabled, disabled, draftView.text, draftView.viewKey]);

  useLayoutEffect(() => {
    if (disabled) return;
    const handler = (event: KeyboardEvent) => {
      const target = event.target;
      if (
        target instanceof HTMLTextAreaElement ||
        target instanceof HTMLInputElement
      )
        return;
      if (
        event.ctrlKey ||
        event.metaKey ||
        event.altKey ||
        event.key.length !== 1
      )
        return;
      inputRef.current?.focus();
    };
    document.addEventListener("keydown", handler);
    return () => {
      document.removeEventListener("keydown", handler);
    };
  }, [disabled]);

  useLayoutEffect(() => {
    if (disabled) return;
    const handler = (event: ClipboardEvent) => {
      const target = event.target;
      if (
        target instanceof HTMLTextAreaElement ||
        target instanceof HTMLInputElement
      )
        return;
      const text = event.clipboardData?.getData("text");
      if (!text) return;
      event.preventDefault();
      pasteTextRef.current?.(text);
    };
    document.addEventListener("paste", handler);
    return () => {
      document.removeEventListener("paste", handler);
    };
  }, [disabled]);

  const agentName = draftView.agent || defaultAgent;
  const agent = agents.find((entry) => entry.name === agentName);
  const changeText = (text: string) => {
    if (draftView.kind === "resolved") draftView.onTextChange(text);
  };
  const changeEntryPoint = (entryPoint: string) => {
    if (draftView.kind === "resolved") draftView.onEntryPointChange(entryPoint);
  };
  const changeAgent = (agent: string) => {
    if (draftView.kind === "resolved") draftView.onAgentChange(agent);
  };
  const submit = (text: string, images: ImageAttachment[]) => {
    if (draftView.kind === "resolved") {
      requestNotificationPermissionFromGesture();
      draftView.onSubmit(text, images);
    }
  };

  return (
    <>
      <SystemBanner
        title="New task"
        agentName={agentName}
        agentDisplayName={agent?.display_name ?? agent?.driver}
        agentDriver={agent?.driver}
        connected={connected}
        tasksLoading={tasksLoading}
        theme={theme}
        onToggleTheme={onToggleTheme}
        onToggleSidebar={onToggleSidebar}
        hasGlobalAttention={hasGlobalAttention}
      />
      <div class="welcome-prompt">
        <div class="session-empty-inner">
          {createdBy && <TaskOrigin creator={createdBy} />}
          <div class="welcome-page-header">
            <LogoBanner />
          </div>
          {notices && <NoticeBar notices={notices} />}
          <SessionConfig
            entryPoints={entryPoints}
            selected={draftView.entryPoint}
            selectedAgent={draftView.agent || defaultAgent}
            onEntryPointChange={changeEntryPoint}
            disabled={configurationDisabled}
            pickerRef={entryPointPickerRef}
            onConfirm={focusInput}
            onType={focusInput}
          />
          <AgentPicker
            agents={agents}
            selected={draftView.agent || defaultAgent}
            onChange={changeAgent}
            disabled={configurationDisabled}
          />
          <InputBox
            heicConversion={heicConversion}
            getHeicConversion={getHeicConversion}
            mode="controlled"
            value={draftView.text}
            onChange={changeText}
            onSubmit={submit}
            submitDisabled={!draftView.submitReady}
            submitLabel={
              draftView.lifecycle === "submitting" ? "Submitting…" : undefined
            }
            composerResetToken={draftView.composerResetToken}
            imageStore={imageStore}
            imageKey={
              draftView.kind === "resolved" ? draftView.editorId : undefined
            }
            onInterrupt={() => {}}
            isProcessing={false}
            disabled={disabled}
            inputRef={inputRef}
            insertTextRef={insertTextRef}
            pasteTextRef={pasteTextRef}
            onEscape={focusPicker}
          />
        </div>
      </div>
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
        if (onQuote()) setPos(null);
      }}
    >
      Quote
    </button>
  );
}
