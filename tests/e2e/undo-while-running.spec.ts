import type { Page } from "@playwright/test";
import {
  test,
  expect,
  enterSession,
  sendMessage,
  assistantText,
  currentTaskTid,
  killSession,
} from "./fixtures";

test(
  "busy Codex undo stops the session, reverts the thread and resumes",
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
    // The turn of the message and the one running after it.
    await expect(page.locator(".undo-dialog-count")).toContainText(
      "2 whole turns will be removed.",
    );
    const rollbackFrameStart = frames.length;
    await page.locator(".btn-undo").click();

    // The undo is async: backend stops the session first (setGoal Dead), then
    // reverts the stopped thread, which triggers a history reload.
    // Wait for the second user message to disappear — this is the primary
    // indicator that the full stop→undo→reload cycle completed.
    await expect(
      page.locator(".message.user-message:not(.pending)", {
        hasText: "second-reply",
      }),
    ).not.toBeVisible();

    const rollbackFrames = () => frames.slice(rollbackFrameStart);
    await expect
      .poll(() => {
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
      })
      .toBe(true);
    const backups = rollbackFrames().filter(
      (frame) =>
        frame?.type === "task_created" &&
        frame?.relation_type === "undo-backup",
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

    // Reload from what Codex kept before sending another turn. This catches
    // an undo that only updates the currently mounted view.
    await page.reload();
    await expect(assistantText(page, "first-reply")).toBeVisible();
    await expect(assistantText(page, "second-reply")).toHaveCount(0);

    const backup = page.locator(`.sidebar-item[data-tid="${backups[0].tid}"]`);
    await expect(backup).toBeVisible();
    await backup.click();
    await expect(assistantText(page, "second-reply")).toBeVisible();
    // The pre-undo backup also preserves the in-flight prompt.
    await expect(
      page.locator(".user-message", { hasText: "stall session" }),
    ).toHaveCount(1);
    await page.locator(`.sidebar-item[data-tid="${tid}"]`).click();

    // Verify the session auto-resumed (input box visible).
    await expect(page.locator(".input-textarea:visible").first()).toBeVisible();

    await sendMessage(page, 'Please reply with "third-reply"');
    await expect(assistantText(page, "third-reply")).toBeVisible();

    // Codex reverts whole turns: there is no undo at an assistant message.
    await enterSession(page);
    await sendMessage(page, 'Please reply with "assistant-ready-unsupported"');
    await expect(
      assistantText(page, "assistant-ready-unsupported"),
    ).toBeVisible();
    const readyAssistant = page
      .locator(".message-wrapper", {
        has: page.locator(".assistant-message", {
          hasText: "assistant-ready-unsupported",
        }),
      })
      .last();
    await readyAssistant.hover();
    await expect(readyAssistant.locator(".undo-btn")).toHaveCount(0);
  },
);

async function confirmUndoTwice(page: Page, state: "busy" | "stopped") {
  let tid: number;
  const otherPage = await page.context().newPage();
  const replies: { tab: number; type: string; message?: string }[] = [];
  const backups: number[] = [];
  const tabs = [page, otherPage];
  for (const [tab, view] of tabs.entries()) {
    view.on("websocket", (ws) => {
      ws.on("framereceived", ({ payload }) => {
        const frame = JSON.parse(payload.toString());
        if (
          frame.tid === tid &&
          (frame.type === "error" || frame.type === "undo_result")
        ) {
          replies.push({ tab, type: frame.type, message: frame.message });
        }
        if (
          tab === 1 &&
          frame.type === "task_created" &&
          frame.parent_tid === tid &&
          frame.relation_type === "undo-backup"
        ) {
          backups.push(frame.tid);
        }
      });
    });
  }
  await enterSession(page);
  await sendMessage(page, 'Please reply with "keep-before-undo"');
  await expect(assistantText(page, "keep-before-undo")).toBeVisible();
  await sendMessage(page, 'Please reply with "remove-by-undo"');
  await expect(assistantText(page, "remove-by-undo")).toBeVisible();
  tid = currentTaskTid(page);

  await sendMessage(page, "stall session");
  await expect(
    page.locator(".user-message:not(.pending)", { hasText: "stall session" }),
  ).toBeVisible();
  await expect(page.locator(".btn-banner-stop")).toBeVisible();
  if (state === "stopped") await killSession(page, "codex");

  await otherPage.goto(page.url());

  async function prepareConfirmation(view: Page) {
    await expect(assistantText(view, "remove-by-undo")).toBeVisible();
    const message = view.locator(".message-wrapper", {
      has: view.locator(".user-message", { hasText: "remove-by-undo" }),
    });
    await message.hover();
    await message.locator(".undo-btn").click();
    await expect(view.locator(".undo-dialog-count")).toContainText(
      "2 whole turns will be removed.",
    );
  }

  for (const view of tabs) await prepareConfirmation(view);

  // Each tab has its own confirmation for the same task. Submit both
  // without waiting for either undo to finish.
  await Promise.all(tabs.map((view) => view.locator(".btn-undo").click()));
  await expect
    .poll(() => replies.map(({ type }) => type))
    .toEqual(["error", "undo_result"]);

  const [refused, completed] = replies;
  expect(refused.message).toContain("undo is already in progress");
  expect(refused.tab).not.toBe(completed.tab);
  await expect(tabs[refused.tab].locator(".command-error-dialog")).toContainText(
    "undo is already in progress",
  );
  const successfulView = tabs[completed.tab];
  await expect(assistantText(successfulView, "remove-by-undo")).toHaveCount(0);
  await expect(assistantText(successfulView, "keep-before-undo")).toBeVisible();
  expect(backups).toHaveLength(1);
}

test(
  "busy Codex undo rejects a second confirmation during backup",
  { tag: "@codex-only" },
  async ({ page }) => confirmUndoTwice(page, "busy"),
);

test(
  "stopped Codex undo rejects a second confirmation during backup",
  { tag: "@codex-only" },
  async ({ page }) => confirmUndoTwice(page, "stopped"),
);
