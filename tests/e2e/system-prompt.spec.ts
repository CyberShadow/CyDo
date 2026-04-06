import { test, expect, enterSession, sendMessage, responseTimeout } from "./fixtures";

test("system_prompt_template is sent to the LLM API", async ({ page, agentType }) => {
  // Only Claude uses --append-system-prompt; Codex/Copilot use different mechanisms
  test.skip(agentType !== "claude", "system prompt echo test is Claude-specific");

  await enterSession(page);

  // Create a sub-task of type test_system_prompt whose user message is
  // "echo system prompt". The mock API will extract parsed.system from the
  // Anthropic request and echo it back as the response text.
  await sendMessage(page, 'call task test_system_prompt echo system prompt');

  // Wait for the sub-task result to come back to the parent.
  // The result text should contain our unique marker from the template.
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "CYDO_TEST_SYSTEM_PROMPT_MARKER",
    }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
});
