import { test, expect, Page } from "./fixtures";

async function enterProject(page: Page) {
  await page.goto("/");
  await page.locator(".project-card-title").first().click({ timeout: 10_000 });
  await expect(page.locator(".input-textarea:visible").first()).toBeEnabled({
    timeout: 10_000,
  });
}

async function sendMessage(page: Page, text: string) {
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled({ timeout: 10_000 });
  await input.fill(text);
  await page.locator(".btn-send:visible").first().click();
}

async function killSession(page: Page) {
  await page.locator(".btn-banner-stop").click();
  await expect(page.locator(".btn-resume")).toBeVisible({ timeout: 10_000 });
}

test("undo moves user message text to input box", async ({ page }) => {
  await enterProject(page);

  // Send first message and wait for reply
  await sendMessage(page, 'Please reply with "first-reply"');
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "first-reply",
    }),
  ).toBeVisible({ timeout: 30_000 });

  // Send second message and wait for reply
  await sendMessage(page, 'Please reply with "second-reply"');
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "second-reply",
    }),
  ).toBeVisible({ timeout: 30_000 });

  // Kill session so JSONL is finalized and undo buttons appear
  await killSession(page);

  // Wait for history reload (messages from JSONL)
  await expect(
    page.locator(".message.user-message", { hasText: "second-reply" }),
  ).toBeVisible({ timeout: 15_000 });

  // Hover the second user message to reveal the undo button
  const secondUserMsg = page
    .locator(".message-wrapper", {
      has: page.locator(".user-message", { hasText: "second-reply" }),
    })
    .last();
  await secondUserMsg.hover();

  // Click undo
  await expect(secondUserMsg.locator(".undo-btn")).toBeVisible({
    timeout: 5_000,
  });
  await secondUserMsg.locator(".undo-btn").click();

  // Confirm undo dialog (revert conversation checked by default)
  await expect(page.locator(".undo-dialog")).toBeVisible({ timeout: 5_000 });
  await page.locator(".btn-undo").click();

  // After undo, the session auto-resumes. Wait for the input box to appear
  // (replaces the Resume button once the session is alive).
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeVisible({ timeout: 15_000 });

  // The second user message should be gone
  await expect(
    page.locator(".message.user-message", { hasText: "second-reply" }),
  ).not.toBeVisible({ timeout: 15_000 });

  // The first message should still be there
  await expect(
    page.locator(".message.user-message", { hasText: "first-reply" }),
  ).toBeVisible({ timeout: 15_000 });

  // The input box should contain the undone message text
  await expect(input).toHaveValue(/reply with "second-reply"/, {
    timeout: 15_000,
  });
});
