/**
 * Backend restart / resume tests.
 *
 * Uses a test-scoped custom fixture that manages its own CyDo backend instance
 * with a `restart()` method, independent of the worker-scoped backend fixture.
 */
import { test as base, expect } from "@playwright/test";
import { spawn, execSync } from "child_process";
import type { ChildProcess } from "child_process";
import { mkdirSync, rmSync, symlinkSync, cpSync } from "fs";

// ---------------------------------------------------------------------------
// Custom fixture
// ---------------------------------------------------------------------------

type RestartableBackend = {
  port: number;
  baseURL: string;
  workDir: string;
  restart: () => Promise<void>;
};

async function waitForBackend(baseURL: string, timeoutMs = 30_000): Promise<void> {
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
}

function spawnBackend(port: number, workDir: string, workerHome: string): ChildProcess {
  return spawn(process.env.CYDO_BIN!, [], {
    cwd: workDir,
    env: {
      ...process.env,
      HOME: workerHome,
      CYDO_LISTEN_PORT: String(port),
    },
    stdio: ["ignore", "ignore", "inherit"],
  });
}

// Per-test unique sequence number. Each test in a worker gets a different
// value so they use different ports and workDirs, preventing orphaned
// processes from one test connecting to the next test's backend.
let _testSeq = 0;

const test = base.extend<{ restartableBackend: RestartableBackend }>({
  restartableBackend: async ({}, use, testInfo) => {
    // Use ports starting at 5100. Combine worker index and per-test counter
    // so tests in different workers also get distinct ports.
    const seq = testInfo.parallelIndex * 100 + _testSeq++;
    const port = 5100 + seq;
    const workDir = `/tmp/cydo-restart-${seq}`;
    const workerHome = `${workDir}/home`;

    rmSync(workDir, { recursive: true, force: true });
    mkdirSync(`${workDir}/data`, { recursive: true });
    symlinkSync("/tmp/cydo-test-workspace/defs", `${workDir}/defs`);
    mkdirSync(`${workerHome}/.config/cydo`, { recursive: true });
    cpSync(
      "/tmp/playwright-home/.config/cydo/config.yaml",
      `${workerHome}/.config/cydo/config.yaml`,
    );

    const baseURL = `http://localhost:${port}`;
    let proc = spawnBackend(port, workDir, workerHome);
    await waitForBackend(baseURL);

    const restart = async () => {
      proc.kill("SIGTERM");
      await new Promise<void>((r) => proc.on("exit", () => r()));
      proc = spawnBackend(port, workDir, workerHome);
      await waitForBackend(baseURL);
    };

    await use({ port, baseURL, workDir, restart });

    proc.kill("SIGTERM");
    await new Promise<void>((r) => proc.on("exit", () => r()));
    rmSync(workDir, { recursive: true, force: true });
  },
  baseURL: async ({ restartableBackend }, use) => {
    await use(restartableBackend.baseURL);
  },
});

// ---------------------------------------------------------------------------
// Helper: wait for a task to appear in the sidebar
// ---------------------------------------------------------------------------

async function waitForSidebarTask(page: any, labelText: string, timeoutMs = 15_000) {
  await expect(
    page.locator(".sidebar-item .sidebar-label", { hasText: labelText }),
  ).toBeVisible({ timeout: timeoutMs });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test("idle task is not nudged after resume + restart", async ({
  page,
  restartableBackend,
}, testInfo) => {
  test.skip(testInfo.project.name === "codex", "claude-only test");
  // Create a task and let it become idle (alive)
  await page.goto("/");
  await page.locator('button[title="New task"]').first().click();
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled({ timeout: 15_000 });
  await input.fill('Please reply with "restart-alive"');
  const sendBtn = page.locator(".btn-send:visible").first();
  await expect(sendBtn).toBeEnabled({ timeout: 5_000 });
  await sendBtn.click();

  // Wait for the response — task becomes "alive" (idle)
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "restart-alive",
    }),
  ).toBeVisible({ timeout: 30_000 });

  // Exactly one assistant message before restart
  await expect(page.locator(".message.assistant-message")).toHaveCount(1);

  // --- First restart ---
  await restartableBackend.restart();
  await page.goto("/");
  await waitForSidebarTask(page, "restart-alive");
  await page.locator(".sidebar-item .sidebar-label", { hasText: "restart-alive" }).click();

  // Click the Resume button (this is where the bug was: handleResumeMsg
  // set status to "active" even though the session is idle).
  const resumeBtn = page.locator(".btn-resume");
  const isResumeVisible = await resumeBtn.isVisible({ timeout: 5_000 }).catch(() => false);
  if (isResumeVisible) {
    await resumeBtn.click();
    await expect(page.locator(".btn-banner-stop")).toBeVisible({ timeout: 15_000 });
  }

  // History preserved, still one assistant message
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "restart-alive",
    }),
  ).toBeVisible({ timeout: 10_000 });
  await expect(page.locator(".message.assistant-message")).toHaveCount(1);

  // --- Second restart ---
  // Before the fix, handleResumeMsg persisted status="active", so
  // resumeInFlightTasks would send a [SYSTEM:] nudge here.
  await restartableBackend.restart();
  await page.goto("/");
  await waitForSidebarTask(page, "restart-alive");
  await page.locator(".sidebar-item .sidebar-label", { hasText: "restart-alive" }).click();

  // Wait for history to load
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "restart-alive",
    }),
  ).toBeVisible({ timeout: 10_000 });

  // Wait to give any [SYSTEM:] nudge time to trigger a response.
  // If nudged, the mock API responds with "Done." — a second assistant message.
  await page.waitForTimeout(5_000);

  // Still exactly one assistant message — the idle task was NOT nudged
  await expect(page.locator(".message.assistant-message")).toHaveCount(1);
});

test("active task receives nudge and continues after restart", async ({
  page,
  restartableBackend,
}, testInfo) => {
  test.skip(testInfo.project.name === "codex", "claude-only test");
  // Create a task and start a long-running command (will be mid-turn when we kill)
  await page.goto("/");
  await page.locator('button[title="New task"]').first().click();
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled({ timeout: 15_000 });
  await input.fill("run command sleep 60");
  const sendBtn = page.locator(".btn-send:visible").first();
  await expect(sendBtn).toBeEnabled({ timeout: 5_000 });
  await sendBtn.click();

  // Wait until the tool call is visible (task is mid-turn / "active")
  await expect(
    page.locator(".tool-call", { hasText: "sleep 60" }),
  ).toBeVisible({ timeout: 30_000 });

  // Kill and restart the backend while task is "active"
  await restartableBackend.restart();

  // Reload the page
  await page.goto("/");

  // Task should still be in the sidebar
  await expect(page.locator(".sidebar-item")).toHaveCount(1, { timeout: 10_000 });

  // Click on the task
  await page.locator(".sidebar-item").first().click();

  // Resume if needed
  const resumeBtn = page.locator(".btn-resume");
  const isResumeVisible = await resumeBtn.isVisible({ timeout: 5_000 }).catch(() => false);
  if (isResumeVisible) {
    await resumeBtn.click();
    await expect(page.locator(".btn-banner-stop")).toBeVisible({ timeout: 15_000 });
  }

  // The nudge message and the agent's reply should appear
  // After nudge, the agent retries and eventually responds with "Done."
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "Done." }),
  ).toBeVisible({ timeout: 60_000 });
});

test("sub-task result delivered to parent after backend restart", async ({
  page,
  restartableBackend,
}, testInfo) => {
  test.skip(testInfo.project.name === "codex", "claude-only test");
  // Create a parent task that spawns a sub-task running a slow command,
  // so the sub-task is guaranteed to be in-flight when we kill the backend.
  await page.goto("/");
  await page.locator('button[title="New task"]').first().click();
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled({ timeout: 15_000 });
  await input.fill("call task research run command sleep 10");
  const sendBtn = page.locator(".btn-send:visible").first();
  await expect(sendBtn).toBeEnabled({ timeout: 5_000 });
  await sendBtn.click();

  // Wait for the sub-task's shell tool call to appear — this confirms the sub-task
  // is actively running "sleep 10" and is in-flight at kill time.
  await expect(
    page.locator(".tool-call", { hasText: "sleep 10" }),
  ).toBeVisible({ timeout: 30_000 });

  // Kill and restart the backend while the sub-task is still running
  await restartableBackend.restart();

  // Reload the page
  await page.goto("/");

  // Navigate to the parent task. The parent has the lower task ID so it appears
  // last when tasks are sorted by descending tid (WelcomePage) or in the Sidebar.
  const taskItems = page.locator(".sidebar-item:not(.sidebar-new-task)");
  await expect(taskItems.last()).toBeVisible({ timeout: 15_000 });
  await taskItems.last().click();

  // Resume if necessary
  const resumeBtn = page.locator(".btn-resume");
  const isResumeVisible = await resumeBtn.isVisible({ timeout: 5_000 }).catch(() => false);
  if (isResumeVisible) {
    await resumeBtn.click();
    await expect(page.locator(".btn-banner-stop")).toBeVisible({ timeout: 15_000 });
  }

  // The parent should eventually process the sub-task result and respond with "Done."
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "Done." }),
  ).toBeVisible({ timeout: 60_000 });
});

test("waiting parent with completed children gets results after restart", async ({
  page,
  restartableBackend,
}, testInfo) => {
  test.skip(testInfo.project.name === "codex", "claude-only test");
  // This test exercises the resumeAndDeliverResults path: parent is "waiting",
  // all children are "completed", but task_deps rows still exist.
  //
  // Strategy: create a simple task (which gets an agent_session_id), then
  // manipulate the DB to simulate the race condition: set parent to "waiting",
  // create a fake completed child, and insert a task_deps row.

  // Create a task and let it complete a turn so it has an agent_session_id.
  await page.goto("/");
  await page.locator('button[title="New task"]').first().click();
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled({ timeout: 15_000 });
  await input.fill('reply with "parent-ready"');
  const sendBtn = page.locator(".btn-send:visible").first();
  await expect(sendBtn).toBeEnabled({ timeout: 5_000 });
  await sendBtn.click();

  // Wait for the response — task is now "alive" with a valid session.
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "parent-ready",
    }),
  ).toBeVisible({ timeout: 30_000 });

  // Manipulate the DB to simulate the race condition:
  // 1. Set parent (tid=1) status to "waiting"
  // 2. Create a fake completed child task (tid=2)
  // 3. Insert task_deps row linking parent to child
  const dbPath = `${restartableBackend.workDir}/data/cydo.db`;
  execSync(
    `sqlite3 "${dbPath}" "` +
      `UPDATE tasks SET status='waiting' WHERE tid=1; ` +
      `INSERT INTO tasks (workspace, project_path, agent_type, status, description, task_type, parent_tid, relation_type) ` +
      `VALUES ('local', '/tmp/cydo-test-workspace', 'claude', 'completed', 'fake child', 'research', 1, 'subtask'); ` +
      `INSERT OR IGNORE INTO task_deps VALUES(1, 2);"`,
  );

  // Restart — the backend should find parent="waiting" with child="completed"
  // and trigger resumeAndDeliverResults.
  await restartableBackend.restart();

  // Reload and navigate to the parent task.
  await page.goto("/");
  await waitForSidebarTask(page, "parent-ready");
  await page.locator(".sidebar-item .sidebar-label", { hasText: "parent-ready" }).click();

  // The parent was "waiting" so it gets auto-resumed by resumeInFlightTasks.
  // If the UI shows a resume button (auto-resume hasn't completed yet), click it.
  const resumeBtn = page.locator(".btn-resume");
  const isResumeVisible = await resumeBtn.isVisible({ timeout: 5_000 }).catch(() => false);
  if (isResumeVisible) {
    await resumeBtn.click();
    await expect(page.locator(".btn-banner-stop")).toBeVisible({ timeout: 15_000 });
  }

  // The parent should receive the [SYSTEM: Session resumed] message with
  // task_results and respond with "Done." (mock API handles [SYSTEM: messages).
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "Done." }),
  ).toBeVisible({ timeout: 60_000 });
});
