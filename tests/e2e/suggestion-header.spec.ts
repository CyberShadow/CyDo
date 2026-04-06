import { test, expect, enterSession, sendMessage, responseTimeout } from "./fixtures";

// Regression test: buildAbbreviatedHistory must count user messages correctly.
// The suggestion prompt's [Session: N user messages, ...] header should reflect
// the actual number of user messages sent, not 0.
test("suggestion header reports correct user message count", async ({ page, agentType }) => {
  await enterSession(page);
  await sendMessage(page, 'Please reply with "done"');

  // Wait for agent response
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "done" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  // Wait for suggestions to appear (the mock echoes the session header as second suggestion)
  const suggestions = page.locator(".btn-suggestion");
  await expect(suggestions.first()).toBeVisible({ timeout: 30_000 });

  // Collect all suggestion texts
  const count = await suggestions.count();
  const texts: string[] = [];
  for (let i = 0; i < count; i++) {
    texts.push(await suggestions.nth(i).innerText());
  }

  // Find the suggestion that contains the session header
  const headerSuggestion = texts.find((t) => t.startsWith("[Session:"));
  expect(headerSuggestion, `Expected a session header suggestion, got: ${texts.join(", ")}`).toBeDefined();

  // The header should report >= 1 user messages (we sent one message).
  // Bug: buildAbbreviatedHistory checked for "message/user" but history uses
  // "item/started" with item_type "user_message", so the count was always 0.
  const msgCountMatch = headerSuggestion!.match(/(\d+) user messages/);
  expect(msgCountMatch, `Could not parse user message count from: ${headerSuggestion}`).not.toBeNull();
  const userMsgCount = parseInt(msgCountMatch![1], 10);
  expect(userMsgCount, `User message count should be >= 1 but was ${userMsgCount}`).toBeGreaterThanOrEqual(1);
});
