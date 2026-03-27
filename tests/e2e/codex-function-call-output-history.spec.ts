import { test as base, expect } from "@playwright/test";
import type { Page } from "@playwright/test";
import { spawn } from "child_process";
import type { ChildProcess } from "child_process";
import {
  appendFileSync,
  cpSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "fs";
import { createServer } from "net";
import { join } from "path";
import { createInterface } from "readline";

type RestartableBackend = {
  baseURL: string;
  codexHome: string;
  restart: () => Promise<void>;
};

async function waitForHttp(baseURL: string, proc?: ChildProcess, timeoutMs = 30_000) {
  const processExited = proc
    ? new Promise<never>((_, reject) => {
        if (proc.exitCode !== null) {
          reject(
            new Error(`Backend process already exited with code ${proc.exitCode}`),
          );
          return;
        }
        proc.on("exit", (code, signal) => {
          reject(
            new Error(
              `Backend process exited with code ${code}` +
                `${signal ? ` (signal ${signal})` : ""} before becoming ready`,
            ),
          );
        });
      })
    : new Promise<never>(() => {});

  const polling = (async () => {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      try {
        const res = await fetch(baseURL);
        if (res.ok || res.status < 500) return;
      } catch {
        // not ready yet
      }
      await new Promise((r) => setTimeout(r, 300));
    }
    throw new Error(`Backend at ${baseURL} did not start in time`);
  })();

  await Promise.race([polling, processExited]);
}

function spawnBackend(
  port: number,
  workDir: string,
  workerHome: string,
  codexHome: string,
  mockApiBaseURL: string,
): ChildProcess {
  const proc = spawn(process.env.CYDO_BIN!, [], {
    detached: true,
    cwd: workDir,
    env: {
      ...process.env,
      HOME: workerHome,
      CYDO_LISTEN_PORT: String(port),
      CYDO_LOG_LEVEL: "trace",
      CYDO_AUTH_USER: "",
      CYDO_AUTH_PASS: "",
      ANTHROPIC_BASE_URL: mockApiBaseURL,
      OPENAI_BASE_URL: `${mockApiBaseURL}/v1`,
      CODEX_HOME: codexHome,
    },
    stdio: ["ignore", "ignore", "pipe"],
  });
  if (proc.stderr) {
    const rl = createInterface({ input: proc.stderr });
    rl.on("line", (line) => console.error(`[backend:${port}] ${line}`));
  }
  return proc;
}

function findRolloutJsonl(root: string): string | null {
  for (const entry of readdirSync(root)) {
    const fullPath = join(root, entry);
    const stat = statSync(fullPath);
    if (stat.isDirectory()) {
      const nested = findRolloutJsonl(fullPath);
      if (nested) return nested;
      continue;
    }
    if (entry.startsWith("rollout-") && entry.endsWith(".jsonl")) return fullPath;
  }
  return null;
}

let testSeq = 0;

async function getFreePort(): Promise<number> {
  const server = createServer();
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve());
  });
  const addr = server.address();
  if (!addr || typeof addr === "string") {
    server.close();
    throw new Error("Failed to allocate free TCP port");
  }
  const port = addr.port;
  await new Promise<void>((resolve) => server.close(() => resolve()));
  return port;
}

const test = base.extend<{ restartableBackend: RestartableBackend }>({
  restartableBackend: async ({}, use, testInfo) => {
    test.skip(testInfo.project.name !== "codex", "codex-only regression");

    const seq = testInfo.parallelIndex * 100 + testSeq++;
    const port = await getFreePort();
    const mockApiPort = await getFreePort();
    const workDir = `/tmp/cydo-codex-history-${seq}`;
    const workerHome = `${workDir}/home`;
    const codexHome = `${workDir}/codex-home`;
    const mockApiBaseURL = `http://127.0.0.1:${mockApiPort}`;
    const mockApiServerPath = join(__dirname, "../mock-api/server.mjs");

    rmSync(workDir, { recursive: true, force: true });
    mkdirSync(`${workDir}/data`, { recursive: true });
    symlinkSync("/tmp/cydo-test-workspace/defs", `${workDir}/defs`);
    mkdirSync(`${workerHome}/.config/cydo`, { recursive: true });
    cpSync(
      "/tmp/playwright-home/.config/cydo/config.yaml",
      `${workerHome}/.config/cydo/config.yaml`,
    );
    mkdirSync(codexHome, { recursive: true });
    writeFileSync(
      `${codexHome}/config.toml`,
      'model = "codex-mini-latest"\napproval_mode = "full-auto"\n',
    );

    const mockProc = spawn(process.execPath, [mockApiServerPath], {
      env: {
        ...process.env,
        MOCK_API_PORT: String(mockApiPort),
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    if (mockProc.stdout) {
      const rl = createInterface({ input: mockProc.stdout });
      rl.on("line", (line) => console.error(`[mock-api:${mockApiPort}] ${line}`));
    }
    if (mockProc.stderr) {
      const rl = createInterface({ input: mockProc.stderr });
      rl.on("line", (line) => console.error(`[mock-api:${mockApiPort}] ${line}`));
    }
    await waitForHttp(`${mockApiBaseURL}/api/hello`, undefined, 15_000);

    const baseURL = `http://localhost:${port}`;
    let proc = spawnBackend(port, workDir, workerHome, codexHome, mockApiBaseURL);
    await waitForHttp(baseURL, proc);

    const stop = async () => {
      const pgid = proc.pid!;
      process.kill(-pgid, "SIGTERM");
      await new Promise<void>((resolve) => proc.on("exit", () => resolve()));
      const deadline = Date.now() + 5_000;
      while (Date.now() < deadline) {
        try {
          process.kill(-pgid, 0);
          await new Promise((r) => setTimeout(r, 100));
        } catch {
          break;
        }
      }
    };

    const restart = async () => {
      await stop();
      proc = spawnBackend(port, workDir, workerHome, codexHome, mockApiBaseURL);
      await waitForHttp(baseURL, proc);
    };

    await use({ baseURL, codexHome, restart });

    try {
      await stop();
    } catch {
      // best effort during teardown
    }
    mockProc.kill();
    await new Promise<void>((resolve) => mockProc.on("exit", () => resolve()));
    rmSync(workDir, { recursive: true, force: true });
  },

  baseURL: async ({ restartableBackend }, use) => {
    await use(restartableBackend.baseURL);
  },
});

async function seedTaskAndLocateRollout(
  page: Page,
  restartableBackend: RestartableBackend,
): Promise<{ taskUrl: string; rolloutPath: string }> {
  await page.goto("/");
  await page.locator('button[title="New task"]').first().click();

  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled({ timeout: 15_000 });
  await input.fill('reply with "seed-history"');
  await page.locator(".btn-send:visible").first().click();

  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "seed-history",
    }),
  ).toBeVisible({ timeout: 60_000 });

  const taskUrl = page.url();
  await page.waitForTimeout(1_000);

  const rolloutPath = findRolloutJsonl(join(restartableBackend.codexHome, "sessions"));
  expect(rolloutPath).not.toBeNull();

  return { taskUrl, rolloutPath: rolloutPath! };
}

async function replayAndReadTaskTool(
  page: Page,
  restartableBackend: RestartableBackend,
  taskUrl: string,
): Promise<string> {
  await restartableBackend.restart();
  await page.goto(taskUrl);

  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "seed-history",
    }),
  ).toBeVisible({ timeout: 15_000 });

  const taskTool = page.locator(".tool-call").filter({
    has: page.locator(".tool-name", { hasText: "Task" }),
  });
  await expect(taskTool).toBeVisible({ timeout: 15_000 });
  return taskTool.innerText();
}

test("live invalid child task_type returns structured task error payload", async ({
  page,
  restartableBackend,
}) => {
  await page.goto("/");
  await page.locator('button[title="New task"]').first().click();

  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled({ timeout: 15_000 });

  await input.fill("call task invalid_type reproduce the bug");
  await page.locator(".btn-send:visible").first().click();

  const toolError = "Task type 'invalid_type' is not in creatable_tasks";
  const taskTool = page.locator(".tool-call").filter({
    has: page.locator(".tool-name", { hasText: "Task" }),
  });
  await expect(taskTool).toContainText(toolError, { timeout: 60_000 });
  const taskText = await taskTool.innerText();
  expect(taskText).not.toContain("0: T");

  const rolloutPath = findRolloutJsonl(join(restartableBackend.codexHome, "sessions"));
  expect(rolloutPath).not.toBeNull();

  const rawLines = readFileSync(rolloutPath!, "utf8")
    .split("\n")
    .filter((line) => line.trim().length > 0);
  const outputPayloads: string[] = [];
  for (const line of rawLines) {
    const row = JSON.parse(line) as {
      type?: string;
      payload?: { type?: string; output?: string };
    };
    if (
      row.type === "response_item" &&
      row.payload?.type === "function_call_output" &&
      typeof row.payload.output === "string"
    ) {
      outputPayloads.push(row.payload.output);
    }
  }

  const invalidTaskOutput = outputPayloads.find((out) =>
    out.includes("not in creatable_tasks"),
  );
  expect(invalidTaskOutput).toBeTruthy();
  expect(invalidTaskOutput!).toContain('"error"');
});

test("codex history replay renders primitive task error as one message", async ({
  page,
  restartableBackend,
}) => {
  const { taskUrl, rolloutPath } = await seedTaskAndLocateRollout(page, restartableBackend);

  const callId = "call_axv2WYmc7W5v0I3un7in9Hvl";
  const toolError =
    "Task type 'execute' is not in creatable_tasks for 'plan_mode'. Allowed: plan, quick_research, deep_research, spike";

  appendFileSync(
    rolloutPath,
    [
      JSON.stringify({
        timestamp: "2026-03-27T07:32:23.000Z",
        type: "response_item",
        payload: {
          type: "function_call",
          call_id: callId,
          name: "mcp__cydo__Task",
          arguments:
            '{"tasks":[{"task_type":"execute","prompt":"reproduce the bug","description":"Invalid task"}]}',
        },
      }),
      JSON.stringify({
        timestamp: "2026-03-27T07:32:23.428Z",
        type: "response_item",
        payload: {
          type: "function_call_output",
          call_id: callId,
          output: JSON.stringify({ tasks: [toolError] }),
        },
      }),
      "",
    ].join("\n"),
  );

  const taskText = await replayAndReadTaskTool(page, restartableBackend, taskUrl);
  expect(taskText).toContain(toolError);
  expect(taskText).not.toContain("0: T");
});

test("codex history replay renders structured task error object cleanly", async ({
  page,
  restartableBackend,
}) => {
  const { taskUrl, rolloutPath } = await seedTaskAndLocateRollout(page, restartableBackend);

  const callId = "call_structured_task_error";
  const toolError =
    "Task type 'execute' is not in creatable_tasks for 'plan_mode'. Allowed: plan, quick_research, deep_research, spike";

  appendFileSync(
    rolloutPath,
    [
      JSON.stringify({
        timestamp: "2026-03-27T07:33:23.000Z",
        type: "response_item",
        payload: {
          type: "function_call",
          call_id: callId,
          name: "mcp__cydo__Task",
          arguments:
            '{"tasks":[{"task_type":"execute","prompt":"reproduce the bug","description":"Invalid task"}]}',
        },
      }),
      JSON.stringify({
        timestamp: "2026-03-27T07:33:23.428Z",
        type: "response_item",
        payload: {
          type: "function_call_output",
          call_id: callId,
          output: JSON.stringify({
            tasks: [{ summary: toolError, error: toolError }],
          }),
        },
      }),
      "",
    ].join("\n"),
  );

  const taskText = await replayAndReadTaskTool(page, restartableBackend, taskUrl);
  expect(taskText).toContain(toolError);
  expect(taskText).not.toContain("0: T");
});

test("codex history replay keeps successful structured task rendering", async ({
  page,
  restartableBackend,
}) => {
  const { taskUrl, rolloutPath } = await seedTaskAndLocateRollout(page, restartableBackend);

  const callId = "call_structured_task_success";
  appendFileSync(
    rolloutPath,
    [
      JSON.stringify({
        timestamp: "2026-03-27T07:34:23.000Z",
        type: "response_item",
        payload: {
          type: "function_call",
          call_id: callId,
          name: "mcp__cydo__Task",
          arguments:
            '{"tasks":[{"task_type":"plan","prompt":"draft plan","description":"Plan task"}]}',
        },
      }),
      JSON.stringify({
        timestamp: "2026-03-27T07:34:23.428Z",
        type: "response_item",
        payload: {
          type: "function_call_output",
          call_id: callId,
          output: JSON.stringify({
            tasks: [
              {
                summary: "Task finished successfully",
                output_file: "/tmp/out.md",
                note: "Read the output file for full findings.",
              },
            ],
          }),
        },
      }),
      "",
    ].join("\n"),
  );

  const taskText = await replayAndReadTaskTool(page, restartableBackend, taskUrl);
  expect(taskText).toContain("Task finished successfully");
  expect(taskText).toContain("output_file:");
  expect(taskText).toContain("/tmp/out.md");
});
