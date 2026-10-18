import {
  test,
  expect,
  enterSession,
  sendMessage,
  assistantText,
  responseTimeout,
} from "./fixtures";
import { writeTestConfig } from "./test-config";

test.use({
  backendEnv: {
    CLAUDE_CODE_ENTRYPOINT: "claude-desktop",
    CLAUDE_CODE_OAUTH_TOKEN: "cydo-test-oauth-token",
  },
});

test("usage banner reflects pushed rate_limit_event headers", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "claude", "claude-only test");

  await enterSession(page);

  const timeout = responseTimeout(agentType);
  await sendMessage(page, "usage headers fixture 5h");
  await expect(assistantText(page, "usage-headers-5h")).toHaveCount(1, {
    timeout,
  });

  await sendMessage(page, "usage headers fixture 7d");
  await expect(assistantText(page, "usage-headers-7d")).toHaveCount(1, {
    timeout,
  });

  const usageWidget = page.locator(".banner-usage");
  await expect(usageWidget).toBeVisible({ timeout });

  const fiveHourRow = usageWidget
    .locator(".banner-usage-row")
    .filter({ hasText: "5h" })
    .first();
  await expect(fiveHourRow.locator(".banner-usage-value")).toHaveText("42%");

  const weekRow = usageWidget
    .locator(".banner-usage-row")
    .filter({ hasText: "Week" })
    .first();
  await expect(weekRow.locator(".banner-usage-value")).toHaveText("71%");
});

test("custom Claude-backed agent still updates the Claude usage banner", { tag: "@claude-only" }, async ({
  page,
  agentType,
}) => {
  writeTestConfig(
    "/tmp/playwright-home/.config/cydo/config.yaml",
    `default_agent: claude
agents:
  claude:
    driver: claude
  work-claude:
    driver: claude
workspaces:
  local:
    root: /tmp/cydo-test-workspace
`,
  );
  await page.waitForTimeout(500);

  await enterSession(page);
  await page.selectOption(".agent-picker", "work-claude");

  const timeout = responseTimeout(agentType);
  await sendMessage(page, "usage headers fixture 5h");
  await expect(assistantText(page, "usage-headers-5h")).toHaveCount(1, {
    timeout,
  });

  await sendMessage(page, "usage headers fixture 7d");
  await expect(assistantText(page, "usage-headers-7d")).toHaveCount(1, {
    timeout,
  });

  await expect(page.locator(".banner-agent")).toContainText("work-claude");

  const usageWidget = page.locator(".banner-usage");
  await expect(usageWidget).toBeVisible({ timeout });

  const fiveHourRow = usageWidget
    .locator(".banner-usage-row")
    .filter({ hasText: "5h" })
    .first();
  await expect(fiveHourRow.locator(".banner-usage-value")).toHaveText("42%");

  const weekRow = usageWidget
    .locator(".banner-usage-row")
    .filter({ hasText: "Week" })
    .first();
  await expect(weekRow.locator(".banner-usage-value")).toHaveText("71%");
});

test("the ui config switches the usage banner to remaining shares, live", { tag: "@claude-only" }, async ({
  page,
  agentType,
}) => {
  const configPath = "/tmp/playwright-home/.config/cydo/config.yaml";
  const config = `workspaces:
  local:
    root: /tmp/cydo-test-workspace
`;

  await enterSession(page);
  const timeout = responseTimeout(agentType);
  await sendMessage(page, "usage headers fixture 5h");
  await expect(assistantText(page, "usage-headers-5h")).toHaveCount(1, {
    timeout,
  });

  const fiveHourValue = page
    .locator(".banner-usage .banner-usage-row")
    .filter({ hasText: "5h" })
    .first()
    .locator(".banner-usage-value");
  await expect(fiveHourValue).toHaveText("42%", { timeout });

  // a config reload re-sends server_status, so the open page follows it
  writeTestConfig(
    configPath,
    config + "ui:\n  usage:\n    coloring: percent\n    remaining: true\n",
  );
  await expect(fiveHourValue).toHaveText("58%", { timeout });

  writeTestConfig(configPath, config);
  await expect(fiveHourValue).toHaveText("42%", { timeout });
});
