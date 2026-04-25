import { test as base, expect } from "@playwright/test";
import type { Locator, Page } from "@playwright/test";
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
import { join } from "path";
import { assistantText } from "./fixtures";

type RestartableBackend = {
  baseURL: string;
  codexHome: string;
  restart: () => Promise<void>;
};

async function waitForHttp(
  baseURL: string,
  proc?: ChildProcess,
  timeoutMs = 30_000,
) {
  const processExited = proc
    ? new Promise<never>((_, reject) => {
        if (proc.exitCode !== null) {
          reject(
            new Error(
              `Backend process already exited with code ${proc.exitCode}`,
            ),
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
  workDir: string,
  workerHome: string,
  codexHome: string,
): ChildProcess {
  return spawn(process.env.CYDO_BIN!, [], {
    detached: true,
    cwd: workDir,
    env: {
      ...process.env,
      HOME: workerHome,
      CODEX_HOME: codexHome,
      XDG_DATA_HOME: `${workDir}/data`,
    },
    stdio: ["ignore", "inherit", "inherit"],
  });
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
    if (entry.startsWith("rollout-") && entry.endsWith(".jsonl"))
      return fullPath;
  }
  return null;
}

function readFunctionCallOutputs(rolloutPath: string): string[] {
  const rawLines = readFileSync(rolloutPath, "utf8")
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
  return outputPayloads;
}

const test = base.extend<{ restartableBackend: RestartableBackend }>({
  restartableBackend: async ({}, use, testInfo) => {
    test.skip(testInfo.project.name !== "codex", "codex-only regression");

    const workDir = "/tmp/cydo-codex-history";
    const workerHome = `${workDir}/home`;
    const codexHome = `${workDir}/codex-home`;

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

    const baseURL = "http://localhost:3940";
    let proc = spawnBackend(workDir, workerHome, codexHome);
    await waitForHttp(baseURL, proc);

    const stop = async () => {
      try {
        process.kill(-proc.pid!, "SIGTERM");
      } catch {}
      await new Promise<void>((resolve) => proc.on("exit", () => resolve()));
      // Brief drain for codex to finish writing rollout JSONL
      await new Promise((r) => setTimeout(r, 5000));
    };

    const restart = async () => {
      await stop();
      proc = spawnBackend(workDir, workerHome, codexHome);
      await waitForHttp(baseURL, proc);
    };

    await use({ baseURL, codexHome, restart });

    try {
      process.kill(-proc.pid!, "SIGTERM");
    } catch {}
    await new Promise<void>((resolve) => proc.on("exit", () => resolve()));
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

  await expect(assistantText(page, "seed-history")).toBeVisible({
    timeout: 90_000,
  });

  const taskUrl = page.url();
  await page.waitForTimeout(1_000);

  const rolloutPath = findRolloutJsonl(
    join(restartableBackend.codexHome, "sessions"),
  );
  expect(rolloutPath).not.toBeNull();

  return { taskUrl, rolloutPath: rolloutPath! };
}

async function replayAndFindTaskTool(
  page: Page,
  restartableBackend: RestartableBackend,
  taskUrl: string,
): Promise<Locator> {
  await restartableBackend.restart();
  await page.goto(taskUrl);

  await expect(assistantText(page, "seed-history")).toBeVisible({
    timeout: 15_000,
  });

  const taskTool = page.locator(".tool-call").filter({
    has: page.locator(".tool-name", { hasText: "Task" }),
  });
  await expect(taskTool).toBeVisible({ timeout: 15_000 });
  return taskTool;
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
  await expect(taskTool).toContainText(toolError, { timeout: 90_000 });
  const taskText = await taskTool.innerText();
  expect(taskText).not.toContain("0: T");

  const rolloutPath = findRolloutJsonl(
    join(restartableBackend.codexHome, "sessions"),
  );
  expect(rolloutPath).not.toBeNull();

  const outputPayloads = readFunctionCallOutputs(rolloutPath!);
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
  const { taskUrl, rolloutPath } = await seedTaskAndLocateRollout(
    page,
    restartableBackend,
  );

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

  const taskTool = await replayAndFindTaskTool(
    page,
    restartableBackend,
    taskUrl,
  );
  await expect(taskTool).toContainText(toolError, { timeout: 15_000 });
  const taskText = await taskTool.innerText();
  expect(taskText).not.toContain("0: T");
});

test("codex history replay renders structured task error object cleanly", async ({
  page,
  restartableBackend,
}) => {
  const { taskUrl, rolloutPath } = await seedTaskAndLocateRollout(
    page,
    restartableBackend,
  );

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

  const taskTool = await replayAndFindTaskTool(
    page,
    restartableBackend,
    taskUrl,
  );
  await expect(taskTool).toContainText(toolError, { timeout: 15_000 });
  const taskText = await taskTool.innerText();
  expect(taskText).not.toContain("0: T");
});

test("codex history replay keeps successful structured task rendering", async ({
  page,
  restartableBackend,
}) => {
  const { taskUrl, rolloutPath } = await seedTaskAndLocateRollout(
    page,
    restartableBackend,
  );

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

  const taskTool = await replayAndFindTaskTool(
    page,
    restartableBackend,
    taskUrl,
  );
  await expect(taskTool).toContainText("Task finished successfully", {
    timeout: 15_000,
  });
  await expect(taskTool).toContainText("output_file:", { timeout: 15_000 });
  await expect(taskTool).toContainText("/tmp/out.md", { timeout: 15_000 });
});
test("codex history replay renders live task output from organic rollout", async ({
  page,
  restartableBackend,
}) => {
  test.setTimeout(180_000);

  await page.goto("/");
  await page.locator('button[title="New task"]').first().click();

  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled({ timeout: 15_000 });

  const markdownItem = "Organic rollout markdown item";
  await input.fill(`call task research reply with "1. ${markdownItem}"`);
  await page.locator(".btn-send:visible").first().click();

  const taskTool = page.locator(".tool-call").filter({
    has: page.locator(".tool-name", { hasText: "Task" }),
  });
  await expect(taskTool).toContainText("tid:", { timeout: 90_000 });
  await expect(taskTool).toContainText(markdownItem, { timeout: 90_000 });
  await expect(
    taskTool.locator(".text-content ol li", {
      hasText: markdownItem,
    }),
  ).toBeVisible({ timeout: 15_000 });

  const taskUrl = page.url();
  await page.waitForTimeout(1_000);

  const rolloutPath = findRolloutJsonl(
    join(restartableBackend.codexHome, "sessions"),
  );
  expect(rolloutPath).not.toBeNull();
  const organicTaskOutput = readFunctionCallOutputs(rolloutPath!).find((out) =>
    out.includes(markdownItem),
  );
  expect(organicTaskOutput).toBeTruthy();

  await restartableBackend.restart();
  await page.goto(taskUrl);

  const replayedTaskTool = page.locator(".tool-call").filter({
    has: page.locator(".tool-name", { hasText: "Task" }),
  });
  await expect(replayedTaskTool).toContainText("tid:", { timeout: 15_000 });
  await expect(replayedTaskTool).toContainText(markdownItem, {
    timeout: 15_000,
  });
  await expect(
    replayedTaskTool.locator(".text-content ol li", {
      hasText: markdownItem,
    }),
  ).toBeVisible({ timeout: 15_000 });
  await expect(replayedTaskTool).not.toContainText("Wall time:");
});
