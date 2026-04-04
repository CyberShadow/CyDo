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
  // Scoped to the active task view ([style*="display: contents"]) to avoid
  // matching hidden tasks that share the same text. Codex can briefly render
  // both a streaming and finalized copy, so wait for the newest visible match.
  await expect(
    page.locator('[style*="display: contents"] .message-list')
      .getByText("subtask-result-marker", { exact: true })
      .last(),
  ).toBeVisible({ timeout: 90_000 });
});
