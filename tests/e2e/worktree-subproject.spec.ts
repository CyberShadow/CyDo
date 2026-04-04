import { test, expect } from "@playwright/test";
import { spawn, execFileSync } from "child_process";
import type { ChildProcess } from "child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync } from "fs";

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

function spawnBackend(workDir: string, workerHome: string): ChildProcess {
  return spawn(process.env.CYDO_BIN!, [], {
    detached: true,
    cwd: workDir,
    env: {
      ...process.env,
      HOME: workerHome,
    },
    stdio: ["ignore", "inherit", "inherit"],
  });
}

async function killBackend(proc: ChildProcess): Promise<void> {
  try {
    process.kill(-proc.pid!, "SIGTERM");
  } catch {
    /* already gone */
  }
  await new Promise<void>((r) => proc.on("exit", () => r()));
}

function createWorkDir(suffix: string): { workDir: string; workerHome: string } {
  const workDir = `/tmp/cydo-backend-${suffix}`;
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
}

function setupMonorepo(workerHome: string, wsRoot: string): {
  repoDir: string;
  projectDir: string;
} {
  const repoDir = `${wsRoot}/monorepo`;
  const projectDir = `${repoDir}/project`;

  rmSync(wsRoot, { recursive: true, force: true });
  initGitRepo(repoDir);
  mkdirSync(projectDir, { recursive: true });
  writeFileSync(`${repoDir}/README.md`, "root\n");
  writeFileSync(`${projectDir}/README.md`, "project\n");
  execFileSync("git", ["-C", repoDir, "add", "."]);
  execFileSync("git", ["-C", repoDir, "commit", "-qm", "init"]);

  writeFileSync(
    `${workerHome}/.config/cydo/config.yaml`,
    [
      "workspaces:",
      "  mono:",
      `    root: ${wsRoot}`,
      "    project_discovery:",
      "      is_project:",
      "        equals:",
      "          - $relative_path",
      "          - monorepo/project",
      "      recurse_when:",
      "        less_than:",
      "          - $depth",
      "          - 3",
    ].join("\n") + "\n",
  );

  return { repoDir, projectDir };
}

function listFilesRecursive(dir: string): string[] {
  if (!existsSync(dir)) return [];
  const entries = readdirSync(dir);
  const files: string[] = [];
  for (const entry of entries) {
    const path = `${dir}/${entry}`;
    const stat = statSync(path);
    if (stat.isDirectory()) files.push(...listFilesRecursive(path));
    else files.push(path);
  }
  return files;
}

function mangleClaudePath(path: string): string {
  return path.replaceAll("/", "-").replaceAll(".", "-");
}

test(
  "worktree task starts in the selected subproject inside a monorepo",
  async ({ page }, testInfo) => {
    test.skip(
      testInfo.project.name !== "claude",
      "worktree regression is backend-level; run once in claude project",
    );

    const { workDir, workerHome } = createWorkDir("worktree-subproject");
    const wsRoot = "/tmp/cydo-worktree-subproject";
    const claudeDir =
      process.env.CLAUDE_CONFIG_DIR || `${process.env.HOME || "/tmp"}/.claude`;

    const { repoDir, projectDir } = setupMonorepo(workerHome, wsRoot);

    const taskCreatedEvents: Array<{
      tid: number;
      parent_tid?: number;
      relation_type?: string;
    }> = [];

    const proc = spawnBackend(workDir, workerHome);
    try {
      await waitForBackend(proc);

      page.on("websocket", (ws) => {
        ws.on("framereceived", (event) => {
          try {
            const data = JSON.parse(event.payload.toString());
            if (data.type === "task_created") {
              taskCreatedEvents.push({
                tid: data.tid,
                parent_tid: data.parent_tid,
                relation_type: data.relation_type,
              });
            }
          } catch {
            /* ignore non-JSON frames */
          }
        });
      });

      await page.goto(BACKEND_URL + "/");

      await expect(
        page.locator(".project-card-title[title='monorepo/project']"),
      ).toBeVisible({ timeout: 15_000 });

      await page.locator(".project-card-title[title='monorepo/project']").click();
      await expect(page.locator(".input-textarea:visible").first()).toBeEnabled({
        timeout: 15_000,
      });
      await expect(page).toHaveTitle("project — CyDo");

      await page.locator(".input-textarea:visible").first().fill(
        "call task spike verify current directory",
      );
      await page.locator(".btn-send:visible").first().click();

      await expect(async () => {
        const spike = taskCreatedEvents.find((e) => e.relation_type === "subtask");
        expect(spike).toBeTruthy();
      }).toPass({ timeout: 60_000 });

      const spikeTid = taskCreatedEvents.find((e) => e.relation_type === "subtask")!.tid;
      const taskScopedWorktree = `${projectDir}/.cydo/tasks/${spikeTid}/worktree`;
      const repoScopedWorktree = `${repoDir}/.cydo/tasks/${spikeTid}/worktree`;

      await expect
        .poll(() => existsSync(repoScopedWorktree), { timeout: 30_000 })
        .toBe(true);
      expect(existsSync(taskScopedWorktree)).toBe(false);

      const expectedCwd = `${repoScopedWorktree}/project`;

      const expectedHistoryDir = `${claudeDir}/projects/${mangleClaudePath(expectedCwd)}`;
      await expect
        .poll(
          () =>
            listFilesRecursive(expectedHistoryDir).filter((path) =>
              path.endsWith(".jsonl"),
            ).length,
          { timeout: 30_000 },
        )
        .toBeGreaterThan(0);
    } finally {
      await killBackend(proc);
      rmSync(workDir, { recursive: true, force: true });
      rmSync(wsRoot, { recursive: true, force: true });
    }
  },
);

test(
  "blank task sandbox allows writes at the monorepo root",
  async ({ page }, testInfo) => {
    test.skip(
      testInfo.project.name !== "claude",
      "sandbox regression is backend-level; run once in claude project",
    );

    const { workDir, workerHome } = createWorkDir("sandbox-subproject");
    const wsRoot = "/tmp/cydo-sandbox-subproject";
    const { repoDir } = setupMonorepo(workerHome, wsRoot);
    const repoRootFile = `${repoDir}/repo-root-write.txt`;

    const proc = spawnBackend(workDir, workerHome);
    try {
      await waitForBackend(proc);
      await page.goto(BACKEND_URL + "/");

      await expect(
        page.locator(".project-card-title[title='monorepo/project']"),
      ).toBeVisible({ timeout: 15_000 });

      await page.locator(".project-card-title[title='monorepo/project']").click();
      await expect(page.locator(".input-textarea:visible").first()).toBeEnabled({
        timeout: 15_000,
      });

      await page.locator(".input-textarea:visible").first().fill(
        "Please run command sh -lc 'printf sandbox-root-ok > ../repo-root-write.txt && cat ../repo-root-write.txt'",
      );
      await page.locator(".btn-send:visible").first().click();

      await expect
        .poll(() => existsSync(repoRootFile), { timeout: 60_000 })
        .toBe(true);
      expect(readFileSync(repoRootFile, "utf8")).toBe("sandbox-root-ok");
    } finally {
      await killBackend(proc);
      rmSync(workDir, { recursive: true, force: true });
      rmSync(wsRoot, { recursive: true, force: true });
    }
  },
);
