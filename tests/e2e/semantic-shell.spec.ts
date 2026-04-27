import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
} from "./fixtures";

/**
 * Test 1: cat file read
 *
 * Sends a prompt that triggers `cat README.md`. Asserts that the result renders
 * through the semantic shell read pipeline (data-testid="semantic-shell-read")
 * rather than plain terminal output, and that the result section is expanded
 * by default.
 */
test("semantic shell: cat read renders through file content preview", async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  const timeout = responseTimeout(agentType);

  await sendMessage(page, "semantic shell cat README.md");

  // Wait for the tool call to appear
  const toolName = agentType === "codex" ? "commandExecution" : "Bash";
  const toolCall = page
    .locator(".tool-call")
    .filter({ has: page.locator(".tool-name", { hasText: toolName }) })
    .last();
  await expect(toolCall).toBeVisible({ timeout });

  // Assert the command input shows the cat command
  await expect(toolCall).toContainText("cat README.md", { timeout });

  // Assert semantic-shell-read container is visible (result is expanded by default)
  const semanticRead = toolCall.locator('[data-testid="semantic-shell-read"]');
  await expect(semanticRead).toBeVisible({ timeout });
});

/**
 * Test 2: heredoc write
 *
 * Sends a prompt that triggers a heredoc `cat > file.md <<EOF` command.
 * Asserts that the command input renders as three visible parts:
 * header line, body content, and terminator.
 */
test("semantic shell: heredoc write renders header/body/footer", async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  const timeout = responseTimeout(agentType);

  await sendMessage(page, "semantic shell heredoc");

  // Wait for the tool call to appear
  const toolName = agentType === "codex" ? "commandExecution" : "Bash";
  const toolCall = page
    .locator(".tool-call")
    .filter({ has: page.locator(".tool-name", { hasText: toolName }) })
    .last();
  await expect(toolCall).toBeVisible({ timeout });

  // Assert the semantic-shell-write container is in the input area
  const semanticWrite = toolCall.locator('[data-testid="semantic-shell-write"]');
  await expect(semanticWrite).toBeVisible({ timeout });

  // The header line should show the cat command
  await expect(semanticWrite).toContainText("cat");

  // The body should render the heredoc content ("Hello World" appears in both
  // rendered and source views of the markdown)
  await expect(semanticWrite).toContainText("Hello World");

  // The terminator (EOF) should be visible as the footer
  await expect(semanticWrite).toContainText("EOF");
});

/**
 * Test 3: rejection fallback
 *
 * Sends a prompt that triggers a piped command (cat README.md | head -5).
 * The pipe makes the parser reject it, so the output should render through
 * the normal .tool-result path — no semantic-shell-read container.
 */
test("semantic shell: pipe command falls back to normal rendering", async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  const timeout = responseTimeout(agentType);

  await sendMessage(page, "semantic shell pipe README.md");

  // Wait for the tool call to appear
  const toolName = agentType === "codex" ? "commandExecution" : "Bash";
  const toolCall = page
    .locator(".tool-call")
    .filter({ has: page.locator(".tool-name", { hasText: toolName }) })
    .last();
  await expect(toolCall).toBeVisible({ timeout });

  // Expand the result section if needed
  const resultHeader = toolCall.locator(".tool-result-header");
  if (await resultHeader.isVisible()) {
    const resultContainer = toolCall.locator(".tool-result-container");
    const resultVisible = await resultContainer.isVisible();
    if (!resultVisible) {
      await resultHeader.click();
    }
  }

  // No semantic-shell-read container should appear
  await expect(
    toolCall.locator('[data-testid="semantic-shell-read"]'),
  ).not.toBeVisible();

  // Normal tool-result rendering is present
  const normalResult = toolCall.locator(".tool-result");
  await expect(normalResult).toBeVisible({ timeout });
});
