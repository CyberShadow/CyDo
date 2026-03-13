import { test, expect, Page } from "./fixtures";

/** Navigate to the first project and wait for WebSocket connection. */
async function enterProject(page: Page) {
  await page.goto("/");
  await page.locator(".project-card-title").first().click({ timeout: 10_000 });
  await expect(page.locator(".input-textarea:visible").first()).toBeEnabled({
    timeout: 10_000,
  });
}

/** Send a message from whichever input is currently visible. */
async function sendMessage(page: Page, text: string) {
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled({ timeout: 10_000 });
  await input.fill(text);
  await page.locator(".btn-send:visible").first().click();
}

test("keep_context continuation injects prompt template", async ({ page }) => {
  await enterProject(page);

  // Send a message that triggers the mock API to return a SwitchMode tool call.
  // The mock API pattern "call switchmode plan" returns mcp__cydo__SwitchMode.
  // The backend handles SwitchMode, the session exits, and spawnContinuation
  // resumes the session with the continuation's prompt_template injected as a
  // user message.
  await sendMessage(page, "call switchmode plan");

  // The continuation prompt from docs/task-types/prompts/enter_plan_mode.md
  // should appear as a user message. Its first line is "# Planning Mode".
  await expect(
    page.locator(".message.user-message", { hasText: "Planning Mode" }),
  ).toBeVisible({ timeout: 30_000 });
});
