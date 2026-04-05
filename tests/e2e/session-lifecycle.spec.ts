import { test, expect, enterSession, sendMessage, killSession, responseTimeout } from "./fixtures";

test("history survives page reload", async ({ page, agentType }) => {
  await enterSession(page);
  await sendMessage(page, 'Please reply with "persistent"');

  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "persistent" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  await killSession(page, agentType);

  await expect(
    page.locator(".message.user-message", { hasText: "persistent" }),
  ).toBeVisible({ timeout: 15_000 });

  await page.reload();

  await page
    .locator(".sidebar-item .sidebar-label", { hasText: "persistent" })
    .click({ timeout: 15_000 });

  await expect(
    page.locator(".message.user-message", { hasText: "persistent" }),
  ).toBeVisible({ timeout: 15_000 });
});

test("no duplicate messages after reload", async ({ page, agentType }) => {
  await enterSession(page);
  await sendMessage(page, 'Please reply with "nodups"');

  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "nodups" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  await killSession(page, agentType);

  await expect(
    page.locator(".message.user-message", { hasText: "nodups" }),
  ).toBeVisible({ timeout: 15_000 });
  const countBefore = await page.locator(".message.user-message").count();

  await page.reload();
  await page
    .locator(".sidebar-item .sidebar-label", { hasText: "nodups" })
    .click({ timeout: 15_000 });

  await expect(
    page.locator(".message.user-message", { hasText: "nodups" }),
  ).toBeVisible({ timeout: 15_000 });

  const countAfter = await page.locator(".message.user-message").count();
  expect(countAfter).toBeLessThanOrEqual(countBefore);
});

test("session stop shows resume button", async ({ page, agentType }) => {
  await enterSession(page);
  await sendMessage(page, 'Please reply with "before-stop"');

  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "before-stop" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  await killSession(page, agentType);
  await expect(page.locator(".btn-banner-resume")).toBeVisible();
});

test("session resume continues conversation", async ({ page, agentType }) => {
  await enterSession(page);
  await sendMessage(page, 'Please reply with "pre-resume"');

  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "pre-resume" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  await killSession(page, agentType);

  await page.locator(".btn-banner-resume").click();

  const bannerTimeout = agentType === "codex" ? 30_000 : 15_000;
  await expect(page.locator(".btn-banner-stop")).toBeVisible({ timeout: bannerTimeout });
  await expect(page.locator(".btn-stop")).not.toBeVisible({ timeout: bannerTimeout });

  const input = page.locator(".input-textarea").first();
  await expect(input).toBeVisible({ timeout: 5_000 });
  await input.click();
  await input.fill('Please reply with "post-resume"');
  await expect(page.locator(".btn-send").first()).toBeEnabled({ timeout: 5_000 });
  await page.locator(".btn-send").first().click();

  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "post-resume" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
});

test("sending message to stopped session auto-resumes it", async ({ page, agentType }) => {
  await enterSession(page);
  await sendMessage(page, 'Please reply with "before-auto"');

  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "before-auto" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  await killSession(page, agentType);

  // Instead of clicking Resume, send a message directly via the input box
  await sendMessage(page, 'Please reply with "after-auto"');

  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "after-auto" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
});

test("codex reload replays apply_patch tool call", async ({ page, agentType }) => {
  test.skip(agentType !== "codex", "codex-only test");

  await enterSession(page);
  await sendMessage(page, "codex filechange create fixture");
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "Done." }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  await killSession(page, agentType);
  await page.reload();
  await page
    .locator(".sidebar-item .sidebar-label", { hasText: "codex filechange create fixture" })
    .first()
    .click({ timeout: 15_000 });

  const tool = page
    .locator(".tool-call")
    .filter({ has: page.locator(".tool-name", { hasText: /apply_patch/i }) })
    .last();
  await expect(tool).toBeVisible({ timeout: responseTimeout(agentType) });

  await tool.locator(".tool-header").hover();
  const viewBtn = tool.locator(".tool-view-file");
  await expect(viewBtn).toBeVisible({ timeout: 5_000 });
  await viewBtn.click();
  await expect(page.locator(".file-viewer")).toBeVisible({ timeout: 5_000 });
  await expect(page.locator(".file-viewer")).toContainText("codex-fileviewer-create.txt");
});
