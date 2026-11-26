import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  test,
  expect,
  enterSession,
  responseTimeout,
  assistantText,
  sendMessage,
} from "./fixtures";

test(
  "send a picked HEIC photo as JPEG and restore it after reload",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    await enterSession(page);
    await expect(page.locator(".input-box:visible .input-file")).toHaveAttribute(
      "accept",
      /\.heic/,
    );

    const chooser = page.waitForEvent("filechooser");
    await page.getByRole("button", { name: "Attach images" }).click();
    await (await chooser).element().setInputFiles({
      name: "IMG_0001.HEIC",
      mimeType: "",
      buffer: readFileSync(join(__dirname, "..", "data", "colors.heic")),
    });

    await expect(page.locator(".image-preview-label")).toHaveText(
      "HEIC IMG_0001.HEIC",
    );
    await expect(page.locator(".image-preview img")).toHaveCount(0);

    const prompt = "describe this photo";
    await sendMessage(page, prompt);
    await expect(
      assistantText(page, "image received: image/jpeg ffd8ff"),
    ).toBeVisible({ timeout: responseTimeout(agentType) });

    await page.reload();
    await expect(
      page
        .locator(".message.user-message")
        .filter({ hasText: prompt })
        .locator("img.user-image"),
    ).toBeVisible({ timeout: responseTimeout(agentType) });
  },
);
