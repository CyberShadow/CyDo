import { writeTestConfig } from "./test-config";
import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
} from "./fixtures";

test("permission_policy allow auto-approves tool calls via can_use_tool", { tag: "@claude-only" }, async ({
  page,
  agentType,
}) => {

  // Configure the workspace with permission_policy: allow so the backend passes
  // --permission-prompt-tool stdio to Claude and answers its can_use_tool
  // control requests.
  writeTestConfig(
    "/tmp/playwright-home/.config/cydo/config.yaml",
    `default_agent: claude
workspaces:
  local:
    root: /tmp/cydo-test-workspace
    permission_policy: allow
`,
  );

  // Give the backend's inotify watcher time to reload the config.
  await page.waitForTimeout(500);

  await enterSession(page);
  await sendMessage(
    page,
    "run command echo permission-allow-test > .claude/test-allow.md",
  );

  // The Bash tool should execute successfully.
  await expect(page.locator(".tool-name", { hasText: "Bash" })).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // The session should complete with "Done." from the mock LLM.
  await expect(assistantText(page, "Done.")).toBeVisible({
    timeout: responseTimeout(agentType),
  });
});
