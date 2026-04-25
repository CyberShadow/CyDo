import {
  test,
  expect,
  enterSession,
  sendMessage,
  assistantText,
} from "./fixtures";

test("Task tool rejects batch with multiple non-read-only siblings on shared worktree", async ({
  page,
  agentType,
}) => {
  test.skip(agentType === "codex", "codex does not use git worktrees");

  const taskCreatedEvents: Array<{
    tid: number;
    parent_tid?: number;
    relation_type?: string;
  }> = [];

  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        const data = JSON.parse(event.payload.toString());
        if (data.type === "task_created") {
          taskCreatedEvents.push({
            tid: data.tid,
            parent_tid: data.parent_tid,
            relation_type: data.relation_type,
          });
        }
      } catch {
        /* ignore non-JSON frames */
      }
    });
  });

  // Enter an isolated session (worktree: require → gets its own worktree).
  // Send "call 2 tasks test_wt_child reply with hi" which the mock API
  // parses into a single mcp__cydo__Task call with 2 items in the array.
  // Both children use inherit edges, sharing the parent's worktree.
  // Since test_wt_child is not tree-read-only, the batch should be
  // rejected upfront by the write-conflict check before any tasks are created.
  await enterSession(page);
  await page.locator(".task-type-row", { hasText: "isolated" }).click();
  await sendMessage(page, "call 2 tasks test_wt_child reply with hi");

  // Wait for the parent task to respond (mock returns "Done." after tool_result),
  // confirming the Task call error was processed.
  await expect(assistantText(page, "Done.")).toBeVisible({ timeout: 60_000 });

  // The entire batch must have been rejected: no children created.
  const children = taskCreatedEvents.filter(
    (e) => e.relation_type === "subtask",
  );
  expect(children).toHaveLength(0);
});
