import { test, expect, enterSession, sendMessage, killSession } from "./fixtures";

test("undo while session is running stops session and removes message", async ({ page }) => {
  await enterSession(page);

  await sendMessage(page, 'Please reply with "first-reply"');
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "first-reply" }),
  ).toBeVisible({ timeout: 30_000 });

  await sendMessage(page, 'Please reply with "second-reply"');
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "second-reply" }),
  ).toBeVisible({ timeout: 30_000 });

  // Send "stall session" — mock API starts a response but never completes it,
  // keeping the session alive indefinitely.
  await sendMessage(page, "stall session");

  // Confirm the session is still running (stop button visible means it's processing).
  await expect(page.locator(".btn-banner-stop")).toBeVisible({ timeout: 30_000 });

  // Hover over the second user message to reveal the undo button.
  const secondUserMsg = page
    .locator(".message-wrapper", {
      has: page.locator(".user-message", { hasText: "second-reply" }),
    })
    .last();
  await secondUserMsg.hover();

  await expect(secondUserMsg.locator(".undo-btn")).toBeVisible({ timeout: 30_000 });
  await secondUserMsg.locator(".undo-btn").click();

  await expect(page.locator(".undo-dialog")).toBeVisible({ timeout: 5_000 });
  await page.locator(".btn-undo").click();

  // The undo is async: backend stops the session first (setGoal Dead), then
  // performs the undo in the callback, which triggers a history reload.
  // Wait for the second user message to disappear — this is the primary
  // indicator that the full stop→undo→reload cycle completed.
  await expect(
    page.locator(".message.user-message:not(.pending)", { hasText: "second-reply" }),
  ).not.toBeVisible({ timeout: 30_000 });

  // The first reply should still be visible.
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "first-reply" }).first(),
  ).toBeVisible({ timeout: 15_000 });

  // Verify the session auto-resumed (input box visible).
  await expect(
    page.locator(".input-textarea:visible").first(),
  ).toBeVisible({ timeout: 15_000 });
});
