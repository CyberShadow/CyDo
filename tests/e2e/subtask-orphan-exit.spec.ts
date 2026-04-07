import { test, expect, enterSession, sendMessage } from "./fixtures";

test("subtask with orphaned background command exits cleanly", async ({ page, agentType }) => {
  test.skip(agentType !== "claude", "claude-only: Bash tool backgrounding behavior");
  test.setTimeout(90_000);

  await enterSession(page);

  // Create a parent task that spawns a subtask. The subtask runs `sleep 999`
  // with a 2s timeout — Claude CLI will background the sleep after the timeout,
  // emit the tool result, but then hang because it waits for `sleep 999` to exit.
  await sendMessage(page, "call task research run command with timeout 2000 sleep 999");

  // If the bug is fixed, the subtask result would appear in the parent's message
  // list within a reasonable time. With the bug, this times out because the
  // subtask's Claude CLI process never exits.
  // .cydo-task-spec is rendered for each item in a Task tool result — it only
  // appears in the parent's view (not the subtask's), confirming the result was
  // delivered and the browser switched back to the parent.
  await expect(
    page.locator('[style*="display: contents"] .message-list .cydo-task-spec').last(),
  ).toBeVisible({ timeout: 60_000 });
});

test("subtask result is completed (not failed) when process is killed after result event", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "claude", "claude-only: Bash tool backgrounding behavior");
  test.setTimeout(90_000);

  await enterSession(page);

  // Same scenario: subtask with an orphaned sleep. The result event fires while
  // `sleep 999` is still running; the backend delivers the result immediately and
  // schedules a SIGTERM after 5s. Without the status guard in onExit, that kill
  // would cause onExit to mark the task "failed" even though it already succeeded.
  await sendMessage(page, "call task research run command with timeout 2000 sleep 999");

  // Wait for the result to be delivered to the parent.
  // .cydo-task-spec renders only for Task tool result items in the parent view.
  await expect(
    page.locator('[style*="display: contents"] .message-list .cydo-task-spec').last(),
  ).toBeVisible({ timeout: 60_000 });

  // After result delivery, the subtask process is killed (SIGTERM after 5s).
  // Wait for the child sidebar item to leave the "processing" state.
  const childItem = page
    .locator(".sidebar-item:not(.active):not(.sidebar-new-task)")
    .first();
  await expect(childItem.locator(".task-type-icon.processing")).not.toBeVisible({
    timeout: 15_000,
  });

  // The subtask must end up as "completed", not "failed".
  await expect(childItem.locator(".task-type-icon.failed")).not.toBeVisible();
});
