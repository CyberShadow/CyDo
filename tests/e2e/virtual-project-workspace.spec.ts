/**
 * E2E test: workspace pinning for tasks vs. multi-workspace for importable sessions.
 *
 * Verifies:
 * 1. An importable task (workspace="") whose project path matches two workspace
 *    roots appears in BOTH workspace sections on the welcome page.
 * 2. A normal task (workspace="alpha") with the same project path appears ONLY
 *    in the alpha section, not in the beta section.
 *
 * Spins up its own per-test backend instance (following session-import.spec.ts
 * conventions) so the test controls its own HOME directory and data files,
 * independent of the worker-scoped backend fixture.
 */
import { test, expect } from "@playwright/test";
import { spawn, execFileSync } from "child_process";
import type { ChildProcess } from "child_process";
import { mkdirSync, rmSync, symlinkSync, writeFileSync } from "fs";

// ---------------------------------------------------------------------------
// Helpers (following discover.spec.ts / session-import.spec.ts pattern)
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

async function killBackend(proc: ChildProcess): Promise<void> {
  try {
    process.kill(-proc.pid!, "SIGTERM");
  } catch {}
  await new Promise<void>((r) => proc.on("exit", () => r()));
}

function createWorkDir(suffix: string): { workDir: string; workerHome: string } {
  const workDir = `/tmp/cydo-vws-${suffix}`;
  const workerHome = `${workDir}/home`;
  rmSync(workDir, { recursive: true, force: true });
  mkdirSync(`${workDir}/data`, { recursive: true });
  symlinkSync("/tmp/cydo-test-workspace/defs", `${workDir}/defs`);
  mkdirSync(`${workerHome}/.config/cydo`, { recursive: true });
  return { workDir, workerHome };
}

function initGitRepo(dir: string): void {
  mkdirSync(dir, { recursive: true });
  execFileSync("git", ["init", "-q"], { cwd: dir });
  execFileSync("git", ["-C", dir, "config", "user.email", "test@test"]);
  execFileSync("git", ["-C", dir, "config", "user.name", "Test"]);
  writeFileSync(`${dir}/README.md`, "test\n");
  execFileSync("git", ["-C", dir, "add", "."]);
  execFileSync("git", ["-C", dir, "commit", "-qm", "init"]);
}

/**
 * Pre-seed the CyDo SQLite database with a fully-migrated schema and one task.
 *
 * Sets PRAGMA user_version=19 (matching the 19 migration entries in persist.d)
 * so the backend's migration runner skips all migrations and uses this schema as-is.
 */
function seedDatabase(
  dbPath: string,
  workspace: string,
  projectPath: string,
  title: string,
): void {
  const args = JSON.stringify({ dbPath, workspace, projectPath, title, now: Date.now() });

  // Build SQL strings via JSON.stringify so embedded single-quotes are escaped.
  const createTasksSQL = JSON.stringify(
    "CREATE TABLE tasks (" +
      "tid INTEGER PRIMARY KEY AUTOINCREMENT," +
      "agent_session_id TEXT," +
      "description TEXT NOT NULL DEFAULT ''," +
      "task_type TEXT NOT NULL DEFAULT 'blank'," +
      "parent_tid INTEGER," +
      "relation_type TEXT NOT NULL DEFAULT ''," +
      "workspace TEXT NOT NULL DEFAULT ''," +
      "project_path TEXT NOT NULL DEFAULT ''," +
      "title TEXT NOT NULL DEFAULT ''," +
      "status TEXT NOT NULL DEFAULT 'pending'," +
      "worktree_path TEXT NOT NULL DEFAULT ''," +
      "has_worktree INTEGER NOT NULL DEFAULT 0," +
      "agent_type TEXT NOT NULL DEFAULT 'claude'," +
      "archived INTEGER NOT NULL DEFAULT 0," +
      "draft TEXT NOT NULL DEFAULT ''," +
      "result_text TEXT DEFAULT ''," +
      "created_at INTEGER," +
      "last_active INTEGER," +
      "worktree_tid INTEGER NOT NULL DEFAULT 0," +
      "entry_point TEXT NOT NULL DEFAULT ''" +
      ")",
  );

  const createDepsSQL = JSON.stringify(
    "CREATE TABLE task_deps (" +
      "parent_tid INTEGER NOT NULL," +
      "child_tid INTEGER NOT NULL," +
      "PRIMARY KEY (parent_tid, child_tid)" +
      ")",
  );

  const createCacheSQL = JSON.stringify(
    "CREATE TABLE session_meta_cache (" +
      "agent_type TEXT NOT NULL," +
      "session_id TEXT NOT NULL," +
      "mtime INTEGER NOT NULL," +
      "project_path TEXT NOT NULL DEFAULT ''," +
      "title TEXT NOT NULL DEFAULT ''," +
      "has_messages INTEGER NOT NULL DEFAULT 1," +
      "PRIMARY KEY (agent_type, session_id)" +
      ")",
  );

  const insertSQL = JSON.stringify(
    "INSERT INTO tasks " +
      "(workspace, project_path, title, status, agent_type, created_at, last_active) " +
      "VALUES (?, ?, ?, ?, ?, ?, ?)",
  );

  const script = `
    const { DatabaseSync } = require('node:sqlite');
    const a = ${args};
    const db = new DatabaseSync(a.dbPath);
    db.exec('PRAGMA journal_mode=WAL');
    db.exec('PRAGMA user_version=19');
    db.exec(${createTasksSQL});
    db.exec(${createDepsSQL});
    db.exec(${createCacheSQL});
    db.prepare(${insertSQL}).run(
      a.workspace, a.projectPath, a.title, 'completed', 'claude', a.now, a.now
    );
    db.close();
  `;

  execFileSync("node", ["--eval", script], {
    stdio: ["ignore", "pipe", "inherit"],
  });
}

// ---------------------------------------------------------------------------
// Test
// ---------------------------------------------------------------------------

test(
  "tasks with workspace are pinned; importable tasks appear in all matching workspaces",
  async ({ page }, testInfo) => {
    test.skip(
      testInfo.project.name !== "claude",
      "agent-agnostic, runs in claude project only",
    );

    const { workDir, workerHome } = createWorkDir("pin");

    // Shared workspace root: both alpha and beta point here.
    // Both will discover "shared-project" at the same absolute path.
    const sharedRoot = "/tmp/cydo-vws-shared-root";
    const sharedProject = `${sharedRoot}/shared-project`;

    rmSync(sharedRoot, { recursive: true, force: true });
    initGitRepo(sharedProject);

    // Config with two workspaces pointing at the same root.
    writeFileSync(
      `${workerHome}/.config/cydo/config.yaml`,
      [
        "workspaces:",
        "  alpha:",
        `    root: ${sharedRoot}`,
        "  beta:",
        `    root: ${sharedRoot}`,
      ].join("\n") + "\n",
    );

    // Importable JSONL session: cwd = sharedProject, first user message = title.
    const sessionId = "aaaabbbb-cccc-dddd-eeee-111111111111";
    const mangledPath = sharedProject.replace(/\//g, "-");
    const claudeProjectsDir = `${workerHome}/.claude/projects/${mangledPath}`;
    mkdirSync(claudeProjectsDir, { recursive: true });
    writeFileSync(
      `${claudeProjectsDir}/${sessionId}.jsonl`,
      [
        JSON.stringify({
          type: "system",
          subtype: "init",
          session_id: sessionId,
          model: "claude-3-5-sonnet-20241022",
          cwd: sharedProject,
        }),
        JSON.stringify({
          type: "user",
          message: { content: "importable shared task" },
        }),
      ].join("\n") + "\n",
    );

    // Pre-seed the database with a task pinned to workspace "alpha".
    const dbPath = `${workDir}/data/cydo.db`;
    seedDatabase(dbPath, "alpha", sharedProject, "pinned alpha task");

    const proc = spawnBackend(workDir, workerHome);
    try {
      await waitForBackend(proc);
      await page.goto(BACKEND_URL + "/");

      // Both workspace sections must appear (both discover "shared-project").
      await expect(
        page.locator(".workspace-group-title", { hasText: "alpha" }),
      ).toBeVisible({ timeout: 15_000 });
      await expect(
        page.locator(".workspace-group-title", { hasText: "beta" }),
      ).toBeVisible({ timeout: 15_000 });

      const alphaSection = page.locator("section.workspace-group").filter({
        has: page.locator(".workspace-group-title", { hasText: "alpha" }),
      });
      const betaSection = page.locator("section.workspace-group").filter({
        has: page.locator(".workspace-group-title", { hasText: "beta" }),
      });

      // Assertion 1: importable task (workspace="") appears in BOTH sections.
      // enumerateSessions() is async, so wait for it to land.
      await expect(
        alphaSection.locator(".sidebar-label", { hasText: "importable shared task" }),
      ).toBeVisible({ timeout: 15_000 });
      await expect(
        betaSection.locator(".sidebar-label", { hasText: "importable shared task" }),
      ).toBeVisible({ timeout: 15_000 });

      // Assertion 2: pinned task (workspace="alpha") appears ONLY in alpha.
      await expect(
        alphaSection.locator(".sidebar-label", { hasText: "pinned alpha task" }),
      ).toBeVisible({ timeout: 5_000 });
      await expect(
        betaSection.locator(".sidebar-label", { hasText: "pinned alpha task" }),
      ).not.toBeVisible();
    } finally {
      await killBackend(proc);
      rmSync(workDir, { recursive: true, force: true });
      rmSync(sharedRoot, { recursive: true, force: true });
    }
  },
);
