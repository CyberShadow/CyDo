import { enterSession, expect, test } from "./fixtures";

const phone = { width: 390, height: 844 };
const keyboardTop = 400;

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
