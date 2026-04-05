import { test, expect, enterSession, sendMessage, responseTimeout } from "./fixtures";

test("codex context compaction shows compacting status", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "codex", "codex-only: context compaction");

  await enterSession(page);
  const timeout = responseTimeout(agentType);

  // Turn 1: "trigger compaction" → mock returns text with total_tokens=500000,
  // which exceeds CYDO_CODEX_COMPACT_LIMIT=100
  await sendMessage(page, "trigger compaction");
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "Ready for compaction.",
    }),
  ).toBeVisible({ timeout });

  // Turn 2: any follow-up triggers pre-turn compaction before processing
  await sendMessage(page, 'reply with "After compaction."');

  // Wait for the final response — confirms the turn completed after compaction
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "After compaction.",
    }),
  ).toBeVisible({ timeout });

  // Verify compaction boundary message appeared (from thread/compacted)
  await expect(
    page.locator(".compact-boundary-message"),
  ).toBeVisible({ timeout });
});
