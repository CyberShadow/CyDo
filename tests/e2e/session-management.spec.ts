import { test, expect, enterSession, sendMessage, responseTimeout } from "./fixtures";

test("session creation shows sidebar entry", async ({ page, agentType }) => {
  await enterSession(page, agentType);
  await sendMessage(page, 'Please reply with "hello-claude"');

  await expect(
    page.locator(".sidebar-item .sidebar-label", { hasText: 'Please reply with "hello-claude"' }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  await expect(
    page.locator(".message.user-message", { hasText: 'Please reply with "hello-claude"' }),
  ).toBeVisible({ timeout: 15_000 });
});

test("session switching preserves messages", async ({ page, agentType }) => {
  // Create first session and send a message
  await enterSession(page, agentType);
  await sendMessage(page, 'Please reply with "first"');
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "first" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  // Create second session and send a message
  await enterSession(page, agentType);
  await sendMessage(page, 'Please reply with "second"');
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "second" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  // Switch back to first task via sidebar
  await page
    .locator(".sidebar-item .sidebar-label", { hasText: 'Please reply with "first"' })
    .click();

  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "first" }),
  ).toBeVisible({ timeout: 10_000 });

  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "second" }),
  ).not.toBeVisible();
});

test("build artifact sanity: hashed asset references", async ({ page, agentType }) => {
  test.skip(agentType === "codex", "agent-agnostic, runs in claude project only");
  const response = await page.goto("/");
  const html = await response!.text();

  expect(html).toMatch(/\/assets\/index-[A-Za-z0-9_-]+\.js/);
  expect(html).toMatch(/\/assets\/index-[A-Za-z0-9_-]+\.css/);
  expect(html).not.toContain("/src/main.tsx");
});
