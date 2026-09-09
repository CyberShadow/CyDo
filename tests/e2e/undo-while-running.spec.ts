import {
  test,
  expect,
  enterSession,
  sendMessage,
  assistantText,
  codexRolloutRecords,
  currentTaskTid,
} from "./fixtures";

test(
  "busy Codex undo replays the canonical rollback and resumes",
  { tag: "@codex-only" },
  async ({ page }) => {
    const frames: any[] = [];
    page.on("websocket", (ws) => {
      ws.on("framereceived", (event) => {
        try {
          frames.push(JSON.parse(event.payload.toString()));
        } catch {
          // ignore non-JSON frames
        }
      });
    });
    await enterSession(page);

    await sendMessage(page, 'Please reply with "first-reply"');
    await expect(assistantText(page, "first-reply")).toBeVisible();

    await sendMessage(page, 'Please reply with "second-reply"');
    await expect(assistantText(page, "second-reply")).toBeVisible();
    const tid = currentTaskTid(page);

    // Send "stall session" — mock API starts a response but never completes it,
    // keeping the session alive indefinitely.
    await sendMessage(page, "stall session");

    // Confirm the session is still running (stop button visible means it's processing).
    await expect(page.locator(".btn-banner-stop")).toBeVisible();

    // Hover over the second user message to reveal the undo button.
    const secondUserMsg = page
      .locator(".message-wrapper", {
        has: page.locator(".user-message", { hasText: "second-reply" }),
      })
      .last();
    await secondUserMsg.hover();

    await expect(secondUserMsg.locator(".undo-btn")).toBeVisible();
    await secondUserMsg.locator(".undo-btn").click();

    await expect(page.locator(".undo-dialog")).toBeVisible();
    // A busy Codex session uses the resolved JSONL fallback preview, rather
    // than a stale native-turn count.
    await expect(page.locator(".undo-dialog-count")).toContainText(
      /\d+ messages?/,
    );
    const rollbackFrameStart = frames.length;
    await page.locator(".btn-undo").click();

    // The undo is async: backend stops the session first (setGoal Dead), then
    // performs the undo in the callback, which triggers a history reload.
    // Wait for the second user message to disappear — this is the primary
    // indicator that the full stop→undo→reload cycle completed.
    await expect(
      page.locator(".message.user-message:not(.pending)", {
        hasText: "second-reply",
      }),
    ).not.toBeVisible();

    const rollbackFrames = () => frames.slice(rollbackFrameStart);
    await expect
      .poll(
        () => {
          const reloads = rollbackFrames().filter(
            (frame) => frame?.type === "task_reload",
          );
          const reloadIdx = rollbackFrames().findIndex(
            (frame) => frame?.type === "task_reload",
          );
          const historyStartIdx = rollbackFrames().findIndex(
            (frame, idx) =>
              idx > reloadIdx && frame?.type === "task_history_start",
          );
          const historyEndIdx = rollbackFrames().findIndex(
            (frame, idx) =>
              idx > historyStartIdx && frame?.type === "task_history_end",
          );
          return (
            reloads.length === 1 &&
            historyStartIdx > reloadIdx &&
            historyEndIdx > historyStartIdx
          );
        },
      )
      .toBe(true);
    const backups = rollbackFrames().filter(
      (frame) =>
        frame?.type === "task_created" && frame?.relation_type === "undo-backup",
    );
    expect(backups).toHaveLength(1);
    expect(backups[0].parent_tid).toBe(tid);
    await expect(page.locator(".command-error-dialog")).not.toBeVisible();
    await expect(page.locator("body")).not.toContainText(
      "Codex generic history forks must use the native thread RPC path",
    );
    await expect(page.locator("body")).not.toContainText(
      "Codex fork source operation cannot retain a task session",
    );

    // The first reply should still be visible.
    await expect(assistantText(page, "first-reply").first()).toBeVisible();

    // The fallback truncation must be durable in the canonical rollout, not
    // merely hidden by the optimistic in-memory view.
    await expect
      .poll(() => JSON.stringify(codexRolloutRecords(tid)))
      .not.toContain("second-reply");

    // Reload from the server's canonical history before sending another turn.
    // This catches a rollback that only updates the currently mounted view.
    await page.reload();
    await expect(assistantText(page, "first-reply")).toBeVisible();
    await expect(assistantText(page, "second-reply")).toHaveCount(0);

    const backup = page.locator(`.sidebar-item[data-tid="${backups[0].tid}"]`);
    await expect(backup).toBeVisible();
    await backup.click();
    await expect(assistantText(page, "second-reply")).toBeVisible();
    await expect(page.locator(".user-message", { hasText: "stall session" })).toHaveCount(0);
    await page.locator(`.sidebar-item[data-tid="${tid}"]`).click();

    // Verify the session auto-resumed (input box visible).
    await expect(page.locator(".input-textarea:visible").first()).toBeVisible();

    await sendMessage(page, 'Please reply with "third-reply"');
    await expect(assistantText(page, "third-reply")).toBeVisible();
    await expect
      .poll(() => JSON.stringify(codexRolloutRecords(tid)))
      .toContain("third-reply");

    await enterSession(page);
    await sendMessage(page, 'Please reply with "assistant-busy-prefix"');
    await expect(assistantText(page, "assistant-busy-prefix")).toBeVisible();
    await sendMessage(page, 'Please reply with "assistant-busy-selected"');
    await expect(assistantText(page, "assistant-busy-selected")).toBeVisible();
    const assistantTid = currentTaskTid(page);
    await sendMessage(page, "stall session");
    await expect(page.locator(".btn-banner-stop")).toBeVisible();
    const selectedAssistant = page
      .locator(".message-wrapper", {
        has: page.locator(".assistant-message", {
          hasText: "assistant-busy-selected",
        }),
      })
      .last();
    await selectedAssistant.hover();
    await selectedAssistant.locator(".undo-btn").click();
    await expect(page.locator(".undo-dialog")).toBeVisible();
    await page.locator(".btn-undo").click();
    await expect(assistantText(page, "assistant-busy-selected")).toHaveCount(0);
    await expect(
      page.locator(".user-message:not(.pending)", { hasText: "stall session" }),
    ).toHaveCount(0);
    await expect(
      page.locator(".user-message:not(.pending)", {
        hasText: "assistant-busy-selected",
      }),
    ).toBeVisible();
    await expect
      .poll(() =>
        codexRolloutRecords(assistantTid).some(
          (record) =>
            record.type === "event_msg" &&
            record.payload?.type === "agent_message" &&
            record.payload?.message === "assistant-busy-selected",
        ),
      )
      .toBe(false);
    await page.reload();
    await expect(assistantText(page, "assistant-busy-prefix")).toBeVisible();
    await expect(assistantText(page, "assistant-busy-selected")).toHaveCount(0);
    await expect(page.locator(".input-textarea:visible").first()).toBeEnabled();
    await sendMessage(page, 'Please reply with "assistant-busy-follow-up"');
    await expect(assistantText(page, "assistant-busy-follow-up")).toBeVisible();
  },
);
