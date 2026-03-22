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
  //    The mock API responds instantly, so the spike will also exit quickly.
  await expect(async () => {
    const spike = taskCreatedEvents.find((e) => e.relation_type === "subtask");
    expect(spike).toBeTruthy();
  }).toPass({ timeout: 60_000 });

  const spikeTid = taskCreatedEvents.find((e) => e.relation_type === "subtask")!.tid;

  // 3. Wait for the spike to complete (alive: false).
  //    The JSONL file is only fully written after the process exits, so we must
  //    wait for completion before navigating — otherwise forkable UUIDs may not
  //    be available yet.
  await expect(async () => {
    const completed = taskUpdatedEvents.find((e) => e.tid === spikeTid && !e.alive);
    expect(completed).toBeTruthy();
  }).toPass({ timeout: 30_000 });

  // 4. Navigate to the spike task in the sidebar using its task ID.
  //    Auto-navigation after spike exit moved back to the parent conversation task.
  await page.locator(`.sidebar-item[data-tid="${spikeTid}"]`).click();

  // 5. Wait for the spike's history to load.
  //    History events and forkable UUIDs are sent together when the client
  //    subscribes. Once the content is visible, forkable UUIDs have been received.
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "worktree-fork-content",
    }),
  ).toBeVisible({ timeout: 15_000 });

  // 6. Hover over the assistant message to reveal the fork button.
  const assistantWrapper = page
    .locator(".message-wrapper", {
      has: page.locator(".assistant-message", {
        hasText: "worktree-fork-content",
      }),
    })
    .last();
  await assistantWrapper.hover();
  const forkBtn = assistantWrapper.locator(".fork-btn");
  await expect(forkBtn).toBeVisible({ timeout: 10_000 });

  // 7. Fork the spike task.
  await forkBtn.click();

  // 8. Wait for the fork's task_created broadcast event to capture its TID.
  await expect(async () => {
    const fork = taskCreatedEvents.find((e) => e.relation_type === "fork");
    expect(fork).toBeTruthy();
  }).toPass({ timeout: 15_000 });

  const forkTid = taskCreatedEvents.find((e) => e.relation_type === "fork")!.tid;

  // 9. The fork must appear in the project's sidebar.
  await expect(
    page.locator(".sidebar-list .sidebar-label", { hasText: / \(fork\)/i }),
  ).toBeVisible({ timeout: 10_000 });

  // 10. KEY ASSERTION: clicking the fork in the sidebar must navigate to it
  //     and display the fork's conversation history.
  //
  //     Without the fix, handleForkTaskMsg in app.d sets the fork's projectPath
  //     to td.effectiveCwd (the worktree path for spike tasks), which does NOT
  //     match any registered workspace project.  When the user clicks the fork
  //     in the sidebar, setActiveTaskId(forkTid) calls taskContext(forkTid) →
  //     findProjectName returns null → buildUrl(null, null, "/task/N") returns
  //     "/task/N" (no workspace/project prefix).  The router matches this as
  //     /:workspace/:project with workspace="task", project="N", setting
  //     activeTaskId=null — so the fork's session view is never marked active
  //     (display:contents) and its history is never loaded.
  //
  //     After the fix (newTd.projectPath = td.projectPath), taskContext returns
  //     the correct [workspace, projectName], navigation goes to
  //     /{workspace}/{project}/task/{forkTid}, the fork's session view becomes
  //     active, and its history (containing "worktree-fork-content") is loaded
  //     and displayed.
  //
  //     This assertion FAILS on the current codebase, demonstrating the bug.
  await page
    .locator(".sidebar-list .sidebar-label", { hasText: / \(fork\)/i })
    .click();

  // Scope to the active session container to avoid matching content from
  // other tasks rendered (but hidden) in the DOM simultaneously.
  await expect(
    page.locator("[style*='display: contents'] .message.assistant-message .text-content", {
      hasText: "worktree-fork-content",
    }),
  ).toBeVisible({ timeout: 15_000 });
});
