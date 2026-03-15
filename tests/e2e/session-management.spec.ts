import { test, expect, Page } from "./fixtures";

const CYDO_WS_URL = "ws://localhost:3456/ws";

async function createClaudeTask(): Promise<number> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(CYDO_WS_URL);
    ws.onopen = () => {
      ws.send(JSON.stringify({ type: "create_task", workspace: "", project_path: "", task_type: "", content: "", agent_type: "claude" }));
    };
    ws.binaryType = "arraybuffer";
    ws.onmessage = (event) => {
      try {
        const text = typeof event.data === "string" ? event.data : new TextDecoder().decode(event.data as ArrayBuffer);
        const msg = JSON.parse(text);
        if (msg.type === "task_created") { ws.close(); resolve(msg.tid); }
      } catch {}
    };
    ws.onerror = () => reject(new Error("WebSocket error creating Claude task"));
    setTimeout(() => reject(new Error("Timeout creating Claude task")), 10_000);
  });
}

/** Send a message from whichever input is currently visible. */
async function sendMessage(page: Page, text: string) {
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled({ timeout: 10_000 });
  await input.click();
  await input.fill(text);
  const sendBtn = page.locator(".btn-send:visible").first();
  // Wait for the controlled component to update (fill may not trigger onInput reliably)
  try {
    await expect(sendBtn).toBeEnabled({ timeout: 2_000 });
  } catch {
    // Fallback: clear and type character by character
    await input.clear();
    await input.pressSequentially(text);
    await expect(sendBtn).toBeEnabled({ timeout: 2_000 });
  }
  await sendBtn.click();
}

test("session creation shows sidebar entry", async ({ page }) => {
  const tid = await createClaudeTask();
  await page.goto(`/task/${tid}`);
  await expect(page.locator(".input-textarea:visible").first()).toBeEnabled({ timeout: 10_000 });
  await sendMessage(page, 'Please reply with "hello-claude"');

  // A new sidebar item should appear with the message as title
  await expect(
    page.locator(".sidebar-item .sidebar-label", { hasText: 'Please reply with "hello-claude"' }),
  ).toBeVisible({ timeout: 15_000 });

  // The session view should show this user message
  await expect(
    page.locator(".message.user-message", { hasText: 'Please reply with "hello-claude"' }),
  ).toBeVisible({ timeout: 15_000 });
});

test("session switching preserves messages", async ({ page }) => {
  // Create both tasks upfront so each gets a known URL
  const tid1 = await createClaudeTask();
  const tid2 = await createClaudeTask();

  // Send first message in task 1
  await page.goto(`/task/${tid1}`);
  await expect(page.locator(".input-textarea:visible").first()).toBeEnabled({ timeout: 10_000 });
  await sendMessage(page, 'Please reply with "first"');
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "first" }),
  ).toBeVisible({ timeout: 30_000 });

  // Send second message in task 2
  await page.goto(`/task/${tid2}`);
  await expect(page.locator(".input-textarea:visible").first()).toBeEnabled({ timeout: 10_000 });
  await sendMessage(page, 'Please reply with "second"');
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "second" }),
  ).toBeVisible({ timeout: 30_000 });

  // Switch back to first task via sidebar
  await page
    .locator(".sidebar-item .sidebar-label", { hasText: 'Please reply with "first"' })
    .click();

  // First task's messages should be visible
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "first" }),
  ).toBeVisible({ timeout: 10_000 });

  // Second task's response should NOT be visible
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "second" }),
  ).not.toBeVisible();
});

test("build artifact sanity: hashed asset references", async ({ page }) => {
  const response = await page.goto("/");
  const html = await response!.text();

  // Vite produces hashed filenames like index-XXXXXXXX.js and index-XXXXXXXX.css
  expect(html).toMatch(/\/assets\/index-[A-Za-z0-9_-]+\.js/);
  expect(html).toMatch(/\/assets\/index-[A-Za-z0-9_-]+\.css/);

  // Must NOT contain raw development references
  expect(html).not.toContain("/src/main.tsx");
});
