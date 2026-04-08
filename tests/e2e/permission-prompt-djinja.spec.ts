import { writeFileSync } from "fs";
import { test, expect, enterSession, sendMessage, responseTimeout } from "./fixtures";

test("permission_policy djinja expression: allow branch auto-approves matching tools", async ({ page, agentType }) => {
  test.skip(agentType !== "claude", "claude-only test");

  // Djinja expression: allow Bash, deny everything else.
  writeFileSync(
    "/tmp/playwright-home/.config/cydo/config.yaml",
    `default_agent_type: claude
workspaces:
  local:
    root: /tmp/cydo-test-workspace
    permission_policy: '{{ "allow" if tool_name == "Bash" else "deny" }}'
`,
  );

  await page.waitForTimeout(500);

  await enterSession(page);
  await sendMessage(page, "run command echo djinja-allow-test > .claude/test-djinja-allow.md");

  // Bash matches the allow branch — tool should execute.
  await expect(
    page.locator(".tool-name", { hasText: "Bash" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "Done." }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
});

test("permission_policy djinja expression: deny branch blocks non-matching tools", async ({ page, agentType }) => {
  test.skip(agentType !== "claude", "claude-only test");

  // Djinja expression: deny Bash, allow everything else.
  writeFileSync(
    "/tmp/playwright-home/.config/cydo/config.yaml",
    `default_agent_type: claude
workspaces:
  local:
    root: /tmp/cydo-test-workspace
    permission_policy: '{{ "deny" if tool_name == "Bash" else "allow" }}'
`,
  );

  await page.waitForTimeout(500);

  await enterSession(page);
  await sendMessage(page, "run command echo djinja-deny-test > .claude/test-djinja-deny.md");

  // Bash matches the deny branch. The tool call is still requested by the LLM
  // and appears in the UI, but the backend denies it.
  await expect(
    page.locator(".tool-name", { hasText: "Bash" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  // After denial the mock LLM sees a tool_result and responds with "Done."
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "Done." }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
});

test("permission_policy deny literal: all tool calls are blocked", async ({ page, agentType }) => {
  test.skip(agentType !== "claude", "claude-only test");

  writeFileSync(
    "/tmp/playwright-home/.config/cydo/config.yaml",
    `default_agent_type: claude
workspaces:
  local:
    root: /tmp/cydo-test-workspace
    permission_policy: deny
`,
  );

  await page.waitForTimeout(500);

  await enterSession(page);
  await sendMessage(page, "run command echo deny-literal-test > .claude/test-deny-literal.md");

  // Tool is requested, appears in UI, then denied.
  await expect(
    page.locator(".tool-name", { hasText: "Bash" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  // Session completes after denial.
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "Done." }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
});
