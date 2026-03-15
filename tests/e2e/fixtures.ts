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

/** Kill the active session and wait for the resume button. */
export async function killSession(page: Page, agentType: AgentType) {
  await page.locator(".btn-banner-stop").click();
  const timeout = agentType === "codex" ? 15_000 : 10_000;
  await expect(page.locator(".btn-resume")).toBeVisible({ timeout });
}

/** Return an appropriate response timeout for the given agent. */
export function responseTimeout(agentType: AgentType): number {
  return agentType === "codex" ? 60_000 : 30_000;
}

/**
 * Extended test fixture that automatically asserts no schema validation
 * errors or unknown message types appear during any test.
 *
 * The frontend renders validation failures as system messages containing
 * "Schema validation failed" or "Unknown message type".  This fixture
 * checks the DOM after every test and fails if any such messages exist.
 *
 * It also asserts that no ExtraFields components rendered — meaning no
 * protocol fields went unrecognized by the Zod schemas.
 *
 * Policy: when these assertions fail, present the failures to the user so
 * they can decide how the new fields should be handled.  Do NOT silence
 * the assertion by adding z.unknown() declarations or removing the check.
 * Agents may suggest how to handle new fields but must not make
 * independent decisions about suppressing them.
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

    // After the test body: assert no validation error messages in the DOM.
    const errorMessages = page.locator(".message.system-message pre", {
      hasText: /Schema validation failed|Unknown message type|No schema for/,
    });
    const errorCount = await errorMessages.count();
    if (errorCount > 0) {
      const texts: string[] = [];
      for (let i = 0; i < errorCount; i++) {
        texts.push(await errorMessages.nth(i).innerText());
      }
      expect(
        errorCount,
        `Protocol validation errors in DOM:\n${texts.join("\n---\n")}`
      ).toBe(0);
    }

    // Assert no ExtraFields rendered — every protocol field should be
    // covered by the Zod schemas.  See schemas.ts for the completeness
    // policy.
    const extraFields = page.locator(".extra-fields");
    const extraCount = await extraFields.count();
    if (extraCount > 0) {
      // Expand collapsed <details> to read the full content
      const descriptions: string[] = [];
      for (let i = 0; i < extraCount; i++) {
        const el = extraFields.nth(i);
        const summary = await el.locator("summary").innerText();
        const content = await el.locator(".extra-fields-content").innerHTML();
        descriptions.push(`${summary}\n${content}`);
      }
      expect(
        extraCount,
        `Unrecognized protocol fields rendered in DOM:\n${descriptions.join(
          "\n---\n"
        )}`
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
