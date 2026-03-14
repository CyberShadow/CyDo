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

test("codex session creation shows sidebar entry", async ({ page }) => {
  const tid = await createCodexTask();
  await page.goto(`/task/${tid}`);

  await sendMessage(page, 'Please reply with "hello"');

  // A new sidebar item should appear with the message as title
  await expect(
    page.locator(".sidebar-item .sidebar-label", { hasText: 'Please reply with "hello"' }),
  ).toBeVisible({ timeout: 30_000 });

  // The session view should show this user message
  await expect(
    page.locator(".message.user-message", { hasText: 'Please reply with "hello"' }),
  ).toBeVisible({ timeout: 15_000 });
});

test("codex session switching preserves messages", async ({ page }) => {
  // Create first Codex task
  const tid1 = await createCodexTask();
  await page.goto(`/task/${tid1}`);

  await sendMessage(page, 'Please reply with "first-codex"');
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "first-codex" }),
  ).toBeVisible({ timeout: 60_000 });

  // Create second Codex task
  const tid2 = await createCodexTask();
  await page.goto(`/task/${tid2}`);

  await sendMessage(page, 'Please reply with "second-codex"');
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "second-codex" }),
  ).toBeVisible({ timeout: 60_000 });

  // Switch back to first task via sidebar
  await page
    .locator(".sidebar-item .sidebar-label", { hasText: 'Please reply with "first-codex"' })
    .click();

  // First task's messages should be visible
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "first-codex" }),
  ).toBeVisible({ timeout: 10_000 });

  // Second task's response should NOT be visible
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "second-codex" }),
  ).not.toBeVisible();
});
