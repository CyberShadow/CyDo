import { test, expect } from "./fixtures";

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

test("page loads and shows CyDo branding", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator(".welcome-page-header h1")).toContainText("CyDo", {
    timeout: 10_000,
  });
});

test("basic message and response", async ({ page }) => {
  const tid = await createClaudeTask();
  await page.goto(`/task/${tid}`);

  // Wait for the input to be enabled (means WebSocket is connected)
  const input = page.locator(".input-textarea");
  await expect(input).toBeEnabled({ timeout: 10_000 });
  await input.fill('Please reply with "OK"');

  // Send the message
  await page.getByRole("button", { name: "Send" }).click();

  // The user message should appear
  await expect(page.locator(".message.user-message")).toBeVisible({
    timeout: 15_000,
  });

  // Wait for the assistant response containing "OK"
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "OK" }),
  ).toBeVisible({ timeout: 30_000 });
});

test("tool call flow", async ({ page }) => {
  const tid = await createClaudeTask();
  await page.goto(`/task/${tid}`);

  // Wait for the input to be enabled (means WebSocket is connected)
  const input = page.locator(".input-textarea");
  await expect(input).toBeEnabled({ timeout: 10_000 });
  await input.fill("Please run command echo hello-from-test");
  await page.getByRole("button", { name: "Send" }).click();

  // Tool call should appear with the Bash tool name
  await expect(
    page.locator(".tool-name", { hasText: "Bash" }),
  ).toBeVisible({ timeout: 30_000 });

  // Tool result should show the command output
  await expect(
    page.locator(".tool-result", { hasText: "hello-from-test" }),
  ).toBeVisible({ timeout: 30_000 });

  // Final "Done." response
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "Done.",
    }),
  ).toBeVisible({ timeout: 30_000 });
});
