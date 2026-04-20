import { test, expect, enterSession, sendMessage } from "./fixtures";

test("parallel Task results have no null entries", async ({ page }) => {
  // Sub-task creation + completion for 2 children requires extra time.
  test.setTimeout(120_000);

  await enterSession(page);

  // Create 2 parallel sub-tasks that each reply with a known marker.
  // "call 2 tasks research reply with ..." creates a Task tool call with
  // 2 task specs, both of type "research" and prompt 'reply with "parallel-ok"'.
  await sendMessage(page, 'call 2 tasks research reply with "parallel-ok"');

  // Wait for both children to appear in the sidebar, then navigate back
  // to the parent to see the Task result with batch results.
  await page.locator('.sidebar-item[data-tid="3"]').waitFor({
    state: "visible",
    timeout: 30_000,
  });
  await page.locator('.sidebar-item[data-tid="1"]').click();
  await expect(
    page.locator('.sidebar-item[data-tid="1"].active'),
  ).toBeVisible({ timeout: 10_000 });

  const msgList = page.locator('[style*="display: contents"] .message-list');

  // Wait for the parent turn to complete. Copilot/Claude agents emit "Done." as
  // an assistant text response after processing the Task tool result.  Codex may
  // not emit any text (context compaction can end the turn silently), so we also
  // accept the first task spec appearing as an equivalent completion signal.
  const firstSpec = msgList.locator('.tool-result-container .cydo-task-spec').first();
  await expect(
    msgList.getByText("Done.", { exact: true }).or(firstSpec).first(),
  ).toBeVisible({ timeout: 90_000 });

  // Scope to the tool result container inside the Task tool call.
  // The .tool-result-container holds result items, while .cydo-task-spec also
  // appears in the input section. Scoping avoids double-counting.
  const resultSpecs = msgList.locator(
    '.tool-result-container .cydo-task-spec',
  );
  await expect(resultSpecs).toHaveCount(2, { timeout: 10_000 });

  // BUG CHECK: due to the D foreach closure capture bug in registerBatchAndAwait,
  // the first child's result slot stays as default McpResult (serializes as null).
  // The frontend renders null items as "result: null" fallback text.
  // Assert that each result item contains the actual task output "parallel-ok".
  for (let i = 0; i < 2; i++) {
    const spec = resultSpecs.nth(i);
    await expect(spec.getByText("parallel-ok")).toBeVisible({
      timeout: 5_000,
    });
  }
});
