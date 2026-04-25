import { writeFileSync } from "fs";
import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
} from "./fixtures";

test("permission_policy ask: Allow button approves the tool call", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "claude", "claude-only test");

  writeFileSync(
    "/tmp/playwright-home/.config/cydo/config.yaml",
    `default_agent_type: claude
workspaces:
  local:
    root: /tmp/cydo-test-workspace
    permission_policy: ask
`,
  );

  await page.waitForTimeout(500);

  await enterSession(page);
  await sendMessage(
    page,
    "run command echo ask-allow-test > .claude/test-ask-allow.md",
  );

  // The permission prompt form must appear.
  const form = page.locator(".permission-prompt-form");
  await expect(form).toBeVisible({ timeout: responseTimeout(agentType) });

  // Click Allow — the backend sends allow back to Claude, which runs the command.
  await page.locator(".permission-allow-btn").click();

  // Form disappears after response.
  await expect(form).not.toBeVisible({ timeout: 10_000 });

  // Session completes with "Done." from the mock LLM.
  await expect(assistantText(page, "Done.")).toBeVisible({
    timeout: responseTimeout(agentType),
  });
});

test("permission_policy ask: Deny button blocks the tool call", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "claude", "claude-only test");

  writeFileSync(
    "/tmp/playwright-home/.config/cydo/config.yaml",
    `default_agent_type: claude
workspaces:
  local:
    root: /tmp/cydo-test-workspace
    permission_policy: ask
`,
  );

  await page.waitForTimeout(500);

  await enterSession(page);
  await sendMessage(
    page,
    "run command echo ask-deny-test > .claude/test-ask-deny.md",
  );

  // The permission prompt form must appear.
  const form = page.locator(".permission-prompt-form");
  await expect(form).toBeVisible({ timeout: responseTimeout(agentType) });

  // First click on Deny reveals the reason textarea.
  await page.locator(".permission-deny-btn").click();
  // Second click confirms the denial.
  await page.locator(".permission-deny-btn").click();

  // Form disappears after response.
  await expect(form).not.toBeVisible({ timeout: 10_000 });

  // Session completes with "Done." from the mock LLM after the denied tool_result.
  await expect(assistantText(page, "Done.")).toBeVisible({
    timeout: responseTimeout(agentType),
  });
});
