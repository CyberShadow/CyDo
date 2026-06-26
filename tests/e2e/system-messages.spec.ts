import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
} from "./fixtures";

test("first message renders as collapsed system-user-message with entry point label", { tag: "@no-codex" }, async ({
  page,
  agentType,
}) => {

  await enterSession(page);

  const messageText = 'Please reply with "system-msg-test"';
  await sendMessage(page, messageText);
  await expect(assistantText(page, "system-msg-test")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  const userMsg = page
    .locator(".message.user-message.system-user-message")
    .first();
  await expect(userMsg).toBeVisible({ timeout: 15_000 });

  const headerText = await userMsg.locator(".system-user-header").innerText();
  expect(headerText.trim().length).toBeGreaterThan(0);

  const body = userMsg.locator(".system-user-body, .user-text");
  await expect(body.first()).toContainText(messageText);

  const details = userMsg.locator("details.system-user-full-text");
  await expect(details).toBeAttached();
  await expect(details).not.toHaveAttribute("open");

  await details.locator("summary").click();
  await expect(details).toHaveAttribute("open", "");

  const pre = details.locator("pre");
  await expect(pre).toContainText(messageText);
});

test("system-user-message persists after agent confirms the message", { tag: "@no-codex" }, async ({
  page,
  agentType,
}) => {

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

test("session-start system message stays collapsed after reload", { tag: "@no-codex" }, async ({
  page,
  agentType,
}) => {

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

test("task prompt system message keeps task type label after reload", { tag: "@no-codex" }, async ({
  page,
  agentType,
}) => {
  const taskCreatedEvents: Array<{
    tid: number;
    relation_type?: string;
  }> = [];

  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        const data = JSON.parse(event.payload.toString());
        if (data.type === "task_created") {
          taskCreatedEvents.push({
            tid: data.tid,
            relation_type: data.relation_type,
          });
        }
      } catch {
        /* ignore non-JSON frames */
      }
    });
  });

  await enterSession(page);
  await sendMessage(page, 'call task research reply with "task-prompt-replay"');

  let childTid: number | null = null;
  await expect(async () => {
    childTid =
      taskCreatedEvents.find((event) => event.relation_type === "subtask")?.tid ??
      null;
    expect(childTid).not.toBeNull();
  }).toPass({ timeout: 30_000 });

  await page.locator(`.sidebar-item[data-tid="${childTid}"]`).waitFor({
    state: "visible",
    timeout: 30_000,
  });
  await page.locator(`.sidebar-item[data-tid="${childTid}"]`).click();
  await expect(
    page.locator(".system-user-message", { hasText: "Task prompt: research" }),
  ).toBeVisible({ timeout: 30_000 });

  await page.reload();
  await page.locator(`.sidebar-item[data-tid="${childTid}"]`).click();
  await expect(
    page.locator(".system-user-message", { hasText: "Task prompt: research" }),
  ).toBeVisible({ timeout: 30_000 });
});
