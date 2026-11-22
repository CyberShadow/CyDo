import { existsSync } from "node:fs";
import { test, expect, enterSession, sendMessage } from "./fixtures";

test("subtask auto-ends after satisfying missing-outputs retry", { tag: "@claude-only" }, async ({ page }) => {
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
    })
    .not.toBeNull();

  const parentItem = page.locator('.sidebar-item[data-tid="1"]');
  const subtaskItem = page.locator(`.sidebar-item[data-tid="${childTid}"]`);

  await parentItem.click();
  await expect(
    page.locator('.sidebar-item[data-tid="1"].active'),
  ).toBeVisible();
  await expect(
    page.locator('[style*="display: contents"] .message-list')
      .getByText("Done.", { exact: true })
      .last(),
  ).toBeVisible();

  await subtaskItem.click();
  await expect(page.locator(`.sidebar-item[data-tid="${childTid}"].active`)).toBeVisible();

  await expect(
    page.locator('[style*="display: contents"] .message-list')
      .getByText("Missing required outputs")
      .last(),
  ).toBeVisible();

  await expect(
    subtaskItem.locator(".task-type-icon.completed, .task-type-icon.resumable"),
  ).toBeVisible();
  await expect(subtaskItem.locator(".task-type-icon.processing")).not.toBeVisible();
  await expect(subtaskItem.locator(".task-type-icon.alive")).not.toBeVisible();
  await expect(subtaskItem.locator(".task-type-icon.failed")).not.toBeVisible();
  await expect(page.locator(".btn-banner-stop")).not.toBeVisible();
});

test("repro: manually ending a resumed completed subtask does not rerun output enforcement", { tag: "@claude-only" }, async ({
  backend,
  page,
}) => {
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
    "call task test_wt_child run command" +
      " mkdir -p /tmp/cydo-test-workspace/.cydo/tasks/2 &&" +
      " printf initial-report > /tmp/cydo-test-workspace/.cydo/tasks/2/output.md",
  );

  await expect
    .poll(() => childTid, {
      message: "expected subtask to be created",
    })
    .not.toBeNull();

  const parentItem = page.locator('.sidebar-item[data-tid="1"]');
  const subtaskItem = page.locator(`.sidebar-item[data-tid="${childTid}"]`);
  const subtaskView = page.locator(`div[data-tid="${childTid}"]`);
  const subtaskMessages = subtaskView.locator(".message-list");
  const resume = subtaskView.getByRole("button", { name: "Resume", exact: true });
  const end = subtaskView.getByRole("button", { name: "End", exact: true });
  const missingOutputs = subtaskMessages.getByText("Missing required outputs");
  const outputPath = `${backend.wsDir}/.cydo/tasks/${childTid}/output.md`;

  await parentItem.click();
  await expect(parentItem).toHaveClass(/\bactive\b/);
  await expect(
    page
      .locator('div[data-tid="1"] .message-list')
      .getByText("Done.", { exact: true })
      .last(),
  ).toBeVisible();

  await subtaskItem.click();
  await expect(subtaskItem).toHaveClass(/\bactive\b/);
  await expect(resume).toBeVisible();
  await expect(missingOutputs).toHaveCount(0);
  expect(existsSync(outputPath)).toBe(true);

  await resume.click();
  await expect(end).toBeVisible();

  const doneMessages = subtaskMessages.getByText("Done.", { exact: true });
  const doneCountBeforeRemoval = await doneMessages.count();
  await sendMessage(page, `run command rm -f ${outputPath}`);
  await expect
    .poll(() => doneMessages.count())
    .toBeGreaterThan(doneCountBeforeRemoval);
  await expect(resume).toBeVisible();
  await expect(subtaskItem).toHaveClass(/\bactive\b/);
  expect(existsSync(outputPath)).toBe(false);
  await expect(missingOutputs).toHaveCount(0);

  // The removal turn auto-ended the child. Resume it without sending a
  // message so the End button closes the child's session manually.
  await resume.click();
  await expect(end).toBeVisible();
  await expect(subtaskItem.locator(".task-type-icon.alive")).toBeVisible();
  await end.click();

  await expect(resume).toBeVisible();
  await expect(
    subtaskItem.locator(".task-type-icon.completed, .task-type-icon.resumable"),
  ).toBeVisible();
  await expect(subtaskItem.locator(".task-type-icon.processing")).not.toBeVisible();
  await expect(subtaskItem.locator(".task-type-icon.alive")).not.toBeVisible();
  await expect(subtaskItem.locator(".task-type-icon.failed")).not.toBeVisible();
  await expect(missingOutputs).toHaveCount(0);
  expect(existsSync(outputPath)).toBe(false);
  await expect(parentItem.locator(".task-type-icon.alive")).toBeVisible();
});
