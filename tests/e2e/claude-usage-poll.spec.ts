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

test("the usage banner fills in from the usage poll", { tag: "@claude-only" }, async ({
  page,
  agentType,
}) => {
  writeTestConfig(
    "/tmp/playwright-home/.config/cydo/config.yaml",
    `agents:
  claude:
    driver: claude
    usage_polling_period:
      turns: 1
workspaces:
  local:
    root: /tmp/cydo-test-workspace
`,
  );
  await page.waitForTimeout(500);

  await enterSession(page);
  const timeout = responseTimeout(agentType);

  // a plain reply carries no usage of its own, so the banner can only fill
  // in from the poll at the end of the turn
  await sendMessage(page, 'Please reply with "OK"');
  await expect(assistantText(page, "OK")).toHaveCount(1, { timeout });

  const usageWidget = page.locator(".banner-usage");
  await expect(usageWidget).toBeVisible({ timeout });
  const value = (label: string) =>
    usageWidget
      .locator(".banner-usage-row")
      .filter({ hasText: label })
      .first()
      .locator(".banner-usage-value");
  await expect(value("5h")).toHaveText("33%");
  await expect(value("Week")).toHaveText("66%");
  // the model-scoped row, labeled from the poll's scope; at 1% it must read
  // as 1%, not as a fraction scaled to 100%
  await expect(value("Fable")).toHaveText("1%");
});
