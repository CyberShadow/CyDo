/**
 * Reproducer for duplicate sub-task result delivery in Codex sessions.
 *
 * Bug: When a Codex sub-task completes, the result is delivered twice:
 *   1. Correctly via the MCP tool result (pending promise fulfillment)
 *   2. Spuriously via deliverBatchResults() which sends a "[SYSTEM: Sub-task
 *      results] ... A Task batch completed" user message
 *
 * Root cause: closeStdin() on Codex sessions synchronously fires exitHandler_(0),
 * which triggers onExit before onToolCallDelivered cleans up taskDeps. The onExit
 * handler sees the child still in taskDeps and takes the batch delivery path.
 *
 * This test sends a simple sub-task prompt and asserts that the spurious
 * "A Task batch completed" message does NOT appear in the parent's message list.
 */
import { test, expect, enterSession, sendMessage } from "./fixtures";

test("codex sub-task result should not be delivered twice", { tag: "@codex-only" }, async ({
  page,
}) => {
  await enterSession(page);

  // Create a sub-task that replies with a known marker.
  await sendMessage(page, 'call task research reply with "unique-subtask-marker"');

  // Wait for the sub-task result to appear in the parent's message list.
  // This confirms the normal delivery path works.
  const messageList = page.locator('[style*="display: contents"] .message-list');
  await expect(
    messageList.getByText("unique-subtask-marker").last(),
  ).toBeVisible();

  // Now check for the spurious duplicate: the batch delivery path sends a
  // message containing "A Task batch completed". This should NOT appear.
  // Wait a few seconds to give the duplicate a chance to arrive.
  await page.waitForTimeout(3_000);

  const batchMessages = messageList.getByText("A Task batch completed. Its results are below.");
  const count = await batchMessages.count();
  expect(
    count,
    'Spurious "A Task batch completed" message found — sub-task result was delivered twice',
  ).toBe(0);
});
