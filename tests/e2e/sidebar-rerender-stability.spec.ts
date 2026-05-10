import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
} from "./fixtures";

test("sidebar re-renders are bounded during agent streaming", { tag: "@claude-only" }, async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "claude", "claude-only: tests Preact memo stability");

  // Hook into Preact's render pipeline via __preactOptions to count Sidebar
  // renders. Sidebar is memo-wrapped; when memo works, it only re-renders when
  // sidebar-visible state (isProcessing, status, title) actually changes.
  // Filter by a unique prop combination (immune to name-mangling in the build);
  // skip the memo wrapper (type._forwarded) to avoid double-counting.
  await page.addInitScript(() => {
    const tracker = {
      active: false,
      sidebarRenders: 0,
      renderLog: [] as Array<{ changedProps: string[] }>,
      lastProps: null as Record<string, unknown> | null,
    };
    (window as any).__renderTracker = tracker;

    const install = () => {
      const opts = (window as any).__preactOptions;
      if (!opts) {
        requestAnimationFrame(install);
        return;
      }
      const prev = opts.__r;
      opts.__r = (vnode: any) => {
        if (tracker.active) {
          const props = vnode?.props;
          const type = vnode?.type;
          // Match the inner Sidebar render (not the memo wrapper).
          // Prop names are preserved by JSX; _forwarded is set on the memo wrapper.
          // "onArchive" + "hasGlobalAttention" + "tasks" uniquely identifies Sidebar.
          if (
            props &&
            "tasks" in props &&
            "onArchive" in props &&
            "hasGlobalAttention" in props &&
            !type?._forwarded
          ) {
            tracker.sidebarRenders++;
            const changedProps: string[] = [];
            if (tracker.lastProps) {
              for (const k of new Set([
                ...Object.keys(tracker.lastProps),
                ...Object.keys(props ?? {}),
              ])) {
                if (tracker.lastProps[k] !== (props as any)[k]) {
                  changedProps.push(k);
                }
              }
            } else {
              changedProps.push("(first render)");
            }
            tracker.renderLog.push({ changedProps });
            tracker.lastProps = { ...props };
          }
        }
        if (prev) prev(vnode);
      };
    };
    install();
  });

  const timeout = responseTimeout(agentType);

  await enterSession(page);

  // Warm-up turn so the task already has hasMessages=true before the
  // measured workload, removing one expected sidebar transition.
  await sendMessage(page, 'reply with "warmup"');
  await expect(assistantText(page, "warmup")).toBeVisible({ timeout });
  await expect(page.locator(".assistant-message.streaming")).toHaveCount(0, {
    timeout,
  });

  // Activate render tracking.
  await page.evaluate(() => {
    const t = (window as any).__renderTracker;
    t.sidebarRenders = 0;
    t.renderLog = [];
    t.lastProps = null;
    t.active = true;
  });

  // Workload: a tool-call message produces a stream of incremental events
  // (token deltas, tool_use, tool_result, more tokens, status flips), each
  // triggering a setTasks(new Map(prev)) in useSessionManager. This is the
  // canonical "many tasks updates" scenario.
  await sendMessage(page, "run command echo sidebar-rerender");
  await expect(
    page.locator(".tool-result", { hasText: "sidebar-rerender" }),
  ).toBeVisible({ timeout });
  await expect(assistantText(page, "Done.")).toBeVisible({ timeout });
  await expect(page.locator(".assistant-message.streaming")).toHaveCount(0, {
    timeout,
  });
  // Settle.
  await page.waitForTimeout(300);

  const result = await page.evaluate(() => {
    const t = (window as any).__renderTracker;
    t.active = false;
    return {
      renders: t.sidebarRenders as number,
      log: t.renderLog as Array<{ changedProps: string[] }>,
    };
  });

  // Positive control: filter must have matched at least one render. If it's
  // zero, the prop-shape filter or _forwarded sentinel has drifted from the
  // real Sidebar component.
  expect(
    result.renders,
    "Filter matched no Sidebar renders during the workload — the test's " +
      "prop-shape filter (tasks/onArchive/hasGlobalAttention) or " +
      "memo-wrapper detection is stale.",
  ).toBeGreaterThan(0);

  // BOUND derived empirically. One tool-call turn (after warm-up) produces:
  //   - prop-change renders: tasks + attention transitions ~4
  //   - internal-state renders: Sidebar's own glowAbove/glowBelow ~4
  // Observed floor: 8. BOUND adds comfortable headroom above that.
  const BOUND = 12;
  const logStr = result.log
    .map((e, i) => `${i}: [${e.changedProps.join(",")}]`)
    .join("\n  ");
  expect(
    result.renders,
    `${result.renders} Sidebar re-renders during a single tool-call turn; ` +
      `expected ≤ ${BOUND}. Memo may have lost stability on a prop.\n` +
      `Render log:\n  ${logStr}`,
  ).toBeLessThanOrEqual(BOUND);
});
