import { useState } from "preact/hooks";
import type { SessionInfo } from "../types";
import type { AgentUsageLimitWindow, AgentUsageMessage } from "../protocol";
import type { Theme } from "../useTheme";
import sunIcon from "../icons/sun.svg?raw";
import moonIcon from "../icons/moon.svg?raw";
import hamburgerIcon from "../icons/hamburger.svg?raw";

interface Props {
  sessionInfo: SessionInfo | null;
  defaultAgent?: string;
  sessionStatus?: string | null;
  connected: boolean;
  totalCost: number;
  isProcessing: boolean;
  stdinClosed: boolean;
  alive: boolean;
  canStop: boolean;
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
  claudeUsage?: AgentUsageMessage;
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

function clamp01(value: number): number {
  if (!Number.isFinite(value)) return 0;
  if (value < 0) return 0;
  if (value > 1) return 1;
  return value;
}

export function usagePercent(utilization?: number): number | null {
  if (!Number.isFinite(utilization)) return null;
  let pct = utilization as number;
  if (pct >= 0 && pct <= 1) pct *= 100;
  if (pct < 0) pct = 0;
  if (pct > 100) pct = 100;
  return pct;
}

function hasClaudeUsageInfo(
  claudeUsage: AgentUsageMessage | undefined,
): boolean {
  return ["five_hour", "seven_day"].some((key) =>
    Number.isFinite(claudeUsage?.limits[key]?.utilization),
  );
}

export function computeUsagePaceRatio(
  utilizationPercent: number,
  resetsAtSeconds: number | undefined,
  windowSeconds: number,
  nowSeconds: number,
): number {
  const usageFraction = clamp01(utilizationPercent / 100);
  if (!Number.isFinite(resetsAtSeconds) || !windowSeconds) {
    return usageFraction / 0.05;
  }
  const remaining = (resetsAtSeconds as number) - nowSeconds;
  const timeProgress = clamp01((windowSeconds - remaining) / windowSeconds);
  return usageFraction / Math.max(timeProgress, 0.05);
}

export function usageFillColor(
  utilizationPercent: number,
  resetsAtSeconds: number | undefined,
  windowSeconds: number,
  nowSeconds: number,
): string {
  const usageFraction = clamp01(utilizationPercent / 100);
  if (usageFraction <= 0.01) return "rgb(76, 175, 80)";
  const ratio = computeUsagePaceRatio(
    utilizationPercent,
    resetsAtSeconds,
    windowSeconds,
    nowSeconds,
  );
  if (ratio >= 1.5) return "rgb(220, 67, 67)";
  if (ratio >= 1.0) return "rgb(242, 153, 74)";
  return "rgb(173, 186, 73)";
}

function usageTitle(
  label: string,
  window: AgentUsageLimitWindow | undefined,
): string {
  const status = window?.status ? `, status: ${window.status}` : "";
  const resetTs = window?.resetsAt;
  const reset =
    Number.isFinite(resetTs) && resetTs
      ? `, resets: ${new Date(resetTs * 1000).toLocaleString()}`
      : "";
  const pct = usagePercent(window?.utilization);
  if (pct === null) return `${label}: unknown${status}${reset}`;
  return `${label}: ${pct.toFixed(1)}%${status}${reset}`;
}

export function SystemBanner({
  sessionInfo,
  defaultAgent,
  sessionStatus,
  connected,
  totalCost,
  isProcessing,
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
  claudeUsage,
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
  const nowSeconds = Date.now() / 1000;
  const fiveHour = claudeUsage?.limits.five_hour;
  const week = claudeUsage?.limits.seven_day;
  const usageRows = [
    { label: "5h", window: fiveHour, windowSeconds: 5 * 60 * 60 },
    { label: "Week", window: week, windowSeconds: 7 * 24 * 60 * 60 },
  ];
  const showClaudeUsage = hasClaudeUsageInfo(claudeUsage);

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
            {sessionInfo.agent_name &&
              sessionInfo.agent_name !== defaultAgent && (
                <span class="banner-agent">{sessionInfo.agent_name}</span>
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
        {showClaudeUsage && (
          <div class="banner-usage" title="Claude account usage">
            {usageRows.map((row) => {
              const pct = usagePercent(row.window?.utilization);
              const color =
                pct === null
                  ? "var(--border)"
                  : usageFillColor(
                      pct,
                      row.window?.resetsAt,
                      row.windowSeconds,
                      nowSeconds,
                    );
              const valueText = pct === null ? "--" : `${pct.toFixed(0)}%`;
              return (
                <div
                  key={row.label}
                  class="banner-usage-row"
                  title={usageTitle(row.label, row.window)}
                >
                  <span class="banner-usage-label">{row.label}</span>
                  <span class="banner-usage-bar">
                    <span
                      class="banner-usage-fill"
                      style={{
                        width: pct === null ? "0%" : `${pct}%`,
                        backgroundColor: color,
                      }}
                    />
                  </span>
                  <span class="banner-usage-value">{valueText}</span>
                </div>
              );
            })}
          </div>
        )}
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
            {canStop && (
              <button
                class="btn-banner-stop"
                onClick={onStop}
                title="Force-stop task execution"
              >
                Kill
              </button>
            )}
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
