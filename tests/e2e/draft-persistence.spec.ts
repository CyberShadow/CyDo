import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
  responseTimeout,
  assistantText,
  currentTaskTid,
} from "./fixtures";

test("ordinary draft persists across an immediate page reload", async ({
  page,
  agentType,
}) => {
  await enterSession(page);

  // Send a message to establish the session and generate a title
  await sendMessage(page, 'Please reply with "draft-reload-test"');
  await expect(assistantText(page, "draft-reload-test")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // Reload immediately after typing, before OrdinaryInputBox's 500 ms save
  // debounce can run.
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill("my unsent draft");

  // Reload the page and navigate back to the task via sidebar
  await page.reload();
  await page
    .locator(".sidebar-item .sidebar-label", { hasText: "draft-reload-test" })
    .click();

  // Wait for the input to appear and check the draft was restored
  const restoredInput = page.locator(".input-textarea:visible").first();
  await expect(restoredInput).toBeVisible();
  await expect(restoredInput).toHaveValue("my unsent draft");
});

test("controlled pending draft persists across an immediate page reload", async ({
  page,
}) => {
  await enterSession(page);

  const input = page.locator(".input-textarea:visible").first();
  await input.fill("pending draft before its final edit");

  // Wait only for the new task to exist. Its task-type picker confirms this
  // remains the controlled pending-task composer rather than OrdinaryInputBox.
  await expect(page).toHaveURL(/\/task\/\d+/, { timeout: 15_000 });
  await expect(page.locator(".task-type-row.selected")).toBeVisible({
    timeout: 15_000,
  });
  const tid = currentTaskTid(page);

  // This edit schedules the controlled draft save for 500 ms later. Reload
  // straight away so the assertion requires an unload-time flush.
  await input.fill("pending draft typed immediately before reload");
  await page.reload();
  await page.locator(`.sidebar-item[data-tid="${tid}"]`).click({
    timeout: 15_000,
  });

  const restoredInput = page.locator(".input-textarea:visible").first();
  await expect(restoredInput).toBeVisible({ timeout: 15_000 });
  await expect(restoredInput).toHaveValue(
    "pending draft typed immediately before reload",
  );
});

test("server clears the persisted draft after accepting its first message", async ({
  page,
  agentType,
}) => {
  const sent: Array<{ type: string; tid?: number; content?: string }> = [];
  const received: Array<{ type: string; tid?: number; new_draft?: string }> =
    [];
  page.on("websocket", (socket) => {
    if (!socket.url().endsWith("/ws")) return;
    socket.on("framesent", ({ payload }) =>
      sent.push(JSON.parse(payload.toString())),
    );
    socket.on("framereceived", ({ payload }) =>
      received.push(JSON.parse(payload.toString())),
    );
  });
  await enterSession(page);

  const prompt = 'Please reply with "draft-clear-test"';
  const input = page.locator(".input-textarea:visible");
  await input.fill(prompt);
  await expect(page).toHaveURL(/\/task\/\d+/, { timeout: 15_000 });
  const tid = currentTaskTid(page);
  await expect
    .poll(() =>
      sent.some(
        (frame) =>
          frame.type === "set_draft" &&
          frame.tid === tid &&
          frame.content === prompt,
      ),
    )
    .toBe(true);

  await page.locator(".btn-send:visible").click();
  await expect
    .poll(() =>
      received.some(
        (frame) =>
          frame.type === "draft_updated" &&
          frame.tid === tid &&
          frame.new_draft === "",
      ),
    )
    .toBe(true);
  await expect(page.locator(".task-type-picker:visible")).toHaveCount(0);
  await expect(input).toHaveValue("");
  expect(
    sent.filter(
      (frame) =>
        frame.type === "set_draft" && frame.tid === tid && frame.content === "",
    ),
  ).toHaveLength(0);

  await expect(assistantText(page, "draft-clear-test")).toBeVisible({
    timeout: responseTimeout(agentType),
  });
  await page.reload();
  await expect(input).toHaveValue("");
});

test("draft syncs to second client via task-list packets", async ({
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

  // Open page 2 — it will get task-list packets with the draft on connect
  const context2 = await browser.newContext();
  const page2 = await context2.newPage();
  await page2.goto(page.url());

  // Page 2 selects the task via sidebar
  await page2
    .locator(".sidebar-item .sidebar-label", { hasText: "draft-sync-test" })
    .click();

  // Page 2 should see the draft hydrated from the task-list packets
  const input2 = page2.locator(".input-textarea:visible").first();
  await expect(input2).toBeVisible();
  await expect(input2).toHaveValue("synced draft text");

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
    .click();
  const input2 = page2.locator(".input-textarea:visible").first();
  await expect(input2).toBeVisible();

  // Page 2 input should be empty initially
  await expect(input2).toHaveValue("");

  // Type a draft on page 1
  const input1 = page.locator(".input-textarea:visible").first();
  await input1.click();
  await input1.fill("live broadcast draft");

  // Wait for debounce + broadcast
  await page.waitForTimeout(1500);

  // Page 2 should receive the draft via draft_updated broadcast
  await expect(input2).toHaveValue("live broadcast draft");

  await context2.close();
});

test("draft broadcast accepts a peer update after its local text saves", async ({
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
    .click();
  const input2 = page2.locator(".input-textarea:visible").first();
  await expect(input2).toBeVisible();

  // Page 2 types something first
  await input2.click();
  await input2.fill("page2 is typing");

  // Focusing page 1 blurs page 2 and saves its local text before page 1
  // replaces it.
  const input1 = page.locator(".input-textarea:visible").first();
  await input1.click();
  await input1.fill("page1 draft");

  // Wait for debounce + broadcast
  await page.waitForTimeout(1500);

  // Page 2's local text matches old_draft, so it accepts the replacement.
  await expect(input2).toHaveValue("page1 draft");

  await context2.close();
});
