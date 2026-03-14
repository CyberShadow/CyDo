import { test, expect, Page } from "./fixtures";

const CYDO_WS_URL = "ws://localhost:3456/ws";

/** Create a Codex task via direct WebSocket and return its tid. */
async function createCodexTask(): Promise<number> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(CYDO_WS_URL);
    ws.onopen = () => {
      ws.send(
        JSON.stringify({
          type: "create_task",
          workspace: "",
          project_path: "",
          task_type: "",
          content: "",
          agent_type: "codex",
        }),
      );
    };
    ws.binaryType = "arraybuffer";
    ws.onmessage = (event) => {
      try {
        const text = typeof event.data === "string"
          ? event.data
          : new TextDecoder().decode(event.data as ArrayBuffer);
        const msg = JSON.parse(text);
        if (msg.type === "task_created") {
          ws.close();
          resolve(msg.tid);
        }
      } catch {}
    };
    ws.onerror = () => reject(new Error("WebSocket error creating Codex task"));
    setTimeout(() => reject(new Error("Timeout creating Codex task")), 10_000);
  });
}

/** Send a message in the currently visible task view. */
async function sendMessage(page: Page, text: string) {
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled({ timeout: 15_000 });
  await input.click();
  await input.fill(text);
  const sendBtn = page.locator(".btn-send:visible").first();
  try {
    await expect(sendBtn).toBeEnabled({ timeout: 2_000 });
  } catch {
    await input.clear();
    await input.pressSequentially(text);
    await expect(sendBtn).toBeEnabled({ timeout: 2_000 });
  }
  await sendBtn.click();
}

/** Kill the active session and wait for the resume button to appear. */
async function killSession(page: Page) {
  await page.locator(".btn-banner-stop").click();
  await expect(page.locator(".btn-resume")).toBeVisible({ timeout: 15_000 });
}

test("codex history survives page reload", async ({ page }) => {
  const tid = await createCodexTask();
  await page.goto(`/task/${tid}`);

  await sendMessage(page, 'Please reply with "persistent-codex"');

  // Wait for response
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "persistent-codex" }),
  ).toBeVisible({ timeout: 60_000 });

  // Kill the session so JSONL is finalized
  await killSession(page);

  // After kill, messages are reloaded from JSONL — wait for them
  await expect(
    page.locator(".message.user-message", { hasText: "persistent-codex" }),
  ).toBeVisible({ timeout: 15_000 });

  // Reload the page
  await page.reload();

  // Click on the session in the sidebar (should appear after reconnect)
  await page
    .locator(".sidebar-item .sidebar-label", { hasText: 'Please reply with "persistent-codex"' })
    .click({ timeout: 15_000 });

  // Messages should still be present after reload (loaded from JSONL)
  await expect(
    page.locator(".message.user-message", { hasText: "persistent-codex" }),
  ).toBeVisible({ timeout: 15_000 });
});

test("codex no duplicate messages after reload", async ({ page }) => {
  const tid = await createCodexTask();
  await page.goto(`/task/${tid}`);

  await sendMessage(page, 'Please reply with "nodups-codex"');

  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "nodups-codex" }),
  ).toBeVisible({ timeout: 60_000 });

  // Kill session so JSONL is finalized
  await killSession(page);

  // After kill, messages are reloaded from JSONL
  await expect(
    page.locator(".message.user-message", { hasText: "nodups-codex" }),
  ).toBeVisible({ timeout: 15_000 });
  const countBefore = await page.locator(".message.user-message").count();

  // Reload
  await page.reload();
  await page
    .locator(".sidebar-item .sidebar-label", { hasText: 'Please reply with "nodups-codex"' })
    .click({ timeout: 15_000 });

  // Wait for messages to load from JSONL
  await expect(
    page.locator(".message.user-message", { hasText: "nodups-codex" }),
  ).toBeVisible({ timeout: 15_000 });

  // Message count should not increase (no duplicates)
  const countAfter = await page.locator(".message.user-message").count();
  expect(countAfter).toBeLessThanOrEqual(countBefore);
});

test("codex session stop shows resume button", async ({ page }) => {
  const tid = await createCodexTask();
  await page.goto(`/task/${tid}`);

  await sendMessage(page, 'Please reply with "before-stop-codex"');

  // Wait for response
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "before-stop-codex" }),
  ).toBeVisible({ timeout: 60_000 });

  // Kill the session
  await killSession(page);

  // Resume button should be visible
  await expect(page.locator(".btn-resume")).toBeVisible();
});

test("codex session resume continues conversation", async ({ page }) => {
  const tid = await createCodexTask();
  await page.goto(`/task/${tid}`);

  await sendMessage(page, 'Please reply with "pre-resume-codex"');

  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "pre-resume-codex" }),
  ).toBeVisible({ timeout: 60_000 });

  // Kill the session
  await killSession(page);

  // Resume
  await page.locator(".btn-resume").click();

  // Wait for the session to be fully active (Kill button means process is alive)
  await expect(page.locator(".btn-banner-stop")).toBeVisible({ timeout: 30_000 });

  // Wait for the resume processing to complete
  await expect(page.locator(".btn-stop")).not.toBeVisible({ timeout: 30_000 });

  // Send a new message
  const input = page.locator(".input-textarea").first();
  await expect(input).toBeVisible({ timeout: 5_000 });
  await input.click();
  await input.fill('Please reply with "post-resume-codex"');
  await expect(page.locator(".btn-send").first()).toBeEnabled({ timeout: 5_000 });
  await page.locator(".btn-send").first().click();

  // New response should appear
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "post-resume-codex" }),
  ).toBeVisible({ timeout: 60_000 });
});
