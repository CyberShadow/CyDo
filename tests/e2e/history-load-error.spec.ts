/**
 * Tests that history-load failures render as a visible error message
 * in the task's event stream rather than crashing the WebSocket handler.
 *
 * Covers the orphan-agent scenario: a task row referencing an agent type that
 * is not registered triggers the synthesized error path added in this commit.
 *
 * Uses a per-test backend instance following the resume.spec.ts pattern so
 * the test controls its own database and can pre-seed state before startup.
 *
 * Agent-agnostic — runs only under the "claude" project to avoid redundant
 * execution.
 */
import { test as base, expect } from "@playwright/test";
import { spawn, execSync } from "child_process";
import type { ChildProcess } from "child_process";
import { cpSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { killBackend } from "./fixtures";

// ---------------------------------------------------------------------------
// Restartable backend fixture (follows resume.spec.ts)
// ---------------------------------------------------------------------------

type RestartableBackend = {
  baseURL: string;
  workDir: string;
  stop: () => Promise<void>;
  start: () => Promise<void>;
};

async function waitForBackend(
  baseURL: string,
  proc: ChildProcess,
  timeoutMs = 30_000,
): Promise<void> {
  const processExited = new Promise<never>((_, reject) => {
    if (proc.exitCode !== null) {
      reject(new Error(`Backend exited with code ${proc.exitCode}`));
      return;
    }
    proc.on("exit", (code, signal) =>
      reject(
        new Error(
          `Backend exited with ${code}${signal ? ` (signal ${signal})` : ""} before ready`,
        ),
      ),
    );
  });
  const polling = (async () => {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      try {
        const res = await fetch(baseURL);
        if (res.ok || res.status < 500) return;
      } catch {
        /* not ready yet */
      }
      await new Promise((r) => setTimeout(r, 300));
    }
    throw new Error(`Backend at ${baseURL} did not start in time`);
  })();
  await Promise.race([polling, processExited]);
}

function spawnBackend(workDir: string, workerHome: string): ChildProcess {
  return spawn(process.env.CYDO_BIN!, [], {
    detached: true,
    cwd: workDir,
    env: {
      ...process.env,
      HOME: workerHome,
      CLAUDE_CONFIG_DIR: `${workerHome}/.claude`,
      XDG_DATA_HOME: `${workDir}/data`,
    },
    stdio: ["ignore", "inherit", "inherit"],
  });
}

const test = base.extend<{ restartableBackend: RestartableBackend }>({
  restartableBackend: async ({}, use) => {
    const workDir = "/tmp/cydo-history-error";
    const workerHome = `${workDir}/home`;

    rmSync(workDir, { recursive: true, force: true });
    mkdirSync(`${workDir}/data`, { recursive: true });
    symlinkSync("/tmp/cydo-test-workspace/defs", `${workDir}/defs`);
    mkdirSync(`${workerHome}/.config/cydo`, { recursive: true });
    cpSync(
      "/tmp/playwright-home/.config/cydo/config.yaml",
      `${workerHome}/.config/cydo/config.yaml`,
    );

    const claudeConfigDir = `${workerHome}/.claude`;
    mkdirSync(claudeConfigDir, { recursive: true });
    writeFileSync(
      `${claudeConfigDir}/settings.json`,
      JSON.stringify({
        hasCompletedOnboarding: true,
        theme: "dark",
        skipDangerousModePermissionPrompt: true,
        autoUpdates: false,
      }),
    );

    const baseURL = "http://localhost:3940";
    let proc = spawnBackend(workDir, workerHome);
    try {
      await waitForBackend(baseURL, proc);
    } catch (e) {
      try {
        process.kill(-proc.pid!, "SIGTERM");
      } catch {}
      throw e;
    }

    const stop = async () => {
      await killBackend(proc);
    };
    const start = async () => {
      proc = spawnBackend(workDir, workerHome);
      await waitForBackend(baseURL, proc);
    };

    await use({ baseURL, workDir, stop, start });

    await killBackend(proc);
  },
  baseURL: async ({ restartableBackend }, use) => {
    await use(restartableBackend.baseURL);
  },
});

// ---------------------------------------------------------------------------
// Test
// ---------------------------------------------------------------------------

test(
  "orphan agent type renders error message in task stream",
  { tag: "@claude-only" },
  async ({ page, restartableBackend }, testInfo) => {

    // Stop the backend so we can safely modify the database.
    await restartableBackend.stop();

    // Insert a task row that references a non-existent agent type.
    // The non-empty agent_session_id causes ensureHistoryLoaded to attempt
    // loading history, which triggers the "Unknown agent type" throw.
    const dbPath = `${restartableBackend.workDir}/data/cydo/cydo.db`;
    execSync(
      `sqlite3 "${dbPath}" "` +
        `INSERT INTO tasks ` +
        `(workspace, project_path, agent_type, agent_session_id, status, title, task_type) ` +
        `VALUES ('local', '/tmp/cydo-test-workspace', 'nonexistent', ` +
        `'fake-session-orphan', 'completed', 'orphan-agent-task', 'blank');"`,
    );

    // Restart the backend with the pre-seeded row.
    await restartableBackend.start();

    // Navigate to the app and open the orphan task.
    await page.goto(restartableBackend.baseURL + "/");
    await expect(
      page.locator(".sidebar-item .sidebar-label", {
        hasText: "orphan-agent-task",
      }),
    ).toBeVisible({ timeout: 15_000 });
    await page
      .locator(".sidebar-item .sidebar-label", { hasText: "orphan-agent-task" })
      .click();

    // The stream must contain exactly one severity-error system message.
    const errorMsg = page.locator(".system-user-message.severity-error");
    await expect(errorMsg).toHaveCount(1, { timeout: 10_000 });

    // The body must mention the orphan agent name and say it is not configured.
    await expect(errorMsg).toContainText(/agent.*nonexistent.*is not configured/i);

    // Reload the page and verify the error survives the history replay.
    await page.reload();
    await expect(
      page.locator(".sidebar-item .sidebar-label", {
        hasText: "orphan-agent-task",
      }),
    ).toBeVisible({ timeout: 15_000 });
    await page
      .locator(".sidebar-item .sidebar-label", { hasText: "orphan-agent-task" })
      .click();
    const errorMsgAfterReload = page.locator(".system-user-message.severity-error");
    await expect(errorMsgAfterReload).toHaveCount(1, { timeout: 10_000 });
    await expect(errorMsgAfterReload).toContainText(
      /agent.*nonexistent.*is not configured/i,
    );
  },
);
