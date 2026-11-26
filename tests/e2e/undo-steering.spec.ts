import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
  openUndoMenu,
  chooseUndo,
} from "./fixtures";

test("undo removes preceding queue-operation lines from steering message", { tag: "@no-codex" }, async ({ page, agentType }) => {

  await enterSession(page);

  // 1. Send a message that triggers a long-running command (sleep 5).
  //    This keeps the agent busy so we can send a steering message.
  await sendMessage(page, "run command sleep 5");
  await expect(
    page.locator(".tool-call", { hasText: "sleep 5" }),
  ).toBeVisible();

  // 2. While the agent is busy, send a steering message.
  //    This creates queue-operation enqueue/dequeue in the JSONL.
  await sendMessage(page, 'reply with "steered-reply"');

  // 3. Wait for the steering message to be confirmed (non-pending user echo visible).
  //    This happens after queue-operation dequeue — the tool finished and Claude
  //    dequeued the steering message into the JSONL as a confirmed type:"user" line.
	await expect(
		page.locator(".message.user-message:not(.pending)", { hasText: "steered-reply" }),
	).toBeVisible();

  // 4. Kill the session so we can undo.
  await killSession(page, agentType);

  // 4b. Wait for canonical history_boundary replacements and history_operations
  //     to make the steering message visible as confirmed before hovering for
  //     the undo button.
  await expect(
    page.locator(".message.user-message:not(.pending)", { hasText: "steered-reply" }),
  ).toBeVisible();

  // 5. Find the confirmed user message for the steering message and undo it.
  const steerUserMsg = page
    .locator(".message-wrapper", {
      has: page.locator(".user-message", { hasText: "steered-reply" }),
    })
    .last();
  await openUndoMenu(steerUserMsg);

  // 6. Confirm undo.
  await chooseUndo(page, "Undo conversation");

  // 7. Wait for reload to complete — the input box should appear.
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeVisible();

  // 8. BUG ASSERTION: After undo, there should be NO pending user message
  //    from the steering. The queue-operation enqueue should have been removed.
  await expect(
    page.locator(".message.user-message.pending"),
  ).not.toBeVisible();

  // The steered message's confirmed echo should also be gone.
  await expect(
    page.locator(".message.user-message:not(.pending)", { hasText: "steered-reply" }),
  ).not.toBeVisible();
});
