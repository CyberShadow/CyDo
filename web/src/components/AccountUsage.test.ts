import { describe, expect, it, vi } from "vitest";
import { h } from "preact";
import renderToString from "preact-render-to-string";
import type { AgentUsageMessage } from "../protocol";
import {
  AccountUsage,
  computeUsagePaceRatio,
  loginExpiryWarning,
  percentUsageFillColor,
  usageFillColor,
  usagePercent,
} from "./AccountUsage";

function renderUsage(props: Parameters<typeof AccountUsage>[0] = {}) {
  return renderToString(h(AccountUsage, props));
}

describe("usage pace", () => {
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
});

function usageMessage(limits: AgentUsageMessage["limits"]): AgentUsageMessage {
  return {
    type: "agent_usage",
    profile: "/tmp/claude",
    updated_at: 1_700_000_000,
    limits,
  };
}

describe("AccountUsage", () => {
  it("does not render usage when no Claude window has utilization", () => {
    const now = 1_700_000_000;
    const clock = vi.spyOn(Date, "now").mockReturnValue(now * 1000);
    try {
      const html = renderUsage({
        claudeUsage: usageMessage({
          five_hour: { resetsAt: now + 18_000 },
          seven_day: { resetsAt: now + 604_800 },
        }),
      });

      expect(html).not.toContain("account-usage");
      expect(html).not.toContain("--");
    } finally {
      clock.mockRestore();
    }
  });

  it("renders used share with pace coloring by default", () => {
    const html = renderUsage({
      claudeUsage: usageMessage({
        five_hour: { utilization: 42 },
        seven_day: {},
      }),
    });

    expect(html).toContain('title="5h: 42.0%"');
    expect(html).toContain(
      'style="width:42%;background-color:rgb(220, 67, 67);"',
    );
    expect(html).toContain('class="account-usage-value">42%</span>');
  });

  it("renders sub-one-percent utilization as a percentage", () => {
    const html = renderUsage({
      claudeUsage: usageMessage({ five_hour: { utilization: 0.5 } }),
    });

    expect(html).toContain('class="account-usage-value">1%</span>');
  });

  it("shows current model windows and hides expired model windows", () => {
    const now = Date.now() / 1000;
    const html = renderUsage({
      claudeUsage: {
        ...usageMessage({}),
        model_weekly: [
          { label: "Fable", utilization: 42.5, resetsAt: now + 3600 },
          { label: "Expired model", utilization: 71, resetsAt: now - 3600 },
        ],
      },
    });

    expect(html).toContain('class="account-usage-label">Fable</span>');
    expect(html).toContain('class="account-usage-value">43%</span>');
    expect(html).not.toContain("Expired model");
  });

  it.each([[undefined], [[]]])("omits model rows for %j", (model_weekly) => {
    const html = renderUsage({
      claudeUsage: {
        ...usageMessage({ five_hour: { utilization: 42 } }),
        model_weekly,
      },
    });

    expect(html.match(/class="account-usage-row"/g)).toHaveLength(2);
  });

  it.each([
    [0, "rgb(0, 255, 0)"],
    [25, "rgb(128, 255, 0)"],
    [50, "rgb(255, 255, 0)"],
    [75, "rgb(255, 128, 0)"],
    [100, "rgb(255, 0, 0)"],
  ])("maps %i%% used to %s in percent mode", (used, color) => {
    expect(percentUsageFillColor(used)).toBe(color);
  });

  it.each([
    ["pace", "rgb(220, 67, 67)"],
    ["percent", "rgb(214, 255, 0)"],
  ] as const)(
    "renders remaining share with %s coloring based on used share",
    (coloring, color) => {
      const html = renderUsage({
        claudeUsage: usageMessage({ five_hour: { utilization: 42 } }),
        ui: { usage: { coloring, remaining: true } },
      });

      expect(html).toContain('title="5h: 58.0% remaining"');
      expect(html).toContain(`style="width:58%;background-color:${color};"`);
      expect(html).toContain('class="account-usage-value">58%</span>');
    },
  );

  it("hides usage widget when all windows are expired", () => {
    const pastTime = Math.floor(Date.now() / 1000) - 100;
    const html = renderUsage({
      claudeUsage: usageMessage({
        five_hour: { utilization: 50, resetsAt: pastTime },
        seven_day: { utilization: 80, resetsAt: pastTime },
      }),
    });

    expect(html).not.toContain("account-usage");
  });

  it("shows non-expired window when only one window is expired", () => {
    const pastTime = Math.floor(Date.now() / 1000) - 100;
    const futureTime = Math.floor(Date.now() / 1000) + 10000;
    const html = renderUsage({
      claudeUsage: usageMessage({
        five_hour: { utilization: 30, resetsAt: pastTime },
        seven_day: { utilization: 60, resetsAt: futureTime },
      }),
    });

    expect(html).toContain("account-usage");
    expect(html).toContain("60%");
    expect(html).not.toContain("30%");
  });
});

describe("loginExpiryWarning", () => {
  const now = Date.parse("2026-11-10T12:00:00Z");

  it("stays quiet while the login has more than ten days left", () => {
    expect(loginExpiryWarning("2026-11-21T12:00:00Z", now)).toBeNull();
    expect(loginExpiryWarning(undefined, now)).toBeNull();
  });

  it("counts the remaining days, rounding up", () => {
    expect(loginExpiryWarning("2026-11-12T12:31:33Z", now)).toBe(
      "Login expires in 3 days",
    );
    expect(loginExpiryWarning("2026-11-10T13:00:00Z", now)).toBe(
      "Login expires in 1 day",
    );
  });

  it("says when the login has expired", () => {
    expect(loginExpiryWarning("2026-11-09T12:00:00Z", now)).toBe(
      "Login expired",
    );
  });
});
