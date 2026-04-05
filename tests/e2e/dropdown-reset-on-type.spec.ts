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

test("agent type dropdown not reset when typing first character", async ({
  page,
  agentType,
}) => {
  // Pick a non-default agent to verify the selection is preserved.
  const targetAgent = agentType === "codex" ? "claude" : "codex";

  await enterSession(page);

  // Agent picker should be visible in draft mode
  await expect(page.locator(".agent-picker")).toBeVisible({ timeout: 5_000 });

  const before = await snapshotTids(page);

  // Select a non-default agent type before typing
  await page.locator(".agent-picker").selectOption(targetAgent);
  await expect(page.locator(".agent-picker")).toHaveValue(targetAgent);

  // Type a character — this triggers onContentStart → createDraftTask
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill("x");

  // Wait for draft task to appear in sidebar (confirms backend task was created)
  await waitForNewTid(page, before);

  // The agent picker should still show the user's selection, not the backend default
  await expect(page.locator(".agent-picker")).toHaveValue(targetAgent);

  // Clean up
  await input.fill("");
});

test("task type dropdown not reset when typing then deleting", async ({
  page,
}) => {
  await enterSession(page);

  // Task type picker should be visible in draft mode
  await expect(page.locator(".task-type-picker")).toBeVisible({
    timeout: 5_000,
  });

  const before = await snapshotTids(page);

  // Select a non-default task type before typing
  await page.locator(".task-type-row", { hasText: "blank" }).click();
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");

  // Type a character — creates a draft task
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill("x");

  // Wait for draft to appear
  const draftTid = await waitForNewTid(page, before);
  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"] .draft-label`),
  ).toBeVisible({ timeout: 2_000 });

  // Delete the character — triggers deleteDraftTask
  await input.fill("");

  // Draft should be removed from sidebar
  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"]`),
  ).not.toBeAttached({ timeout: 5_000 });

  // Task type picker should still show "blank", not the default
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");
});
