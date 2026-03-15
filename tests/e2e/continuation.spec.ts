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

test("keep_context continuation injects prompt template", async ({ page }) => {
  await enterProject(page);

  // Send a message that triggers the mock API to return a SwitchMode tool call.
  // The mock API pattern "call switchmode plan" returns mcp__cydo__SwitchMode.
  // The backend handles SwitchMode, the session exits, and spawnContinuation
  // resumes the session with the continuation's prompt_template injected as a
  // user message.
  await sendMessage(page, "call switchmode plan");

  // The continuation prompt from defs/task-types/prompts/enter_plan_mode.md
  // should appear as a user message. Its first line is "# Planning Mode".
  await expect(
    page.locator(".message.user-message", { hasText: "Planning Mode" }),
  ).toBeVisible({ timeout: 30_000 });
});

test("unsent message recovered into input box after kill", async ({ page }) => {
  await enterProject(page);

  // Send a message that triggers a long-running command. Claude Code will
  // actually execute `sleep 60`, blocking the session.
  await sendMessage(page, "run command sleep 60");

  // Wait for the tool call to appear (confirms Claude is executing sleep).
  await expect(
    page.locator(".tool-call", { hasText: "sleep 60" }),
  ).toBeVisible({ timeout: 30_000 });

  // Send a second message while the agent is busy. This message will be
  // broadcast as an unconfirmed user event but never written to the JSONL
  // because Claude is blocked on sleep.
  await sendMessage(page, "this should be recovered");

  // Kill the session. The sleep is terminated, session reloads from JSONL.
  await page.locator(".btn-banner-stop").click();
  await expect(page.locator(".btn-resume")).toBeVisible({ timeout: 10_000 });

  // Resume so the input box reappears.
  await page.locator(".btn-resume").click();
  await expect(page.locator(".btn-banner-stop")).toBeVisible({ timeout: 15_000 });

  // The second message was never persisted in the JSONL, so it should be
  // recovered into the input box as an unsent draft.
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toHaveValue("this should be recovered", { timeout: 10_000 });
});

test("input box stays empty after mode switch", async ({ page }) => {
  await enterProject(page);

  // Trigger a mode switch. The user's message gets wrapped in a prompt
  // template before being sent to Claude. After the session reloads, the
  // unsent-message-recovery logic must recognize that the message was
  // persisted (even though the JSONL contains the wrapped version) and
  // NOT restore it into the input box.
  await sendMessage(page, "call switchmode plan");

  // Wait for the continuation to complete (the prompt template appears).
  await expect(
    page.locator(".message.user-message", { hasText: "Planning Mode" }),
  ).toBeVisible({ timeout: 30_000 });

  // The input box should be empty — the original message was sent and
  // persisted, so it must not be restored as a draft.
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled({ timeout: 10_000 });
  await expect(input).toHaveValue("");
});
