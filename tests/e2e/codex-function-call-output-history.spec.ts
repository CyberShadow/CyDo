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
import { assistantText, killBackend } from "./fixtures";

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
    const configPath = `${workerHome}/.config/cydo/config.yaml`;
    const config = readFileSync(configPath, "utf8");
    writeFileSync(
      configPath,
      config.includes("dev_mode:")
        ? config.replace(/^dev_mode:.*$/m, "dev_mode: true")
        : `${config}\ndev_mode: true\n`,
    );
    mkdirSync(codexHome, { recursive: true });
    mkdirSync(`${codexHome}/shell_snapshots`, { recursive: true });
    writeFileSync(
      `${codexHome}/config.toml`,
      `model = "codex-mini-latest"
model_provider = "cydo-mock"
approval_policy = "never"
sandbox_mode = "danger-full-access"

[model_providers.cydo-mock]
name = "CyDo mock OpenAI"
base_url = "http://127.0.0.1:9000/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
`,
    );

    const baseURL = "http://localhost:3940";
    let proc = spawnBackend(workDir, workerHome, codexHome);
    await waitForHttp(baseURL, proc);

    const stop = async () => {
      await killBackend(proc);
      // Brief drain for codex to finish writing rollout JSONL
      await new Promise((r) => setTimeout(r, 5000));
    };

    const restart = async () => {
      await stop();
      proc = spawnBackend(workDir, workerHome, codexHome);
      await waitForHttp(baseURL, proc);
    };

    await use({ baseURL, codexHome, restart });

    await killBackend(proc);
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
  await expect(input).toBeEnabled();
  await input.fill('reply with "seed-history"');
  await page.locator(".btn-send:visible").first().click();

  await expect(assistantText(page, "seed-history")).toBeVisible({
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
      });

  const taskTool = page.locator(".tool-call").filter({
    has: page.locator(".tool-name", { hasText: "Task" }),
  });
  await expect(taskTool).toBeVisible();
  return taskTool;
}

test("live invalid child task_type returns structured task error payload", { tag: "@codex-only" }, async ({
  page,
  restartableBackend,
}) => {
  await page.goto("/");
  await page.locator('button[title="New task"]').first().click();

  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled();

  await input.fill("call task invalid_type reproduce the bug");
  await page.locator(".btn-send:visible").first().click();

  const toolError = "Task type 'invalid_type' is not in creatable_tasks";
  const taskTool = page.locator(".tool-call").filter({
    has: page.locator(".tool-name", { hasText: "Task" }),
  });
  await expect(taskTool).toContainText(toolError);
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

test("codex history replay renders primitive task error as one message", { tag: "@codex-only" }, async ({
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
  await expect(taskTool).toContainText(toolError);
  const taskText = await taskTool.innerText();
  expect(taskText).not.toContain("0: T");
});

test("codex history replay renders structured task error object cleanly", { tag: "@codex-only" }, async ({
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
  await expect(taskTool).toContainText(toolError);
  const taskText = await taskTool.innerText();
  expect(taskText).not.toContain("0: T");
});

test("codex history replay keeps successful structured task rendering", { tag: "@codex-only" }, async ({
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
  await expect(taskTool).toContainText("Task finished successfully");
  await expect(taskTool).toContainText("output_file:");
  await expect(taskTool).toContainText("/tmp/out.md");
});

test("codex history replay renders custom exec output as one expanded tool", { tag: "@codex-only" }, async ({
  page,
  restartableBackend,
}) => {
  const { taskUrl, rolloutPath } = await seedTaskAndLocateRollout(
    page,
    restartableBackend,
  );
  await restartableBackend.restart();
  await page.goto(taskUrl);
  await expect(assistantText(page, "seed-history")).toBeVisible({
      });
  const diagnostics = page
    .locator(".message.system-message")
    .filter({ hasText: "Unrecognized agent data" });
  const diagnosticCount = await diagnostics.count();

  const callId = "call_custom_exec_history";
  const script =
    'const result = await tools.exec_command({ cmd: "pwd" });\ntext(result.output);';
  appendFileSync(
    rolloutPath,
    [
      JSON.stringify({
        timestamp: "2026-03-27T07:35:23.000Z",
        type: "response_item",
        payload: {
          type: "custom_tool_call",
          call_id: callId,
          name: "exec",
          input: script,
        },
      }),
      JSON.stringify({
        timestamp: "2026-03-27T07:35:23.428Z",
        type: "response_item",
        payload: {
          type: "custom_tool_call_output",
          call_id: callId,
          output: [
            { type: "input_text", text: "first " },
            { type: "input_text", text: "second" },
          ],
        },
      }),
      "",
    ].join("\n"),
  );

  await restartableBackend.restart();
  await page.goto(taskUrl);
  await expect(assistantText(page, "seed-history")).toBeVisible({
      });

  const execTool = page.locator(".tool-call").filter({
    has: page.locator(".tool-name", { hasText: "exec" }),
  });
  await expect(execTool).toHaveCount(1);
  await expect(execTool.locator(".write-content")).toHaveText(script);
  await expect(execTool.locator(".field-label", { hasText: "input:" })).toHaveCount(0);
  await expect(execTool.locator(".write-content span").first()).toBeVisible({
      });
  const scriptCopy = execTool
    .locator(".code-pre-wrap")
    .first()
    .locator('button[title="Copy to clipboard"]');
  await page.context().grantPermissions(["clipboard-read", "clipboard-write"], {
    origin: "http://localhost:3940",
  });
  await expect(scriptCopy).toBeVisible();
  await scriptCopy.click();
  await expect
    .poll(() => page.evaluate(() => navigator.clipboard.readText()))
    .toBe(script);
  await expect(execTool).toContainText("first second");
  await expect(diagnostics).toHaveCount(diagnosticCount);
});

test("codex history replay renders wait output", { tag: "@codex-only" }, async ({
  page,
  restartableBackend,
}) => {
  const { taskUrl, rolloutPath } = await seedTaskAndLocateRollout(
    page,
    restartableBackend,
  );
  await restartableBackend.restart();
  await page.goto(taskUrl);
  await expect(assistantText(page, "seed-history")).toBeVisible({
      });
  const diagnostics = page
    .locator(".message.system-message")
    .filter({ hasText: "Unrecognized agent data" });
  const diagnosticCount = await diagnostics.count();

  const waitCases = [
    ["cell_second_boundary", 999.95, "1s"],
    ["cell_one_second", 1000, "1s"],
    ["cell_ten_seconds", 10_000, "10s"],
    ["cell_fractional_second", 1500, "1.5s"],
    ["cell_minute_boundary", 59_999, "1m"],
    ["cell_hour", 3_600_000, "1h"],
    ["cell_hour_boundary", 3_599_999, "1h"],
  ] as const;
  appendFileSync(
    rolloutPath,
    [
      ...waitCases.flatMap(([cellId, yieldTimeMs]) => [
        JSON.stringify({
          timestamp: "2026-03-27T07:35:24.000Z",
          type: "response_item",
          payload: {
            type: "function_call",
            call_id: `call_wait_${cellId}`,
            name: "wait",
            arguments: JSON.stringify({
              cell_id: cellId,
              yield_time_ms: yieldTimeMs,
              max_tokens: 2000,
            }),
          },
        }),
        JSON.stringify({
          timestamp: "2026-03-27T07:35:24.428Z",
          type: "response_item",
          payload: {
            type: "function_call_output",
            call_id: `call_wait_${cellId}`,
            output: "Command finished.",
          },
        }),
      ]),
      "",
    ].join("\n"),
  );

  await restartableBackend.restart();
  await page.goto(taskUrl);
  await expect(assistantText(page, "seed-history")).toBeVisible({
      });

  const waitTool = page.locator(".tool-call").filter({
    has: page.locator(".tool-name", { hasText: "wait" }),
  });
  await expect(waitTool).toHaveCount(waitCases.length);
  for (const [cellId, yieldTimeMs, duration] of waitCases) {
    const tool = waitTool.filter({
      has: page.locator(".tool-subtitle-tag", {
        hasText: new RegExp(`^cell ${cellId}$`),
      }),
    });
    await expect(tool.locator(".tool-subtitle-tag")).toHaveText(`cell ${cellId}`);
    await tool.locator(".tool-header").click();
    await expect(tool.locator(".field-label", { hasText: "cell_id:" })).toHaveCount(1);
    await expect(tool).toContainText(cellId);
    await expect(
      tool.locator(".field-label", { hasText: "yield_time_ms:" }),
    ).toHaveCount(1);
    await expect(tool).toContainText(duration);
    await expect(tool).not.toContainText(String(yieldTimeMs));
    await expect(tool.locator(".field-label", { hasText: "max_tokens:" })).toHaveCount(1);
    await expect(tool).toContainText("2000");
    await expect(tool).toContainText("Command finished.");
    await expect(tool.locator(".unknown-result-fields")).toHaveCount(0);
  }
  await expect(diagnostics).toHaveCount(diagnosticCount);
});

test("codex history replay exposes unknown response-item payloads in dev mode", { tag: "@codex-only" }, async ({
  page,
  restartableBackend,
}) => {
  const { taskUrl, rolloutPath } = await seedTaskAndLocateRollout(
    page,
    restartableBackend,
  );

  appendFileSync(
    rolloutPath,
    `${JSON.stringify({
      timestamp: "2026-03-27T07:36:23.000Z",
      type: "response_item",
      payload: { type: "future_codex_payload" },
    })}\n`,
  );

  await restartableBackend.restart();
  await page.goto(taskUrl);

  const diagnostic = page
    .locator(".message.system-message")
    .filter({ hasText: "future_codex_payload" });
  await expect(diagnostic).toBeVisible();
  await expect(diagnostic).toContainText("Unrecognized agent data");
});

test("codex history replay renders live task output from organic rollout", { tag: "@codex-only" }, async ({
  page,
  restartableBackend,
}) => {

  await page.goto("/");
  await page.locator('button[title="New task"]').first().click();

  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled();

  const markdownItem = "Organic rollout markdown item";
  await input.fill(`call task research reply with "1. ${markdownItem}"`);
  await page.locator(".btn-send:visible").first().click();

  const taskTool = page.locator(".tool-call").filter({
    has: page.locator(".tool-name", { hasText: "Task" }),
  });
  await expect(taskTool).toContainText("Open task");
  await expect(taskTool).toContainText(markdownItem);
  await expect(
    taskTool.locator(".text-content ol li", {
      hasText: markdownItem,
    }),
  ).toBeVisible();

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
  await expect(replayedTaskTool).toContainText("Open task");
  await expect(replayedTaskTool).toContainText(markdownItem);
  await expect(
    replayedTaskTool.locator(".text-content ol li", {
      hasText: markdownItem,
    }),
  ).toBeVisible();
  await expect(replayedTaskTool).not.toContainText("Wall time:");
});
