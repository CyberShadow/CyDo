import { test, expect, enterSession, sendMessage, killSession, responseTimeout } from "./fixtures";

async function snapshotTids(page: Parameters<typeof sendMessage>[0]): Promise<Set<string>> {
  const tids = await page
    .locator(".sidebar-item[data-tid]")
    .evaluateAll((els: Element[]) =>
      els.map((el) => el.getAttribute("data-tid")!),
    );
  return new Set(tids);
}

async function waitForNewTid(
  page: Parameters<typeof sendMessage>[0],
  before: Set<string>,
): Promise<string> {
  let newTid: string | undefined;
  await expect(async () => {
    const tids = await page
      .locator(".sidebar-item[data-tid]")
      .evaluateAll((els: Element[]) =>
        els.map((el) => el.getAttribute("data-tid")!),
      );
    newTid = tids.find((tid: string) => !before.has(tid));
    expect(newTid).toBeTruthy();
  }).toPass({ timeout: 15_000 });
  return newTid!;
}

async function resumeIfNeeded(page: Parameters<typeof sendMessage>[0]) {
  const resumeBtn = page.locator(".btn-resume:visible").first();
  const visible = await resumeBtn.isVisible({ timeout: 5_000 }).catch(() => false);
  if (visible) {
    await resumeBtn.click();
  }
}

function activeAssistantText(page: Parameters<typeof sendMessage>[0], text: string) {
  return page
    .locator("[style*='display: contents'] .message.assistant-message .text-content", {
      hasText: text,
    })
    .last();
}

test("codex fork from older turn truncates later history and isolates branches", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "codex", "codex-only regression");

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

  const turnOne = "FORK_OLD_TURN_ONE";
  const turnTwo = "FORK_OLD_TURN_TWO";
  const forkOnly = "FORK_CHILD_ONLY";
  const parentOnly = "FORK_PARENT_ONLY";

  await enterSession(page);
  const before = await snapshotTids(page);

  await sendMessage(page, `Reply exactly with ${turnOne}`);
  const parentTid = Number(await waitForNewTid(page, before));
  expect(parentTid).toBeGreaterThan(0);
  await expect(activeAssistantText(page, turnOne)).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  await sendMessage(page, `Reply exactly with ${turnTwo}`);
  await expect(activeAssistantText(page, turnTwo)).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  await killSession(page, agentType);
  await page.reload();
  await expect(activeAssistantText(page, turnTwo)).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  await expect(async () => {
    const turnOneAssistant = page
      .locator("[style*='display: contents'] .message-wrapper", {
        has: page.locator(".assistant-message", { hasText: turnOne }),
      })
      .last();
    await turnOneAssistant.hover();
    await expect(turnOneAssistant.locator(".fork-btn")).toBeVisible({
      timeout: 5_000,
    });
  }).toPass({ timeout: 20_000 });

  await page
    .locator("[style*='display: contents'] .message-wrapper", {
      has: page.locator(".assistant-message", { hasText: turnOne }),
    })
    .last()
    .locator(".fork-btn")
    .click();

  await expect(async () => {
    const fork = taskCreatedEvents.find(
      (event) => event.relation_type === "fork" && event.parent_tid === parentTid,
    );
    expect(fork).toBeTruthy();
  }).toPass({ timeout: 20_000 });

  const forkTid = taskCreatedEvents.find(
    (event) => event.relation_type === "fork" && event.parent_tid === parentTid,
  )!.tid;

  await expect(async () => {
    if (!page.url().endsWith(`/task/${forkTid}`)) {
      await page.locator(`.sidebar-item[data-tid="${forkTid}"]`).click();
    }
    await expect(page).toHaveURL(new RegExp(`/task/${forkTid}$`), {
      timeout: 5_000,
    });
  }).toPass({ timeout: 20_000 });

  await expect(activeAssistantText(page, turnOne)).toBeVisible({ timeout: 15_000 });
  await expect(
    page.locator("[style*='display: contents'] .message.assistant-message .text-content", {
      hasText: turnTwo,
    }),
  ).toHaveCount(0);

  await resumeIfNeeded(page);
  await sendMessage(page, `Reply exactly with ${forkOnly}`);
  await expect(activeAssistantText(page, forkOnly)).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  await page.locator(`.sidebar-item[data-tid="${parentTid}"]`).click();
  await expect(page).toHaveURL(new RegExp(`/task/${parentTid}$`), {
    timeout: 15_000,
  });

  await resumeIfNeeded(page);
  await sendMessage(page, `Reply exactly with ${parentOnly}`);
  await expect(activeAssistantText(page, parentOnly)).toBeVisible({
    timeout: responseTimeout(agentType),
  });
  await expect(
    page.locator("[style*='display: contents'] .message.assistant-message .text-content", {
      hasText: forkOnly,
    }),
  ).toHaveCount(0);

  await page.locator(`.sidebar-item[data-tid="${forkTid}"]`).click();
  await expect(page).toHaveURL(new RegExp(`/task/${forkTid}$`), {
    timeout: 15_000,
  });
  await expect(activeAssistantText(page, forkOnly)).toBeVisible({ timeout: 15_000 });
  await expect(
    page.locator("[style*='display: contents'] .message.assistant-message .text-content", {
      hasText: parentOnly,
    }),
  ).toHaveCount(0);
  await expect(
    page.locator("[style*='display: contents'] .message.assistant-message .text-content", {
      hasText: turnTwo,
    }),
  ).toHaveCount(0);
});
