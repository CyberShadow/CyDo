import { writeFileSync } from "fs";
import { test, expect, enterSession, sendMessage, responseTimeout } from "./fixtures";

test("permission_policy allow auto-approves tool calls via PermissionPrompt", async ({ page, agentType }) => {
  test.skip(agentType !== "claude", "claude-only test");

  // Configure the workspace with permission_policy: allow so the backend passes
  // --permission-prompt-tool to Claude and our PermissionPrompt MCP tool handles it.
  writeFileSync(
    "/tmp/playwright-home/.config/cydo/config.yaml",
    `default_agent_type: claude
workspaces:
  local:
    root: /tmp/cydo-test-workspace
    permission_policy: allow
`,
  );

  // Give the backend's inotify watcher time to reload the config.
  await page.waitForTimeout(500);

  await enterSession(page);
  await sendMessage(page, "run command echo permission-allow-test > .claude/test-allow.md");

  // The Bash tool should execute successfully.
  await expect(
    page.locator(".tool-name", { hasText: "Bash" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  // The session should complete with "Done." from the mock LLM.
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "Done." }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
});
