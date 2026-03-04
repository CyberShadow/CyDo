import { h } from "preact";
import { useState } from "preact/hooks";
import type { SessionInfo } from "../types";

interface Props {
  sessionInfo: SessionInfo | null;
  connected: boolean;
  totalCost: number;
  isProcessing: boolean;
}

export function SystemBanner({
  sessionInfo,
  connected,
  totalCost,
  isProcessing,
}: Props) {
  const [detailsOpen, setDetailsOpen] = useState(false);

  return (
    <div class="system-banner">
      <div class="banner-left">
        <span class="banner-title">CyDo</span>
        {sessionInfo && (
          <span
            class="banner-model clickable"
            onClick={() => setDetailsOpen(!detailsOpen)}
            title="Click for session details"
          >
            {sessionInfo.model}
          </span>
        )}
        {sessionInfo?.permissionMode && (
          <span class="banner-perms">{sessionInfo.permissionMode}</span>
        )}
      </div>
      <div class="banner-right">
        {isProcessing && <span class="banner-processing">Processing...</span>}
        {totalCost > 0 && (
          <span class="banner-cost">${totalCost.toFixed(4)}</span>
        )}
        <span
          class={`banner-status ${connected ? "connected" : "disconnected"}`}
        >
          {connected ? "Connected" : "Disconnected"}
        </span>
      </div>
      {detailsOpen && sessionInfo && (
        <div class="banner-details">
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
            {sessionInfo.permissionMode}
          </div>
          {sessionInfo.apiKeySource && (
            <div class="banner-detail-row">
              <span class="detail-label">API Key:</span>{" "}
              {sessionInfo.apiKeySource}
            </div>
          )}
          {sessionInfo.fast_mode_state &&
            sessionInfo.fast_mode_state !== "off" && (
              <div class="banner-detail-row">
                <span class="detail-label">Fast mode:</span>{" "}
                {sessionInfo.fast_mode_state}
              </div>
            )}
          {sessionInfo.tools && sessionInfo.tools.length > 0 && (
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
