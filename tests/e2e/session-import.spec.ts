/**
 * E2E tests for the session import feature.
 *
 * Verifies that:
 * 1. External Claude sessions are discovered and shown in the Import group on
 *    backend startup (via the startup enumerateSessions() call).
 * 2. Clicking an importable session in the welcome-page project card loads
 *    its history in the session view.
 * 3. The "Import Session" button promotes the task out of the Import group.
 * 4. The Import group disappears once all importable sessions are promoted.
 *
 * Spins up its own per-test backend instance (following discover.spec.ts
 * conventions) so the test controls its own HOME directory and JSONL files,
 * independent of the worker-scoped backend fixture.
 *
 * All tests are agent-type-agnostic and run only under the "claude" project.
 */
import { test, expect } from "@playwright/test";
import { spawn } from "child_process";
import type { ChildProcess } from "child_process";
import { mkdirSync, rmSync, symlinkSync, writeFileSync } from "fs";

// ---------------------------------------------------------------------------
// Helpers (following discover.spec.ts pattern)
// ---------------------------------------------------------------------------

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
    throw new Error(
      `Backend at ${BACKEND_URL} did not start within ${timeoutMs}ms`,
    );
  })();

  await Promise.race([polling, processExited]);
}

function spawnBackend(
  workDir: string,
  workerHome: string,
): ChildProcess {
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

async function killBackend(proc: ChildProcess): Promise<void> {
  try {
    process.kill(-proc.pid!, "SIGTERM");
  } catch {}
  await new Promise<void>((r) => proc.on("exit", () => r()));
}

function createWorkDir(suffix: string): { workDir: string; workerHome: string } {
  const workDir = `/tmp/cydo-session-import-${suffix}`;
  const workerHome = `${workDir}/home`;
  rmSync(workDir, { recursive: true, force: true });
  mkdirSync(`${workDir}/data`, { recursive: true });
  symlinkSync("/tmp/cydo-test-workspace/defs", `${workDir}/defs`);
  mkdirSync(`${workerHome}/.config/cydo`, { recursive: true });
  return { workDir, workerHome };
}

// ---------------------------------------------------------------------------
// Test: full import flow
// ---------------------------------------------------------------------------

test("Import group node in sidebar expands on click and navigates correctly", async ({
  page,
}, testInfo) => {
  test.skip(
    testInfo.project.name !== "claude",
    "agent-agnostic, runs in claude project only",
  );

  const { workDir, workerHome } = createWorkDir("sidebar");

  const projectPath = "/tmp/cydo-test-workspace";
  const mangledPath = projectPath.replace(/\//g, "-");
  const sessionId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
  const claudeProjectsDir = `${workerHome}/.claude/projects/${mangledPath}`;
  mkdirSync(claudeProjectsDir, { recursive: true });

  const jsonlContent =
    [
      JSON.stringify({
        type: "system",
        subtype: "init",
        session_id: sessionId,
        model: "claude-3-5-sonnet-20241022",
        cwd: projectPath,
      }),
      JSON.stringify({
        type: "user",
        message: { content: "sidebar import group test" },
      }),
    ].join("\n") + "\n";

  writeFileSync(`${claudeProjectsDir}/${sessionId}.jsonl`, jsonlContent);

  writeFileSync(
    `${workerHome}/.config/cydo/config.yaml`,
    ["workspaces:", "  testws:", `    root: ${projectPath}`].join("\n") + "\n",
  );

  const proc = spawnBackend(workDir, workerHome);
  try {
    await waitForBackend(proc);

    // Navigate to the project view (shows sidebar with tasks).
    await page.goto(BACKEND_URL + "/testws/cydo-test-workspace");

    // Sidebar should appear.
    await expect(page.locator(".sidebar")).toBeVisible({ timeout: 15_000 });

    // Wait for the Import group node to appear (enumerateSessions is async).
    const importGroupNode = page.locator(".sidebar-item.sidebar-archive-node", {
      hasText: /Import \(\d+\)/,
    });
    await expect(importGroupNode).toBeVisible({ timeout: 15_000 });

    // Before clicking the group, its children should NOT be visible.
    const importableEntry = page.locator(".sidebar-item .sidebar-label", {
      hasText: "sidebar import group test",
    });
    await expect(importableEntry).not.toBeVisible();

    // Click the Import group node — should navigate to /import and expand.
    await importGroupNode.click();

    // URL must contain /import (not navigate to /).
    await expect(page).toHaveURL(/\/import/, { timeout: 5_000 });

    // Group is now expanded: child importable session is visible.
    await expect(importableEntry).toBeVisible({ timeout: 5_000 });

    // Click the importable session to load its history.
    await importableEntry.click();

    // History loads.
    await expect(
      page.locator(".message.user-message", {
        hasText: "sidebar import group test",
      }),
    ).toBeVisible({ timeout: 15_000 });

    // Group remains expanded because a descendant is active.
    await expect(importableEntry).toBeVisible();

    // Click the Import group node again — must stay on /import (not navigate to /).
    await importGroupNode.click();
    await expect(page).toHaveURL(/\/import/, { timeout: 5_000 });

    // Group is still visible and expanded.
    await expect(importGroupNode).toBeVisible();
    await expect(importableEntry).toBeVisible({ timeout: 5_000 });
  } finally {
    await killBackend(proc);
    rmSync(workDir, { recursive: true, force: true });
  }
});

test("importable session appears on startup, history loads, Import Session promotes it", async ({
  page,
}, testInfo) => {
  test.skip(
    testInfo.project.name !== "claude",
    "agent-agnostic, runs in claude project only",
  );

  const { workDir, workerHome } = createWorkDir("import");

  // Use the shared test workspace path so it matches a configured workspace.
  const projectPath = "/tmp/cydo-test-workspace";
  const mangledPath = projectPath.replace(/\//g, "-");

  // Create a fake Claude session JSONL file with a recognizable user message.
  const sessionId = "11111111-2222-3333-4444-555555555555";
  const claudeProjectsDir = `${workerHome}/.claude/projects/${mangledPath}`;
  mkdirSync(claudeProjectsDir, { recursive: true });

  const jsonlContent =
    [
      JSON.stringify({
        type: "system",
        subtype: "init",
        session_id: sessionId,
        model: "claude-3-5-sonnet-20241022",
        cwd: projectPath,
      }),
      JSON.stringify({
        type: "user",
        message: { content: "hello imported session" },
      }),
    ].join("\n") + "\n";

  writeFileSync(`${claudeProjectsDir}/${sessionId}.jsonl`, jsonlContent);

  // Workspace config pointing at the test workspace.
  writeFileSync(
    `${workerHome}/.config/cydo/config.yaml`,
    ["workspaces:", "  testws:", `    root: ${projectPath}`].join("\n") + "\n",
  );

  const proc = spawnBackend(workDir, workerHome);
  try {
    await waitForBackend(proc);
    await page.goto(BACKEND_URL + "/");

    // Welcome page: project card must appear.
    await expect(
      page.locator(".project-card-title", {
        hasText: "cydo-test-workspace",
      }),
    ).toBeVisible({ timeout: 15_000 });

    // The importable session should appear in the project card task list.
    // enumerateSessions() runs asynchronously in a background thread, so
    // we wait for the session title to appear.
    const importableLabel = page.locator(
      ".project-card-sessions .sidebar-item .sidebar-label",
      { hasText: "hello imported session" },
    );
    await expect(importableLabel).toBeVisible({ timeout: 15_000 });

    // Click the importable session to navigate to it.  This triggers
    // setActiveTaskId(String(tid)) which routes to /:ws/:proj/task/:tid.
    await importableLabel.click();

    // Session view with sidebar should now be visible.
    await expect(page.locator(".sidebar")).toBeVisible({ timeout: 10_000 });

    // The Import group must be visible and expanded (the active task is a
    // descendant, so flattenTree renders the group's children).
    await expect(
      page.locator(".sidebar-item.sidebar-archive-node", {
        hasText: /Import \(1\)/,
      }),
    ).toBeVisible({ timeout: 10_000 });

    // The importable session entry is visible inside the expanded group.
    await expect(
      page.locator(".sidebar-item .sidebar-label", {
        hasText: "hello imported session",
      }),
    ).toBeVisible({ timeout: 5_000 });

    // History loads: the user message from the JSONL file is rendered.
    await expect(
      page.locator(".message.user-message", {
        hasText: "hello imported session",
      }),
    ).toBeVisible({ timeout: 15_000 });

    // The "Import Session" button is shown for importable tasks.
    const importBtn = page.locator(".btn-resume", {
      hasText: "Import Session",
    });
    await expect(importBtn).toBeVisible({ timeout: 5_000 });

    // Click "Import Session" to promote the task to a regular session.
    await importBtn.click();

    // After promotion the "Import Session" button disappears.
    await expect(importBtn).not.toBeVisible({ timeout: 10_000 });

    // The Import group disappears because there are no more importable sessions.
    await expect(
      page.locator(".sidebar-item.sidebar-archive-node", {
        hasText: /Import/,
      }),
    ).not.toBeVisible({ timeout: 10_000 });

    // The promoted session is now a regular resumable task in the sidebar.
    await expect(
      page.locator(".btn-banner-resume"),
    ).toBeVisible({ timeout: 5_000 });
  } finally {
    await killBackend(proc);
    rmSync(workDir, { recursive: true, force: true });
  }
});
