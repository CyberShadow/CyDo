import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
} from "./fixtures";
import type { Page } from "./fixtures";

async function disableFocusForAttentionChecks(page: Page) {
  // Keep this false across navigations; otherwise auto-dismiss can clear
  // attention before assertions run.
  await page.addInitScript(() => {
    Document.prototype.hasFocus = () => false;
  });
  await page.evaluate(() => {
    document.hasFocus = () => false;
  });
}

test("tab title shows attention count scoped to current project", async ({
  page,
  agentType,
}) => {
  // codex mock cannot reliably handle AskUserQuestion
  test.skip(agentType === "codex", "codex mock cannot handle AskUserQuestion");

  // Enter session 1. Override hasFocus to prevent auto-dismiss from racing
  // with navigation (auto-dismiss gates on document.hasFocus()).
  await enterSession(page);
  await disableFocusForAttentionChecks(page);
  await sendMessage(page, "call askuserquestion Do you agree?");
  await page.goto("/local/cydo-test-workspace");

  // The tab title should show "(1)" because session 1 (same project) needs
  // attention. This exercises the bug fix: the counter now uses the resolved
  // project path rather than the raw project name string.
  await expect(page).toHaveTitle(/^\(1\) /, {
    timeout: responseTimeout(agentType),
  });
});

test("home button does not show attention for same-project sessions", async ({
  page,
  agentType,
}) => {
  // codex mock cannot reliably handle AskUserQuestion
  test.skip(agentType === "codex", "codex mock cannot handle AskUserQuestion");

  // Enter session and trigger attention. Override hasFocus to prevent the
  // auto-dismiss race with navigation.
  await enterSession(page);
  await disableFocusForAttentionChecks(page);
  await sendMessage(page, "call askuserquestion Do you agree?");
  await page.goto("/local/cydo-test-workspace");

  // Wait for the page to settle and attention to be received
  await expect(page).toHaveTitle(/^\(1\) /, {
    timeout: responseTimeout(agentType),
  });

  // The home button should NOT have the attention class — it only lights up
  // for other-project attention, and the tab title covers current-project.
  const homeBtn = page.locator(".sidebar-back-btn");
  await expect(homeBtn).not.toHaveClass(/has-attention/);
});

test("hamburger button shows attention for any session on mobile", async ({
  page,
  agentType,
}) => {
  // codex mock cannot reliably handle AskUserQuestion
  test.skip(agentType === "codex", "codex mock cannot handle AskUserQuestion");

  // Create session 1 and trigger attention. Override hasFocus to prevent the
  // auto-dismiss race with navigation.
  await enterSession(page);
  await disableFocusForAttentionChecks(page);
  await sendMessage(page, "call askuserquestion Do you agree?");
  await page.goto("/local/cydo-test-workspace");

  // Wait for session 1's attention to appear in the tab title (confirms the
  // backend set needsAttention and the frontend received it).
  await expect(page).toHaveTitle(/^\(1\) /, {
    timeout: responseTimeout(agentType),
  });

  // Create session 2 so we have a SessionView with a hamburger.
  await enterSession(page);
  await sendMessage(page, 'reply with "second"');
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "second",
    }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  // Now shrink to mobile viewport — hamburger appears, sidebar hides.
  await page.setViewportSize({ width: 375, height: 667 });

  // The hamburger button should show attention (session 1 still needs it)
  const hamburger = page.locator(".hamburger-btn");
  await expect(hamburger).toHaveClass(/has-attention/, {
    timeout: responseTimeout(agentType),
  });
  await expect(hamburger.locator(".task-type-icon-check")).toBeVisible();
});

test("active sessions sort attention-needing tasks first with attention styling", async ({
  page,
  agentType,
}) => {
  // codex mock cannot reliably handle AskUserQuestion
  test.skip(agentType === "codex", "codex mock cannot handle AskUserQuestion");

  // Create first session - let it complete so it stays in active sessions without attention
  await enterSession(page);
  await sendMessage(page, 'reply with "first-task"');
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "first-task",
    }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  // Create second session. Override document.hasFocus to prevent auto-dismiss
  // from firing (it gates on hasFocus()). This eliminates the race between
  // the AskUserQuestion response arriving and page.goto navigating away.
  await enterSession(page);
  await disableFocusForAttentionChecks(page);
  await sendMessage(page, "call askuserquestion Do you agree?");
  await page.goto("/local/cydo-test-workspace");
  await page.goto("/");
  await expect(page.locator(".active-sessions-table")).toBeVisible({
    timeout: 10_000,
  });

  // The first row in active sessions should be the attention-needing task.
  // Attention rows are sorted first by the welcome page reducer.
  const firstRow = page.locator(".active-sessions-row").first();
  await expect(firstRow).toHaveClass(/attention/, {
    timeout: responseTimeout(agentType),
  });

  // The attention row should have the checkmark icon
  await expect(firstRow.locator(".task-type-icon-check")).toBeVisible();
});
