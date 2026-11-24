import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
} from "./fixtures";
import { writeTestConfig } from "./test-config";

test.use({
  backendEnv: async ({ agentType }, use) => {
    if (agentType === "claude") {
      writeTestConfig(
        "/tmp/playwright-home/.config/cydo/config.yaml",
        `default_agent: claude
workspaces:
  local:
    root: /tmp/cydo-test-workspace
    permissions:
      policy: "{{ 'ask' if tool_name == 'mcp__cydo__UnsandboxedCommand' else 'allow' }}"
`,
      );
    }
    await use({ SHELL: "/bin/sh", CYDO_E2E_HOST_MARKER: "host-env-marker" });
  },
});

test("approve a host command and see its output", async ({ page, agentType }) => {
  const prompts: string[] = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", ({ payload }) => {
      let message: { type?: string; tool_use_id?: string; tool_name?: string };
      try {
        message = JSON.parse(payload.toString());
      } catch {
        return;
      }
      if (message.type === "permission_prompt" && message.tool_use_id)
        prompts.push(message.tool_name ?? "");
    });
  });

  await enterSession(page);
  const command = `printf '%s:' "$CYDO_E2E_HOST_MARKER"; pwd`;
  await sendMessage(page, `run unsandboxed command ${command}`);

  const timeout = responseTimeout(agentType);
  const form = page.locator(".permission-prompt-form");
  await expect(form).toBeVisible({ timeout });
  await expect(form.locator(".permission-prompt-tool")).toHaveText(
    "UnsandboxedCommand",
  );
  const input = form.locator(".permission-prompt-input");
  await expect(input).toContainText(JSON.stringify(command));
  await expect(input).toContainText('"/tmp/cydo-test-workspace"');
  await expect(input).toContainText('"timeout": 60');

  await form.locator(".permission-allow-btn").click();
  await expect(form).toHaveCount(0);
  await expect(page.locator(".permission-prompt-sending")).toHaveCount(0);
  await expect(page.locator(".tool-result-container")).toContainText(
    "host-env-marker:/tmp/cydo-test-workspace",
    { timeout },
  );
  await expect(assistantText(page, "Done.")).toBeVisible({ timeout });
  expect(prompts).toEqual(["UnsandboxedCommand"]);
});
