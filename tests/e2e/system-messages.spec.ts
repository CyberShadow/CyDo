import { test, expect, enterSession, sendMessage } from "./fixtures";

test("first message renders as collapsed system-user-message with entry point label", async ({
  page,
  agentType,
}) => {
  test.skip(agentType === "codex", "agent-agnostic, runs in claude project only");

  await enterSession(page);

  const messageText = 'Please reply with "system-msg-test"';
  await sendMessage(page, messageText);

  // The first message should render as a system-user-message (template style)
  const userMsg = page.locator(".message.user-message.system-user-message").first();
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

  // Click the <details> to expand and verify the full rendered text
  await details.locator("summary").click();
  await expect(details).toHaveAttribute("open", "");

  // The full rendered text for the "blank" template is just the task_description
  const pre = details.locator("pre");
  await expect(pre).toContainText(messageText);
});
