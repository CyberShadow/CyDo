import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
} from "./fixtures";

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
  await expect(assistantText(page, "Ready for compaction.")).toBeVisible({
    timeout,
  });

  // Turn 2: any follow-up triggers pre-turn compaction before processing
  await sendMessage(page, 'reply with "After compaction."');

  // Wait for the final response — confirms the turn completed after compaction
  await expect(assistantText(page, "After compaction.")).toBeVisible({
    timeout,
  });

  // session/status must not pollute the transcript.
  await expect(page.locator(".system-status-message")).toHaveCount(0);

  // Verify compaction boundary message appeared (from thread/compacted)
  await expect(page.locator(".compact-boundary-message")).toBeVisible({
    timeout,
  });
});

test("codex reconnect during active turn does not replay stale compacting status", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "codex", "codex-only: active reconnect replay");

  const frames: any[] = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        frames.push(JSON.parse(event.payload.toString()));
      } catch {
        // ignore non-JSON frames
      }
    });
  });

  await enterSession(page);
  const timeout = responseTimeout(agentType);

  // Turn 1 inflates total_tokens so turn 2 triggers pre-turn compaction.
  await sendMessage(page, "trigger compaction");
  await expect(assistantText(page, "Ready for compaction.")).toBeVisible({
    timeout,
  });

  // Turn 2 keeps processing long enough to reconnect mid-turn.
  await sendMessage(page, "run background command sleep 8");

  // Wait until the live stream reports compacting before reloading.
  await expect
    .poll(() =>
      frames.some(
        (msg) =>
          msg?.event?.type === "session/status" &&
          typeof msg?.event?.status === "string" &&
          /compact/i.test(msg.event.status),
      ),
    )
    .toBe(true);

  const beforeReloadIdx = frames.length;
  await page.reload();
  await page
    .locator(".sidebar-item .sidebar-label", { hasText: "trigger compaction" })
    .first()
    .click({ timeout: 15_000 });

  await expect(assistantText(page, "Done.")).toBeVisible({ timeout });

  const replayFrames = frames.slice(beforeReloadIdx);
  const historyEndIdx = replayFrames.findIndex(
    (msg) => msg?.type === "task_history_end",
  );
  expect(historyEndIdx).toBeGreaterThanOrEqual(0);

  const resultIdx = replayFrames.findIndex(
    (msg, idx) => idx > historyEndIdx && msg?.event?.type === "turn/result",
  );
  expect(resultIdx).toBeGreaterThan(historyEndIdx);

  // During active replay, stale compacting status from prior history must not
  // reappear after task_history_end.
  const compactingAfterHistory = replayFrames
    .slice(historyEndIdx + 1, resultIdx)
    .some(
      (msg) =>
        msg?.event?.type === "session/status" &&
        typeof msg?.event?.status === "string" &&
        /compact/i.test(msg.event.status),
    );
  expect(compactingAfterHistory).toBe(false);

  await expect(page.locator(".system-status-message")).toHaveCount(0);
  await expect(page.locator(".compact-boundary-message")).toBeVisible({
    timeout,
  });
});
