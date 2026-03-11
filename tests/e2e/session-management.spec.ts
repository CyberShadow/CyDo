import { test, expect, Page } from "./fixtures";

/** Navigate to the first project and wait for WebSocket connection. */
async function enterProject(page: Page) {
  await page.goto("/");
  await page.locator(".project-card-title").first().click({ timeout: 10_000 });
  await expect(page.locator(".input-textarea:visible").first()).toBeEnabled({
    timeout: 10_000,
  });
}

/** Send a message from whichever input is currently visible. */
async function sendMessage(page: Page, text: string) {
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled({ timeout: 10_000 });
  await input.click();
  await input.fill(text);
  const sendBtn = page.locator(".btn-send:visible").first();
  // Wait for the controlled component to update (fill may not trigger onInput reliably)
  try {
    await expect(sendBtn).toBeEnabled({ timeout: 2_000 });
  } catch {
    // Fallback: clear and type character by character
    await input.clear();
    await input.pressSequentially(text);
    await expect(sendBtn).toBeEnabled({ timeout: 2_000 });
  }
  await sendBtn.click();
}

test("session creation shows sidebar entry", async ({ page }) => {
  await enterProject(page);
  await sendMessage(page, 'Please reply with "hello"');

  // A new sidebar item should appear with the message as title
  await expect(
    page.locator(".sidebar-item .sidebar-label", { hasText: 'Please reply with "hello"' }),
  ).toBeVisible({ timeout: 15_000 });

  // The session view should show this user message
  await expect(
    page.locator(".message.user-message", { hasText: 'Please reply with "hello"' }),
  ).toBeVisible({ timeout: 15_000 });
});

test("session switching preserves messages", async ({ page }) => {
  await enterProject(page);

  // Create first task
  await sendMessage(page, 'Please reply with "first"');
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "first" }),
  ).toBeVisible({ timeout: 30_000 });

  // Go back to "New Task" view — wait for the transition to complete
  await page.locator(".sidebar-new-task").click();
  await expect(page.locator(".session-empty")).toBeVisible({ timeout: 5_000 });

  // Create second task — use sendMessage (now only one visible input)
  await sendMessage(page, 'Please reply with "second"');

  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "second" }),
  ).toBeVisible({ timeout: 30_000 });

  // Switch back to first task via sidebar
  await page
    .locator(".sidebar-item .sidebar-label", { hasText: 'Please reply with "first"' })
    .click();

  // First task's messages should be visible
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "first" }),
  ).toBeVisible({ timeout: 10_000 });

  // Second task's response should NOT be visible
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "second" }),
  ).not.toBeVisible();
});

test("build artifact sanity: hashed asset references", async ({ page }) => {
  const response = await page.goto("/");
  const html = await response!.text();

  // Vite produces hashed filenames like index-XXXXXXXX.js and index-XXXXXXXX.css
  expect(html).toMatch(/\/assets\/index-[A-Za-z0-9_-]+\.js/);
  expect(html).toMatch(/\/assets\/index-[A-Za-z0-9_-]+\.css/);

  // Must NOT contain raw development references
  expect(html).not.toContain("/src/main.tsx");
});
