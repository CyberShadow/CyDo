import { test, expect } from "@playwright/test";
import { spawn, execFileSync } from "child_process";
import type { ChildProcess } from "child_process";
import type { Page } from "@playwright/test";
import { basename } from "path";
import { mkdirSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { sendMessage } from "./fixtures";

function backendUrl(port: number): string {
  return `http://localhost:${port}`;
}

async function waitForBackend(
  proc: ChildProcess,
  baseUrl: string,
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
        const res = await fetch(baseUrl);
        if (res.ok || res.status < 500) return;
      } catch {
        // not ready yet
      }
      await new Promise((r) => setTimeout(r, 300));
    }
    throw new Error(
      `Backend at ${baseUrl} did not start within ${timeoutMs}ms`,
    );
  })();

  await Promise.race([polling, processExited]);
}

function spawnBackend(workDir: string, workerHome: string, port: number): ChildProcess {
  return spawn(process.env.CYDO_BIN!, [], {
    detached: true,
    cwd: workDir,
    env: {
      ...process.env,
      CYDO_AUTH_PASS: "",
      CYDO_LISTEN_PORT: String(port),
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
  } catch {
    // already gone
  }
  await new Promise<void>((r) => proc.on("exit", () => r()));
}

function createWorkDir(suffix: string): { workDir: string; workerHome: string } {
  const workDir = `/tmp/cydo-ask-ws-${suffix}`;
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

async function activeTid(page: Page): Promise<number> {
  const tid = await page.locator(".sidebar-item.active").first().getAttribute("data-tid");
  if (!tid) throw new Error("Missing active task tid");
  return parseInt(tid, 10);
}

async function createTaskInWorkspaceProject(
  page: Page,
  url: string,
  workspaceName: string,
  projectName: string,
  marker: string,
): Promise<number> {
  await page.goto(`${url}/`);
  const workspaceSection = page.locator("section.workspace-group").filter({
    has: page.locator(".workspace-group-title", { hasText: workspaceName }),
  });
  await expect(workspaceSection).toBeVisible({ timeout: 15_000 });
  const projectCard = workspaceSection.locator(".project-card").filter({
    has: page.locator(".project-card-title", { hasText: projectName }),
  }).first();
  await expect(projectCard).toBeVisible({ timeout: 15_000 });
  await projectCard.locator('button.sidebar-new-btn[title="New task"]').click();
  await sendMessage(page, `reply with "${marker}"`);
  await expect(
    page
      .locator('[style*="display: contents"] .message-list')
      .getByText(marker, { exact: true })
      .last(),
  ).toBeVisible({ timeout: 60_000 });
  await expect(page.locator(".sidebar-item.active")).toBeVisible({
    timeout: 15_000,
  });
  return activeTid(page);
}

test("Ask/Answer: Ask to importable target is rejected", async ({ page }, testInfo) => {
  test.skip(
    testInfo.project.name !== "claude",
    "agent-agnostic, runs in claude project only",
  );

  const { workDir, workerHome } = createWorkDir("importable");
  const wsRoot = "/tmp/cydo-ask-importable-project";
  rmSync(wsRoot, { recursive: true, force: true });
  initGitRepo(wsRoot);

  writeFileSync(
    `${workerHome}/.config/cydo/config.yaml`,
    ["workspaces:", "  askws:", `    root: ${wsRoot}`].join("\n") + "\n",
  );

  const sessionId = "f1111111-2222-3333-4444-555555555555";
  const mangledPath = wsRoot.replace(/\//g, "-");
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
        cwd: wsRoot,
      }),
      JSON.stringify({
        type: "user",
        message: { content: "importable ask target" },
      }),
    ].join("\n") + "\n",
  );

  const port = 3941;
  const url = backendUrl(port);
  const proc = spawnBackend(workDir, workerHome, port);
  try {
    await waitForBackend(proc, url);
    await createTaskInWorkspaceProject(
      page,
      url,
      "askws",
      basename(wsRoot),
      "importable-ask-root-ready",
    );

    const importableTid = 1;
    await sendMessage(page, `call ask ${importableTid} should fail`);
    await expect(
      page
        .locator('[style*="display: contents"] .message-list')
        .getByText(/cannot ask importable task/i)
        .last(),
    ).toBeVisible({ timeout: 60_000 });

    const importGroup = page.locator(".sidebar-item.sidebar-archive-node", {
      hasText: /Import \(1\)/,
    });
    await expect(importGroup).toBeVisible({ timeout: 15_000 });
    await importGroup.click();

    const importableItem = page.locator(".sidebar-item", {
      has: page.locator(".sidebar-label", { hasText: "importable ask target" }),
    });
    await expect(importableItem).toBeVisible({ timeout: 15_000 });
    await expect(importableItem.first()).toHaveAttribute("data-tid", "1");

    await importableItem.first().click();
    await expect(
      page.locator(".btn-resume", { hasText: "Import Session" }),
    ).toBeVisible({ timeout: 15_000 });
    await expect(
      page
        .locator('[style*="display: contents"] .message-list')
        .getByText(/Question from task \d+ \(qid=\d+\)/),
    ).not.toBeVisible();
  } finally {
    await killBackend(proc);
    rmSync(workDir, { recursive: true, force: true });
    rmSync(wsRoot, { recursive: true, force: true });
  }
});

test("Ask/Answer: cross-workspace Ask is rejected", async ({ page }, testInfo) => {
  test.skip(
    testInfo.project.name !== "claude",
    "agent-agnostic, runs in claude project only",
  );

  const { workDir, workerHome } = createWorkDir("cross");
  const wsRootA = "/tmp/cydo-ask-cross-alpha";
  const wsRootB = "/tmp/cydo-ask-cross-beta";
  rmSync(wsRootA, { recursive: true, force: true });
  rmSync(wsRootB, { recursive: true, force: true });
  initGitRepo(wsRootA);
  initGitRepo(wsRootB);

  writeFileSync(
    `${workerHome}/.config/cydo/config.yaml`,
    [
      "workspaces:",
      "  alpha:",
      `    root: ${wsRootA}`,
      "  beta:",
      `    root: ${wsRootB}`,
    ].join("\n") + "\n",
  );

  const port = 3942;
  const url = backendUrl(port);
  const proc = spawnBackend(workDir, workerHome, port);
  try {
    await waitForBackend(proc, url);

    const alphaTid = await createTaskInWorkspaceProject(
      page,
      url,
      "alpha",
      basename(wsRootA),
      "cross-alpha-root-ready",
    );
    const betaTid = await createTaskInWorkspaceProject(
      page,
      url,
      "beta",
      basename(wsRootB),
      "cross-beta-root-ready",
    );

    await page.goto(`${url}/alpha/${basename(wsRootA)}/task/${alphaTid}`);
    await sendMessage(page, `call ask ${betaTid} cross workspace question`);
    await expect(
      page
        .locator('[style*="display: contents"] .message-list')
        .getByText(/same workspace/i)
        .last(),
    ).toBeVisible({ timeout: 60_000 });

    await page.goto(`${url}/beta/${basename(wsRootB)}/task/${betaTid}`);
    await expect(
      page
        .locator('[style*="display: contents"] .message-list')
        .getByText(/Question from task \d+ \(qid=\d+\)/),
    ).not.toBeVisible();
  } finally {
    await killBackend(proc);
    rmSync(workDir, { recursive: true, force: true });
    rmSync(wsRootA, { recursive: true, force: true });
    rmSync(wsRootB, { recursive: true, force: true });
  }
});
