import { test, expect, enterSession } from "./fixtures";
import type { Page } from "./fixtures";

async function snapshotTids(page: Page): Promise<Set<string>> {
  const tids = await page
    .locator(".sidebar-item[data-tid]")
    .evaluateAll((els: Element[]) =>
      els.map((el) => el.getAttribute("data-tid")!),
    );
  return new Set(tids);
}

async function waitForNewTid(
  page: Page,
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
  }).toPass({ timeout: 5_000 });
  return newTid!;
}

test("sidebar icon updates when task type changed on draft", async ({
  page,
}) => {
  await enterSession(page);

  const before = await snapshotTids(page);

  // Type something to create a draft task (default type is "conversation")
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill("sidebar icon test");

  // Wait for draft to appear in sidebar
  const draftTid = await waitForNewTid(page, before);
  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"] .draft-label`),
  ).toBeVisible({ timeout: 2_000 });

  // Default icon should be "conversation"
  await expect(
    page.locator(
      `.sidebar-item[data-tid="${draftTid}"] .task-type-icon-conversation`,
    ),
  ).toBeVisible({ timeout: 2_000 });

  // Change task type to "blank" via the picker
  await page.locator(".task-type-row", { hasText: "blank" }).click();
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");

  // BUG: sidebar icon should update to "blank" but stays as "conversation"
  // because the task type change is not sent to the backend until send()
  await expect(
    page.locator(
      `.sidebar-item[data-tid="${draftTid}"] .task-type-icon-blank`,
    ),
  ).toBeVisible({ timeout: 3_000 });
});

test("task type persists across page reload on draft", async ({ page }) => {
  await enterSession(page);

  const before = await snapshotTids(page);

  // Type something to create a draft task
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill("task type reload test");

  // Wait for draft to appear in sidebar
  const draftTid = await waitForNewTid(page, before);
  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"] .draft-label`),
  ).toBeVisible({ timeout: 2_000 });

  // Change task type to "blank"
  await page.locator(".task-type-row", { hasText: "blank" }).click();
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");

  // Wait for any debounce
  await page.waitForTimeout(1000);

  // Reload the page
  await page.reload();

  // Navigate to the draft task
  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"]`),
  ).toBeAttached({ timeout: 15_000 });
  await page.locator(`.sidebar-item[data-tid="${draftTid}"]`).click();

  // Wait for the task type picker to be visible
  await expect(page.locator(".task-type-picker")).toBeVisible({
    timeout: 5_000,
  });

  // BUG: task type should still be "blank" but reverts to default "conversation"
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");
});

test("agent type persists across page reload on draft", async ({
  page,
  agentType,
}) => {
  const targetAgent = agentType === "codex" ? "claude" : "codex";

  await enterSession(page);

  const before = await snapshotTids(page);

  // Type something to create a draft task
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill("agent type reload test");

  // Wait for draft to appear in sidebar
  const draftTid = await waitForNewTid(page, before);
  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"] .draft-label`),
  ).toBeVisible({ timeout: 2_000 });

  // Change the agent type
  await page.locator(".agent-picker").selectOption(targetAgent);
  await expect(page.locator(".agent-picker")).toHaveValue(targetAgent);

  // Wait for any debounce
  await page.waitForTimeout(1000);

  // Reload the page
  await page.reload();

  // Navigate to the draft task
  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"]`),
  ).toBeAttached({ timeout: 15_000 });
  await page.locator(`.sidebar-item[data-tid="${draftTid}"]`).click();

  // Wait for the agent picker to be visible
  await expect(page.locator(".agent-picker")).toBeVisible({
    timeout: 5_000,
  });

  // BUG: agent type should still be the changed value but reverts to default
  await expect(page.locator(".agent-picker")).toHaveValue(targetAgent);
});
