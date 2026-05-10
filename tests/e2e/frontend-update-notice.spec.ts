import { test, expect } from "./fixtures";

// Verifies the frontend_update notice flow end-to-end. The test forces the
// browser-loaded script-tag hash to differ from the hash the backend reads
// from web/dist/index.html when building server_status, by intercepting the
// SPA root request and rewriting the script src to a known fake hash. The
// fake JS URL is then routed to the real one so the app actually runs.
test("frontend update notice appears on build hash mismatch", { tag: "@claude-only" }, async ({
  page,
  agentType,
}) => {

  const fakeHash = "faketestbuildhash";
  let realHash: string | null = null;

  await page.route("**/*", async (route) => {
    const url = new URL(route.request().url());
    if (url.pathname === "/") {
      const response = await route.fetch();
      let html = await response.text();
      const m = html.match(/\/assets\/index-([^.]+)\.js/);
      if (m) {
        realHash = m[1];
        html = html.replace(
          /\/assets\/index-[^.]+\.js/,
          `/assets/index-${fakeHash}.js`,
        );
      }
      await route.fulfill({
        body: html,
        contentType: "text/html",
      });
      return;
    }
    if (
      realHash !== null &&
      url.pathname.startsWith(`/assets/index-${fakeHash}.js`)
    ) {
      const newUrl = route
        .request()
        .url()
        .replace(fakeHash, realHash);
      await route.continue({ url: newUrl });
      return;
    }
    await route.continue();
  });

  await page.goto("/");

  const notice = page.locator(".notice-item", {
    hasText: /outdated CyDo UI/i,
  });
  await expect(notice).toBeVisible({ timeout: 15_000 });

  const reloadButton = notice.locator("button.notice-action-button");
  await expect(reloadButton).toHaveText(/reload/i);

  // Clicking Reload should trigger a navigation. The route handler stays
  // attached, so after reload the mismatch persists and the notice is
  // visible again — which proves the reload actually fired.
  const navigated = page.waitForEvent("framenavigated");
  await reloadButton.click();
  await navigated;
  await expect(notice).toBeVisible({ timeout: 15_000 });
});
