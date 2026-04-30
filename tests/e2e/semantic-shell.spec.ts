import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  type Page,
  type AgentType,
} from "./fixtures";

async function lastShellToolCall(
  page: Page,
  agentType: AgentType,
  timeout: number,
) {
  const toolName = agentType === "codex" ? "commandExecution" : "Bash";
  const toolCall = page
    .locator(".tool-call")
    .filter({ has: page.locator(".tool-name", { hasText: toolName }) })
    .last();
  await expect(toolCall).toBeVisible({ timeout });
  return toolCall;
}

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

  // Assert semantic-shell-read container is visible (result is expanded by default,
  // input is collapsed for reads per Phase 1 auto-expand/collapse)
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
 * Test 3: pipe-read (accepted)
 *
 * Sends a prompt that triggers `cat README.md | head -5`. With the v2 parser,
 * this pipeline is classified as a Read and renders through the semantic
 * shell read pipeline (data-testid="semantic-shell-read").
 */
test("semantic shell: pipe read renders through file content preview", async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  const timeout = responseTimeout(agentType);

  await sendMessage(page, "semantic shell pipe read README.md");

  const toolName = agentType === "codex" ? "commandExecution" : "Bash";
  const toolCall = page
    .locator(".tool-call")
    .filter({ has: page.locator(".tool-name", { hasText: toolName }) })
    .last();
  await expect(toolCall).toBeVisible({ timeout });

  // Assert semantic-shell-read container is visible
  const semanticRead = toolCall.locator('[data-testid="semantic-shell-read"]');
  await expect(semanticRead).toBeVisible({ timeout });
});

/**
 * Test 4: rejection fallback
 *
 * Sends a prompt that triggers `cat README.md | rm -rf /`. The pipe stage
 * "rm" is not in the formatting allowlist, so the parser rejects it and
 * output renders through the normal .tool-result path.
 */
test("semantic shell: unrecognized pipe stage falls back to normal rendering", async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  const timeout = responseTimeout(agentType);

  await sendMessage(page, "semantic shell pipe reject README.md");

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


/**
 * Test 5: heredoc script execution
 *
 * Sends a prompt that triggers a heredoc Python script execution.
 * Asserts that the command input renders as three parts: header, script
 * content, and terminator, using the semantic-shell-script container.
 */
test("semantic shell: heredoc script renders with syntax-highlighted body", async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  const timeout = responseTimeout(agentType);

  await sendMessage(page, "semantic shell script");

  const toolName = agentType === "codex" ? "commandExecution" : "Bash";
  const toolCall = page
    .locator(".tool-call")
    .filter({ has: page.locator(".tool-name", { hasText: toolName }) })
    .last();
  await expect(toolCall).toBeVisible({ timeout });

  // Assert semantic-shell-script container is visible in the input area
  const semanticScript = toolCall.locator(
    '[data-testid="semantic-shell-script"]',
  );
  await expect(semanticScript).toBeVisible({ timeout });

  // The header should contain the python3 command
  await expect(semanticScript).toContainText("python3");

  // The script content should be visible
  await expect(semanticScript).toContainText("import json");

  // The terminator should be visible as the footer
  await expect(semanticScript).toContainText("PY");
});

/**
 * Test N: git diff renders through PatchView (semantic-shell-diff)
 *
 * Sends a prompt that triggers `git log -p -1 --no-color -- README.md`.
 * Asserts that the result renders through the semantic shell diff pipeline
 * (data-testid="semantic-shell-diff") rather than plain terminal output,
 * and that the result section is expanded by default.
 */
test("semantic shell: git diff renders through patch view", async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  const timeout = responseTimeout(agentType);

  await sendMessage(page, "semantic shell diff");

  // Wait for the tool call to appear
  const toolName = agentType === "codex" ? "commandExecution" : "Bash";
  const toolCall = page
    .locator(".tool-call")
    .filter({ has: page.locator(".tool-name", { hasText: toolName }) })
    .last();
  await expect(toolCall).toBeVisible({ timeout });

  // Assert semantic-shell-diff container is visible (result is expanded by default,
  // input is collapsed for diffs per auto-expand/collapse)
  const semanticDiff = toolCall.locator('[data-testid="semantic-shell-diff"]');
  await expect(semanticDiff).toBeVisible({ timeout });
});

test("semantic shell: wrapped python heredoc preserves wrapper syntax and content", async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  const timeout = responseTimeout(agentType);

  await sendMessage(page, "semantic shell wrapped python heredoc");
  const toolCall = await lastShellToolCall(page, agentType, timeout);

  const semanticScript = toolCall.locator(
    '[data-testid="semantic-shell-script"]',
  );
  await expect(semanticScript).toBeVisible({ timeout });
  await expect(semanticScript).toContainText("/run/current-system/sw/bin/zsh");
  await expect(semanticScript).toContainText("-lc");
  await expect(semanticScript).toContainText("<<'PY'");
  await expect(semanticScript).toContainText("PY");
  await expect(semanticScript).toContainText('print("wrapped")');
  await expect(semanticScript).toContainText('"');
});

test("semantic shell: wrapped markdown heredoc renders semantic output with proven boundaries", async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  const timeout = responseTimeout(agentType);

  await sendMessage(page, "semantic shell wrapped markdown heredoc");
  const toolCall = await lastShellToolCall(page, agentType, timeout);

  const semanticWrite = toolCall.locator('[data-testid="semantic-shell-write"]');
  await expect(semanticWrite).toBeVisible({ timeout });
  await expect(semanticWrite).toContainText("bash");
  await expect(semanticWrite).toContainText("-lc");
  await expect(semanticWrite).toContainText("mkdir -p");
  await expect(semanticWrite).toContainText("<<'EOF'");
  await expect(semanticWrite).toContainText("EOF");
  await expect(semanticWrite).toContainText("ls -l");
  await expect(semanticWrite).toContainText("sed -n");

  const semanticOut = toolCall.locator('[data-testid="semantic-shell-output"]');
  await expect(semanticOut).toBeVisible({ timeout });
  await expect(semanticOut.locator(".markdown")).toContainText("Wrapped Markdown");
  await expect(semanticOut.locator(".markdown")).toHaveCount(1);
  await expect(semanticOut).toContainText("-rw");
});

test("semantic shell: rg structured output keeps per-line prefixes and independent line rendering", async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  const timeout = responseTimeout(agentType);

  await sendMessage(page, "semantic shell rg structured");
  const toolCall = await lastShellToolCall(page, agentType, timeout);

  const searchRoot = toolCall.locator(
    '[data-testid="semantic-shell-output-search"]',
  );
  await expect(searchRoot).toBeVisible({ timeout });

  const prefixes = searchRoot.locator(
    '[data-testid="semantic-shell-line-prefix"]',
  );
  await expect(prefixes.first()).toBeVisible({ timeout });
  const count = await prefixes.count();
  expect(count).toBeGreaterThanOrEqual(2);
  const first = (await prefixes.first().innerText()).trim();
  expect(first).toMatch(/^\d+:/);
});

test("semantic shell: unsupported rg fallback stays raw", async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  const timeout = responseTimeout(agentType);

  await sendMessage(page, "semantic shell rg fallback");
  const toolCall = await lastShellToolCall(page, agentType, timeout);

  await expect(
    toolCall.locator('[data-testid="semantic-shell-output-search"]'),
  ).not.toBeVisible();
  const rawResult = toolCall.locator(".tool-result").first();
  if (!(await rawResult.isVisible())) {
    const resultHeader = toolCall.locator(".tool-result-header");
    if ((await resultHeader.count()) > 0) {
      await resultHeader.click();
    }
  }
  await expect(toolCall.locator(".tool-result")).toContainText(
    /semantic shell|rg: command not found|rg: not found/,
  );
});

test("semantic shell: sed/printf sections keep delimiter anchors", async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  const timeout = responseTimeout(agentType);

  await sendMessage(page, "semantic shell sections");
  const toolCall = await lastShellToolCall(page, agentType, timeout);
  const root = toolCall.locator('[data-testid="semantic-shell-output"]');
  await expect(root).toBeVisible({ timeout });

  await expect(root.getByText("--- section ---")).toHaveCount(1);
  const pieceCount = await root.locator(".semantic-shell-structured-piece").count();
  expect(pieceCount).toBeGreaterThanOrEqual(2);

  await page.context().grantPermissions(
    ["clipboard-read", "clipboard-write"],
    { origin: "http://localhost:3940" },
  );
  await page.bringToFront();
  const copyButton = root.locator(".semantic-shell-output-toolbar .btn-copy");
  await expect(copyButton).toBeVisible({ timeout });
  const probe = await page.evaluate(async () => {
    await navigator.clipboard.writeText("__cydo_clipboard_probe__");
    return navigator.clipboard.readText();
  });
  expect(probe).toBe("__cydo_clipboard_probe__");
  await copyButton.click({ force: true });
  const expectedClipboard =
    agentType === "claude"
      ? "import {\n\n--- section ---\nimport {"
      : "import {\n\n--- section ---\nimport {\n";
  await expect
    .poll(() => page.evaluate(() => navigator.clipboard.readText()))
    .toBe(expectedClipboard);
});

test("semantic shell: duplicated section delimiters fall back without guessed markdown", async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  const timeout = responseTimeout(agentType);

  await sendMessage(page, "semantic shell sections fallback");
  const toolCall = await lastShellToolCall(page, agentType, timeout);

  await expect(
    toolCall.locator('[data-testid="semantic-shell-output"]'),
  ).not.toBeVisible();
  const rawResult = toolCall.locator(".tool-result").first();
  if (!(await rawResult.isVisible())) {
    const resultHeader = toolCall.locator(".tool-result-header");
    if ((await resultHeader.count()) > 0) {
      await resultHeader.click();
    }
  }
  await expect(toolCall.locator(".tool-result")).toContainText("section");
});
