import { request as httpRequest } from "http";
import { test, expect } from "./fixtures";

test.use({
  backendEnv: {
    CYDO_AUTH_USER: "user",
    CYDO_AUTH_PASS: "test-pass",
  },
  httpCredentials: {
    username: "user",
    password: "test-pass",
  },
});

/** Attempt a bare WebSocket upgrade handshake with exactly the given extra
 *  headers, resolving with the HTTP status the server answered. */
function upgradeStatus(headers: Record<string, string>): Promise<number> {
  return new Promise((resolve, reject) => {
    const req = httpRequest({
      host: "localhost",
      port: 3940,
      path: "/ws",
      headers: {
        Connection: "Upgrade",
        Upgrade: "websocket",
        "Sec-WebSocket-Version": "13",
        "Sec-WebSocket-Key": "AAAAAAAAAAAAAAAAAAAAAA==",
        ...headers,
      },
    });
    req.on("upgrade", (res, socket) => {
      socket.destroy();
      resolve(res.statusCode ?? 0);
    });
    req.on("response", (res) => {
      res.destroy();
      resolve(res.statusCode ?? 0);
    });
    req.on("error", reject);
    req.end();
  });
}

test(
  "websocket upgrade authenticates via the session cookie alone",
  { tag: "@claude-only" },
  async ({ page }) => {
    await page.goto("/");
    await expect(page.locator('button[title="New task"]').first()).toBeVisible({
      timeout: 15_000,
    });

    const cookies = await page.context().cookies();
    const auth = cookies.find((cookie) => cookie.name === "cydo_auth");
    expect(auth).toBeTruthy();

    // WebKit on old iOS Safari omits the Authorization header on upgrade
    // requests, so the cookie must carry the handshake entirely on its own.
    expect(await upgradeStatus({ Cookie: `cydo_auth=${auth!.value}` })).toBe(
      101,
    );

    // And the cookie is load-bearing: an upgrade with no credentials at all
    // stays rejected.
    expect(await upgradeStatus({})).toBe(401);
  },
);
