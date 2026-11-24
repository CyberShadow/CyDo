/**
 * E2E tests for the session import feature.
 *
 * Verifies that:
 * 1. External sessions are discovered and shown in the Import group on
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
 * Each test runs under the Playwright project for the native history it creates.
 */
import { test, expect } from "@playwright/test";
import { execFileSync, spawn } from "child_process";
import type { ChildProcess } from "child_process";
import { randomUUID } from "node:crypto";
import { copyFileSync, globSync, mkdirSync, readdirSync, readFileSync, rmSync, symlinkSync } from "fs";
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
  codexHome = process.env.CODEX_HOME,
): ChildProcess {
  return spawn(process.env.CYDO_BIN!, [], {
    detached: true,
    cwd: workDir,
    env: {
      ...process.env,
      HOME: workerHome,
      CLAUDE_CONFIG_DIR: `${workerHome}/.claude`,
      CODEX_HOME: codexHome,
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

const projectPath = "/tmp/cydo-test-workspace";

function runClaude(
  workerHome: string,
  profileRoot: string,
  prompt: string,
  args: string[],
): void {
  execFileSync(
    "claude",
    ["-p", prompt, "--output-format", "json", "--permission-mode", "acceptEdits", ...args],
    {
      cwd: projectPath,
      env: { ...process.env, HOME: workerHome, CLAUDE_CONFIG_DIR: profileRoot },
      timeout: 120_000,
    },
  );
}

function createClaudeSession(
  workerHome: string,
  profileRoot: string,
  marker: string,
  sessionId = randomUUID(),
): string {
  runClaude(workerHome, profileRoot, `${marker}: reply with OK`, ["--session-id", sessionId]);
  const history = `${profileRoot}/projects/${projectPath.replace(/\//g, "-")}/${sessionId}.jsonl`;
  expect(readFileSync(history, "utf8")).toContain(marker);
  return history;
}

test(
  "a new real Claude session becomes importable after rescan",
  { tag: "@claude-only" },
  async ({ page }) => {
    const { workDir, workerHome } = createWorkDir("live-real-claude");
    const profileRoot = `${workerHome}/.claude`;
    writeTestConfig(
      `${workerHome}/.config/cydo/config.yaml`,
      ["workspaces:", "  testws:", `    root: ${projectPath}`].join("\n") + "\n",
    );

    const existingMarker = "claude-before-cydo-starts";
    const newMarker = "claude-after-cydo-starts";
    createClaudeSession(workerHome, profileRoot, existingMarker);

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

      createClaudeSession(workerHome, profileRoot, newMarker);

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
}) => {
  const { workDir, workerHome } = createWorkDir("sidebar");
  createClaudeSession(workerHome, `${workerHome}/.claude`, "sidebar import group test");

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
}) => {
  const { workDir, workerHome } = createWorkDir("import");
  createClaudeSession(workerHome, `${workerHome}/.claude`, "hello imported session");

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

test("import replay shows a real Claude compact boundary", { tag: "@claude-only" }, async ({
  page,
}) => {
  const { workDir, workerHome } = createWorkDir("compact-replay");
  const profileRoot = `${workerHome}/.claude`;
  const marker = "import replay compact fixture";
  const sessionId = randomUUID();
  const history = createClaudeSession(workerHome, profileRoot, marker, sessionId);
  runClaude(workerHome, profileRoot, "/compact", ["--resume", sessionId]);
  const rows = readFileSync(history, "utf8")
    .trimEnd().split("\n").map((line) => JSON.parse(line));
  expect(rows).toEqual(expect.arrayContaining([
    expect.objectContaining({
      type: "system",
      subtype: "compact_boundary",
    }),
  ]));

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
      { hasText: marker },
    );
    await expect(importableLabel).toBeVisible();
    await importableLabel.click();

    await expect(page).toHaveURL(/\/task\//);
    await expect(
      page.locator(".message.user-message", {
        hasText: marker,
      }),
    ).toBeVisible();

    // compact_boundary is durable and must remain visible in replay.
    await expect(page.locator(".compact-boundary-message")).toBeVisible();

    // Completed imported sessions should not resurrect transient banners.
    await expect(page.locator(".banner-processing")).not.toBeVisible();
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

test(
  "importable preview is exact-rooted and a stale-root promote is rejected without promoting",
  { tag: "@claude-only" },
  async ({ page }) => {
    const { workDir, workerHome } = createWorkDir("split-root");
    const sessionId = randomUUID();
    const realMarker = "split-root-real-import-marker";
    const poisonMarker = "split-root-a-poison-import-marker";

    // profileB is the currently-configured work-claude root; profileA is the
    // backend's own parent CLAUDE_CONFIG_DIR (unconfigured for work-claude,
    // never scanned); profileC is the root work-claude is reconfigured to
    // live, after the one and only scan already happened against B.
    const profileB = `${workDir}/profile-b`;
    const profileA = `${workerHome}/.claude`;
    const profileC = `${workDir}/profile-c`;

    createClaudeSession(workerHome, profileB, realMarker, sessionId);
    createClaudeSession(workerHome, profileA, poisonMarker, sessionId);

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

test(
  "a standalone Copilot session is offered for import in its project",
  { tag: "@copilot-only" },
  async ({ page }) => {
    const { workDir, workerHome } = createWorkDir("native-copilot");
    const profileRoot = `${workerHome}/.copilot`;
    const prompt = "Native Copilot import check";
    try {
      expect(process.env.HTTPS_PROXY).toBe("http://127.0.0.1:9001");
      expect(process.env.COPILOT_GITHUB_TOKEN).toBe("gho_mock_oauth_token");
      execFileSync("copilot", ["-p", prompt], {
        cwd: projectPath,
        env: {
          ...process.env,
          HOME: workerHome,
          XDG_CONFIG_HOME: `${workerHome}/.config`,
          XDG_DATA_HOME: `${workDir}/data`,
          COPILOT_HOME: profileRoot,
        },
        timeout: 120_000,
      });

      const stateDir = `${profileRoot}/session-state`;
      const sessions = readdirSync(stateDir, { withFileTypes: true })
        .filter((entry) => entry.isDirectory());
      expect(sessions).toHaveLength(1);
      const history = readFileSync(`${stateDir}/${sessions[0].name}/events.jsonl`, "utf8")
        .trimEnd().split("\n").map((line) => JSON.parse(line));
      expect(history).toEqual(expect.arrayContaining([
        expect.objectContaining({
          type: "user.message",
          data: expect.objectContaining({ content: prompt }),
        }),
        expect.objectContaining({ type: "assistant.message" }),
      ]));

      writeTestConfig(
        `${workerHome}/.config/cydo/config.yaml`,
        `default_agent: copilot
agents:
  copilot:
    driver: copilot
    sandbox:
      env:
        COPILOT_HOME: ${profileRoot}
workspaces:
  testws:
    root: ${projectPath}
`,
      );

      const proc = spawnBackend(workDir, workerHome);
      try {
        await waitForBackend(proc);
        await page.goto(BACKEND_URL + "/");

        const project = page.locator(".project-card").filter({
          has: page.locator(".project-card-title", { hasText: "cydo-test-workspace" }),
        });
        await expect(project).toBeVisible();
        const entry = project.locator(".project-card-sessions .sidebar-label", {
          hasText: prompt,
        });
        await expect(entry).toBeVisible({ timeout: 15_000 });
        await entry.click();

        await expect(page.locator(".message.user-message", { hasText: prompt })).toBeVisible();
        const importButton = page.getByRole("button", { name: "Import Session" });
        await expect(importButton).toBeVisible();
        await importButton.click();
        await expect(importButton).not.toBeVisible();
        await expect(page.locator(".btn-banner-resume")).toBeVisible();
      } finally {
        await killBackend(proc);
      }
    } finally {
      rmSync(workDir, { recursive: true, force: true });
    }
  },
);

test("standalone Codex session appears under its project with its title and can be imported", {
  tag: "@codex-only",
}, async ({ page }) => {
  const { workDir, workerHome } = createWorkDir("native-codex");
  const codexHome = `${workerHome}/.codex`;
  const marker = "Native Codex import test. Reply with OK.";
  try {
    mkdirSync(`${codexHome}/shell_snapshots`, { recursive: true });
    copyFileSync(`${process.env.CODEX_HOME}/config.toml`, `${codexHome}/config.toml`);
    const events = execFileSync("codex", ["exec", "--json", marker], {
      cwd: projectPath,
      env: { ...process.env, HOME: workerHome, CODEX_HOME: codexHome },
      encoding: "utf8",
      timeout: 120_000,
    }).trimEnd().split("\n").map((line) => JSON.parse(line));
    expect(events).toContainEqual(expect.objectContaining({ type: "turn.completed" }));

    const rollouts = globSync("sessions/**/rollout-*.jsonl", { cwd: codexHome });
    expect(rollouts).toHaveLength(1);
    const history = readFileSync(`${codexHome}/${rollouts[0]}`, "utf8")
      .trimEnd().split("\n").map((line) => JSON.parse(line));
    expect(history[0]).toMatchObject({
      type: "session_meta",
      payload: { cwd: projectPath },
    });
    expect(history).toContainEqual(expect.objectContaining({
      type: "response_item",
      payload: expect.objectContaining({
        type: "message",
        role: "user",
        content: expect.arrayContaining([
          expect.objectContaining({ type: "input_text", text: marker }),
        ]),
      }),
    }));

    writeTestConfig(
      `${workerHome}/.config/cydo/config.yaml`,
      `default_agent: codex
workspaces:
  testws:
    root: ${projectPath}
`,
    );
    const proc = spawnBackend(workDir, workerHome, codexHome);
    try {
      await waitForBackend(proc);
      await page.goto(BACKEND_URL + "/");

      const projectCard = page.locator(".project-card").filter({
        has: page.locator(".project-card-title", { hasText: "cydo-test-workspace" }),
      });
      await expect(projectCard).toBeVisible();
      const importableLabel = projectCard.locator(".project-card-sessions .sidebar-label", {
        hasText: marker,
      });
      await expect(importableLabel).toBeVisible({ timeout: 20_000 });
      await importableLabel.click();

      await expect(page.locator(".message.user-message", { hasText: marker })).toBeVisible();
      const importBtn = page.locator(".btn-resume", { hasText: "Import Session" });
      await expect(importBtn).toBeVisible();
      await importBtn.click();
      await expect(importBtn).not.toBeVisible();
      await expect(page.locator(".btn-banner-resume")).toBeVisible();
    } finally {
      await killBackend(proc);
    }
  } finally {
    rmSync(workDir, { recursive: true, force: true });
  }
});
