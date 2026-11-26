import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import type { SessionInfo } from "../types";
import type { Theme } from "../useTheme";
import filesIcon from "../icons/copy.svg?raw";
import hamburgerIcon from "../icons/hamburger.svg?raw";
import { TaskId, TaskPanel } from "./TaskPanel";
import { ThemeToggle } from "./ThemeToggle";

interface Props {
  sessionInfo?: SessionInfo | null;
  tid?: number;
  title?: string;
  onSetTitle?: (title: string) => void;
  agentName?: string;
  agentDisplayName?: string;
  agentDriver?: string;
  trackedFileCount?: number;
  onToggleFiles?: () => void;
  filesOpen?: boolean;
  cost?: number;
  entryPoint?: string;
  createdAt?: number;
  lastActive?: number;
  connected: boolean;
  tasksLoading: boolean;
  stdinClosed?: boolean;
  alive?: boolean;
  canStop?: boolean;
  theme: Theme;
  onToggleTheme: () => void;
  onStop?: () => void;
  onCloseStdin?: () => void;
  taskType?: string;
  onToggleSidebar?: () => void;
  hasGlobalAttention?: boolean;
  archived?: boolean;
  archiving?: boolean;
  onSetArchived?: () => void;
  resumable?: boolean;
  onResume?: () => void;
  exportMode?: boolean;
}

export function normalizeSessionStatus(status?: string | null): string | null {
  if (typeof status !== "string" || status.trim().length === 0) return null;
  return status;
}

export function isCompactingStatus(status: string): boolean {
  const lower = status.toLowerCase();
  if (lower === "compacting" || lower.includes("compacting")) return true;
  return lower.includes("compact") && !lower.includes("compacted");
}

export function SystemBanner({
  sessionInfo,
  tid,
  title,
  onSetTitle,
  agentName,
  agentDisplayName,
  agentDriver,
  trackedFileCount = 0,
  onToggleFiles,
  filesOpen,
  cost,
  entryPoint,
  createdAt,
  lastActive,
  connected,
  tasksLoading,
  stdinClosed,
  alive,
  canStop,
  theme,
  onToggleTheme,
  onStop,
  onCloseStdin,
  taskType,
  onToggleSidebar,
  hasGlobalAttention,
  archived,
  archiving,
  onSetArchived,
  resumable,
  onResume,
  exportMode,
}: Props) {
  const [panelOpen, setPanelOpen] = useState(false);
  const [titleDraft, setTitleDraft] = useState<string | null>(null);
  const editingTitle = titleDraft !== null;
  const titleInputRef = useRef<HTMLInputElement>(null);
  const titleButtonRef = useRef<HTMLButtonElement>(null);
  useLayoutEffect(() => {
    if (editingTitle) titleInputRef.current?.focus();
  }, [editingTitle]);
  useEffect(() => {
    setTitleDraft((draft) => (draft?.trim() === (title ?? "") ? null : draft));
  }, [title]);
  const closePanel = () => {
    setPanelOpen(false);
    setTitleDraft(null);
  };
  const panelRef = useRef<HTMLElement>(null);
  const panelToggleRef = useRef<HTMLButtonElement>(null);
  useLayoutEffect(() => {
    if (!panelOpen) return;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      if (editingTitle) setTitleDraft(null);
      else closePanel();
    };
    const onClick = (event: MouseEvent) => {
      const target = event.target as Element;
      if (
        !panelRef.current?.contains(target) &&
        !panelToggleRef.current?.contains(target) &&
        !titleButtonRef.current?.contains(target) &&
        // Dismissing a modal dialog, such as a rejected title edit, must
        // leave the panel as it was.
        !target.closest(".undo-overlay")
      ) {
        closePanel();
      }
    };
    document.addEventListener("keydown", onKeyDown);
    document.addEventListener("click", onClick, true);
    return () => {
      document.removeEventListener("keydown", onKeyDown);
      document.removeEventListener("click", onClick, true);
    };
  }, [panelOpen, editingTitle]);
  const connection = exportMode
    ? undefined
    : !connected
      ? "disconnected"
      : tasksLoading
        ? "loading"
        : "connected";
  const connectionLabel =
    connection === "disconnected"
      ? "Disconnected"
      : connection === "loading"
        ? "Loading…"
        : undefined;
  const barTitle = title || (tid === undefined ? connectionLabel : undefined);
  const secondaryAction =
    !exportMode &&
    (alive
      ? canStop && (
          <button
            class="btn-banner-stop"
            onClick={onStop}
            title="Force-stop task execution"
          >
            Kill
          </button>
        )
      : onSetArchived && (
          <button
            class={`btn-banner-archive${archived ? " archived" : ""}`}
            onClick={onSetArchived}
            disabled={archiving}
            title={
              archiving
                ? "Archive operation in progress…"
                : archived
                  ? "Unarchive task (Ctrl+Shift+A)"
                  : "Archive task (Ctrl+Shift+A)"
            }
          >
            {archiving
              ? archived
                ? "Archiving…"
                : "Unarchiving…"
              : archived
                ? "Unarchive"
                : "Archive"}
          </button>
        ));
  return (
    <div class="task-bar" data-connection={connection}>
      {onToggleSidebar && (
        <button
          class={`hamburger-btn${hasGlobalAttention ? " has-attention" : ""}`}
          onClick={onToggleSidebar}
          title={
            hasGlobalAttention
              ? "Toggle sidebar — sessions need attention"
              : "Toggle sidebar"
          }
        >
          {hasGlobalAttention ? (
            <span class="task-type-icon task-type-icon-check alive" />
          ) : (
            <span
              class="action-icon"
              dangerouslySetInnerHTML={{ __html: hamburgerIcon }}
            />
          )}
        </button>
      )}
      {agentName && (
        <span
          class="task-bar-agent banner-agent"
          data-driver={agentDriver}
          title={connectionLabel ?? agentDisplayName}
        >
          {agentName}
        </span>
      )}
      {sessionInfo?.model && (
        <span class="banner-model">{sessionInfo.model}</span>
      )}
      {tid !== undefined && (
        <span class="task-bar-desktop">
          <TaskId tid={tid} />
        </span>
      )}
      {onSetTitle ? (
        <button
          type="button"
          ref={titleButtonRef}
          class="task-bar-title"
          title={barTitle}
          aria-label={barTitle ? `Edit title: ${barTitle}` : "Edit title"}
          onClick={() => {
            setPanelOpen(true);
            setTitleDraft((draft) => draft ?? title ?? "");
            titleInputRef.current?.focus();
          }}
        >
          {barTitle || "Edit title"}
        </button>
      ) : (
        <span class="task-bar-title" title={barTitle}>
          {barTitle}
        </span>
      )}
      {trackedFileCount > 0 && (
        <button
          type="button"
          class="task-bar-files"
          onClick={onToggleFiles}
          aria-label={`Files ${trackedFileCount}`}
          aria-pressed={filesOpen}
        >
          <span
            class="action-icon"
            aria-hidden="true"
            dangerouslySetInnerHTML={{ __html: filesIcon }}
          />
          <span class="task-bar-desktop">Files {trackedFileCount}</span>
        </button>
      )}
      {exportMode ? (
        <span class="task-bar-exported">Exported</span>
      ) : (
        <>
          {alive && !stdinClosed && (
            <button
              class="btn-banner-end"
              onClick={onCloseStdin}
              title="End session gracefully (Ctrl+Shift+E)"
            >
              End
            </button>
          )}
          {!alive && resumable && onResume && (
            <button
              class="btn-banner-resume"
              onClick={onResume}
              title="Resume session"
            >
              Resume
            </button>
          )}
          {secondaryAction && (
            <span class="task-bar-desktop">{secondaryAction}</span>
          )}
        </>
      )}
      {tid !== undefined && (
        <button
          type="button"
          ref={panelToggleRef}
          class="task-bar-panel-toggle"
          aria-label="Task details"
          aria-expanded={panelOpen}
          onClick={() => {
            if (panelOpen) closePanel();
            else setPanelOpen(true);
          }}
        >
          ▾
        </button>
      )}
      {panelOpen && tid !== undefined && (
        <TaskPanel
          tid={tid}
          panelRef={panelRef}
          title={title ?? ""}
          titleDraft={titleDraft}
          onTitleDraftChange={setTitleDraft}
          titleInputRef={titleInputRef}
          onSetTitle={onSetTitle}
          agentName={agentName}
          agentDisplayName={agentDisplayName}
          sessionInfo={sessionInfo}
          taskType={taskType}
          entryPoint={entryPoint}
          cost={cost}
          createdAt={createdAt}
          lastActive={lastActive}
          mobileAction={secondaryAction}
          onClose={closePanel}
        />
      )}
      <ThemeToggle theme={theme} onToggle={onToggleTheme} />
    </div>
  );
}
