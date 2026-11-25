import { existsSync, rmSync, writeFileSync } from "node:fs";
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
    const fifo = `/tmp/mobile-overflow-${Math.random().toString(36).slice(2, 10)}`;
    const header = page
      .locator(".message-list .tool-header")
      .filter({
        has: page.locator(".tool-name").getByText("Bash", { exact: true }),
      })
      .filter({ hasText: path });
    const icon = header.locator(".tool-icon");

    const expectNoOverflow = async (phase: string) => {
      await header.scrollIntoViewIfNeeded();
      const widths = await header.evaluate((element) => {
        const list = element.closest(".message-list")!;
        return {
          header: { scroll: element.scrollWidth, client: element.clientWidth },
          list: { scroll: list.scrollWidth, client: list.clientWidth },
        };
      });
      expect(
        widths.header.scroll,
        `Bash header scroll width ${phase}`,
      ).toBeLessThanOrEqual(widths.header.client);
      expect(
        widths.list.scroll,
        `message list scroll width ${phase}`,
      ).toBeLessThanOrEqual(widths.list.client);
      expect(await documentWidth(), `document width ${phase}`).toBe(390);
    };

    try {
      await sendMessage(
        page,
        `run detached command mkfifo ${fifo} && read r < ${fifo} && printf %s ${path} with description ${path}`,
      );
      await expect(icon.getByTitle("Running in background")).toBeVisible();
      await expect.poll(() => existsSync(fifo)).toBe(true);
      await expectNoOverflow("while running");

      writeFileSync(fifo, "release\n");
      await expect(icon.getByTitle(/completed \(exit code 0\)/)).toBeVisible();
      await expectNoOverflow("after completion");
    } finally {
      rmSync(fifo, { force: true });
    }
  },
);
