import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
} from "./fixtures";

test("completed messages are not recreated when new messages arrive", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "claude", "claude-only: tests Preact memo stability");

  // Hook into Preact's render pipeline via __PREACT_DEVTOOLS__ to count
  // MessageView renders. MessageView is memo-wrapped; when memo works, only
  // new messages trigger a render. The bug causes ALL messages to re-render.
  await page.addInitScript(() => {
    const tracker = {
      active: false,
      preExistingRenders: 0,
      totalCalls: 0,
      preExistingIds: null as Set<string> | null,
    };
    (window as any).__renderTracker = tracker;

    (window as any).__PREACT_DEVTOOLS__ = {
      attachPreact(_version: string, options: any, _exports: any) {
        const prev = options.__r;
        options.__r = (vnode: any) => {
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
              // Only count re-renders of pre-existing (completed) messages.
              const msgId = props.msg?.id;
              if (msgId && tracker.preExistingIds.has(String(msgId))) {
                tracker.preExistingRenders++;
              }
            }
          }
          if (prev) prev(vnode);
        };
      },
    };
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
    };
  });

  // When memo works correctly, pre-existing completed MessageView instances
  // must not re-render at all when new messages arrive.
  expect(
    result.preExistingRenders,
    `${result.preExistingRenders} pre-existing MessageView(s) re-rendered when ` +
      `only new messages should have rendered (${result.preExistingCount} pre-existing). ` +
      `Memo is not preventing re-renders of completed messages.`,
  ).toBe(0);
});
