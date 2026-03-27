import { test, expect } from "./fixtures";

async function stubConnectingWebSocket(
  page: import("@playwright/test").Page,
  theme?: "dark" | "light",
) {
  await page.addInitScript((selectedTheme) => {
    if (selectedTheme) {
      localStorage.setItem("theme", selectedTheme);
    }

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (window as any).WebSocket = function StubWS(url: string) {
      this.url = url;
      this.readyState = 0; // CONNECTING — never advances
      this.binaryType = "arraybuffer";
      this.bufferedAmount = 0;
      this.extensions = "";
      this.protocol = "";
      this.onopen = null;
      this.onclose = null;
      this.onerror = null;
      this.onmessage = null;
      this.send = () => {};
      this.close = () => {};
    };
  }, theme);
}

test("should show connection overlay on welcome page while connecting", async ({
  page,
  agentType,
}) => {
  test.skip(
    agentType !== "claude",
    "agent-agnostic, runs in claude project only",
  );

  // Stub WebSocket so the app stays in "connecting" state indefinitely.
  // The real WS connects to localhost in milliseconds, which is too fast
  // to catch with a page.goto + assertion. By replacing WebSocket with a
  // no-op stub, connected stays false and the overlay remains visible.
  await stubConnectingWebSocket(page);

  await page.goto("/");

  // The overlay is rendered when !connected. With the stub in place the
  // connection never completes so connected stays false indefinitely.
  await expect(page.locator(".connection-overlay")).toBeVisible({
    timeout: 5_000,
  });
});

test("should use the selected light theme while connecting", async ({
  page,
  agentType,
}) => {
  test.skip(
    agentType !== "claude",
    "agent-agnostic, runs in claude project only",
  );

  await stubConnectingWebSocket(page, "light");
  await page.goto("/");

  const overlay = page.locator(".connection-overlay");
  await expect(overlay).toBeVisible({ timeout: 5_000 });

  await expect
    .poll(async () =>
      page.evaluate(() => document.documentElement.dataset.theme),
    )
    .toBe("light");

  const styles = await overlay.evaluate((element) => {
    const overlayStyle = getComputedStyle(element);
    const appStyle = getComputedStyle(document.body);
    return {
      overlayBackground: overlayStyle.backgroundColor,
      appBackground: appStyle.backgroundColor,
    };
  });

  expect(styles.overlayBackground).toBe(styles.appBackground);
});
