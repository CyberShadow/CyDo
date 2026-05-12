import { test as base, expect } from "@playwright/test";
import type { Page } from "@playwright/test";
import { spawn } from "child_process";
import type { ChildProcess, SpawnOptions } from "child_process";
import { existsSync, mkdirSync, rmSync, symlinkSync } from "fs";
import { sendMessage, responseTimeout } from "./fixtures";

const BACKEND_URL = "http://localhost:3940";

async function waitForBackend(
  proc: ChildProcess,
  timeoutMs = 30_000,
): Promise<void> {
  const processExited = new Promise<never>((_, reject) => {
    if (proc.exitCode !== null) {
      reject(new Error(`Backend already exited with code ${proc.exitCode}`));
      return;
    }
    proc.on("exit", (code, signal) =>
      reject(
        new Error(
          `Backend exited with ${code}${signal ? ` (signal ${signal})` : ""} before becoming ready`,
        ),
      ),
    );
  });

  const polling = (async () => {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      try {
        const res = await fetch(BACKEND_URL);
        if (res.ok || res.status < 500) return;
      } catch {
        /* not ready yet */
      }
      await new Promise((r) => setTimeout(r, 300));
    }
    throw new Error(`Backend at ${BACKEND_URL} did not start within ${timeoutMs}ms`);
  })();

  await Promise.race([polling, processExited]);
}

function spawnBackend(workDir: string): ChildProcess {
  const opts: SpawnOptions = {
    detached: true,
    cwd: workDir,
    env: {
      ...process.env,
      XDG_DATA_HOME: `${workDir}/data`,
    },
    stdio: ["ignore", "inherit", "inherit"],
  };
  return spawn(process.env.CYDO_BIN!, [], opts);
}

async function killBackend(proc: ChildProcess): Promise<void> {
  try {
    process.kill(-proc.pid!, "SIGTERM");
  } catch {
    /* already gone */
  }
  await new Promise<void>((resolve) => proc.on("exit", () => resolve()));
}

async function openNewTask(page: Page): Promise<void> {
  await page.goto(`${BACKEND_URL}/`);
  await page.locator('button[title="New task"]').first().click();
  await expect(page.locator(".input-textarea:visible").first()).toBeEnabled({
    timeout: 15_000,
  });
}

async function createSpikeAndWaitForComplete(
  page: Page,
  taskCreatedEvents: Array<{ tid: number; relation_type?: string }>,
  taskUpdatedEvents: Array<{ tid: number; alive: boolean }>,
): Promise<number> {
  const priorSubtaskCount = taskCreatedEvents.filter(
    (e) => e.relation_type === "subtask",
  ).length;

  await openNewTask(page);
  await sendMessage(page, "call task spike worktree-archive-test");

  await expect(async () => {
    const subtasks = taskCreatedEvents.filter((e) => e.relation_type === "subtask");
    expect(subtasks.length).toBeGreaterThan(priorSubtaskCount);
  }).toPass({ timeout: 60_000 });

  const subtasks = taskCreatedEvents.filter((e) => e.relation_type === "subtask");
  const spikeTid = subtasks[subtasks.length - 1]!.tid;

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

  await page.waitForURL((url) => !url.pathname.endsWith(`/task/${spikeTid}`), {
    timeout: 10_000,
  });

  return spikeTid;
}

const test = base;

test(
  "archive targets correct task after restart with persisted queues",
  { tag: "@claude-only" },
  async ({ page }) => {
    const workDir = "/tmp/cydo-backend-worktree-archive-persisted-queue";
    rmSync(workDir, { recursive: true, force: true });
    mkdirSync(`${workDir}/data`, { recursive: true });
    symlinkSync("/tmp/cydo-test-workspace/defs", `${workDir}/defs`);

    const taskCreatedEvents: Array<{ tid: number; relation_type?: string }> = [];
    const taskUpdatedEvents: Array<{ tid: number; alive: boolean }> = [];

    let proc = spawnBackend(workDir);
    try {
      await waitForBackend(proc);
      await page.goto(`${BACKEND_URL}/`);

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

      const spikeTidA = await createSpikeAndWaitForComplete(
        page,
        taskCreatedEvents,
        taskUpdatedEvents,
      );
      const spikeTidB = await createSpikeAndWaitForComplete(
        page,
        taskCreatedEvents,
        taskUpdatedEvents,
      );

      const wtDirA = `/tmp/cydo-test-workspace/.cydo/tasks/${spikeTidA}/worktree`;
      const wtDirB = `/tmp/cydo-test-workspace/.cydo/tasks/${spikeTidB}/worktree`;
      expect(existsSync(wtDirA)).toBe(true);
      expect(existsSync(wtDirB)).toBe(true);

      await killBackend(proc);
      proc = spawnBackend(workDir);
      await waitForBackend(proc);

      await expect(async () => {
        await page.goto(`${BACKEND_URL}/task/${spikeTidA}`);
        await expect(page.locator(".btn-banner-archive:visible")).toHaveText(
          "Archive",
          { timeout: 3_000 },
        );
      }).toPass({ timeout: 30_000 });

      await page.locator(".btn-banner-archive:visible").click();
      await expect(page.locator(".btn-banner-archive:visible")).toHaveText(
        "Unarchive",
        { timeout: responseTimeout("claude") },
      );

      expect(existsSync(wtDirA)).toBe(false);
      expect(existsSync(wtDirB)).toBe(true);
    } finally {
      if (proc.exitCode === null) await killBackend(proc);
      rmSync(workDir, { recursive: true, force: true });
    }
  },
);
