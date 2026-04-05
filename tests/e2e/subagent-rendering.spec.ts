/**
 * Verifies that sub-agent messages with parent_tool_use_id render nested
 * inside .sub-agent-messages under the parent tool call.
 *
 * Uses the mock API to return Claude's built-in Task tool_use block.
 * Claude CLI handles this internally by spawning a sub-agent, which makes
 * its own API request. The sub-agent is prompted to run a command, which
 * forces it to emit an intermediate assistant message with a Bash tool_use
 * block before completing.
 *
 * Root cause 1 (backend): normalizeUserLive dropped parent_tool_use_id on
 *   user messages — fixed in source/cydo/agent/claude.d.
 *
 * Root cause 2 (frontend): MessageView memo comparator did not check the
 *   `children` prop — fixed in web/src/components/MessageList.tsx.
 */
import { test, expect, enterSession, sendMessage, responseTimeout } from "./fixtures";

test("sub-agent messages with parent_tool_use_id render nested", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "claude", "claude-only — uses Claude's built-in Task tool");
  test.setTimeout(120_000);

  await enterSession(page);

  // Select the "blank" entry point which has allow_native_subagents: true,
  // enabling Claude's built-in Task tool for spawning sub-agents.
  await page.locator("button.task-type-row", { hasText: "blank" }).click();

  // Trigger Claude's built-in Task tool via the mock API.
  // The sub-agent is directed to run a command, causing it to make a Bash
  // tool call before finishing. This produces intermediate sub-agent
  // assistant messages with parent_tool_use_id, exercising both bug fixes.
  await sendMessage(page, "spawn task run command echo hello");

  const timeout = responseTimeout(agentType);

  // Bug 1 (backend): the sub-agent's user message (task prompt) must appear
  // nested inside .sub-agent-messages. Verifies parent_tool_use_id is
  // propagated for user messages.
  await expect(
    page.locator(
      '[style*="display: contents"] .sub-agent-messages .user-message',
    ),
  ).toBeVisible({ timeout });

  // Bug 2 (frontend): the sub-agent's assistant message (with the Bash
  // tool_use block) must also appear nested. Verifies MessageView re-renders
  // when childrenByParent updates.
  await expect(
    page.locator(
      '[style*="display: contents"] .sub-agent-messages .assistant-message',
    ),
  ).toBeVisible({ timeout: 15_000 });
});
