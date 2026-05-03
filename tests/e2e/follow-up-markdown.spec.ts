import { test, expect, enterSession, sendMessage } from "./fixtures";

// Follow-up bodies must be rendered as Markdown (agent-authored content).
// This test drives the same parent→completed-child Ask flow as ask-answer.spec.ts
// but sends a message that contains Markdown bold syntax so we can assert that
// the rendered body contains a <strong> element rather than raw **…** text.

const TALK_TIMEOUT = 120_000;

test("Follow-up from parent renders body as Markdown (live and after reload)", async ({
  page,
  agentType,
}) => {
  test.setTimeout(TALK_TIMEOUT);

  await enterSession(page);

  // Create a sub-task that completes normally.
  await sendMessage(page, 'call task research reply with "initial-result"');

  // Wait for the sub-task result.
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText("initial-result", { exact: true })
      .last(),
  ).toBeVisible({ timeout: 90_000 });

  // Wait for parent's turn to complete before sending the follow-up.
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText("Done.", { exact: true })
      .last(),
  ).toBeVisible({ timeout: 30_000 });

  // Wait for focus to return to the parent task (tid=1).
  await expect(
    page.locator('.sidebar-item[data-tid="1"].active'),
  ).toBeVisible({ timeout: 90_000 });

  // Parent asks the completed child (tid=2) with a Markdown-formatted message.
  await sendMessage(page, "call ask 2 **important question**");

  // Wait for the child to answer.
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText("follow-up-answered", { exact: true })
      .last(),
  ).toBeVisible({ timeout: 90_000 });

  // Navigate to the child task and verify Markdown rendering.
  await page.locator('.sidebar-item[data-tid="2"]').click();
  await expect(
    page.locator('.sidebar-item[data-tid="2"].active'),
  ).toBeVisible({ timeout: 10_000 });

  const followUpMessage = page
    .locator(
      '[style*="display: contents"] .message-list .message.user-message.system-user-message',
      { hasText: "Follow-up from parent" },
    )
    .last();
  await expect(followUpMessage).toBeVisible({ timeout: 30_000 });

  // The body must contain a <strong> element — proof that **…** was rendered as Markdown.
  await expect(
    followUpMessage.locator(".system-user-body strong").first(),
  ).toBeVisible({ timeout: 10_000 });

  // After page reload the offline replay path must also render Markdown.
  await page.reload();
  await page.locator('.sidebar-item[data-tid="2"]').click();
  await expect(
    page.locator('.sidebar-item[data-tid="2"].active'),
  ).toBeVisible({ timeout: 10_000 });

  const followUpMessageAfterReload = page
    .locator(
      '[style*="display: contents"] .message-list .message.user-message.system-user-message',
      { hasText: "Follow-up from parent" },
    )
    .last();
  await expect(followUpMessageAfterReload).toBeVisible({ timeout: 30_000 });
  await expect(
    followUpMessageAfterReload.locator(".system-user-body strong").first(),
  ).toBeVisible({ timeout: 10_000 });
});
