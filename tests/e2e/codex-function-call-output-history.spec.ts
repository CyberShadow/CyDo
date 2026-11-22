import { test as base, expect } from "@playwright/test";
import { spawn } from "child_process";
import type { ChildProcess } from "child_process";
import {
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

test(
  "live invalid child task_type returns structured task error payload",
  { tag: "@codex-only" },
  async ({ page, restartableBackend }) => {
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
  },
);

test(
  "codex history replay renders live task output from organic rollout",
  { tag: "@codex-only" },
  async ({ page, restartableBackend }) => {
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
    const organicTaskOutput = readFunctionCallOutputs(rolloutPath!).find(
      (out) => out.includes(markdownItem),
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
  },
);
