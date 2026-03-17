import { test, expect, enterSession, sendMessage, killSession } from "./fixtures";

test("undo moves user message text to input box", async ({ page, agentType }) => {
  await enterSession(page);

  await sendMessage(page, 'Please reply with "first-reply"');
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "first-reply" }),
  ).toBeVisible({ timeout: 30_000 });

  await sendMessage(page, 'Please reply with "second-reply"');
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "second-reply" }),
  ).toBeVisible({ timeout: 30_000 });

  await killSession(page, agentType);

  await expect(
    page.locator(".message.user-message", { hasText: "second-reply" }),
  ).toBeVisible({ timeout: 15_000 });

  const secondUserMsg = page
    .locator(".message-wrapper", {
      has: page.locator(".user-message", { hasText: "second-reply" }),
    })
    .last();
  await secondUserMsg.hover();

  await expect(secondUserMsg.locator(".undo-btn")).toBeVisible({ timeout: 5_000 });
  await secondUserMsg.locator(".undo-btn").click();

  await expect(page.locator(".undo-dialog")).toBeVisible({ timeout: 5_000 });
  await page.locator(".btn-undo").click();

  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeVisible({ timeout: 15_000 });

  await expect(
    page.locator(".message.user-message:not(.pending)", { hasText: "second-reply" }),
  ).not.toBeVisible({ timeout: 15_000 });

  await expect(
    page.locator(".message.user-message", { hasText: "first-reply" }),
  ).toBeVisible({ timeout: 15_000 });

  await expect(input).toHaveValue(/reply with "second-reply"/, { timeout: 15_000 });
});
