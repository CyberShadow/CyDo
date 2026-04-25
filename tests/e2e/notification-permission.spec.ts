import { test, expect, enterSession, sendMessage } from "./fixtures";

test("notification permission is requested from a user send gesture", async ({
  page,
}) => {
  await page.addInitScript(() => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (window as any).__notificationProbe = {
      calls: 0,
      activationStates: [] as boolean[],
    };

    if (!("Notification" in window)) return;

    try {
      Object.defineProperty(Notification, "permission", {
        configurable: true,
        get: () => "default",
      });
    } catch {
      // Ignore if the browser exposes a non-configurable descriptor.
    }

    Object.defineProperty(Notification, "requestPermission", {
      configurable: true,
      value: () => {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const probe = (window as any).__notificationProbe;
        probe.calls += 1;
        probe.activationStates.push(Boolean(navigator.userActivation?.isActive));
        return Promise.resolve("granted");
      },
    });
  });

  await enterSession(page);

  await expect
    .poll(
      async () =>
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        page.evaluate(() => (window as any).__notificationProbe.calls as number),
    )
    .toBe(0);

  await sendMessage(page, 'reply with "notification permission check"');

  await expect
    .poll(
      async () =>
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        page.evaluate(() => (window as any).__notificationProbe.calls as number),
    )
    .toBe(1);

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const activationStates = await page.evaluate(
    () => (window as any).__notificationProbe.activationStates as boolean[],
  );
  expect(activationStates).toEqual([true]);
});
