import { test as base, expect } from "@playwright/test";
import type { Page, WorkerInfo } from "@playwright/test";
import { spawn } from "child_process";
import { mkdirSync, cpSync, symlinkSync } from "fs";
import { createInterface } from "readline";
import * as path from "path";
import { enterSession, sendMessage, responseTimeout } from "./fixtures";

type WorkerFixtures = {
  backend: { port: number; baseURL: string };
};

function parsePortFromLines(
  rl: ReturnType<typeof createInterface>,
  proc: ReturnType<typeof spawn>,
  pattern: RegExp,
): Promise<number> {
  return new Promise((resolve, reject) => {
    const onExit = (code: number | null) =>
      reject(new Error(`Process exited with ${code} before logging port`));
    const onLine = (line: string) => {
      const match = line.match(pattern);
      if (match) {
        rl.off("line", onLine);
        proc.off("exit", onExit);
        resolve(parseInt(match[1], 10));
      }
    };
    rl.on("line", onLine);
    proc.on("exit", onExit);
  });
}

/**
 * Extended test fixture that starts a per-worker CyDo backend configured
 * to use the extra-fields wrapper as the claude binary. This injects
 * extra/unknown fields into every NDJSON line to verify they are surfaced in
 * the UI.
 *
 * Intentionally does NOT perform the standard post-test assertions for
 * .unknown-result-fields or "Unknown message type", since extra fields are
 * expected here.
 */
const test = base.extend<{ agentType: string }, WorkerFixtures>({
  backend: [
    async (
      {},
      use: (r: WorkerFixtures["backend"]) => Promise<void>,
      workerInfo: WorkerInfo,
    ) => {
      const workDir = `/tmp/cydo-extra-fields-worker-${workerInfo.workerIndex}`;
      const workerHome = `${workDir}/home`;

      mkdirSync(`${workDir}/data`, { recursive: true });
      symlinkSync("/tmp/cydo-test-workspace/defs", `${workDir}/defs`);

      mkdirSync(`${workerHome}/.config/cydo`, { recursive: true });
      cpSync(
        "/tmp/playwright-home/.config/cydo/config.yaml",
        `${workerHome}/.config/cydo/config.yaml`,
      );

      const wrapperPath = path.join(__dirname, "..", "extra-fields-wrapper.sh");

      // Start per-worker mock API with port 0 (OS-assigned)
      const mockApiServerPath = path.join(__dirname, "../mock-api/server.mjs");
      const mockProc = spawn(process.execPath, [mockApiServerPath], {
        env: { ...process.env, MOCK_API_PORT: "0" },
        stdio: ["ignore", "pipe", "pipe"],
      });
      const mockOutRl = createInterface({ input: mockProc.stdout! });
      mockOutRl.on("line", () => {});
      if (mockProc.stderr) {
        const rl = createInterface({ input: mockProc.stderr });
        rl.on("line", () => {});
      }

      // Parse actual port from mock API stdout
      const mockApiPort = await parsePortFromLines(
        mockOutRl,
        mockProc,
        /listening on http:\/\/127\.0\.0\.1:(\d+)/,
      );
      const mockApiBaseURL = `http://127.0.0.1:${mockApiPort}`;

      let mockReady = false;
      for (let i = 0; i < 30; i++) {
        try {
          const res = await fetch(`${mockApiBaseURL}/api/hello`);
          if (res.ok) {
            mockReady = true;
            break;
          }
        } catch {
          /* not ready yet */
        }
        await new Promise((r) => setTimeout(r, 500));
      }
      if (!mockReady) {
        mockProc.kill();
        throw new Error(
          `Mock API on port ${mockApiPort} did not start in time`,
        );
      }

      const proc = spawn(process.env.CYDO_BIN!, [], {
        detached: true,
        cwd: workDir,
        env: {
          ...process.env,
          HOME: workerHome,
          CYDO_LISTEN_PORT: "0",
          CYDO_LOG_LEVEL: "trace",
          CYDO_CLAUDE_BIN: wrapperPath,
          CYDO_REAL_CLAUDE_BIN: "claude",
          ANTHROPIC_BASE_URL: mockApiBaseURL,
          OPENAI_BASE_URL: `${mockApiBaseURL}/v1`,
          CYDO_AUTH_USER: "",
          CYDO_AUTH_PASS: "",
        },
        stdio: ["ignore", "ignore", "pipe"],
      });
      const backendErrRl = createInterface({ input: proc.stderr! });
      backendErrRl.on("line", () => {});

      // Parse actual port from backend stderr
      const port = await parsePortFromLines(
        backendErrRl,
        proc,
        /CyDo server listening on \S+:(\d+)/,
      );
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
        await new Promise((r) => setTimeout(r, 500));
      }
      if (!ready) {
        process.kill(-proc.pid!, "SIGTERM");
        mockProc.kill();
        throw new Error(
          `CyDo extra-fields backend on port ${port} did not start in time`,
        );
      }

      await use({ port, baseURL });

      process.kill(-proc.pid!, "SIGTERM");
      await new Promise<void>((r) => proc.on("exit", r));
      mockProc.kill();
      await new Promise<void>((r) => mockProc.on("exit", r));
      const { rmSync } = await import("fs");
      rmSync(workDir, { recursive: true, force: true });
    },
    { scope: "worker" },
  ],

  baseURL: async ({ backend }, use) => {
    await use(backend.baseURL);
  },

  agentType: async ({}, use, testInfo) => {
    const at = (testInfo.project.use as any).agentType ?? "claude";
    await use(at);
  },

  page: async ({ page }, use) => {
    // No post-test assertions — extra fields are expected in this spec
    await use(page);
  },
});

test("extra fields in tool_result are surfaced", async ({
  page,
  agentType,
}) => {
  test.skip(
    agentType === "codex" || agentType === "copilot",
    "claude-only test",
  );

  await enterSession(page);
  await sendMessage(page, "run command echo test-extra-fields");

  await expect(
    page.locator(".unknown-result-fields", { hasText: "_test_extra_result" }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
});

test("extra fields on assistant message are surfaced", async ({
  page,
  agentType,
}) => {
  test.skip(
    agentType === "codex" || agentType === "copilot",
    "claude-only test",
  );

  await enterSession(page);
  await sendMessage(page, 'reply with "hello"');

  // Use "_test_extra:" (with colon) to avoid matching "_test_extra_block:"
  await expect(
    page.locator(".message.assistant-message .unknown-extra-fields", {
      hasText: "_test_extra:",
    }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
});

test("extra fields on content blocks are surfaced", async ({
  page,
  agentType,
}) => {
  test.skip(
    agentType === "codex" || agentType === "copilot",
    "claude-only test",
  );

  await enterSession(page);
  await sendMessage(page, 'reply with "hello"');

  await expect(
    page.locator(".message.assistant-message .unknown-extra-fields", {
      hasText: "_test_extra_block",
    }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
});

test("extra fields on result event are surfaced", async ({
  page,
  agentType,
}) => {
  test.skip(
    agentType === "codex" || agentType === "copilot",
    "claude-only test",
  );

  await enterSession(page);
  await sendMessage(page, 'reply with "hello"');

  // Result message starts collapsed as a divider; click to expand it
  const resultDivider = page.locator(".result-divider.result-success");
  await resultDivider.first().waitFor({ timeout: responseTimeout(agentType) });
  await resultDivider.first().click();

  await expect(
    page.locator(".message.result-message .unknown-extra-fields", {
      hasText: "_test_extra:",
    }),
  ).toBeVisible();
});
