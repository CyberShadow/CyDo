import { test as base, expect } from "@playwright/test";
import type { Page } from "@playwright/test";

type AgentType = "claude" | "codex";

/** Navigate to the welcome page, click +, and wait for the InputBox to be ready. */
export async function enterSession(page: Page) {
  await page.goto("/");
  await page.locator('button[title="New task"]').first().click();
  await expect(page.locator(".input-textarea:visible").first()).toBeEnabled({
    timeout: 15_000,
  });
}

/** Send a message from whichever input is currently visible. */
export async function sendMessage(page: Page, text: string) {
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled({ timeout: 15_000 });
  await input.click();
  await input.fill(text);
  const sendBtn = page.locator(".btn-send:visible").first();
  try {
    await expect(sendBtn).toBeEnabled({ timeout: 2_000 });
  } catch {
    await input.clear();
    await input.pressSequentially(text);
    await expect(sendBtn).toBeEnabled({ timeout: 2_000 });
  }
  await sendBtn.click();
}

/** Kill the active session and wait for it to become inactive. */
export async function killSession(page: Page, agentType: AgentType) {
  await page.locator(".btn-banner-stop").click();
  const timeout = 15_000;
  await expect(page.locator(".btn-banner-archive")).toBeVisible({ timeout });
}

/** Return an appropriate response timeout for the given agent. */
export function responseTimeout(agentType: AgentType): number {
  return agentType === "codex" ? 60_000 : 30_000;
}

/**
 * Extended test fixture that automatically asserts no unknown message types
 * appear during any test.
 *
 * The frontend renders unknown message type errors as system messages
 * containing "Unknown message type".  This fixture checks the DOM after
 * every test and fails if any such messages exist.
 *
 * Usage: import { test, expect } from "./fixtures" instead of "@playwright/test".
 */
export const test = base.extend<{ agentType: AgentType }>({
  agentType: async ({}, use, testInfo) => {
    const at = (testInfo.project.use as any).agentType ?? "claude";
    await use(at);
  },
  page: async ({ page }, use) => {
    await use(page);

    // After the test body: assert no unknown message type errors in the DOM.
    const errorMessages = page.locator(".message.system-message pre", {
      hasText: /Unknown message type/,
    });
    const errorCount = await errorMessages.count();
    if (errorCount > 0) {
      const texts: string[] = [];
      for (let i = 0; i < errorCount; i++) {
        texts.push(await errorMessages.nth(i).innerText());
      }
      expect(
        errorCount,
        `Protocol errors in DOM:\n${texts.join("\n---\n")}`
      ).toBe(0);
    }

    // Assert no unknown tool result fields rendered — every toolUseResult
    // field should be explicitly categorized per tool.
    const unknownResultFields = page.locator(".unknown-result-fields");
    const unknownResultCount = await unknownResultFields.count();
    if (unknownResultCount > 0) {
      const descriptions: string[] = [];
      for (let i = 0; i < unknownResultCount; i++) {
        descriptions.push(await unknownResultFields.nth(i).innerText());
      }
      expect(
        unknownResultCount,
        `Unknown tool result fields rendered in DOM:\n${descriptions.join("\n---\n")}`,
      ).toBe(0);
    }
  },
});

export { expect } from "@playwright/test";
export type { Page } from "@playwright/test";
export type { AgentType };
