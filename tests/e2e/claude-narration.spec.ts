import {
  test,
  expect,
  enterSession,
  sendMessage,
  assistantText,
  killSession,
  responseTimeout,
} from "./fixtures";

// The mock answers "narration fixture" with a reasoning block, a block whose
// signature the server tagged as narration, then text. Claude Code reports
// the tag on live frames only (narration_block_indexes), so narration carries
// a summary badge while the task is live and reads as plain thinking once
// reloaded from the session file.
test(
  "Claude narration is badged as a summary while live",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    await enterSession(page);
    const timeout = responseTimeout(agentType);
    await sendMessage(page, "narration fixture");
    await expect(assistantText(page, "narration-fixture-done")).toHaveCount(1, {
      timeout,
    });

    const narration = page.getByTestId("assistant-narration");
    await expect(narration).toHaveCount(1);
    await expect(narration.locator(".text-content")).toContainText(
      "Checking the fixture before answering.",
    );
    await expect(page.locator(".meta-badge.summary")).toHaveText("summary");
    await expect(page.locator(".thinking-text")).toHaveCount(1);
    // The reload below replaces the live view, so check it for unknown agent
    // data (thinking frames carry extra fields) before the fixture's sweep.
    await expect(page.locator(".unknown-extra-fields")).toHaveCount(0);

    await killSession(page, agentType);
    await page.reload();
    await expect(assistantText(page, "narration-fixture-done")).toHaveCount(1, {
      timeout,
    });
    await expect(page.locator(".thinking-text")).toHaveCount(2);
    await expect(page.getByTestId("assistant-narration")).toHaveCount(0);
    await expect(page.locator(".meta-badge.summary")).toHaveCount(0);
  },
);
