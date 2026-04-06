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
  await expect(
    page.locator('[style*="display: contents"] .message-list .tool-result').last(),
  ).toBeVisible({ timeout: 60_000 });
});
