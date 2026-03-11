import { test, expect, Page } from "./fixtures";

/** Navigate to the first project and wait for WebSocket connection. */
async function enterProject(page: Page) {
  await page.goto("/");
  await page.locator(".project-card-title").first().click({ timeout: 10_000 });
  await expect(page.locator(".input-textarea:visible").first()).toBeEnabled({
    timeout: 10_000,
  });
}

/** Send a message from whichever input is currently visible. */
async function sendMessage(page: Page, text: string) {
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled({ timeout: 10_000 });
  await input.fill(text);
  await page.locator(".btn-send:visible").first().click();
}

test("sidebar status dot reflects session state", async ({ page }) => {
  await enterProject(page);
  await sendMessage(page, 'Please reply with "dot-test"');

  // While processing, the sidebar dot should have the "processing" class
  const sidebarItem = page.locator(".sidebar-item", {
    hasText: 'Please reply with "dot-test"',
  });
  await expect(sidebarItem).toBeVisible({ timeout: 15_000 });

  // Wait for response — session becomes alive+idle
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "dot-test" }),
  ).toBeVisible({ timeout: 30_000 });

  // The dot should now have the "alive" class (alive and not processing)
  await expect(sidebarItem.locator(".sidebar-dot.alive")).toBeVisible({ timeout: 5_000 });

  // Kill the session
  await page.locator(".btn-banner-stop").click();
  await expect(page.locator(".btn-resume")).toBeVisible({ timeout: 10_000 });

  // After SIGTERM kill, the dot should have the "failed" class
  // (killed sessions have non-zero exit code; sidebar shows "failed" before "resumable")
  await expect(sidebarItem.locator(".sidebar-dot.failed")).toBeVisible({ timeout: 5_000 });
});

test("multi-client navigation isolation", async ({ page, context }) => {
  // Open two tabs connected to the same backend
  const pageA = page;
  const pageB = await context.newPage();

  await enterProject(pageA);
  await enterProject(pageB);

  // Verify both are on the new-task view
  await expect(pageA.locator(".session-empty")).toBeVisible({ timeout: 5_000 });
  await expect(pageB.locator(".session-empty")).toBeVisible({ timeout: 5_000 });

  // Create a task from page A
  await sendMessage(pageA, 'Please reply with "isolation-a"');

  // Page A should navigate to the new session
  await expect(
    pageA.locator(".message.user-message", { hasText: "isolation-a" }),
  ).toBeVisible({ timeout: 15_000 });

  // Page B should still show the new-task view (not auto-navigated)
  await expect(pageB.locator(".session-empty")).toBeVisible({ timeout: 5_000 });

  // Page B's sidebar should show the new session entry though
  await expect(
    pageB.locator(".sidebar-item .sidebar-label", { hasText: 'Please reply with "isolation-a"' }),
  ).toBeVisible({ timeout: 15_000 });

  await pageB.close();
});

test("auto-scroll stays at bottom for new messages", async ({ page }) => {
  await enterProject(page);

  // Send a message and wait for response
  await sendMessage(page, 'Please reply with "scroll-test"');
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "scroll-test" }),
  ).toBeVisible({ timeout: 30_000 });

  // The message list uses column-reverse, so scrollTop=0 means at bottom.
  // After new messages, the scroll should remain at bottom (scrollTop >= -1).
  const scrollTop = await page.locator(".message-list").evaluate(
    (el) => el.scrollTop,
  );
  expect(scrollTop).toBeGreaterThanOrEqual(-1);
});

test("tool result with Bash output renders correctly", async ({ page }) => {
  await enterProject(page);
  await sendMessage(page, "Please run command echo tool-result-test");

  // Tool call block should appear
  await expect(
    page.locator(".tool-name", { hasText: "Bash" }),
  ).toBeVisible({ timeout: 30_000 });

  // Tool result should contain the command output
  await expect(
    page.locator(".tool-result", { hasText: "tool-result-test" }),
  ).toBeVisible({ timeout: 30_000 });

  // Tool header should show the description subtitle
  await expect(
    page.locator(".tool-subtitle", { hasText: "Running command" }),
  ).toBeVisible({ timeout: 5_000 });
});

test("fork stays focused on forked session", async ({ page }) => {
  await enterProject(page);
  await sendMessage(page, 'Please reply with "fork-source"');

  // Wait for response
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "fork-source" }),
  ).toBeVisible({ timeout: 30_000 });

  // Wait for the fork button to become available on the user message.
  // The backend needs to read the JSONL and send forkable_uuids first.
  const userMsg = page.locator(".message-wrapper").filter({
    has: page.locator(".message.user-message", { hasText: "fork-source" }),
  });
  await userMsg.hover();
  const forkBtn = userMsg.locator(".fork-btn");
  await expect(forkBtn).toBeVisible({ timeout: 15_000 });

  // Click fork
  await forkBtn.click();

  // A forked session should appear in the sidebar with "(fork)" suffix
  const forkEntry = page.locator(".sidebar-item .sidebar-label", { hasText: "(fork)" });
  await expect(forkEntry).toBeVisible({ timeout: 10_000 });

  // The forked session should be active (auto-focused)
  const forkSidebarItem = page.locator(".sidebar-item.active", { hasText: "(fork)" });
  await expect(forkSidebarItem).toBeVisible({ timeout: 5_000 });

  // The forked session should show a "Resume Session" button (fork has status "completed")
  await expect(page.locator(".btn-resume")).toBeVisible({ timeout: 5_000 });
});
