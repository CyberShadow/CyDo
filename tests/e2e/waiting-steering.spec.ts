import { randomUUID } from "node:crypto";
import { rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Page } from "@playwright/test";
import {
  test,
  expect,
  assistantText,
  enterSession,
  sendMessage,
} from "./fixtures";

test(
  "steering preserves waiting during Task",
  { tag: "@no-copilot" },
  async ({ page, backend }) => {
    const releasePath = join(backend.wsDir, `waiting-steering-${randomUUID()}`);
    try {
      await expectWaitingAfterSteering(
        page,
        `call task research run command until test -f '${releasePath}'; do sleep 0.1; done`,
        1,
        null,
        () => () => writeFileSync(releasePath, ""),
      );
    } finally {
      rmSync(releasePath, { force: true });
    }
  },
);

test(
  "steering preserves waiting during Ask",
  { tag: "@no-copilot" },
  async ({ page }) => {
    await expectWaitingAfterSteering(
      page,
      "call task research call ask hold for an answer",
      2,
      1,
      async () => {
        await page.locator('.sidebar-item[data-tid="1"]').click();
        const qid = page
          .locator(".cydo-task-spec:visible", { hasText: "hold for an answer" })
          .locator(".tool-input-field", { hasText: /^qid:\s*\d+$/ })
          .locator(".field-value");
        await expect(qid).toHaveText(/^\s*\d+\s*$/);
        await expect(assistantText(page, /^Done\.$/)).toBeVisible();
        const answer = `call answer ${(await qid.innerText()).trim()} continue`;
        return () => sendMessage(page, answer);
      },
    );
  },
);

type Release = () => void | Promise<void>;

async function expectWaitingAfterSteering(
  page: Page,
  prompt: string,
  tid: number,
  returnTo: number | null,
  prepareRelease: () => Release | Promise<Release>,
) {
  const statuses: string[] = [];
  const hints: { from: number; to: number }[] = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", ({ payload }) => {
      const frame = JSON.parse(payload.toString());
      if (frame.type === "task_updated" && frame.task.tid === tid)
        statuses.push(frame.task.status);
      if (frame.type === "focus_hint")
        hints.push({ from: frame.from_tid, to: frame.to_tid });
    });
  });

  const returnHint = (since: number) =>
    expect
      .poll(() =>
        hints
          .slice(since)
          .some((hint) => hint.from === tid && hint.to === returnTo),
      )
      .toBe(true);

  await enterSession(page);
  await sendMessage(page, prompt);
  const task = page.locator(`.sidebar-item[data-tid="${tid}"]`);
  const icon = task.locator(".task-type-icon");
  const returnTask = page.locator(`.sidebar-item[data-tid="${returnTo}"]`);
  await expect(icon).toHaveClass(/\bwaiting\b/);
  if (returnTo !== null) {
    // Rendering the child's waiting state has already applied the earlier
    // launch hint to the child. The Ask hint must move focus back.
    await returnHint(0);
    await expect(returnTask).toHaveClass(/\bactive\b/);
  }
  await task.click();
  await expect(task).toHaveClass(/\bactive\b/);

  const beforeSteer = statuses.length;
  const marker = `waiting-steering-consumed-${randomUUID()}`;
  const steer = `reply with "${marker}"`;
  await sendMessage(page, steer);
  await expect(
    page.locator(".user-message:visible:not(.ack-4)", { hasText: steer }),
  ).toBeVisible();

  expect.soft(await icon.getAttribute("class")).toMatch(/\bwaiting\b/);
  expect(statuses.slice(beforeSteer)).not.toContain("active");

  const release = await prepareRelease();
  const beforeRelease = statuses.length;
  const hintsBeforeRelease = hints.length;
  expect(statuses.slice(beforeSteer, beforeRelease)).not.toContain("active");
  await release();
  await expect
    .poll(() => statuses.slice(beforeRelease))
    .toContain("active");
  if (returnTo !== null) {
    // Batch delivery sends a return hint that can undo a click on the child.
    await returnHint(hintsBeforeRelease);
    await expect(returnTask).toHaveClass(/\bactive\b/);
    // The parent can still be selected before the Answer hint is applied.
    // Its second Done follows batch delivery and the return hint in the queue.
    await expect(assistantText(page, /^Done\.$/)).toHaveCount(2);
  }
  await task.click();
  await expect(task).toHaveClass(/\bactive\b/);
  await expect(assistantText(page, marker)).toBeVisible();
}
