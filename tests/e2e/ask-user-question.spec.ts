import { test, expect, enterSession, sendMessage, responseTimeout } from "./fixtures";

// Regression guard: AskUserQuestion works from plan_mode.
// plan_mode has user_visible: false but is in the interactive cluster —
// it is reachable from conversation (user_visible: true) via keep_context.
// Bug: the gate in handleAskUserQuestion() checks typeDef.user_visible, so
// it incorrectly rejects AskUserQuestion calls from plan_mode with:
//   "AskUserQuestion is only available for interactive tasks.
//    This task type (plan_mode) is not user-visible."
test("AskUserQuestion works from plan_mode after keep_context mode switch", async ({
  page,
  agentType,
}) => {
  // The codex mock's hasToolOutput() scans the entire input history for any
  // prior function_call_output and returns "Done." — after SwitchMode, it finds
  // that output and cannot distinguish the subsequent AskUserQuestion call.
  test.skip(agentType === "codex", "codex mock cannot handle AskUserQuestion after a keep_context mode switch");

  await enterSession(page); // creates a conversation task (user_visible: true)

  // Switch to plan_mode via a keep_context continuation.
  await sendMessage(page, "call switchmode plan");

  // Wait for the mode switch to complete: visible as a divider labelled "Mode switch: plan".
  await expect(
    page.locator(".result-divider.system-user-message", { hasText: "Mode switch: plan" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  // Wait for the agent to finish processing so the input is active.
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled({ timeout: responseTimeout(agentType) });

  // From plan_mode, call AskUserQuestion.
  // This should succeed — plan_mode is interactive (reachable from conversation
  // via keep_context), even though its user_visible flag is false.
  await sendMessage(page, "call askuserquestion Do you agree?");

  // The AskUserForm must appear. Currently fails because handleAskUserQuestion()
  // gates on typeDef.user_visible which is false for plan_mode.
  const form = page.locator(".ask-user-form");
  await expect(form).toBeVisible({ timeout: responseTimeout(agentType) });
});

test("ask_user_question clears on all connected clients when one answers", async ({
  page,
  browser,
  agentType,
}) => {
  // Copilot spawns a fresh cydo --mcp-server for each MCP tool call which adds latency
  if (agentType === "copilot") test.setTimeout(120_000);

  // Page 1: create session and trigger AskUserQuestion
  await enterSession(page);
  await sendMessage(page, "call askuserquestion Do you agree?");

  // Wait for the AskUserForm to appear on page 1
  const form1 = page.locator(".ask-user-form");
  await expect(form1).toBeVisible({ timeout: agentType === "copilot" ? 60_000 : responseTimeout(agentType) });

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

test("codex AskUserQuestion with delimiter text shows selected answer", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "codex", "codex-only regression for normalized array result content");

  await enterSession(page);
  await sendMessage(page, 'call askuserquestion What does "=" mean?');

  const form = page.locator(".ask-user-form");
  await expect(form).toBeVisible({ timeout: responseTimeout(agentType) });

  await page.locator(".ask-option-btn", { hasText: "Yes" }).click();
  await page.locator(".ask-submit-btn").click();
  await expect(form).not.toBeVisible({ timeout: 5_000 });

  await expect(
    page.locator(".tool-call .ask-answer", { hasText: "Yes" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
});
