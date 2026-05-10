import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
} from "./fixtures";

test("diff result: toggle reveals raw git log output and headers", { tag: "@no-copilot" }, async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  const timeout = responseTimeout(agentType);
  await sendMessage(page, "semantic shell diff");
  const toolName = agentType === "codex" ? "commandExecution" : "Bash";
  const toolCall = page
    .locator(".tool-call")
    .filter({ has: page.locator(".tool-name", { hasText: toolName }) })
    .last();
  await expect(toolCall).toBeVisible({ timeout });

  // Result is collapsed by default for diffs (local source, re-derivable).
  // Use toPass so that if semantic parsing completes and collapses the result
  // after our initial visibility check, we click again and retry.
  const resultHeader = toolCall.locator(".tool-result-header");
  const resultContainer = toolCall.locator(".tool-result-container");
  const diff = toolCall.locator('[data-testid="semantic-shell-diff"]');
  await expect(async () => {
    if (
      (await resultHeader.isVisible()) &&
      !(await resultContainer.isVisible())
    ) {
      await resultHeader.click();
    }
    await expect(diff).toBeVisible();
  }).toPass({ timeout });
  await expect(diff.locator(".diff-view").first()).toBeVisible({ timeout });

  const toggle = diff.locator(".markdown-toggle-btn");
  await expect(toggle).toBeVisible();

  await toggle.click();
  const raw = diff.locator(".code-pre-wrap").first();
  await expect(raw).toBeVisible();
  await expect(raw).toContainText("commit ");
  await expect(raw).toContainText("diff --git");

  await toggle.click();
  await expect(diff.locator(".diff-view").first()).toBeVisible();
});
