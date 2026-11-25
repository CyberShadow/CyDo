import {
  test,
  expect,
  enterSession,
  sendMessage,
  assistantText,
  endSession,
} from "./fixtures";

test(
  "Claude shows replies recovered after a mid-stream disconnect",
  { tag: "@claude-only" },
  async ({ page }) => {
    for (const scenario of ["text", "thinking", "tool"]) {
      await test.step(scenario, async () => {
        await enterSession(page);
        await page.locator("button.task-type-row", { hasText: "blank" }).click();
        await sendMessage(page, `interrupted Claude reply ${scenario}`);
        const answer =
          scenario === "tool"
            ? "streamed-after-tool"
            : `fallback-${scenario}-answer`;
        const result = page.locator(
          ".result-divider.result-success, .result-divider.result-error, .result-message",
        );
        await expect(result).toHaveCount(1);
        await expect(
          assistantText(page, answer),
          `${scenario} reply live`,
        ).toHaveCount(1, { timeout: 1_000 });

        const abandoned = assistantText(
          page,
          "Abandoned text before disconnect.",
        );
        await expect(abandoned).toHaveCount(0);

        const forkTarget =
          scenario === "tool"
            ? page.locator(".tool-call:visible", {
                hasText: "echo fallback-tool-ran",
              })
            : assistantText(page, answer);
        const wrapper = page.locator(".message-wrapper:visible", {
          has: forkTarget,
        });
        if (scenario === "thinking") {
          await expect(wrapper.locator(".thinking-text")).toContainText(
            "Completed thinking before disconnect.",
          );
        }
        if (scenario === "tool") {
          await expect(forkTarget.locator(".tool-result")).toContainText(
            "fallback-tool-ran",
          );
        }
        await wrapper.hover();
        await expect(wrapper.locator(".fork-btn")).toBeVisible();

        await sendMessage(page, "interrupted Claude reply follow-up");
        await expect(assistantText(page, "streamed-follow-up")).toHaveCount(1);
        await expect(result).toHaveCount(2);
        await endSession(page);
        await page.reload();
        await expect(assistantText(page, "streamed-follow-up")).toHaveCount(1);
        await expect(abandoned).toHaveCount(0);
        await expect(
          assistantText(page, answer),
          `${scenario} reply after reload`,
        ).toHaveCount(1, { timeout: 1_000 });
        if (scenario === "thinking") {
          await expect(wrapper.locator(".thinking-text")).toContainText(
            "Completed thinking before disconnect.",
          );
        }
        if (scenario === "tool") {
          await expect(forkTarget.locator(".tool-result")).toContainText(
            "fallback-tool-ran",
          );
        }
      });
    }
  },
);
