import { test, expect, enterSession, responseTimeout } from "./fixtures";

// 1x1 red pixel PNG, base64-encoded
const TINY_PNG_BASE64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==";

async function pasteImage(page: import("@playwright/test").Page, base64: string) {
  await page.evaluate((b64) => {
    const binary = atob(b64);
    const array = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) array[i] = binary.charCodeAt(i);
    const blob = new Blob([array], { type: "image/png" });
    const file = new File([blob], "test.png", { type: "image/png" });
    const dt = new DataTransfer();
    dt.items.add(file);
    const event = new Event("paste", { bubbles: true, cancelable: true });
    Object.defineProperty(event, "clipboardData", { value: dt });
    document.querySelector(".input-textarea")!.dispatchEvent(event);
  }, base64);
}

test.describe("image paste", () => {
  test("paste image into input, send, and verify round-trip", async ({
    page,
    agentType,
  }) => {
    test.skip(agentType !== "claude", "Image support is Claude-only");

    await enterSession(page);

    const input = page.locator(".input-textarea:visible").first();
    await expect(input).toBeEnabled({ timeout: 15_000 });

    // Step 1: Simulate pasting an image
    await input.focus();
    await pasteImage(page, TINY_PNG_BASE64);

    // Step 2: Verify image preview appears
    await expect(page.locator(".image-preview img")).toBeVisible({
      timeout: 5_000,
    });

    // Step 3: Type text and send
    await input.fill("describe this image");
    await page.locator(".btn-send:visible").first().click();

    // Step 4: Verify image appears in the user message in chat history
    await expect(
      page.locator(".message.user-message .user-image"),
    ).toBeVisible({ timeout: responseTimeout(agentType) });

    // Step 5: Verify user message text is also present
    await expect(
      page.locator(".message.user-message .user-text"),
    ).toContainText("describe this image");

    // Step 6: Verify mock API recognized the image and responded
    await expect(
      page.locator(".message.assistant-message .text-content", {
        hasText: "[image received]",
      }),
    ).toBeVisible({ timeout: responseTimeout(agentType) });

    // Step 7: Verify image preview was cleared from input area after send
    await expect(page.locator(".image-preview img")).not.toBeVisible();
  });

  test("remove image from preview before sending", async ({
    page,
    agentType,
  }) => {
    test.skip(agentType !== "claude", "Image support is Claude-only");

    await enterSession(page);

    const input = page.locator(".input-textarea:visible").first();
    await expect(input).toBeEnabled({ timeout: 15_000 });

    // Paste an image
    await input.focus();
    await pasteImage(page, TINY_PNG_BASE64);

    // Verify preview appears
    await expect(page.locator(".image-preview img")).toBeVisible({
      timeout: 5_000,
    });

    // Click remove button
    await page.locator(".image-preview-remove").click();

    // Verify preview is gone
    await expect(page.locator(".image-preview img")).not.toBeVisible();

    // Send text-only message to confirm normal flow still works
    await input.fill('reply with "text only works"');
    await page.locator(".btn-send:visible").first().click();

    await expect(
      page.locator(".message.assistant-message .text-content", {
        hasText: "text only works",
      }),
    ).toBeVisible({ timeout: responseTimeout(agentType) });
  });
});
