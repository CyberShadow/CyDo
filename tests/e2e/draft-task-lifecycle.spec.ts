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

test("task created on first keystroke, deleted on blanking", async ({
  page,
}) => {
  await enterSession(page);

  const before = await snapshotTids(page);

  // Type a character to trigger draft task creation
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill("x");

  // Wait for a new draft sidebar item to appear
  const draftTid = await waitForNewTid(page, before);

  // Assert the new sidebar item has draft styling
  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"] .draft-label`),
  ).toBeVisible({ timeout: 2_000 });

  // Clear the text to trigger draft deletion
  await input.fill("");

  // Wait for that specific sidebar item to disappear
  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"]`),
  ).not.toBeAttached({
    timeout: 5_000,
  });
});

test("draft task becomes active on send", async ({ page, agentType }) => {
  await enterSession(page);

  const before = await snapshotTids(page);

  // Type text to create draft task
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill('Please reply with "draft-active-test"');

  // Wait for draft to appear in sidebar
  const draftTid = await waitForNewTid(page, before);

  // Send the message
  await page.locator(".btn-send:visible").first().click();

  // Assert URL changed to /task/:tid pattern
  await expect(page).toHaveURL(/\/task\/\d+/, { timeout: 5_000 });

  // Assert agent response arrives
  await expect(assistantText(page, "draft-active-test")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // Assert sidebar item no longer has draft styling
  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"] .draft-label`),
  ).not.toBeAttached({ timeout: 5_000 });
});

test("no remount during draft creation", async ({ page, agentType }) => {
  await enterSession(page);

  const before = await snapshotTids(page);

  const input = page.locator(".input-textarea:visible").first();
  await input.click();

  // Type character by character
  await input.pressSequentially("hello world", { delay: 100 });

  // The draft should have been created mid-typing without losing focus
  await expect(input).toBeFocused();
  await expect(input).toHaveValue("hello world");

  // Draft should be in sidebar
  const draftTid = await waitForNewTid(page, before);
  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"] .draft-label`),
  ).toBeVisible({ timeout: 5_000 });

  // Send and verify all characters came through
  await page.locator(".btn-send:visible").first().click();
  await expect(
    page.locator(".message.user-message", { hasText: "hello world" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
});

test("multiple draft create-delete cycles", async ({ page }) => {
  await enterSession(page);

  const input = page.locator(".input-textarea:visible").first();
  await input.click();

  // Cycle 1: type → draft created
  const before1 = await snapshotTids(page);
  await input.fill("first draft");
  const tid1 = await waitForNewTid(page, before1);

  // Clear → draft deleted
  await input.fill("");
  await expect(
    page.locator(`.sidebar-item[data-tid="${tid1}"]`),
  ).not.toBeAttached({
    timeout: 5_000,
  });

  // Cycle 2: type new text → new draft created (different tid)
  const before2 = await snapshotTids(page);
  await input.fill("second draft");
  const tid2 = await waitForNewTid(page, before2);

  // The two drafts should have different task IDs
  expect(tid2).not.toBe(tid1);

  // Clean up: delete the second draft so it doesn't leak into other tests
  // sharing this worker.
  await input.fill("");
  await expect(
    page.locator(`.sidebar-item[data-tid="${tid2}"]`),
  ).not.toBeAttached({
    timeout: 5_000,
  });
});

test("fast type and send before task_created", async ({ page, agentType }) => {
  await enterSession(page);

  const before = await snapshotTids(page);

  const input = page.locator(".input-textarea:visible").first();
  await input.click();

  // Type and immediately send (no delay for task_created)
  await input.fill('Please reply with "fast-send-test"');
  await input.press("Enter");

  // Assert agent response arrives (the atomic create+send path handled it)
  await expect(assistantText(page, "fast-send-test")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // Assert no zombie draft tasks remain — any new sidebar items should not
  // have .draft-label (the sent task becomes active, not a lingering draft).
  const current = await snapshotTids(page);
  const newTids = [...current].filter((tid) => !before.has(tid));
  for (const tid of newTids) {
    await expect(
      page.locator(`.sidebar-item[data-tid="${tid}"] .draft-label`),
    ).not.toBeAttached({ timeout: 2_000 });
  }
});

test("draft task visible to second client", async ({ page, browser }) => {
  await enterSession(page);

  const before = await snapshotTids(page);

  // Client 1: type text (creates draft)
  const input1 = page.locator(".input-textarea:visible").first();
  await input1.click();
  await input1.fill("visible to others");

  // Wait for new draft to appear in client 1's sidebar
  const draftTid = await waitForNewTid(page, before);

  // Open second page (client 2)
  const context2 = await browser.newContext();
  const page2 = await context2.newPage();
  await page2.goto(page.url());

  // Client 2 should see the same draft item
  await expect(
    page2.locator(`.sidebar-item[data-tid="${draftTid}"]`),
  ).toBeAttached({
    timeout: 10_000,
  });

  // Client 1: clear text (deletes draft)
  await input1.fill("");

  // Client 2's draft item should disappear
  await expect(
    page2.locator(`.sidebar-item[data-tid="${draftTid}"]`),
  ).not.toBeAttached({
    timeout: 5_000,
  });

  await context2.close();
});

test("new task after draft clears form correctly", async ({ page }) => {
  await enterSession(page);

  const before = await snapshotTids(page);

  // Step 1: Type something to create a draft task
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill("draft navigation test");

  // Step 2: Wait for draft to appear in sidebar
  const draftTid = await waitForNewTid(page, before);
  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"] .draft-label`),
  ).toBeVisible({ timeout: 2_000 });

  // Step 3: Click 'New Task' in the sidebar
  await page.locator(".sidebar-new-task").click();

  // Bug 1: Should show welcome prompt, not 'Loading task…'
  await expect(page.locator(".session-loading")).not.toBeAttached({
    timeout: 5_000,
  });
  await expect(page.locator(".welcome-prompt:visible")).toBeVisible({
    timeout: 5_000,
  });

  // Bug 1: Input should be empty in the new task form
  const newInput = page.locator(".input-textarea:visible").first();
  await expect(newInput).toHaveValue("", { timeout: 5_000 });

  // Step 4: Click the draft task in sidebar to go back to it
  await page.locator(`.sidebar-item[data-tid="${draftTid}"]`).click();

  // Bug 2: Should show the task type picker (SessionConfig) on return
  await expect(page.locator(".welcome-prompt .task-type-picker")).toBeVisible({
    timeout: 5_000,
  });

  // Bug 3: Clear input text — draft should be deleted from sidebar
  const draftInput = page.locator(".input-textarea:visible").first();
  await expect(draftInput).toBeVisible({ timeout: 5_000 });
  await draftInput.fill("");

  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"]`),
  ).not.toBeAttached({
    timeout: 5_000,
  });
});

test("draft persists across page reload", async ({ page }) => {
  await enterSession(page);

  const before = await snapshotTids(page);

  // Type text to create draft task
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill("reload test draft");

  // Wait for draft to appear in sidebar and debounce to save
  const draftTid = await waitForNewTid(page, before);
  await page.waitForTimeout(1000); // wait for debounce

  // Reload the page
  await page.reload();

  // Assert that specific draft task appears in the sidebar after reload
  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"]`),
  ).toBeAttached({
    timeout: 15_000,
  });

  // Click it to navigate to the draft task
  await page.locator(`.sidebar-item[data-tid="${draftTid}"]`).click();
  const restoredInput = page.locator(".input-textarea:visible").first();
  await expect(restoredInput).toBeVisible({ timeout: 5_000 });
  await expect(restoredInput).toHaveValue("reload test draft", {
    timeout: 5_000,
  });
});

test("draft sidebar title survives page reload", async ({ page }) => {
  await enterSession(page);

  const before = await snapshotTids(page);

  // Type text to create draft task
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill("my important draft title");

  // Wait for draft to appear in sidebar
  const draftTid = await waitForNewTid(page, before);

  // Verify sidebar shows draft text as title (before reload)
  const sidebarLabel = page.locator(
    `.sidebar-item[data-tid="${draftTid}"] .sidebar-label`,
  );
  await expect(sidebarLabel).toHaveText("my important draft title", {
    timeout: 5_000,
  });

  // Wait for debounce to persist draft to backend
  await page.waitForTimeout(1000);

  // Navigate away so InputBox for this task is NOT mounted after reload
  await page.locator(".sidebar-new-task").click();
  await expect(page.locator(".welcome-prompt:visible")).toBeVisible({
    timeout: 5_000,
  });

  // Reload the page
  await page.reload();

  // Wait for the draft task to reappear in sidebar after reload
  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"]`),
  ).toBeAttached({
    timeout: 15_000,
  });

  // Sidebar title should still show the draft text, not "Task NNN"
  const reloadedLabel = page.locator(
    `.sidebar-item[data-tid="${draftTid}"] .sidebar-label`,
  );
  await expect(reloadedLabel).toHaveText("my important draft title", {
    timeout: 5_000,
  });
});

test("draft deletable after page reload", async ({ page }) => {
  await enterSession(page);

  const before = await snapshotTids(page);

  // Type text to create draft task
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill("delete after reload");

  // Wait for draft to appear in sidebar and debounce to save
  const draftTid = await waitForNewTid(page, before);
  await page.waitForTimeout(1000); // wait for debounce

  // Reload the page
  await page.reload();

  // Wait for the draft task to reappear in sidebar after reload
  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"]`),
  ).toBeAttached({
    timeout: 15_000,
  });

  // Click the draft task in the sidebar to navigate to it
  await page.locator(`.sidebar-item[data-tid="${draftTid}"]`).click();
  const restoredInput = page.locator(".input-textarea:visible").first();
  await expect(restoredInput).toBeVisible({ timeout: 5_000 });
  await expect(restoredInput).toHaveValue("delete after reload", {
    timeout: 5_000,
  });

  // Wait for re-adopt to complete (task type picker visible = onContentEnd wired)
  await expect(page.locator(".welcome-prompt .task-type-picker")).toBeVisible({
    timeout: 5_000,
  });

  // Clear the text — this should trigger draft deletion
  await restoredInput.fill("");

  // Assert that the draft task is deleted from the sidebar
  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"]`),
  ).not.toBeAttached({
    timeout: 5_000,
  });
});
