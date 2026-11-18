import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
} from "./fixtures";

test(
  "a response the CLI retracts after a refusal stays on display, marked",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    await enterSession(page);
    // The mock's primary model refuses twice (the CLI retries it once),
    // then the fallback model answers.
    await sendMessage(page, "refuse-fallback-test");

    await expect(assistantText(page, "fallback-answer")).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    await expect(
      page.locator(".diagnostic-message", {
        hasText: "Model refused; switched",
      }),
    ).toBeVisible();

    // Only the response the fallback replaced is retracted; the first
    // refused one stays, followed by the CLI's request to continue.
    await expect(assistantText(page, "refused-partial")).toHaveCount(2);
    const retracted = page.locator(".assistant-message.retracted-message");
    await expect(retracted).toHaveCount(1);
    await expect(retracted).toContainText("refused-partial");
    await expect(retracted.locator(".meta-badge.retracted")).toBeVisible();

    // A reload replays the task's events, retraction included.
    await page.reload();
    await expect(assistantText(page, "fallback-answer")).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    await expect(assistantText(page, "refused-partial")).toHaveCount(2);
    await expect(retracted).toHaveCount(1);
    await expect(retracted).toContainText("refused-partial");
  },
);
