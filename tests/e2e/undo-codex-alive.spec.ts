import { test as base } from "@playwright/test";
import { spawn } from "child_process";
import type { ChildProcess } from "child_process";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "fs";
import { basename, dirname, join, relative } from "path";
import { writeTestConfig } from "./test-config";
import {
  test,
  expect,
  enterSession,
  sendMessage,
  assistantText,
  killSession,
  killBackend,
  responseTimeout,
  visibleHistory,
  installCydoE2eBridge,
  undoThroughBridge, currentTaskTid, codexRolloutRecords, expectUndoRefusalForUserMessage, // One line on purpose: check attribute names are pinned to test() line numbers.
} from "./fixtures";
import type { Page } from "@playwright/test";

async function activeTid(page: Page): Promise<number> {
  const tid = await page
    .locator(".sidebar-item.active[data-tid]")
    .getAttribute("data-tid")
    .catch(() => null);
  if (tid !== null) return Number(tid);
  return Number(
    await page.locator(".sidebar-item[data-tid]").last().getAttribute("data-tid"),
  );
}

async function expectUndoRequestRejected(
  page: Page,
  tid: number,
  anchor: string,
  dryRun: boolean,
  revertFiles: boolean,
) {
  await undoThroughBridge(page, tid, anchor, dryRun, revertFiles);
  const errorDialog = page.locator(".command-error-dialog");
  await expect(errorDialog).toContainText("UUID not found in task history");
  await errorDialog.getByRole("button", { name: "Dismiss" }).click();
  await expect(errorDialog).not.toBeVisible();
}

async function openUndoDialogForUserMessage(
  page: import("@playwright/test").Page,
  userText: string,
) {
  const userMsg = page
    .locator(".message-wrapper:visible", {
      has: page.locator(
        ".message.user-message:visible:not(.pending):not(.meta-message)",
        { hasText: userText },
      ),
    })
    .last();
  await userMsg.hover();
  await expect(userMsg.locator(".undo-btn")).toBeVisible();
  await userMsg.locator(".undo-btn").click();
  const confirmation = page.locator(
    ".undo-dialog:not(.command-error-dialog):visible",
  );
  const commandError = page.locator(".command-error-dialog:visible");
  await expect
    .poll(
      async () =>
        (await commandError.count()) > 0
          ? "error"
          : (await confirmation.count()) > 0
            ? "confirmation"
            : "pending",
    )
    .not.toBe("pending");
  if ((await commandError.count()) > 0)
    throw new Error(
      `Unexpected undo command error: ${await commandError.innerText()}`,
    );
}

async function undoUserMessage(
  page: import("@playwright/test").Page,
  userText: string,
) {
  await openUndoDialogForUserMessage(page, userText);
  await page.locator(".btn-undo:visible").click();
}

test(
  "codex alive-path undo: session stays alive after undo",
  { tag: "@codex-only" },
  async ({ page }) => {
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

    await enterSession(page);

    await sendMessage(page, 'Please reply with "alive-one"');
    await expect(assistantText(page, "alive-one")).toBeVisible();

    await sendMessage(page, 'Please reply with "alive-two"');
    await expect(assistantText(page, "alive-two")).toBeVisible();

    await sendMessage(page, 'Please reply with "alive-three"');
    await expect(assistantText(page, "alive-three")).toBeVisible();

    await sendMessage(page, 'Please reply with "alive-four"');
    await expect(assistantText(page, "alive-four")).toBeVisible();

    await sendMessage(page, 'Please reply with "alive-five"');
    await expect(assistantText(page, "alive-five")).toBeVisible();

    // Session is idle but alive — do NOT kill it before undoing.
    await expect(page.locator(".input-textarea:visible").first()).toBeEnabled();

    const assistantUndo = page
      .locator(".message-wrapper:visible", {
        has: page.locator(".assistant-message:visible", {
          hasText: "alive-three",
        }),
      })
      .last();
    await assistantUndo.hover();
    await expect(assistantUndo.locator(".undo-btn")).toHaveCount(0);

    await openUndoDialogForUserMessage(page, 'Please reply with "alive-three"');
    await expect(page.locator(".undo-dialog-count:visible")).toContainText(
      "3 whole turns will be removed.",
    );
    const rollbackFrameStart = frames.length;
    await page.locator(".btn-undo:visible").click();

    // After undo: exactly turns 1-2 remain.
    await expect(
      page.locator(
        ".message.user-message:not(.pending):not(.meta-message):visible",
      ),
    ).toHaveCount(2);

    // After undo: exactly 2 assistant messages remain.
    await expect(
      page.locator(".message.assistant-message:visible"),
    ).toHaveCount(2);

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
    await expect(page.locator(".input-textarea:visible").first()).toBeEnabled();

    const rollbackFrames = () => frames.slice(rollbackFrameStart);
    await expect
      .poll(
        () => {
          const reloads = rollbackFrames().filter(
            (frame) => frame?.type === "task_reload",
          );
          const reloadIdx = rollbackFrames().findIndex(
            (frame) => frame?.type === "task_reload",
          );
          const historyEndIdx = rollbackFrames().findIndex(
            (frame, idx) =>
              idx > reloadIdx && frame?.type === "task_history_end",
          );
          return reloads.length === 1 && historyEndIdx > reloadIdx;
        },
      )
      .toBe(true);
    expect(
      rollbackFrames().findIndex((frame) => frame?.type === "task_history_end"),
    ).toBeGreaterThan(
      rollbackFrames().findIndex((frame) => frame?.type === "task_reload"),
    );

    // Send a follow-up message to confirm the session is fully functional.
    await sendMessage(page, 'Please reply with "alive-six"');
    await expect
      .poll(
        () =>
          rollbackFrames().some(
            (frame) =>
              typeof frame?.agentAck === "string" && frame.agentAck.length > 0,
          ),
      )
      .toBe(true);
    await expect(assistantText(page, "alive-six")).toBeVisible();
    await expect(
      page.locator(
        ".message.user-message:visible:not(.pending):not(.meta-message)",
        { hasText: "alive-six" },
      ),
    ).toBeVisible();
    expect(
      rollbackFrames().filter((frame) => frame?.type === "task_reload"),
    ).toHaveLength(1);
    expect(
      rollbackFrames().some(
        (frame) =>
          frame?.type === "task_reload" && frame?.reason === "history_lineage",
      ),
    ).toBe(false);
  },
);

test(
  "codex alive-path undo counts only active turns after prior rollback",
  { tag: "@codex-only" },
  async ({ page }) => {
    await enterSession(page);

    for (const marker of [
      "rolled-count-one",
      "rolled-count-two",
      "rolled-count-three",
    ]) {
      await sendMessage(page, `Please reply with "${marker}"`);
      await expect(assistantText(page, marker)).toBeVisible();
    }

    await undoUserMessage(page, 'Please reply with "rolled-count-three"');
    await expect(
      page.locator(
        ".message.user-message:visible:not(.pending):not(.meta-message)",
      ),
    ).toHaveCount(2);

    await sendMessage(page, 'Please reply with "rolled-count-four"');
    await expect(assistantText(page, "rolled-count-four")).toBeVisible();

    await openUndoDialogForUserMessage(
      page,
      'Please reply with "rolled-count-two"',
    );
    await expect(page.locator(".undo-dialog-count:visible")).toContainText(
      "2 whole turns will be removed.",
    );
    await page.locator(".btn-undo:visible").click();

    await expect(
      page.locator(
        ".message.user-message:visible:not(.pending):not(.meta-message)",
      ),
    ).toHaveCount(1);
    await expect(
      page.locator(".message.assistant-message:visible"),
    ).toHaveCount(1);

    await expect(
      page.locator(".message.user-message:visible", {
        hasText: "rolled-count-one",
      }),
    ).toBeVisible();
    await expect(assistantText(page, "rolled-count-one")).toBeVisible();

    for (const marker of [
      "rolled-count-two",
      "rolled-count-three",
      "rolled-count-four",
    ]) {
      await expect(
        page.locator(".message.user-message:visible", { hasText: marker }),
      ).not.toBeVisible();
      await expect(assistantText(page, marker)).not.toBeVisible();
    }
  },
);

test(
  "codex capability loss falls back to JSONL assistant undo",
  { tag: "@codex-only" },
  async ({ page, agentType }) => {
    const prompt = "CODEX_FALLBACK_PROMPT";
    const response = "CODEX_FALLBACK_RESPONSE";
    const later = "CODEX_FALLBACK_LATER";

    await enterSession(page);

    // Produce a real native rollback marker and leave its dead physical records
    // in Codex's JSONL before switching mechanisms.
    await sendMessage(page, 'Please reply with "CODEX_ROLLBACK_LIVE"');
    await expect(assistantText(page, "CODEX_ROLLBACK_LIVE")).toBeVisible();
    await sendMessage(page, 'Please reply with "CODEX_ROLLBACK_DEAD"');
    await expect(assistantText(page, "CODEX_ROLLBACK_DEAD")).toBeVisible();
    await undoUserMessage(page, 'Please reply with "CODEX_ROLLBACK_DEAD"');
    await expect(assistantText(page, "CODEX_ROLLBACK_DEAD")).toHaveCount(0);

    await sendMessage(page, `Reply exactly with ${response}. ${prompt}`);
    await expect(assistantText(page, response)).toBeVisible();
    await sendMessage(page, `Reply exactly with ${later}`);
    await expect(assistantText(page, later)).toBeVisible();
    await killSession(page, agentType);

    const assistant = page
      .locator(".message-wrapper:visible", {
        has: page.locator(".assistant-message:visible", { hasText: response }),
      })
      .last();
    await assistant.hover();
    await expect(assistant.locator(".undo-btn")).toBeVisible();
    await assistant.locator(".undo-btn").click();
    await expect(
      page.locator(".undo-dialog-prompt-retention:visible"),
    ).toHaveText(
      "This response and later history will be removed. The preceding prompt will remain.",
    );
    await expect(page.locator(".undo-dialog-count:visible")).toContainText(
      "3 messages will be removed.",
    );
    await page.locator(".btn-undo:visible").click();

    await expect(assistantText(page, response)).toHaveCount(0);
    await expect(assistantText(page, later)).toHaveCount(0);
    await expect(
      page.locator(".message.user-message:visible:not(.pending)", {
        hasText: prompt,
      }),
    ).toBeVisible();
    await expect
      .poll(() =>
        codexRolloutRecords(currentTaskTid(page)).some(
          (record) =>
            record.type === "event_msg" &&
            record.payload?.type === "agent_message" &&
            record.payload?.message === response,
        ),
      )
      .toBe(false);

    await page.reload();
    for (const marker of ["CODEX_ROLLBACK_DEAD", response, later]) {
      await expect(assistantText(page, marker)).toHaveCount(0);
    }
    await expect(
      page.locator(".message.user-message:visible:not(.pending)", {
        hasText: "CODEX_ROLLBACK_DEAD",
      }),
    ).toHaveCount(0);
    await expect(
      page.locator(".message.user-message:visible:not(.pending)", {
        hasText: prompt,
      }),
    ).toBeVisible();

    await sendMessage(page, 'Please reply with "CODEX_FALLBACK_FOLLOW_UP"');
    await expect(assistantText(page, "CODEX_FALLBACK_FOLLOW_UP")).toBeVisible();
  },
);

test(
  "codex rejects a plausible forged undo line anchor without side effects",
  { tag: "@codex-only" },
  async ({ page, backend }) => {
    await installCydoE2eBridge(page);
    const marker = "UNDO_FORGED_CANONICAL";
    const probe = "UNDO_FORGED_ALIVE";
    const testFile = `${backend.wsDir}/tmp/codex-fileviewer-create.txt`;
    const fileContent = "hello from create fixture";
    const frames: any[] = [];
    page.on("websocket", (ws) => {
      ws.on("framereceived", (event) => {
        try {
          frames.push(JSON.parse(event.payload.toString()));
        } catch {
          // Ignore non-JSON frames.
        }
      });
    });

    await enterSession(page);
    await sendMessage(page, "codex filechange create fixture");
    await expect(assistantText(page, "Done.")).toBeVisible();
    expect(readFileSync(testFile, "utf8").trimEnd()).toBe(fileContent);
    await sendMessage(page, `Reply exactly with ${marker}`);
    await expect(assistantText(page, marker)).toBeVisible();
    const tid = await activeTid(page);
    const history = await visibleHistory(page);
    const frameStart = frames.length;

    await expectUndoRequestRejected(page, tid, "line:999999", true, false);
    await expectUndoRequestRejected(page, tid, "line:999999", false, true);

    await expect.poll(() => frames.slice(frameStart).filter(
      (frame) => frame?.type === "error",
    ).length).toBe(2);
    expect(
      frames
        .slice(frameStart)
        .filter((frame) => frame?.type === "error")
        .map((frame) => ({ tid: frame.tid, message: frame.message })),
    ).toEqual([
      { tid, message: "UUID not found in task history" },
      { tid, message: "UUID not found in task history" },
    ]);
    expect(
      frames.slice(frameStart).some(
        (frame) =>
          frame?.type === "undo_preview" ||
          frame?.type === "undo_result" ||
          frame?.type === "task_reload",
      ),
    ).toBe(false);
    expect(await visibleHistory(page)).toEqual(history);
    expect(readFileSync(testFile, "utf8").trimEnd()).toBe(fileContent);
    await page.reload();
    await expect(assistantText(page, marker)).toBeVisible();
    expect(await visibleHistory(page)).toEqual(history);
    expect(readFileSync(testFile, "utf8").trimEnd()).toBe(fileContent);
    await expect(page.locator(".input-textarea:visible").first()).toBeEnabled();
    await sendMessage(page, `Reply exactly with ${probe}`);
    await expect(assistantText(page, probe)).toBeVisible();
  },
);

test(
  "codex rejects a rollback-dead undo anchor after canonical reload without side effects",
  { tag: "@codex-only" },
  async ({ page }) => {
    await installCydoE2eBridge(page);
    const retained = "UNDO_STALE_RETAINED";
    const rolledBack = "UNDO_STALE_ROLLED_BACK";
    const frames: any[] = [];
    page.on("websocket", (ws) => {
      ws.on("framereceived", (event) => {
        try {
          frames.push(JSON.parse(event.payload.toString()));
        } catch {
          // Ignore non-JSON frames.
        }
      });
    });

    await enterSession(page);
    await sendMessage(page, `Reply exactly with ${retained}`);
    await expect(assistantText(page, retained)).toBeVisible();
    await sendMessage(page, `Reply exactly with ${rolledBack}`);
    await expect(assistantText(page, rolledBack)).toBeVisible();
    const tid = await activeTid(page);
    let staleAnchor: string | undefined;
    await expect
      .poll(() => {
        const matches = frames.filter(
          (frame) =>
            frame?.type === "task_history_boundary_replaced" &&
            frame?.tid === tid &&
            frame?.event?.type === "item/started" &&
            frame?.event?.item_type === "user_message" &&
            !frame.event?.pending &&
            !frame.event?.is_meta &&
            !frame.event?.is_synthetic &&
            !frame.event?.is_sidechain &&
            Array.isArray(frame.event?.content) &&
            frame.event.content.length === 1 &&
            frame.event.content[0]?.type === "text" &&
            frame.event.content[0]?.text ===
              `Reply exactly with ${rolledBack}` &&
            frame.event?.history_boundary?.kind === "user",
        );
        staleAnchor = matches[0]?.event?.history_boundary?.anchor;
        return matches.length;
      })
      .toBe(1);
    expect(staleAnchor).toMatch(/^line:\d+$/);

    const rollbackFrameStart = frames.length;
    await undoUserMessage(page, `Reply exactly with ${rolledBack}`);
    await expect(assistantText(page, rolledBack)).toHaveCount(0);
    await expect
      .poll(
        () =>
          frames
            .slice(rollbackFrameStart)
            .some((frame) => frame?.type === "undo_result"),
      )
      .toBe(true);
    await expect
      .poll(
        () =>
          frames
            .slice(rollbackFrameStart)
            .some((frame) => frame?.type === "task_reload"),
      )
      .toBe(true);
    // Reload from the canonical active boundary set before replaying the old
    // physical JSONL line anchor through the normal request bridge.
    await page.reload();
    await expect(assistantText(page, retained)).toBeVisible();
    await expect(assistantText(page, rolledBack)).toHaveCount(0);
    const history = await visibleHistory(page);
    const frameStart = frames.length;

    await expectUndoRequestRejected(page, tid, staleAnchor, false, true);
    await expect.poll(() => frames.slice(frameStart).filter(
      (frame) => frame?.type === "error",
    ).length).toBe(1);
    expect(
      frames
        .slice(frameStart)
        .filter((frame) => frame?.type === "error")
        .map((frame) => ({ tid: frame.tid, message: frame.message })),
    ).toEqual([{ tid, message: "UUID not found in task history" }]);
    expect(
      frames.slice(frameStart).some(
        (frame) =>
          frame?.type === "undo_preview" ||
          frame?.type === "undo_result" ||
          frame?.type === "task_reload",
      ),
    ).toBe(false);
    expect(await visibleHistory(page)).toEqual(history);
    await page.reload();
    await expect(assistantText(page, retained)).toBeVisible();
    await expect(assistantText(page, rolledBack)).toHaveCount(0);
    expect(await visibleHistory(page)).toEqual(history);
    await expect(page.locator(".input-textarea:visible").first()).toBeEnabled();
    await sendMessage(page, "Reply exactly with UNDO_STALE_ALIVE");
    await expect(assistantText(page, "UNDO_STALE_ALIVE")).toBeVisible();
  },
);

test(
  "codex second live undo after an interrupted turn retains earlier history",
  { tag: "@codex-only" },
  async ({ page }) => {
    await enterSession(page);

    // The small Codex model uses the v1 interrupted-turn history marker, which
    // is persisted as a contextual role=user response item.
    await page
      .locator(".task-type-row", { hasText: "system_prompt_test" })
      .click();
    await expect(
      page.locator(".task-type-row.selected .task-type-name"),
    ).toHaveText("system_prompt_test");

    for (const marker of [
      "interrupt-undo-one",
      "interrupt-undo-two",
      "interrupt-undo-three",
    ]) {
      await sendMessage(page, `Please reply with "${marker}"`);
      await expect(assistantText(page, marker)).toBeVisible();
    }

    await openUndoDialogForUserMessage(
      page,
      'Please reply with "interrupt-undo-three"',
    );
    await expect(page.locator(".undo-dialog-count:visible")).toContainText(
      "1 whole turn will be removed.",
    );
    await page.locator(".btn-undo:visible").click();

    const activeUsers = page.locator(
      ".message.user-message:visible:not(.pending):not(.meta-message)",
    );
    await expect(activeUsers).toHaveCount(2);
    await expect(assistantText(page, "interrupt-undo-one")).toBeVisible();
    await expect(assistantText(page, "interrupt-undo-two")).toBeVisible();

    const retainedContextProbe =
      "check context contains aW50ZXJydXB0LXVuZG8tb25l";
    await sendMessage(page, retainedContextProbe);
    await expect(
      assistantText(page, "context-check-passed").last(),
    ).toBeVisible();
    await expect(activeUsers).toHaveCount(3);

    const interrupted = "stall session interrupt-undo-running";
    await sendMessage(page, interrupted);
    await expect(
      page.locator(".message.user-message:visible:not(.pending)", {
        hasText: interrupted,
      }),
    ).toBeVisible();
    await expect(page.locator(".btn-stop:visible")).toBeVisible();
    await page.locator(".btn-stop:visible").click();
    await expect(page.locator(".btn-stop:visible")).toHaveCount(0);
    await expect(activeUsers).toHaveCount(4);

    const tid = currentTaskTid(page);
    await expect
      .poll(
        () =>
          codexRolloutRecords(tid).some(
            (record) =>
              record.type === "response_item" &&
              record.payload?.type === "message" &&
              record.payload?.role === "user" &&
              (record.payload?.content ?? [])
                .map((part: any) => part?.text ?? "")
                .join("")
                .includes("<turn_aborted>"),
          ),
      )
      .toBe(true);

    await openUndoDialogForUserMessage(
      page,
      'Please reply with "interrupt-undo-two"',
    );
    // Only interrupt-undo-two, the probe, and the interrupted prompt are
    // active user turns, so the correct rollback count is three.
    const secondUndoCount = page.locator(".undo-dialog-count:visible");
    await expect(secondUndoCount).toContainText("whole turns will be removed.");
    const secondUndoPreview = await secondUndoCount.innerText();
    await page.locator(".btn-undo:visible").click();

    await expect(activeUsers).toHaveCount(1);
    await expect(
      page.locator(".message.assistant-message:visible"),
    ).toHaveCount(1);
    await expect(
      page.locator(".message.user-message:visible", {
        hasText: "interrupt-undo-one",
      }),
    ).toBeVisible();
    await expect(assistantText(page, "interrupt-undo-one")).toBeVisible();

    await sendMessage(page, retainedContextProbe);
    const contextProbe = assistantText(
      page,
      /context-check-(?:passed|failed)/,
    ).last();
    await expect(contextProbe).toBeVisible();
    expect({
      secondUndoPreview,
      retainedContext: await contextProbe.innerText(),
    }).toEqual({
      secondUndoPreview: "3 whole turns will be removed.",
      retainedContext: "context-check-passed",
    });

    await expect
      .poll(
        () =>
          codexRolloutRecords(tid)
            .filter(
              (record) =>
                record.type === "event_msg" &&
                record.payload?.type === "thread_rolled_back",
            )
            .map((record) => record.payload.num_turns),
      )
      .toEqual([1, 3]);
  },
);

test(
  "codex live undo of a duplicate prompt retires only the later client id",
  { tag: "@codex-only" },
  async ({ page }) => {
    const frames: any[] = [];
    page.on("websocket", (ws) => {
      ws.on("framereceived", (event) => {
        try {
          frames.push(JSON.parse(event.payload.toString()));
        } catch {}
      });
    });
    await enterSession(page);

    await sendMessage(page, 'Please reply with "dup-first"');
    await expect(assistantText(page, "dup-first")).toBeVisible();

    await sendMessage(page, 'Please reply with "dup-marker"');
    await expect(assistantText(page, "dup-marker")).toBeVisible();

    await sendMessage(page, 'Please reply with "dup-marker"');
    await expect(assistantText(page, "dup-marker").nth(1)).toBeVisible();

    const tid = currentTaskTid(page);
    let dupAnchors: string[] = [];
    await expect
      .poll(() => {
        dupAnchors = frames
          .filter(
            (frame) =>
              frame?.type === "task_history_boundary_replaced" &&
              frame?.tid === tid &&
              frame?.event?.type === "item/started" &&
              frame?.event?.item_type === "user_message" &&
              !frame.event?.pending &&
              !frame.event?.is_meta &&
              !frame.event?.is_synthetic &&
              !frame.event?.is_sidechain &&
              Array.isArray(frame.event?.content) &&
              frame.event.content.length === 1 &&
              frame.event.content[0]?.type === "text" &&
              frame.event.content[0]?.text ===
                'Please reply with "dup-marker"' &&
              frame.event?.history_boundary?.kind === "user",
          )
          .map((frame) => frame.event.history_boundary.anchor);
        return dupAnchors.length;
      })
      .toBe(2);
    expect(dupAnchors).toHaveLength(2);
    const [earlierAnchor, laterAnchor] = dupAnchors;
    expect(earlierAnchor).toMatch(/^line:\d+$/);
    expect(laterAnchor).toMatch(/^line:\d+$/);
    expect(earlierAnchor).not.toBe(laterAnchor);

    await openUndoDialogForUserMessage(page, 'Please reply with "dup-marker"');
    await expect(page.locator(".undo-dialog-count:visible")).toContainText(
      "1 whole turn will be removed.",
    );
    await page.locator(".btn-undo:visible").click();

    const remainingDupMarkers = page.locator(
      ".message.user-message:visible:not(.pending):not(.meta-message)",
      { hasText: "dup-marker" },
    );
    await expect(remainingDupMarkers).toHaveCount(1);
    const remainingWrapper = page
      .locator(".message-wrapper:visible", { has: remainingDupMarkers })
      .last();
    await remainingWrapper.hover();
    await expect(remainingWrapper.locator(".undo-btn")).toBeVisible();

    await expect(
      page.locator(".message.user-message:visible:not(.pending):not(.meta-message)", {
        hasText: "dup-first",
      }),
    ).toBeVisible();
    await expect(assistantText(page, "dup-first")).toBeVisible();

    // Rollout evidence for the undo itself, asserted before any further
    // message adds another client-id-bearing turn to the ledger.
    await expect
      .poll(() => {
        const clientIds = codexRolloutRecords(tid)
          .filter(
            (record) =>
              record.type === "event_msg" && record.payload?.type === "user_message",
          )
          .map((record) => record.payload?.client_id)
          .filter((clientId) => typeof clientId === "string" && clientId.length > 0);
        return { count: clientIds.length, distinct: new Set(clientIds).size };
      })
      .toEqual({ count: 2, distinct: 2 });

    await expect
      .poll(
        () =>
          codexRolloutRecords(tid)
            .filter(
              (record) =>
                record.type === "event_msg" &&
                record.payload?.type === "thread_rolled_back",
            )
            .map((record) => record.payload.num_turns),
      )
      .toEqual([1]);

    const probeMarker = Buffer.from("dup-first").toString("base64");
    await sendMessage(page, `check context contains ${probeMarker}`);
    await expect(
      assistantText(page, /context-check-(?:passed|failed)/).last(),
    ).toBeVisible();
    expect(
      await assistantText(page, /context-check-(?:passed|failed)/)
        .last()
        .innerText(),
    ).toBe("context-check-passed");
  },
);

test(
  "codex refuses native undo of a steered turn without side effects",
  { tag: "@codex-only" },
  async ({ page }) => {
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

    await enterSession(page);

    await sendMessage(page, 'Please reply with "steer-first"');
    await expect(assistantText(page, "steer-first")).toBeVisible();

    await sendMessage(page, "run command sleep 5");
    await expect(
      page.locator(".tool-call", { hasText: "sleep 5" }).first(),
    ).toBeVisible();

    await sendMessage(page, 'Also please reply with "steer-marker"');

    await expect(
      page.locator(".message.user-message:visible:not(.pending):not(.meta-message)", {
        hasText: "steer-marker",
      }),
    ).toBeVisible();
    await expect(page.locator(".btn-stop:visible")).toHaveCount(0);

    const tid = currentTaskTid(page);
    const history = await visibleHistory(page);
    // Read before/after the two refusal attempts below; this spans a
    // multi-second window, so a late-flushed record from the *preceding*
    // turn could in principle fail this check pointing at an innocent undo
    // (plan §3.3c).
    const before = codexRolloutRecords(tid).length;
    const frameStart = frames.length;

    await expectUndoRefusalForUserMessage(
      page,
      'Also please reply with "steer-marker"',
      "Native Codex undo preparation refused: completed native turn does not match the simple one-user grammar",
    );
    await expectUndoRefusalForUserMessage(
      page,
      "run command sleep 5",
      "Native Codex undo preparation refused: candidate suffix reuses a raw turn id",
    );

    await expect
      .poll(
        () =>
          frames.slice(frameStart).filter((frame) => frame?.type === "error")
            .length,
      )
      .toBe(2);
    expect(
      frames
        .slice(frameStart)
        .filter((frame) => frame?.type === "error")
        .map((frame) => ({ tid: frame.tid, message: frame.message })),
    ).toEqual([
      {
        tid,
        message:
          "Native Codex undo preparation refused: completed native turn does not match the simple one-user grammar",
      },
      {
        tid,
        message:
          "Native Codex undo preparation refused: candidate suffix reuses a raw turn id",
      },
    ]);
    expect(
      frames
        .slice(frameStart)
        .some(
          (frame) =>
            frame?.type === "undo_preview" ||
            frame?.type === "undo_result" ||
            frame?.type === "task_reload",
        ),
    ).toBe(false);

    // See the "before" comment above re: the multi-second comparison window.
    expect(await visibleHistory(page)).toEqual(history);
    expect(codexRolloutRecords(tid).length).toBe(before);

    const sleepProbe = Buffer.from("run command sleep 5").toString("base64");
    await sendMessage(page, `check context contains ${sleepProbe}`);
    await expect(
      assistantText(page, /context-check-(?:passed|failed)/).last(),
    ).toBeVisible();
    expect(
      await assistantText(page, /context-check-(?:passed|failed)/)
        .last()
        .innerText(),
    ).toBe("context-check-passed");

    const steerProbe = Buffer.from("steer-marker").toString("base64");
    await sendMessage(page, `check context contains ${steerProbe}`);
    await expect(
      assistantText(page, /context-check-(?:passed|failed)/).last(),
    ).toBeVisible();
    expect(
      await assistantText(page, /context-check-(?:passed|failed)/)
        .last()
        .innerText(),
    ).toBe("context-check-passed");

    await sendMessage(page, 'Please reply with "steer-final"');
    await expect(assistantText(page, "steer-final")).toBeVisible();
  },
);

// ---------------------------------------------------------------------------
// AC23 real-Codex undo/rollback split-CODEX_HOME regression test.
//
// Mirrors codex-fork.spec.ts's AC23 fork-lifecycle test and
// custom-claude-agent-lifecycle.spec.ts's AC21 profile-lifecycle test: a
// live task's own native rollback (Codex's thread/rollback, recorded as a
// `thread_rolled_back` marker appended to the session's own rollout JSONL —
// Codex's rollback is append-only/marker-based, never a truncation of the
// file) must land in the launch profile (B) the task actually ran under,
// even after the agent is reconfigured live to a different profile (C), and
// must never touch a same-session-ID sibling poisoned under the backend's
// own parent profile (A) or under C. Codex's native rollback requires a live
// app-server connection, so unlike AC21/AC23's cold-diagnostic checks this
// is a live-only proof (there is no cold native-rollback path to exercise).
// ---------------------------------------------------------------------------

type ProfiledCodexBackend = {
  baseURL: string;
  workDir: string;
  workerHome: string;
  configPath: string;
  backendProfileA: string;
  profileB: string;
  profileC: string;
};

const CODEX_UNDO_PROFILE_WORK_DIR = "/tmp/cydo-codex-undo-profile-lifecycle";
const CODEX_UNDO_PROFILE_BASE_URL = "http://localhost:3940";

/** Minimal CODEX_HOME: config.toml pointed at the mock API, no session state. */
function initCodexProfileDir(dir: string): void {
  mkdirSync(dir, { recursive: true });
  mkdirSync(join(dir, "shell_snapshots"), { recursive: true });
  writeFileSync(
    join(dir, "config.toml"),
    `model = "codex-mini-latest"
model_provider = "cydo-mock"
approval_policy = "never"
sandbox_mode = "danger-full-access"

[model_providers.cydo-mock]
name = "CyDo mock OpenAI"
base_url = "http://127.0.0.1:9000/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
`,
  );
}

/** Write a complete work-codex config pointed at the given CODEX_HOME. */
function writeCodexProfileConfig(
  configPath: string,
  profileRoot: string,
  displayName: string,
): void {
  writeTestConfig(
    configPath,
    `default_agent: work-codex
agents:
  work-codex:
    driver: codex
    display_name: ${displayName}
    sandbox:
      env:
        CODEX_HOME: ${profileRoot}
workspaces:
  local:
    root: /tmp/cydo-test-workspace
`,
  );
}

function spawnCodexProfiledBackend(
  workDir: string,
  workerHome: string,
  backendProfileA: string,
): ChildProcess {
  return spawn(process.env.CYDO_BIN!, [], {
    detached: true,
    cwd: workDir,
    env: {
      ...process.env,
      HOME: workerHome,
      CODEX_HOME: backendProfileA,
      XDG_DATA_HOME: `${workDir}/data`,
    },
    stdio: ["ignore", "inherit", "inherit"],
  });
}

async function waitForCodexProfiledBackend(
  baseURL: string,
  proc: ChildProcess,
  timeoutMs = 540_000,
): Promise<void> {
  const processExited = new Promise<never>((_, reject) => {
    if (proc.exitCode !== null) {
      reject(
        new Error(`Backend process already exited with code ${proc.exitCode}`),
      );
      return;
    }
    proc.on("exit", (code, signal) => {
      reject(
        new Error(
          `Backend process exited with code ${code}` +
            `${signal ? ` (signal ${signal})` : ""} before becoming ready`,
        ),
      );
    });
  });

  const polling = (async () => {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      try {
        const res = await fetch(baseURL);
        if (res.ok || res.status < 500) return;
      } catch {
        // not ready yet
      }
      await new Promise((r) => setTimeout(r, 300));
    }
    throw new Error(`Backend at ${baseURL} did not start in time`);
  })();

  await Promise.race([polling, processExited]);
}

/**
 * Local restartable backend fixture with a separate backend-parent profile
 * (A) and configured agent profile (B/C), overriding baseURL so
 * page.goto("/") targets this backend instead of fixtures.ts's fixed
 * /tmp/cydo-backend. Uses its own work dir, distinct from codex-fork.spec.ts's
 * CODEX_PROFILE_WORK_DIR, so the two specs' fixtures never collide.
 */
const codexProfileTest = base.extend<{ profileBackend: ProfiledCodexBackend }>({
  profileBackend: async ({}, use, testInfo) => {
    test.skip(testInfo.project.name !== "codex", "codex-only regression");

    const workDir = CODEX_UNDO_PROFILE_WORK_DIR;
    const workerHome = `${workDir}/home`;
    const backendProfileA = `${workDir}/profile-a`;
    const profileB = `${workDir}/profile-b`;
    const profileC = `${workDir}/profile-c`;
    const configPath = `${workerHome}/.config/cydo/config.yaml`;

    rmSync(workDir, { recursive: true, force: true });
    mkdirSync(`${workDir}/data`, { recursive: true });
    symlinkSync("/tmp/cydo-test-workspace/defs", `${workDir}/defs`);
    mkdirSync(`${workerHome}/.config/cydo`, { recursive: true });

    initCodexProfileDir(backendProfileA);
    initCodexProfileDir(profileB);
    writeCodexProfileConfig(configPath, profileB, "Profile B");

    const proc = spawnCodexProfiledBackend(
      workDir,
      workerHome,
      backendProfileA,
    );
    try {
      await waitForCodexProfiledBackend(CODEX_UNDO_PROFILE_BASE_URL, proc);
    } catch (e) {
      try {
        process.kill(-proc.pid!, "SIGTERM");
      } catch {
        // already gone
      }
      throw e;
    }

    await use({
      baseURL: CODEX_UNDO_PROFILE_BASE_URL,
      workDir,
      workerHome,
      configPath,
      backendProfileA,
      profileB,
      profileC,
    });

    await killBackend(proc);
  },
  baseURL: async ({ profileBackend }, use) => {
    await use(profileBackend.baseURL);
  },
});

function listRolloutFiles(sessionsDir: string): string[] {
  if (!existsSync(sessionsDir)) return [];
  const matches: string[] = [];
  for (const entry of readdirSync(sessionsDir, {
    recursive: true,
  }) as string[]) {
    if (!entry.endsWith(".jsonl")) continue;
    if (!basename(entry).startsWith("rollout-")) continue;
    matches.push(join(sessionsDir, entry));
  }
  return matches;
}

/** Poll root/sessions for exactly one real Codex rollout JSONL containing marker. */
async function findRolloutJsonlContaining(
  root: string,
  marker: string,
): Promise<string> {
  const sessionsDir = join(root, "sessions");
  let found: string | undefined;
  await expect
    .poll(
      () => {
        const matches: string[] = [];
        for (const full of listRolloutFiles(sessionsDir)) {
          try {
            if (readFileSync(full, "utf8").includes(marker)) matches.push(full);
          } catch {
            // file may be mid-write; retry on next poll
          }
        }
        found = matches.length === 1 ? matches[0] : undefined;
        return matches.length;
      },
    )
    .toBe(1);
  return found!;
}

function relativeRolloutPath(root: string, realFile: string): string {
  const rel = relative(root, realFile);
  expect(rel.startsWith("sessions/")).toBe(true);
  return rel;
}

function sessionIdFromRollout(path: string): string {
  const firstLine = readFileSync(path, "utf8").split("\n")[0];
  const parsed = JSON.parse(firstLine);
  expect(parsed.type).toBe("session_meta");
  expect(typeof parsed.payload?.id).toBe("string");
  return parsed.payload.id as string;
}

/** Create a valid two-line rollout at the given relative location, same session ID. */
function writeSameIdRolloutPoison(
  root: string,
  relativePath: string,
  sessionId: string,
  cwd: string,
  marker: string,
): void {
  const fullPath = join(root, relativePath);
  mkdirSync(dirname(fullPath), { recursive: true });
  const content =
    [
      JSON.stringify({
        type: "session_meta",
        payload: { id: sessionId, cwd, cli_version: "0.0.0-poison" },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "message",
          role: "user",
          content: [{ type: "input_text", text: marker }],
        },
      }),
    ].join("\n") + "\n";
  writeFileSync(fullPath, content);
}

async function openTaskByTid(
  page: Page,
  tid: string,
  timeoutMs = 540_000,
): Promise<void> {
  const row = page.locator(`.sidebar-item[data-tid="${tid}"]`);
  await expect(row).toBeVisible({ timeout: timeoutMs });
  await row.click();
  await expect(row).toHaveClass(/active/, { timeout: timeoutMs });
}

codexProfileTest(
  "codex live rollback lands in the launch profile B rollout, never in an A/C same-ID poison sibling",
  { tag: "@codex-only" },
  async ({ page, profileBackend }) => {
    const marker1 = "split-undo-one";
    const marker2 = "split-undo-two";
    const marker3 = "split-undo-three";
    const followup = "split-undo-followup";
    const cwd = "/tmp/cydo-test-workspace";
    const timeout = responseTimeout("codex");

    await enterSession(page);

    for (const marker of [marker1, marker2, marker3]) {
      await sendMessage(page, `Please reply with "${marker}"`);
      await expect(assistantText(page, marker)).toBeVisible({ timeout });
    }

    const tid = String(await activeTid(page));
    const taskUrl = page.url();

    // The task's own rollout lands under B, never A or C.
    const realRollout = await findRolloutJsonlContaining(
      profileBackend.profileB,
      marker3,
    );
    const relPath = relativeRolloutPath(profileBackend.profileB, realRollout);
    const sessionId = sessionIdFromRollout(realRollout);
    expect(readFileSync(realRollout, "utf8")).not.toContain(
      "thread_rolled_back",
    );

    // Adversarial same-session-ID poison siblings under the backend's own
    // parent profile (A) and under the root work-codex is about to be
    // reconfigured to (C): a rollback that fell back to reading or writing
    // either would surface (or be recorded against) this content instead of
    // B's own.
    writeSameIdRolloutPoison(
      profileBackend.backendProfileA,
      relPath,
      sessionId,
      cwd,
      "split-undo-a-poison-marker",
    );
    const poisonAContent = readFileSync(
      join(profileBackend.backendProfileA, relPath),
      "utf8",
    );
    initCodexProfileDir(profileBackend.profileC);
    writeSameIdRolloutPoison(
      profileBackend.profileC,
      relPath,
      sessionId,
      cwd,
      "split-undo-c-poison-marker",
    );
    const poisonCContent = readFileSync(
      join(profileBackend.profileC, relPath),
      "utf8",
    );

    // Reconfigure work-codex live, from B to C, with no backend restart —
    // the task is still alive and bound to its own already-launched B
    // process throughout. Confirm the reload actually landed via a fresh
    // draft's picker before returning to the live task, rather than a fixed
    // sleep — the exact-message assertions below have zero tolerance for a
    // race-induced wrong branch.
    writeCodexProfileConfig(
      profileBackend.configPath,
      profileBackend.profileC,
      "Profile C",
    );
    await enterSession(page);
    await expect(
      page.locator('.agent-picker option[value="work-codex"]'),
    ).toHaveText("Profile C");

    await page.goto(taskUrl);
    await openTaskByTid(page, tid);
    await expect(assistantText(page, marker3)).toBeVisible();

    await undoUserMessage(page, `Please reply with "${marker3}"`);
    await expect(assistantText(page, marker3)).toHaveCount(0);
    await expect(assistantText(page, marker2)).toBeVisible();
    await expect(assistantText(page, marker1)).toBeVisible();

    // The rollback landed in B's own rollout file as a native
    // thread_rolled_back marker (append-only — Codex's rollback never
    // truncates the file, it appends an event marker that CyDo's own replay
    // logic skips past)...
    await expect
      .poll(() => readFileSync(realRollout, "utf8"))
      .toContain("thread_rolled_back");

    // ...and never touched either poison sibling.
    expect(
      readFileSync(join(profileBackend.backendProfileA, relPath), "utf8"),
    ).toBe(poisonAContent);
    expect(
      readFileSync(join(profileBackend.profileC, relPath), "utf8"),
    ).toBe(poisonCContent);

    // Session is still alive and fully functional after the rollback, and
    // its follow-up turn lands in the very same B rollout file, not a new
    // one under B, A, or C.
    await expect(page.locator(".input-textarea:visible").first()).toBeEnabled();
    await sendMessage(page, `Please reply with "${followup}"`);
    await expect(assistantText(page, followup)).toBeVisible({ timeout });
    const followupRollout = await findRolloutJsonlContaining(
      profileBackend.profileB,
      followup,
    );
    expect(followupRollout).toBe(realRollout);
    expect(
      readFileSync(join(profileBackend.backendProfileA, relPath), "utf8"),
    ).toBe(poisonAContent);
    expect(
      readFileSync(join(profileBackend.profileC, relPath), "utf8"),
    ).toBe(poisonCContent);
  },
);
