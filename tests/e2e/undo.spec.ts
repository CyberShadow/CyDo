import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
  assistantText,
} from "./fixtures";

test("undo moves user message text to input box", async ({
  page,
  agentType,
}) => {
  const taskCreatedEvents: Array<{
    tid: number;
    parent_tid?: number;
    relation_type?: string;
  }> = [];
  if (agentType === "codex") {
    page.on("websocket", (ws) => {
      ws.on("framereceived", (event) => {
        try {
          const frame = JSON.parse(event.payload.toString());
          if (frame?.type === "task_created") taskCreatedEvents.push(frame);
        } catch {
          // Ignore non-JSON frames.
        }
      });
    });
  }

  await enterSession(page);

  await sendMessage(page, 'Please reply with "reply-one"');
  await expect(assistantText(page, "reply-one")).toBeVisible();

  await sendMessage(page, 'Please reply with "reply-two"');
  await expect(assistantText(page, "reply-two")).toBeVisible();

  await sendMessage(page, 'Please reply with "reply-three"');
  await expect(assistantText(page, "reply-three")).toBeVisible();

  await sendMessage(page, 'Please reply with "reply-four"');
  await expect(assistantText(page, "reply-four")).toBeVisible();

  await sendMessage(page, 'Please reply with "reply-five"');
  await expect(assistantText(page, "reply-five")).toBeVisible();

  await killSession(page, agentType);

  const confirmedUser = page.locator(".message.user-message:not(.pending)");
  const replyUser = confirmedUser.filter({
    hasText: /reply-(one|two|three|four|five)/,
  });

  // Before undo: all 5 user messages must be visible (confirmed, not pending)
  for (const marker of [
    "reply-one",
    "reply-two",
    "reply-three",
    "reply-four",
    "reply-five",
  ]) {
    await expect(replyUser.filter({ hasText: marker })).toBeVisible();
  }

  // Undo at message 3
  const thirdUserMsg = page
    .locator(".message-wrapper", {
      has: page.locator(".user-message", { hasText: "reply-three" }),
    })
    .last();
  await thirdUserMsg.hover();

  await expect(thirdUserMsg.locator(".undo-btn")).toBeVisible();
  await thirdUserMsg.locator(".undo-btn").click();

  await expect(page.locator(".undo-dialog")).toBeVisible();
  await page.locator(".btn-undo").click();

  // After undo: exactly 2 confirmed user messages remain
  await expect(replyUser).toHaveCount(2);

  // After undo: exactly 2 assistant messages remain (reply-one and reply-two)
  await expect(page.locator(".message.assistant-message")).toHaveCount(2);

  // Messages 1 and 2 are still visible (user + assistant)
  await expect(replyUser.filter({ hasText: "reply-one" })).toBeVisible();
  await expect(replyUser.filter({ hasText: "reply-two" })).toBeVisible();
  await expect(assistantText(page, "reply-one")).toBeVisible();
  await expect(assistantText(page, "reply-two")).toBeVisible();

  // Messages 3, 4, 5 are gone
  for (const marker of ["reply-three", "reply-four", "reply-five"]) {
    await expect(replyUser.filter({ hasText: marker })).not.toBeVisible();
    await expect(assistantText(page, marker)).not.toBeVisible();
  }

  // Input box contains the undone message text
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeVisible();
  await expect(input).toHaveValue(
    'Please reply with "reply-three"\n\nPlease reply with "reply-four"\n\nPlease reply with "reply-five"',
  );

  if (agentType === "codex") {
    await expect(async () => {
      expect(
        taskCreatedEvents.find(
          (event) => event.relation_type === "undo-backup",
        ),
      ).toBeTruthy();
    }).toPass();

    const backupTid = taskCreatedEvents.find(
      (event) => event.relation_type === "undo-backup",
    )!.tid;
    await page.reload();
    const backup = page.locator(`.sidebar-item[data-tid="${backupTid}"]`);
    await expect(backup).toBeVisible();
    await backup.click();
    await expect(assistantText(page, "reply-five")).toBeVisible();
  }
});

test(
  "undo on first Claude message restores draft input",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    await enterSession(page);

    const prompt = 'Please reply with "first-undo-draft"';
    await sendMessage(page, prompt);
    await expect(assistantText(page, "first-undo-draft")).toBeVisible();

    await killSession(page, agentType);

    const firstUserMsg = page
      .locator(".message-wrapper", {
        has: page.locator(".user-message", { hasText: "first-undo-draft" }),
      })
      .last();
    await expect(firstUserMsg).toBeVisible();
    await firstUserMsg.hover();

    await expect(firstUserMsg.locator(".undo-btn")).toBeVisible();
    await firstUserMsg.locator(".undo-btn").click();

    await expect(page.locator(".undo-dialog")).toBeVisible();
    await page.locator(".btn-undo").click();

    await expect(
      page.locator(".message.user-message:not(.pending)", {
        hasText: "first-undo-draft",
      }),
    ).toHaveCount(0);
    await expect(assistantText(page, "first-undo-draft")).toHaveCount(0);

    const input = page.locator(".input-textarea:visible").first();
    await expect(input).toBeVisible();
    await expect(input).toHaveValue(prompt);
  },
);

test(
  "offline assistant undo retains its prompt",
  { tag: "@no-codex" },
  async ({ page, agentType }) => {
    const prompt = "ASSISTANT_UNDO_PROMPT";
    const selected = "ASSISTANT_UNDO_SELECTED";
    const later = "ASSISTANT_UNDO_LATER";

    await enterSession(page);
    await sendMessage(page, `Reply exactly with ${selected}. ${prompt}`);
    await expect(assistantText(page, selected)).toBeVisible();
    await sendMessage(page, `Reply exactly with ${later}`);
    await expect(assistantText(page, later)).toBeVisible();

    let assistant = page
      .locator(".message-wrapper", {
        has: page.locator(".assistant-message", { hasText: selected }),
      })
      .last();
    await assistant.hover();
    await expect(assistant.locator(".undo-btn")).toBeVisible();
    await assistant.locator(".undo-btn").click();
    await expect(page.locator(".undo-dialog")).toBeVisible();
    // Assistant boundaries never carry a file checkpoint, even during live
    // JSONL reconciliation.
    await expect(
      page.locator('.undo-dialog input[type="checkbox"]').nth(1),
    ).toBeDisabled();
    await page.locator(".undo-dialog .btn", { hasText: "Cancel" }).click();

    await killSession(page, agentType);
    await page.reload();
    await expect(assistantText(page, selected)).toBeVisible();
    assistant = page
      .locator(".message-wrapper", {
        has: page.locator(".assistant-message", { hasText: selected }),
      })
      .last();
    await assistant.hover();
    await assistant.locator(".undo-btn").click();
    await expect(
      page.locator('.undo-dialog input[type="checkbox"]').nth(1),
    ).toBeDisabled();
    await expect(page.locator(".undo-dialog-prompt-retention")).toHaveText(
      "This response and later history will be removed. The preceding prompt will remain.",
    );
    await page.locator(".btn-undo").click();

    await expect(assistantText(page, selected)).toHaveCount(0);
    await expect(assistantText(page, later)).toHaveCount(0);
    await expect(
      page.locator(".message.user-message:not(.pending)", { hasText: prompt }),
    ).toBeVisible();
  },
);
