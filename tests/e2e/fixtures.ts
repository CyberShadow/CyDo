import { test as base, expect } from "@playwright/test";
import type { Page, TestInfo } from "@playwright/test";
import { spawn, spawnSync } from "child_process";
import { mkdirSync, cpSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { createInterface } from "readline";
import { join } from "path";

type AgentType = "claude" | "codex" | "copilot";

class LogCollector {
  private lines: { ts: number; source: string; text: string }[] = [];

  push(source: string, text: string) {
    this.lines.push({ ts: Date.now(), source, text });
  }

  flushRaw(): { ts: number; source: string; text: string }[] {
    return this.lines;
  }
}

// Module-level reference so helper functions can push log entries without
// changing their signatures. Safe because workers are separate processes and
// tests within a worker run sequentially.
let currentLogs: LogCollector | null = null;

/** Navigate to the welcome page, click +, and wait for the InputBox to be ready. */
export async function enterSession(page: Page) {
  currentLogs?.push("test", "enterSession");
  await page.goto("/");
  await page.locator('button[title="New task"]').first().click();
  await expect(page.locator(".input-textarea:visible").first()).toBeEnabled({
    timeout: 15_000,
  });
}

/** Send a message from whichever input is currently visible. */
export async function sendMessage(page: Page, text: string) {
  currentLogs?.push("test", `sendMessage: "${text}"`);
  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled({ timeout: 15_000 });
  await input.click();
  await input.fill(text);
  const sendBtn = page.locator(".btn-send:visible").first();
  try {
    await expect(sendBtn).toBeEnabled({ timeout: 2_000 });
  } catch {
    await input.clear();
    await input.pressSequentially(text);
    await expect(sendBtn).toBeEnabled({ timeout: 2_000 });
  }
  await sendBtn.click();
}

/** Kill the active session and wait for it to become inactive. */
export async function killSession(page: Page, agentType: AgentType) {
  currentLogs?.push("test", "killSession");
  await page.locator(".btn-banner-stop").click();
  const timeout = 15_000;
  await expect(page.locator(".btn-banner-archive")).toBeVisible({ timeout });
}

/** Return an appropriate response timeout for the given agent. */
export function responseTimeout(agentType: AgentType): number {
  return agentType === "codex" ? 60_000 : 30_000;
}

type TestFixtures = {
  agentType: AgentType;
  logs: LogCollector;
  backend: { port: number; baseURL: string; pid: number; wsDir: string };
};

// Sequential counter for unique temp directories within a worker.
let _testSeq = 0;

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
 * Extended test fixture that:
 * - Starts a per-test CyDo backend on an OS-assigned port (test-scoped)
 * - Starts a per-test mock API on an OS-assigned port (test-scoped)
 * - Overrides baseURL to point to the per-test backend
 * - Automatically asserts no unknown message types appear during any test
 *
 * Usage: import { test, expect } from "./fixtures" instead of "@playwright/test".
 */
export const test = base.extend<TestFixtures>({
  logs: async ({}, use) => {
    await use(new LogCollector());
  },

  backend: async ({ logs }, use, testInfo: TestInfo) => {
    const seq = testInfo.parallelIndex * 100 + _testSeq++;
    const workDir = `/tmp/cydo-test-${seq}`;
    const workerHome = `${workDir}/home`;

    // Set up working directory with data dir (for SQLite) and defs
    // (task type definitions are loaded relative to CWD)
    mkdirSync(`${workDir}/data`, { recursive: true });
    symlinkSync("/tmp/cydo-test-workspace/defs", `${workDir}/defs`);

    // Create a per-test git workspace so parallel tests don't conflict on
    // task directories (each backend gets unique task paths).
    const wsDir = `${workDir}/workspace`;
    mkdirSync(wsDir, { recursive: true });
    spawnSync("git", ["-C", wsDir, "init", "-q"]);
    spawnSync("git", ["-C", wsDir, "config", "user.email", "test@test"]);
    spawnSync("git", ["-C", wsDir, "config", "user.name", "Test"]);
    writeFileSync(`${wsDir}/README.md`, "test\n");
    spawnSync("git", ["-C", wsDir, "add", "."]);
    spawnSync("git", ["-C", wsDir, "commit", "-qm", "init"]);

    // Write per-test config with unique workspace root to avoid race conditions
    // between parallel tests that would otherwise share /tmp/cydo-test-workspace.
    const agentType = (testInfo.project.use as any).agentType ?? "claude";
    mkdirSync(`${workerHome}/.config/cydo`, { recursive: true });
    writeFileSync(
      `${workerHome}/.config/cydo/config.yaml`,
      `default_agent_type: ${agentType}\nworkspaces:\n  local:\n    root: ${wsDir}\n`,
    );

    // Give each test its own COPILOT_HOME to avoid MCP config file
    // race conditions when multiple tests run concurrently.
    const copilotHome = `${workDir}/copilot-home`;
    mkdirSync(copilotHome, { recursive: true });

    // Per-test CODEX_HOME to avoid contention between parallel tests
    const codexHome = `${workDir}/codex-home`;
    mkdirSync(codexHome, { recursive: true });
    writeFileSync(
      `${codexHome}/config.toml`,
      'model = "codex-mini-latest"\napproval_mode = "full-auto"\n',
    );

    // Start per-test mock API with port 0 (OS-assigned)
    const mockApiServerPath = join(__dirname, "../mock-api/server.mjs");
    const mockProc = spawn(process.execPath, [mockApiServerPath], {
      env: {
        ...process.env,
        MOCK_API_PORT: "0",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    const mockOutRl = createInterface({ input: mockProc.stdout! });
    mockOutRl.on("line", (line) => logs.push("mock-api", line));
    if (mockProc.stderr) {
      const rl = createInterface({ input: mockProc.stderr });
      rl.on("line", (line) => logs.push("mock-api", line));
    }

    // Parse actual port from mock API stdout
    const mockApiPort = await parsePortFromLines(
      mockOutRl,
      mockProc,
      /listening on http:\/\/127\.0\.0\.1:(\d+)/,
    );
    const mockApiBaseURL = `http://127.0.0.1:${mockApiPort}`;

    // Wait for mock API to be ready (poll up to 15s)
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
      await new Promise((r) => setTimeout(r, 500));
    }
    if (!mockReady) {
      mockProc.kill();
      throw new Error(`Mock API on port ${mockApiPort} did not start in time`);
    }

    // Start backend with port 0 (OS-assigned)
    const proc = spawn(process.env.CYDO_BIN!, [], {
      detached: true,
      cwd: workDir,
      env: {
        ...process.env,
        HOME: workerHome,
        CYDO_LISTEN_PORT: "0",
        CYDO_LOG_LEVEL: "trace",
        ANTHROPIC_BASE_URL: mockApiBaseURL,
        OPENAI_BASE_URL: `${mockApiBaseURL}/v1`,
        CYDO_AUTH_USER: "",
        CYDO_AUTH_PASS: "",
        ...(process.env.COPILOT_HOME !== undefined
          ? { COPILOT_HOME: copilotHome }
          : {}),
        CODEX_HOME: codexHome,
      },
      stdio: ["ignore", "ignore", "pipe"],
    });
    const backendErrRl = createInterface({ input: proc.stderr! });
    backendErrRl.on("line", (line) => logs.push("backend", line));

    // Parse actual port from backend stderr
    const port = await parsePortFromLines(
      backendErrRl,
      proc,
      /CyDo server listening on \S+:(\d+)/,
    );
    const baseURL = `http://localhost:${port}`;

    // Wait for ready (poll up to 30s)
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
      throw new Error(`CyDo backend on port ${port} did not start in time`);
    }

    await use({ port, baseURL, pid: proc.pid!, wsDir });

    // Teardown
    process.kill(-proc.pid!, "SIGTERM");
    await new Promise<void>((r) => proc.on("exit", r));
    // Wait for child processes in the group to exit before removing the
    // work directory — the leader exits first, but bwrap/agent children
    // may still be writing JSONL files.
    const pgid = proc.pid!;
    const drainDeadline = Date.now() + 5000;
    while (Date.now() < drainDeadline) {
      try {
        process.kill(-pgid, 0);
        await new Promise((r) => setTimeout(r, 100));
      } catch {
        break;
      }
    }
    mockProc.kill();
    await new Promise<void>((r) => mockProc.on("exit", r));
    rmSync(workDir, { recursive: true, force: true });
  },

  // Override baseURL per test so page.goto("/") uses the right backend
  baseURL: async ({ backend }, use) => {
    await use(backend.baseURL);
  },

  agentType: async ({}, use, testInfo) => {
    const at = (testInfo.project.use as any).agentType ?? "claude";
    await use(at);
  },

  page: async ({ page, logs }, use, testInfo: TestInfo) => {
    currentLogs = logs;

    page.on("console", (msg) =>
      logs.push("browser", `console.${msg.type()}: ${msg.text()}`),
    );
    page.on("request", (req) =>
      logs.push("browser", `→ ${req.method()} ${req.url()}`),
    );
    page.on("framenavigated", (frame) => {
      if (frame === page.mainFrame())
        logs.push("browser", `navigate: ${frame.url()}`);
    });

    await use(page);

    currentLogs = null;
    const rawLogs = logs.flushRaw();
    if (
      rawLogs.length > 0 &&
      (testInfo.status === "failed" || testInfo.status === "timedOut")
    ) {
      await testInfo.attach("server-log", {
        body: JSON.stringify(rawLogs),
        contentType: "application/json",
      });
    }

    // After the test body: assert no unknown message type errors in the DOM.
    const errorMessages = page.locator(".message.system-message pre", {
      hasText: /Unknown message type/,
    });
    const errorCount = await errorMessages.count();
    if (errorCount > 0) {
      const texts: string[] = [];
      for (let i = 0; i < errorCount; i++) {
        texts.push(await errorMessages.nth(i).innerText());
      }
      expect(
        errorCount,
        `Protocol errors in DOM:\n${texts.join("\n---\n")}`,
      ).toBe(0);
    }

    // Also assert no unrecognized agent data messages.
    const unrecognizedMessages = page.locator(".message.system-message pre", {
      hasText: /Unrecognized agent data/,
    });
    const unrecognizedCount = await unrecognizedMessages.count();
    if (unrecognizedCount > 0) {
      const firstMsg = await unrecognizedMessages.first().textContent();
      throw new Error(
        `Found ${unrecognizedCount} unrecognized agent data message(s) in DOM. ` +
          `First: ${firstMsg?.slice(0, 200)}`,
      );
    }

    // Assert no unknown tool result fields rendered — every toolUseResult
    // field should be explicitly categorized per tool.
    const unknownResultFields = page.locator(".unknown-result-fields");
    const unknownResultCount = await unknownResultFields.count();
    if (unknownResultCount > 0) {
      const descriptions: string[] = [];
      for (let i = 0; i < unknownResultCount; i++) {
        descriptions.push(await unknownResultFields.nth(i).innerText());
      }
      expect(
        unknownResultCount,
        `Unknown tool result fields rendered in DOM:\n${descriptions.join("\n---\n")}`,
      ).toBe(0);
    }

    // Assert no unknown extra fields on messages — every agent field should
    // be explicitly listed in the protocol translation known-fields lists.
    const unknownExtraFields = page.locator(".unknown-extra-fields");
    const unknownExtraCount = await unknownExtraFields.count();
    if (unknownExtraCount > 0) {
      const descriptions: string[] = [];
      for (let i = 0; i < unknownExtraCount; i++) {
        descriptions.push(await unknownExtraFields.nth(i).innerText());
      }
      expect(
        unknownExtraCount,
        `Unknown extra fields rendered in DOM:\n${descriptions.join("\n---\n")}`,
      ).toBe(0);
    }
  },
});

export { expect } from "@playwright/test";
export type { Page } from "@playwright/test";
export type { AgentType };
