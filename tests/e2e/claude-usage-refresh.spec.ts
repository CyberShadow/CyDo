import { writeFileSync } from "fs";
import type { Page } from "@playwright/test";
import {
  activeStatusBand,
  assistantText,
  enterSession,
  expect,
  responseTimeout,
  sendMessage,
  test,
} from "./fixtures";

test.use({
  backendEnv: {
    ANTHROPIC_API_KEY: "",
    CLAUDE_CODE_OAUTH_TOKEN: "",
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "",
    HTTPS_PROXY: "http://127.0.0.1:9000",
    NODE_TLS_REJECT_UNAUTHORIZED: "0",
  },
});

const usageUrl = "http://127.0.0.1:9000/api/claude-usage";
const resets_at = "2099-01-01T00:00:00Z";
const workspace = `workspaces:
  local:
    root: /tmp/cydo-test-workspace
`;

function usageWindows(fiveHour: number, week: number) {
  return {
    five_hour: { utilization: fiveHour, resets_at },
    seven_day: { utilization: week, resets_at },
  };
}

async function setUsage(status: number, body: object) {
  const response = await fetch(usageUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ status, body }),
  });
  expect(response.status).toBe(204);
}

async function usageRequests(): Promise<number> {
  const response = await fetch(`${usageUrl}/requests`);
  expect(response.ok).toBe(true);
  const { requests } = await response.json();
  return requests;
}

function usageValue(page: Page, label: string) {
  return page
    .locator(".sidebar-account .account-usage-row")
    .filter({ has: page.getByText(label, { exact: true }) })
    .locator(".account-usage-value");
}

test.beforeEach(() => {
  writeFileSync(
    "/tmp/claude-test-home/.credentials.json",
    JSON.stringify({
      claudeAiOauth: {
        accessToken: "fake",
        refreshToken: "fake",
        expiresAt: Date.now() + 86_400_000,
        scopes: ["user:profile", "user:inference"],
        subscriptionType: "max",
        rateLimitTier: "default_claude_max_20x",
      },
    }),
  );
});

const startupTest = test.extend({
  cydoConfig: `${workspace}
agents: {claude: {usage_polling_period: {timespan: {hours: 1}}}}
`,
});

startupTest("startup refresh shows usage without a rate-limit push", { tag: "@claude-only" }, async ({
  page,
  agentType,
}) => {
  await setUsage(200, {
    ...usageWindows(12.5, 34.5),
    limits: [
      {
        kind: "weekly_scoped",
        group: "weekly",
        percent: 42.5,
        resets_at,
        scope: { model: { display_name: "Fable" } },
      },
    ],
  });
  await enterSession(page);
  await sendMessage(page, "hello");
  await expect(assistantText(page, "hello")).toHaveCount(1, {
    timeout: responseTimeout(agentType),
  });
  await expect(usageValue(page, "5h")).toHaveText("13%");
  await expect(usageValue(page, "Week")).toHaveText("35%");
  await expect(usageValue(page, "Fable")).toHaveText("43%");
  expect(await usageRequests()).toBeGreaterThanOrEqual(1);
});

const idleTest = test.extend({
  cydoConfig: `${workspace}
agents: {claude: {usage_polling_period: {timespan: {seconds: 2}}}}
`,
});

idleTest("timer refresh updates usage while idle", { tag: "@claude-only" }, async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  await sendMessage(page, "hello");
  await expect(assistantText(page, "hello")).toHaveCount(1, {
    timeout: responseTimeout(agentType),
  });
  await expect(activeStatusBand(page)).toHaveAttribute("data-status", "idle");
  await expect.poll(usageRequests).toBeGreaterThanOrEqual(1);
  await expect(page.locator(".sidebar-account .account-usage")).toHaveCount(0);

  await setUsage(200, usageWindows(61.25, 81.25));
  await expect(usageValue(page, "5h")).toHaveText("61%");
  await expect(usageValue(page, "Week")).toHaveText("81%");

  // Claude can serve its successful snapshot for up to 60 seconds.
  await setUsage(200, usageWindows(15, 35));
});
