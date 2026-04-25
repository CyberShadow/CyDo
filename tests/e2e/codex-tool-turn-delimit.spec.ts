import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
} from "./fixtures";

// Regression test for tool turn delimiting in Codex sessions.
//
// When Codex executes a multi-inference-pass turn (e.g., a tool call followed
// by a text response), each inference pass should produce a separate assistant
// message in the UI. The backend emits an intermediate turn/stop on each
// thread/tokenUsage/updated notification to delimit the messages.
//
// Without this, all content from the turn appears in a single assistant message
// and the tool call and final text response are not visually separated.

test("codex tool turn produces separate assistant messages for tool call and response", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "codex", "codex-only: tool turn delimiting");

  await enterSession(page);

  // "run command echo hello" triggers:
  // 1. First API response: exec_command(echo hello) tool call → response.completed
  //    → Codex emits thread/tokenUsage/updated → backend emits intermediate turn/stop
  // 2. Codex runs echo hello, sends output back to API
  // 3. Second API response (isToolOutput): text "Done." → response.completed
  //    → Codex emits thread/tokenUsage/updated → backend emits intermediate turn/stop
  // 4. turn/completed → hadItemsSinceLastStop_=false → no redundant turn/stop
  await sendMessage(page, "run command echo hello");

  const timeout = responseTimeout(agentType);

  // Wait for the turn to complete — "Done." text response appears
  await expect(assistantText(page, "Done.")).toBeVisible({ timeout });

  // Verify two separate assistant messages were created (one for the tool call,
  // one for "Done."). The intermediate turn/stop from thread/tokenUsage/updated
  // seals the first message before the second inference pass starts.
  const assistantMessages = page.locator(".message.assistant-message");
  await expect(assistantMessages).toHaveCount(2, { timeout: 5_000 });

  // First message should contain the tool call block (commandExecution)
  await expect(assistantMessages.first().locator(".tool-call")).toBeVisible({
    timeout: 5_000,
  });

  // Second message should contain the "Done." text
  await expect(
    assistantMessages.nth(1).locator('[data-testid="assistant-text"]', {
      hasText: "Done.",
    }),
  ).toBeVisible({ timeout: 5_000 });
});
