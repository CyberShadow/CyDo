import { test, expect, enterSession, sendMessage, responseTimeout } from "./fixtures";

test("page loads and shows CyDo branding", async ({ page, agentType }) => {
  test.skip(agentType === "codex", "agent-agnostic, runs in claude project only");
  await page.goto("/");
  await expect(page.locator(".welcome-page-header h1")).toContainText("CyDo", {
    timeout: 10_000,
  });
});

test("basic message and response", async ({ page, agentType }) => {
  await enterSession(page);

  const input = page.locator(".input-textarea");
  await expect(input).toBeEnabled({ timeout: 15_000 });
  await input.fill('Please reply with "OK"');
  await page.getByRole("button", { name: "Send" }).click();

  await expect(page.locator(".message.user-message")).toBeVisible({
    timeout: 15_000,
  });

  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "OK" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
});

test("tool call flow", async ({ page, agentType }) => {
  test.skip(agentType === "copilot", "MCP Bash tool not yet reliable in test sandbox");
  await enterSession(page);

  // Use base64 so the output ("aGVsbG8tZnJvbS10ZXN0Cg==") is distinct from
  // the input command — this lets us assert input and output independently.
  const input = page.locator(".input-textarea");
  await expect(input).toBeEnabled({ timeout: 15_000 });
  await input.fill("Please run command echo hello-from-test | base64");
  await page.getByRole("button", { name: "Send" }).click();

  const timeout = responseTimeout(agentType);
  const toolName = agentType === "codex" ? "commandExecution" : "Bash";

  await expect(
    page.locator(".tool-name", { hasText: toolName }),
  ).toBeVisible({ timeout });

  // Verify the command text is rendered in the tool call block (not just the tool name).
  await expect(
    page.locator(".tool-call", { hasText: toolName }),
  ).toContainText("echo hello-from-test", { timeout });

  // Verify the command output appears in the tool result.
  await expect(
    page.locator(".tool-result", { hasText: "aGVsbG8tZnJvbS10ZXN0" }),
  ).toBeVisible({ timeout });

  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "Done." }),
  ).toBeVisible({ timeout });
});

test("codex tool call renders output content", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "codex", "codex-only test");
  // This test verifies that Codex tool results include structured content
  // that the frontend can render (not just the tool name).
  await enterSession(page);
  await sendMessage(page, "run command echo hello-from-test | base64");
  await expect(
    page.locator(".tool-result", { hasText: "aGVsbG8tZnJvbS10ZXN0" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
});

test("codex agent type indicator", async ({ page, agentType }) => {
  test.skip(agentType !== "codex", "codex-only test");
  await enterSession(page);

  const input = page.locator(".input-textarea");
  await expect(input).toBeEnabled({ timeout: 15_000 });
  await input.fill('reply with "hello"');
  await page.getByRole("button", { name: "Send" }).click();

  await expect(page.locator(".message.assistant-message")).toBeVisible({ timeout: 60_000 });
  await expect(page.locator(".banner-agent")).toBeVisible({ timeout: 10_000 });
  await expect(page.locator(".banner-agent")).toContainText("codex", { ignoreCase: true });
});

test("codex file fixture shows view-file action", async ({ page, agentType }) => {
  test.skip(agentType !== "codex", "codex-only test");

  await enterSession(page);
  await sendMessage(page, "codex filechange create fixture");
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "Done." }).last(),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  const timeout = responseTimeout(agentType);
  const tool = page
    .locator(".tool-call")
    .filter({ has: page.locator(".tool-name", { hasText: /fileChange/i }) })
    .last();
  await expect(tool).toBeVisible({ timeout });

  await tool.locator(".tool-header").hover();
  const viewBtn = tool.locator(".tool-view-file");
  await expect(viewBtn).toBeVisible({ timeout: 5_000 });
  await viewBtn.click();
  await expect(page.locator(".file-viewer")).toBeVisible({ timeout: 5_000 });
  await expect(page.locator(".file-viewer")).toContainText("codex-fileviewer-create.txt");
  await expect(page.locator(".file-viewer")).toContainText("hello from create fixture");
});

test("codex update fixture shows patch preview", async ({ page, agentType }) => {
  test.skip(agentType !== "codex", "codex-only test");

  await enterSession(page);
  await sendMessage(page, "codex filechange create fixture");
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "Done." }).last(),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
  await sendMessage(page, "codex filechange update fixture");
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "Done." }),
  ).toHaveCount(2, { timeout: responseTimeout(agentType) });

  const timeout = responseTimeout(agentType);
  const tool = page
    .locator(".tool-call")
    .filter({ has: page.locator(".tool-name", { hasText: /fileChange/i }) })
    .last();
  await expect(tool).toBeVisible({ timeout });

  // dispatchEvent bypasses CSS display:none on the hover-reveal button
  await tool.locator(".tool-view-file").dispatchEvent("click");
  await expect(page.locator(".file-viewer")).toBeVisible({ timeout: 5_000 });
  await expect(page.locator(".file-viewer")).toContainText("codex-fileviewer-create.txt");
  // Edit history should show the Patch entry tracked from the second fileChange
  await expect(page.locator(".file-viewer")).toContainText(/Patch/);
});

test("codex delete fixture shows deleted state", async ({ page, agentType }) => {
  test.skip(agentType !== "codex", "codex-only test");

  await enterSession(page);
  await sendMessage(page, "codex filechange create fixture");
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "Done." }).last(),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
  await sendMessage(page, "codex filechange delete fixture");
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "Done." }),
  ).toHaveCount(2, { timeout: responseTimeout(agentType) });

  const timeout = responseTimeout(agentType);
  const tool = page
    .locator(".tool-call")
    .filter({ has: page.locator(".tool-name", { hasText: /fileChange/i }) })
    .last();
  await expect(tool).toBeVisible({ timeout });

  // dispatchEvent bypasses CSS display:none on the hover-reveal button
  await tool.locator(".tool-view-file").dispatchEvent("click");
  await expect(page.locator(".file-viewer")).toBeVisible({ timeout: 5_000 });
  await expect(page.locator(".file-viewer")).toContainText("codex-fileviewer-create.txt");
  // Edit history should show the Delete entry tracked from the second fileChange
  await expect(page.locator(".file-viewer")).toContainText(/Delete/);
});
