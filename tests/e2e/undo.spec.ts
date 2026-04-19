import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
} from "./fixtures";

test("undo moves user message text to input box", async ({
  page,
  agentType,
}) => {
  // Known bug: Codex undo doesn't truncate history at undo point
  test.fixme(
    agentType === "codex",
    "Known bug: Codex undo doesn't truncate history at undo point",
  );

  await enterSession(page);

  await sendMessage(page, 'Please reply with "reply-one"');
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "reply-one",
    }),
  ).toBeVisible({ timeout: 30_000 });

  await sendMessage(page, 'Please reply with "reply-two"');
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "reply-two",
    }),
  ).toBeVisible({ timeout: 30_000 });

  await sendMessage(page, 'Please reply with "reply-three"');
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "reply-three",
    }),
  ).toBeVisible({ timeout: 30_000 });

  await sendMessage(page, 'Please reply with "reply-four"');
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "reply-four",
    }),
  ).toBeVisible({ timeout: 30_000 });

  await sendMessage(page, 'Please reply with "reply-five"');
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "reply-five",
    }),
  ).toBeVisible({ timeout: 30_000 });

  await killSession(page, agentType);

  // Before undo: all 5 user messages must be visible (confirmed, not pending)
  for (const marker of [
    "reply-one",
    "reply-two",
    "reply-three",
    "reply-four",
    "reply-five",
  ]) {
    await expect(
      page.locator(".message.user-message:not(.pending)", { hasText: marker }),
    ).toBeVisible({ timeout: 15_000 });
  }

  // Undo at message 3
  const thirdUserMsg = page
    .locator(".message-wrapper", {
      has: page.locator(".user-message", { hasText: "reply-three" }),
    })
    .last();
  await thirdUserMsg.hover();

  await expect(thirdUserMsg.locator(".undo-btn")).toBeVisible({
    timeout: 5_000,
  });
  await thirdUserMsg.locator(".undo-btn").click();

  await expect(page.locator(".undo-dialog")).toBeVisible({ timeout: 5_000 });
  await page.locator(".btn-undo").click();

  // After undo: exactly 2 confirmed user messages remain
  await expect(page.locator(".message.user-message:not(.pending)")).toHaveCount(
    2,
    { timeout: 15_000 },
  );

  // After undo: exactly 2 assistant messages remain (reply-one and reply-two)
  await expect(page.locator(".message.assistant-message")).toHaveCount(2, {
    timeout: 15_000,
  });

  // Messages 1 and 2 are still visible (user + assistant)
  await expect(
    page.locator(".message.user-message:not(.pending)", {
      hasText: "reply-one",
    }),
  ).toBeVisible();
  await expect(
    page.locator(".message.user-message:not(.pending)", {
      hasText: "reply-two",
    }),
  ).toBeVisible();
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "reply-one",
    }),
  ).toBeVisible();
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "reply-two",
    }),
  ).toBeVisible();

  // Messages 3, 4, 5 are gone
  for (const marker of ["reply-three", "reply-four", "reply-five"]) {
    await expect(
      page.locator(".message.user-message", { hasText: marker }),
    ).not.toBeVisible();
    await expect(
      page.locator(".message.assistant-message .text-content", {
        hasText: marker,
      }),
    ).not.toBeVisible();
  }

  // Input box contains the undone message text
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeVisible({ timeout: 15_000 });
  await expect(input).toHaveValue(/reply with "reply-three"/, {
    timeout: 15_000,
  });
});
