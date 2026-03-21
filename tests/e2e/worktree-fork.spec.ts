import { test, expect, enterSession, sendMessage, killSession } from "./fixtures";

test("forked worktree task history is accessible without restart", async ({ page, agentType }) => {
  test.skip(agentType === "codex", "codex does not use git worktrees");

  // 1. Enter a conversation session and create a spike subtask.
  //    The 'spike' type has worktree: true, so the backend creates a git worktree.
  await enterSession(page);
  await sendMessage(page, 'call task spike reply with "worktree-fork-content"');

  // 2. UI auto-navigates to the spike subtask. Wait for the mock API response.
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "worktree-fork-content",
    }),
  ).toBeVisible({ timeout: 60_000 });

  // 3. Kill the spike session so the JSONL is finalized.
  await killSession(page, agentType);

  // 4. Wait for history reload from JSONL (message still visible).
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "worktree-fork-content",
    }),
  ).toBeVisible({ timeout: 15_000 });

  // 5. Hover over the assistant message to reveal the fork button.
  const assistantWrapper = page
    .locator(".message-wrapper", {
      has: page.locator(".assistant-message", {
        hasText: "worktree-fork-content",
      }),
    })
    .last();
  await assistantWrapper.hover();
  const forkBtn = assistantWrapper.locator(".fork-btn");
  await expect(forkBtn).toBeVisible({ timeout: 10_000 });

  // 6. Fork the task.
  await forkBtn.click();

  // 7. The forked task appears in the sidebar.
  await expect(
    page.locator(".sidebar-item .sidebar-label", { hasText: / \(fork\)/i }),
  ).toBeVisible({ timeout: 15_000 });

  // 8. Navigate to the forked task.
  await page
    .locator(".sidebar-item .sidebar-label", { hasText: / \(fork\)/i })
    .click();

  // 9. KEY ASSERTION: the forked task must show history immediately,
  //    without a backend restart. This fails without the fix because
  //    the in-memory projectPath points to the original project path
  //    instead of the worktree path, so historyPath() looks in the
  //    wrong ~/.claude/projects/ directory.
  //    Scope to the active session container ([style*='display: contents'])
  //    to avoid strict-mode violations when both the spike session and the
  //    forked session are rendered in the DOM simultaneously.
  await expect(
    page.locator("[style*='display: contents'] .message.assistant-message .text-content", {
      hasText: "worktree-fork-content",
    }),
  ).toBeVisible({ timeout: 15_000 });
});
