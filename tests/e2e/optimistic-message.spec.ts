import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
  lastAssistantText,
} from "./fixtures";

test("user bubble appears immediately after Send (ack-4 optimistic render)", { tag: "@claude-only" }, async ({
  page,
  agentType,
}) => {

  await enterSession(page);

  // Send a stalling message so the backend never completes the turn.
  // The user bubble must appear before the LLM replies.
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill("stall session");
  const sendBtn = page.locator(".btn-send:visible").first();
  await expect(sendBtn).toBeEnabled({ timeout: 5_000 });

  // Click send — do NOT await the assistant reply, check immediately.
  await sendBtn.click();

  // The optimistic bubble must be visible within one render cycle.
  await expect(
    page.locator(".user-message", { hasText: "stall session" }),
  ).toBeVisible({ timeout: 3_000 });
});

test("outbox replays unsent message after offline reload", { tag: "@claude-only" }, async ({
  page,
  agentType,
}) => {

  await enterSession(page);

  // Establish a real session by exchanging one message so we have a task tid.
  await sendMessage(page, 'Please reply with "outbox-test-established"');
  await expect(assistantText(page, "outbox-test-established")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // Go offline so the next send cannot reach the backend.
  await page.context().setOffline(true);

  // Fill and click Send while offline — the outbox captures the message,
  // an ack-4 placeholder appears, but no bytes reach the backend.
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill('Please reply with "outbox-recovery"');
  const sendBtn = page.locator(".btn-send:visible").first();
  await expect(sendBtn).toBeEnabled({ timeout: 5_000 });
  await sendBtn.click();

  // Placeholder should be visible with ack-4 (offline, no backend ack).
  await expect(
    page.locator(".user-message", { hasText: "outbox-recovery" }),
  ).toBeVisible({ timeout: 3_000 });

  // Verify outbox has an entry.
  const outboxBefore = await page.evaluate(() =>
    JSON.parse(localStorage.getItem("cydo.outbox.v1") ?? "[]"),
  );
  expect(outboxBefore.length).toBeGreaterThan(0);

  // Come back online and reload — the outbox will replay on reconnect.
  await page.context().setOffline(false);
  await page.reload();

  // Navigate back to the task via sidebar.
  await page
    .locator(".sidebar-item .sidebar-label", {
      hasText: "outbox-test-established",
    })
    .click({ timeout: 15_000 });

  // The replayed message should eventually get a response.
  await expect(assistantText(page, "outbox-recovery")).toBeVisible({
    timeout: responseTimeout(agentType),
  });
});

test("backend deduplicates message sent twice with same nonce", { tag: "@claude-only" }, async ({
  page,
  agentType,
}) => {

  await enterSession(page);

  // Capture the first non-empty outbox write before the send path runs so a
  // fast backend ack cannot race the test's snapshot read.
  await page.evaluate(() => {
    const storage = Storage.prototype as Storage & {
      __cydoTestSetItemWrapped?: boolean;
      __cydoTestOriginalSetItem?: Storage["setItem"];
    };
    const testWindow = window as Window & {
      __cydoTestOutboxSnapshot?: unknown[];
    };

    testWindow.__cydoTestOutboxSnapshot = undefined;
    if (storage.__cydoTestSetItemWrapped) return;

    storage.__cydoTestOriginalSetItem = storage.setItem;
    storage.setItem = function (key: string, value: string) {
      if (key === "cydo.outbox.v1" && testWindow.__cydoTestOutboxSnapshot === undefined) {
        const parsed = JSON.parse(value);
        if (Array.isArray(parsed) && parsed.length > 0) {
          testWindow.__cydoTestOutboxSnapshot = parsed;
        }
      }
      storage.__cydoTestOriginalSetItem!.call(this, key, value);
    };
    storage.__cydoTestSetItemWrapped = true;
  });

  // Start sending the message and recover the nonce from the captured write.
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill('Please reply with "dedupe-test"');
  const sendBtn = page.locator(".btn-send:visible").first();
  await expect(sendBtn).toBeEnabled({ timeout: 5_000 });
  await sendBtn.click();

  const outboxSnapshot = await page.evaluate(() => {
    const testWindow = window as Window & {
      __cydoTestOutboxSnapshot?: unknown[];
    };
    return testWindow.__cydoTestOutboxSnapshot ?? [];
  });
  expect(outboxSnapshot.length).toBeGreaterThan(0);
  const { nonce, tid, content } = outboxSnapshot[0] as {
    nonce: string;
    tid: number;
    content: unknown;
  };

  // Wait for the full round-trip: assistant replies and outbox is cleared.
  await expect(assistantText(page, "dedupe-test")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // The outbox should now be empty (ack-3 removed the entry).
  const outboxAfterAck = await page.evaluate(() =>
    JSON.parse(localStorage.getItem("cydo.outbox.v1") ?? "[]"),
  );
  expect(outboxAfterAck).toHaveLength(0);

  // Re-inject the SAME nonce into the outbox to simulate a stale replay.
  await page.evaluate(
    ({
      tid,
      nonce,
      content,
    }: {
      tid: number;
      nonce: string;
      content: unknown;
    }) => {
      const entry = { tid, nonce, content, createdAt: Date.now() - 1000 };
      localStorage.setItem("cydo.outbox.v1", JSON.stringify([entry]));
    },
    { tid, nonce, content },
  );

  // Reload so the outbox replayer fires with the same nonce.
  await page.reload();
  await page
    .locator(".sidebar-item .sidebar-label", { hasText: "dedupe-test" })
    .click({ timeout: 15_000 });

  // Wait for the task to be visible, then check no second reply arrives.
  await expect(assistantText(page, "dedupe-test").first()).toBeVisible({
    timeout: responseTimeout(agentType),
  });
  await page.waitForTimeout(2_000);
  await expect(assistantText(page, "dedupe-test")).toHaveCount(1);
});

test("outbox entry evicted after backend ack", { tag: "@claude-only" }, async ({ page, agentType }) => {

  await enterSession(page);

  // Send a message and wait for the assistant to reply (full round-trip).
  await sendMessage(page, 'Please reply with "eviction-test"');
  await expect(assistantText(page, "eviction-test")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // After the assistant replies, the outbox should be empty (ack-3 removed the entry).
  const outboxAfter = await page.evaluate(() =>
    JSON.parse(localStorage.getItem("cydo.outbox.v1") ?? "[]"),
  );
  expect(outboxAfter).toHaveLength(0);
});

// ──── ack-2 state-transition specs ────────────────────────────────────────

test("codex emits agentAck on turn/start response (ack-2 signal)", { tag: "@codex-only" }, async ({
  page,
  agentType,
}) => {

  // Capture agentAck frames before page.goto so the WebSocket listener is in
  // place when the connection is established.
  const agentAcks: string[] = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        const data = JSON.parse(event.payload.toString());
        if (
          "agentAck" in data &&
          typeof data.agentAck === "string" &&
          data.agentAck
        ) {
          agentAcks.push(data.agentAck);
        }
      } catch {
        // ignore non-JSON frames
      }
    });
  });

  await enterSession(page);

  // Establish session with a completing first turn so the second message uses
  // the normal sendMessage path (with a nonce).
  await sendMessage(page, 'Please reply with "codex-ack2-ready"');
  await expect(assistantText(page, "codex-ack2-ready")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  const acksBeforeStall = agentAcks.length;

  // Send a stalling second message — this starts a new turn via turn/start.
  // agentAck is emitted as soon as turn/start returns (before the LLM stalls).
  await sendMessage(page, "stall session");

  // The DOM transition ack-4 → ack-3 → ack-2 is too fast to observe directly
  // (item/started fires within ~3 ms and replaces the placeholder).  Verify
  // instead that the backend emitted an agentAck WebSocket frame — that is the
  // agentAck signal that drives the ack-2 state.
  await expect
    .poll(() => agentAcks.length, { timeout: responseTimeout(agentType) })
    .toBeGreaterThan(acksBeforeStall);
});

test("copilot emits agentAck on session.send (ack-2 signal)", { tag: "@copilot-only" }, async ({
  page,
  agentType,
}) => {

  // Capture agentAck frames before page.goto so the WebSocket listener is in
  // place when the connection is established.
  const agentAcks: string[] = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        const data = JSON.parse(event.payload.toString());
        if (
          "agentAck" in data &&
          typeof data.agentAck === "string" &&
          data.agentAck
        ) {
          agentAcks.push(data.agentAck);
        }
      } catch {
        // ignore non-JSON frames
      }
    });
  });

  await enterSession(page);

  // Establish a real session by exchanging one message so the second message
  // uses the normal handleUserMessage path (which attaches a nonce).
  // create_task (first message) sends no nonce, so no agentAck is emitted.
  await sendMessage(page, 'Please reply with "copilot-ack2-ready"');
  await expect(assistantText(page, "copilot-ack2-ready")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  const acksBeforeStall = agentAcks.length;

  // Send a second message — this uses handleUserMessage which attaches a nonce,
  // so agentAck is emitted once session.send returns.
  await sendMessage(page, 'Please reply with "copilot-ack2-test"');

  // Verify the backend emitted an agentAck WebSocket frame — the agentAck signal.
  // DOM-based ack-4/ack-3/ack-2 checks are not reliable for follow-up copilot
  // turns because session.send returns in < 5 ms, so unconfirmedUserEvent +
  // agentAck + item_started all land in one rAF batch and only the confirmed
  // state is painted.
  await expect
    .poll(() => agentAcks.length, { timeout: responseTimeout(agentType) })
    .toBeGreaterThan(acksBeforeStall);

  // Full round-trip confirmation.
  await expect(lastAssistantText(page, "copilot-ack2-test")).toBeVisible({
    timeout: responseTimeout(agentType),
  });
});

test("claude skips ack-2 (no agent-ack signal)", { tag: "@claude-only" }, async ({
  page,
  agentType,
}) => {

  await enterSession(page);

  // Establish a real session first so the stalling follow-up uses the normal
  // nonce-based send path rather than the initial create_task handshake.
  await sendMessage(page, 'Please reply with "claude-ack3-ready"');
  await expect(assistantText(page, "claude-ack3-ready")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill("stall session");
  const sendBtn = page.locator(".btn-send:visible").first();
  await expect(sendBtn).toBeEnabled({ timeout: 5_000 });
  await sendBtn.click();

  const bubble = page
    .locator(".user-message:not(.system-user-message)", {
      hasText: "stall session",
    })
    .first();

  // By the time the DOM paints, the optimistic placeholder may still be
  // ack-4 or may already have been upgraded to ack-3 by the backend echo.
  await expect(bubble).toHaveClass(/ack-(3|4)/, { timeout: 3_000 });
  await expect(bubble).toHaveClass(/ack-3/, { timeout: 15_000 });

  // Claude has no agent-ack signal — ack-2 must never appear.
  // Wait slightly longer than the ack-3 round-trip to confirm stability.
  await page.waitForTimeout(3_000);
  await expect(bubble).not.toHaveClass(/ack-2/);
});

test("late-joining tab sees pending bubble from history", { tag: "@claude-only" }, async ({
  page,
  browser,
  agentType,
}) => {

  await enterSession(page);

  // Send a stalling message so the session is busy and the pending bubble
  // is in td.history for replay.
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill("stall session");
  const sendBtn = page.locator(".btn-send:visible").first();
  await expect(sendBtn).toBeEnabled({ timeout: 5_000 });
  await sendBtn.click();

  // Wait for the unconfirmed-user-event echo so the pending bubble is in history.
  await expect(
    page.locator(".user-message", { hasText: "stall session" }),
  ).toBeVisible({ timeout: 5_000 });

  // Open the same task in a second context.
  const url = page.url();
  const ctx2 = await browser.newContext();
  const page2 = await ctx2.newPage();
  await page2.goto(url);

  // Tab B should see the pending bubble replayed from history.
  await expect(
    page2.locator(".user-message", { hasText: "stall session" }),
  ).toBeVisible({ timeout: 15_000 });

  await ctx2.close();
});

test("outbox ack-4 placeholder visible offline; persists across reload", { tag: "@claude-only" }, async ({
  page,
  agentType,
}) => {

  await enterSession(page);

  // Establish session with one completing exchange so we have a valid tid.
  await sendMessage(page, 'Please reply with "reload-outbox-established"');
  await expect(assistantText(page, "reload-outbox-established")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // Go offline so the next send lands in the outbox only.
  await page.context().setOffline(true);

  const inputEl = page.locator(".input-textarea:visible").first();
  await inputEl.click();
  await inputEl.fill('Please reply with "outbox-reload-pending"');
  const sendBtn = page.locator(".btn-send:visible").first();
  await expect(sendBtn).toBeEnabled({ timeout: 5_000 });
  await sendBtn.click();

  // Render-layer outbox composition: ack-4 placeholder is visible immediately
  // from localStorage — no WS round-trip needed (we're offline).
  await expect(
    page.locator(".user-message.ack-4", { hasText: "outbox-reload-pending" }),
  ).toBeVisible({ timeout: 3_000 });
  const outboxBefore = await page.evaluate(() =>
    JSON.parse(localStorage.getItem("cydo.outbox.v1") ?? "[]"),
  );
  expect(outboxBefore.length).toBeGreaterThan(0);

  // Come back online so page.reload() can reach the backend.
  // The outbox entry persists in localStorage across the reload.
  await page.context().setOffline(false);
  await page.reload();

  // Navigate to the task — the message bubble should be visible (either from
  // the outbox composition if the reload was fast, or from WS replay).
  await page
    .locator(".sidebar-item .sidebar-label", {
      hasText: "reload-outbox-established",
    })
    .click({ timeout: 15_000 });

  // Full delivery: outbox replays the message and the backend replies.
  await expect(assistantText(page, "outbox-reload-pending")).toBeVisible({
    timeout: responseTimeout(agentType),
  });
});

test("identical-text messages use separate nonces (no placeholder collision)", { tag: "@claude-only" }, async ({
  page,
  agentType,
}) => {

  await enterSession(page);

  // Establish the session with one completing exchange.
  await sendMessage(page, 'Please reply with "nonce-dedup-established"');
  await expect(assistantText(page, "nonce-dedup-established")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // Extract the task id from the current URL (e.g. "/…/123" → 123).
  const url = page.url();
  const tidMatch = url.match(/\/(\d+)(?:[?#].*)?$/);
  expect(tidMatch).not.toBeNull();
  const tid = parseInt(tidMatch![1], 10);
  expect(tid).toBeGreaterThan(0);

  // Wait for the outbox to be empty (cleared by ack-3 from the last send).
  await expect
    .poll(
      async () => {
        const raw = await page.evaluate(() =>
          localStorage.getItem("cydo.outbox.v1"),
        );
        return JSON.parse(raw ?? "[]");
      },
      { timeout: responseTimeout(agentType) },
    )
    .toHaveLength(0);

  // Inject two outbox entries with identical text but different nonces.
  // Content must be ContentBlock[] so the backend can parse them on replay.
  const sharedText = "stall session";
  await page.evaluate(
    ({ tid, text }: { tid: number; text: string }) => {
      const content = [{ type: "text", text }];
      const entries = [
        {
          tid,
          nonce: "nonce-dedup-aaa-111",
          content,
          createdAt: Date.now() - 2000,
        },
        {
          tid,
          nonce: "nonce-dedup-bbb-222",
          content,
          createdAt: Date.now() - 1000,
        },
      ];
      localStorage.setItem("cydo.outbox.v1", JSON.stringify(entries));
    },
    { tid, text: sharedText },
  );

  // Reload so the outbox replayer fires on reconnect. Each entry has a unique
  // nonce so the backend processes both as separate messages.
  await page.reload();
  await page
    .locator(".sidebar-item .sidebar-label", {
      hasText: "nonce-dedup-established",
    })
    .click({ timeout: 15_000 });

  // After both outbox entries are replayed and ack-3 arrives for each, the
  // reducer places them as two separate user message bubbles (one per nonce).
  // If text-equality fallback were used, the second entry would overwrite the
  // first placeholder and only one bubble would appear.
  await expect(
    page.locator(".user-message", { hasText: sharedText }),
  ).toHaveCount(2, { timeout: responseTimeout(agentType) });
});
