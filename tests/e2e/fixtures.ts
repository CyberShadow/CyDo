import { test as base, expect } from "@playwright/test";
import type { Locator, Page, TestInfo } from "@playwright/test";
import { spawn } from "child_process";
import type { ChildProcess } from "child_process";
import { mkdirSync, symlinkSync } from "fs";

type AgentType = "claude" | "codex" | "copilot";

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
  const timeout = 15_000;
  await expect(page.locator(".btn-banner-archive")).toBeVisible({ timeout });
}

/** Return an appropriate response timeout for the given agent. */
export function responseTimeout(agentType: AgentType): number {
  return agentType === "codex" ? 90_000 : 60_000;
}

type TestFixtures = {
  agentType: AgentType;
  backend: { port: number; baseURL: string; pid: number; wsDir: string };
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
  backend: async ({}, use, testInfo: TestInfo) => {
    const workDir = "/tmp/cydo-backend";
    mkdirSync(`${workDir}/data`, { recursive: true });
    symlinkSync("/tmp/cydo-test-workspace/defs", `${workDir}/defs`);

    const proc = spawn(process.env.CYDO_BIN!, [], {
      detached: true,
      cwd: workDir,
      env: {
        ...process.env,
        XDG_DATA_HOME: `${workDir}/data`,
      },
      stdio: ["ignore", "inherit", "inherit"],
    });

    // Poll for readiness
    const baseURL = "http://localhost:3940";
    for (let i = 0; i < 60; i++) {
      try {
        const res = await fetch(baseURL);
        if (res.ok || res.status < 500) break;
      } catch {
        // not ready yet
      }
      if (proc.exitCode !== null) {
        throw new Error(`CyDo backend exited with code ${proc.exitCode}`);
      }
      await new Promise((r) => setTimeout(r, 500));
    }

    await use({
      port: 3940,
      baseURL,
      pid: proc.pid!,
      wsDir: "/tmp/cydo-test-workspace",
    });

    // Teardown — SIGTERM the process group and wait for exit.
    const exitResult = new Promise<{ code: number | null; signal: string | null }>(
      (r) => proc.on("exit", (code, signal) => r({ code, signal })),
    );
    await killBackend(proc);
    const { signal } = await exitResult;
    const crashSignals = ["SIGSEGV", "SIGABRT", "SIGBUS"];
    if (signal && crashSignals.includes(signal)) {
      throw new Error(`Backend crashed during shutdown: ${signal}`);
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
    page.on("console", (msg) =>
      console.error(`[browser] console.${msg.type()}: ${msg.text()}`),
    );

    await use(page);

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

export { expect } from "@playwright/test";
export type { Page } from "@playwright/test";
export type { AgentType };
