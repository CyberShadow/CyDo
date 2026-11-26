import {
  test,
  expect,
  enterSession,
  openUndoMenu,
  chooseUndo,
  sendMessage,
  killSession,
  responseTimeout,
  type Page,
  assistantText,
  currentTaskTid,
  historyPathForTask,
  readHistoryFile,
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

async function openUndoMenuForTurn(page: Page, turnText: string) {
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
  await openUndoMenu(userMsg);
}

async function readUndoRemovalCount(page: Page): Promise<number> {
  const countText =
    (await page.locator(".undo-menu-count").textContent()) ?? "";
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

    await openUndoMenuForTurn(page, "alert-two");

    // The idle live session is offered the in-process rewind.
    expect(
      frames.findLast((frame) => frame?.type === "history_operations")
        ?.history_operations?.undo?.user,
    ).toBe("claude_native");
    const tid = currentTaskTid(page);
    const framesBeforeUndo = frames.length;
    await chooseUndo(page, "Undo conversation");

    const input = page.locator(".input-textarea:visible").first();
    await expect(input).toBeEnabled();
    await expect(async () => {
      await assertTurnPresence(page, ["alert-one"], true);
      await assertTurnPresence(page, ["alert-two"], false);
    }).toPass();
    // Rewound in-process: the Claude process was never stopped.
    expect(
      frames
        .slice(framesBeforeUndo)
        .filter(
          (frame) =>
            frame?.type === "task_updated" &&
            frame.task?.tid === tid &&
            !frame.task.alive,
        ),
    ).toHaveLength(0);

    await expect(
      page.locator(".command-error-dialog", {
        hasText: "UUID not found for truncation",
      }),
    ).toHaveCount(0);

    await expect(input).toHaveValue('Please reply with "alert-two"');

    // The CLI keeps the undone turn in its session file as a rewound
    // branch; read back, the history continues from before it.
    const historyPath = historyPathForTask(tid);
    expect(readHistoryFile(historyPath)).toContain("alert-two");
    await input.fill("");
    await sendMessage(page, 'Please reply with "alert-three"');
    await expect(assistantText(page, "alert-three")).toBeVisible({ timeout });
    await page.reload();
    await expect(assistantText(page, "alert-three")).toBeVisible({ timeout });
    await expect(async () => {
      await assertTurnPresence(page, ["alert-one", "alert-three"], true);
      await assertTurnPresence(page, ["alert-two"], false);
    }).toPass();
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
  // Codex can replay the same message in a new history generation after Stop.
  const liveCodexFrames = agentType === "codex" ? frames.slice() : null;
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
    // Codex names a turn when it accepts the message that starts it, so its
    // user messages arrive with their boundary; the end of a turn is known
    // only once the turn is over. The other agents' boundaries are all read
    // from their history files afterwards.
    const userBoundaryAtEmission = agentType === "codex";
    expect(
      new Set(replacements.map((frame) => frame.event.history_boundary.kind)),
    ).toEqual(
      new Set(userBoundaryAtEmission ? ["agent_turn"] : ["user", "agent_turn"]),
    );
    const targetUsers = (liveCodexFrames ?? frames).filter(
      (frame) =>
        frame?.type !== "task_history_boundary_replaced" &&
        frame?.event?.type === "item/started" &&
        frame?.event?.item_type === "user_message" &&
        !frame?.event?.is_meta &&
        !frame?.event?.is_synthetic &&
        !frame?.event?.pending &&
        (frame?.event?.history_boundary?.kind === "user") ===
          userBoundaryAtEmission &&
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
    ).toHaveLength(userBoundaryAtEmission ? 0 : 1);
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

    await openUndoMenuForTurn(page, "reply-one");
    await chooseUndo(page, "Undo conversation");

    await expect(input).toBeEnabled();
    await expect(async () => {
      await assertTurnPresence(page, ["reply-one"], false);
    }).toPass();

    await expect(input).toHaveValue(prompt);
  },
);

test(
  "non-Codex live idle undo removes selected user or assistant history",
  { tag: "@no-codex" },
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
    await openUndoMenuForTurn(page, "live-three");
    await chooseUndo(page, "Undo conversation");
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

    await enterSession(page);
    await sendMessage(page, 'Please reply with "assistant-undo-prefix"');
    await expect(assistantText(page, "assistant-undo-prefix")).toBeVisible({
      timeout,
    });
    await sendMessage(page, 'Please reply with "assistant-undo-selected"');
    await expect(assistantText(page, "assistant-undo-selected")).toBeVisible({
      timeout,
    });
    await sendMessage(page, 'Please reply with "assistant-undo-later"');
    await expect(assistantText(page, "assistant-undo-later")).toBeVisible({
      timeout,
    });
    const selectedAssistant = page
      .locator(".message-wrapper", {
        has: page.locator(".assistant-message", {
          hasText: "assistant-undo-selected",
        }),
      })
      .last();
    const menu = await openUndoMenu(selectedAssistant);
    await expect(menu).toContainText(
      "Remove this response and later history?",
    );
    await expect(menu).toContainText(
      "The preceding prompt will remain.",
    );
    await chooseUndo(page, "Undo conversation");
    await expect(async () => {
      await assertTurnPresence(page, ["assistant-undo-prefix"], true);
      await expect(
        page.locator(
          ".message.user-message:visible:not(.pending):not(.meta-message)",
          { hasText: "assistant-undo-selected" },
        ),
      ).toBeVisible();
      await expect(assistantText(page, "assistant-undo-selected")).toHaveCount(
        0,
      );
      await assertTurnPresence(page, ["assistant-undo-later"], false);
    }).toPass();
    await sendMessage(page, 'Please reply with "assistant-undo-follow-up"');
    await expect(assistantText(page, "assistant-undo-follow-up")).toBeVisible({
      timeout,
    });
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

    await openUndoMenuForTurn(page, "reload-three");
    await page.keyboard.press("Escape");
    await expect(page.locator(".undo-menu")).not.toBeVisible();

    await killSession(page, agentType);
    await expect(
      page.locator(".message.user-message:not(.pending):not(.meta-message)", {
        hasText: "reload-three",
      }),
    ).toBeVisible();

    await openUndoMenuForTurn(page, "reload-three");
    await chooseUndo(page, "Undo conversation");
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

    await openUndoMenuForTurn(page, "proto-three");
    const expectedRemoved = await readUndoRemovalCount(page);
    await chooseUndo(page, "Undo conversation");
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
