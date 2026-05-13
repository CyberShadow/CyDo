import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
} from "./fixtures";

test("copilot text before tool produces separate assistant messages without duplicate text", { tag: "@copilot-only" }, async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  await sendMessage(page, "copilot text before tool");

  const activeSession = page.locator("[style*='display: contents']");
  const assistantMessages = activeSession.locator(".message.assistant-message");
  const timeout = responseTimeout(agentType);

  await expect(
    activeSession
      .locator('[data-testid="assistant-text"]', {
        hasText: "Done.",
      })
      .first(),
  ).toBeVisible({ timeout });

  await expect(assistantMessages).toHaveCount(2, { timeout: 5_000 });
  await expect(
    assistantMessages.first().locator('[data-testid="assistant-text"]', {
      hasText: "pre-tool-visible-text",
    }),
  ).toHaveCount(1);
  await expect(
    assistantMessages.nth(1).locator('[data-testid="assistant-text"]', {
      hasText: "Done.",
    }),
  ).toHaveCount(1);
  await expect(
    activeSession.locator('[data-testid="assistant-text"]', {
      hasText: "Done.",
    }),
  ).toHaveCount(1);
});
