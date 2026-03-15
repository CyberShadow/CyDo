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

async function enterProject(page: Page) {
  const tid = await createClaudeTask();
  await page.goto(`/task/${tid}`);
  await expect(page.locator(".input-textarea:visible").first()).toBeEnabled({
    timeout: 10_000,
  });
}

async function sendMessage(page: Page, text: string) {
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled({ timeout: 10_000 });
  await input.fill(text);
  await page.locator(".btn-send:visible").first().click();
}

async function killSession(page: Page) {
  await page.locator(".btn-banner-stop").click();
  await expect(page.locator(".btn-resume")).toBeVisible({ timeout: 10_000 });
}

test("undo moves user message text to input box", async ({ page }) => {
  await enterProject(page);

  // Send first message and wait for reply
  await sendMessage(page, 'Please reply with "first-reply"');
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "first-reply",
    }),
  ).toBeVisible({ timeout: 30_000 });

  // Send second message and wait for reply
  await sendMessage(page, 'Please reply with "second-reply"');
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "second-reply",
    }),
  ).toBeVisible({ timeout: 30_000 });

  // Kill session so JSONL is finalized and undo buttons appear
  await killSession(page);

  // Wait for history reload (messages from JSONL)
  await expect(
    page.locator(".message.user-message", { hasText: "second-reply" }),
  ).toBeVisible({ timeout: 15_000 });

  // Hover the second user message to reveal the undo button
  const secondUserMsg = page
    .locator(".message-wrapper", {
      has: page.locator(".user-message", { hasText: "second-reply" }),
    })
    .last();
  await secondUserMsg.hover();

  // Click undo
  await expect(secondUserMsg.locator(".undo-btn")).toBeVisible({
    timeout: 5_000,
  });
  await secondUserMsg.locator(".undo-btn").click();

  // Confirm undo dialog (revert conversation checked by default)
  await expect(page.locator(".undo-dialog")).toBeVisible({ timeout: 5_000 });
  await page.locator(".btn-undo").click();

  // After undo, the session auto-resumes. Wait for the input box to appear
  // (replaces the Resume button once the session is alive).
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeVisible({ timeout: 15_000 });

  // The second user message should be gone (or only remain as a pending placeholder
  // from an orphaned queue-operation enqueue that survived JSONL truncation)
  await expect(
    page.locator(".message.user-message:not(.pending)", { hasText: "second-reply" }),
  ).not.toBeVisible({ timeout: 15_000 });

  // The first message should still be there
  await expect(
    page.locator(".message.user-message", { hasText: "first-reply" }),
  ).toBeVisible({ timeout: 15_000 });

  // The input box should contain the undone message text
  await expect(input).toHaveValue(/reply with "second-reply"/, {
    timeout: 15_000,
  });
});
