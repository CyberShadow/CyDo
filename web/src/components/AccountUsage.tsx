import type {
  AgentUsageLimitWindow,
  AgentUsageMessage,
  UiConfig,
} from "../protocol";

/** How far ahead to warn that the login expires (as the Claude CLI does). */
const loginExpiryWarningDays = 10;

/** A warning that the account login is about to expire, if it is. */
export function loginExpiryWarning(
  expiresAt: string | undefined,
  nowMs: number,
): string | null {
  if (expiresAt === undefined) return null;
  const msLeft = Date.parse(expiresAt) - nowMs;
  const dayMs = 24 * 60 * 60 * 1000;
  if (msLeft > loginExpiryWarningDays * dayMs) return null;
  if (msLeft <= 0) return "Login expired";
  const days = Math.ceil(msLeft / dayMs);
  return `Login expires in ${days} ${days === 1 ? "day" : "days"}`;
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
  if (pct < 0) pct = 0;
  if (pct > 100) pct = 100;
  return pct;
}

function isWindowExpired(
  window: AgentUsageLimitWindow | undefined,
  nowSeconds: number,
): boolean {
  return (
    Number.isFinite(window?.resetsAt) &&
    (window!.resetsAt as number) < nowSeconds
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

export function percentUsageFillColor(utilizationPercent: number): string {
  const pct = clamp01(utilizationPercent / 100) * 100;
  const red = Math.round(255 * Math.min(1, pct / 50));
  const green = Math.round(255 * Math.min(1, (100 - pct) / 50));
  return `rgb(${red}, ${green}, 0)`;
}

function usageTitle(
  label: string,
  window: AgentUsageLimitWindow | undefined,
  pct: number | null,
  remaining: boolean,
): string {
  const status = window?.status ? `, status: ${window.status}` : "";
  const resetTs = window?.resetsAt;
  const reset =
    Number.isFinite(resetTs) && resetTs
      ? `, resets: ${new Date(resetTs * 1000).toLocaleString()}`
      : "";
  if (pct === null) return `${label}: unknown${status}${reset}`;
  const suffix = remaining ? " remaining" : "";
  return `${label}: ${pct.toFixed(1)}%${suffix}${status}${reset}`;
}

export function AccountUsage({
  claudeUsage,
  ui,
}: {
  claudeUsage?: AgentUsageMessage;
  ui?: UiConfig;
}) {
  const remaining = ui?.usage?.remaining ?? false;
  const nowSeconds = Date.now() / 1000;
  const fiveHour = isWindowExpired(claudeUsage?.limits.five_hour, nowSeconds)
    ? undefined
    : claudeUsage?.limits.five_hour;
  const week = isWindowExpired(claudeUsage?.limits.seven_day, nowSeconds)
    ? undefined
    : claudeUsage?.limits.seven_day;
  const weekSeconds = 7 * 24 * 60 * 60;
  const usageRows = [
    { label: "5h", window: fiveHour, windowSeconds: 5 * 60 * 60 },
    { label: "Week", window: week, windowSeconds: weekSeconds },
    ...(claudeUsage?.model_weekly ?? [])
      .filter((window) => !isWindowExpired(window, nowSeconds))
      .map((window) => ({
        label: window.label,
        window,
        windowSeconds: weekSeconds,
      })),
  ];
  const loginWarning = loginExpiryWarning(
    claudeUsage?.credential_expires_at,
    Date.now(),
  );
  const showClaudeUsage = usageRows.some((row) =>
    Number.isFinite(row.window?.utilization),
  );
  if (!showClaudeUsage && !loginWarning) return null;
  return (
    <div class="sidebar-account">
      {loginWarning && (
        <span
          class="account-login-expiry"
          title={`The Claude login expires ${claudeUsage!.credential_expires_at!}. Run /login in Claude Code to renew it.`}
        >
          {loginWarning}
        </span>
      )}
      {showClaudeUsage && (
        <div class="account-usage" title="Claude account usage">
          {usageRows.map((row) => {
            const pct = usagePercent(row.window?.utilization);
            const color =
              pct === null
                ? "var(--border)"
                : ui?.usage?.coloring === "percent"
                  ? percentUsageFillColor(pct)
                  : usageFillColor(
                      pct,
                      row.window?.resetsAt,
                      row.windowSeconds,
                      nowSeconds,
                    );
            const shownPct = pct !== null && remaining ? 100 - pct : pct;
            const valueText =
              shownPct === null ? "--" : `${shownPct.toFixed(0)}%`;
            return (
              <div
                key={row.label}
                class="account-usage-row"
                title={usageTitle(row.label, row.window, shownPct, remaining)}
              >
                <span class="account-usage-label">{row.label}</span>
                <span class="account-usage-bar">
                  <span
                    class="account-usage-fill"
                    style={{
                      width: `${shownPct ?? 0}%`,
                      backgroundColor: color,
                    }}
                  />
                </span>
                <span class="account-usage-value">{valueText}</span>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
