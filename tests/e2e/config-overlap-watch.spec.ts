import { test, expect } from "@playwright/test";
import { execFileSync, spawn } from "child_process";
import type { ChildProcess } from "child_process";
import { mkdirSync, rmSync, symlinkSync, writeFileSync } from "fs";

const BACKEND_PORT =
  process.env.CYDO_TEST_PORT ?? process.env.CYDO_LISTEN_PORT ?? "3940";
const BACKEND_URL = `http://localhost:${BACKEND_PORT}`;

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
      XDG_DATA_HOME: `${workDir}/data`,
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

function createWorkDir(suffix: string): {
  workDir: string;
  workerHome: string;
} {
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
  writeFileSync(`${dir}/README.md`, "test\n");
  execFileSync("git", ["-C", dir, "add", "."]);
  execFileSync("git", ["-C", dir, "commit", "-qm", "init"]);
}

function writeConfig(configPath: string, workspaceRoot: string): void {
  writeFileSync(
    configPath,
    [
      "workspaces:",
      "  parent:",
      `    root: ${workspaceRoot}`,
      "    project_discovery:",
      '      recurse_when: "{{ not is_project and depth < 2 }}"',
      "  nested:",
      `    root: ${workspaceRoot}/repo/`,
    ].join("\n") + "\n",
  );
}

function writeConfigWithoutNested(
  configPath: string,
  workspaceRoot: string,
): void {
  writeFileSync(
    configPath,
    [
      "workspaces:",
      "  parent:",
      `    root: ${workspaceRoot}`,
      "    project_discovery:",
      '      recurse_when: "{{ not is_project and depth < 2 }}"',
    ].join("\n") + "\n",
  );
}

function decodeWebSocketData(data: unknown): string {
  if (typeof data === "string") return data;
  if (data instanceof ArrayBuffer) return new TextDecoder().decode(data);
  if (ArrayBuffer.isView(data)) {
    return new TextDecoder().decode(
      new Uint8Array(data.buffer, data.byteOffset, data.byteLength),
    );
  }
  return String(data);
}

async function requestProjectTaskTypes(projectPath: string): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const ws = new WebSocket(`${BACKEND_URL.replace(/^http/, "ws")}/ws`);
    ws.binaryType = "arraybuffer";
    let settled = false;
    const timeout = setTimeout(() => {
      settled = true;
      ws.close();
      reject(new Error(`Timed out waiting for task types for ${projectPath}`));
    }, 10_000);

    ws.addEventListener("open", () => {
      ws.send(
        JSON.stringify({
          type: "request_task_types",
          project_path: projectPath,
        }),
      );
    });

    ws.addEventListener("message", (ev) => {
      const msg = JSON.parse(decodeWebSocketData(ev.data)) as {
        type?: string;
        project_path?: string;
      };
      if (
        msg.type === "project_task_types_list" &&
        msg.project_path === projectPath
      ) {
        settled = true;
        clearTimeout(timeout);
        ws.close();
        resolve();
      }
    });

    ws.addEventListener("error", () => {
      settled = true;
      clearTimeout(timeout);
      reject(
        new Error(
          `WebSocket error while requesting task types for ${projectPath}`,
        ),
      );
    });

    ws.addEventListener("close", () => {
      clearTimeout(timeout);
      if (!settled) {
        reject(
          new Error(
            `WebSocket closed while requesting task types for ${projectPath}`,
          ),
        );
      }
    });
  });
}

async function rewriteConfigAndWaitForReload(
  configPath: string,
  workspaceRoot: string,
): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const ws = new WebSocket(`${BACKEND_URL.replace(/^http/, "ws")}/ws`);
    ws.binaryType = "arraybuffer";
    let settled = false;
    const timeout = setTimeout(() => {
      settled = true;
      ws.close();
      reject(new Error("Timed out waiting for config reload broadcast"));
    }, 10_000);

    ws.addEventListener("open", () => {
      writeConfigWithoutNested(configPath, workspaceRoot);
    });

    ws.addEventListener("message", (ev) => {
      const msg = JSON.parse(decodeWebSocketData(ev.data)) as {
        type?: string;
        workspaces?: { name: string }[];
      };
      if (
        msg.type === "workspaces_list" &&
        msg.workspaces?.some((workspace) => workspace.name === "parent") &&
        !msg.workspaces.some((workspace) => workspace.name === "nested")
      ) {
        settled = true;
        clearTimeout(timeout);
        ws.close();
        resolve();
      }
    });

    ws.addEventListener("error", () => {
      settled = true;
      clearTimeout(timeout);
      reject(new Error("WebSocket error while waiting for config reload"));
    });

    ws.addEventListener("close", () => {
      clearTimeout(timeout);
      if (!settled) {
        reject(
          new Error("WebSocket closed while waiting for config reload"),
        );
      }
    });
  });
}

async function expectBackendAlive(proc: ChildProcess): Promise<void> {
  await new Promise((r) => setTimeout(r, 500));
  expect(proc.exitCode, "CyDo backend should still be running").toBeNull();
}

test(
  "config reload removing overlapping workspace does not crash project watch registration",
  async ({}, testInfo) => {
    test.skip(
      testInfo.project.name !== "claude",
      "agent-agnostic, runs in claude project only",
    );

    const suffix = `overlap-watch-${testInfo.workerIndex}`;
    const { workDir, workerHome } = createWorkDir(suffix);
    const workspaceRoot = `/tmp/cydo-overlap-watch-${testInfo.workerIndex}`;
    const repoPath = `${workspaceRoot}/repo`;
    const configPath = `${workerHome}/.config/cydo/config.yaml`;

    rmSync(workspaceRoot, { recursive: true, force: true });
    initGitRepo(repoPath);
    mkdirSync(`${repoPath}/.cydo`, { recursive: true });
    writeConfig(configPath, workspaceRoot);

    const proc = spawnBackend(workDir, workerHome);
    try {
      await waitForBackend(proc);

      await requestProjectTaskTypes(`${repoPath}/`);
      await expectBackendAlive(proc);

      await rewriteConfigAndWaitForReload(configPath, workspaceRoot);
      await requestProjectTaskTypes(repoPath);
      await expectBackendAlive(proc);
    } finally {
      if (proc.exitCode === null) await killBackend(proc);
      rmSync(workDir, { recursive: true, force: true });
      rmSync(workspaceRoot, { recursive: true, force: true });
    }
  },
);
