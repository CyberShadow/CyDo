import { test, expect } from "@playwright/test";
import { execFileSync, spawn } from "child_process";
import type { ChildProcess } from "child_process";
import {
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "fs";

type StartupRecord = {
  pid: number;
  event: "start" | "handoff";
  timestampNs: string;
  codexHome: string;
};

function waitForOpen(ws: WebSocket): Promise<void> {
  return new Promise((resolve, reject) => {
    ws.addEventListener("open", () => resolve(), { once: true });
    ws.addEventListener(
      "error",
      () => reject(new Error("WebSocket failed to open")),
      { once: true },
    );
  });
}

function waitForMessage(
  ws: WebSocket,
  predicate: (data: any) => boolean,
  timeoutMs: number,
): Promise<any> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      ws.removeEventListener("message", onMessage);
      reject(
        new Error(
          `Timed out waiting for matching WebSocket message after ${timeoutMs}ms`,
        ),
      );
    }, timeoutMs);

    const onMessage = async (event: MessageEvent) => {
      try {
        const text =
          typeof event.data === "string"
            ? event.data
            : event.data instanceof Blob
              ? await event.data.text()
              : String(event.data);
        const data = JSON.parse(text);
        if (!predicate(data)) return;
        clearTimeout(timeout);
        ws.removeEventListener("message", onMessage);
        resolve(data);
      } catch {
        // Ignore non-JSON frames.
      }
    };

    ws.addEventListener("message", onMessage);
  });
}

async function waitForBackend(proc: ChildProcess): Promise<void> {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    if (proc.exitCode !== null)
      throw new Error(`Backend exited with code ${proc.exitCode}`);
    try {
      const response = await fetch("http://localhost:3940");
      if (response.ok || response.status < 500) return;
    } catch {
      // The backend is still starting.
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error("Backend did not become ready within 30000ms");
}

async function stopBackend(proc: ChildProcess): Promise<void> {
  const exited = new Promise<void>((resolve) =>
    proc.once("exit", () => resolve()),
  );
  try {
    process.kill(-proc.pid!, "SIGTERM");
  } catch {
    // The backend has already exited.
  }
  if (proc.exitCode === null) await exited;
}

function readStartupRecords(logPath: string): StartupRecord[] {
  return readFileSync(logPath, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line) as StartupRecord);
}

function windowFor(
  records: StartupRecord[],
  codexHome: string,
): {
  start: StartupRecord;
  handoff: StartupRecord;
}[] {
  return records
    .filter(
      (record) => record.codexHome === codexHome && record.event === "start",
    )
    .map((start) => {
      const handoff = records.find(
        (record) =>
          record.codexHome === codexHome &&
          record.pid === start.pid &&
          record.event === "handoff",
      );
      expect(handoff).toBeDefined();
      return { start, handoff: handoff! };
    });
}

test(
  "Codex app-server startup is serialized per CODEX_HOME, not globally",
  { tag: "@codex-only" },
  async ({}, testInfo) => {
    test.skip(testInfo.project.name !== "codex", "codex-only regression");

    const workDir = "/tmp/cydo-codex-app-server-startup-serialization";
    const workerHome = `${workDir}/home`;
    const logPath = `${workDir}/app-server-startups.jsonl`;
    const wrapperPath = `${workDir}/codex-wrapper.sh`;
    const sharedHome = `${workDir}/codex-shared`;
    const firstHome = `${workDir}/codex-first`;
    const secondHome = `${workDir}/codex-second`;
    const alphaProject = `${workDir}/alpha`;
    const betaProject = `${workDir}/beta`;
    const realCodexBin = execFileSync("sh", ["-lc", "command -v codex"], {
      encoding: "utf8",
    }).trim();

    rmSync(workDir, { recursive: true, force: true });
    mkdirSync(`${workDir}/data`, { recursive: true });
    mkdirSync(alphaProject, { recursive: true });
    mkdirSync(betaProject, { recursive: true });
    for (const project of [alphaProject, betaProject])
      execFileSync("git", ["init", project]);
    symlinkSync("/tmp/cydo-test-workspace/defs", `${workDir}/defs`);
    mkdirSync(`${workerHome}/.config/cydo`, { recursive: true });
    for (const home of [sharedHome, firstHome, secondHome])
      cpSync("/tmp/codex-test-home", home, { recursive: true });

    writeFileSync(
      wrapperPath,
      `#!/bin/sh
if [ "$1" = app-server ] && [ "$2" = --listen ] && [ "$3" = stdio:// ]; then
  printf '{"pid":%s,"event":"start","timestampNs":%s,"codexHome":"%s"}\\n' "$$" "$(date +%s%N)" "$CODEX_HOME" >> "$CYDO_APP_SERVER_STARTUP_LOG"
  sleep 2
  printf '{"pid":%s,"event":"handoff","timestampNs":%s,"codexHome":"%s"}\\n' "$$" "$(date +%s%N)" "$CODEX_HOME" >> "$CYDO_APP_SERVER_STARTUP_LOG"
fi
exec "$CYDO_REAL_CODEX_BIN" "$@"
`,
      { mode: 0o755 },
    );

    writeFileSync(
      `${workerHome}/.config/cydo/config.yaml`,
      [
        "default_agent: shared-alpha",
        "agents:",
        "  shared-alpha:",
        "    driver: codex",
        "    sandbox:",
        "      env:",
        `        CYDO_CODEX_BIN: ${wrapperPath}`,
        `        CODEX_HOME: ${sharedHome}`,
        `        CYDO_REAL_CODEX_BIN: ${realCodexBin}`,
        `        CYDO_APP_SERVER_STARTUP_LOG: ${logPath}`,
        "  separate-first:",
        "    driver: codex",
        "    sandbox:",
        "      env:",
        `        CYDO_CODEX_BIN: ${wrapperPath}`,
        `        CODEX_HOME: ${firstHome}`,
        `        CYDO_REAL_CODEX_BIN: ${realCodexBin}`,
        `        CYDO_APP_SERVER_STARTUP_LOG: ${logPath}`,
        "  separate-second:",
        "    driver: codex",
        "    sandbox:",
        "      env:",
        `        CYDO_CODEX_BIN: ${wrapperPath}`,
        `        CODEX_HOME: ${secondHome}`,
        `        CYDO_REAL_CODEX_BIN: ${realCodexBin}`,
        `        CYDO_APP_SERVER_STARTUP_LOG: ${logPath}`,
        "workspaces:",
        "  alpha:",
        `    root: ${alphaProject}`,
        "    sandbox:",
        "      env:",
        "        CYDO_POOL_KEY: alpha",
        "  beta:",
        `    root: ${betaProject}`,
        "    sandbox:",
        "      env:",
        "        CYDO_POOL_KEY: beta",
        "",
      ].join("\n"),
    );

    const backend = spawn(process.env.CYDO_BIN!, [], {
      detached: true,
      cwd: workDir,
      env: {
        ...process.env,
        HOME: workerHome,
        CODEX_HOME: sharedHome,
        CYDO_CODEX_BIN: wrapperPath,
        CYDO_REAL_CODEX_BIN: realCodexBin,
        CYDO_APP_SERVER_STARTUP_LOG: logPath,
        XDG_DATA_HOME: `${workDir}/data`,
      },
      stdio: ["ignore", "inherit", "inherit"],
    });

    try {
      await waitForBackend(backend);
      const ws = new WebSocket("ws://localhost:3940/ws");
      await waitForOpen(ws);

      async function createTask(
        workspace: string,
        projectPath: string,
        agentName: string,
      ): Promise<number> {
        const correlationId = `startup-serialization-${agentName}-${workspace}`;
        const created = waitForMessage(
          ws,
          (data) =>
            data.type === "task_created" &&
            data.correlation_id === correlationId &&
            typeof data.tid === "number",
          540_000,
        );
        ws.send(
          JSON.stringify({
            type: "create_task",
            workspace,
            project_path: projectPath,
            entry_point: "agentic",
            agent_name: agentName,
            correlation_id: correlationId,
          }),
        );
        return (await created).tid;
      }

      async function completeTurn(tid: number): Promise<void> {
        const completed = waitForMessage(
          ws,
          (data) =>
            data.tid === tid &&
            data.event?.type === "turn/result" &&
            data.event?.subtype === "success",
          540_000,
        );
        ws.send(
          JSON.stringify({
            type: "message",
            tid,
            content: [{ type: "text", text: 'Please reply with "done"' }],
          }),
        );
        await completed;
      }

      async function subscribeTask(tid: number): Promise<void> {
        const historyEnd = waitForMessage(
          ws,
          (data) => data.type === "task_history_end" && data.tid === tid,
          540_000,
        );
        ws.send(JSON.stringify({ type: "request_history", tid }));
        await historyEnd;
      }

      const sharedTasks = await Promise.all([
        createTask("alpha", alphaProject, "shared-alpha"),
        createTask("beta", betaProject, "shared-alpha"),
      ]);
      await Promise.all(sharedTasks.map(subscribeTask));
      await Promise.all(sharedTasks.map(completeTurn));

      const separateTasks = await Promise.all([
        createTask("alpha", alphaProject, "separate-first"),
        createTask("beta", betaProject, "separate-second"),
      ]);
      await Promise.all(separateTasks.map(subscribeTask));
      await Promise.all(separateTasks.map(completeTurn));
      ws.close();

      const records = readStartupRecords(logPath);
      const sharedWindows = windowFor(records, sharedHome);
      expect(sharedWindows).toHaveLength(2);
      sharedWindows.sort((a, b) =>
        BigInt(a.start.timestampNs) < BigInt(b.start.timestampNs) ? -1 : 1,
      );
      expect(BigInt(sharedWindows[1].start.timestampNs)).toBeGreaterThanOrEqual(
        BigInt(sharedWindows[0].handoff.timestampNs),
      );

      const firstWindows = windowFor(records, firstHome);
      const secondWindows = windowFor(records, secondHome);
      expect(firstWindows).toHaveLength(1);
      expect(secondWindows).toHaveLength(1);
      const [first, second] = [firstWindows[0], secondWindows[0]].sort(
        (a, b) =>
          BigInt(a.start.timestampNs) < BigInt(b.start.timestampNs) ? -1 : 1,
      );
      expect(BigInt(second.start.timestampNs)).toBeLessThan(
        BigInt(first.handoff.timestampNs),
      );
    } finally {
      await stopBackend(backend);
      rmSync(workDir, { recursive: true, force: true });
    }
  },
);

test(
  "Codex app-server startup timeout does not crash the backend",
  { tag: "@codex-only" },
  async ({}, testInfo) => {
    test.skip(testInfo.project.name !== "codex", "codex-only regression");

    const workDir = "/tmp/cydo-codex-app-server-startup-timeout";
    const workerHome = `${workDir}/home`;
    const logPath = `${workDir}/app-server-startups.jsonl`;
    const wrapperPath = `${workDir}/codex-wrapper.sh`;
    const codexHome = `${workDir}/codex-home`;
    const project = `${workDir}/project`;
    const realCodexBin = execFileSync("sh", ["-lc", "command -v codex"], {
      encoding: "utf8",
    }).trim();

    rmSync(workDir, { recursive: true, force: true });
    mkdirSync(`${workDir}/data`, { recursive: true });
    mkdirSync(project, { recursive: true });
    execFileSync("git", ["init", project]);
    symlinkSync("/tmp/cydo-test-workspace/defs", `${workDir}/defs`);
    mkdirSync(`${workerHome}/.config/cydo`, { recursive: true });
    cpSync("/tmp/codex-test-home", codexHome, { recursive: true });

    writeFileSync(
      wrapperPath,
      `#!/bin/sh
if [ "$1" = app-server ] && [ "$2" = --listen ] && [ "$3" = stdio:// ]; then
  printf '{"pid":%s,"event":"start","timestampNs":%s,"codexHome":"%s"}\\n' "$$" "$(date +%s%N)" "$CODEX_HOME" >> "$CYDO_APP_SERVER_STARTUP_LOG"
  sleep 31
  printf '{"pid":%s,"event":"handoff","timestampNs":%s,"codexHome":"%s"}\\n' "$$" "$(date +%s%N)" "$CODEX_HOME" >> "$CYDO_APP_SERVER_STARTUP_LOG"
fi
exec "$CYDO_REAL_CODEX_BIN" "$@"
`,
      { mode: 0o755 },
    );

    writeFileSync(
      `${workerHome}/.config/cydo/config.yaml`,
      [
        "default_agent: delayed-codex",
        "agents:",
        "  delayed-codex:",
        "    driver: codex",
        "    sandbox:",
        "      env:",
        `        CYDO_CODEX_BIN: ${wrapperPath}`,
        `        CODEX_HOME: ${codexHome}`,
        `        CYDO_REAL_CODEX_BIN: ${realCodexBin}`,
        `        CYDO_APP_SERVER_STARTUP_LOG: ${logPath}`,
        "workspaces:",
        "  delayed:",
        `    root: ${project}`,
        "",
      ].join("\n"),
    );

    const backend = spawn(process.env.CYDO_BIN!, [], {
      detached: true,
      cwd: workDir,
      env: {
        ...process.env,
        HOME: workerHome,
        CODEX_HOME: codexHome,
        CYDO_CODEX_BIN: wrapperPath,
        CYDO_REAL_CODEX_BIN: realCodexBin,
        CYDO_APP_SERVER_STARTUP_LOG: logPath,
        XDG_DATA_HOME: `${workDir}/data`,
      },
      stdio: ["ignore", "inherit", "inherit"],
    });

    try {
      await waitForBackend(backend);
      const ws = new WebSocket("ws://localhost:3940/ws");
      await waitForOpen(ws);
      const correlationId = "startup-timeout";
      const created = waitForMessage(
        ws,
        (data) =>
          data.type === "task_created" &&
          data.correlation_id === correlationId &&
          typeof data.tid === "number",
        30_000,
      );
      ws.send(
        JSON.stringify({
          type: "create_task",
          workspace: "delayed",
          project_path: project,
          entry_point: "agentic",
          agent_name: "delayed-codex",
          correlation_id: correlationId,
        }),
      );
      const tid = (await created).tid;
      const historyEnd = waitForMessage(
        ws,
        (data) => data.type === "task_history_end" && data.tid === tid,
        30_000,
      );
      ws.send(JSON.stringify({ type: "request_history", tid }));
      await historyEnd;
      ws.send(
        JSON.stringify({
          type: "message",
          tid,
          content: [{ type: "text", text: 'Please reply with "done"' }],
        }),
      );

      await expect
        .poll(
          () =>
            existsSync(logPath) &&
            readStartupRecords(logPath).some((record) => record.event === "start"),
        )
        .toBe(true);
      await expect
        .poll(
          () =>
            existsSync(logPath) &&
            readStartupRecords(logPath).some((record) => record.event === "handoff"),
          { timeout: 45_000 },
        )
        .toBe(true);
      expect(backend.exitCode).toBeNull();
      expect((await fetch("http://localhost:3940")).status).toBeLessThan(500);
      ws.close();
    } finally {
      await stopBackend(backend);
      rmSync(workDir, { recursive: true, force: true });
    }
  },
);
