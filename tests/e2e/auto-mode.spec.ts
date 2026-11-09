import { writeTestConfig } from "./test-config";
import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
} from "./fixtures";

// The mock API's classifier flags tool calls that mention AUTO_MODE_FLAG.

test(
  "auto mode: approving a classifier denial lets the agent retry",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    writeTestConfig(
      "/tmp/playwright-home/.config/cydo/config.yaml",
      `default_agent: claude
workspaces:
  local:
    root: /tmp/cydo-test-workspace
    auto_mode: true
`,
    );
    await page.waitForTimeout(500);

    await enterSession(page);
    await sendMessage(page, "run command echo AUTO_MODE_FLAG blocked");

    const denial = page.locator(".tool-denial");
    await expect(denial).toContainText(
      "mock classifier: the call mentions AUTO_MODE_FLAG",
      { timeout: responseTimeout(agentType) },
    );
    await expect(assistantText(page, "Done.")).toBeVisible({
      timeout: responseTimeout(agentType),
    });

    await denial.locator(".approve-retry-btn").click();
    await expect(denial.locator(".approve-retry-btn")).toBeDisabled();
    await expect(
      page.locator(".message.user-message", {
        hasText:
          'Permission granted for this exact command only, as one whole string: "echo AUTO_MODE_FLAG blocked".',
      }),
    ).toBeVisible({ timeout: responseTimeout(agentType) });

    // Calls the classifier does not flag run without asking anyone.
    await sendMessage(page, "run command echo auto-mode-allowed");
    await expect(
      page
        .locator(".tool-call", { hasText: "echo auto-mode-allowed" })
        .locator(".tool-result"),
    ).toContainText("auto-mode-allowed", {
      timeout: responseTimeout(agentType),
    });
    await expect(page.locator(".permission-prompt-form")).toHaveCount(0);
  },
);

test(
  "auto mode: the permission policy rules before the classifier",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    writeTestConfig(
      "/tmp/playwright-home/.config/cydo/config.yaml",
      `default_agent: claude
workspaces:
  local:
    root: /tmp/cydo-test-workspace
    auto_mode: true
    permission_policy: '{{ "ask" if tool_name == "Bash" else "auto" }}'
`,
    );
    await page.waitForTimeout(500);

    await enterSession(page);
    await sendMessage(page, "run command echo AUTO_MODE_FLAG asked");

    // The policy asks a person; the classifier never gets to block the call.
    const form = page.locator(".permission-prompt-form");
    await expect(form).toBeVisible({ timeout: responseTimeout(agentType) });
    await page.locator(".permission-allow-btn").click();
    await expect(form).not.toBeVisible();
    await expect(
      page
        .locator(".tool-call", { hasText: "echo AUTO_MODE_FLAG asked" })
        .locator(".tool-result"),
    ).toContainText("AUTO_MODE_FLAG asked", {
      timeout: responseTimeout(agentType),
    });
    await expect(page.locator(".tool-denial")).toHaveCount(0);
  },
);
