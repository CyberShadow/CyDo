import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
  assistantText,
} from "./fixtures";

test("undo while session is running stops session and removes message", async ({
  page,
}) => {
  await enterSession(page);

  await sendMessage(page, 'Please reply with "first-reply"');
  await expect(assistantText(page, "first-reply")).toBeVisible({
      });

  await sendMessage(page, 'Please reply with "second-reply"');
  await expect(assistantText(page, "second-reply")).toBeVisible({
      });

  // Send "stall session" — mock API starts a response but never completes it,
  // keeping the session alive indefinitely.
  await sendMessage(page, "stall session");

  // Confirm the session is still running (stop button visible means it's processing).
  await expect(page.locator(".btn-banner-stop")).toBeVisible({
      });

  // Hover over the second user message to reveal the undo button.
  const secondUserMsg = page
    .locator(".message-wrapper", {
      has: page.locator(".user-message", { hasText: "second-reply" }),
    })
    .last();
  await secondUserMsg.hover();

  await expect(secondUserMsg.locator(".undo-btn")).toBeVisible({
      });
  await secondUserMsg.locator(".undo-btn").click();

  await expect(page.locator(".undo-dialog")).toBeVisible();
  await page.locator(".btn-undo").click();

  // The undo is async: backend stops the session first (setGoal Dead), then
  // performs the undo in the callback, which triggers a history reload.
  // Wait for the second user message to disappear — this is the primary
  // indicator that the full stop→undo→reload cycle completed.
  await expect(
    page.locator(".message.user-message:not(.pending)", {
      hasText: "second-reply",
    }),
  ).not.toBeVisible();

  // The first reply should still be visible.
  await expect(assistantText(page, "first-reply").first()).toBeVisible({
      });

  // Verify the session auto-resumed (input box visible).
  await expect(page.locator(".input-textarea:visible").first()).toBeVisible({
      });
});
