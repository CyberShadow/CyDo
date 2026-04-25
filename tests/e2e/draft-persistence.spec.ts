import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
  responseTimeout,
  assistantText,
} from "./fixtures";

test("draft persists across page reload", async ({ page, agentType }) => {
  await enterSession(page);

  // Send a message to establish the session and generate a title
  await sendMessage(page, 'Please reply with "draft-reload-test"');
  await expect(assistantText(page, "draft-reload-test")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // Type a draft without sending
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill("my unsent draft");

  // Wait for debounce to fire (500ms) + server round-trip
  await page.waitForTimeout(1000);

  // Reload the page and navigate back to the task via sidebar
  await page.reload();
  await page
    .locator(".sidebar-item .sidebar-label", { hasText: "draft-reload-test" })
    .click({ timeout: 15_000 });

  // Wait for the input to appear and check the draft was restored
  const restoredInput = page.locator(".input-textarea:visible").first();
  await expect(restoredInput).toBeVisible({ timeout: 15_000 });
  await expect(restoredInput).toHaveValue("my unsent draft");
});

test("draft clears after sending message", async ({ page, agentType }) => {
  await enterSession(page);

  // Send a real message (this should clear the draft)
  await sendMessage(page, 'Please reply with "draft-clear-test"');
  await expect(assistantText(page, "draft-clear-test")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // Wait for any draft-clear debounce
  await page.waitForTimeout(1000);

  // Reload and navigate back
  await page.reload();
  await page
    .locator(".sidebar-item .sidebar-label", { hasText: "draft-clear-test" })
    .click({ timeout: 15_000 });

  // Input should be empty (draft was cleared on send)
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeVisible({ timeout: 15_000 });
  await expect(input).toHaveValue("");
});

test("draft syncs to second client via tasks_list", async ({
  page,
  browser,
  agentType,
}) => {
  await enterSession(page);

  // Send a message to establish the session
  await sendMessage(page, 'Please reply with "draft-sync-test"');
  await expect(assistantText(page, "draft-sync-test")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // Type a draft on page 1 (while session is alive, InputBox is visible)
  const input1 = page.locator(".input-textarea:visible").first();
  await input1.click();
  await input1.fill("synced draft text");

  // Wait for debounce to fire and persist to backend
  await page.waitForTimeout(1000);

  // Open page 2 — it will get tasks_list with the draft on connect
  const context2 = await browser.newContext();
  const page2 = await context2.newPage();
  await page2.goto(page.url());

  // Page 2 selects the task via sidebar
  await page2
    .locator(".sidebar-item .sidebar-label", { hasText: "draft-sync-test" })
    .click({ timeout: 15_000 });

  // Page 2 should see the draft hydrated from tasks_list
  const input2 = page2.locator(".input-textarea:visible").first();
  await expect(input2).toBeVisible({ timeout: 15_000 });
  await expect(input2).toHaveValue("synced draft text", { timeout: 5_000 });

  await context2.close();
});

test("draft broadcasts live to subscribed clients", async ({
  page,
  browser,
  agentType,
}) => {
  await enterSession(page);

  // Send a message to establish the session
  await sendMessage(page, 'Please reply with "draft-live-test"');
  await expect(assistantText(page, "draft-live-test")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // Open page 2 on the same task URL before typing the draft
  const url = page.url();
  const context2 = await browser.newContext();
  const page2 = await context2.newPage();
  await page2.goto(url);

  // Page 2 selects the task and waits for InputBox
  await page2
    .locator(".sidebar-item .sidebar-label", { hasText: "draft-live-test" })
    .click({ timeout: 15_000 });
  const input2 = page2.locator(".input-textarea:visible").first();
  await expect(input2).toBeVisible({ timeout: 15_000 });

  // Page 2 input should be empty initially
  await expect(input2).toHaveValue("");

  // Type a draft on page 1
  const input1 = page.locator(".input-textarea:visible").first();
  await input1.click();
  await input1.fill("live broadcast draft");

  // Wait for debounce + broadcast
  await page.waitForTimeout(1500);

  // Page 2 should receive the draft via draft_updated broadcast
  await expect(input2).toHaveValue("live broadcast draft", { timeout: 5_000 });

  await context2.close();
});

test("draft broadcast does not overwrite local typing", async ({
  page,
  browser,
  agentType,
}) => {
  await enterSession(page);

  // Send a message to establish the session
  await sendMessage(page, 'Please reply with "draft-nooverwrite"');
  await expect(assistantText(page, "draft-nooverwrite")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // Open page 2 on the same task URL
  const url = page.url();
  const context2 = await browser.newContext();
  const page2 = await context2.newPage();
  await page2.goto(url);

  // Page 2 selects the task
  await page2
    .locator(".sidebar-item .sidebar-label", { hasText: "draft-nooverwrite" })
    .click({ timeout: 15_000 });
  const input2 = page2.locator(".input-textarea:visible").first();
  await expect(input2).toBeVisible({ timeout: 15_000 });

  // Page 2 types something first
  await input2.click();
  await input2.fill("page2 is typing");

  // Page 1 types something different
  const input1 = page.locator(".input-textarea:visible").first();
  await input1.click();
  await input1.fill("page1 draft");

  // Wait for debounce + broadcast
  await page.waitForTimeout(1500);

  // Page 2 should NOT have its text overwritten — it diverged from the server draft
  await expect(input2).toHaveValue("page2 is typing");

  await context2.close();
});
