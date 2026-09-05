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

const userEventText = (event: any): string =>
  typeof event?.text === "string"
    ? event.text
    : Array.isArray(event?.content)
      ? event.content
          .filter((block: any) => block?.type === "text")
          .map((block: any) => block.text)
          .join("")
      : "";

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
  await expect(userMsg.locator(".undo-btn")).toBeVisible();
  await userMsg.locator(".undo-btn").click();
  await expect(page.locator(".undo-dialog")).toBeVisible();
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

test(
  "claude live idle undo latest turn avoids UUID truncation alert",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    const timeout = responseTimeout(agentType);
    const frames: any[] = [];
    page.on("websocket", (ws) => {
      ws.on("framereceived", (event) => {
        try {
          frames.push(JSON.parse(event.payload.toString()));
        } catch {}
      });
    });
    await enterSession(page);

    await sendMessage(page, 'Please reply with "alert-one"');
    await expect(assistantText(page, "alert-one")).toBeVisible({ timeout });

    await sendMessage(page, 'Please reply with "alert-two"');
    await expect(assistantText(page, "alert-two")).toBeVisible({ timeout });

    await openUndoDialogForTurn(page, "alert-two");
    const revertFilesCheckbox = page
      .locator(".undo-dialog-options label", { hasText: "Revert file changes" })
      .locator('input[type="checkbox"]');
    if ((await revertFilesCheckbox.count()) > 0) {
      await revertFilesCheckbox.first().uncheck();
    }

    await page.locator(".btn-undo").click();

    const input = page.locator(".input-textarea:visible").first();
    await expect(input).toBeEnabled();
    await expect(async () => {
      await assertTurnPresence(page, ["alert-one"], true);
      await assertTurnPresence(page, ["alert-two"], false);
    }).toPass();

    await expect(
      page.locator(".command-error-dialog", {
        hasText: "UUID not found for truncation",
      }),
    ).toHaveCount(0);

    await expect(input).toHaveValue('Please reply with "alert-two"');
  },
);

test("all agents publish canonical boundary replacements without duplicate transcript messages", async ({
  page,
  agentType,
}) => {
  const frames: any[] = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        frames.push(JSON.parse(event.payload.toString()));
      } catch {}
    });
  });
  await enterSession(page);
  const bootstrap = "boundary-bootstrap";
  await sendMessage(page, userPrompt(bootstrap));
  await expect(assistantText(page, bootstrap)).toBeVisible({
    timeout: responseTimeout(agentType),
  });
  const turn = "boundary-cross-driver";
  const targetPrompt = userPrompt(turn);
  await sendMessage(page, targetPrompt);
  await expect(assistantText(page, turn)).toBeVisible({
    timeout: responseTimeout(agentType),
  });
  // Stopping the real agent flushes its native history file, allowing the
  // JSONL tracker to correlate the just-visible canonical events.
  await killSession(page);
  await expect(async () => {
    const replacements = frames.filter(
      (frame) =>
        frame?.type === "task_history_boundary_replaced" &&
        typeof frame?.seq === "number" &&
        typeof frame?.event?.history_boundary?.anchor === "string",
    );
    expect(replacements.length).toBeGreaterThan(0);
    expect(new Set(replacements.map((frame) => frame.seq)).size).toBe(
      replacements.length,
    );
    expect(
      new Set(replacements.map((frame) => frame.event.history_boundary.kind)),
    ).toEqual(new Set(["user", "agent_turn"]));
    const targetUsers = frames.filter(
      (frame) =>
        frame?.type !== "task_history_boundary_replaced" &&
        frame?.event?.type === "item/started" &&
        frame?.event?.item_type === "user_message" &&
        !frame?.event?.is_meta &&
        !frame?.event?.is_synthetic &&
        !frame?.event?.pending &&
        !frame?.event?.history_boundary &&
        frame?.event?.content?.length === 1 &&
        frame.event.content[0]?.text === targetPrompt,
    );
    expect(targetUsers).toHaveLength(1);
    const targetSeq = targetUsers[0]?.seq;
    expect(
      replacements.filter(
        (frame) =>
          frame.seq === targetSeq &&
          frame.event.history_boundary.kind === "user",
      ),
    ).toHaveLength(1);
    for (const replacement of replacements) {
      expect(
        frames.some(
          (frame) =>
            frame?.type !== "task_history_boundary_replaced" &&
            frame?.seq === replacement.seq &&
            !frame?.event?.history_boundary,
        ),
      ).toBe(true);
    }
  }).toPass();
  const replacements = frames.filter(
    (frame) => frame?.type === "task_history_boundary_replaced",
  );
  const replayFrames: any[] = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        replayFrames.push(JSON.parse(event.payload.toString()));
      } catch {}
    });
  });
  await page.reload();
  await expect(assistantText(page, turn)).toBeVisible({
    timeout: responseTimeout(agentType),
  });
  await expect(assistantText(page, turn)).toHaveCount(1);
  await expect(
    page.locator(
      ".message.user-message:not(.pending):not(.meta-message):visible",
      {
        hasText: targetPrompt,
      },
    ),
  ).toHaveCount(1);
  await expect(() =>
    expect(
      replayFrames.some((frame) => frame?.type === "task_history_end"),
    ).toBe(true),
  ).toPass();
});

test(
  "claude live idle undo restores user message text into the textarea",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    const prompt = 'Please reply with "reply-one"';
    const timeout = responseTimeout(agentType);
    const frames: any[] = [];
    page.on("websocket", (ws) => {
      ws.on("framereceived", (event) => {
        try {
          frames.push(JSON.parse(event.payload.toString()));
        } catch {}
      });
    });
    await enterSession(page);
    await sendMessage(page, prompt);
    await expect(assistantText(page, "reply-one")).toBeVisible({ timeout });

    await expect(() => {
      const originals = frames.filter(
        (frame) =>
          frame?.type !== "task_history_boundary_replaced" &&
          frame?.event?.type === "item/started" &&
          frame?.event?.item_type === "user_message" &&
          !frame?.event?.pending &&
          !frame?.event?.is_meta &&
          userEventText(frame.event).includes(prompt),
      );
      expect(originals).toHaveLength(1);
      const seq = originals[0].seq;
      expect(typeof seq).toBe("number");
      const canonicalUserFrames = frames.filter(
        (frame) =>
          frame?.type === "task_history_boundary_replaced" &&
          frame?.seq === seq &&
          frame?.event?.history_boundary?.kind === "user" &&
          typeof frame.event.history_boundary.anchor === "string" &&
          frame.event.history_boundary.anchor.length > 0,
      );
      expect(canonicalUserFrames).toHaveLength(1);
      expect(
        frames.some(
          (frame) =>
            frame?.type === "history_operations" &&
            frame?.history_operations?.undo?.user === "jsonl",
        ),
      ).toBe(true);
    }).toPass({ timeout });

    const input = page.locator(".input-textarea:visible").first();
    await expect(input).toBeEnabled();

    await openUndoDialogForTurn(page, "reply-one");
    await page.locator(".btn-undo").click();

    await expect(input).toBeEnabled();
    await expect(async () => {
      await assertTurnPresence(page, ["reply-one"], false);
    }).toPass();

    await expect(input).toHaveValue(prompt);
  },
);

test(
  "claude live idle undo on turn three removes only turns three through five",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
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
    await expect(input).toBeEnabled();
    await openUndoDialogForTurn(page, "live-three");
    await page.locator(".btn-undo").click();
    await expect(input).toBeEnabled();
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
    }).toPass();

    await expect(input).toHaveValue(
      'Please reply with "live-three"\n\nPlease reply with "live-four"\n\nPlease reply with "live-five"',
    );

    await sendMessage(page, 'Please reply with "live-six"');
    await expect(assistantText(page, "live-six")).toBeVisible({ timeout });
  },
);

test(
  "claude undo preview targets the same turn before and after reload",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
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

    await expect(page.locator(".input-textarea:visible").first()).toBeEnabled();

    await openUndoDialogForTurn(page, "reload-three");
    await page.locator(".undo-dialog .btn", { hasText: "Cancel" }).click();
    await expect(page.locator(".undo-dialog")).not.toBeVisible();

    await killSession(page, agentType);
    await expect(
      page.locator(".message.user-message:not(.pending):not(.meta-message)", {
        hasText: "reload-three",
      }),
    ).toBeVisible();

    await openUndoDialogForTurn(page, "reload-three");
    await page.locator(".btn-undo").click();
    await expect(page.locator(".input-textarea:visible").first()).toBeEnabled();
    await expect(page.locator(".input-textarea:visible").first()).toHaveValue(
      /Please reply with "reload-three"/,
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
    }).toPass();
  },
);

test(
  "claude undo protocol keeps reload barrier and stable seq assignments",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
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
    await expect(page.locator(".input-textarea:visible").first()).toBeEnabled();

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

      const operationsIdx = frames.findIndex(
        (msg, idx) =>
          idx > reloadIdx &&
          msg?.type === "history_operations" &&
          msg?.history_operations?.fork?.user === "jsonl",
      );
      expect(operationsIdx).toBeGreaterThan(reloadIdx);

      const historyEndIdx = frames.findIndex(
        (msg, idx) => idx > reloadIdx && msg?.type === "task_history_end",
      );
      expect(historyEndIdx).toBeGreaterThan(reloadIdx);
      expect(operationsIdx).toBeLessThan(historyEndIdx);
    }).toPass();

    const seqToAnchor = new Map<number, string>();
    const conflicts: string[] = [];
    for (const frame of frames) {
      if (frame?.type !== "task_history_boundary_replaced") continue;
      const boundary = frame.event?.history_boundary;
      if (typeof frame.seq !== "number" || typeof boundary?.anchor !== "string")
        continue;
      const prev = seqToAnchor.get(frame.seq);
      if (prev && prev !== boundary.anchor) {
        conflicts.push(`seq ${frame.seq}: ${prev} -> ${boundary.anchor}`);
      } else {
        seqToAnchor.set(frame.seq, boundary.anchor);
      }
    }
    expect(
      conflicts,
      `Unexpected boundary replacement conflicts: ${conflicts.join(", ")}`,
    ).toEqual([]);
    for (const [seq, anchor] of seqToAnchor) {
      expect(anchor).not.toEqual("");
      expect(
        frames.some(
          (frame) =>
            frame?.type !== "task_history_boundary_replaced" &&
            frame?.seq === seq,
        ),
      ).toBe(true);
    }
  },
);
