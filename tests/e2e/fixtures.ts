import { test as base, expect } from "@playwright/test";

/**
 * Extended test fixture that automatically asserts no schema validation
 * errors or unknown message types appear during any test.
 *
 * The frontend renders validation failures as system messages containing
 * "Schema validation failed" or "Unknown message type".  This fixture
 * checks the DOM after every test and fails if any such messages exist.
 *
 * Usage: import { test, expect } from "./fixtures" instead of "@playwright/test".
 */
export const test = base.extend({
  page: async ({ page }, use) => {
    await use(page);

    // After the test body: assert no validation error messages in the DOM.
    const errorMessages = page.locator(".message.system-message pre", {
      hasText: /Schema validation failed|Unknown message type|No schema for/,
    });
    const count = await errorMessages.count();
    if (count > 0) {
      const texts: string[] = [];
      for (let i = 0; i < count; i++) {
        texts.push(await errorMessages.nth(i).innerText());
      }
      expect(
        count,
        `Protocol validation errors in DOM:\n${texts.join("\n---\n")}`,
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
