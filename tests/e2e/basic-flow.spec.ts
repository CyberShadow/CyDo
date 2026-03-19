import { test, expect, enterSession, sendMessage, responseTimeout } from "./fixtures";

test("page loads and shows CyDo branding", async ({ page, agentType }) => {
  test.skip(agentType === "codex", "agent-agnostic, runs in claude project only");
  await page.goto("/");
  await expect(page.locator(".welcome-page-header h1")).toContainText("CyDo", {
    timeout: 10_000,
  });
});

test("basic message and response", async ({ page, agentType }) => {
  await enterSession(page);

  const input = page.locator(".input-textarea");
  await expect(input).toBeEnabled({ timeout: 15_000 });
  await input.fill('Please reply with "OK"');
  await page.getByRole("button", { name: "Send" }).click();

  await expect(page.locator(".message.user-message")).toBeVisible({
    timeout: 15_000,
  });

  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "OK" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
});

test("tool call flow", async ({ page, agentType }) => {
  await enterSession(page);

  const input = page.locator(".input-textarea");
  await expect(input).toBeEnabled({ timeout: 15_000 });
  await input.fill("Please run command echo hello-from-test");
  await page.getByRole("button", { name: "Send" }).click();

  await expect(
    page.locator(".tool-name", { hasText: "Bash" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  await expect(
    page.locator(".tool-result", { hasText: "hello-from-test" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "Done." }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
});

test("codex tool call renders output content", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "codex", "codex-only test");
  // This test verifies that Codex tool results include structured content
  // that the frontend can render (not just the tool name).
  await enterSession(page);
  await sendMessage(page, "run command echo hello-from-test");
  await expect(
    page.locator(".tool-result", { hasText: "hello-from-test" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
});

test("codex agent type indicator", async ({ page, agentType }) => {
  test.skip(agentType !== "codex", "codex-only test");
  await enterSession(page);

  const input = page.locator(".input-textarea");
  await expect(input).toBeEnabled({ timeout: 15_000 });
  await input.fill('reply with "hello"');
  await page.getByRole("button", { name: "Send" }).click();

  await expect(page.locator(".message.assistant-message")).toBeVisible({ timeout: 60_000 });
  await expect(page.locator(".banner-agent")).toBeVisible({ timeout: 10_000 });
  await expect(page.locator(".banner-agent")).toContainText("codex", { ignoreCase: true });
});
