/**
 * Regression test: user messages must appear ABOVE the assistant response
 * they triggered, not below.
 *
 * Bug: commit bef37f3 removed `reduceUserReplay` (which used
 * `insertBeforeStreaming`) and unified all user echoes into
 * `reduceUserEcho`, which always appends confirmed echoes at the END
 * of the message list.
 *
 * When Claude Code outputs streaming events (content_block_start, etc.)
 * before the user echo (type: "user"), the streaming assistant message
 * is created first.  Then `reduceUserEcho` removes the pending
 * placeholder and appends the confirmed echo at the end — AFTER the
 * streaming assistant.  The user message "jumps" from above (pending
 * placeholder) to below (confirmed echo) the assistant response.
 *
 * Expected order:  [user] [assistant]
 * Actual order:    [assistant] [user]
 */
import { test, expect, enterSession, sendMessage, responseTimeout } from "./fixtures";

/**
 * Collect [type, textSnippet] pairs for every visible user/assistant
 * message in the message list.
 */
async function collectMessageOrder(page: import("@playwright/test").Page) {
  const allMessages = page.locator(".message-list .message");
  const count = await allMessages.count();
  const entries: Array<{ type: string; text: string; pending: boolean }> = [];
  for (let i = 0; i < count; i++) {
    const el = allMessages.nth(i);
    const classes = (await el.getAttribute("class")) ?? "";
    if (classes.includes("user-message")) {
      entries.push({
        type: "user",
        text: (await el.innerText()).slice(0, 80),
        pending: classes.includes("pending"),
      });
    } else if (classes.includes("assistant-message")) {
      entries.push({
        type: "assistant",
        text: (await el.innerText()).slice(0, 80),
        pending: false,
      });
    }
  }
  return entries;
}

test("user message appears above assistant response during live session", async ({
  page,
  agentType,
}) => {
  await enterSession(page);

  // Send a simple message that triggers a text reply
  await sendMessage(page, 'reply with "hello-order-test"');

  // Wait for the assistant response
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "hello-order-test",
    }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  // Wait for the confirmed (non-pending) user message
  await expect(
    page.locator(".message.user-message:not(.pending)"),
  ).toBeVisible({ timeout: 15_000 });

  // Collect message order and verify: user must come BEFORE assistant
  const entries = await collectMessageOrder(page);
  const userIdx = entries.findIndex(
    (e) => e.type === "user" && !e.pending,
  );
  const assistantIdx = entries.findIndex(
    (e) => e.type === "assistant" && e.text.includes("hello-order-test"),
  );

  expect(
    userIdx,
    "User message should be found in DOM",
  ).toBeGreaterThanOrEqual(0);
  expect(
    assistantIdx,
    "Assistant message should be found in DOM",
  ).toBeGreaterThanOrEqual(0);
  expect(
    userIdx,
    `User message (index ${userIdx}) must appear BEFORE assistant ` +
      `(index ${assistantIdx}) in DOM.\n` +
      `Messages: ${entries.map((e) => `${e.type}${e.pending ? "(pending)" : ""}`).join(", ")}`,
  ).toBeLessThan(assistantIdx);
});
