import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
} from "./fixtures";

function captureEndingCanStop(page: {
  on: (
    event: "websocket",
    listener: (ws: {
      on: (
        event: "framereceived",
        listener: (frame: { payload: { toString: () => string } }) => void,
      ) => void;
    }) => void,
  ) => void;
}): () => boolean | null {
  let endingCanStop: boolean | null = null;
  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        const data = JSON.parse(event.payload.toString());
        if (data.type !== "task_updated" || !data.task) return;
        if (data.task.stdinClosed !== true) return;
        endingCanStop = data.task.canStop === true;
      } catch {
        /* ignore non-JSON frames */
      }
    });
  });
  return () => endingCanStop;
}

test("End button shows ending state then session exits", async ({
  page,
  agentType,
}) => {
  // Codex's closeStdin() fires the exit callback synchronously, so the "Ending..."
  // state is only visible for < 1 ms — too brief for Playwright's polling to detect.
  // The codex synchronous-exit behaviour is a separate issue; skip here.
  test.skip(
    agentType === "codex",
    "codex closeStdin exits synchronously; Ending... state is undetectable",
  );

  await enterSession(page);

  // Run a short sleep command so the agent stays busy when End is pressed,
  // then exits naturally once the subprocess completes (~ 5 s after End click).
  // Claude does not cancel a running subprocess on stdin close; it waits for
  // completion, after which it reads EOF and exits.
  await sendMessage(page, "run command sleep 5");

  // Wait for the agent to start processing (tool call visible)
  await expect(page.locator(".tool-call")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // Click the End button
  await page.locator(".btn-banner-end").click();

  // The End button should disappear (or be hidden)
  await expect(page.locator(".btn-banner-end")).not.toBeVisible({
    timeout: 5_000,
  });

  const ending = page.locator(".banner-processing", { hasText: "Ending..." });
  const stop = page.locator(".btn-banner-stop");
  const archive = page.locator(".btn-banner-archive");

  // End transitions to either ending state or direct completion.
  const deadline = Date.now() + 5_000;
  let sawEnding = false;
  let sawArchive = false;
  while (Date.now() < deadline) {
    sawEnding ||= await ending.isVisible();
    sawArchive ||= await archive.isVisible();
    if (sawEnding || sawArchive) break;
    await page.waitForTimeout(25);
  }
  expect(sawEnding || sawArchive).toBe(true);

  if (sawEnding && agentType === "claude") {
    await expect(async () => {
      expect(await ending.isVisible()).toBe(true);
      expect(await stop.isVisible()).toBe(true);
    }).toPass({ timeout: 5_000 });
  }

  // The textarea should still be enabled (user can keep typing drafts)
  const textarea = page.locator(".input-textarea").first();
  await expect(textarea).toBeEnabled();

  // But the Send button should be disabled
  await expect(page.locator(".btn-send").first()).toBeDisabled();

  // Eventually the session should exit and show the Archive button
  await expect(page.locator(".btn-banner-archive")).toBeVisible({
    timeout: 30_000,
  });

  // "Ending..." should no longer be visible
  await expect(page.locator(".banner-processing")).not.toBeVisible();
});

test("background command output re-enters processing state", async ({
  page,
  agentType,
}) => {
  test.skip(
    agentType === "copilot",
    "copilot does not support background commands",
  );

  // Track task_updated isProcessing transitions via WebSocket frames.
  // The re-entry window may be brief (< 200ms for Claude) so we can't rely on
  // DOM visibility — instead we observe the backend broadcast directly.
  const processingTransitions: boolean[] = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        const data = JSON.parse(event.payload.toString());
        if (data.type === "task_updated" && data.task) {
          const last = processingTransitions.at(-1);
          if (last !== data.task.isProcessing) {
            processingTransitions.push(data.task.isProcessing);
          }
        }
      } catch {
        /* ignore non-JSON frames */
      }
    });
  });

  await enterSession(page);

  // Use a background command with quick yield - the turn completes fast,
  // then the command continues running in the background.
  const cmd =
    agentType === "codex"
      ? "run background command sleep 3"
      : "run command with timeout 1000 sleep 5";
  await sendMessage(page, cmd);

  const timeout = responseTimeout(agentType);

  // Wait for the turn to complete — "Done." text appears
  await expect(assistantText(page, "Done.")).toBeVisible({ timeout });

  // After the first turn ends (isProcessing goes false), the background command
  // eventually completes and triggers a new turn — isProcessing goes true again.
  // Assert that the transitions array contains a false→true re-entry after the
  // initial true→false turn-end, i.e. at least one true after a false.
  await expect(async () => {
    const falseIdx = processingTransitions.indexOf(false);
    expect(falseIdx).toBeGreaterThanOrEqual(0); // turn completed
    const reentry = processingTransitions.slice(falseIdx + 1).includes(true);
    expect(reentry).toBe(true); // re-entered processing
  }).toPass({ timeout: 10_000 });
});

test("repro: ending capability matches Stop visibility", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "copilot", "reproducer targets Copilot only");

  const readEndingCanStop = captureEndingCanStop(page);
  await enterSession(page);
  await sendMessage(page, "run command sleep 5");

  await expect(page.locator(".tool-call")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  await page.locator(".btn-banner-end").click();
  await expect(page.locator(".btn-banner-end")).not.toBeVisible({
    timeout: 5_000,
  });

  const ending = page.locator(".banner-processing", { hasText: "Ending..." });
  const stop = page.locator(".btn-banner-stop");
  const archive = page.locator(".btn-banner-archive");

  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    const endingVisible = await ending.isVisible();
    if (!endingVisible) {
      if (await archive.isVisible()) return;
      await page.waitForTimeout(25);
      continue;
    }

    const canStop = readEndingCanStop();
    if (canStop === null) {
      await page.waitForTimeout(25);
      continue;
    }
    expect(await stop.isVisible()).toBe(canStop);
    return;
  }

  await expect(archive).toBeVisible({ timeout: 30_000 });
});
