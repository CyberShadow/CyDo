import { test, expect } from "@playwright/test";

test("page loads and shows CyDo branding", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator(".welcome-page-header h1")).toContainText("CyDo", {
    timeout: 10_000,
  });
});

test("basic message and response", async ({ page }) => {
  await page.goto("/");

  // Click on the project to enter the project view
  await page.locator(".project-card-title").first().click({ timeout: 10_000 });

  // Wait for the input to be enabled (means WebSocket is connected)
  const input = page.locator(".input-textarea");
  await expect(input).toBeEnabled({ timeout: 10_000 });
  await input.fill('Please reply with "OK"');

  // Send the message
  await page.getByRole("button", { name: "Send" }).click();

  // The user message should appear
  await expect(page.locator(".message.user-message")).toBeVisible({
    timeout: 15_000,
  });

  // Wait for the assistant response containing "OK"
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "OK" }),
  ).toBeVisible({ timeout: 30_000 });
});

test("tool call flow", async ({ page }) => {
  await page.goto("/");

  // Click on the project to enter the project view
  await page.locator(".project-card-title").first().click({ timeout: 10_000 });

  // Wait for the input to be enabled (means WebSocket is connected)
  const input = page.locator(".input-textarea");
  await expect(input).toBeEnabled({ timeout: 10_000 });
  await input.fill("Please run command echo hello-from-test");
  await page.getByRole("button", { name: "Send" }).click();

  // Tool call should appear with the Bash tool name
  await expect(
    page.locator(".tool-name", { hasText: "Bash" }),
  ).toBeVisible({ timeout: 30_000 });

  // Tool result should show the command output
  await expect(
    page.locator(".tool-result", { hasText: "hello-from-test" }),
  ).toBeVisible({ timeout: 30_000 });

  // Final "Done." response
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "Done.",
    }),
  ).toBeVisible({ timeout: 30_000 });
});
