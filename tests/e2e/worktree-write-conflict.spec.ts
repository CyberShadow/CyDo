import { test, expect, enterSession, sendMessage } from "./fixtures";

test(
  "Task tool rejects second non-read-only sibling on shared worktree",
  async ({ page, agentType }) => {
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
    // Since test_wt_child is not tree-read-only, the second should be
    // rejected by the write-conflict check.
    await enterSession(page);
    await page.locator(".task-type-row", { hasText: "isolated" }).click();
    await sendMessage(
      page,
      "call 2 tasks test_wt_child reply with hi",
    );

    // Wait for at least one child to be created, then verify only one was.
    await expect(async () => {
      const children = taskCreatedEvents.filter(
        (e) => e.relation_type === "subtask",
      );
      expect(children.length).toBeGreaterThanOrEqual(1);
    }).toPass({ timeout: 60_000 });

    // Give a brief window for the second child to appear (it shouldn't).
    await page.waitForTimeout(2_000);
    const children = taskCreatedEvents.filter(
      (e) => e.relation_type === "subtask",
    );
    expect(children).toHaveLength(1);
  },
);
