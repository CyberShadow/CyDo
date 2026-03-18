import { test, expect, enterSession, sendMessage, killSession } from "./fixtures";

test("undo removes preceding queue-operation lines from steering message", async ({ page, agentType }) => {
  test.skip(agentType === "codex", "codex handles steering differently");

  await enterSession(page);

  // 1. Send a message that triggers a long-running command (sleep 5).
  //    This keeps the agent busy so we can send a steering message.
  await sendMessage(page, "run command sleep 5");
  await expect(
    page.locator(".tool-call", { hasText: "sleep 5" }),
  ).toBeVisible({ timeout: 30_000 });

  // 2. While the agent is busy, send a steering message.
  //    This creates queue-operation enqueue/dequeue in the JSONL.
  await sendMessage(page, 'reply with "steered-reply"');

  // 3. Wait for the steering message to be fully processed:
  //    the agent should eventually reply with "steered-reply".
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "steered-reply" }),
  ).toBeVisible({ timeout: 60_000 });

  // 4. Kill the session so we can undo.
  await killSession(page, agentType);

  // 5. Find the confirmed user message for the steering message and undo it.
  const steerUserMsg = page
    .locator(".message-wrapper", {
      has: page.locator(".user-message", { hasText: "steered-reply" }),
    })
    .last();
  await steerUserMsg.hover();
  await expect(steerUserMsg.locator(".undo-btn")).toBeVisible({ timeout: 5_000 });
  await steerUserMsg.locator(".undo-btn").click();

  // 6. Confirm undo.
  await expect(page.locator(".undo-dialog")).toBeVisible({ timeout: 5_000 });
  await page.locator(".btn-undo").click();

  // 7. Wait for reload to complete — the input box should appear.
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeVisible({ timeout: 15_000 });

  // 8. BUG ASSERTION: After undo, there should be NO pending user message
  //    from the steering. The queue-operation enqueue should have been removed.
  await expect(
    page.locator(".message.user-message.pending"),
  ).not.toBeVisible({ timeout: 10_000 });

  // The steered message's confirmed echo should also be gone.
  await expect(
    page.locator(".message.user-message:not(.pending)", { hasText: "steered-reply" }),
  ).not.toBeVisible({ timeout: 5_000 });
});
