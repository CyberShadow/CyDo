import { test, expect, enterSession, sendMessage } from "./fixtures";

test("codex alive-path undo: session stays alive after undo", async ({
  page,
  agentType,
}) => {
  test.skip(
    agentType !== "codex",
    "Codex-only: tests thread/rollback undo path",
  );
  // Known bug: Codex alive-path undo doesn't correctly truncate displayed
  // history — the thread/rollback RPC succeeds but the JSONL reload shows
  // extra messages from the undone turn.
  test.fixme(
    true,
    "Known bug: Codex alive-path undo doesn't correctly truncate displayed history",
  );

  await enterSession(page);

  await sendMessage(page, 'Please reply with "alive-one"');
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "alive-one",
    }),
  ).toBeVisible({ timeout: 90_000 });

  await sendMessage(page, 'Please reply with "alive-two"');
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "alive-two",
    }),
  ).toBeVisible({ timeout: 90_000 });

  // Session is idle but alive — do NOT kill it before undoing.
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled({ timeout: 15_000 });

  // Hover over the second user message to reveal the undo button.
  const secondUserMsg = page
    .locator(".message-wrapper", {
      has: page.locator(".user-message", { hasText: "alive-two" }),
    })
    .last();
  await secondUserMsg.hover();

  await expect(secondUserMsg.locator(".undo-btn")).toBeVisible({
    timeout: 5_000,
  });
  await secondUserMsg.locator(".undo-btn").click();

  await expect(page.locator(".undo-dialog")).toBeVisible({ timeout: 5_000 });
  await page.locator(".btn-undo").click();

  // After undo: exactly 1 confirmed user message remains.
  await expect(page.locator(".message.user-message:not(.pending)")).toHaveCount(
    1,
    { timeout: 15_000 },
  );

  // After undo: exactly 1 assistant message remains.
  await expect(page.locator(".message.assistant-message")).toHaveCount(1, {
    timeout: 15_000,
  });

  // alive-two is gone; alive-one remains.
  await expect(
    page.locator(".message.user-message", { hasText: "alive-two" }),
  ).not.toBeVisible();
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "alive-one",
    }),
  ).toBeVisible();

  // Session is still alive: input box is visible and enabled.
  await expect(page.locator(".input-textarea:visible").first()).toBeEnabled({
    timeout: 15_000,
  });

  // Send a follow-up message to confirm the session is fully functional.
  await sendMessage(page, 'Please reply with "alive-three"');
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "alive-three",
    }),
  ).toBeVisible({ timeout: 90_000 });
});
