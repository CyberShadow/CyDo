import { writeTestConfig } from "./test-config";
import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
} from "./fixtures";

test("permission_policy ask: Allow button approves the tool call", { tag: "@claude-only" }, async ({
  page,
  agentType,
}) => {

  writeTestConfig(
    "/tmp/playwright-home/.config/cydo/config.yaml",
    `default_agent: claude
workspaces:
  local:
    root: /tmp/cydo-test-workspace
    permissions:
      policy: ask
`,
  );

  await page.waitForTimeout(500);

  await enterSession(page);
  await sendMessage(
    page,
    "run command echo ask-allow-test > test-ask-allow.md",
  );

  // The permission prompt form must appear. The CLI itself would run this
  // write unasked; only the policy asks, so the prompt carries no CLI reason.
  const form = page.locator(".permission-prompt-form");
  await expect(form).toBeVisible({ timeout: responseTimeout(agentType) });
  await expect(page.locator(".permission-prompt-reason")).toHaveCount(0);
  // Unanswered, it is denied after permission_prompt_timeout (2 min).
  await expect(page.locator(".permission-prompt-timeout")).toContainText(
    /Denied automatically in [12]:\d\d/,
  );

  // The tool call shows it awaits the decision.
  const toolCall = page.locator(".tool-call", { hasText: "ask-allow-test" });
  await expect(toolCall.locator(".tool-icon-asked")).toBeVisible();

  // Click Allow — the backend sends allow back to Claude, which runs the command.
  await page.locator(".permission-allow-btn").click();

  // Form disappears once Claude takes the answer.
  await expect(form).not.toBeVisible();

  // Session completes with "Done." from the mock LLM.
  await expect(assistantText(page, "Done.")).toBeVisible({
    timeout: responseTimeout(agentType),
  });
  await expect(toolCall.locator(".tool-icon-asked")).toHaveCount(0);
  // Claude's echoes of CyDo's answers mark the calls, not the transcript.
  await expect(page.locator(".control-response-message")).toHaveCount(0);
});

test("permission_policy ask: Deny button blocks the tool call", { tag: "@claude-only" }, async ({
  page,
  agentType,
}) => {

  writeTestConfig(
    "/tmp/playwright-home/.config/cydo/config.yaml",
    `default_agent: claude
workspaces:
  local:
    root: /tmp/cydo-test-workspace
    permissions:
      policy: ask
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
  await expect(form).not.toBeVisible();

  // Session completes with "Done." from the mock LLM after the denied tool_result.
  await expect(assistantText(page, "Done.")).toBeVisible({
    timeout: responseTimeout(agentType),
  });
});

test("permission_policy ask: an unanswered prompt denies the call after the timeout", { tag: "@claude-only" }, async ({
  page,
  agentType,
}) => {

  writeTestConfig(
    "/tmp/playwright-home/.config/cydo/config.yaml",
    `default_agent: claude
workspaces:
  local:
    root: /tmp/cydo-test-workspace
    permissions:
      policy: ask
      prompt_timeout: 1
`,
  );

  await page.waitForTimeout(500);

  await enterSession(page);
  await sendMessage(
    page,
    "run command echo ask-timeout-test > .claude/test-ask-timeout.md",
  );

  // Nobody answers: the prompt goes away and the agent hears the denial.
  await expect(
    page.locator(".tool-call", { hasText: "echo ask-timeout-test" }),
  ).toContainText("nobody answered the permission prompt within 1 sec", {
    timeout: responseTimeout(agentType),
  });
  await expect(page.locator(".permission-prompt-form")).toHaveCount(0);
  await expect(assistantText(page, "Done.")).toBeVisible({
    timeout: responseTimeout(agentType),
  });
});

test("default policy: a call the CLI's safety checks flag asks a person", { tag: "@claude-only" }, async ({
  page,
  agentType,
}) => {
  writeTestConfig(
    "/tmp/playwright-home/.config/cydo/config.yaml",
    `default_agent: claude
workspaces:
  local:
    root: /tmp/cydo-test-workspace
`,
  );

  await page.waitForTimeout(500);

  await enterSession(page);
  await sendMessage(page, "run command cat README.md | rm -rf /");

  // Everything else runs unasked; this one waits, saying why.
  const form = page.locator(".permission-prompt-form");
  await expect(form).toBeVisible({ timeout: responseTimeout(agentType) });
  await expect(form.locator(".permission-prompt-reason")).toContainText(
    "Dangerous rm operation",
  );

  // Never allow it: the command would really run.
  await page.locator(".permission-deny-btn").click();
  await page.locator(".permission-deny-btn").click();
  await expect(form).not.toBeVisible();

  await expect(assistantText(page, "Done.")).toBeVisible({
    timeout: responseTimeout(agentType),
  });
});
