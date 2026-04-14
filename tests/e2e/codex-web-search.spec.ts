import { test as base, expect } from "@playwright/test";
import type { Page } from "@playwright/test";
import { spawn } from "child_process";
import type { ChildProcess } from "child_process";
import {
  appendFileSync,
  cpSync,
  mkdirSync,
  readdirSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "fs";
import { join } from "path";
import { enterSession, sendMessage, killSession, responseTimeout } from "./fixtures";

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
    if (entry.startsWith("rollout-") && entry.endsWith(".jsonl")) return fullPath;
  }
  return null;
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

  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "seed-history",
    }),
  ).toBeVisible({ timeout: 90_000 });

  const taskUrl = page.url();
  await page.waitForTimeout(1_000);

  const rolloutPath = findRolloutJsonl(join(restartableBackend.codexHome, "sessions"));
  expect(rolloutPath).not.toBeNull();

  return { taskUrl, rolloutPath: rolloutPath! };
}

test("codex web search renders query subtitle and formatted results", async ({
  page,
  restartableBackend,
}) => {
  // Phase 1: Live streaming
  await page.goto("/");
  await enterSession(page);
  await sendMessage(page, "web search dagster incremental pipelines");

  // Wait for WebSearch tool call to appear
  const toolCall = page.locator(".tool-call").filter({
    has: page.locator(".tool-name", { hasText: "WebSearch" }),
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
    has: page.locator(".tool-name", { hasText: "WebSearch" }),
  });
  await expect(replayedToolCall).toBeVisible({ timeout: 15_000 });
  await expect(replayedToolCall.locator(".tool-subtitle")).toContainText(
    "dagster incremental pipelines",
  );
  await expect(replayedToolCall.locator(".web-search-query")).toBeVisible();
});

test("codex history replay renders web_search_call from rollout JSONL", async ({
  page,
  restartableBackend,
}) => {
  const { taskUrl, rolloutPath } = await seedTaskAndLocateRollout(page, restartableBackend);

  // Append a web_search_call event to the rollout JSONL
  appendFileSync(
    rolloutPath,
    [
      JSON.stringify({
        timestamp: "2026-04-14T10:00:00.000Z",
        type: "response_item",
        payload: {
          type: "web_search_call",
          status: "completed",
          action: {
            type: "search",
            query: "dagster incremental pipelines",
            queries: [
              "dagster incremental pipelines",
              "dagster asset partitions docs",
            ],
          },
        },
      }),
      "",
    ].join("\n"),
  );

  await restartableBackend.restart();
  await page.goto(taskUrl);

  // Verify seed message replays
  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "seed-history",
    }),
  ).toBeVisible({ timeout: 15_000 });

  // Verify web search tool call renders from history
  const wsToolCall = page.locator(".tool-call").filter({
    has: page.locator(".tool-name", { hasText: "WebSearch" }),
  });
  await expect(wsToolCall).toBeVisible({ timeout: 15_000 });

  // Verify subtitle has main query
  await expect(wsToolCall.locator(".tool-subtitle")).toContainText(
    "dagster incremental pipelines",
  );

  // Verify both queries appear in formatted result
  await expect(wsToolCall).toContainText("dagster incremental pipelines");
  await expect(wsToolCall).toContainText("dagster asset partitions docs");
});
