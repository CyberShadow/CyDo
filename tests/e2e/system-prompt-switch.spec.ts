import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
} from "./fixtures";

test("new system prompt is present after keep_context mode switch", async ({
  page,
  agentType,
}) => {
  await enterSession(page);

  // Create a sub-task of type test_sysprompt_mode_a. Its system prompt contains
  // MARKER_A. The prompt tells it to switch to mode_b via the "check_new" continuation.
  // After the switch, the continuation prompt (test_sysprompt_check_b.md) checks
  // that MARKER_B (mode_b's system prompt) is present in the API context.
  await sendMessage(
    page,
    "call task test_sysprompt_mode_a call switchmode check_new",
  );

  // The sub-task should report "context-check-passed" — MARKER_B is in the context.
  await expect(
    page
      .locator(".tool-result-container .text-content:visible", {
        hasText: "context-check-passed",
      })
      .first(),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
});

test("old system prompt is absent after keep_context mode switch", async ({
  page,
  agentType,
}) => {
  test.skip(
    agentType === "codex",
    "Codex injects task system prompts through user input fallback instead of developer prompt channel",
  );

  await enterSession(page);

  // Same setup but using "check_old_absent" continuation, whose prompt checks
  // for MARKER_A (mode_a's system prompt). After switching to mode_b, MARKER_A
  // should no longer be in the system prompt.
  await sendMessage(
    page,
    "call task test_sysprompt_mode_a call switchmode check_old_absent",
  );

  // The sub-task should report "context-check-failed" — MARKER_A is NOT in the context.
  await expect(
    page
      .locator(".tool-result-container .text-content:visible", {
        hasText: "context-check-failed",
      })
      .first(),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
});
