import { test, expect, enterSession, sendMessage } from "../e2e/fixtures";

test("process failure shows session-failed label", async ({ page }) => {
  await enterSession(page);
  await sendMessage(page, "hello");

  await expect(
    page.locator(".session-failed-label"),
  ).toBeVisible();

  await expect(
    page.locator(".input-textarea"),
  ).not.toBeVisible();
});

test("process failure shows error text", async ({ page }) => {
  await enterSession(page);
  await sendMessage(page, "hello");

  await expect(
    page.locator(".session-failed-label", {
      hasText: /simulated process failure/,
    }),
  ).toBeVisible();
});
