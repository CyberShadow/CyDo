import { test, expect, enterSession, sendMessage, responseTimeout } from "./fixtures";

/**
 * Regression test: after multi-turn conversations with tool calls, the
 * mergeStreamingDelta optimisation in app.d can cause msg.rawSource (abstract
 * events) and msg.seq (backend indices) to drift apart. When that happens the
 * Raw tab shows the wrong raw event for a given Abstract event.
 *
 * This test sends multiple tool-call turns, opens the source view on the last
 * assistant message, and checks that every event's Abstract type is consistent
 * with its Raw data.
 */
test("source view abstract/raw events stay aligned across multi-turn streaming", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "claude", "stream events are Claude-protocol only");

  await enterSession(page);
  const timeout = responseTimeout(agentType);

  // Send 3 turns that each trigger a tool call, to accumulate potential
  // seq drift from merged item/delta events.
  for (const marker of ["seq-align-1", "seq-align-2", "seq-align-3"]) {
    await sendMessage(page, `run command echo ${marker}`);
    await expect(
      page.locator(".tool-result", { hasText: marker }),
    ).toBeVisible({ timeout });
    await expect(
      page.locator(".message.assistant-message .text-content", { hasText: "Done." }).last(),
    ).toBeVisible({ timeout });
  }

  // Find the last assistant message (the third "Done.")
  const lastAssistantMsg = page
    .locator(".message-wrapper")
    .filter({
      has: page.locator(".message.assistant-message .text-content", { hasText: "Done." }),
    })
    .last();
  await lastAssistantMsg.hover();

  // Open source view
  const viewSourceBtn = lastAssistantMsg.locator(".view-source-btn");
  await expect(viewSourceBtn).toBeVisible({ timeout: 5_000 });
  await viewSourceBtn.click();

  const sourceView = page.locator(".source-view").last();
  await expect(sourceView).toBeVisible({ timeout: 5_000 });

  // Collect all event headers
  const eventHeaders = sourceView.locator(".source-event-header");
  await expect(eventHeaders.first()).toBeVisible({ timeout: 5_000 });
  const eventCount = await eventHeaders.count();
  expect(eventCount).toBeGreaterThan(0);

  // For each event: expand, read abstract type, switch to Raw, read raw type,
  // and verify consistency.
  for (let i = 0; i < eventCount; i++) {
    const header = eventHeaders.nth(i);
    const abstractType = await header.locator(".source-event-type").innerText();

    // Expand the event
    await header.click();

    // The event body should now be visible
    const eventItem = sourceView.locator(".source-event").nth(i);
    const eventBody = eventItem.locator(".source-event-body");
    await expect(eventBody).toBeVisible({ timeout: 5_000 });

    // Check if a Raw tab exists (it may not if no raw data)
    const rawTab = eventBody.locator(".source-tab", { hasText: "Raw" });
    const hasRawTab = (await rawTab.count()) > 0;

    if (hasRawTab) {
      await rawTab.click();

      // Wait for raw JSON to load
      const rawBlock = eventBody.locator(".code-pre-wrap").first();
      await expect(rawBlock).toBeVisible({ timeout: 10_000 });

      const rawText = await rawBlock.locator("pre").innerText();

      let rawObj: Record<string, unknown>;
      try {
        rawObj = JSON.parse(rawText.trim());
      } catch {
        throw new Error(
          `Event ${i} (${abstractType}): raw JSON should be parseable, got: ${rawText.slice(0, 200)}`,
        );
      }

      // The key assertion: abstract type must be consistent with raw data.
      // They don't need to be identical but must not be from completely
      // different wire events.
      assertConsistency(abstractType, rawObj, i);
    }

    // Collapse the event before moving to the next one
    await header.click();
    await expect(eventBody).not.toBeVisible({ timeout: 2_000 });
  }
});

/**
 * Assert that the abstract event type is consistent with the raw event data.
 *
 * Abstract types are translated from Claude's wire protocol:
 * - item/started   → raw: content_block_start stream_event or assistant JSONL
 * - item/completed → raw: content_block_stop stream_event or assistant JSONL
 * - item/delta     → raw: content_block_delta stream_event (shouldn't normally appear)
 * - turn/delta     → raw: assistant JSONL or message_delta stream_event
 * - turn/stop      → raw: message_stop stream_event or assistant JSONL
 *
 * If an abstract and raw event come from completely different wire events
 * (e.g. item/started paired with a message_stop) that indicates the desync bug.
 */
function assertConsistency(
  abstractType: string,
  rawObj: Record<string, unknown>,
  index: number,
) {
  const expectedFamilies = getExpectedFamilies(abstractType);
  if (expectedFamilies.length === 0) return; // no mapping defined — skip

  const rawFamily = getRawFamily(rawObj);

  expect(
    expectedFamilies,
    `Event ${index}: abstract "${abstractType}" paired with raw family "${rawFamily}". ` +
      `Expected one of [${expectedFamilies.join(", ")}]. ` +
      `This likely indicates a seq desync between abstract events and raw source indices.`,
  ).toContain(rawFamily);
}

function getRawFamily(rawObj: Record<string, unknown>): string {
  const rawType = typeof rawObj.type === "string" ? rawObj.type : undefined;

  if (rawType === "assistant") return "assistant";

  if (rawType === "stream_event") {
    // Claude outputs: {"type":"stream_event","event":{"type":"content_block_start",...}}
    const innerEvent = rawObj.event as Record<string, unknown> | undefined;
    const st = typeof innerEvent?.type === "string" ? innerEvent.type : "";
    if (st.includes("content_block_start")) return "content_block_start";
    if (st.includes("content_block_delta")) return "content_block_delta";
    if (st.includes("content_block_stop")) return "content_block_stop";
    if (st.includes("message_start")) return "message_start";
    if (st.includes("message_stop")) return "message_stop";
    if (st.includes("message_delta")) return "message_delta";
    return `stream_event:${st || "unknown"}`;
  }

  if (rawType) return rawType;

  // Fallback: detect assistant shape without "type" field
  if ("content" in rawObj && "role" in rawObj) return "assistant";

  return "unknown";
}

function getExpectedFamilies(abstractType: string): string[] {
  switch (abstractType) {
    case "item/started":
      return ["content_block_start", "assistant"];
    case "item/completed":
      return ["content_block_stop", "assistant"];
    case "item/delta":
      return ["content_block_delta", "assistant"];
    case "turn/delta":
      return ["assistant", "message_delta"];
    case "turn/stop":
      return ["message_stop", "assistant"];
    default:
      return [];
  }
}
