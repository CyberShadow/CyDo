import { test, expect, enterSession, sendMessage, responseTimeout } from "./fixtures";

test("ask_user_question clears on all connected clients when one answers", async ({
  page,
  browser,
  agentType,
}) => {
  // Page 1: create session and trigger AskUserQuestion
  await enterSession(page);
  await sendMessage(page, "call askuserquestion Do you agree?");

  // Wait for the AskUserForm to appear on page 1
  const form1 = page.locator(".ask-user-form");
  await expect(form1).toBeVisible({ timeout: responseTimeout(agentType) });

  // Extract the task ID from the URL so page 2 can navigate to the same task
  const url = page.url();
  const tidMatch = url.match(/\/task\/(\d+)/);
  // If URL doesn't have /task/N, try extracting from sidebar's active item
  let taskUrl = url;
  if (!tidMatch) {
    // The sidebar active item has data-tid or we can just navigate to the same URL
    // Since enterSession clicks new task, the URL should reflect the task
    taskUrl = url;
  }

  // Page 2: open a second browser context and navigate to the same task
  const context2 = await browser.newContext();
  const page2 = await context2.newPage();
  await page2.goto(taskUrl);

  // Wait for the AskUserForm to appear on page 2
  const form2 = page2.locator(".ask-user-form");
  await expect(form2).toBeVisible({ timeout: 15_000 });

  // Page 1: answer the question by clicking "Yes"
  await page.locator(".ask-option-btn", { hasText: "Yes" }).click();
  await page.locator(".ask-submit-btn").click();

  // Page 1: form should be cleared (replaced by input box)
  await expect(form1).not.toBeVisible({ timeout: 5_000 });

  // Page 2: form should also be cleared
  await expect(form2).not.toBeVisible({ timeout: 5_000 });

  await context2.close();
});

test("sidebar shows asking status while AskUserQuestion is pending", async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  await sendMessage(page, "call askuserquestion Do you agree?");

  // Wait for the AskUserForm to appear
  const form = page.locator(".ask-user-form");
  await expect(form).toBeVisible({ timeout: responseTimeout(agentType) });

  // The active sidebar item should have the .asking class
  const sidebarItem = page.locator(".sidebar-item.active");
  await expect(sidebarItem).toHaveClass(/asking/, { timeout: 5_000 });

  // The question icon should be visible
  const questionIcon = sidebarItem.locator(".task-type-icon-question");
  await expect(questionIcon).toBeVisible();

  // Answer the question
  await page.locator(".ask-option-btn", { hasText: "Yes" }).click();
  await page.locator(".ask-submit-btn").click();

  // Form should disappear
  await expect(form).not.toBeVisible({ timeout: 5_000 });

  // The .asking class should be removed from the sidebar item
  await expect(sidebarItem).not.toHaveClass(/asking/, { timeout: 5_000 });

  // The question icon should no longer be visible
  await expect(questionIcon).not.toBeVisible({ timeout: 5_000 });
});
