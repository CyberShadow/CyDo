import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
} from "./fixtures";

test("completed messages are not recreated when new messages arrive", { tag: "@claude-only" }, async ({
  page,
  agentType,
}) => {

  // Hook into Preact's render pipeline via window.__preactOptions to count
  // MessageView renders. MessageView is memo-wrapped; when memo works, only
  // new messages trigger a render. The bug causes ALL messages to re-render.
  await page.addInitScript(() => {
    const tracker = {
      active: false,
      preExistingRenders: 0,
      // Count of MessageView renders observed while active, regardless of
      // pre-existing status. Acts as a positive control: if the prop-signature
      // filter or memo-wrapper detection drifts, this stays 0 and the test
      // fails loudly instead of green-passing on preExistingRenders === 0.
      messageViewRenders: 0,
      totalCalls: 0,
      preExistingIds: null as Set<string> | null,
    };
    (window as any).__renderTracker = tracker;

    // main.tsx assigns __preactOptions during module init, after this script
    // runs, so we poll with rAF until it's available.
    const install = () => {
      const opts = (window as any).__preactOptions;
      if (!opts) {
        requestAnimationFrame(install);
        return;
      }
      const prev = opts.__r;
      opts.__r = (vnode: any) => {
        tracker.totalCalls++;
        if (tracker.active && tracker.preExistingIds) {
          // Identify MessageView renders by unique prop signature.
          // Filter out the Memoed wrapper (type._forwarded) to avoid
          // double-counting — both wrapper and inner fn get the same props.
          const props = vnode?.props;
          const type = vnode?.type;
          if (
            props &&
            "msg" in props &&
            "tid" in props &&
            "resolvedBlocks" in props &&
            !type?._forwarded
          ) {
            tracker.messageViewRenders++;
            // Only count re-renders of pre-existing (completed) messages.
            const msgId = props.msg?.id;
            if (msgId && tracker.preExistingIds.has(String(msgId))) {
              tracker.preExistingRenders++;
            }
          }
        }
        if (prev) prev(vnode);
      };
    };
    install();
  });

  await enterSession(page);

  // Send a message that triggers a tool call
  await sendMessage(page, "run command echo rerender-test");
  const timeout = responseTimeout(agentType);
  await expect(
    page.locator(".tool-result", { hasText: "rerender-test" }),
  ).toBeVisible({ timeout });
  await expect(assistantText(page, "Done.")).toBeVisible({ timeout });
  await expect(page.locator(".assistant-message.streaming")).toHaveCount(0, {
    timeout,
  });
  // Wait for forkable_uuids control message to arrive — under heavy CPU
  // load, this can arrive in a separate render cycle after the turn completes,
  // changing the `forkable` prop and causing spurious memo-breaking re-renders.
  // The fork button is rendered (though hidden) for forkable messages.
  await expect(
    page.locator("[style*='display: contents'] .fork-btn"),
  ).not.toHaveCount(0, { timeout: 5_000 });

  // Verify hook is working
  const totalCalls = await page.evaluate(
    () => (window as any).__renderTracker.totalCalls as number,
  );
  expect(totalCalls, "Render hook never fired").toBeGreaterThan(0);

  // Collect IDs of all currently rendered message wrappers.
  // These are the "pre-existing" messages that must NOT re-render.
  const preExistingIds = await page.evaluate(() =>
    Array.from(document.querySelectorAll(".message-wrapper"))
      .map((el) => el.id.replace("msg-", ""))
      .filter(Boolean),
  );
  expect(preExistingIds.length).toBeGreaterThan(0);

  // Activate render tracking for pre-existing message IDs
  await page.evaluate((ids) => {
    const t = (window as any).__renderTracker;
    t.preExistingIds = new Set(ids);
    t.preExistingRenders = 0;
    t.messageViewRenders = 0;
    t.active = true;
  }, preExistingIds);

  // Send a second message
  await sendMessage(page, 'reply with "second response"');
  await expect(assistantText(page, "second response")).toBeVisible({ timeout });
  await page.waitForTimeout(500);

  // Collect results
  const result = await page.evaluate(() => {
    const t = (window as any).__renderTracker;
    t.active = false;
    return {
      preExistingRenders: t.preExistingRenders,
      preExistingCount: t.preExistingIds?.size ?? 0,
      messageViewRenders: t.messageViewRenders,
    };
  });

  // Positive control: the second message must have triggered at least one
  // MessageView render that the filter recognised. If this is 0, the
  // prop-signature filter (msg/tid/resolvedBlocks) or the memo-wrapper
  // sentinel (type._forwarded) has drifted from the real component, and
  // the preExistingRenders === 0 assertion below is meaningless.
  expect(
    result.messageViewRenders,
    "Filter matched no MessageView renders while active — the test's prop " +
      "signature or memo-wrapper detection is stale and must be updated.",
  ).toBeGreaterThan(0);

  // When memo works correctly, pre-existing completed MessageView instances
  // must not re-render at all when new messages arrive.
  expect(
    result.preExistingRenders,
    `${result.preExistingRenders} pre-existing MessageView(s) re-rendered when ` +
      `only new messages should have rendered (${result.preExistingCount} pre-existing). ` +
      `Memo is not preventing re-renders of completed messages.`,
  ).toBe(0);
});
