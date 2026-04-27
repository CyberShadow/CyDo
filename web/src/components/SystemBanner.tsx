import { useState } from "preact/hooks";
import type { SessionInfo } from "../types";
import type { Theme } from "../useTheme";
import sunIcon from "../icons/sun.svg?raw";
import moonIcon from "../icons/moon.svg?raw";
import hamburgerIcon from "../icons/hamburger.svg?raw";

interface Props {
  sessionInfo: SessionInfo | null;
  sessionStatus?: string | null;
  connected: boolean;
  totalCost: number;
  isProcessing: boolean;
  stdinClosed: boolean;
  alive: boolean;
  theme: Theme;
  onToggleTheme: () => void;
  onStop: () => void;
  onCloseStdin: () => void;
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
  sessionStatus,
  connected,
  totalCost,
  isProcessing,
  stdinClosed,
  alive,
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
  const [detailsOpen, setDetailsOpen] = useState(false);
  const liveStatus = normalizeSessionStatus(sessionStatus);
  let processingText: string | null = null;
  if (alive && stdinClosed) {
    processingText = "Ending...";
  } else if (liveStatus) {
    if (isCompactingStatus(liveStatus)) {
      processingText = "Compacting...";
    } else if (liveStatus.trim().toLowerCase() === "requesting") {
      processingText = "Requesting...";
    } else {
      processingText = liveStatus;
    }
  } else if (isProcessing && !stdinClosed) {
    processingText = "Processing...";
  }

  return (
    <div class="system-banner">
      <div class="banner-left">
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
        <span class="banner-title">CyDo</span>
        {sessionInfo && (
          <span
            class="banner-model clickable"
            onClick={() => {
              setDetailsOpen(!detailsOpen);
            }}
            title="Click for session details"
          >
            {sessionInfo.agent && sessionInfo.agent !== "claude" && (
              <span class="banner-agent">{sessionInfo.agent}</span>
            )}
            {sessionInfo.model}
          </span>
        )}
        {sessionInfo?.permission_mode && (
          <span class="banner-perms">{sessionInfo.permission_mode}</span>
        )}
        {taskType && <span class="banner-task-type">{taskType}</span>}
      </div>
      <div class="banner-right">
        {processingText && (
          <span class="banner-processing">{processingText}</span>
        )}
        {alive && (
          <>
            {!stdinClosed && (
              <button
                class="btn-banner-end"
                onClick={onCloseStdin}
                title="End session gracefully (Ctrl+Shift+E)"
              >
                End
              </button>
            )}
            <button
              class="btn-banner-stop"
              onClick={onStop}
              title="Force-stop task execution"
            >
              Kill
            </button>
          </>
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
        {!alive && onSetArchived && (
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
        )}
        {totalCost > 0 && (
          <span class="banner-cost">${totalCost.toFixed(4)}</span>
        )}
        <span
          class={`banner-status ${connected ? "connected" : "disconnected"}`}
        >
          {exportMode ? "Exported" : connected ? "Connected" : "Disconnected"}
        </span>
        <button
          class="theme-toggle"
          onClick={onToggleTheme}
          title={`Switch to ${theme === "dark" ? "light" : "dark"} theme`}
        >
          <span
            class="action-icon"
            dangerouslySetInnerHTML={{
              __html: theme === "dark" ? sunIcon : moonIcon,
            }}
          />
        </button>
      </div>
      {detailsOpen && sessionInfo && (
        <div class="banner-details">
          {sessionInfo.agent && (
            <div class="banner-detail-row">
              <span class="detail-label">Agent:</span> {sessionInfo.agent}
            </div>
          )}
          <div class="banner-detail-row">
            <span class="detail-label">Session:</span> {sessionInfo.sessionId}
          </div>
          <div class="banner-detail-row">
            <span class="detail-label">Version:</span> {sessionInfo.version}
          </div>
          <div class="banner-detail-row">
            <span class="detail-label">Directory:</span> {sessionInfo.cwd}
          </div>
          <div class="banner-detail-row">
            <span class="detail-label">Permissions:</span>{" "}
            {sessionInfo.permission_mode}
          </div>
          {sessionInfo.api_key_source && (
            <div class="banner-detail-row">
              <span class="detail-label">API Key:</span>{" "}
              {sessionInfo.api_key_source}
            </div>
          )}
          {sessionInfo.fast_mode_state &&
            sessionInfo.fast_mode_state !== "off" && (
              <div class="banner-detail-row">
                <span class="detail-label">Fast mode:</span>{" "}
                {sessionInfo.fast_mode_state}
              </div>
            )}
          {sessionInfo.tools.length > 0 && (
            <div class="banner-detail-row">
              <span class="detail-label">
                Tools ({sessionInfo.tools.length}):
              </span>
              <span class="detail-tools">{sessionInfo.tools.join(", ")}</span>
            </div>
          )}
          {sessionInfo.skills && sessionInfo.skills.length > 0 && (
            <div class="banner-detail-row">
              <span class="detail-label">Skills:</span>{" "}
              {sessionInfo.skills.join(", ")}
            </div>
          )}
          {sessionInfo.mcp_servers && sessionInfo.mcp_servers.length > 0 && (
            <div class="banner-detail-row">
              <span class="detail-label">MCP:</span>{" "}
              <pre class="detail-json">
                {JSON.stringify(sessionInfo.mcp_servers, null, 2)}
              </pre>
            </div>
          )}
          {sessionInfo.agents && sessionInfo.agents.length > 0 && (
            <div class="banner-detail-row">
              <span class="detail-label">Agents:</span>{" "}
              <pre class="detail-json">
                {JSON.stringify(sessionInfo.agents, null, 2)}
              </pre>
            </div>
          )}
          {sessionInfo.plugins && sessionInfo.plugins.length > 0 && (
            <div class="banner-detail-row">
              <span class="detail-label">Plugins:</span>{" "}
              <pre class="detail-json">
                {JSON.stringify(sessionInfo.plugins, null, 2)}
              </pre>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
