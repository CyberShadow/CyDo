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
import { execFileSync, spawn } from "child_process";
import type { ChildProcess } from "child_process";
import { mkdirSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { writeTestConfig } from "./test-config";

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

test(
  "a new real Claude session becomes importable after rescan",
  { tag: "@claude-only" },
  async ({ page }) => {
    const { workDir, workerHome } = createWorkDir("live-real-claude");
    const projectPath = "/tmp/cydo-test-workspace";
    const profileRoot = `${workerHome}/.claude`;
    const projectsDir = `${profileRoot}/projects/${projectPath.replace(/\//g, "-")}`;
    mkdirSync(profileRoot, { recursive: true });
    writeFileSync(
      `${profileRoot}/settings.json`,
      JSON.stringify({
        hasCompletedOnboarding: true,
        theme: "dark",
        skipDangerousModePermissionPrompt: true,
        autoUpdates: false,
      }),
    );
    writeTestConfig(
      `${workerHome}/.config/cydo/config.yaml`,
      ["workspaces:", "  testws:", `    root: ${projectPath}`].join("\n") + "\n",
    );

    function createClaudeSession(marker: string): void {
      execFileSync(
        "claude",
        ["-p", `${marker}: reply with OK`, "--output-format", "json", "--dangerously-skip-permissions"],
        {
          cwd: projectPath,
          env: { ...process.env, HOME: workerHome, CLAUDE_CONFIG_DIR: profileRoot },
          timeout: 120_000,
        },
      );
      const histories = readdirSync(projectsDir).filter((name) => name.endsWith(".jsonl"));
      expect(
        histories.some((name) => readFileSync(`${projectsDir}/${name}`, "utf8").includes(marker)),
        `Claude must write a session JSONL containing ${marker}`,
      ).toBe(true);
    }

    const existingMarker = "claude-before-cydo-starts";
    const newMarker = "claude-after-cydo-starts";
    createClaudeSession(existingMarker);

    const proc = spawnBackend(workDir, workerHome);
    try {
      await waitForBackend(proc);
      await page.goto(BACKEND_URL + "/testws/cydo-test-workspace");
      const sidebar = page.locator(".sidebar");
      const importGroup = sidebar.locator(".sidebar-item.sidebar-archive-node", {
        hasText: /Import \(\d+\)/,
      });
      const sessionLabel = (marker: string) =>
        sidebar.locator(".sidebar-item .sidebar-label", {
          hasText: marker,
        });

      await expect(importGroup).toHaveText("Import (1)");
      await importGroup.click();
      await expect(page).toHaveURL(/\/import/);
      await expect(sessionLabel(existingMarker)).toBeVisible();

      createClaudeSession(newMarker);

      await expect(sessionLabel(newMarker)).not.toBeVisible();
      await page.getByRole("button", { name: "Rescan for importable sessions" }).click();
      await expect(sessionLabel(newMarker)).toBeVisible({ timeout: 20_000 });
      await expect(importGroup).toHaveText("Import (2)");
    } finally {
      await killBackend(proc);
      rmSync(workDir, { recursive: true, force: true });
    }
  },
);

// ---------------------------------------------------------------------------
// Test: full import flow
// ---------------------------------------------------------------------------

test("Import group node in sidebar expands on click and navigates correctly", { tag: "@claude-only" }, async ({
  page,
}, testInfo) => {

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

  writeTestConfig(
    `${workerHome}/.config/cydo/config.yaml`,
    ["workspaces:", "  testws:", `    root: ${projectPath}`].join("\n") + "\n",
  );

  const proc = spawnBackend(workDir, workerHome);
  try {
    await waitForBackend(proc);

    // Navigate to the project view (shows sidebar with tasks).
    await page.goto(BACKEND_URL + "/testws/cydo-test-workspace");

    // Sidebar should appear.
    await expect(page.locator(".sidebar")).toBeVisible();

    // Wait for the Import group node to appear (enumerateSessions is async).
    const importGroupNode = page.locator(".sidebar-item.sidebar-archive-node", {
      hasText: /Import \(\d+\)/,
    });
    await expect(importGroupNode).toBeVisible();

    // Before clicking the group, its children should NOT be visible.
    const importableEntry = page.locator(".sidebar-item .sidebar-label", {
      hasText: "sidebar import group test",
    });
    await expect(importableEntry).not.toBeVisible();

    // Click the Import group node — should navigate to /import and expand.
    await importGroupNode.click();

    // URL must contain /import (not navigate to /).
    await expect(page).toHaveURL(/\/import/);

    // Group is now expanded: child importable session is visible.
    await expect(importableEntry).toBeVisible();

    // Click the importable session to load its history.
    await importableEntry.click();

    // An unresolvable imported task keeps the honest, unscoped task URL.
    await expect
      .poll(() => new URL(page.url()).pathname)
      .toMatch(/^\/task\/\d+$/);

    // History loads.
    await expect(
      page.locator(".message.user-message", {
        hasText: "sidebar import group test",
      }),
    ).toBeVisible();

    // Group remains expanded because a descendant is active.
    await expect(importableEntry).toBeVisible();

    // Click the Import group node again — must stay on /import (not navigate to /).
    await importGroupNode.click();
    await expect(page).toHaveURL(/\/import/);

    // Group is still visible and expanded.
    await expect(importGroupNode).toBeVisible();
    await expect(importableEntry).toBeVisible();
  } finally {
    await killBackend(proc);
    rmSync(workDir, { recursive: true, force: true });
  }
});

test("importable session appears on startup, history loads, Import Session promotes it", { tag: "@claude-only" }, async ({
  page,
}, testInfo) => {

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
  writeTestConfig(
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
    ).toBeVisible();

    // The importable session should appear in the project card task list.
    // enumerateSessions() runs asynchronously in a background thread, so
    // we wait for the session title to appear.
    const importableLabel = page.locator(
      ".project-card-sessions .sidebar-item .sidebar-label",
      { hasText: "hello imported session" },
    );
    await expect(importableLabel).toBeVisible();

    // Click the importable session to navigate to its unscoped task URL.
    await importableLabel.click();

    // Session view with sidebar should now be visible.
    await expect(page.locator(".sidebar")).toBeVisible();

    // The Import group must be visible and expanded (the active task is a
    // descendant, so flattenTree renders the group's children).
    await expect(
      page.locator(".sidebar-item.sidebar-archive-node", {
        hasText: /Import \(1\)/,
      }),
    ).toBeVisible();

    // The importable session entry is visible inside the expanded group.
    await expect(
      page.locator(".sidebar-item .sidebar-label", {
        hasText: "hello imported session",
      }),
    ).toBeVisible();

    // History loads: the user message from the JSONL file is rendered.
    await expect(
      page.locator(".message.user-message", {
        hasText: "hello imported session",
      }),
    ).toBeVisible();

    // The "Import Session" button is shown for importable tasks.
    const importBtn = page.locator(".btn-resume", {
      hasText: "Import Session",
    });
    await expect(importBtn).toBeVisible();

    // Click "Import Session" to promote the task to a regular session.
    await importBtn.click();

    // After promotion the "Import Session" button disappears.
    await expect(importBtn).not.toBeVisible();

    // The Import group disappears because there are no more importable sessions.
    await expect(
      page.locator(".sidebar-item.sidebar-archive-node", {
        hasText: /Import/,
      }),
    ).not.toBeVisible();

    // The promoted session is now a regular resumable task in the sidebar.
    await expect(
      page.locator(".btn-banner-resume"),
    ).toBeVisible();
  } finally {
    await killBackend(proc);
    rmSync(workDir, { recursive: true, force: true });
  }
});

test("import replay drops durable session/status rows but keeps compact boundary", { tag: "@claude-only" }, async ({
  page,
}, testInfo) => {

  const { workDir, workerHome } = createWorkDir("status-replay");
  const projectPath = "/tmp/cydo-test-workspace";
  const mangledPath = projectPath.replace(/\//g, "-");
  const sessionId = "66666666-7777-8888-9999-aaaaaaaaaaaa";
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
        permissionMode: "init-perm",
      }),
      JSON.stringify({
        type: "system",
        subtype: "status",
        status: "compacting",
        permissionMode: "acceptEdits",
      }),
      JSON.stringify({
        type: "system",
        subtype: "status",
        status: "requesting",
      }),
      JSON.stringify({
        type: "system",
        subtype: "status",
        status: "future-status",
      }),
      JSON.stringify({
        type: "system",
        subtype: "status",
        status: null,
        permissionMode: "acceptEdits",
      }),
      JSON.stringify({
        type: "system",
        subtype: "compact_boundary",
        compact_metadata: { trigger: "auto", pre_tokens: 321 },
      }),
      JSON.stringify({
        type: "user",
        message: { content: "import replay status fixture" },
      }),
    ].join("\n") + "\n";

  writeFileSync(`${claudeProjectsDir}/${sessionId}.jsonl`, jsonlContent);

  writeTestConfig(
    `${workerHome}/.config/cydo/config.yaml`,
    ["workspaces:", "  testws:", `    root: ${projectPath}`].join("\n") + "\n",
  );

  const proc = spawnBackend(workDir, workerHome);
  try {
    await waitForBackend(proc);
    await page.goto(BACKEND_URL + "/");

    const importableLabel = page.locator(
      ".project-card-sessions .sidebar-item .sidebar-label",
      { hasText: "import replay status fixture" },
    );
    await expect(importableLabel).toBeVisible();
    await importableLabel.click();

    await expect(page).toHaveURL(/\/task\//);
    await expect(
      page.locator(".message.user-message", {
        hasText: "import replay status fixture",
      }),
    ).toBeVisible();

    // session/status is transient and must not appear in transcript replay.
    await expect(page.locator(".system-status-message")).toHaveCount(0);

    // compact_boundary is durable and must remain visible in replay.
    await expect(page.locator(".compact-boundary-message")).toBeVisible();

    // Completed imported sessions should not resurrect transient banners.
    await expect(page.locator(".banner-processing")).not.toBeVisible();

    // Permission mode comes from durable init metadata.
    await expect(page.locator(".banner-perms")).toHaveText("init-perm");
  } finally {
    await killBackend(proc);
    rmSync(workDir, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// Split-root import preview/adoption test.
//
// Proves discovery is exact-rooted, not resolved via any bare-session-ID
// fallback: a poisoned same-session-ID sibling written under a different,
// unconfigured root (mirroring the backend-parent-profile-A vs.
// configured-profile-B split used by AC21/AC22/AC23 elsewhere in this unit)
// must never surface in the importable preview. It also proves workspace
// adoption is only durable after the server confirms it: reconfiguring the
// agent's profile root live (B -> C, with no re-scan — config reload only
// re-derives the workspace list, never re-enumerates native sessions) makes
// the server reject "Import Session" as a root mismatch, and the item must
// remain importable rather than silently promoting client-side.
// ---------------------------------------------------------------------------

function writeSplitRootConfig(
  configPath: string,
  profileRoot: string,
  displayName: string,
): void {
  writeTestConfig(
    configPath,
    `default_agent: work-claude
agents:
  work-claude:
    driver: claude
    display_name: ${displayName}
    sandbox:
      env:
        CLAUDE_CONFIG_DIR: ${profileRoot}
workspaces:
  testws:
    root: /tmp/cydo-test-workspace
`,
  );
}

function writeNativeClaudeSession(
  root: string,
  projectPath: string,
  sessionId: string,
  marker: string,
): void {
  const mangledPath = projectPath.replace(/\//g, "-");
  const dir = `${root}/projects/${mangledPath}`;
  mkdirSync(dir, { recursive: true });
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
        message: { content: marker },
      }),
    ].join("\n") + "\n";
  writeFileSync(`${dir}/${sessionId}.jsonl`, jsonlContent);
}

test(
  "importable preview is exact-rooted and a stale-root promote is rejected without promoting",
  { tag: "@claude-only" },
  async ({ page }) => {
    const { workDir, workerHome } = createWorkDir("split-root");
    const projectPath = "/tmp/cydo-test-workspace";
    const sessionId = "22223333-4444-5555-6666-777788889999";
    const realMarker = "split-root-real-import-marker";
    const poisonMarker = "split-root-a-poison-import-marker";

    // profileB is the currently-configured work-claude root; profileA is the
    // backend's own parent CLAUDE_CONFIG_DIR (unconfigured for work-claude,
    // never scanned); profileC is the root work-claude is reconfigured to
    // live, after the one and only scan already happened against B.
    const profileB = `${workDir}/profile-b`;
    const profileA = `${workerHome}/.claude`;
    const profileC = `${workDir}/profile-c`;

    writeNativeClaudeSession(profileB, projectPath, sessionId, realMarker);
    writeNativeClaudeSession(profileA, projectPath, sessionId, poisonMarker);

    const configPath = `${workerHome}/.config/cydo/config.yaml`;
    writeSplitRootConfig(configPath, profileB, "Profile B");

    const proc = spawnBackend(workDir, workerHome);
    try {
      await waitForBackend(proc);
      await page.goto(BACKEND_URL + "/");

      const realLabel = page.locator(
        ".project-card-sessions .sidebar-item .sidebar-label",
        { hasText: realMarker },
      );
      await expect(realLabel).toBeVisible();
      await expect(
        page.locator(".sidebar-item .sidebar-label", {
          hasText: poisonMarker,
        }),
      ).toHaveCount(0);

      await realLabel.click();
      await expect(page).toHaveURL(/\/task\//);
      await expect(
        page.locator(".message.user-message", { hasText: realMarker }),
      ).toBeVisible();
      await expect(
        page.locator(".message.user-message", { hasText: poisonMarker }),
      ).toHaveCount(0);

      const importBtn = page.locator(".btn-resume", {
        hasText: "Import Session",
      });
      await expect(importBtn).toBeVisible();
      const taskUrl = page.url();

      // Reconfigure work-claude live, from B to C, with no backend restart.
      writeSplitRootConfig(configPath, profileC, "Profile C");

      // Observe the config-reload acknowledgement via a fresh draft's
      // picker on the project card (mirrors the AC21/AC23 reconfiguration-
      // ack pattern), before returning to the still-importable task.
      await page.goto(BACKEND_URL + "/");
      await page
        .locator(".project-card", { hasText: "cydo-test-workspace" })
        .locator('button[title="New task"]')
        .click();
      await expect(
        page.locator('.agent-picker option[value="work-claude"]'),
      ).toHaveText("Profile C");

      await page.goto(taskUrl);
      await expect(importBtn).toBeVisible();
      await importBtn.click();

      const errorDialog = page.locator(".command-error-dialog");
      await expect(errorDialog).toBeVisible();
      await expect(errorDialog.locator(".command-error-message")).toHaveText(
        `Cannot import session ${sessionId} into workspace 'testws': ` +
          `it resolves to ${profileC} but the scanned session belongs to ${profileB}`,
      );
      await errorDialog.getByRole("button", { name: "Dismiss" }).click();
      await expect(errorDialog).not.toBeVisible();

      // The rejected promotion left the task importable, not silently
      // promoted client-side.
      await expect(importBtn).toBeVisible();
      await expect(
        page.locator(".sidebar-item.sidebar-archive-node", {
          hasText: /Import/,
        }),
      ).toBeVisible();
    } finally {
      await killBackend(proc);
      rmSync(workDir, { recursive: true, force: true });
    }
  },
);
