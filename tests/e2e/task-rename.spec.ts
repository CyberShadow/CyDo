import {
  test,
  expect,
  enterSession,
  sendMessage,
  assistantText,
  responseTimeout,
} from "./fixtures";

test("task rename from the banner", async ({ page, agentType }) => {
  const timeout = responseTimeout(agentType);

  await enterSession(page);
  await sendMessage(page, 'Please reply with "rename-me"');
  await expect(assistantText(page, "rename-me")).toBeVisible({ timeout });

  // the starting title is the first message or the one-shot result,
  // depending on what the agent's title generation produced; read it live
  const sidebarLabel = page.locator(".sidebar-item .sidebar-label");
  await expect(sidebarLabel.filter({ hasText: "rename-me" })).toBeVisible({
    timeout,
  });
  const initialTitle =
    (await sidebarLabel
      .filter({ hasText: "rename-me" })
      .first()
      .textContent()) ?? "";
  expect(initialTitle).toContain("rename-me");

  // the input opens pre-filled with the current name; Enter commits
  await page.locator(".btn-banner-rename").click();
  const input = page.locator(".banner-rename-input");
  await expect(input).toHaveValue(initialTitle);
  await input.fill("renamed by enter");
  await input.press("Enter");
  await expect(input).toHaveCount(0);
  await expect(
    sidebarLabel.filter({ hasText: "renamed by enter" }),
  ).toBeVisible();

  // the Apply button commits too
  await page.locator(".btn-banner-rename").click();
  await expect(input).toHaveValue("renamed by enter");
  await input.fill("renamed by apply");
  await page.locator(".btn-banner-apply").click();
  await expect(input).toHaveCount(0);
  await expect(
    sidebarLabel.filter({ hasText: "renamed by apply" }),
  ).toBeVisible();

  // Escape cancels without renaming
  await page.locator(".btn-banner-rename").click();
  await input.fill("discarded name");
  await input.press("Escape");
  await expect(input).toHaveCount(0);
  await expect(
    sidebarLabel.filter({ hasText: "renamed by apply" }),
  ).toBeVisible();

  // the rename came back from the server store, not client state
  await page.reload();
  await expect(sidebarLabel.filter({ hasText: "renamed by apply" })).toBeVisible(
    { timeout },
  );
});
