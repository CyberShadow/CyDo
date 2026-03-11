import { test, expect, Page } from "@playwright/test";

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

test("codex sidebar status dot reflects session state", async ({ page }) => {
  const tid = await createCodexTask();
  await page.goto(`/task/${tid}`);

  await sendMessage(page, 'Please reply with "dot-test-codex"');

  // While processing, the sidebar dot should have the "processing" class
  const sidebarItem = page.locator(".sidebar-item", {
    hasText: 'Please reply with "dot-test-codex"',
  });
  await expect(sidebarItem).toBeVisible({ timeout: 30_000 });

  // Wait for response — session becomes alive+idle
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "dot-test-codex" }),
  ).toBeVisible({ timeout: 60_000 });

  // The dot should now have the "alive" class (alive and not processing)
  await expect(sidebarItem.locator(".sidebar-dot.alive")).toBeVisible({ timeout: 10_000 });

  // Kill the session
  await page.locator(".btn-banner-stop").click();
  await expect(page.locator(".btn-resume")).toBeVisible({ timeout: 15_000 });

  // After kill, the dot should have the "failed" class
  await expect(sidebarItem.locator(".sidebar-dot.failed")).toBeVisible({ timeout: 10_000 });
});

test("codex fork stays focused on forked session", async ({ page }) => {
  const tid = await createCodexTask();
  await page.goto(`/task/${tid}`);

  await sendMessage(page, 'Please reply with "fork-source-codex"');

  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "fork-source-codex" }),
  ).toBeVisible({ timeout: 60_000 });

  await page.locator(".btn-banner-stop").click();
  await expect(page.locator(".btn-resume")).toBeVisible({ timeout: 15_000 });

  await page.goto(`/task/${tid}`);
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "fork-source-codex" }),
  ).toBeVisible({ timeout: 30_000 });

  const userMsg = page.locator(".message-wrapper").filter({
    has: page.locator(".message.user-message", { hasText: "fork-source-codex" }),
  });
  await userMsg.hover();
  const forkBtn = userMsg.locator(".fork-btn");
  await expect(forkBtn).toBeVisible({ timeout: 15_000 });

  await forkBtn.click();

  const forkEntry = page.locator(".sidebar-item .sidebar-label", { hasText: "(fork)" });
  await expect(forkEntry).toBeVisible({ timeout: 10_000 });

  const forkSidebarItem = page.locator(".sidebar-item.active", { hasText: "(fork)" });
  await expect(forkSidebarItem).toBeVisible({ timeout: 5_000 });

  await expect(page.locator(".btn-resume:visible").first()).toBeVisible({ timeout: 5_000 });
});

test("codex tool result with shell output renders correctly", async ({ page }) => {
  const tid = await createCodexTask();
  await page.goto(`/task/${tid}`);

  await sendMessage(page, "Please run command echo codex-tool-render-test");

  // Tool call block should appear
  await expect(
    page.locator(".tool-name", { hasText: "Bash" }),
  ).toBeVisible({ timeout: 60_000 });

  // Tool result should contain the command output
  await expect(
    page.locator(".tool-result", { hasText: "codex-tool-render-test" }),
  ).toBeVisible({ timeout: 60_000 });
});
