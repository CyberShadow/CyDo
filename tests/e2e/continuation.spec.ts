import { test, expect, enterSession, sendMessage } from "./fixtures";

test("keep_context continuation injects prompt template", async ({ page, agentType }) => {
  await enterSession(page);

  await sendMessage(page, "call switchmode plan");

  // Verify MCP tool call shows correct tool name (not "cydo__SwitchMode" or "unknown").
  await expect(
    page.locator(".tool-name", { hasText: "SwitchMode" }),
  ).toBeVisible({ timeout: 30_000 });

  await expect(
    page.locator(".message.user-message", { hasText: "Planning Mode" }),
  ).toBeVisible({ timeout: 30_000 });
});

test("unsent steer is either recovered into input box or shown in history after kill", async ({ page, agentType }) => {
  // Codex and Copilot write turn/steer messages to their session files immediately upon
  // receipt (before the LLM responds), so the preReloadDrafts confirmation logic
  // incorrectly marks the steer as "confirmed" even though the LLM never processed it.
  // The first message also fails to match because codex/copilot store the full rendered
  // prompt template, not the raw text.
  test.skip(agentType === "codex" || agentType === "copilot", "codex/copilot write steers eagerly; preReloadDrafts mechanism cannot distinguish unprocessed steers");

  await enterSession(page);

  await sendMessage(page, "run command sleep 60");

  await expect(
    page.locator(".tool-call", { hasText: "sleep 60" }),
  ).toBeVisible({ timeout: 30_000 });

  await sendMessage(page, "this should be recovered");

  await page.locator(".btn-banner-stop").click();
  await expect(page.locator(".btn-resume")).toBeVisible({ timeout: 10_000 });

  await page.locator(".btn-resume").click();
  await expect(page.locator(".btn-banner-stop")).toBeVisible({ timeout: 15_000 });

  const input = page.locator(".input-textarea:visible").first();
  const historyMessage = page.locator(".user-message", { hasText: "this should be recovered" });

  await expect(
    async () => {
      const inputValue = await input.inputValue();
      const messageVisible = await historyMessage.isVisible();
      expect(inputValue === "this should be recovered" || messageVisible).toBe(true);
    }
  ).toPass({ timeout: 10_000 });
});

test("handoff continuation exit navigates to grandparent, not completed parent", async ({ page, agentType }) => {

  // Create root task G and enter its session.
  await enterSession(page);

  // G calls Task to create subtask A (type test_handoff).
  // A's prompt is "call handoff done test-prompt" which triggers Handoff immediately.
  // G's fiber blocks waiting for A's result, keeping G alive throughout.
  // The task is created atomically with this first message (activeTaskId === null).
  await sendMessage(page, "call task test_handoff call handoff done test-prompt");

  // Wait for the task URL to settle so we can capture G's tid.
  await expect(page).toHaveURL(/\/[^/]+\/[^/]+\/task\/\d+/, { timeout: 15_000 });
  const tidG = parseInt(page.url().match(/\/[^/]+\/[^/]+\/task\/(\d+)/)?.[1] ?? "0");
  expect(tidG).toBeGreaterThan(0);

  // Flow: A calls Handoff → A completes → continuation C created → C auto-focused
  //        → C responds → C exits → frontend should navigate to G (first alive ancestor)
  //
  // With the bug, it would navigate to A (completed direct parent).
  // With the fix, it walks up through completed A to find alive G.
  await expect(page).toHaveURL(new RegExp(`/task/${tidG}$`), { timeout: 30_000 });
});

test("SwitchMode from sub-task sends is_continuation flag", async ({ page, agentType }) => {
  // Listen for task_reload broadcast frames — sent to ALL clients regardless
  // of subscription. The process/exit event with is_continuation is only sent
  // to subscribers of the child's tid, which is racy (the child can exit
  // before any client subscribes). task_reload with reason "continuation" is
  // the reliable broadcast equivalent.
  const reloadEvents: Array<{ tid: number; reason?: string }> = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        const data = JSON.parse(event.payload.toString());
        if (data.type === "task_reload") {
          reloadEvents.push({
            tid: data.tid,
            reason: data.reason,
          });
        }
      } catch { /* ignore non-JSON frames */ }
    });
  });

  // Create root task G and enter its session.
  await enterSession(page);

  // G creates child C of type blank. C's initial prompt is
  // "call switchmode plan", triggering a keep_context continuation.
  await sendMessage(page, "call task blank call switchmode plan");

  // Wait for a task_reload with reason "continuation" — this confirms the
  // backend processed the SwitchMode and transitioned the task in-place.
  await expect(async () => {
    const continuationReload = reloadEvents.find((e) => e.reason === "continuation");
    expect(continuationReload).toBeTruthy();
  }).toPass({ timeout: 30_000 });
});

test("on_yield continuation auto-fires on clean exit", async ({ page, agentType }) => {
  // Listen for task_created broadcast frames — sent to ALL clients regardless of subscription.
  const taskCreatedEvents: Array<{ tid: number; parent_tid: number; relation_type: string }> = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        const data = JSON.parse(event.payload.toString());
        if (data.type === "task_created") {
          taskCreatedEvents.push({
            tid: data.tid,
            parent_tid: data.parent_tid,
            relation_type: data.relation_type,
          });
        }
      } catch { /* ignore non-JSON frames */ }
    });
  });

  await enterSession(page);

  // Create a sub-task of type test_on_yield. The mock agent produces a text
  // reply and exits cleanly (code 0) without calling SwitchMode/Handoff.
  // The on_yield continuation should auto-fire, creating a blank successor.
  await sendMessage(page, "call task test_on_yield hello");

  // A task_created with relation_type "continuation" must appear.
  await expect(async () => {
    const continuationCreated = taskCreatedEvents.find((e) => e.relation_type === "continuation");
    expect(continuationCreated).toBeTruthy();
  }).toPass({ timeout: 30_000 });
});

test("on_yield does not fire on non-zero exit", async ({ page, agentType }) => {
  // Codex exits with code 0 on "OutputTextDelta without active item" errors,
  // triggering on_yield before the Kill button can be clicked.
  test.skip(agentType === "codex", "Codex exits with code 0 on internal errors, triggering on_yield before kill");

  const taskCreatedEvents: Array<{ tid: number; parent_tid: number; relation_type: string }> = [];
  const taskUpdatedEvents: Array<{ tid: number; alive: boolean }> = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        const data = JSON.parse(event.payload.toString());
        if (data.type === "task_created") {
          taskCreatedEvents.push({
            tid: data.tid,
            parent_tid: data.parent_tid,
            relation_type: data.relation_type,
          });
        } else if (data.type === "task_updated") {
          taskUpdatedEvents.push({ tid: data.task.tid, alive: data.task.alive });
        }
      } catch {}
    });
  });

  await enterSession(page);

  // Create a sub-task of type test_on_yield with a stalling LLM response so
  // the sub-task stays alive long enough for us to kill it.
  await sendMessage(page, "call task test_on_yield stall session");

  // Wait for the sub-task to be created (task_created is broadcast to all clients).
  await expect(async () => {
    const subTask = taskCreatedEvents.find((e) => e.relation_type === "subtask");
    expect(subTask).toBeTruthy();
  }).toPass({ timeout: 30_000 });
  const subTaskTid = taskCreatedEvents.find((e) => e.relation_type === "subtask")!.tid;

  // Kill the sub-task. getByRole targets only accessible elements, so it
  // finds the sub-task's Kill button and ignores hidden buttons from other tasks.
  await page.getByRole("button", { name: "Kill" }).click({ timeout: 30_000 });

  // Wait for the sub-task to show as dead via broadcast task_updated.
  await expect(async () => {
    const deadUpdate = taskUpdatedEvents.find((e) => e.tid === subTaskTid && !e.alive);
    expect(deadUpdate).toBeTruthy();
  }).toPass({ timeout: 10_000 });

  // No task_created with relation_type "continuation" should have appeared.
  const continuationCreated = taskCreatedEvents.find((e) => e.relation_type === "continuation");
  expect(continuationCreated).toBeFalsy();
});

test("input box stays empty after mode switch", async ({ page, agentType }) => {
  await enterSession(page);

  await sendMessage(page, "call switchmode plan");

  await expect(
    page.locator(".message.user-message", { hasText: "Planning Mode" }),
  ).toBeVisible({ timeout: 30_000 });

  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled({ timeout: 10_000 });
  await expect(input).toHaveValue("");
});
