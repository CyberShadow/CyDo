import { test, expect, enterSession, sendMessage } from "./fixtures";

test("process failure shows session-failed label", async ({ page }) => {
  await enterSession(page);
  await sendMessage(page, "hello");

  await expect(
    page.locator(".session-failed-label"),
  ).toBeVisible({ timeout: 15_000 });

  await expect(
    page.locator(".input-textarea"),
  ).not.toBeVisible({ timeout: 5_000 });
});

test("process failure shows error text", async ({ page }) => {
  await enterSession(page);
  await sendMessage(page, "hello");

  await expect(
    page.locator(".session-failed-label", {
      hasText: /simulated process failure/,
    }),
  ).toBeVisible({ timeout: 15_000 });
});
