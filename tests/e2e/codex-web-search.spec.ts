import { test as base, expect } from "@playwright/test";
import { spawn } from "child_process";
import type { ChildProcess } from "child_process";
import {
  cpSync,
  mkdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "fs";
import {
  enterSession,
  sendMessage,
  killSession,
  responseTimeout,
  killBackend,
} from "./fixtures";

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

const test = base.extend<{ restartableBackend: RestartableBackend }>({
  restartableBackend: async ({}, use, testInfo) => {
    test.skip(testInfo.project.name !== "codex", "codex-only regression");

    const workDir = "/tmp/cydo-codex-web-search";
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

test("codex web search renders query subtitle and formatted results", { tag: "@codex-only" }, async ({
  page,
  restartableBackend,
}) => {
  // Phase 1: Live streaming
  await page.goto("/");
  await enterSession(page);
  await sendMessage(page, "web search dagster incremental pipelines");

  // Wait for WebSearch tool call to appear
  const toolCall = page.locator(".tool-call").filter({
    has: page.locator(".tool-name", { hasText: "webSearch" }),
  });
  await expect(toolCall).toBeVisible({ timeout: responseTimeout("codex") });

  // Verify query subtitle shows the search query
  await expect(toolCall.locator(".tool-subtitle")).toContainText(
    "dagster incremental pipelines",
  );

  // Verify the result was parsed by WebSearchResult component (query shown in web-search-query div)
  await expect(toolCall.locator(".web-search-query")).toBeVisible();
  // Verify no raw JSON in result (the old bug)
  await expect(toolCall).not.toContainText('"type":"web_search_call"');

  // Phase 2: History replay
  const taskUrl = page.url();
  await killSession(page, "codex");

  // Restart backend to trigger history replay from rollout JSONL
  await restartableBackend.restart();
  await page.goto(taskUrl);

  // Verify the same WebSearch tool call appears from history
  const replayedToolCall = page.locator(".tool-call").filter({
    has: page.locator(".tool-name", { hasText: "webSearch" }),
  });
  await expect(replayedToolCall).toBeVisible();
  await expect(replayedToolCall.locator(".tool-subtitle")).toContainText(
    "dagster incremental pipelines",
  );
  await expect(replayedToolCall.locator(".web-search-query")).toBeVisible();
});
