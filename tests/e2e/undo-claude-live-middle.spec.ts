import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
  responseTimeout,
  type Page,
  assistantText,
} from "./fixtures";

async function openUndoDialogForTurn(page: Page, turnText: string) {
  const userMsg = page
    .locator(".message-wrapper", {
      has: page.locator(
        ".message.user-message:not(.pending):not(.meta-message)",
        {
          hasText: turnText,
        },
      ),
    })
    .last();
  await userMsg.hover();
  await expect(userMsg.locator(".undo-btn")).toBeVisible({ timeout: 5_000 });
  await userMsg.locator(".undo-btn").click();
  await expect(page.locator(".undo-dialog")).toBeVisible({ timeout: 5_000 });
}

async function readUndoRemovalCount(page: Page): Promise<number> {
  const countText =
    (await page.locator(".undo-dialog-count").textContent()) ?? "";
  const match = countText.match(/(\d+)/);
  expect(
    match,
    `Could not parse undo count from: "${countText}"`,
  ).not.toBeNull();
  return Number(match![1]);
}

function uniqueNormalized(texts: string[]) {
  return Array.from(
    new Set(texts.map((text) => text.replace(/\s+/g, " ").trim())),
  );
}

async function readVisibleTurnTexts(page: Page) {
  const userTexts = uniqueNormalized(
    await page
      .locator(".message.user-message:visible:not(.pending):not(.meta-message)")
      .allTextContents(),
  );
  const assistantTexts = uniqueNormalized(
    await page
      .locator('[data-testid="assistant-text"]:visible')
      .allTextContents(),
  );
  return { userTexts, assistantTexts };
}

function userPrompt(turn: string) {
  return `Please reply with "${turn}"`;
}

async function assertTurnPresence(
  page: Page,
  turns: string[],
  visible: boolean,
) {
  const { userTexts, assistantTexts } = await readVisibleTurnTexts(page);
  for (const turn of turns) {
    const userFound = userTexts.some(
      (text) => text.includes(userPrompt(turn)) || text.includes(turn),
    );
    const assistantFound = assistantTexts.includes(turn);
    if (visible) {
      expect(
        userFound,
        `Expected visible user turn for ${turn}. Saw: ${userTexts.join(" | ")}`,
      ).toBe(true);
      expect(
        assistantFound,
        `Expected visible assistant turn for ${turn}. Saw: ${assistantTexts.join(" | ")}`,
      ).toBe(true);
    } else {
      expect(
        userFound,
        `Unexpected visible user turn for ${turn}. Saw: ${userTexts.join(" | ")}`,
      ).toBe(false);
      expect(
        assistantFound,
        `Unexpected visible assistant turn for ${turn}. Saw: ${assistantTexts.join(" | ")}`,
      ).toBe(false);
    }
  }
}

test("claude live idle undo latest turn avoids UUID truncation alert", async ({
  page,
  agentType,
}) => {
  test.skip(
    agentType !== "claude",
    "Claude-only regression for live latest-turn undo alert",
  );

  const timeout = responseTimeout(agentType);
  await enterSession(page);

  await sendMessage(page, 'Please reply with "alert-one"');
  await expect(assistantText(page, "alert-one")).toBeVisible({ timeout });

  await sendMessage(page, 'Please reply with "alert-two"');
  await expect(assistantText(page, "alert-two")).toBeVisible({ timeout });

  const dialogs: string[] = [];
  page.on("dialog", (dialog) => {
    dialogs.push(dialog.message());
    dialog.dismiss().catch(() => {});
  });

  await openUndoDialogForTurn(page, "alert-two");
  const revertFilesCheckbox = page
    .locator(".undo-dialog-options label", { hasText: "Revert file changes" })
    .locator('input[type="checkbox"]');
  if ((await revertFilesCheckbox.count()) > 0) {
    await revertFilesCheckbox.first().uncheck();
  }

  await page.locator(".btn-undo").click();

  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled({ timeout: 15_000 });
  await expect(async () => {
    await assertTurnPresence(page, ["alert-one"], true);
    await assertTurnPresence(page, ["alert-two"], false);
  }).toPass({ timeout: 15_000 });

  expect(
    dialogs.filter((message) => message.includes("UUID not found for truncation")),
  ).toEqual([]);
});

test("claude live idle undo on turn three removes only turns three through five", async ({
  page,
  agentType,
}) => {
  test.skip(
    agentType !== "claude",
    "Claude-only regression for live undo UUID anchoring",
  );

  const turns = [
    "live-one",
    "live-two",
    "live-three",
    "live-four",
    "live-five",
  ];
  const timeout = responseTimeout(agentType);

  await enterSession(page);
  for (const turn of turns) {
    await sendMessage(page, `Please reply with "${turn}"`);
    await expect(assistantText(page, turn)).toBeVisible({ timeout });
  }

  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled({ timeout: 15_000 });

  await openUndoDialogForTurn(page, "live-three");
  await page.locator(".btn-undo").click();
  await expect(input).toBeEnabled({ timeout: 15_000 });
  await expect(async () => {
    const { userTexts, assistantTexts } = await readVisibleTurnTexts(page);
    const survivingUserTurns = turns.filter((turn) =>
      userTexts.some(
        (text) => text.includes(userPrompt(turn)) || text.includes(turn),
      ),
    );
    const survivingAssistantTurns = turns.filter((turn) =>
      assistantTexts.includes(turn),
    );
    expect(survivingUserTurns).toHaveLength(2);
    expect(survivingAssistantTurns).toHaveLength(2);
    await assertTurnPresence(page, ["live-one", "live-two"], true);
    await assertTurnPresence(
      page,
      ["live-three", "live-four", "live-five"],
      false,
    );
  }).toPass({ timeout: 15_000 });

  await sendMessage(page, 'Please reply with "live-six"');
  await expect(assistantText(page, "live-six")).toBeVisible({ timeout });
});

test("claude undo preview targets the same turn before and after reload", async ({
  page,
  agentType,
}) => {
  test.skip(
    agentType !== "claude",
    "Claude-only regression for live/replay undo target invariant",
  );

  const turns = [
    "reload-one",
    "reload-two",
    "reload-three",
    "reload-four",
    "reload-five",
  ];
  const timeout = responseTimeout(agentType);

  await enterSession(page);
  for (const turn of turns) {
    await sendMessage(page, `Please reply with "${turn}"`);
    await expect(assistantText(page, turn)).toBeVisible({ timeout });
  }

  await expect(page.locator(".input-textarea:visible").first()).toBeEnabled({
    timeout: 15_000,
  });

  await openUndoDialogForTurn(page, "reload-three");
  await page.locator(".undo-dialog .btn", { hasText: "Cancel" }).click();
  await expect(page.locator(".undo-dialog")).not.toBeVisible({
    timeout: 5_000,
  });

  await killSession(page, agentType);
  await expect(
    page.locator(".message.user-message:not(.pending):not(.meta-message)", {
      hasText: "reload-three",
    }),
  ).toBeVisible({ timeout: 15_000 });

  await openUndoDialogForTurn(page, "reload-three");
  await page.locator(".btn-undo").click();
  await expect(page.locator(".input-textarea:visible").first()).toBeEnabled({
    timeout: 15_000,
  });
  await expect(page.locator(".input-textarea:visible").first()).toHaveValue(
    /Please reply with "reload-three"/,
    { timeout: 15_000 },
  );
  await expect(async () => {
    const { userTexts, assistantTexts } = await readVisibleTurnTexts(page);
    const survivingUserTurns = turns.filter((turn) =>
      userTexts.some(
        (text) => text.includes(userPrompt(turn)) || text.includes(turn),
      ),
    );
    const survivingAssistantTurns = turns.filter((turn) =>
      assistantTexts.includes(turn),
    );
    expect(survivingUserTurns).toHaveLength(2);
    expect(survivingAssistantTurns).toHaveLength(2);
    await assertTurnPresence(page, ["reload-one", "reload-two"], true);
    await assertTurnPresence(
      page,
      ["reload-three", "reload-four", "reload-five"],
      false,
    );
  }).toPass({ timeout: 15_000 });
});

test("claude undo protocol keeps reload barrier and stable seq assignments", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "claude", "Claude-only undo protocol regression");

  const frames: any[] = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        frames.push(JSON.parse(event.payload.toString()));
      } catch {
        // ignore non-JSON frames
      }
    });
  });

  const turns = [
    "proto-one",
    "proto-two",
    "proto-three",
    "proto-four",
    "proto-five",
  ];
  const timeout = responseTimeout(agentType);

  await enterSession(page);

  for (const turn of turns) {
    await sendMessage(page, `Please reply with "${turn}"`);
    await expect(assistantText(page, turn)).toBeVisible({ timeout });
  }

  await openUndoDialogForTurn(page, "proto-three");
  const expectedRemoved = await readUndoRemovalCount(page);
  await page.locator(".btn-undo").click();
  await expect(page.locator(".input-textarea:visible").first()).toBeEnabled({
    timeout: 15_000,
  });

  await expect(async () => {
    const undoIdx = frames.findIndex(
      (msg) =>
        msg?.type === "undo_preview" &&
        msg?.messages_removed === expectedRemoved,
    );
    expect(undoIdx).toBeGreaterThanOrEqual(0);

    const reloadIdx = frames.findIndex(
      (msg, idx) => idx > undoIdx && msg?.type === "task_reload",
    );
    expect(reloadIdx).toBeGreaterThan(undoIdx);

    const forkableIdx = frames.findIndex(
      (msg, idx) =>
        idx > reloadIdx &&
        msg?.type === "forkable_uuids" &&
        Array.isArray(msg?.uuids) &&
        msg.uuids.length > 0,
    );
    expect(forkableIdx).toBeGreaterThan(reloadIdx);

    const historyEndIdx = frames.findIndex(
      (msg, idx) => idx > reloadIdx && msg?.type === "task_history_end",
    );
    expect(historyEndIdx).toBeGreaterThan(reloadIdx);
  }).toPass({ timeout: 15_000 });

  const seqToUuid = new Map<number, string>();
  const conflicts: string[] = [];
  for (const frame of frames) {
    if (frame?.type !== "assign_uuids" || !Array.isArray(frame?.assignments))
      continue;
    for (const assignment of frame.assignments) {
      if (
        typeof assignment?.seq !== "number" ||
        typeof assignment?.uuid !== "string"
      )
        continue;
      const prev = seqToUuid.get(assignment.seq);
      if (prev && prev !== assignment.uuid) {
        conflicts.push(`seq ${assignment.seq}: ${prev} -> ${assignment.uuid}`);
      } else {
        seqToUuid.set(assignment.seq, assignment.uuid);
      }
    }
  }
  expect(
    conflicts,
    `Unexpected UUID reassignment conflicts: ${conflicts.join(", ")}`,
  ).toEqual([]);
});
