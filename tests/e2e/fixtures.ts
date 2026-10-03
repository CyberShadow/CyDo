import { test as base, expect } from "@playwright/test";
import type { Locator, Page, TestInfo } from "@playwright/test";
import { execFileSync, spawn } from "child_process";
import type { ChildProcess } from "child_process";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  statSync,
  symlinkSync,
} from "fs";
import { join } from "path";

type AgentType = "claude" | "codex" | "copilot";

export function currentTaskTid(page: Page): number {
  const match = page.url().match(/\/task\/(\d+)(?:$|[/?#])/);
  if (!match) throw new Error(`Could not extract tid from URL: ${page.url()}`);
  return Number(match[1]);
}

export function lookupTaskSession(
  tid: number,
): { sessionId: string; projectPath: string; agentType: AgentType } {
  const row = execFileSync(
    "sqlite3",
    [
      "/tmp/cydo-backend/data/cydo/cydo.db",
      `SELECT agent_session_id || '|' || project_path || '|' || agent_type FROM tasks WHERE tid = ${tid};`,
    ],
    { encoding: "utf8" },
  ).trim();
  if (row.length === 0) throw new Error(`No task row found for tid ${tid}`);
  const [sessionId, projectPath, agentType] = row.split("|");
  if (!sessionId || !projectPath || !agentType)
    throw new Error(`Incomplete task row for tid ${tid}: ${row}`);
  if (agentType !== "claude" && agentType !== "codex" && agentType !== "copilot")
    throw new Error(`Unexpected agent type ${agentType}`);
  return { sessionId, projectPath, agentType };
}

export function findFileRecursive(
  root: string,
  predicate: (path: string) => boolean,
): string | null {
  for (const entry of readdirSync(root)) {
    const fullPath = join(root, entry);
    const stat = statSync(fullPath);
    if (stat.isDirectory()) {
      const nested = findFileRecursive(fullPath, predicate);
      if (nested) return nested;
      continue;
    }
    if (predicate(fullPath)) return fullPath;
  }
  return null;
}

export function historyPathForTask(tid: number): string {
  const { sessionId, projectPath, agentType } = lookupTaskSession(tid);
  switch (agentType) {
    case "claude":
      return `/tmp/claude-test-home/projects/${projectPath.replace(/\//g, "-")}/${sessionId}.jsonl`;
    case "codex": {
      const path = findFileRecursive(
        "/tmp/codex-test-home/sessions",
        (candidate) =>
          candidate.endsWith(".jsonl") &&
          candidate.endsWith(`${sessionId}.jsonl`),
      );
      if (!path) throw new Error(`Could not find Codex history file for ${sessionId}`);
      return path;
    }
    case "copilot":
      return `/tmp/copilot-test-home/session-state/${sessionId}/events.jsonl`;
  }
}

export function readHistoryFile(historyPath: string): string {
  if (!existsSync(historyPath))
    throw new Error(`History file does not exist: ${historyPath}`);
  return readFileSync(historyPath, "utf8");
}

/** Navigate to the welcome page, click +, and wait for the InputBox to be ready. */
export async function enterSession(page: Page) {
  await page.goto("/");
  await page.locator('button[title="New task"]').first().click();
  await expect(page.locator(".input-textarea:visible").first()).toBeEnabled({
    timeout: 15_000,
  });
}

/** Send a message from whichever input is currently visible. */
export async function sendMessage(page: Page, text: string) {
  const input = page.locator(".input-textarea:visible").first();
  const inputBox = input.locator(
    "xpath=ancestor::div[contains(concat(' ', normalize-space(@class), ' '), ' input-box ')]",
  );
  await expect(input).toBeEnabled({ timeout: 15_000 });
  await input.click();
  await input.fill(text);
  const sendBtn = inputBox.locator(".btn-send");
  try {
    await expect(sendBtn).toBeVisible({ timeout: 2_000 });
    await expect(sendBtn).toBeEnabled({ timeout: 2_000 });
  } catch {
    await input.clear();
    await input.pressSequentially(text);
    await expect(sendBtn).toBeVisible({ timeout: 2_000 });
    await expect(sendBtn).toBeEnabled({ timeout: 2_000 });
  }
  await sendBtn.click();
}

/** Locate top-level assistant text blocks by content (excludes nested tool markdown). */
export function assistantText(
  page: Page,
  textOrRegex: string | RegExp,
): Locator {
  return page.locator('[data-testid="assistant-text"]:visible', {
    hasText: textOrRegex,
  });
}

/** Locate the latest top-level assistant text block that matches content. */
export function lastAssistantText(
  page: Page,
  textOrRegex: string | RegExp,
): Locator {
  return assistantText(page, textOrRegex).last();
}

/** Kill the active session and wait for it to become inactive. */
export async function killSession(page: Page, agentType: AgentType) {
  await page.locator(".btn-banner-stop").click();
  await expect(page.locator(".btn-banner-archive")).toBeVisible();
}

/** Gracefully end the active session (closes stdin) and wait for it to archive. */
export async function endSession(page: Page) {
  await page.locator(".btn-banner-end").click();
  await expect(page.locator(".btn-banner-archive")).toBeVisible();
}

/** Assertion budget for agent responses. Deliberately the shared generous
 * budget (see playwright.config.ts): condition waits return the moment they
 * are satisfied, so this costs nothing on passing runs and stops contention
 * from failing correctness tests. */
export function responseTimeout(_agentType: AgentType): number {
  return 540_000;
}

const MOCK_CONTROL_PORT: Record<AgentType, number> = {
  claude: 9000,
  codex: 9000,
  copilot: 9001,
};

/** A held mock tool-call response (see the hold/release side channel in
 *  tests/mock-api): the mock parks the next response carrying `tool` until
 *  `release()`, so the UI state between the call and its response can be
 *  observed for as long as the test needs, independent of timing. Releasing
 *  before the call arrives lets it stream through unparked. */
export interface MockHold {
  id: string;
  held(): Promise<boolean>;
  release(): Promise<void>;
}

export async function holdMockTool(
  agentType: AgentType,
  tool: string,
): Promise<MockHold> {
  const base = `http://127.0.0.1:${MOCK_CONTROL_PORT[agentType]}`;
  const armed = await fetch(`${base}/mock/hold`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ tool }),
  });
  if (!armed.ok) throw new Error(`mock hold refused: HTTP ${armed.status}`);
  const { id } = (await armed.json()) as { id: string };
  return {
    id,
    async held() {
      const res = await fetch(`${base}/mock/hold/${id}`);
      if (!res.ok) throw new Error(`mock hold lookup failed: HTTP ${res.status}`);
      return ((await res.json()) as { held: boolean }).held;
    },
    async release() {
      const res = await fetch(`${base}/mock/release/${id}`, { method: "POST" });
      if (!res.ok) throw new Error(`mock release failed: HTTP ${res.status}`);
    },
  };
}

export async function visibleHistory(page: Page) {
  return page.locator(".message-wrapper").evaluateAll((wrappers) =>
    wrappers
      .filter((wrapper) => wrapper.querySelector(".message:not(.meta-message)"))
      .map((wrapper) => wrapper.textContent),
  );
}

export async function installCydoE2eBridge(page: Page) {
  await page.addInitScript(() => {
    (window as Window & { __cydoE2e?: object }).__cydoE2e = {};
  });
}

export async function forkThroughBridge(page: Page, tid: number, anchor: string) {
  await page.evaluate(({ tid, anchor }) => {
    if (!window.__cydoE2e?.fork) throw new Error("CyDo e2e fork bridge unavailable");
    window.__cydoE2e.fork(tid, anchor);
  }, { tid, anchor });
}

export async function undoThroughBridge(
  page: Page,
  tid: number,
  anchor: string,
  dryRun: boolean,
  revertFiles: boolean,
) {
  await page.evaluate(({ tid, anchor, dryRun, revertFiles }) => {
    if (!window.__cydoE2e?.undo)
      throw new Error("CyDo e2e undo bridge unavailable");
    window.__cydoE2e.undo(tid, anchor, dryRun, true, revertFiles);
  }, { tid, anchor, dryRun, revertFiles });
}

type TestFixtures = {
  agentType: AgentType;
  backend: { port: number; baseURL: string; pid: number; wsDir: string };
  backendEnv: Record<string, string>;
};

/**
 * Extended test fixture that:
 * - Starts a per-test CyDo backend on fixed port 3940 (test-scoped)
 * - Overrides baseURL to point to the backend
 * - Automatically asserts no unknown message types appear during any test
 *
 * With per-derivation Nix isolation, there is exactly one test running per
 * sandbox. No dynamic ports, unique workdirs, or process group draining needed.
 */
export const test = base.extend<TestFixtures>({
  backendEnv: [{}, { option: true }],

  backend: async ({ backendEnv }, use, testInfo: TestInfo) => {
    const workDir = "/tmp/cydo-backend";
    mkdirSync(`${workDir}/data`, { recursive: true });
    symlinkSync("/tmp/cydo-test-workspace/defs", `${workDir}/defs`);

    const proc = spawn(process.env.CYDO_BIN!, [], {
      detached: true,
      cwd: workDir,
      env: {
        ...process.env,
        ...backendEnv,
        XDG_DATA_HOME: `${workDir}/data`,
      },
      stdio: ["ignore", "inherit", "inherit"],
    });

    // Poll for readiness
    const baseURL = "http://localhost:3940";
    const READY_TIMEOUT_MS = 60_000;
    const pollInterval = 500;
    const maxAttempts = READY_TIMEOUT_MS / pollInterval;
    let ready = false;
    for (let i = 0; i < maxAttempts; i++) {
      try {
        const res = await fetch(baseURL);
        if (res.ok || res.status < 500) {
          ready = true;
          break;
        }
      } catch {
        // not ready yet
      }
      if (proc.exitCode !== null) {
        throw new Error(`CyDo backend exited with code ${proc.exitCode}`);
      }
      await new Promise((r) => setTimeout(r, pollInterval));
    }
    if (!ready) {
      throw new Error(`Backend did not become ready within ${READY_TIMEOUT_MS}ms`);
    }

    await use({
      port: 3940,
      baseURL,
      pid: proc.pid!,
      wsDir: "/tmp/cydo-test-workspace",
    });

    // Teardown — SIGTERM the process group and wait for exit.
    // Acceptable outcomes:
    //   - clean exit (code === 0, signal === null) — backend handled SIGTERM.
    //   - terminated by SIGTERM (signal === "SIGTERM", code === null) — kernel
    //     delivered the signal before the backend's handler ran, or the handler
    //     re-raised. Both are normal.
    // Any other exit (non-zero code, or any other signal) indicates an abnormal
    // shutdown — including uncaught Throwables escaping main() (which exit with
    // a non-zero code and no signal).
    const exitResult = new Promise<{ code: number | null; signal: string | null }>(
      (r) => proc.on("exit", (code, signal) => r({ code, signal })),
    );
    await killBackend(proc);
    const { code, signal } = await exitResult;
    if (signal !== null && signal !== "SIGTERM") {
      throw new Error(`Backend exited with unexpected signal: ${signal}`);
    }
    if (signal === null && code !== 0) {
      throw new Error(`Backend exited abnormally with code ${code} (no signal)`);
    }
  },

  baseURL: async ({ backend }, use) => {
    await use(backend.baseURL);
  },

  agentType: async ({}, use, testInfo) => {
    const at = (testInfo.project.use as any).agentType ?? "claude";
    await use(at);
  },

  page: async ({ page }, use, testInfo: TestInfo) => {
    // page-level waits (waitForEvent and friends) share the assertion budget
    page.setDefaultTimeout(540_000);
    const pageErrors: string[] = [];
    page.on("console", (msg) =>
      console.error(`[browser] console.${msg.type()}: ${msg.text()}`),
    );
    page.on("pageerror", (error) => {
      const stack = error.stack ? `\n${error.stack}` : "";
      pageErrors.push(`${error.name}: ${error.message}${stack}`);
    });

    await use(page);

    if (pageErrors.length > 0) {
      expect(
        pageErrors,
        `Uncaught page errors:\n${pageErrors.join("\n---\n")}`,
      ).toEqual([]);
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

    // Assert no unknown tool result fields rendered.
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

    // Assert no unknown extra fields on messages.
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

test.beforeEach(async ({}, testInfo) => {
  // Tag-based agent gating. testInfo.tags preserves the leading "@" at runtime
  // (it is stripped only in `playwright --list --reporter=json` output).
  const agentType = testInfo.project.name;
  const tags = testInfo.tags;

  const onlyAgents = tags
    .filter((t) => t.startsWith("@") && t.endsWith("-only"))
    .map((t) => t.slice(1, -"-only".length));

  if (onlyAgents.length > 0) {
    test.skip(
      !onlyAgents.includes(agentType),
      `requires one of: ${onlyAgents.join(", ")}`,
    );
  }

  for (const t of tags) {
    if (t.startsWith("@no-")) {
      const forbid = t.slice("@no-".length);
      test.skip(agentType === forbid, `not on ${forbid}`);
    }
  }
});

/** Send SIGTERM to a backend process group and wait for it to exit. */
export async function killBackend(proc: ChildProcess): Promise<void> {
  const exitPromise = new Promise<void>((r) => proc.on("exit", () => r()));
  try {
    process.kill(-proc.pid!, "SIGTERM");
  } catch {
    // already gone
  }
  await exitPromise;
}

/** Read and parse every record from the Codex rollout JSONL for the given task. */
export function codexRolloutRecords(tid: number): any[] {
  const task = lookupTaskSession(tid);
  if (task.agentType !== "codex")
    throw new Error(`Task ${tid} is not a Codex task: ${task.agentType}`);
  const raw = readHistoryFile(historyPathForTask(tid));
  const lines = raw.split("\n");
  // Codex may be mid-append; a file not ending in a newline has a torn final
  // line that would fail JSON.parse, so drop it rather than parse garbage.
  if (!raw.endsWith("\n")) lines.pop();
  return lines.filter((line) => line.length > 0).map((line) => JSON.parse(line));
}

/** The error-branch sibling of openUndoDialogForUserMessage in undo-codex-alive.spec.ts. */
export async function expectUndoRefusalForUserMessage(
  page: Page,
  userText: string,
  expectedMessage: string,
): Promise<void> {
  // Duplicates openUndoDialogForUserMessage's wrapper-locating block rather than
  // sharing it: that helper lives above line 72 of undo-codex-alive.spec.ts,
  // and deduping would delete lines there, renumbering the pinned check attributes.
  const userMsg = page
    .locator(".message-wrapper:visible", {
      has: page.locator(
        ".message.user-message:visible:not(.pending):not(.meta-message)",
        { hasText: userText },
      ),
    })
    .last();
  await userMsg.hover();
  await expect(userMsg.locator(".undo-btn")).toBeVisible();
  await userMsg.locator(".undo-btn").click();
  const errorDialog = page.locator(".command-error-dialog");
  await expect(page.locator(".command-error-message:visible")).toHaveText(
    expectedMessage,
  );
  await errorDialog.getByRole("button", { name: "Dismiss" }).click();
  await expect(errorDialog).not.toBeVisible();
}

export { expect } from "@playwright/test";
export type { Locator, Page } from "@playwright/test";
export type { AgentType };
