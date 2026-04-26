import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
} from "./fixtures";

test("first message renders as collapsed system-user-message with entry point label", async ({
  page,
  agentType,
}) => {
  test.skip(
    agentType === "codex",
    "agent-agnostic, runs in claude project only",
  );

  await enterSession(page);

  const messageText = 'Please reply with "system-msg-test"';
  await sendMessage(page, messageText);

  // The first message should render as a system-user-message (template style)
  const userMsg = page
    .locator(".message.user-message.system-user-message")
    .first();
  await expect(userMsg).toBeVisible({ timeout: 15_000 });

  // The entry point label is shown in the header (exact name depends on default
  // entry point configured in the test workspace)
  const headerText = await userMsg.locator(".system-user-header").innerText();
  expect(headerText.trim().length).toBeGreaterThan(0);

  // The user's text is visible in the default (non-expanded) view
  const body = userMsg.locator(".system-user-body, .user-text");
  await expect(body.first()).toContainText(messageText);

  // The <details> element exists (collapsed by default)
  const details = userMsg.locator("details.system-user-full-text");
  await expect(details).toBeAttached();
  await expect(details).not.toHaveAttribute("open");

  // Click the <details> to expand and verify the full message
  await details.locator("summary").click();
  await expect(details).toHaveAttribute("open", "");

  // The full message for the "blank" template is just the task_description
  const pre = details.locator("pre");
  await expect(pre).toContainText(messageText);
});

test("system-user-message persists after agent confirms the message", async ({
  page,
  agentType,
}) => {
  test.skip(
    agentType === "codex",
    "agent-agnostic, runs in claude project only",
  );

  await enterSession(page);

  const messageText = 'Please reply with "system-msg-confirm-test"';
  await sendMessage(page, messageText);

  // Wait for the agent to respond — this means the is_replay confirmation echo
  // has replaced the pending message, which is where the cydoMeta bug triggers.
  await expect(assistantText(page, "system-msg-confirm-test")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // After the agent has responded, the user message must still render as a
  // system-user-message with a label and the original text.
  const userMsg = page
    .locator(".message.user-message.system-user-message")
    .first();
  await expect(userMsg).toBeVisible();

  const headerText = await userMsg.locator(".system-user-header").innerText();
  expect(headerText.trim().length).toBeGreaterThan(0);

  const body = userMsg.locator(".system-user-body, .user-text");
  await expect(body.first()).toContainText(messageText);
});

test("session-start system message stays collapsed after reload", async ({
  page,
  agentType,
}) => {
  test.skip(
    agentType === "codex",
    "agent-agnostic, runs in claude project only",
  );

  await enterSession(page);
  const messageText = 'Please reply with "session-start-replay"';
  await sendMessage(page, messageText);
  await expect(assistantText(page, "session-start-replay")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  await page.reload();
  await expect(
    page.locator(".system-user-message", { hasText: "Session start:" }).first(),
  ).toBeVisible({ timeout: 30_000 });
});

test("task prompt system message keeps task type label after reload", async ({
  page,
  agentType,
}) => {
  test.skip(
    agentType === "codex",
    "agent-agnostic, runs in claude project only",
  );

  await enterSession(page);
  await sendMessage(page, 'call task research reply with "task-prompt-replay"');

  await page.locator('.sidebar-item[data-tid="2"]').waitFor({
    state: "visible",
    timeout: 30_000,
  });
  await page.locator('.sidebar-item[data-tid="2"]').click();
  await expect(
    page.locator(".system-user-message", { hasText: "Task prompt: research" }),
  ).toBeVisible({ timeout: 30_000 });

  await page.reload();
  await page.locator('.sidebar-item[data-tid="2"]').click();
  await expect(
    page.locator(".system-user-message", { hasText: "Task prompt: research" }),
  ).toBeVisible({ timeout: 30_000 });
});
