import { test, expect, enterSession, sendMessage, responseTimeout } from "./fixtures";

test("markdown diff toggle button visible for .md file edit with structuredPatch", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "claude", "Claude-only: Edit tool with structuredPatch");

  await enterSession(page);

  const timeout = responseTimeout(agentType);

  // Prime Claude's file cache by reading README.md first; without this, the
  // Edit tool fails with "File has not been read yet" and returns no structuredPatch.
  await sendMessage(page, "read file README.md");
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "Done." }),
  ).toBeVisible({ timeout });

  // Now edit the file — Claude has the file cached so the Edit succeeds and
  // returns structuredPatch in the tool result. With the old ternary order,
  // patchHunks was checked first, routing to PatchView instead of MarkdownDiffView.
  await sendMessage(page, "edit file README.md replace test with updated");

  // Wait for the Edit tool call to appear and complete
  const toolCall = page.locator(".tool-call").filter({
    has: page.locator(".tool-name", { hasText: "Edit" }),
  });
  await expect(toolCall).toBeVisible({ timeout });

  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "Done." }).last(),
  ).toBeVisible({ timeout });

  // The markdown diff toggle button should be visible inside the Edit tool call.
  const toggleBtn = toolCall.locator(".markdown-diff-wrap .markdown-toggle-btn");
  await expect(toggleBtn).toBeVisible({ timeout: 5_000 });
});
