import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
} from "./fixtures";

// Helper: send a message and wait for the assistant's response text.
async function sendAndWait(
  page: Parameters<typeof sendMessage>[0],
  msg: string,
  agentType: string,
) {
  await sendMessage(page, msg);
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: msg.match(/reply with "([^"]*)"/)?.[1] ?? msg,
    }),
  ).toBeVisible({ timeout: responseTimeout(agentType as any) });
}

// Helper: wait for suggestions and return all button raw text contents.
// Uses textContent() (not innerText()) to preserve newlines in the body.
async function getSuggestionTexts(
  page: Parameters<typeof sendMessage>[0],
): Promise<string[]> {
  const suggestions = page.locator(".btn-suggestion");
  await expect(suggestions.first()).toBeVisible({ timeout: 30_000 });
  const count = await suggestions.count();
  const texts: string[] = [];
  for (let i = 0; i < count; i++) {
    texts.push((await suggestions.nth(i).textContent()) ?? "");
  }
  return texts;
}

// The mock server echoes suggestions as JSON: ["run the tests", sessionHeader, convBody]
// Index 1 = session header ("[Session: N user messages, M tool uses]")
// Index 2 = conversation body (abbreviated history body)

test("multi-turn suggestion context has no spurious [...] markers", async ({
  page,
  agentType,
}) => {
  await enterSession(page);

  // Send 3 messages (text-only, no tool calls)
  await sendAndWait(page, 'Please reply with "alpha"', agentType);
  await sendAndWait(page, 'Please reply with "beta"', agentType);
  await sendAndWait(page, 'Please reply with "gamma"', agentType);

  const texts = await getSuggestionTexts(page);

  // Session header (2nd suggestion) should report 3 user messages and 0 tool uses
  const header = texts.length >= 2 ? texts[1] : "";
  expect(
    header,
    `Expected session header as 2nd suggestion, got: ${texts.join(" | ")}`,
  ).toMatch(/3 user messages/);
  expect(header).toMatch(/0 tool uses/);

  // Conversation body (3rd suggestion) should have no spurious [...] standalone entries.
  // Note: [...] CAN appear embedded within a truncated USER message (from abbreviateText),
  // but must NOT appear as a standalone paragraph (entry on its own line).
  // Standalone [...]  entries look like "\n\n[...]\n\n" in the raw body.
  const convBody = texts.length >= 3 ? texts[2] : "";
  expect(
    convBody,
    `Conversation body should not contain a standalone [...] entry, got: ${convBody}`,
  ).not.toMatch(/(^|\n\n)\[\.\.\.]\s*(\n\n|$)/);

  // Should contain USER: and A: entries for all 3 turns
  const userMatches = convBody.match(/USER:/g) ?? [];
  const aMatches = convBody.match(/\bA: /g) ?? [];
  expect(
    userMatches.length,
    `Expected >= 3 USER: entries, got ${userMatches.length}`,
  ).toBeGreaterThanOrEqual(3);
  expect(
    aMatches.length,
    `Expected >= 3 A: entries, got ${aMatches.length}`,
  ).toBeGreaterThanOrEqual(3);
});

test("suggestion context truncates by turns not entries", async ({
  page,
  agentType,
}) => {
  await enterSession(page);

  // Send 5 messages — exceeds the 4-turn limit
  for (const word of ["one", "two", "three", "four", "five"]) {
    await sendAndWait(page, `Please reply with "${word}"`, agentType);
  }

  const texts = await getSuggestionTexts(page);

  // Session header should report 5 user messages
  const header = texts.length >= 2 ? texts[1] : "";
  expect(header).toMatch(/5 user messages/);

  // Conversation body should contain exactly 4 USER: and 4 A: entries (last 4 turns)
  const convBody = texts.length >= 3 ? texts[2] : "";
  const userMatches = convBody.match(/USER:/g) ?? [];
  const aMatches = convBody.match(/\bA: /g) ?? [];
  expect(
    userMatches.length,
    `Expected exactly 4 USER: entries in truncated body, got ${userMatches.length}. Body: ${convBody}`,
  ).toBe(4);
  expect(
    aMatches.length,
    `Expected exactly 4 A: entries in truncated body, got ${aMatches.length}. Body: ${convBody}`,
  ).toBe(4);
});
