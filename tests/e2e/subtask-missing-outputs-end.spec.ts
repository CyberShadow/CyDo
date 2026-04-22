import { test, expect, enterSession, sendMessage } from "./fixtures";

test("subtask auto-ends after satisfying missing-outputs retry", async ({ page, agentType }) => {
  test.skip(
    agentType !== "claude",
    "claude-only: reproduction uses isolated worktree subtask output enforcement",
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
  await sendMessage(page, 'call task test_wt_child reply with "missing-output-child"');

  await expect
    .poll(() => childTid, {
      message: "expected subtask to be created",
      timeout: 30_000,
    })
    .not.toBeNull();

  const parentItem = page.locator('.sidebar-item[data-tid="1"]');
  const subtaskItem = page.locator(`.sidebar-item[data-tid="${childTid}"]`);

  await parentItem.click();
  await expect(page.locator('.sidebar-item[data-tid="1"].active')).toBeVisible();
  await expect(
    page.locator('[style*="display: contents"] .message-list')
      .getByText("Done.", { exact: true })
      .last(),
  ).toBeVisible({ timeout: 60_000 });

  await subtaskItem.click();
  await expect(page.locator(`.sidebar-item[data-tid="${childTid}"].active`)).toBeVisible();

  await expect(
    page.locator('[style*="display: contents"] .message-list')
      .getByText("Missing required outputs")
      .last(),
  ).toBeVisible({ timeout: 60_000 });

  await expect(
    subtaskItem.locator(".task-type-icon.completed, .task-type-icon.resumable"),
  ).toBeVisible({ timeout: 30_000 });
  await expect(subtaskItem.locator(".task-type-icon.processing")).not.toBeVisible();
  await expect(subtaskItem.locator(".task-type-icon.alive")).not.toBeVisible();
  await expect(subtaskItem.locator(".task-type-icon.failed")).not.toBeVisible();
  await expect(page.locator(".btn-banner-stop")).not.toBeVisible();
});
