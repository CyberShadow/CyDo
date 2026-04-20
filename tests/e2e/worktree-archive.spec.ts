import { existsSync } from "fs";
import { execSync } from "child_process";
import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  killSession,
} from "./fixtures";
import type { Page, AgentType } from "./fixtures";

test("archive and unarchive a spike task's worktree", async ({
  page,
  agentType,
  backend,
}) => {
  test.skip(agentType === "codex", "codex does not use git worktrees");

  const taskCreatedEvents: Array<{ tid: number; relation_type: string }> = [];
  const taskUpdatedEvents: Array<{ tid: number; alive: boolean }> = [];

  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        const data = JSON.parse(event.payload.toString());
        if (data.type === "task_created") {
          taskCreatedEvents.push({
            tid: data.tid,
            relation_type: data.relation_type,
          });
        } else if (data.type === "task_updated") {
          taskUpdatedEvents.push({
            tid: data.task.tid,
            alive: data.task.alive,
          });
        }
      } catch {
        /* ignore non-JSON frames */
      }
    });
  });

  // 1. Enter a conversation session and create a spike subtask.
  await enterSession(page);
  await sendMessage(page, "call task spike worktree-archive-test");

  // 2. Wait for spike to be created.
  await expect(async () => {
    const spike = taskCreatedEvents.find((e) => e.relation_type === "subtask");
    expect(spike).toBeTruthy();
  }).toPass({ timeout: 60_000 });
  const spikeTid = taskCreatedEvents.find(
    (e) => e.relation_type === "subtask",
  )!.tid;

  // 3. Wait for spike to complete (alive: true → alive: false).
  await expect(async () => {
    const spikeEvents = taskUpdatedEvents.filter((e) => e.tid === spikeTid);
    let seenAlive = false;
    let completed = false;
    for (const e of spikeEvents) {
      if (e.alive) seenAlive = true;
      else if (seenAlive) {
        completed = true;
        break;
      }
    }
    expect(completed).toBeTruthy();
  }).toPass({ timeout: 60_000 });

  // 4. Wait for auto-navigation away from the spike (process/exit handler fires).
  await page.waitForURL((url) => !url.pathname.endsWith(`/task/${spikeTid}`), {
    timeout: 10_000,
  });

  // 5. Navigate to the spike task and wait for the Archive button (task is inactive).
  await expect(async () => {
    await page.locator(`.sidebar-item[data-tid="${spikeTid}"]`).click();
    await expect(
      page.locator(`.sidebar-item[data-tid="${spikeTid}"].active`),
    ).toBeVisible({ timeout: 3_000 });
    await expect(page.locator(".btn-banner-archive")).toBeVisible({
      timeout: 3_000,
    });
    await expect(page.locator(".btn-banner-archive")).toHaveText("Archive", {
      timeout: 1_000,
    });
  }).toPass({ timeout: 30_000 });

  // Verify worktree directory exists before archiving.
  const wtDir = `${backend.wsDir}/.cydo/tasks/${spikeTid}/worktree`;
  expect(existsSync(wtDir)).toBe(true);

  // 6. Archive the spike task.
  await page.locator(".btn-banner-archive").click();
  await expect(page.locator(".btn-banner-archive")).toHaveText("Unarchive", {
    timeout: responseTimeout(agentType),
  });

  // Verify worktree directory is removed and archive ref exists.
  expect(existsSync(wtDir)).toBe(false);
  let archiveRefExists = false;
  try {
    execSync(
      `git -C ${backend.wsDir} rev-parse refs/cydo/worktree-archive/${spikeTid}`,
      { stdio: "ignore" },
    );
    archiveRefExists = true;
  } catch {
    /* ref does not exist */
  }
  expect(archiveRefExists).toBe(true);

  // 7. Unarchive the spike task.
  await page.locator(".btn-banner-archive").click();
  await expect(page.locator(".btn-banner-archive")).toHaveText("Archive", {
    timeout: responseTimeout(agentType),
  });

  // Verify worktree directory is restored.
  expect(existsSync(wtDir)).toBe(true);
});

test("cannot archive parent with alive descendant", async ({
  page,
  agentType,
}) => {
  test.skip(agentType === "codex", "codex does not use git worktrees");

  const taskCreatedEvents: Array<{ tid: number; relation_type: string }> = [];
  const taskUpdatedEvents: Array<{
    tid: number;
    alive: boolean;
    archived: boolean;
  }> = [];

  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        const data = JSON.parse(event.payload.toString());
        if (data.type === "task_created") {
          taskCreatedEvents.push({
            tid: data.tid,
            relation_type: data.relation_type,
          });
        } else if (data.type === "task_updated") {
          taskUpdatedEvents.push({
            tid: data.task.tid,
            alive: data.task.alive,
            archived: data.task.archived,
          });
        }
      } catch {
        /* ignore non-JSON frames */
      }
    });
  });

  // 1. Enter a conversation session and create a spike that stalls.
  await enterSession(page);
  await sendMessage(page, "call task spike stall session");

  // 2. Wait for the conversation task_created event (first event).
  await expect(async () => {
    expect(taskCreatedEvents.length).toBeGreaterThan(0);
  }).toPass({ timeout: 30_000 });
  const convTid = taskCreatedEvents[0].tid;

  // 3. Wait for spike to be created and alive.
  await expect(async () => {
    const spike = taskCreatedEvents.find((e) => e.relation_type === "subtask");
    expect(spike).toBeTruthy();
  }).toPass({ timeout: 60_000 });
  const spikeTid = taskCreatedEvents.find(
    (e) => e.relation_type === "subtask",
  )!.tid;

  await expect(async () => {
    const aliveEvent = taskUpdatedEvents.find(
      (e) => e.tid === spikeTid && e.alive,
    );
    expect(aliveEvent).toBeTruthy();
  }).toPass({ timeout: 30_000 });

  // 4. Navigate to the parent conversation task (which is alive, waiting for
  //    the stalling spike's MCP result).
  await expect(async () => {
    await page.locator(`.sidebar-item[data-tid="${convTid}"]`).click();
    await expect(
      page.locator(`.sidebar-item[data-tid="${convTid}"].active`),
    ).toBeVisible({ timeout: 3_000 });
  }).toPass({ timeout: 15_000 });

  // 5. Attempt to archive via keyboard shortcut while the subtree is alive.
  //    Ctrl+Shift+A calls setArchived regardless of the task's own alive state,
  //    so this exercises the subtree check in handleSetArchivedMsg.
  const dialogPromise = page.waitForEvent("dialog");
  await page.keyboard.press("Control+Shift+A");
  const dialog = await dialogPromise;
  expect(dialog.message()).toMatch(/Cannot archive/i);
  await dialog.dismiss();

  // 6. Verify the parent was NOT archived (most recent task_updated for convTid
  //    should not have archived=true).
  const convEvents = taskUpdatedEvents.filter((e) => e.tid === convTid);
  const lastConvEvent = convEvents[convEvents.length - 1];
  if (lastConvEvent) {
    expect(lastConvEvent.archived).toBe(false);
  }
});

test("archiving parent task archives spike's worktree", async ({
  page,
  agentType,
  backend,
}) => {
  test.skip(agentType === "codex", "codex does not use git worktrees");

  const taskCreatedEvents: Array<{ tid: number; relation_type: string }> = [];
  const taskUpdatedEvents: Array<{ tid: number; alive: boolean }> = [];

  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        const data = JSON.parse(event.payload.toString());
        if (data.type === "task_created") {
          taskCreatedEvents.push({
            tid: data.tid,
            relation_type: data.relation_type,
          });
        } else if (data.type === "task_updated") {
          taskUpdatedEvents.push({
            tid: data.task.tid,
            alive: data.task.alive,
          });
        }
      } catch {
        /* ignore non-JSON frames */
      }
    });
  });

  // 1. Enter a conversation session and create a spike subtask.
  await enterSession(page);
  await sendMessage(page, "call task spike worktree-archive-test");

  // 2. Wait for the conversation task_created event (first event).
  await expect(async () => {
    expect(taskCreatedEvents.length).toBeGreaterThan(0);
  }).toPass({ timeout: 30_000 });
  const convTid = taskCreatedEvents[0].tid;

  // 3. Wait for spike to be created.
  await expect(async () => {
    const spike = taskCreatedEvents.find((e) => e.relation_type === "subtask");
    expect(spike).toBeTruthy();
  }).toPass({ timeout: 60_000 });
  const spikeTid = taskCreatedEvents.find(
    (e) => e.relation_type === "subtask",
  )!.tid;

  // 4. Wait for spike to complete (alive: true → alive: false).
  await expect(async () => {
    const spikeEvents = taskUpdatedEvents.filter((e) => e.tid === spikeTid);
    let seenAlive = false;
    let completed = false;
    for (const e of spikeEvents) {
      if (e.alive) seenAlive = true;
      else if (seenAlive) {
        completed = true;
        break;
      }
    }
    expect(completed).toBeTruthy();
  }).toPass({ timeout: 60_000 });

  // 5. Wait for auto-navigation away from the spike.
  await page.waitForURL((url) => !url.pathname.endsWith(`/task/${spikeTid}`), {
    timeout: 10_000,
  });

  // 6. Navigate to the parent conversation task.
  await expect(async () => {
    await page.locator(`.sidebar-item[data-tid="${convTid}"]`).click();
    await expect(
      page.locator(`.sidebar-item[data-tid="${convTid}"].active`),
    ).toBeVisible({ timeout: 3_000 });
  }).toPass({ timeout: 15_000 });

  // 7. Stop if still alive, then wait for Archive button.
  try {
    await expect(page.locator(".btn-banner-stop")).toBeVisible({
      timeout: 5_000,
    });
    await page.locator(".btn-banner-stop").click();
  } catch {
    // Task already inactive — no stop button
  }
  await expect(page.locator(".btn-banner-archive:visible")).toHaveText(
    "Archive",
    { timeout: responseTimeout(agentType) },
  );

  // Verify spike's worktree exists before archiving parent.
  const wtDir = `${backend.wsDir}/.cydo/tasks/${spikeTid}/worktree`;
  expect(existsSync(wtDir)).toBe(true);

  // 8. Archive the parent conversation task.
  await page.locator(".btn-banner-archive:visible").click();
  await expect(page.locator(".btn-banner-archive:visible")).toHaveText(
    "Unarchive",
    { timeout: responseTimeout(agentType) },
  );

  // Spike's worktree should be removed (parent cascade archived it).
  expect(existsSync(wtDir)).toBe(false);

  // 9. Unarchive the parent conversation task.
  await page.locator(".btn-banner-archive:visible").click();
  await expect(page.locator(".btn-banner-archive:visible")).toHaveText(
    "Archive",
    { timeout: responseTimeout(agentType) },
  );

  // Spike's worktree should be restored.
  expect(existsSync(wtDir)).toBe(true);
});
