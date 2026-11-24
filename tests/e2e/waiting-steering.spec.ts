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
      async () => {
        await page.locator('.sidebar-item[data-tid="1"]').click();
        const qid = page
          .locator(".cydo-task-spec:visible", { hasText: "hold for an answer" })
          .locator(".tool-input-field", { hasText: /^qid:\s*\d+$/ })
          .locator(".field-value");
        await expect(qid).toHaveText(/^\s*\d+\s*$/, { timeout: 30_000 });
        await expect(assistantText(page, /^Done\.$/)).toBeVisible({
          timeout: 30_000,
        });
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
  prepareRelease: () => Release | Promise<Release>,
) {
  const statuses: string[] = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", ({ payload }) => {
      const frame = JSON.parse(payload.toString());
      if (frame.type === "task_updated" && frame.task.tid === tid)
        statuses.push(frame.task.status);
    });
  });

  await enterSession(page);
  await sendMessage(page, prompt);
  const task = page.locator(`.sidebar-item[data-tid="${tid}"]`);
  const icon = task.locator(".task-type-icon");
  await expect(icon).toHaveClass(/\bwaiting\b/, { timeout: 30_000 });
  await task.click();
  await expect(task).toHaveClass(/\bactive\b/);

  const beforeSteer = statuses.length;
  const marker = `waiting-steering-consumed-${randomUUID()}`;
  const steer = `reply with "${marker}"`;
  await sendMessage(page, steer);
  await expect(
    page.locator(".user-message:visible:not(.ack-4)", { hasText: steer }),
  ).toBeVisible({ timeout: 15_000 });

  expect.soft(await icon.getAttribute("class")).toMatch(/\bwaiting\b/);
  expect(statuses.slice(beforeSteer)).not.toContain("active");

  const release = await prepareRelease();
  const beforeRelease = statuses.length;
  expect(statuses.slice(beforeSteer, beforeRelease)).not.toContain("active");
  await release();
  await expect
    .poll(() => statuses.slice(beforeRelease), { timeout: 30_000 })
    .toContain("active");
  await task.click();
  await expect(assistantText(page, marker)).toBeVisible({ timeout: 30_000 });
}
