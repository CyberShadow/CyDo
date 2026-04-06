import { test, expect, enterSession, sendMessage, responseTimeout } from "./fixtures";

test("system_prompt_template is sent to the LLM API", async ({ page, agentType }) => {
  await enterSession(page);

  // Base64-encode the unique marker from defs/prompts/test_system_prompt.md.
  // The mock API will decode this and check if it appears anywhere in the
  // serialized API request (which includes system prompts, messages, etc.).
  const marker = Buffer.from("CYDO_TEST_SYSTEM_PROMPT_MARKER").toString("base64");

  // Create a sub-task of type test_system_prompt. The sub-task's user message
  // triggers the mock API's "check context contains" pattern, which searches
  // the full API request for the decoded marker string.
  await sendMessage(page, `call task test_system_prompt check context contains ${marker}`);

  // The sub-task result should contain "context-check-passed" if the system
  // prompt template was correctly sent to the LLM API.
  // Use .first() because the result text may also appear in nested sub-agent
  // messages (loaded asynchronously), causing a strict mode violation.
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "context-check-passed",
    }).first(),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
});
