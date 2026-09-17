/**
 * Claude tracks a mutable session working directory — a `cd` in a Bash tool
 * call moves it — and re-announces it in a fresh `system/init` event on a
 * later turn of the *same* process. CyDo binds a live session to its history
 * file from that init CWD, but Claude never moves the transcript: it stays in
 * the project directory the session was created in.
 *
 * So the second init names a directory holding no transcript. CyDo used to
 * conclude the session had moved and throw, out of the agent's stdout line
 * handler and into the socket event loop, ending the backend process and
 * every other task with it.
 *
 * The first test is that sequence. The second covers the other way the two
 * can disagree — a resumed process whose own CWD is not where the session was
 * created — which does not depend on Claude's re-announcement behaviour.
 */
import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
  assistantText,
  responseTimeout,
  currentTaskTid,
  historyPathForTask,
  readHistoryFile,
} from "./fixtures";
import { mkdirSync, renameSync, symlinkSync, writeFileSync } from "fs";

const WORKSPACE = "/tmp/cydo-test-workspace";
const MOVED = "/tmp/cydo-test-workspace-moved";
const SUBDIR_NAME = "cwd-drift-subdir";

test(
  "session survives the agent moving its own working directory",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    mkdirSync(`${WORKSPACE}/${SUBDIR_NAME}`, { recursive: true });
    writeFileSync(
      `${WORKSPACE}/${SUBDIR_NAME}/marker.txt`,
      "cwd-drift-marker\n",
    );

    await enterSession(page);

    // Turn one: the agent cd's into a subdirectory, which moves the session's
    // working directory for good.
    await sendMessage(page, `run command cd ${SUBDIR_NAME} && cat marker.txt`);
    await expect(
      page.locator(".tool-result", { hasText: "cwd-drift-marker" }),
    ).toBeVisible({ timeout: responseTimeout(agentType) });

    const tid = currentTaskTid(page);
    const historyPath = historyPathForTask(tid);

    // Precondition: the move is real and recorded. If a future Claude stops
    // moving the session CWD on `cd`, this test no longer covers what it
    // claims to and must fail here rather than pass vacuously.
    await expect
      .poll(
        () =>
          readHistoryFile(historyPath).includes(
            `"cwd":"${WORKSPACE}/${SUBDIR_NAME}"`,
          ),
        { timeout: responseTimeout(agentType) },
      )
      .toBe(true);

    // Turn two on the same process: Claude re-announces the moved CWD in a
    // second init event, and CyDo must not read that as a moved transcript.
    await sendMessage(page, 'reply with "cwd-drift-after"');
    await expect(assistantText(page, "cwd-drift-after")).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    await expect(
      page.locator(".diagnostic-message.diagnostic-error"),
    ).toHaveCount(0);

    await expectHistoryStillBound(
      page,
      agentType,
      historyPath,
      "cwd-drift-after",
    );
  },
);

test(
  "session survives resuming into a moved project directory",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    await enterSession(page);

    await sendMessage(page, 'reply with "cwd-move-before"');
    await expect(assistantText(page, "cwd-move-before")).toBeVisible({
      timeout: responseTimeout(agentType),
    });

    const tid = currentTaskTid(page);
    const historyPath = historyPathForTask(tid);
    await expect
      .poll(() => readHistoryFile(historyPath).includes("cwd-move-before"), {
        timeout: responseTimeout(agentType),
      })
      .toBe(true);

    await killSession(page, agentType);

    // The project moves on disk; the path CyDo recorded still reaches it, but
    // the agent process now resolves that path to a different spelling.
    renameSync(WORKSPACE, MOVED);
    symlinkSync(MOVED, WORKSPACE);

    await page.locator(".btn-banner-resume").click();
    await expect(page.locator(".btn-banner-stop")).toBeVisible();

    await sendMessage(page, 'reply with "cwd-move-after"');
    await expect(assistantText(page, "cwd-move-after")).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    await expect(
      page.locator(".diagnostic-message.diagnostic-error"),
    ).toHaveCount(0);

    await expectHistoryStillBound(
      page,
      agentType,
      historyPath,
      "cwd-move-after",
    );
  },
);

/**
 * The turn landed in the transcript Claude already had, and CyDo is still
 * bound to that file: undo reads and rewrites the file it believes the
 * session owns, so it only works end to end while the binding is right.
 */
async function expectHistoryStillBound(
  page: Parameters<typeof enterSession>[0],
  agentType: Parameters<typeof responseTimeout>[0],
  historyPath: string,
  marker: string,
): Promise<void> {
  await expect
    .poll(() => readHistoryFile(historyPath).includes(marker), {
      timeout: responseTimeout(agentType),
    })
    .toBe(true);

  await killSession(page, agentType);
  const userMsg = page
    .locator(".message-wrapper", {
      has: page.locator(".user-message", { hasText: marker }),
    })
    .last();
  await userMsg.hover();
  await expect(userMsg.locator(".undo-btn")).toBeVisible();
  await userMsg.locator(".undo-btn").click();
  await expect(page.locator(".undo-dialog")).toBeVisible();
  await page.locator(".btn-undo").click();

  await expect(assistantText(page, marker)).toHaveCount(0);
  await expect
    .poll(() => readHistoryFile(historyPath).includes(marker), {
      timeout: responseTimeout(agentType),
    })
    .toBe(false);
}
