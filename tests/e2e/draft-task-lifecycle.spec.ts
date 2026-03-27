import { test, expect, enterSession, sendMessage, responseTimeout } from "./fixtures";

test("task created on first keystroke, deleted on blanking", async ({ page }) => {
  await enterSession(page);

  // Count initial sidebar items (excluding the "New Task" row)
  const sidebarItems = page.locator(".sidebar-item:not(.sidebar-new-task)");
  const initialCount = await sidebarItems.count();

  // Type a character to trigger draft task creation
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill("x");

  // Wait for draft task to appear in sidebar
  await expect(sidebarItems).toHaveCount(initialCount + 1, { timeout: 5_000 });

  // Assert the new sidebar item has draft styling
  const draftLabels = page.locator(".sidebar-item .draft-label");
  await expect(draftLabels.last()).toBeVisible({ timeout: 2_000 });

  // Clear the text to trigger draft deletion
  await input.fill("");

  // Wait for sidebar item count to return to initial value
  await expect(sidebarItems).toHaveCount(initialCount, { timeout: 5_000 });
});

test("draft task becomes active on send", async ({ page, agentType }) => {
  await enterSession(page);

  const draftLabels = page.locator(".sidebar-item .draft-label");
  const initialDraftCount = await draftLabels.count();

  // Type text to create draft task
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill("Please reply with \"draft-active-test\"");

  // Wait for draft to appear in sidebar
  await expect(draftLabels).toHaveCount(initialDraftCount + 1, { timeout: 5_000 });

  // Send the message
  await page.locator(".btn-send:visible").first().click();

  // Assert URL changed to /task/:tid pattern
  await expect(page).toHaveURL(/\/task\/\d+/, { timeout: 5_000 });

  // Assert agent response arrives
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "draft-active-test" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  // Assert sidebar item no longer has draft styling
  await expect(draftLabels).toHaveCount(initialDraftCount, { timeout: 5_000 });
});

test("no remount during draft creation", async ({ page, agentType }) => {
  await enterSession(page);

  const draftLabels = page.locator(".sidebar-item .draft-label");
  const initialDraftCount = await draftLabels.count();

  const input = page.locator(".input-textarea:visible").first();
  await input.click();

  // Type character by character
  await input.pressSequentially("hello world", { delay: 100 });

  // The draft should have been created mid-typing without losing focus
  await expect(input).toBeFocused();
  await expect(input).toHaveValue("hello world");

  // Draft should be in sidebar
  await expect(draftLabels).toHaveCount(initialDraftCount + 1, { timeout: 5_000 });

  // Send and verify all characters came through
  await page.locator(".btn-send:visible").first().click();
  await expect(
    page.locator(".message.user-message", { hasText: "hello world" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
});

test("multiple draft create-delete cycles", async ({ page }) => {
  await enterSession(page);

  const input = page.locator(".input-textarea:visible").first();
  const sidebarItems = page.locator(".sidebar-item:not(.sidebar-new-task)");
  const initialCount = await sidebarItems.count();

  // Cycle 1: type → draft created
  await input.click();
  await input.fill("first draft");
  await expect(sidebarItems).toHaveCount(initialCount + 1, { timeout: 5_000 });

  // Note the first draft's label text (use .last() in case pre-existing drafts exist)
  const firstDraftText = await page.locator(".sidebar-item .draft-label").last().textContent();

  // Clear → draft deleted
  await input.fill("");
  await expect(sidebarItems).toHaveCount(initialCount, { timeout: 5_000 });

  // Cycle 2: type new text → new draft created (different tid)
  await input.fill("second draft");
  await expect(sidebarItems).toHaveCount(initialCount + 1, { timeout: 5_000 });

  const secondDraftText = await page.locator(".sidebar-item .draft-label").last().textContent();

  // The two drafts should have different task IDs (shown as "Task N")
  expect(secondDraftText).not.toBe(firstDraftText);

  // Clean up: delete the second draft so it doesn't leak into other tests
  // sharing this worker.
  await input.fill("");
  await expect(sidebarItems).toHaveCount(initialCount, { timeout: 5_000 });
});

test("fast type and send before task_created", async ({ page, agentType }) => {
  await enterSession(page);

  const draftLabels = page.locator(".sidebar-item .draft-label");
  const initialDraftCount = await draftLabels.count();

  const input = page.locator(".input-textarea:visible").first();
  await input.click();

  // Type and immediately send (no delay for task_created)
  await input.fill("Please reply with \"fast-send-test\"");
  await input.press("Enter");

  // Assert agent response arrives (the atomic create+send path handled it)
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "fast-send-test" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  // Assert no zombie draft tasks remain — draft count should not have
  // increased (the sent task becomes active, not a lingering draft).
  await expect(draftLabels).toHaveCount(initialDraftCount, { timeout: 2_000 });
});

test("draft task visible to second client", async ({ page, browser }) => {
  await enterSession(page);

  // Count pre-existing drafts (workers may share backends with other tests)
  const draftLabels1 = page.locator(".sidebar-item .draft-label");
  const initialDraftCount = await draftLabels1.count();

  // Client 1: type text (creates draft)
  const input1 = page.locator(".input-textarea:visible").first();
  await input1.click();
  await input1.fill("visible to others");

  // Wait for new draft to appear in sidebar
  await expect(draftLabels1).toHaveCount(initialDraftCount + 1, { timeout: 5_000 });

  // Open second page (client 2)
  const context2 = await browser.newContext();
  const page2 = await context2.newPage();
  await page2.goto(page.url());

  // Client 2 should see the same draft count (including our new one)
  const draftLabels2 = page2.locator(".sidebar-item .draft-label");
  await expect(draftLabels2).toHaveCount(initialDraftCount + 1, { timeout: 10_000 });

  // Client 1: clear text (deletes draft)
  await input1.fill("");

  // Client 2's draft count should drop back to the pre-existing level
  await expect(draftLabels2).toHaveCount(initialDraftCount, { timeout: 5_000 });

  await context2.close();
});

test("draft persists across page reload", async ({ page }) => {
  await enterSession(page);

  const draftLabels = page.locator(".sidebar-item .draft-label");
  const initialDraftCount = await draftLabels.count();

  // Type text to create draft task
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill("reload test draft");

  // Wait for draft to appear in sidebar and debounce to save
  await expect(draftLabels).toHaveCount(initialDraftCount + 1, { timeout: 5_000 });
  await page.waitForTimeout(1000); // wait for debounce

  // Reload the page
  await page.reload();

  // Assert the draft task appears in the sidebar (use .last() since
  // pre-existing drafts from other tests sharing this worker may exist)
  const reloadedDraftLabels = page.locator(".sidebar-item .draft-label");
  await expect(reloadedDraftLabels).toHaveCount(initialDraftCount + 1, { timeout: 15_000 });

  // Click the last draft label (ours, the most recently created)
  await reloadedDraftLabels.last().click();
  const restoredInput = page.locator(".input-textarea:visible").first();
  await expect(restoredInput).toBeVisible({ timeout: 5_000 });
  await expect(restoredInput).toHaveValue("reload test draft", { timeout: 5_000 });
});
