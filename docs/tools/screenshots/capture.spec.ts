import { test } from '@playwright/test';

const OUTPUT_DIR = process.env.SCREENSHOT_OUTPUT || '/tmp/screenshots';

test('main-page', async ({ page }) => {
  await page.goto('/');
  // Wait for welcome page with project list
  await page.locator('.welcome-page-header h1').waitFor({ state: 'visible', timeout: 30_000 });
  await page.screenshot({ path: `${OUTPUT_DIR}/main-page.png` });
});

test('conversation', async ({ page }) => {
  // Navigate to the cydo project in the open-source workspace
  await page.goto('/open-source/cydo');

  // Wait for the child-less conversation task to appear (alive after resume)
  await page.locator('.sidebar-item[data-tid="9060"]')
    .waitFor({ state: 'visible', timeout: 60_000 });

  // Wait for the alive status icon
  await page.locator('.sidebar-item[data-tid="9060"] .task-type-icon.alive')
    .waitFor({ state: 'visible', timeout: 30_000 });

  // Click on the task to view conversation
  await page.locator('.sidebar-item[data-tid="9060"]').click();

  // Wait for conversation messages to load
  await page.locator('.message.assistant-message').first()
    .waitFor({ state: 'visible', timeout: 30_000 });

  // Wait for suggestion buttons (generated after subscribe, once task is alive)
  await page.locator('.btn-suggestion').first()
    .waitFor({ state: 'visible', timeout: 60_000 });

  await page.screenshot({ path: `${OUTPUT_DIR}/conversation.png` });
});

test('file-viewer', async ({ page }) => {
  // Navigate to the ae project in the open-source workspace
  await page.goto('/open-source/ae');

  // Wait for task 1039 to appear in the sidebar (alive after resume)
  await page.locator('.sidebar-item[data-tid="1039"]')
    .waitFor({ state: 'visible', timeout: 60_000 });
  await page.locator('.sidebar-item[data-tid="1039"] .task-type-icon.alive')
    .waitFor({ state: 'visible', timeout: 30_000 });
  await page.locator('.sidebar-item[data-tid="1039"]').click();

  // Wait for messages to load
  await page.locator('.message.assistant-message').first()
    .waitFor({ state: 'visible', timeout: 30_000 });

  // Find the first Edit tool call that has an eye icon
  const editToolCall = page.locator('.tool-call:has(.tool-view-file)', { hasText: 'Edit' }).first();
  await editToolCall.locator('.tool-header').hover();
  await editToolCall.locator('.tool-view-file').click({ force: true });

  // Wait for file viewer to open
  await page.locator('.file-viewer').waitFor({ state: 'visible', timeout: 10_000 });

  // Switch to Diff tab for more visually interesting view
  const diffTab = page.locator('.file-viewer').getByText('Diff', { exact: true });
  if (await diffTab.count() > 0) {
    await diffTab.click();
    await page.waitForTimeout(500);
  }

  await page.screenshot({ path: `${OUTPUT_DIR}/file-viewer.png` });
});

test('search', async ({ page }) => {
  // Navigate to conversation view first for a richer background
  await page.goto('/open-source/cydo');

  // Wait for task 9060 to appear and click it
  await page.locator('.sidebar-item[data-tid="9060"]')
    .waitFor({ state: 'visible', timeout: 60_000 });
  await page.locator('.sidebar-item[data-tid="9060"]').click();
  await page.locator('.message.assistant-message').first()
    .waitFor({ state: 'visible', timeout: 30_000 });

  // Open search popup
  await page.keyboard.press('Control+k');
  await page.locator('.search-popup').waitFor({ state: 'visible', timeout: 5_000 });

  // Type a query that matches tasks across workspaces
  await page.locator('.search-input').fill('implement');

  // Wait for search results to populate
  await page.locator('.search-result-item').first()
    .waitFor({ state: 'visible', timeout: 5_000 });

  await page.screenshot({ path: `${OUTPUT_DIR}/search.png` });
});

test('tool-calls', async ({ page }) => {
  // Navigate to the cydo project and open the implement task with tool calls
  await page.goto('/open-source/cydo');

  // Wait for the implement task (tid 1700) to appear — becomes processing after resume
  await page.locator('.sidebar-item[data-tid="1700"]')
    .waitFor({ state: 'visible', timeout: 60_000 });
  await page.locator('.sidebar-item[data-tid="1700"]').click();

  // Wait for tool call elements to render (Edit, Bash, etc.)
  await page.locator('.tool-call').first()
    .waitFor({ state: 'visible', timeout: 30_000 });

  // Scroll down to show a mix of tool calls (edits and bash commands)
  const toolCalls = page.locator('.tool-call');
  const count = await toolCalls.count();
  if (count > 4) {
    // Scroll to show tool calls in the middle of the session
    await toolCalls.nth(Math.min(4, count - 1)).scrollIntoViewIfNeeded();
    await page.waitForTimeout(300);
  }

  await page.screenshot({ path: `${OUTPUT_DIR}/tool-calls.png` });
});

// ── Mobile screenshots (portrait) ────────────────────────────────

test('mobile-file-viewer', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });

  // Navigate to the ae project — same task as desktop file-viewer
  await page.goto('/open-source/ae');

  // On mobile, sidebar is hidden. Open it via hamburger, select task, it auto-closes.
  await page.locator('.hamburger-btn').first()
    .waitFor({ state: 'visible', timeout: 30_000 });
  await page.locator('.hamburger-btn').first().click();
  await page.locator('.sidebar').waitFor({ state: 'visible', timeout: 5_000 });

  await page.locator('.sidebar-item[data-tid="1039"]')
    .waitFor({ state: 'visible', timeout: 60_000 });
  await page.locator('.sidebar-item[data-tid="1039"]').click();

  // Sidebar auto-closes on task select; wait for conversation messages
  await page.locator('.message.assistant-message').first()
    .waitFor({ state: 'visible', timeout: 30_000 });

  await page.screenshot({ path: `${OUTPUT_DIR}/mobile-conversation.png` });
});

test('mobile-sidebar', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });

  // Navigate to the cydo project — same task as desktop conversation
  await page.goto('/open-source/cydo');

  // Open sidebar, select task (auto-closes), then reopen sidebar for screenshot
  await page.locator('.hamburger-btn').first()
    .waitFor({ state: 'visible', timeout: 30_000 });
  await page.locator('.hamburger-btn').first().click();
  await page.locator('.sidebar').waitFor({ state: 'visible', timeout: 5_000 });

  await page.locator('.sidebar-item[data-tid="9060"]')
    .waitFor({ state: 'visible', timeout: 60_000 });
  await page.locator('.sidebar-item[data-tid="9060"]').click();

  // Wait for messages to load in background
  await page.locator('.message.assistant-message').first()
    .waitFor({ state: 'visible', timeout: 30_000 });

  // Reopen sidebar for the screenshot
  await page.locator('.system-banner .hamburger-btn')
    .waitFor({ state: 'visible', timeout: 5_000 });
  await page.locator('.system-banner .hamburger-btn').click();
  await page.locator('.sidebar').waitFor({ state: 'visible', timeout: 5_000 });

  await page.screenshot({ path: `${OUTPUT_DIR}/mobile-sidebar.png` });
});
