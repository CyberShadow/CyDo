import type { Locator, Page } from "@playwright/test";
import { assistantText, enterSession, expect, responseTimeout, sendMessage, test } from "./fixtures";

const phone = { width: 390, height: 844 };
const keyboardTop = 400;
const composerHeight = 36; // One-line composer height (--composer-btn-h).

test.use({ viewport: phone, isMobile: true, hasTouch: true });

test("mobile new-task description can scroll into view after layout resize", async ({ page }) => {
  await enterSession(page);
  const field = page.locator(".welcome-prompt textarea");
  await field.tap();
  await expect(field).toBeFocused();

  // Simulate resizes-content and the browser's focus reveal without an OS keyboard.
  await page.setViewportSize({ width: phone.width, height: keyboardTop });
  await field.evaluate((textarea) => textarea.scrollIntoView({ block: "nearest" }));

  await expect(field).toBeFocused();
  const { top, bottom, visibleTop, visibleBottom } = await field.evaluate((textarea) => {
    const fieldRect = textarea.getBoundingClientRect();
    const scrollRect = textarea.closest(".welcome-prompt")!.getBoundingClientRect();
    return {
      top: fieldRect.top,
      bottom: fieldRect.bottom,
      visibleTop: Math.max(0, scrollRect.top),
      visibleBottom: Math.min(document.documentElement.clientHeight, scrollRect.bottom),
    };
  });
  expect(top).toBeGreaterThanOrEqual(visibleTop);
  expect(bottom).toBeLessThanOrEqual(visibleBottom);
});

async function expectResponsiveDraftHeight(page: Page, field: Locator) {
  await expect(field).toHaveValue("");
  const height = () => field.evaluate((textarea) => textarea.getBoundingClientRect().height);
  await expect.poll(height).toBe(composerHeight);
  await field.fill("A short draft");
  await expect.poll(height).toBe(composerHeight);

  const draft = Array.from({ length: 30 }, (_, index) => `Draft line ${index + 1}`).join("\n");
  await field.fill(draft);
  const overflow = () => field.evaluate((textarea) => textarea.scrollHeight - textarea.clientHeight);
  await expect.poll(height).toBe(200);
  await expect.poll(overflow).toBeGreaterThan(0);

  await page.setViewportSize({ width: phone.width, height: 500 });
  await expect(field).toHaveValue(draft);
  await expect.poll(async () => Math.abs((await height()) - 125)).toBeLessThanOrEqual(2);
  await expect.poll(overflow).toBeGreaterThan(0);
}

test("mobile new-task draft height follows the viewport", async ({ page }) => {
  await enterSession(page);
  await expectResponsiveDraftHeight(page, page.locator(".welcome-prompt textarea"));
});

test("mobile session draft height follows the viewport", async ({ page, agentType }) => {
  await enterSession(page);
  await sendMessage(page, 'Please reply with "draft-height-session"');
  await expect(assistantText(page, "draft-height-session")).toBeVisible({
    timeout: responseTimeout(agentType),
  });
  const field = page.locator(".input-textarea:visible");
  await expect(field).toHaveAttribute("placeholder", "Type a message...", {
    timeout: responseTimeout(agentType),
  });
  await expectResponsiveDraftHeight(page, field);
});
