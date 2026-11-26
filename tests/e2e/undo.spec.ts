import {
  test,
  expect,
  enterSession,
  openUndoMenu,
  chooseUndo,
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
  await openUndoMenu(thirdUserMsg);
  await chooseUndo(page, "Undo conversation");

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
  "a stopped Claude session offers no undo for its first message",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    // Rewriting the session file back to before its first message would leave
    // Claude no conversation to resume.
    await enterSession(page);

    await sendMessage(page, 'Please reply with "first-undo-kept"');
    await expect(assistantText(page, "first-undo-kept")).toBeVisible();
    await sendMessage(page, 'Please reply with "second-undo-offered"');
    await expect(assistantText(page, "second-undo-offered")).toBeVisible();

    await killSession(page, agentType);

    const userMessage = (text: string) =>
      page
        .locator(".message-wrapper", {
          has: page.locator(".user-message", { hasText: text }),
        })
        .last();
    const second = userMessage("second-undo-offered");
    await second.hover();
    await expect(second.locator(".undo-btn")).toBeVisible();

    const first = userMessage("first-undo-kept");
    await first.hover();
    await expect(first.locator(".fork-btn")).toBeVisible();
    await expect(first.locator(".undo-btn")).toHaveCount(0);
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
    const liveMenu = await openUndoMenu(assistant);
    // Assistant boundaries never carry a file checkpoint, even during live
    // JSONL reconciliation.
    await expect(
      liveMenu.getByRole("menuitem", { name: "Undo files only", exact: true }),
    ).toHaveCount(0);
    await page.keyboard.press("Escape");

    await killSession(page, agentType);
    await page.reload();
    await expect(assistantText(page, selected)).toBeVisible();
    assistant = page
      .locator(".message-wrapper", {
        has: page.locator(".assistant-message", { hasText: selected }),
      })
      .last();
    const endedMenu = await openUndoMenu(assistant);
    await expect(
      endedMenu.getByRole("menuitem", { name: "Undo files only", exact: true }),
    ).toHaveCount(0);
    await expect(endedMenu).toContainText(
      "Remove this response and later history?",
    );
    await expect(endedMenu).toContainText(
      "The preceding prompt will remain.",
    );
    await chooseUndo(page, "Undo conversation");

    await expect(assistantText(page, selected)).toHaveCount(0);
    await expect(assistantText(page, later)).toHaveCount(0);
    await expect(
      page.locator(".message.user-message:not(.pending)", { hasText: prompt }),
    ).toBeVisible();
  },
);
