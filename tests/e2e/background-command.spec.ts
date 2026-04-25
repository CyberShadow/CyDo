import { existsSync, rmSync } from "fs";
import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  killSession,
  assistantText,
} from "./fixtures";

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
  test.skip(
    agentType !== "codex",
    "codex-only: exec_command with yield_time_ms",
  );

  await enterSession(page);

  // "run background command sleep 3" triggers exec_command with yield_time_ms: 500.
  // Codex starts `sleep 3`, yields after 500ms, mock LLM responds with "Done.",
  // turn completes. ~2.5s later, `sleep 3` finishes and item/completed arrives.
  await sendMessage(page, "run background command sleep 3");

  const timeout = responseTimeout(agentType);

  // Wait for the tool call to appear (commandExecution rendered as tool block).
  await expect(page.locator(".tool-call")).toBeVisible({ timeout });

  // Wait for the turn to end — the LLM's "Done." text response appears after
  // processing the yielded tool output.
  await expect(assistantText(page, "Done.")).toBeVisible({ timeout });

  // At this point the turn has completed but `sleep 3` is still running.
  // The spinner should still be visible.
  await expect(page.locator(".tool-spinner")).toBeVisible();

  // Wait for the command to finish (sleep 3 = ~3s from start, plus buffer).
  // After completion, the spinner should disappear and a result should appear.
  //
  // BUG: The spinner never disappears because item/completed is dropped by
  // the backend (activeItemId_ was cleared by handleTurnCompleted).
  await expect(page.locator(".tool-spinner")).not.toBeVisible({
    timeout: 10_000,
  });
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
  test.skip(
    agentType !== "codex",
    "codex-only: exec_command with yield_time_ms",
  );

  await enterSession(page);

  // "run two background commands" triggers two sequential exec_command calls:
  //   1. exec_command(sleep 2, yield_time_ms=500)  — yields, command continues
  //   2. exec_command(sleep 3, yield_time_ms=500)  — yields, command continues
  // After both yields, mock LLM responds with "Done." and the turn completes.
  // Both sleep commands continue running in the background.
  await sendMessage(page, "run two background commands");

  const timeout = responseTimeout(agentType);

  // Wait for both tool calls to appear.
  await expect(page.locator(".tool-call")).toHaveCount(2, { timeout });

  // Wait for the turn to end — "Done." text appears.
  await expect(assistantText(page, "Done.")).toBeVisible({ timeout });

  // Both commands are still running; spinners should be visible.
  const spinners = page.locator(".tool-spinner");
  await expect(spinners).toHaveCount(2);

  // Wait for both commands to finish.
  // sleep 8 finishes ~8s after start, sleep 10 ~10s after start (offset by ~0.5s).
  await expect(spinners).toHaveCount(0, { timeout: 20_000 });
});

// Regression test: late output_delta content after turn/stop is rendered.
//
// When a command continues producing output after the agent's turn ends
// (turn/stop seals the message), the output_delta events must be applied
// to the sealed content block and rendered in the UI.

test("late command output appears after turn completes", async ({
  page,
  agentType,
}) => {
  test.skip(
    agentType !== "codex",
    "codex-only: exec_command with yield_time_ms",
  );

  await enterSession(page);

  // yield_time_ms=1 causes near-immediate yield. The shell command sleeps
  // briefly then echoes a marker string. The turn completes before the echo
  // runs, so the output arrives as a late output_delta on a sealed message.
  await sendMessage(
    page,
    "run quick-yield command sleep 2 && echo late-output-marker",
  );

  const timeout = responseTimeout(agentType);

  // Wait for the tool call to appear and the turn to complete.
  await expect(page.locator(".tool-call")).toBeVisible({ timeout });
  await expect(assistantText(page, "Done.")).toBeVisible({ timeout });

  // The late output should appear in the tool call's output area.
  // This verifies that output_delta events are applied to the sealed content
  // block and rendered by the UI.
  await expect(
    page.locator(".tool-result", { hasText: "late-output-marker" }),
  ).toBeVisible({ timeout: 10_000 });
});

test("kill stops codex background command before delayed side effect", async ({
  page,
  agentType,
}) => {
  test.skip(
    agentType !== "codex",
    "codex-only: pooled app-server kill behavior",
  );

  await enterSession(page);

  const marker = `/tmp/cydo-codex-kill-marker-${Date.now()}-${Math.random().toString(16).slice(2)}.txt`;
  rmSync(marker, { force: true });

  await sendMessage(
    page,
    `run background command sh -c "sleep 6; touch ${marker}"`,
  );

  await expect(page.locator(".tool-call")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  await killSession(page, agentType);
  await page.waitForTimeout(8_000);
  expect(existsSync(marker)).toBe(false);
  rmSync(marker, { force: true });
});

test("killing one codex task also interrupts sibling session on pooled server", async ({
  page,
  agentType,
}) => {
  test.skip(
    agentType !== "codex",
    "codex-only: pooled app-server sibling interruption",
  );

  const markerA = `/tmp/cydo-codex-kill-sibling-a-${Date.now()}-${Math.random().toString(16).slice(2)}.txt`;
  const markerB = `/tmp/cydo-codex-kill-sibling-b-${Date.now()}-${Math.random().toString(16).slice(2)}.txt`;
  rmSync(markerA, { force: true });
  rmSync(markerB, { force: true });

  await enterSession(page);
  await sendMessage(
    page,
    `run background command sh -c "sleep 8; touch ${markerA}"`,
  );
  await expect(page.locator(".tool-call")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  await enterSession(page);
  await sendMessage(
    page,
    `run background command sh -c "sleep 8; touch ${markerB}"`,
  );
  await expect(page.locator(".tool-call")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  await killSession(page, agentType);

  await page.waitForTimeout(9_000);
  const siblingWasInterrupted = !existsSync(markerA);
  expect(existsSync(markerB)).toBe(false);

  if (!siblingWasInterrupted) {
    rmSync(markerA, { force: true });
    rmSync(markerB, { force: true });
    return;
  }

  const siblingTask = page
    .locator(".sidebar-item:not(.active):not(.sidebar-new-task)")
    .first();
  await siblingTask.click({ timeout: 15_000 });
  await expect(page.locator(".btn-banner-resume")).toBeVisible({
    timeout: 30_000,
  });

  await page.locator(".btn-banner-resume").click();
  await sendMessage(page, 'Please reply with "sibling-resumed"');
  await expect(assistantText(page, "sibling-resumed")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  rmSync(markerA, { force: true });
  rmSync(markerB, { force: true });
});
