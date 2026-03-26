import { test as base, expect } from "@playwright/test";
import type { WorkerInfo } from "@playwright/test";
import { execFileSync, spawn } from "child_process";
import { mkdirSync, cpSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { createInterface } from "readline";
import { join } from "path";

type WorkerFixtures = {
  backend: { baseURL: string };
  backendLogs: string[];
};

function countMatches(lines: string[], pattern: RegExp): number {
  return lines.filter((line) => pattern.test(line)).length;
}

function waitForOpen(ws: WebSocket): Promise<void> {
  return new Promise((resolve, reject) => {
    ws.addEventListener("open", () => resolve(), { once: true });
    ws.addEventListener("error", () => reject(new Error("WebSocket failed to open")), { once: true });
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
      reject(new Error(`Timed out waiting for matching WebSocket message after ${timeoutMs}ms`));
    }, timeoutMs);

    const onMessage = async (event: MessageEvent) => {
      try {
        let rawText: string;
        if (typeof event.data === "string") {
          rawText = event.data;
        } else if (event.data instanceof Blob) {
          rawText = await event.data.text();
        } else if (event.data instanceof ArrayBuffer) {
          rawText = Buffer.from(event.data).toString("utf8");
        } else {
          rawText = String(event.data);
        }
        const data = JSON.parse(rawText);
        if (!predicate(data)) {
          return;
        }
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

const test = base.extend<WorkerFixtures>({
  backendLogs: [
    async ({}, use) => {
      await use([]);
    },
    { scope: "worker" },
  ],

  backend: [
    async (
      { backendLogs },
      use: (value: WorkerFixtures["backend"]) => Promise<void>,
      workerInfo: WorkerInfo,
    ) => {
      const port = 4300 + workerInfo.workerIndex;
      const mockApiPort = 9300 + workerInfo.workerIndex;
      const workDir = `/tmp/cydo-suggestion-failure-worker-${workerInfo.workerIndex}`;
      const workerHome = `${workDir}/home`;

      mkdirSync(`${workDir}/data`, { recursive: true });
      symlinkSync("/tmp/cydo-test-workspace/defs", `${workDir}/defs`);

      mkdirSync(`${workerHome}/.config/cydo`, { recursive: true });
      cpSync(
        "/tmp/playwright-home/.config/cydo/config.yaml",
        `${workerHome}/.config/cydo/config.yaml`,
      );

      const codexHome = `${workDir}/codex-home`;
      mkdirSync(codexHome, { recursive: true });
      writeFileSync(
        `${codexHome}/config.toml`,
        'model = "codex-mini-latest"\napproval_mode = "full-auto"\n',
      );

      const mockApiServerPath = join(__dirname, "../mock-api/server.mjs");
      const mockApiBaseURL = `http://127.0.0.1:${mockApiPort}`;
      const mockProc = spawn(process.execPath, [mockApiServerPath], {
        env: {
          ...process.env,
          MOCK_API_PORT: String(mockApiPort),
        },
        stdio: ["ignore", "pipe", "pipe"],
      });

      if (mockProc.stdout) {
        const rl = createInterface({ input: mockProc.stdout });
        rl.on("line", (line) => backendLogs.push(`[mock-api] ${line}`));
      }
      if (mockProc.stderr) {
        const rl = createInterface({ input: mockProc.stderr });
        rl.on("line", (line) => backendLogs.push(`[mock-api] ${line}`));
      }

      let mockReady = false;
      for (let i = 0; i < 30; i++) {
        try {
          const res = await fetch(`${mockApiBaseURL}/api/hello`);
          if (res.ok) {
            mockReady = true;
            break;
          }
        } catch {
          // not ready yet
        }
        await new Promise((resolve) => setTimeout(resolve, 500));
      }
      if (!mockReady) {
        mockProc.kill();
        throw new Error(`Mock API on port ${mockApiPort} did not start in time`);
      }

      const wrapperPath = join(__dirname, "..", "suggestion-one-shot-fail-wrapper.sh");
      const realClaudeBin = execFileSync("sh", ["-lc", "command -v claude"], {
        encoding: "utf8",
      }).trim();
      const proc = spawn(process.env.CYDO_BIN!, [], {
        detached: true,
        cwd: workDir,
        env: {
          ...process.env,
          HOME: workerHome,
          CYDO_LISTEN_PORT: String(port),
          CYDO_LOG_LEVEL: "trace",
          CYDO_CLAUDE_BIN: wrapperPath,
          CYDO_REAL_CLAUDE_BIN: realClaudeBin,
          ANTHROPIC_BASE_URL: mockApiBaseURL,
          OPENAI_BASE_URL: `${mockApiBaseURL}/v1`,
          CODEX_HOME: codexHome,
        },
        stdio: ["ignore", "ignore", "pipe"],
      });

      if (proc.stderr) {
        const rl = createInterface({ input: proc.stderr });
        rl.on("line", (line) => backendLogs.push(line));
      }

      const baseURL = `http://localhost:${port}`;
      let ready = false;
      for (let i = 0; i < 60; i++) {
        try {
          const res = await fetch(baseURL);
          if (res.ok || res.status < 500) {
            ready = true;
            break;
          }
        } catch {
          // not ready yet
        }
        await new Promise((resolve) => setTimeout(resolve, 500));
      }
      if (!ready) {
        process.kill(-proc.pid!, "SIGTERM");
        mockProc.kill();
        throw new Error(`CyDo backend on port ${port} did not start in time`);
      }

      await use({ baseURL });

      process.kill(-proc.pid!, "SIGTERM");
      await new Promise<void>((resolve) => proc.on("exit", resolve));
      await new Promise((resolve) => setTimeout(resolve, 500));
      mockProc.kill();
      await new Promise<void>((resolve) => mockProc.on("exit", resolve));

      rmSync(workDir, { recursive: true, force: true });
    },
    { scope: "worker" },
  ],

  baseURL: async ({ backend }, use) => {
    await use(backend.baseURL);
  },
});

test("suggestion one-shot rejection keeps session responsive", async ({ backend, backendLogs }) => {
  const ws = new WebSocket(`${backend.baseURL.replace("http", "ws")}/ws`);
  await waitForOpen(ws);

  const createdPromise = waitForMessage(
    ws,
    (data) => data.type === "task_created" && typeof data.tid === "number",
    10_000,
  );
  ws.send(JSON.stringify({
    type: "create_task",
    workspace: "local",
    project_path: "/tmp/cydo-test-workspace",
    correlation_id: "repro",
  }));

  const created = await createdPromise;
  const tid = created.tid as number;

  const historyEndPromise = waitForMessage(
    ws,
    (data) => data.type === "task_history_end" && data.tid === tid,
    10_000,
  );
  ws.send(JSON.stringify({ type: "request_history", tid }));
  await historyEndPromise;

  const failurePattern = /generateSuggestions\[\d+\]: one-shot failed: claude exited with status 1/;
  const resultPattern = /"type":"result","subtype":"success"/;
  let sawFailure = false;
  for (let i = 0; i < 6; i++) {
    const seenResults = countMatches(backendLogs, resultPattern);
    ws.send(JSON.stringify({ type: "message", tid, content: [{ type: "text", text: 'Please reply with "done"' }] }));

    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline) {
      if (countMatches(backendLogs, failurePattern) > 0) {
        sawFailure = true;
      }
      if (countMatches(backendLogs, resultPattern) > seenResults) {
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, 100));
    }

    expect(
      countMatches(backendLogs, resultPattern),
      `Expected a successful turn result after turn ${i + 1}.\n\n${backendLogs.join("\n")}`,
    ).toBeGreaterThan(seenResults);
  }

  ws.close();
  expect(
    sawFailure,
    `Expected to observe at least one rejected suggestion one-shot.\n\n${backendLogs.join("\n")}`,
  ).toBeTruthy();
});
