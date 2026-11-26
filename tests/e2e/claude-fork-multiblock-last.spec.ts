import {
  test,
  expect,
  enterSession,
  openUndoMenu,
  chooseUndo,
  sendMessage,
  assistantText,
  currentTaskTid,
  historyPathForTask,
  readHistoryFile,
  killSession,
} from "./fixtures";

function assistantMessages(tid: number) {
  return readHistoryFile(historyPathForTask(tid))
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line))
    .filter((record) => record.type === "assistant")
    .map((record) => record.message);
}

async function parentMessageIds(tid: number) {
  let finalMessageId = "";
  let secondRoundMessageId = "";
  await expect(async () => {
    const messages = assistantMessages(tid);
    const byId = new Map<string, typeof messages>();
    for (const message of messages) {
      const group = byId.get(message.id) ?? [];
      group.push(message);
      byId.set(message.id, group);
    }
    const toolRounds = [...byId.values()].filter(
      (group) =>
        group.length === 2 &&
        group.every((message) => message.content[0].type === "tool_use"),
    );
    expect(toolRounds).toHaveLength(2);
    const secondRound = toolRounds.find(
      (group) =>
        group.map((message) => message.content[0].input.command).join(",") ===
        "echo second-round-a,echo second-round-b",
    );
    expect(secondRound).toBeDefined();
    const final = messages.find(
      (message) => message.content[0].text === "fork-final-last-block",
    );
    expect(
      byId.get(final?.id)?.map((message) => message.content[0].text),
    ).toEqual(["fork-final-first-block", "fork-final-last-block"]);
    finalMessageId = final!.id;
    secondRoundMessageId = secondRound![0].id;
  }).toPass({ timeout: 20_000 });
  return { finalMessageId, secondRoundMessageId };
}

async function forkFromLastBlock(
  page: Parameters<typeof currentTaskTid>[0],
  parentTid: number,
) {
  const lastMessage = page
    .locator(".message-wrapper:visible", {
      has: page.locator(".assistant-message:visible", {
        hasText: "fork-final-last-block",
      }),
    })
    .last();
  await lastMessage.hover();
  await expect(lastMessage.locator(".fork-btn")).toBeVisible();
  await lastMessage.locator(".fork-btn").click();
  await expect(page).toHaveURL(new RegExp(`/task/(?!${parentTid}$)\\d+$`));
  return currentTaskTid(page);
}

async function expectCompleteFinalMessage(tid: number, finalMessageId: string) {
  await expect(async () => {
    const childMessages = assistantMessages(tid);
    const final = childMessages.filter(
      (message) => message.id === finalMessageId,
    );
    expect(final.map((message) => message.content[0].text)).toEqual([
      "fork-final-first-block",
      "fork-final-last-block",
    ]);
  }).toPass({ timeout: 20_000 });
}

test(
  "fork below last Claude assistant block preserves the complete API message",
  { tag: "@claude-only" },
  async ({ page }) => {
    await enterSession(page);
    await sendMessage(page, "fork multi-block rounds fixture");
    await expect(assistantText(page, "fork-final-last-block")).toBeVisible();
    const parentTid = currentTaskTid(page);

    const { finalMessageId } = await parentMessageIds(parentTid);
    const childTid = await forkFromLastBlock(page, parentTid);

    // The fork's JSONL must retain the selected API message as a whole.
    await expectCompleteFinalMessage(childTid, finalMessageId);
  },
);

test(
  "reload fork and undo preserve Claude API message boundaries",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    await enterSession(page);
    await sendMessage(page, "fork multi-block rounds fixture");
    await expect(assistantText(page, "fork-final-last-block")).toBeVisible();
    const parentTid = currentTaskTid(page);
    const { finalMessageId, secondRoundMessageId } = await parentMessageIds(
      parentTid,
    );

    await killSession(page, agentType);
    await page.reload();
    await expect(assistantText(page, "fork-final-last-block")).toBeVisible();
    const childTid = await forkFromLastBlock(page, parentTid);
    await expectCompleteFinalMessage(childTid, finalMessageId);

    const lastMessage = page
      .locator(".message-wrapper:visible", {
        has: page.locator(".assistant-message:visible", {
          hasText: "fork-final-last-block",
        }),
      })
      .last();
    const menu = await openUndoMenu(lastMessage);
    await expect(menu).toContainText(
      "Remove this response and later history?",
    );
    await expect(menu).toContainText(
      "The preceding prompt will remain.",
    );
    await chooseUndo(page, "Undo conversation");

    await expect(async () => {
      const messages = assistantMessages(childTid);
      expect(
        messages.filter((message) => message.id === finalMessageId),
      ).toHaveLength(0);
      expect(
        messages
          .filter((message) => message.id === secondRoundMessageId)
          .map((message) => message.content[0].input.command),
      ).toEqual(["echo second-round-a", "echo second-round-b"]);
    }).toPass({ timeout: 20_000 });
    await expect(assistantText(page, "fork-final-first-block")).toHaveCount(0);
    await expect(assistantText(page, "fork-final-last-block")).toHaveCount(0);
    await expect(
      page.locator(".tool-call:visible", { hasText: "second-round-a" }),
    ).toBeVisible();
    await expect(
      page.locator(".tool-call:visible", { hasText: "second-round-b" }),
    ).toBeVisible();
  },
);
