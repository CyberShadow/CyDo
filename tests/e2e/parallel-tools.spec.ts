import { test, expect, enterSession, sendMessage, responseTimeout } from "./fixtures";

test("parallel tool calls render in a single assistant message", async ({ page, agentType }) => {
  test.skip(agentType !== "claude", "parallel tool_use blocks are claude-only");

  await enterSession(page);
  await sendMessage(page, "run parallel commands echo one and echo two");

  const timeout = responseTimeout(agentType);

  // Wait for both tool calls to appear
  await expect(page.locator(".tool-call")).toHaveCount(2, { timeout });

  // CRITICAL: both tool calls must be inside a single assistant message
  const msgsWithTools = page.locator(".message.assistant-message:has(.tool-call)");
  await expect(msgsWithTools).toHaveCount(1, { timeout });

  // Both tool names should be visible within that one message
  await expect(msgsWithTools.locator(".tool-name")).toHaveCount(2, { timeout });
});
