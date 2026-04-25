import {
  test,
  expect,
  enterSession,
  responseTimeout,
  assistantText,
} from "./fixtures";
import type { Page } from "./fixtures";

async function snapshotTids(page: Page): Promise<Set<string>> {
  const tids = await page
    .locator(".sidebar-item[data-tid]")
    .evaluateAll((els: Element[]) =>
      els.map((el) => el.getAttribute("data-tid")!),
    );
  return new Set(tids);
}

async function waitForNewTid(page: Page, before: Set<string>): Promise<string> {
  let newTid: string | undefined;
  await expect(async () => {
    const tids = await page
      .locator(".sidebar-item[data-tid]")
      .evaluateAll((els: Element[]) =>
        els.map((el) => el.getAttribute("data-tid")!),
      );
    newTid = tids.find((tid: string) => !before.has(tid));
    expect(newTid).toBeTruthy();
  }).toPass({ timeout: 5_000 });
  return newTid!;
}

test("changing entry point after draft creation updates backend", async ({
  page,
  agentType,
}) => {
  // Capture task_updated broadcasts to verify the derived backend task type
  const taskUpdatedEvents: Array<{
    tid: number;
    task_type: string;
  }> = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        const data = JSON.parse(event.payload.toString());
        if (data.type === "task_updated" && data.task) {
          taskUpdatedEvents.push({
            tid: data.task.tid,
            task_type: data.task.task_type,
          });
        }
      } catch {}
    });
  });

  await enterSession(page);

  // Entry-point picker should be visible in draft mode
  await expect(page.locator(".task-type-picker")).toBeVisible({
    timeout: 5_000,
  });

  const before = await snapshotTids(page);

  // Type something to create a draft task (with default "agentic" entry point)
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill('reply with "type-change-test"');

  // Wait for draft to appear in sidebar
  const draftTid = await waitForNewTid(page, before);
  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"] .draft-label`),
  ).toBeVisible({ timeout: 2_000 });

  // Click a different entry point ("blank")
  await page.locator(".task-type-row", { hasText: "blank" }).click();
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");

  // Send the message
  await page.locator(".btn-send:visible").first().click();

  // Wait for the agent response
  await expect(assistantText(page, "type-change-test")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // Verify the backend task has task_type "blank" (not the default conversation type)
  const tid = parseInt(draftTid);
  const finalUpdate = taskUpdatedEvents.filter((e) => e.tid === tid).pop();
  expect(finalUpdate).toBeTruthy();
  expect(finalUpdate!.task_type).toBe("blank");
});
