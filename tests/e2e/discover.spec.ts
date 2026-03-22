/**
 * Tests for the sandboxed project discovery feature (cydo --discover).
 *
 * Tests 2-4 spin up their own per-test backend instances so each test can
 * exercise a specific workspace/sandbox configuration without interfering
 * with the shared per-worker backend from the main fixture.
 *
 * All four tests are agent-type-agnostic and run only under the "claude"
 * project to avoid redundant execution.
 */
import { test, expect } from "@playwright/test";
import { spawn, spawnSync, execFileSync } from "child_process";
import type { ChildProcess } from "child_process";
import { mkdirSync, rmSync, symlinkSync, writeFileSync, existsSync } from "fs";
import { createInterface } from "readline";

// Per-file sequential counter — incremented only for tests that actually
// run (not skipped), so ports are always unique within this file.
let _testSeq = 0;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function waitForBackend(
  baseURL: string,
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
        const res = await fetch(baseURL);
        if (res.ok || res.status < 500) return;
      } catch {
        /* not ready yet */
      }
      await new Promise((r) => setTimeout(r, 300));
    }
    throw new Error(`Backend at ${baseURL} did not start within ${timeoutMs}ms`);
  })();

  await Promise.race([polling, processExited]);
}

function spawnBackend(
  port: number,
  workDir: string,
  workerHome: string,
): ChildProcess {
  const proc = spawn(process.env.CYDO_BIN!, [], {
    detached: true,
    cwd: workDir,
    env: {
      ...process.env,
      HOME: workerHome,
      CYDO_LISTEN_PORT: String(port),
      CYDO_LOG_LEVEL: "trace",
    },
    stdio: ["ignore", "ignore", "pipe"],
  });
  if (proc.stderr) {
    const rl = createInterface({ input: proc.stderr });
    rl.on("line", (line) =>
      console.error(`[discover-backend:${port}] ${line}`),
    );
  }
  return proc;
}

async function killBackend(proc: ChildProcess): Promise<void> {
  const pgid = proc.pid!;
  try {
    process.kill(-pgid, "SIGTERM");
  } catch {
    /* already gone */
  }
  await new Promise<void>((r) => proc.on("exit", () => r()));
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    try {
      process.kill(-pgid, 0);
      await new Promise((r) => setTimeout(r, 100));
    } catch {
      break;
    }
  }
}

/** Create the standard per-test backend work directory layout. */
function createWorkDir(seq: number): { workDir: string; workerHome: string } {
  const workDir = `/tmp/cydo-discover-${seq}`;
  const workerHome = `${workDir}/home`;
  rmSync(workDir, { recursive: true, force: true });
  mkdirSync(`${workDir}/data`, { recursive: true });
  // The defs directory is required by the backend (task type definitions).
  symlinkSync("/tmp/cydo-test-workspace/defs", `${workDir}/defs`);
  mkdirSync(`${workerHome}/.config/cydo`, { recursive: true });
  return { workDir, workerHome };
}

/** Initialize a minimal git repository at the given path. */
function initGitRepo(dir: string): void {
  mkdirSync(dir, { recursive: true });
  execFileSync("git", ["init", "-q"], { cwd: dir });
  execFileSync("git", ["-C", dir, "config", "user.email", "test@test"]);
  execFileSync("git", ["-C", dir, "config", "user.name", "Test"]);
  writeFileSync(`${dir}/README.md`, "test\n");
  execFileSync("git", ["-C", dir, "add", "."]);
  execFileSync("git", ["-C", dir, "commit", "-qm", "init"]);
}

// ---------------------------------------------------------------------------
// Test 1: cydo --discover works as a standalone subcommand
// ---------------------------------------------------------------------------

test("cydo --discover subcommand works standalone", ({}, testInfo) => {
  test.skip(
    testInfo.project.name !== "claude",
    "agent-agnostic, runs in claude project only",
  );

  const result = spawnSync(
    process.env.CYDO_BIN!,
    ["--discover", "/tmp/cydo-test-workspace", "local", "3"],
    { encoding: "utf8" },
  );

  expect(result.status).toBe(0);

  const projects = JSON.parse(result.stdout) as Array<{
    path: string;
    name: string;
  }>;

  // /tmp/cydo-test-workspace is itself a git repo → single project returned
  // with name = basename(root) and path = root.
  expect(projects).toHaveLength(1);
  expect(projects[0]).toMatchObject({
    path: "/tmp/cydo-test-workspace",
    name: "cydo-test-workspace",
  });
});

// ---------------------------------------------------------------------------
// Test 2: sandboxed discovery with empty_dir masking excludes masked project
// ---------------------------------------------------------------------------

test(
  "sandboxed discovery with empty_dir masking excludes masked project",
  async ({ page }, testInfo) => {
    test.skip(
      testInfo.project.name !== "claude",
      "agent-agnostic, runs in claude project only",
    );

    // This test requires real bwrap.  In the Nix test environment the
    // fake-bwrap wrapper strips all bind-mount flags, so empty_dir overlays
    // have no effect and the masked project would still be found.
    const hasRealBwrap =
      existsSync("/run/wrappers/bin/bwrap") ||
      existsSync("/usr/bin/bwrap");
    test.skip(
      !hasRealBwrap,
      "real bwrap not found; empty_dir masking requires real bwrap",
    );

    const seq = testInfo.parallelIndex * 100 + _testSeq++;
    const port = 7050 + seq;
    const { workDir, workerHome } = createWorkDir(seq);
    const wsRoot = `/tmp/cydo-discover-bwrap-${seq}`;
    rmSync(wsRoot, { recursive: true, force: true });

    initGitRepo(`${wsRoot}/project-alpha`);
    initGitRepo(`${wsRoot}/project-beta`);

    // project-beta is masked with an empty_dir overlay in the sandbox config
    // so the discovery process cannot see its .git directory.
    writeFileSync(
      `${workerHome}/.config/cydo/config.yaml`,
      [
        "workspaces:",
        "  myws:",
        `    root: ${wsRoot}`,
        "    max_depth: 2",
        "    sandbox:",
        "      paths:",
        `        ${wsRoot}/project-beta: empty_dir`,
      ].join("\n") + "\n",
    );

    const proc = spawnBackend(port, workDir, workerHome);
    try {
      await waitForBackend(`http://localhost:${port}`, proc);
      await page.goto(`http://localhost:${port}/`);

      // project-alpha should appear (not masked)
      await expect(
        page.locator(".project-card-title", { hasText: "project-alpha" }),
      ).toBeVisible({ timeout: 15_000 });

      // project-beta must NOT appear (masked by empty_dir overlay)
      await expect(
        page.locator(".project-card-title", { hasText: "project-beta" }),
      ).not.toBeVisible();
    } finally {
      await killBackend(proc);
      rmSync(workDir, { recursive: true, force: true });
      rmSync(wsRoot, { recursive: true, force: true });
    }
  },
);

// ---------------------------------------------------------------------------
// Test 3: config reload triggers re-discovery and updates the welcome page
// ---------------------------------------------------------------------------

test(
  "config reload triggers re-discovery with new workspace",
  async ({ page }, testInfo) => {
    test.skip(
      testInfo.project.name !== "claude",
      "agent-agnostic, runs in claude project only",
    );

    const seq = testInfo.parallelIndex * 100 + _testSeq++;
    const port = 7050 + seq;
    const { workDir, workerHome } = createWorkDir(seq);

    // Second workspace: a directory containing one git repo.
    const wsRoot2 = `/tmp/cydo-discover-reload-${seq}`;
    rmSync(wsRoot2, { recursive: true, force: true });
    initGitRepo(`${wsRoot2}/new-project`);

    // Initial config: only the existing test workspace.
    const configPath = `${workerHome}/.config/cydo/config.yaml`;
    writeFileSync(
      configPath,
      ["workspaces:", "  ws1:", "    root: /tmp/cydo-test-workspace"].join(
        "\n",
      ) + "\n",
    );

    const proc = spawnBackend(port, workDir, workerHome);
    try {
      await waitForBackend(`http://localhost:${port}`, proc);
      await page.goto(`http://localhost:${port}/`);

      // Initial workspace project is visible.
      await expect(
        page.locator(".project-card-title", {
          hasText: "cydo-test-workspace",
        }),
      ).toBeVisible({ timeout: 15_000 });

      // Update config to add a second workspace.
      // The backend watches config.yaml via inotify (closeWrite event) and
      // calls discoverAllWorkspaces() + broadcasts workspaces_list on change.
      writeFileSync(
        configPath,
        [
          "workspaces:",
          "  ws1:",
          "    root: /tmp/cydo-test-workspace",
          "  ws2:",
          `    root: ${wsRoot2}`,
          "    max_depth: 2",
        ].join("\n") + "\n",
      );

      // The new workspace's project appears after the reload-triggered broadcast.
      await expect(
        page.locator(".project-card-title", { hasText: "new-project" }),
      ).toBeVisible({ timeout: 20_000 });

      // Original workspace still present.
      await expect(
        page.locator(".project-card-title", {
          hasText: "cydo-test-workspace",
        }),
      ).toBeVisible();
    } finally {
      await killBackend(proc);
      rmSync(workDir, { recursive: true, force: true });
      rmSync(wsRoot2, { recursive: true, force: true });
    }
  },
);

// ---------------------------------------------------------------------------
// Test 4: discovery failure for non-existent workspace root is handled
// ---------------------------------------------------------------------------

test(
  "discovery failure for non-existent workspace root is handled gracefully",
  async ({ page }, testInfo) => {
    test.skip(
      testInfo.project.name !== "claude",
      "agent-agnostic, runs in claude project only",
    );

    const seq = testInfo.parallelIndex * 100 + _testSeq++;
    const port = 7050 + seq;
    const { workDir, workerHome } = createWorkDir(seq);

    // "badws" points at a path that does not exist.
    writeFileSync(
      `${workerHome}/.config/cydo/config.yaml`,
      [
        "workspaces:",
        "  goodws:",
        "    root: /tmp/cydo-test-workspace",
        "  badws:",
        "    root: /tmp/this-path-does-not-exist-for-discover-test",
      ].join("\n") + "\n",
    );

    const proc = spawnBackend(port, workDir, workerHome);
    try {
      // The backend must start successfully — discovery failure must not crash it.
      await waitForBackend(`http://localhost:${port}`, proc);
      await page.goto(`http://localhost:${port}/`);

      // Page loads: the backend is alive after the failed discovery.
      await expect(page.locator(".welcome-page-header h1")).toContainText(
        "CyDo",
        { timeout: 10_000 },
      );

      // The good workspace still shows its project.
      await expect(
        page.locator(".project-card-title", {
          hasText: "cydo-test-workspace",
        }),
      ).toBeVisible({ timeout: 15_000 });

      // The failing workspace is NOT rendered: zero projects → no workspace
      // group element in the DOM (WelcomePage returns null when projects=[]).
      await expect(
        page.locator(".workspace-group-title", { hasText: "badws" }),
      ).not.toBeVisible();
    } finally {
      await killBackend(proc);
      rmSync(workDir, { recursive: true, force: true });
    }
  },
);
