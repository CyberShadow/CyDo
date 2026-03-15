import { test, expect, enterSession, sendMessage } from "./fixtures";

test("keep_context continuation injects prompt template", async ({ page, agentType }) => {
  test.skip(agentType !== "claude", "claude-only: continuation");
  await enterSession(page, agentType);

  await sendMessage(page, "call switchmode plan");

  await expect(
    page.locator(".message.user-message", { hasText: "Planning Mode" }),
  ).toBeVisible({ timeout: 30_000 });
});

test("unsent message recovered into input box after kill", async ({ page, agentType }) => {
  test.skip(agentType !== "claude", "claude-only: unsent message recovery");
  await enterSession(page, agentType);

  await sendMessage(page, "run command sleep 60");

  await expect(
    page.locator(".tool-call", { hasText: "sleep 60" }),
  ).toBeVisible({ timeout: 30_000 });

  await sendMessage(page, "this should be recovered");

  await page.locator(".btn-banner-stop").click();
  await expect(page.locator(".btn-resume")).toBeVisible({ timeout: 10_000 });

  await page.locator(".btn-resume").click();
  await expect(page.locator(".btn-banner-stop")).toBeVisible({ timeout: 15_000 });

  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toHaveValue("this should be recovered", { timeout: 10_000 });
});

test("input box stays empty after mode switch", async ({ page, agentType }) => {
  test.skip(agentType !== "claude", "claude-only: mode switch input recovery");
  await enterSession(page, agentType);

  await sendMessage(page, "call switchmode plan");

  await expect(
    page.locator(".message.user-message", { hasText: "Planning Mode" }),
  ).toBeVisible({ timeout: 30_000 });

  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled({ timeout: 10_000 });
  await expect(input).toHaveValue("");
});
