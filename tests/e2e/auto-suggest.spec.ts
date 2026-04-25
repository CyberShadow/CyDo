import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
} from "./fixtures";

test("suggestions appear after agent responds", async ({ page, agentType }) => {
  await enterSession(page);
  await sendMessage(page, 'Please reply with "done"');

  // Wait for agent response
  await expect(assistantText(page, "done")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // Suggestions should appear asynchronously (from suggestion subprocess)
  const suggestions = page.locator(".btn-suggestion");
  await expect(suggestions.first()).toBeVisible({ timeout: 30_000 });

  // Should have 1-3 suggestions
  const count = await suggestions.count();
  expect(count).toBeGreaterThan(0);
  expect(count).toBeLessThanOrEqual(3);
});

test("suggestions disappear when user types", async ({ page, agentType }) => {
  await enterSession(page);
  await sendMessage(page, 'Please reply with "done"');

  await expect(assistantText(page, "done")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // Wait for suggestions
  const suggestions = page.locator(".btn-suggestion");
  await expect(suggestions.first()).toBeVisible({ timeout: 30_000 });

  // Type in input — suggestions should hide
  const input = page.locator(".input-textarea:visible").first();
  await input.fill("typing something");
  await expect(suggestions.first()).not.toBeVisible();

  // Clear input — suggestions reappear
  await input.fill("");
  await expect(suggestions.first()).toBeVisible({ timeout: 5_000 });
});

test("clicking suggestion sends it immediately", async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  await sendMessage(page, 'Please reply with "done"');

  await expect(assistantText(page, "done")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // Wait for suggestions and get first button text
  const suggBtn = page.locator(".btn-suggestion").first();
  await expect(suggBtn).toBeVisible({ timeout: 30_000 });
  const suggText = await suggBtn.innerText();

  // Click sends immediately
  await suggBtn.click();

  // Suggestions should be gone immediately after click (isProcessing = true clears them).
  // Check before any network round-trips so we see the state right after the click handler ran.
  await expect(page.locator(".btn-suggestion").first()).not.toBeVisible();

  // Should appear as a user message
  await expect(
    page.locator(".message.user-message", { hasText: suggText }),
  ).toBeVisible({ timeout: 15_000 });

  // Input should be empty
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toHaveValue("");
});

test("shift+click suggestion pre-fills input without sending", async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  await sendMessage(page, 'Please reply with "done"');

  await expect(assistantText(page, "done")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  const suggBtn = page.locator(".btn-suggestion").first();
  await expect(suggBtn).toBeVisible({ timeout: 30_000 });
  const suggText = await suggBtn.innerText();

  // Shift+click to pre-fill
  await suggBtn.click({ modifiers: ["Shift"] });

  // Should fill input with suggestion text, not send
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toHaveValue(suggText, { timeout: 5_000 });

  // Only the original user message should exist (no new one sent)
  const userMsgCount = await page.locator(".message.user-message").count();
  expect(userMsgCount).toBe(1);

  // Suggestions hidden because input now has text
  await expect(page.locator(".btn-suggestion").first()).not.toBeVisible();
});
