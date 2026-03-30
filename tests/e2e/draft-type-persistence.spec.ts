import { test, expect, enterSession, responseTimeout } from "./fixtures";
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

test("sidebar icon updates when entry point changed on draft", async ({
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

  // Change entry point to "blank" via the picker
  await page.locator(".task-type-row", { hasText: "blank" }).click();
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");

  // BUG: sidebar icon should update to "blank" but stays as "conversation"
  // because the selected entry point was not being persisted on the draft task
  await expect(
    page.locator(
      `.sidebar-item[data-tid="${draftTid}"] .task-type-icon-blank`,
    ),
  ).toBeVisible({ timeout: 3_000 });
});

test("entry point persists across page reload on draft", async ({ page }) => {
  await enterSession(page);

  const before = await snapshotTids(page);

  // Type something to create a draft task
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill("entry point reload test");

  // Wait for draft to appear in sidebar
  const draftTid = await waitForNewTid(page, before);
  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"] .draft-label`),
  ).toBeVisible({ timeout: 2_000 });

  // Change entry point to "blank"
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

  // Wait for the entry-point picker to be visible
  await expect(page.locator(".task-type-picker")).toBeVisible({
    timeout: 5_000,
  });

  // BUG: entry point should still be "blank" but reverts to default "agentic"
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");
});

test("sending from isolated draft applies the isolated entry-point prompt", async ({
  page,
  agentType,
}) => {
  await enterSession(page);

  await page.locator(".task-type-row", { hasText: "isolated" }).click();
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("isolated");

  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill("isolated draft echo test");
  await page.locator(".btn-send:visible").first().click();

  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "hands-on coding assistant working in an isolated worktree",
    }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "isolated draft echo test",
    }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
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
