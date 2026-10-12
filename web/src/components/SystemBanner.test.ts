import { describe, expect, it } from "vitest";
import { h } from "preact";
import renderToString from "preact-render-to-string";
import type { AgentUsageMessage } from "../protocol";
import {
  computeUsagePaceRatio,
  isCompactingStatus,
  normalizeSessionStatus,
  SystemBanner,
  usagePercent,
  usageFillColor,
} from "./SystemBanner";

function renderSystemBanner({
  claudeUsage,
  connected = true,
  tasksLoading = false,
  exportMode = false,
}: {
  claudeUsage?: AgentUsageMessage;
  connected?: boolean;
  tasksLoading?: boolean;
  exportMode?: boolean;
} = {}): string {
  return renderToString(
    h(SystemBanner, {
      sessionInfo: null,
      connected,
      tasksLoading,
      totalCost: 0,
      isProcessing: false,
      stdinClosed: false,
      alive: false,
      canStop: false,
      theme: "dark",
      onToggleTheme: () => {},
      onStop: () => {},
      onCloseStdin: () => {},
      claudeUsage,
      exportMode,
    }),
  );
}

function usageMessage(limits: AgentUsageMessage["limits"]): AgentUsageMessage {
  return {
    type: "agent_usage",
    agent: "claude",
    updated_at: 1_700_000_000,
    limits,
  };
}

describe("SystemBanner status helpers", () => {
  it("recognizes codex compacting status strings", () => {
    expect(isCompactingStatus("compacting")).toBe(true);
    expect(isCompactingStatus("Compacting context...")).toBe(true);
  });

  it("does not treat non-compacting statuses as compacting", () => {
    expect(isCompactingStatus("requesting")).toBe(false);
    expect(isCompactingStatus("compacted")).toBe(false);
  });

  it("normalizes empty status strings to null", () => {
    expect(normalizeSessionStatus("")).toBeNull();
    expect(normalizeSessionStatus("   ")).toBeNull();
    expect(normalizeSessionStatus("requesting")).toBe("requesting");
  });

  it("colors usage by pace ratio thresholds", () => {
    const now = 1_700_000_000;
    const fiveHour = 5 * 60 * 60;

    const green = usageFillColor(0.5, now + fiveHour, fiveHour, now);
    const yellow = usageFillColor(
      20,
      now + fiveHour - fiveHour * 0.2,
      fiveHour,
      now,
    );
    const red = usageFillColor(
      95,
      now + fiveHour - fiveHour * 0.2,
      fiveHour,
      now,
    );

    expect(green).toBe("rgb(76, 175, 80)");
    expect(yellow).toBe("rgb(242, 153, 74)");
    expect(red).toBe("rgb(220, 67, 67)");
  });

  it("computes pace ratio using elapsed window progress", () => {
    const now = 1_700_000_000;
    const week = 7 * 24 * 60 * 60;
    const ratio = computeUsagePaceRatio(70, now + week * 0.5, week, now);
    expect(ratio).toBeCloseTo(1.4, 3);
  });

  it("treats missing utilization as unknown", () => {
    expect(usagePercent(undefined)).toBeNull();
    expect(usagePercent(Number.NaN)).toBeNull();
  });

  it("keeps small percentages intact and clamps out-of-range ones", () => {
    // a freshly-reset weekly window reports 1, meaning 1%, not 100%
    expect(usagePercent(1)).toBe(1);
    expect(usagePercent(0.42)).toBe(0.42);
    expect(usagePercent(0)).toBe(0);
    expect(usagePercent(140)).toBe(100);
    expect(usagePercent(-5)).toBe(0);
  });
});

describe("SystemBanner connection status", () => {
  it("renders the disconnected status before task loading state", () => {
    const html = renderSystemBanner({ connected: false, tasksLoading: true });

    expect(html).toContain(
      '<span class="banner-status disconnected">Disconnected</span>',
    );
  });

  it("renders the loading status while a connected task list is partial", () => {
    const html = renderSystemBanner({ connected: true, tasksLoading: true });

    expect(html).toContain(
      '<span class="banner-status loading">Loading…</span>',
    );
  });

  it("renders the connected status after task loading completes", () => {
    const html = renderSystemBanner({ connected: true, tasksLoading: false });

    expect(html).toContain(
      '<span class="banner-status connected">Connected</span>',
    );
  });

  it("gives export mode priority over the live connection status", () => {
    const html = renderSystemBanner({
      connected: false,
      tasksLoading: true,
      exportMode: true,
    });

    expect(html).toContain(
      '<span class="banner-status disconnected">Exported</span>',
    );
  });
});

describe("SystemBanner Claude usage", () => {
  it("does not render usage when no Claude window has utilization", () => {
    const html = renderSystemBanner({
      claudeUsage: usageMessage({
        five_hour: { resetsAt: 1_700_018_000 },
        seven_day: { resetsAt: 1_700_604_800 },
      }),
    });

    expect(html).not.toContain("banner-usage");
    expect(html).not.toContain("--");
  });

  it("renders usage when a Claude window has finite utilization", () => {
    const futureTime = Math.floor(Date.now() / 1000) + 10000;
    const html = renderSystemBanner({
      claudeUsage: usageMessage({
        five_hour: { utilization: 42, resetsAt: futureTime },
        seven_day: {},
      }),
    });

    expect(html).toContain("banner-usage");
    expect(html).toContain("42%");
  });

  it("hides usage widget when all windows are expired", () => {
    const pastTime = Math.floor(Date.now() / 1000) - 100;
    const html = renderSystemBanner({
      claudeUsage: usageMessage({
        five_hour: { utilization: 50, resetsAt: pastTime },
        seven_day: { utilization: 80, resetsAt: pastTime },
      }),
    });

    expect(html).not.toContain("banner-usage");
  });

  it("shows non-expired window when only one window is expired", () => {
    const pastTime = Math.floor(Date.now() / 1000) - 100;
    const futureTime = Math.floor(Date.now() / 1000) + 10000;
    const html = renderSystemBanner({
      claudeUsage: usageMessage({
        five_hour: { utilization: 30, resetsAt: pastTime },
        seven_day: { utilization: 60, resetsAt: futureTime },
      }),
    });

    expect(html).toContain("banner-usage");
    expect(html).toContain("60%");
    expect(html).not.toContain("30%");
  });

  it("renders the model-scoped row a usage poll reports", () => {
    const futureTime = Math.floor(Date.now() / 1000) + 10000;
    const html = renderSystemBanner({
      claudeUsage: usageMessage({
        five_hour: { utilization: 8, resetsAt: futureTime },
        model: { utilization: 1, resetsAt: futureTime, label: "Fable" },
      }),
    });

    expect(html).toContain("Fable");
    expect(html).toContain("1%");
    expect(html).not.toContain("100%");
  });
});
