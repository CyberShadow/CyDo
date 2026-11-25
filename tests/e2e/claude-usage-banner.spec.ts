import { readFileSync } from "fs";
import {
  test,
  expect,
  enterSession,
  sendMessage,
  assistantText,
  responseTimeout,
} from "./fixtures";
import { withTestAgentEnvironment, writeTestConfig } from "./test-config";

test.use({
  backendEnv: {
    CLAUDE_CODE_ENTRYPOINT: "claude-desktop",
    CLAUDE_CODE_OAUTH_TOKEN: "cydo-test-oauth-token",
  },
});

test("sidebar account usage reflects pushed rate_limit_event headers", async ({
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

  const account = page.locator(".sidebar .sidebar-account");
  await expect(account).toBeVisible({ timeout });

  const fiveHourRow = account
    .locator(".account-usage-row")
    .filter({ hasText: "5h" })
    .first();
  await expect(fiveHourRow.locator(".account-usage-value")).toHaveText("42%");

  const weekRow = account
    .locator(".account-usage-row")
    .filter({ hasText: "Week" })
    .first();
  await expect(weekRow.locator(".account-usage-value")).toHaveText("71%");
});

test("sidebar account usage updates when display settings are reloaded", { tag: "@claude-only" }, async ({
  page,
  agentType,
}) => {
  const configPath = "/tmp/playwright-home/.config/cydo/config.yaml";
  const original = readFileSync(configPath, "utf8");
  const sharedPrefix = withTestAgentEnvironment("").trimEnd() + "\n";
  expect(original.startsWith(sharedPrefix)).toBe(true);
  const config = original.slice(sharedPrefix.length);

  await enterSession(page);
  const timeout = responseTimeout(agentType);
  await sendMessage(page, "usage headers fixture 5h");
  await expect(assistantText(page, "usage-headers-5h")).toHaveCount(1, {
    timeout,
  });

  const fiveHourRow = page
    .locator(".sidebar .sidebar-account .account-usage-row")
    .filter({ has: page.getByText("5h", { exact: true }) });
  const value = fiveHourRow.locator(".account-usage-value");
  const fill = fiveHourRow.locator(".account-usage-fill");
  const width = () => fill.evaluate((element) => element.style.width);

  await expect(value).toHaveText("42%");
  await expect.poll(width).toBe("42%");
  await expect(fill).toHaveCSS("background-color", "rgb(220, 67, 67)");

  try {
    writeTestConfig(
      configPath,
      `${config.trimEnd()}
ui:
  usage:
    coloring: percent
    remaining: true
`,
    );
    await expect(value).toHaveText("58%");
    await expect.poll(width).toBe("58%");
    await expect(fill).toHaveCSS("background-color", "rgb(214, 255, 0)");
  } finally {
    writeTestConfig(configPath, config);
  }

  await expect(value).toHaveText("42%");
  await expect.poll(width).toBe("42%");
  await expect(fill).toHaveCSS("background-color", "rgb(220, 67, 67)");
});

test("custom Claude-backed agent still updates the Claude sidebar account usage", { tag: "@claude-only" }, async ({
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

  await expect(page.locator(".task-bar-agent")).toContainText("work-claude");

  const account = page.locator(".sidebar .sidebar-account");
  await expect(account).toBeVisible({ timeout });

  const fiveHourRow = account
    .locator(".account-usage-row")
    .filter({ hasText: "5h" })
    .first();
  await expect(fiveHourRow.locator(".account-usage-value")).toHaveText("42%");

  const weekRow = account
    .locator(".account-usage-row")
    .filter({ hasText: "Week" })
    .first();
  await expect(weekRow.locator(".account-usage-value")).toHaveText("71%");
});
