import {
  test,
  expect,
  enterSession,
  sendMessage,
  assistantText,
} from "./fixtures";

test("codex alive-path undo: session stays alive after undo", async ({
  page,
  agentType,
}) => {
  test.skip(
    agentType !== "codex",
    "Codex-only: tests thread/rollback undo path",
  );

  await enterSession(page);

  await sendMessage(page, 'Please reply with "alive-one"');
  await expect(assistantText(page, "alive-one")).toBeVisible({
    timeout: 90_000,
  });

  await sendMessage(page, 'Please reply with "alive-two"');
  await expect(assistantText(page, "alive-two")).toBeVisible({
    timeout: 90_000,
  });

  await sendMessage(page, 'Please reply with "alive-three"');
  await expect(assistantText(page, "alive-three")).toBeVisible({
    timeout: 90_000,
  });

  await sendMessage(page, 'Please reply with "alive-four"');
  await expect(assistantText(page, "alive-four")).toBeVisible({
    timeout: 90_000,
  });

  await sendMessage(page, 'Please reply with "alive-five"');
  await expect(assistantText(page, "alive-five")).toBeVisible({
    timeout: 90_000,
  });

  // Session is idle but alive — do NOT kill it before undoing.
  await expect(page.locator(".input-textarea:visible").first()).toBeEnabled({
    timeout: 15_000,
  });

  // Hover over the third user message to reveal the undo button.
  const thirdUserMsg = page
    .locator(".message-wrapper:visible", {
      has: page.locator(".user-message:visible", { hasText: "alive-three" }),
    })
    .last();
  await thirdUserMsg.hover();

  await expect(thirdUserMsg.locator(".undo-btn")).toBeVisible({
    timeout: 5_000,
  });
  await thirdUserMsg.locator(".undo-btn").click();

  await expect(page.locator(".undo-dialog:visible")).toBeVisible({
    timeout: 5_000,
  });
  await page.locator(".btn-undo:visible").click();

  // After undo: exactly turns 1-2 remain.
  await expect(
    page.locator(
      ".message.user-message:not(.pending):not(.meta-message):visible",
    ),
  ).toHaveCount(2, { timeout: 15_000 });

  // After undo: exactly 2 assistant messages remain.
  await expect(page.locator(".message.assistant-message:visible")).toHaveCount(
    2,
    {
      timeout: 15_000,
    },
  );

  // alive-one/alive-two remain.
  await expect(
    page.locator(".message.user-message:not(.pending):visible", {
      hasText: "alive-one",
    }),
  ).toBeVisible();
  await expect(
    page.locator(".message.user-message:not(.pending):visible", {
      hasText: "alive-two",
    }),
  ).toBeVisible();
  await expect(assistantText(page, "alive-one")).toBeVisible();
  await expect(assistantText(page, "alive-two")).toBeVisible();

  // alive-three..alive-five are gone.
  for (const marker of ["alive-three", "alive-four", "alive-five"]) {
    await expect(
      page.locator(".message.user-message:visible", { hasText: marker }),
    ).not.toBeVisible();
    await expect(assistantText(page, marker)).not.toBeVisible();
  }

  // Session is still alive: input box is visible and enabled.
  await expect(page.locator(".input-textarea:visible").first()).toBeEnabled({
    timeout: 15_000,
  });

  // Send a follow-up message to confirm the session is fully functional.
  await sendMessage(page, 'Please reply with "alive-six"');
  await expect(assistantText(page, "alive-six")).toBeVisible({
    timeout: 90_000,
  });
});
