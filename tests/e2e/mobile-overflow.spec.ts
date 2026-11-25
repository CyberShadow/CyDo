import {
  assistantText,
  enterSession,
  expect,
  sendMessage,
  test,
} from "./fixtures";

test.use({
  viewport: { width: 390, height: 844 },
  backendEnv: {
    CLAUDE_CODE_ENTRYPOINT: "claude-desktop",
    CLAUDE_CODE_OAUTH_TOKEN: "cydo-test-oauth-token",
  },
});

test(
  "the task bar, account usage, and background command fit on mobile",
  { tag: "@claude-only" },
  async ({ page }) => {
    await enterSession(page);
    await sendMessage(page, "usage headers fixture 5h");
    await expect(assistantText(page, "usage-headers-5h")).toBeVisible();
    await sendMessage(page, "usage headers fixture 7d");
    await expect(assistantText(page, "usage-headers-7d")).toBeVisible();

    const documentWidth = () =>
      page.evaluate(() => document.documentElement.scrollWidth);
    const bar = page.locator(".task-bar:visible");
    await expect(bar).toHaveAttribute("data-connection", "connected");
    await bar.locator(".hamburger-btn").click();
    const account = page.locator(".sidebar .sidebar-account");
    await expect(account).toBeVisible();
    await expect(account.locator(".account-usage-value")).toHaveText([
      "42%",
      "71%",
    ]);
    expect(await documentWidth(), "document with sidebar open").toBe(390);
    await page.locator(".sidebar-backdrop").click({
      position: { x: 345, y: 400 },
    });
    await expect(account).toBeHidden();
    await expect(bar.locator(".btn-banner-end")).toBeVisible();
    await expect(bar.locator(".btn-banner-stop")).toBeHidden();
    await expect(bar.locator(".theme-toggle")).toBeVisible();

    const barWidth = await bar.evaluate((element) => ({
      scroll: element.scrollWidth,
      client: element.clientWidth,
    }));
    expect(barWidth.scroll, "task bar scroll width").toBeLessThanOrEqual(
      barWidth.client,
    );
    expect(await documentWidth(), "document with task bar").toBe(390);

    const path = `/tmp/${"longbackgroundcommandpath".repeat(5)}output`;
    await sendMessage(
      page,
      `run detached command sleep 5 && printf %s ${path} with description ${path}`,
    );

    const messageList = page.locator(".message-list");
    const row = messageList.locator(".task-started").filter({ hasText: path });
    await expect(row).toBeVisible();
    await row.scrollIntoViewIfNeeded();

    const widths = await row.evaluate((element) => {
      const list = element.closest(".message-list")!;
      return {
        row: { scroll: element.scrollWidth, client: element.clientWidth },
        list: { scroll: list.scrollWidth, client: list.clientWidth },
      };
    });
    expect(widths.row.scroll, "lifecycle row scroll width").toBeLessThanOrEqual(
      widths.row.client,
    );
    expect(widths.list.scroll, "message list scroll width").toBeLessThanOrEqual(
      widths.list.client,
    );
    expect(await documentWidth(), "document with lifecycle row").toBe(390);
  },
);
