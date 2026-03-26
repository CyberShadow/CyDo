import { test, expect } from "./fixtures";

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
  await page.addInitScript(() => {
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
  });

  await page.goto("/");

  // The overlay is rendered when !connected. With the stub in place the
  // connection never completes so connected stays false indefinitely.
  await expect(page.locator(".connection-overlay")).toBeVisible({
    timeout: 5_000,
  });
});
