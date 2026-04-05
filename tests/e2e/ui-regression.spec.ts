import { test, expect, enterSession, sendMessage, killSession, responseTimeout } from "./fixtures";

test("sidebar status dot reflects session state", async ({ page, agentType }) => {
  await enterSession(page);
  await sendMessage(page, 'Please reply with "dot-test"');

  const sidebarItem = page.locator(".sidebar-item", {
    hasText: "dot-test",
  });
  await expect(sidebarItem).toBeVisible({ timeout: responseTimeout(agentType) });

  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "dot-test" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  const dotAliveTimeout = agentType === "codex" ? 10_000 : 5_000;
  await expect(sidebarItem.locator(".task-type-icon.alive")).toBeVisible({ timeout: dotAliveTimeout });

  await killSession(page, agentType);

  const dotFailedTimeout = agentType === "codex" ? 10_000 : 5_000;
  await expect(sidebarItem.locator(".task-type-icon.failed")).toBeVisible({ timeout: dotFailedTimeout });
});

test("multi-client navigation isolation", async ({ page, agentType, context }) => {
  test.skip(agentType === "codex", "claude-only test");
  const pageA = page;
  const pageB = await context.newPage();

  await enterSession(pageA);
  await enterSession(pageB);

  await sendMessage(pageA, 'Please reply with "isolation-a"');

  await expect(
    pageA.locator(".message.user-message", { hasText: "isolation-a" }),
  ).toBeVisible({ timeout: 15_000 });

  await expect(
    pageB.locator(".message.user-message", { hasText: "isolation-a" }),
  ).not.toBeVisible();

  await expect(
    pageB.locator(".sidebar-item .sidebar-label", { hasText: "isolation-a" }),
  ).toBeVisible({ timeout: 15_000 });

  await pageB.close();
});

test("auto-scroll stays at bottom for new messages", async ({ page, agentType }) => {
  await enterSession(page);

  await sendMessage(page, 'Please reply with "scroll-test"');
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "scroll-test" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  const scrollTop = await page.locator(".message-list").evaluate(
    (el) => el.scrollTop,
  );
  expect(scrollTop).toBeGreaterThanOrEqual(-1);
});

test("tool result with Bash output renders correctly", async ({ page, agentType }) => {
  test.skip(agentType === "copilot", "MCP Bash tool not yet reliable in test sandbox");
  await enterSession(page);
  await sendMessage(page, "Please run command echo tool-result-test");

  const toolName = agentType === "codex" ? "commandExecution" : "Bash";
  await expect(
    page.locator(".tool-name", { hasText: toolName }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  await expect(
    page.locator(".tool-result", { hasText: "tool-result-test" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) + 15_000 });

  // Tool subtitle only present for Claude (description field)
  if (agentType === "claude") {
    await expect(
      page.locator(".tool-subtitle", { hasText: "Running command" }),
    ).toBeVisible({ timeout: 5_000 });
  }
});

test("fork stays focused on forked session", async ({ page, agentType }) => {
  await enterSession(page);
  await sendMessage(page, 'Please reply with "fork-source"');

  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "fork-source" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  if (agentType === "codex" || agentType === "copilot") {
    // Codex/Copilot: kill and reload so JSONL is finalized and fork buttons appear
    await killSession(page, agentType);
    await page.reload();
    await expect(
      page.locator(".message.assistant-message .text-content", { hasText: "fork-source" }),
    ).toBeVisible({ timeout: responseTimeout(agentType) });
  }

  const userMsg = page.locator(".message-wrapper").filter({
    has: page.locator(".message.user-message", { hasText: "fork-source" }),
  });
  await userMsg.hover();
  const forkBtn = userMsg.locator(".fork-btn");
  await expect(forkBtn).toBeVisible({ timeout: 15_000 });

  await forkBtn.click();

  const forkEntry = page.locator(".sidebar-item .sidebar-label", { hasText: "(fork)" });
  await expect(forkEntry).toBeVisible({ timeout: 10_000 });

  const forkSidebarItem = page.locator(".sidebar-item.active", { hasText: "(fork)" });
  await expect(forkSidebarItem).toBeVisible({ timeout: 5_000 });

  // Use :visible to avoid strict mode violation from multiple resume buttons (codex sessions)
  await expect(page.locator(".btn-banner-resume:visible").first()).toBeVisible({ timeout: 5_000 });
});

test("assistant messages do not render literal undefined", async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  await sendMessage(page, 'reply with "hello"');
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "hello" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
  // Ensure no text block renders literal "undefined"
  const undefinedBlocks = page.locator(".text-content", { hasText: /^undefined$/ });
  await expect(undefinedBlocks).toHaveCount(0);
});
