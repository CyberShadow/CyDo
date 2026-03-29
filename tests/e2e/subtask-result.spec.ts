import { test, expect, enterSession, sendMessage } from "./fixtures";

test("sub-task result text delivered to parent", async ({ page }) => {
  // Sub-task creation + completion requires more time than the default 60s budget.
  test.setTimeout(120_000);

  await enterSession(page);

  // The parent creates a sub-task that replies with a specific marker text.
  // When the sub-task completes, its result text should appear in the parent's
  // tool result display (or as assistant text if auto-navigated to sub-task).
  await sendMessage(page, 'call task research reply with "subtask-result-marker"');

  // Wait for the marker text to appear in the message list.
  // Scoped to .message-list to avoid matching the sidebar label which also
  // shows the same text. Use exact:true to avoid matching the user message.
  await expect(
    page.locator('.message-list').getByText("subtask-result-marker", { exact: true }),
  ).toBeVisible({ timeout: 90_000 });
});
