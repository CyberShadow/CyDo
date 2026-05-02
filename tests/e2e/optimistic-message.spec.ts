import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
} from "./fixtures";

test("user bubble appears immediately after Send (ack-4 optimistic render)", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "claude", "agent-agnostic, runs in claude project only");

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

test("outbox replays unsent message after offline reload", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "claude", "agent-agnostic, runs in claude project only");

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

test("backend deduplicates message sent twice with same nonce", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "claude", "agent-agnostic, runs in claude project only");

  await enterSession(page);

  // Start sending the message but capture the outbox entry (which exists
  // synchronously before the network round-trip) to recover the nonce.
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill('Please reply with "dedupe-test"');
  const sendBtn = page.locator(".btn-send:visible").first();
  await expect(sendBtn).toBeEnabled({ timeout: 5_000 });
  await sendBtn.click();

  // Capture the outbox entry immediately — it's added synchronously before
  // the WS send, so it's available before the backend ack clears it.
  const outboxSnapshot = await page.evaluate(() =>
    JSON.parse(localStorage.getItem("cydo.outbox.v1") ?? "[]"),
  );
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
    ({ tid, nonce, content }: { tid: number; nonce: string; content: unknown }) => {
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

test("outbox entry evicted after backend ack", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "claude", "agent-agnostic, runs in claude project only");

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

test("late-joining tab sees pending bubble from history", async ({
  page,
  browser,
  agentType,
}) => {
  test.skip(agentType !== "claude", "agent-agnostic, runs in claude project only");

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
