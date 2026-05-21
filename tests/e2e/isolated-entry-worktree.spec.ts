import { existsSync, rmSync } from "fs";
import {
  test,
  expect,
  enterSession,
  sendMessage,
  assistantText,
  responseTimeout,
} from "./fixtures";

test("isolated Copilot Bash runs inside its task worktree", { tag: "@copilot-only" }, async ({
  page,
  backend,
  agentType,
}) => {
  const timeout = responseTimeout(agentType);
  const markerName = `cydo-isolated-entry-marker-${Date.now()}.txt`;
  const mainCheckoutMarker = `${backend.wsDir}/${markerName}`;
  const backendCwdMarker = `/tmp/cydo-backend/${markerName}`;
  const taskUpdatedEvents: Array<{
    tid: number;
    task_type?: string;
    entry_point?: string;
  }> = [];

  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        const data = JSON.parse(event.payload.toString());
        if (data.type === "task_updated" && data.task) {
          taskUpdatedEvents.push({
            tid: data.task.tid,
            task_type: data.task.task_type,
            entry_point: data.task.entry_point,
          });
        }
      } catch {
        /* ignore non-JSON frames */
      }
    });
  });

  rmSync(mainCheckoutMarker, { force: true });
  rmSync(backendCwdMarker, { force: true });

  await enterSession(page);
  await page.locator(".task-type-row", { hasText: "isolated" }).click();

  await sendMessage(
    page,
    `run command sh -lc 'printf isolated-entry-worktree > ${markerName} && pwd'`,
  );

  const bashToolCall = page
    .locator(".tool-call")
    .filter({ has: page.locator(".tool-name", { hasText: "Bash" }) })
    .last();
  await expect(bashToolCall).toBeVisible({ timeout });
  await expect(bashToolCall).toContainText(markerName, { timeout });

  await expect(async () => {
    const isolatedTask = taskUpdatedEvents.find(
      (e) => e.entry_point === "isolated" || e.task_type === "isolated",
    );
    expect(isolatedTask).toBeTruthy();
  }).toPass({ timeout: 15_000 });

  const tid = taskUpdatedEvents.find(
    (e) => e.entry_point === "isolated" || e.task_type === "isolated",
  )!.tid;
  const worktreeDir = `${backend.wsDir}/.cydo/tasks/${tid}/worktree`;
  const worktreeMarker = `${worktreeDir}/${markerName}`;

  await expect(assistantText(page, "Done.")).toBeVisible({
    timeout,
  });

  await expect
    .poll(() => existsSync(worktreeDir), {
      timeout: 30_000,
    })
    .toBe(true);

  const bashResultHeader = bashToolCall.locator(".tool-result-header");
  const bashResultContainer = bashToolCall.locator(".tool-result-container");
  const bashResult = bashToolCall.locator(".tool-result");
  await expect(async () => {
    if (
      (await bashResultHeader.isVisible()) &&
      !(await bashResultContainer.isVisible())
    ) {
      await bashResultHeader.click();
    }
    await expect(bashResult).toContainText(worktreeDir);
  }).toPass({ timeout });

  expect(
    existsSync(backendCwdMarker),
    `isolated task wrote marker in backend cwd instead of task worktree: ${backendCwdMarker}`,
  ).toBe(false);
  expect(
    existsSync(mainCheckoutMarker),
    `isolated task wrote marker in main checkout: ${mainCheckoutMarker}`,
  ).toBe(false);
  expect(
    existsSync(worktreeMarker),
    `isolated task should write marker in task worktree: ${worktreeMarker}`,
  ).toBe(true);
});
