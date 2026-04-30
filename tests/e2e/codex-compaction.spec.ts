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
  // shell intent (not background_shell) delays response.completed by 5s.
  await sendMessage(page, "run command sleep 5");

  // Wait until the live stream reports compacting before reloading.
  await expect
    .poll(
      () =>
        frames.some(
          (msg) =>
            msg?.event?.type === "session/status" &&
            typeof msg?.event?.status === "string" &&
            /compact/i.test(msg.event.status),
        ),
      { timeout },
    )
    .toBe(true);

  const beforeReloadIdx = frames.length;
  await page.reload();
  await page
    .locator('.sidebar-item[data-tid="1"]')
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

test("codex compaction reminder steers active turn before keep_context continuation", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "codex", "codex-only: post-compaction continuation");

  await enterSession(page);
  const timeout = responseTimeout(agentType);

  await page.locator(".task-type-row", { hasText: "sysprompt_mode_a" }).click();
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("sysprompt_mode_a");

  await sendMessage(page, "trigger compaction");
  await expect(assistantText(page, "Ready for compaction.")).toBeVisible({
    timeout,
  });

  await sendMessage(page, "call switchmode check_old_user_absent");
  await expect(assistantText(page, "context-check-failed")).toBeVisible({
    timeout,
  });

  const reminderDivider = page
    .locator(".result-divider.system-user-message", {
      hasText: "Post-compaction task mode reminder",
    })
    .first();
  await expect(reminderDivider).toBeVisible({ timeout });
  await expect(reminderDivider).not.toContainText("[CYDO TASK MODE REMINDER]");
  await reminderDivider.click();
  await expect(
    page.locator(".message.user-message.system-user-expanded", {
      hasText: "[CYDO TASK MODE REMINDER]",
    }).first(),
  ).toBeVisible({ timeout });

  const order = await page.locator(".message").evaluateAll((nodes) => {
    const reminderIdx = nodes.findIndex((n) =>
      n.classList.contains("user-message") &&
      n.textContent?.includes("[CYDO TASK MODE REMINDER]"),
    );
    const resultIdx = nodes.findIndex((n) =>
      n.classList.contains("assistant-message") &&
      n.textContent?.includes("context-check-failed"),
    );
    return { reminderIdx, resultIdx };
  });
  expect(order.reminderIdx).toBeGreaterThanOrEqual(0);
  expect(order.resultIdx).toBeGreaterThanOrEqual(0);
  expect(order.reminderIdx).toBeLessThan(order.resultIdx);
});

test("codex compaction reminder steers autonomous continuation without extra user message", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "codex", "codex-only: autonomous compaction continuation");

  await enterSession(page);
  const timeout = responseTimeout(agentType);

  await page.locator(".task-type-row", { hasText: "sysprompt_mode_a" }).click();
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("sysprompt_mode_a");

  await sendMessage(page, "autonomous compaction reminder fixture");

  await expect(
    assistantText(page, "autonomous-reminder-observed"),
  ).toBeVisible({ timeout });

  const reminderDivider = page
    .locator(".result-divider.system-user-message", {
      hasText: "Post-compaction task mode reminder",
    })
    .first();
  await expect(reminderDivider).toBeVisible({ timeout });
  await expect(reminderDivider).not.toContainText("[CYDO TASK MODE REMINDER]");
  await reminderDivider.click();
  await expect(
    page.locator(".message.user-message.system-user-expanded", {
      hasText: "[CYDO TASK MODE REMINDER]",
    }).first(),
  ).toBeVisible({ timeout });

  const order = await page.locator(".message").evaluateAll((nodes) => {
    const reminderIdx = nodes.findIndex((n) =>
      n.classList.contains("user-message") &&
      n.textContent?.includes("[CYDO TASK MODE REMINDER]"),
    );
    const resultIdx = nodes.findIndex((n) =>
      n.classList.contains("assistant-message") &&
      n.textContent?.includes("autonomous-reminder-observed"),
    );
    return { reminderIdx, resultIdx };
  });
  expect(order.reminderIdx).toBeGreaterThanOrEqual(0);
  expect(order.resultIdx).toBeGreaterThanOrEqual(0);
  expect(order.reminderIdx).toBeLessThan(order.resultIdx);
});
