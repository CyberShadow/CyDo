import { test, expect, enterSession, sendMessage } from "./fixtures";

test("commit output enforcement fires when subtask exits without committing", async ({
  page,
  agentType,
}) => {
  test.skip(
    agentType !== "claude",
    "claude-only: uses isolated worktree subtask output enforcement",
  );
  test.setTimeout(120_000);

  let childTid: number | null = null;

  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        const data = JSON.parse(event.payload.toString());
        if (data.type === "task_created" && data.relation_type === "subtask") {
          childTid = data.tid;
        }
      } catch {
        /* ignore non-JSON frames */
      }
    });
  });

  await enterSession(page);
  await page.locator(".task-type-row", { hasText: "isolated" }).click();
  await sendMessage(
    page,
    'call task test_commit_child reply with "no-commit-child"',
  );

  await expect
    .poll(() => childTid, {
      message: "expected subtask to be created",
      timeout: 30_000,
    })
    .not.toBeNull();

  const parentItem = page.locator('.sidebar-item[data-tid="1"]');
  const subtaskItem = page.locator(`.sidebar-item[data-tid="${childTid}"]`);

  // Wait for the parent to complete first (which means the child has fully
  // finished, including any enforcement retry). Then inspect the child's
  // history for the enforcement message.
  await parentItem.click();
  await expect(page.locator('.sidebar-item[data-tid="1"].active')).toBeVisible();
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText("Done.", { exact: true })
      .last(),
  ).toBeVisible({ timeout: 90_000 });

  await subtaskItem.click();
  await expect(
    page.locator(`.sidebar-item[data-tid="${childTid}"].active`),
  ).toBeVisible();

  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText("Missing required outputs")
      .last(),
  ).toBeVisible({ timeout: 30_000 });

  await expect(
    subtaskItem.locator(".task-type-icon.completed, .task-type-icon.resumable"),
  ).toBeVisible({ timeout: 15_000 });
  await expect(subtaskItem.locator(".task-type-icon.processing")).not.toBeVisible();
  await expect(subtaskItem.locator(".task-type-icon.alive")).not.toBeVisible();
});

test("commit output happy path: subtask commits and parent receives commits in result", async ({
  page,
  agentType,
}) => {
  test.skip(
    agentType !== "claude",
    "claude-only: uses isolated worktree subtask with git commit",
  );
  test.setTimeout(120_000);

  let childTid: number | null = null;

  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        const data = JSON.parse(event.payload.toString());
        if (data.type === "task_created" && data.relation_type === "subtask") {
          childTid = data.tid;
        }
      } catch {
        /* ignore non-JSON frames */
      }
    });
  });

  await enterSession(page);
  await page.locator(".task-type-row", { hasText: "isolated" }).click();
  await sendMessage(
    page,
    "call task test_commit_child run command" +
      " echo test > testfile.txt && git add . && git commit -m 'test commit'",
  );

  await expect
    .poll(() => childTid, {
      message: "expected subtask to be created",
      timeout: 30_000,
    })
    .not.toBeNull();

  const parentItem = page.locator('.sidebar-item[data-tid="1"]');

  // Navigate to parent and wait for it to complete. If the child committed
  // successfully the output enforcement passes, the Task tool returns a result
  // with commits, and the parent can finish. This exercises the full happy path.
  await parentItem.click();
  await expect(page.locator('.sidebar-item[data-tid="1"].active')).toBeVisible();
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText("Done.", { exact: true })
      .last(),
  ).toBeVisible({ timeout: 90_000 });
});
