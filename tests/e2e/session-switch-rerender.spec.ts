import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
} from "./fixtures";

test("switching sessions does not re-render every mounted SessionView", { tag: "@claude-only" }, async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "claude", "claude-only: tests Preact memo stability");

  // Hook into Preact's render pipeline. We count SessionViewInner renders by
  // matching the function name (preserved by keepNames:true in vite.config.ts).
  await page.addInitScript(() => {
    const tracker = {
      active: false,
      sessionViewRenders: 0,
      renderLog: [] as Array<{ uuid: string; changedProps: string[] }>,
      lastProps: new Map<string, Record<string, unknown>>(),
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
          if (type?.name === "SessionViewInner") {
            const uuid = props?.task?.uuid ?? "unknown";
            tracker.sessionViewRenders++;
            const last = tracker.lastProps.get(uuid);
            const changedProps: string[] = [];
            if (last) {
              for (const k of new Set([
                ...Object.keys(last),
                ...Object.keys(props ?? {}),
              ])) {
                if (last[k] !== (props as any)[k]) changedProps.push(k);
              }
            } else {
              changedProps.push("(first render)");
            }
            tracker.renderLog.push({ uuid, changedProps });
            tracker.lastProps.set(uuid, { ...props });
          }
        }
        if (prev) prev(vnode);
      };
    };
    install();
  });

  const timeout = responseTimeout(agentType);
  const N = 5;
  const labels: string[] = [];

  // Create N sessions, each with one completed reply so each task is fully
  // loaded, has an in-flight history-loaded state, and the SessionView is
  // mounted into the DOM (kept by the everLoaded filter in app.tsx).
  for (let i = 0; i < N; i++) {
    const label = `session-${i}`;
    labels.push(label);
    await enterSession(page);
    await sendMessage(page, `Please reply with "${label}"`);
    await expect(assistantText(page, label)).toBeVisible({ timeout });
  }

  // Verify all N sidebar items are present.
  for (const label of labels) {
    await expect(
      page.locator(".sidebar-item .sidebar-label", { hasText: label }),
    ).toBeVisible();
  }

  // Sanity: confirm the filter actually matches SessionViewInner renders.
  // This is the positive control — if the filter never matches, the bound
  // assertion below would false-pass.
  await page.evaluate(() => {
    const t = (window as any).__renderTracker;
    t.sessionViewRenders = 0;
    t.active = true;
  });

  // Trigger one switch to validate the filter sees something.
  await page
    .locator(".sidebar-item .sidebar-label", { hasText: labels[0]! })
    .click();
  await expect(assistantText(page, labels[0]!)).toBeVisible({
    timeout: 10_000,
  });

  const probeCount = await page.evaluate(() => {
    const t = (window as any).__renderTracker;
    return t.sessionViewRenders as number;
  });
  expect(
    probeCount,
    "Filter matched no SessionViewInner renders during a session switch — " +
      "the test's function-name filter or keepNames:true config may be broken.",
  ).toBeGreaterThan(0);

  // Reset and run the cycle: 0 → 1 → 2 → 3 → 4 → 0  (6 switches).
  await page.evaluate(() => {
    const t = (window as any).__renderTracker;
    t.sessionViewRenders = 0;
    t.renderLog = [];
    t.lastProps = new Map();
  });

  const cycle = [
    labels[1]!,
    labels[2]!,
    labels[3]!,
    labels[4]!,
    labels[0]!,
    labels[1]!,
  ];
  for (const label of cycle) {
    await page
      .locator(".sidebar-item .sidebar-label", { hasText: label })
      .click();
    await expect(assistantText(page, label)).toBeVisible({ timeout: 10_000 });
    // Brief flush so render counts settle before the next click.
    await page.waitForTimeout(50);
  }
  // Final flush
  await page.waitForTimeout(200);

  const result = await page.evaluate(() => {
    const t = (window as any).__renderTracker;
    t.active = false;
    return {
      renders: t.sessionViewRenders as number,
      log: t.renderLog as Array<{ uuid: string; changedProps: string[] }>,
    };
  });

  // BOUND derived empirically: with fix ~17, without fix ~31. Threshold 25
  // sits between the two with comfortable headroom on each side.
  const switches = cycle.length;
  const BOUND = 25;
  const logStr = result.log
    .map((e) => `${e.uuid.slice(0, 8)}: [${e.changedProps.join(",")}]`)
    .join("\n  ");
  expect(
    result.renders,
    `${result.renders} SessionViewInner re-renders during ${switches} ` +
      `session switches; expected ≤ ${BOUND}. ` +
      `Task-control callbacks may have lost stable identity.\n` +
      `Render log:\n  ${logStr}`,
  ).toBeLessThanOrEqual(BOUND);
});
