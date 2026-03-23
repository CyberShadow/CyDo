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

test("user message appears above assistant response during live session", async ({
  page,
  agentType,
}) => {
  await enterSession(page);

  // Send a simple message that triggers a text reply
  await sendMessage(page, 'reply with "hello-order-test"');

  // Wait for the assistant response to appear in the DOM
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "hello-order-test",
    }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  // Wait for the confirmed (non-pending) user message
  await expect(
    page.locator(".message.user-message:not(.pending)"),
  ).toBeVisible({ timeout: 15_000 });

  // Check DOM order: user message must come BEFORE assistant in the same
  // message list.  Use compareDocumentPosition to avoid relying on
  // innerText (which returns "" for elements inside display:none containers
  // from other cached sessions rendered in the background).
  const userBefore = await page
    .locator(".message.user-message:not(.pending)")
    .evaluate((userEl) => {
      const msgList = userEl.closest(".message-list");
      if (!msgList) return { ok: false, reason: "no .message-list ancestor" };
      const assistantEl = msgList.querySelector(".message.assistant-message");
      if (!assistantEl) return { ok: false, reason: "no .message.assistant-message in list" };
      // DOCUMENT_POSITION_FOLLOWING (4): assistantEl comes after userEl in DOM
      const pos = userEl.compareDocumentPosition(assistantEl);
      const ok = (pos & Node.DOCUMENT_POSITION_FOLLOWING) !== 0;
      return { ok, reason: ok ? "" : "assistant appears before user in DOM" };
    });

  expect(
    userBefore.ok,
    `User message must appear before (above) assistant response in DOM order.\n` +
      `Reason: ${userBefore.reason}`,
  ).toBe(true);
});
