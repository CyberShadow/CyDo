import { test, expect, enterSession, sendMessage } from "./fixtures";

test("forked worktree spike task appears in sidebar", async ({ page, agentType }) => {
  test.skip(agentType === "codex", "codex does not use git worktrees");

  // Track WebSocket events to reliably detect task creation/completion.
  const taskCreatedEvents: Array<{
    tid: number;
    parent_tid?: number;
    relation_type?: string;
  }> = [];
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
      } catch {
        /* ignore non-JSON frames */
      }
    });
  });

  // 1. Enter a conversation session and create a spike subtask.
  //    The 'spike' type has worktree: true, so the backend creates a git worktree.
  await enterSession(page);
  await sendMessage(page, "call task spike worktree-fork-content");

  // 2. Wait for the spike subtask to be created (relation_type = "subtask").
  await expect(async () => {
    const spike = taskCreatedEvents.find((e) => e.relation_type === "subtask");
    expect(spike).toBeTruthy();
  }).toPass({ timeout: 60_000 });

  const spikeTid = taskCreatedEvents.find((e) => e.relation_type === "subtask")!.tid;

  // 3. Wait for the spike to actually complete (alive: true → alive: false).
  //    The first task_updated broadcast has alive: false (initial state before
  //    the process starts), so we must wait for alive: true followed by
  //    alive: false to confirm the process has actually run and exited.
  //    The JSONL file is only fully written after the process exits, so we must
  //    wait for completion before navigating — otherwise forkable UUIDs may not
  //    be available yet.
  await expect(async () => {
    const spikeEvents = taskUpdatedEvents.filter((e) => e.tid === spikeTid);
    let seenAlive = false;
    let completed = false;
    for (const e of spikeEvents) {
      if (e.alive) seenAlive = true;
      else if (seenAlive) { completed = true; break; }
    }
    expect(completed).toBeTruthy();
  }).toPass({ timeout: 60_000 });

  // 3b. Wait for auto-navigation away from spike (process/exit handler).
  //     This fires ~100ms after the spike exits. If we don't wait, our
  //     subsequent hover+fork-click may land on the conversation task
  //     instead of the spike (race with the auto-navigation).
  await page.waitForURL((url) => !url.pathname.endsWith(`/task/${spikeTid}`), {
    timeout: 10_000,
  });

  // 4+5. Navigate to the spike task and wait for its history to load.
  //    The process/exit event is sent before task_updated, so React may process
  //    it after our sidebar click, auto-navigating away to the parent task.
  //    We retry the click until the spike is confirmed active and its content
  //    is visible (which also guarantees forkable UUIDs have been received).
  await expect(async () => {
    await page.locator(`.sidebar-item[data-tid="${spikeTid}"]`).click();
    // Confirm spike is the active task (not navigated away by process/exit).
    await expect(
      page.locator(`.sidebar-item[data-tid="${spikeTid}"].active`),
    ).toBeVisible({ timeout: 3_000 });
    // Confirm spike's history loaded (scoped to active session to avoid
    // matching the conversation task's tool-call result, which also
    // contains "worktree-fork-content" in its text-content block).
    await expect(
      page.locator(
        "[style*='display: contents'] .message.assistant-message .text-content",
        { hasText: "worktree-fork-content" },
      ),
    ).toBeVisible({ timeout: 10_000 });
  }).toPass({ timeout: 30_000 });

  // 6. Hover over the assistant message to reveal the fork button.
  //    Scope to the active session to avoid matching the conversation task's
  //    messages (which also contain "worktree-fork-content" in a tool result).
  //    Copilot emits a verbose event stream that causes React re-renders while
  //    the history loads; retry the hover+check until the DOM stabilises.
  await expect(async () => {
    const assistantWrapper = page
      .locator("[style*='display: contents'] .message-wrapper", {
        has: page.locator(".assistant-message", {
          hasText: "worktree-fork-content",
        }),
      })
      .last();
    await assistantWrapper.hover();
    await expect(assistantWrapper.locator(".fork-btn")).toBeVisible({
      timeout: 5_000,
    });
  }).toPass({ timeout: 15_000 });

  // 7. Fork the spike task (re-resolve the locator fresh after the hover).
  await page
    .locator("[style*='display: contents'] .message-wrapper", {
      has: page.locator(".assistant-message", { hasText: "worktree-fork-content" }),
    })
    .last()
    .locator(".fork-btn")
    .click();

  // 8. Wait for the fork's task_created broadcast event to capture its TID.
  await expect(async () => {
    const fork = taskCreatedEvents.find((e) => e.relation_type === "fork");
    expect(fork).toBeTruthy();
  }).toPass({ timeout: 15_000 });

  const forkTid = taskCreatedEvents.find((e) => e.relation_type === "fork")!.tid;

  // 9. The fork should auto-navigate via shouldFocus in the task_created handler.
  //    If auto-focus didn't fire (race condition), click the sidebar as fallback.
  //    Wrap in toPass to handle either path.
  await expect(async () => {
    // If not already on the fork's URL, click it in the sidebar.
    const url = page.url();
    if (!url.endsWith(`/task/${forkTid}`)) {
      const forkSidebar = page.locator(`.sidebar-item[data-tid="${forkTid}"]`);
      if (await forkSidebar.isVisible()) {
        await forkSidebar.click();
      }
    }
    // Wait for the fork's URL.
    await expect(page).toHaveURL(new RegExp(`/task/${forkTid}$`), { timeout: 5_000 });
    // Wait for the fork's content to be visible in the active session.
    await expect(
      page.locator("[style*='display: contents'] .message.assistant-message .text-content", {
        hasText: "worktree-fork-content",
      }),
    ).toBeVisible({ timeout: 5_000 });
  }).toPass({ timeout: 30_000 });
});
