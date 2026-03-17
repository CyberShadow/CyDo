import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
  responseTimeout,
} from "./fixtures";
import type { Page, AgentType } from "./fixtures";

// Archive tests depend on sequenced task operations and share server state
// (archived tasks accumulate across tests). Serial mode ensures they run
// sequentially so count assertions and "archive disappears" checks are accurate.
test.describe.configure({ mode: "serial" });


/** Creates a task with a known sidebar title and kills it (leaves it inactive). */
async function createCompletedTask(
  page: Page,
  keyword: string,
  agentType: AgentType,
) {
  await enterSession(page);
  await sendMessage(page, `Please reply with "${keyword}"`);
  // Wait for the assistant response — confirms system/init was output and
  // agentSessionId is set, so killSession leaves a resumable task.
  await expect(
    page.locator(".message.assistant-message", { hasText: keyword }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
  await killSession(page, agentType);
}

test("archive button appears for inactive tasks, not active ones", async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  await sendMessage(page, 'Please reply with "arch-alive-test"');

  // Wait for the assistant response in the active chat — this proves Claude CLI
  // initialized (system:init output, agentSessionId set) and made its API call.
  // The sidebar label alone is not reliable because title generation (a separate
  // subprocess) can complete before Claude CLI outputs system:init.
  await expect(
    page.locator(".message.assistant-message", { hasText: "arch-alive-test" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  // Task is alive — archive button must NOT be visible
  await expect(page.locator(".btn-banner-archive")).not.toBeVisible();

  await killSession(page, agentType);

  // Task is now inactive — archive button must be visible with text "Archive"
  await expect(page.locator(".btn-banner-archive")).toBeVisible();
  await expect(page.locator(".btn-banner-archive")).toHaveText("Archive");
});

test("archiving a task moves it under Archive node", async ({
  page,
  agentType,
}) => {
  await createCompletedTask(page, "arch-keep-me", agentType);
  await createCompletedTask(page, "arch-archive-me", agentType);

  // Select "arch-archive-me" in the sidebar and archive it
  await page
    .locator(".sidebar-item .sidebar-label", { hasText: "arch-archive-me" })
    .first()
    .click();
  await page.locator(".btn-banner-archive").click();

  // Navigate to "arch-keep-me" so the archive node collapses
  await page
    .locator(".sidebar-item .sidebar-label", { hasText: "arch-keep-me" })
    .first()
    .click();

  // Archive node must appear
  await expect(page.locator(".sidebar-archive-node")).toBeVisible();

  // "arch-archive-me" must NOT be visible as a direct item (hidden under collapsed archive)
  await expect(
    page.locator(".sidebar-item .sidebar-label", { hasText: "arch-archive-me" }).first(),
  ).not.toBeVisible();

  // "arch-keep-me" must still be visible directly
  await expect(
    page.locator(".sidebar-item .sidebar-label", { hasText: "arch-keep-me" }).first(),
  ).toBeVisible();
});

test("archive node expands when selected", async ({ page, agentType }) => {
  await createCompletedTask(page, "arch-hidden-task", agentType);

  // Archive the task (archive node auto-expands since task is still active)
  await page.locator(".btn-banner-archive").click();

  // Wait for server to confirm archived state before navigating away.
  // The button only changes to "Unarchive" after the server processes set_archived
  // and broadcasts tasks_list — this ensures the DB is updated before page reload.
  await expect(page.locator(".btn-banner-archive")).toHaveText("Unarchive");

  // Navigate away so archive collapses
  await enterSession(page);

  // Click the Archive node
  await page.locator(".sidebar-archive-node").click();

  // Archive node must have "active" CSS class
  await expect(page.locator(".sidebar-archive-node")).toHaveClass(/active/);

  // "arch-hidden-task" must now be visible (archive expanded).
  // Scroll into view first: with many tasks the item may be outside the
  // visible scroll area even though it is rendered in the DOM.
  const hiddenTaskLabel = page.locator(".sidebar-item .sidebar-label", {
    hasText: "arch-hidden-task",
  }).first();
  await hiddenTaskLabel.scrollIntoViewIfNeeded();
  await expect(hiddenTaskLabel).toBeVisible();

  // Main content area must show the archive placeholder
  await expect(page.locator(".archive-placeholder")).toBeVisible();
});

test("unarchiving a task removes it from Archive", async ({
  page,
  agentType,
}) => {
  await createCompletedTask(page, "arch-restore-me", agentType);

  // Archive the task
  await page.locator(".btn-banner-archive").click();

  // Wait for server confirmation before navigating away — prevents the race
  // condition where page.goto closes the WebSocket before set_archived is processed.
  // The button changes to "Unarchive" only after the server broadcasts tasks_list.
  await expect(page.locator(".btn-banner-archive")).toHaveText("Unarchive");

  // Navigate away so archive collapses
  await enterSession(page);

  // Click Archive node to expand it, then select the archived task
  await page.locator(".sidebar-archive-node").click();
  const restoreLabel = page.locator(".sidebar-item .sidebar-label", {
    hasText: "arch-restore-me",
  }).first();
  await restoreLabel.scrollIntoViewIfNeeded();
  await restoreLabel.click();

  // The button now says "Unarchive" — click it
  await expect(page.locator(".btn-banner-archive")).toHaveText("Unarchive");
  await page.locator(".btn-banner-archive").click();

  // After unarchiving, the button must say "Archive" again
  await expect(page.locator(".btn-banner-archive")).toHaveText("Archive");

  // Task must be back in the normal sidebar list (not under the Archive node)
  await expect(
    page.locator(".sidebar-item .sidebar-label", { hasText: "arch-restore-me" }).first(),
  ).toBeVisible();
});

test("archive node shows count", async ({ page, agentType }) => {
  await createCompletedTask(page, "arch-count-one", agentType);
  await page.locator(".btn-banner-archive").click();
  // Wait for server confirmation before navigating away (createCompletedTask calls enterSession).
  await expect(page.locator(".btn-banner-archive")).toHaveText("Unarchive");

  await createCompletedTask(page, "arch-count-two", agentType);
  await page.locator(".btn-banner-archive").click();
  // Wait for server confirmation before navigating away.
  await expect(page.locator(".btn-banner-archive")).toHaveText("Unarchive");

  // Navigate away so we see the collapsed Archive node
  await enterSession(page);

  // Archive node label must show a count in parentheses
  await expect(
    page.locator(".sidebar-archive-node .sidebar-label"),
  ).toContainText(/\(\d+\)/);

  // Expand archive and verify both newly archived tasks appear
  await page.locator(".sidebar-archive-node").click();
  const countOneLabel = page.locator(".sidebar-item .sidebar-label", {
    hasText: "arch-count-one",
  }).first();
  await countOneLabel.scrollIntoViewIfNeeded();
  await expect(countOneLabel).toBeVisible();
  const countTwoLabel = page.locator(".sidebar-item .sidebar-label", {
    hasText: "arch-count-two",
  }).first();
  await countTwoLabel.scrollIntoViewIfNeeded();
  await expect(countTwoLabel).toBeVisible();
});

test("archived task cannot be resumed without unarchiving", async ({
  page,
  agentType,
}) => {
  await createCompletedTask(page, "arch-no-resume", agentType);

  // Resume button must be visible before archiving
  await expect(page.locator(".btn-resume")).toBeVisible();

  // Archive the task
  await page.locator(".btn-banner-archive").click();
  // Wait for server confirmation before navigating away.
  await expect(page.locator(".btn-banner-archive")).toHaveText("Unarchive");

  // Navigate away, expand archive, select the archived task
  await enterSession(page);
  await page.locator(".sidebar-archive-node").click();
  const noResumeLabel = page.locator(".sidebar-item .sidebar-label", {
    hasText: "arch-no-resume",
  }).first();
  await noResumeLabel.scrollIntoViewIfNeeded();
  await noResumeLabel.click();

  // If the resume button is visible, click it and verify the task stays non-alive
  const resumeBtn = page.locator(".btn-resume");
  if (await resumeBtn.isVisible()) {
    await resumeBtn.click();
    // The task must NOT become alive (stop button must not appear)
    await expect(page.locator(".btn-banner-stop")).not.toBeVisible({
      timeout: 3_000,
    });
    await expect(resumeBtn).toBeVisible();
  }
});

test("URL routing for archive nodes", async ({ page, agentType }) => {
  await createCompletedTask(page, "arch-url-task", agentType);

  // Archive the task
  await page.locator(".btn-banner-archive").click();
  // Wait for server confirmation before navigating away.
  await expect(page.locator(".btn-banner-archive")).toHaveText("Unarchive");

  // Navigate away so archive collapses
  await enterSession(page);

  // Click the Archive node
  await page.locator(".sidebar-archive-node").click();

  // URL must contain "/archive"
  await expect(page).toHaveURL(/\/archive$/);

  // Reload the page
  await page.reload();

  // Archive node must still be selected after reload
  await expect(page.locator(".sidebar-archive-node")).toHaveClass(/active/, {
    timeout: 15_000,
  });

  // Archive placeholder must be shown (not "Loading task...")
  await expect(page.locator(".archive-placeholder")).toBeVisible({
    timeout: 15_000,
  });
});
