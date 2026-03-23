import { test, expect, enterSession, sendMessage, responseTimeout } from "./fixtures";

// Regression test for background commands shown as still running after completion.
//
// When Codex's exec_command tool uses yield_time_ms, the command continues
// running in the background after the yield. The LLM gets partial output,
// responds, and the turn completes. Later, when the command actually finishes,
// item/completed arrives — but CyDo's backend drops it because
// handleTurnCompleted() already cleared activeItemId_.
//
// Result: the tool call spinner persists forever even though the command finished.

test("background command spinner disappears after command completes", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "codex", "codex-only: exec_command with yield_time_ms");

  await enterSession(page);

  // "run background command sleep 3" triggers exec_command with yield_time_ms: 500.
  // Codex starts `sleep 3`, yields after 500ms, mock LLM responds with "Done.",
  // turn completes. ~2.5s later, `sleep 3` finishes and item/completed arrives.
  await sendMessage(page, "run background command sleep 3");

  const timeout = responseTimeout(agentType);

  // Wait for the tool call to appear (commandExecution rendered as tool block).
  await expect(
    page.locator(".tool-call"),
  ).toBeVisible({ timeout });

  // Wait for the turn to end — the LLM's "Done." text response appears after
  // processing the yielded tool output.
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "Done." }),
  ).toBeVisible({ timeout });

  // At this point the turn has completed but `sleep 3` is still running.
  // The spinner should still be visible.
  await expect(page.locator(".tool-spinner")).toBeVisible();

  // Wait for the command to finish (sleep 3 = ~3s from start, plus buffer).
  // After completion, the spinner should disappear and a result should appear.
  //
  // BUG: The spinner never disappears because item/completed is dropped by
  // the backend (activeItemId_ was cleared by handleTurnCompleted).
  await expect(page.locator(".tool-spinner")).not.toBeVisible({ timeout: 10_000 });
});

// Regression test: multiple concurrent background commands.
//
// When two exec_command calls with yield_time_ms run sequentially in the same
// turn, both commands continue in the background after their yields.
// handleItemStarted sets activeItemId_ to each item's id as it starts, so
// after both items have started, activeItemId_ holds only the LAST item's id.
//
// When the commands finish later:
// - The first command's item/completed is either dropped (activeItemId_ was
//   cleared) or misattributed (activeItemId_ points to the second command).
// - At best, only the second command's spinner disappears.
//
// The proper fix should use params.item.id from item/completed instead of
// relying on the single activeItemId_ field.

test("multiple background command spinners all disappear after completion", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "codex", "codex-only: exec_command with yield_time_ms");

  await enterSession(page);

  // "run two background commands" triggers two sequential exec_command calls:
  //   1. exec_command(sleep 2, yield_time_ms=500)  — yields, command continues
  //   2. exec_command(sleep 3, yield_time_ms=500)  — yields, command continues
  // After both yields, mock LLM responds with "Done." and the turn completes.
  // Both sleep commands continue running in the background.
  await sendMessage(page, "run two background commands");

  const timeout = responseTimeout(agentType);

  // Wait for both tool calls to appear.
  await expect(
    page.locator(".tool-call"),
  ).toHaveCount(2, { timeout });

  // Wait for the turn to end — "Done." text appears.
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "Done." }),
  ).toBeVisible({ timeout });

  // Both commands are still running; spinners should be visible.
  const spinners = page.locator(".tool-spinner");
  await expect(spinners).toHaveCount(2);

  // Wait for both commands to finish.
  // sleep 8 finishes ~8s after start, sleep 10 ~10s after start (offset by ~0.5s).
  await expect(spinners).toHaveCount(0, { timeout: 20_000 });
});
