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

/** Create a task and navigate directly to its URL. */
async function enterProject(page: Page) {
  const tid = await createClaudeTask();
  await page.goto(`/task/${tid}`);
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

/** Kill the active session and wait for the resume button to appear. */
async function killSession(page: Page) {
  await page.locator(".btn-banner-stop").click();
  await expect(page.locator(".btn-resume")).toBeVisible({ timeout: 10_000 });
}

test("history survives page reload", async ({ page }) => {
  await enterProject(page);
  await sendMessage(page, 'Please reply with "persistent"');

  // Wait for response
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "persistent" }),
  ).toBeVisible({ timeout: 30_000 });

  // Kill the session so JSONL is finalized
  await killSession(page);

  // After kill, messages are reloaded from JSONL — wait for them
  await expect(
    page.locator(".message.user-message", { hasText: "persistent" }),
  ).toBeVisible({ timeout: 15_000 });

  // Reload the page
  await page.reload();

  // Click on the session in the sidebar (should appear after reconnect)
  await page
    .locator(".sidebar-item .sidebar-label", { hasText: 'Please reply with "persistent"' })
    .click({ timeout: 15_000 });

  // Messages should still be present after reload (loaded from JSONL)
  await expect(
    page.locator(".message.user-message", { hasText: "persistent" }),
  ).toBeVisible({ timeout: 15_000 });
});

test("no duplicate messages after reload", async ({ page }) => {
  await enterProject(page);
  await sendMessage(page, 'Please reply with "nodups"');

  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "nodups" }),
  ).toBeVisible({ timeout: 30_000 });

  // Kill session so JSONL is finalized
  await killSession(page);

  // After kill, messages are reloaded from JSONL — wait for them
  await expect(
    page.locator(".message.user-message", { hasText: "nodups" }),
  ).toBeVisible({ timeout: 15_000 });
  const countBefore = await page.locator(".message.user-message").count();

  // Reload
  await page.reload();
  await page
    .locator(".sidebar-item .sidebar-label", { hasText: 'Please reply with "nodups"' })
    .click({ timeout: 15_000 });

  // Wait for messages to load from JSONL
  await expect(
    page.locator(".message.user-message", { hasText: "nodups" }),
  ).toBeVisible({ timeout: 15_000 });

  // Message count should not increase (no duplicates)
  const countAfter = await page.locator(".message.user-message").count();
  expect(countAfter).toBeLessThanOrEqual(countBefore);
});

test("session stop shows resume button", async ({ page }) => {
  await enterProject(page);
  await sendMessage(page, 'Please reply with "before-stop"');

  // Wait for response
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "before-stop" }),
  ).toBeVisible({ timeout: 30_000 });

  // Kill the session
  await killSession(page);

  // Resume button should be visible
  await expect(page.locator(".btn-resume")).toBeVisible();
});

test("session resume continues conversation", async ({ page }) => {
  await enterProject(page);
  await sendMessage(page, 'Please reply with "pre-resume"');

  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "pre-resume" }),
  ).toBeVisible({ timeout: 30_000 });

  // Kill the session
  await killSession(page);

  // Resume
  await page.locator(".btn-resume").click();

  // Wait for the session to be fully active (Kill button means Claude process is alive)
  await expect(page.locator(".btn-banner-stop")).toBeVisible({ timeout: 15_000 });

  // Wait for the resume processing turn to complete before sending a new message.
  // During resume, Claude re-sends conversation to the API. The InputBox "Stop" button
  // appears during processing and disappears when the turn ends.
  await expect(page.locator(".btn-stop")).not.toBeVisible({ timeout: 15_000 });

  // Send a new message — target the InputBox directly since :visible may not
  // work reliably with display:contents parent
  const input = page.locator(".input-textarea").first();
  await expect(input).toBeVisible({ timeout: 5_000 });
  await input.click();
  await input.fill('Please reply with "post-resume"');
  await expect(page.locator(".btn-send").first()).toBeEnabled({ timeout: 5_000 });
  await page.locator(".btn-send").first().click();

  // New response should appear
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "post-resume" }),
  ).toBeVisible({ timeout: 30_000 });
});
