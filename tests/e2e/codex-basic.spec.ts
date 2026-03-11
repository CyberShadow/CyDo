import { test, expect } from "./fixtures";

const CYDO_WS_URL = "ws://localhost:3456/ws";

// Helper: create a Codex task via a direct WebSocket connection from Node.js.
// Uses the native WebSocket available in Node 22+.
async function createCodexTaskViaWs(): Promise<number> {
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
    ws.onmessage = (event) => {
      try {
        const msg = JSON.parse(String(event.data));
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

test("codex basic message and response", async ({ page }) => {
  const tid = await createCodexTaskViaWs();
  await page.goto(`/task/${tid}`);

  const input = page.locator(".input-textarea");
  await expect(input).toBeEnabled({ timeout: 15_000 });

  await input.fill('Please reply with "OK"');
  await page.getByRole("button", { name: "Send" }).click();

  await expect(page.locator(".message.user-message")).toBeVisible({
    timeout: 15_000,
  });

  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "OK" }),
  ).toBeVisible({ timeout: 60_000 });
});

test("codex tool call flow", async ({ page }) => {
  const tid = await createCodexTaskViaWs();
  await page.goto(`/task/${tid}`);

  const input = page.locator(".input-textarea");
  await expect(input).toBeEnabled({ timeout: 15_000 });

  await input.fill("Please run command echo hello-from-codex");
  await page.getByRole("button", { name: "Send" }).click();

  // Tool call should appear (Codex shell calls map to Bash tool name)
  await expect(
    page.locator(".tool-name", { hasText: "Bash" }),
  ).toBeVisible({ timeout: 60_000 });

  // Tool result should show the command output
  await expect(
    page.locator(".tool-result", { hasText: "hello-from-codex" }),
  ).toBeVisible({ timeout: 60_000 });

  // Final "Done." response
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "Done.",
    }),
  ).toBeVisible({ timeout: 60_000 });
});

test("codex agent type indicator", async ({ page }) => {
  const tid = await createCodexTaskViaWs();
  await page.goto(`/task/${tid}`);

  const input = page.locator(".input-textarea");
  await expect(input).toBeEnabled({ timeout: 15_000 });

  // Send a message to start the session (agent type shows after session/init)
  await input.fill('reply with "hello"');
  await page.getByRole("button", { name: "Send" }).click();

  // Wait for assistant response (ensures session is fully initialized)
  await expect(
    page.locator(".message.assistant-message"),
  ).toBeVisible({ timeout: 60_000 });

  // The banner should show the "codex" agent indicator
  await expect(page.locator(".banner-agent")).toBeVisible({ timeout: 10_000 });
  await expect(page.locator(".banner-agent")).toContainText("codex", {
    ignoreCase: true,
  });
});
