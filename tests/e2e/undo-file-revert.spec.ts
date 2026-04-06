import { test, expect, enterSession, sendMessage, killSession } from "./fixtures";
import { existsSync } from "fs";

test("undo with file revert removes file created by agent", async ({ page, backend, agentType }) => {
  test.skip(agentType !== "claude", "file revert only supported for Claude Code");

  const testFile = `${backend.wsDir}/undo-revert-test.txt`;
  const testContent = "hello from undo-revert test";

  await enterSession(page);

  // 1. Ask Claude to create a file — the "create file" pattern triggers a Write tool call
  await sendMessage(page, `create file ${testFile} with content ${testContent}`);

  // Wait for the Write tool call and its result to complete (the mock follows
  // up with a "Done." text response after the tool result)
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "Done." }),
  ).toBeVisible({ timeout: 30_000 });

  // 2. Verify the file was created on disk
  expect(existsSync(testFile), `File should exist at ${testFile}`).toBe(true);

  // 3. Kill the session so we can undo
  await killSession(page, agentType);

  // 4. Find the user message that asked to create the file and click undo
  const userMsg = page
    .locator(".message-wrapper", {
      has: page.locator(".user-message", { hasText: "create file" }),
    })
    .last();
  await userMsg.hover();
  await expect(userMsg.locator(".undo-btn")).toBeVisible({ timeout: 5_000 });
  await userMsg.locator(".undo-btn").click();

  // 5. Confirm undo in the dialog (with file revert enabled — the default)
  await expect(page.locator(".undo-dialog")).toBeVisible({ timeout: 5_000 });
  await page.locator(".btn-undo").click();

  // 6. Wait for the undo to complete — the result banner confirms rewindFiles finished
  await expect(page.locator(".undo-result-banner")).toBeVisible({ timeout: 15_000 });

  // 7. Verify the file was reverted (should no longer exist since it didn't
  //    exist before the undone message)
  expect(
    existsSync(testFile),
    `File should have been removed by undo file revert: ${testFile}`,
  ).toBe(false);
});
