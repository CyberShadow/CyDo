import { h } from "preact";
import type { SessionInfo } from "../app";

interface Props {
  sessionInfo: SessionInfo | null;
  connected: boolean;
  totalCost: number;
  isProcessing: boolean;
}

export function SystemBanner({ sessionInfo, connected, totalCost, isProcessing }: Props) {
  return (
    <div class="system-banner">
      <div class="banner-left">
        <span class="banner-title">CyDo</span>
        {sessionInfo && (
          <span class="banner-model">{sessionInfo.model}</span>
        )}
      </div>
      <div class="banner-right">
        {isProcessing && <span class="banner-processing">Processing...</span>}
        {totalCost > 0 && (
          <span class="banner-cost">${totalCost.toFixed(4)}</span>
        )}
        <span class={`banner-status ${connected ? "connected" : "disconnected"}`}>
          {connected ? "Connected" : "Disconnected"}
        </span>
      </div>
    </div>
  );
}
