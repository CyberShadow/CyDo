import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
  responseTimeout,
  assistantText,
  currentTaskTid,
  historyPathForTask,
  readHistoryFile,
} from "./fixtures";

test(
  "un-sending a queued steering message withdraws it and restores the composer",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    const steer = "UNSEND_ME_steering_text";

    await enterSession(page);
    // Keep the turn busy so the next message queues behind it.
    await sendMessage(page, "run command sleep 15");
    await expect(page.locator(".tool-call", { hasText: "sleep 15" })).toBeVisible(
      { timeout: responseTimeout(agentType) },
    );

    await sendMessage(page, steer);
    const queued = page
      .locator(".message-wrapper:visible", {
        has: page.locator(".message.user-message", { hasText: steer }),
      })
      .last();
    await queued.hover();
    await queued.locator(".unsend-btn").click();

    await expect(
      page.locator(".message.user-message", { hasText: steer }),
    ).toHaveCount(0);
    await expect(page.locator(".input-textarea:visible").first()).toHaveValue(
      steer,
    );

    // The turn finishes without the model ever seeing the withdrawn message.
    await expect(assistantText(page, "Done.")).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    const historyPath = historyPathForTask(currentTaskTid(page));
    await expect
      .poll(() => readHistoryFile(historyPath).includes(`"content":"${steer}"`))
      .toBe(true);
    expect(
      readHistoryFile(historyPath)
        .split("\n")
        .filter(Boolean)
        .map((line) => JSON.parse(line))
        .some(
          (record) =>
            (record.type === "attachment" &&
              record.attachment?.prompt === steer) ||
            (record.type === "user" && record.message?.content === steer),
        ),
    ).toBe(false);

    // Reloaded from the session file, the withdrawn message stays gone.
    await killSession(page, agentType);
    await page.reload();
    await expect(assistantText(page, "Done.")).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    await expect(
      page.locator(".message.user-message", { hasText: steer }),
    ).toHaveCount(0);
  },
);
