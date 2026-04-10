import { test, expect, enterSession, sendMessage, responseTimeout } from "./fixtures";

test("sidebar click pushes exactly one history entry", async ({ page, agentType }) => {
  // Create first session
  await enterSession(page);
  await sendMessage(page, 'Please reply with "alpha"');
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "alpha" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  // Create second session
  await enterSession(page);
  await sendMessage(page, 'Please reply with "beta"');
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "beta" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  // Record history length before clicking
  const historyBefore = await page.evaluate(() => history.length);

  // Click the first task in the sidebar
  await page
    .locator(".sidebar-item .sidebar-label", { hasText: "alpha" })
    .click();

  // Verify we navigated to the first task
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "alpha" }),
  ).toBeVisible({ timeout: 10_000 });

  // Check that exactly one history entry was pushed (not two)
  const historyAfter = await page.evaluate(() => history.length);
  expect(historyAfter - historyBefore).toBe(1);

  // The definitive test: one Back click should return to "beta"
  await page.goBack();
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "beta" }),
  ).toBeVisible({ timeout: 10_000 });
});
