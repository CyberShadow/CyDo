import {
  test,
  expect,
  enterSession,
  sendMessage,
  assistantText,
  responseTimeout,
} from "./fixtures";

test(
  "Codex header preserves the exact model after a mode switch",
  { tag: "@codex-only" },
  async ({ page, agentType }) => {
    await enterSession(page);

    await sendMessage(page, "initialize session");
    await expect(assistantText(page, "initialize session")).toBeVisible({
      timeout: responseTimeout(agentType),
    });

    const headerModel = page.locator(".task-bar:visible .banner-model");
    await expect(headerModel).toHaveText("gpt-5.6-sol");

    await sendMessage(page, "call switchmode plan");
    await expect(
      page.locator(".result-divider.system-user-message", {
        hasText: "Mode switch: plan",
      }),
    ).toBeVisible({ timeout: responseTimeout(agentType) });

    await expect(headerModel).toHaveText("gpt-5.6-sol");
  },
);
