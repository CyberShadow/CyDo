import {
  test,
  expect,
  enterSession,
  sendMessage,
  assistantText,
  responseTimeout,
} from "./fixtures";

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
