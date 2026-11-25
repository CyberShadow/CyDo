import {
  test,
  expect,
  enterSession,
  responseTimeout,
  assistantText,
} from "./fixtures";

const TINY_PNG_BASE64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==";

test(
  "send a picked image and restore it after reload",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    await enterSession(page);

    const chooser = page.waitForEvent("filechooser");
    await page.getByRole("button", { name: "Attach images" }).click();
    await (await chooser).element().setInputFiles({
      name: "test.png",
      mimeType: "image/png",
      buffer: Buffer.from(TINY_PNG_BASE64, "base64"),
    });

    const preview = page.locator(".image-preview img");
    const prompt = "describe this image";
    const message = page
      .locator(".message.user-message")
      .filter({ hasText: prompt });
    const image = message.locator(".user-image");

    await expect(preview).toBeVisible();
    await page.locator(".input-textarea:visible").first().fill(prompt);
    await page.locator(".btn-send:visible").first().click();

    await expect(image).toBeVisible({ timeout: responseTimeout(agentType) });
    await expect(assistantText(page, "image received")).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    await expect(preview).not.toBeVisible();

    await page.reload();
    await expect(image).toBeVisible({ timeout: responseTimeout(agentType) });
  },
);
