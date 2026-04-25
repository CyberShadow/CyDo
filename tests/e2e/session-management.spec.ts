import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
} from "./fixtures";

test("session creation shows sidebar entry", async ({ page, agentType }) => {
  await enterSession(page);
  await sendMessage(page, 'Please reply with "hello-claude"');

  await expect(
    page.locator(".sidebar-item .sidebar-label", { hasText: "hello-claude" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  await expect(
    page.locator(".message.user-message", {
      hasText: 'Please reply with "hello-claude"',
    }),
  ).toBeVisible({ timeout: 15_000 });
});

test("session switching preserves messages", async ({ page, agentType }) => {
  // Create first session and send a message
  await enterSession(page);
  await sendMessage(page, 'Please reply with "first"');
  await expect(assistantText(page, "first")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // Create second session and send a message
  await enterSession(page);
  await sendMessage(page, 'Please reply with "second"');
  await expect(assistantText(page, "second")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // Switch back to first task via sidebar
  await page
    .locator(".sidebar-item .sidebar-label", { hasText: "first" })
    .click();

  await expect(assistantText(page, "first")).toBeVisible({ timeout: 10_000 });

  await expect(assistantText(page, "second")).not.toBeVisible();
});

test("build artifact sanity: hashed asset references", async ({
  page,
  agentType,
}) => {
  test.skip(
    agentType === "codex",
    "agent-agnostic, runs in claude project only",
  );
  const response = await page.goto("/");
  const html = await response!.text();

  expect(html).toMatch(/\/assets\/index-[A-Za-z0-9_-]+\.js/);
  expect(html).toMatch(/\/assets\/index-[A-Za-z0-9_-]+\.css/);
  expect(html).not.toContain("/src/main.tsx");
});
