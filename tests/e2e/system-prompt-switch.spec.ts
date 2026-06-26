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

  // Create a sub-task of type test_sysprompt_mode_a. Its generated guidance contains
  // the mode A marker. The prompt tells it to switch to mode_b via the "check_new"
  // continuation.
  // After the switch, the continuation prompt (test_sysprompt_check_b.md) checks
  // that the mode B generated-guidance marker is present in the API context.
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

test("old system prompt is absent after keep_context mode switch", { tag: "@no-codex" }, async ({
  page,
  agentType,
}) => {

  await enterSession(page);

  // Same setup but using "check_old_absent" continuation, whose prompt checks
  // for the mode A generated-guidance marker. After switching to mode_b, the
  // old mode A guidance should no longer be in the system prompt.
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
