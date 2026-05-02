import { test, expect, enterSession, sendMessage, assistantText } from "./fixtures";

test("blank-mode entry point preserves first user message after SwitchMode", async ({ page, agentType }) => {
  test.skip(agentType !== "codex", "reproducer is codex-specific — codex JSONL stores wrapped prompt text");

  await enterSession(page);

  // Pick the `blank` entry point. blank's prompt template has NO `--------------------------------------------------------------------------------` separator,
  // so the backend cannot extract task_description from the wrapped [SYSTEM:] body during JSONL replay → cydoMeta on replay has only `label`, no `vars/bodyVar`.
  await page.locator(".task-type-row", { hasText: "blank" }).click();
  await expect(page.locator(".task-type-row.selected .task-type-name")).toHaveText("blank");

  // Send a unique first user message.
  const FIRST = "unique-message-please-keep-me-12345";
  await sendMessage(page, FIRST);

  // Wait for an assistant text response so the message is fully processed and persisted in JSONL.
  await expect(assistantText(page, /./).first()).toBeVisible({ timeout: 60_000 });

  // Now trigger SwitchMode keep_context. This kills the codex agent, resets td.history, and the
  // continuation emits a task_reload that forces the frontend to re-request the JSONL.
  await sendMessage(page, "call switchmode plan");

  // Wait for the switch to surface — the mode-switch system message divider appears post-replay.
  await expect(
    page.locator(".result-divider.system-user-message", { hasText: "Mode switch: plan" }),
  ).toBeVisible({ timeout: 60_000 });

  // ── Assertions that fail with the bug ───────────────────────────────────────
  // 1) The first message must not have leaked into the input box.
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toHaveValue("");

  // 2) The first message must be visible in the conversation transcript as a real
  //    user message body (not collapsed to a label-only divider). The expanded
  //    template-style render uses `.message.user-message.system-user-message`
  //    and contains the user text. The buggy render produces only
  //    `.result-divider.system-user-message` with the label, no body.
  await expect(
    page.locator(".message.user-message.system-user-message", { hasText: FIRST }),
  ).toBeVisible({ timeout: 10_000 });
});
