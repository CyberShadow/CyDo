import { test as base, expect } from "@playwright/test";
import type { Page, WorkerInfo } from "@playwright/test";
import { spawn } from "child_process";
import type { ChildProcess } from "child_process";
import { mkdirSync, cpSync, rmSync, symlinkSync } from "fs";

type AgentType = "claude" | "codex";

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

/** Kill the active session and wait for it to become inactive. */
export async function killSession(page: Page, agentType: AgentType) {
  await page.locator(".btn-banner-stop").click();
  const timeout = 15_000;
  await expect(page.locator(".btn-banner-archive")).toBeVisible({ timeout });
}

/** Return an appropriate response timeout for the given agent. */
export function responseTimeout(agentType: AgentType): number {
  return agentType === "codex" ? 60_000 : 30_000;
}

type WorkerFixtures = {
  backend: { port: number; baseURL: string };
};

/**
 * Extended test fixture that:
 * - Starts a per-worker CyDo backend on a unique port (worker-scoped)
 * - Overrides baseURL to point to the per-worker backend
 * - Automatically asserts no unknown message types appear during any test
 *
 * Usage: import { test, expect } from "./fixtures" instead of "@playwright/test".
 */
export const test = base.extend<{ agentType: AgentType }, WorkerFixtures>({
  backend: [
    async ({}, use: (r: WorkerFixtures["backend"]) => Promise<void>, workerInfo: WorkerInfo) => {
      const port = 4000 + workerInfo.workerIndex;
      const workDir = `/tmp/cydo-worker-${workerInfo.workerIndex}`;
      const workerHome = `${workDir}/home`;

      // Set up working directory with data dir (for SQLite) and defs
      // (task type definitions are loaded relative to CWD)
      mkdirSync(`${workDir}/data`, { recursive: true });
      symlinkSync("/tmp/cydo-test-workspace/defs", `${workDir}/defs`);

      // Copy config from the shared playwright HOME
      mkdirSync(`${workerHome}/.config/cydo`, { recursive: true });
      cpSync(
        "/tmp/playwright-home/.config/cydo/config.yaml",
        `${workerHome}/.config/cydo/config.yaml`,
      );

      // Start backend
      const proc = spawn(process.env.CYDO_BIN!, [], {
        cwd: workDir,
        env: {
          ...process.env,
          HOME: workerHome,
          CYDO_LISTEN_PORT: String(port),
        },
        stdio: ["ignore", "ignore", "inherit"],
      });

      // Wait for ready (poll up to 30s)
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
        proc.kill();
        throw new Error(`CyDo backend on port ${port} did not start in time`);
      }

      await use({ port, baseURL });

      // Teardown
      proc.kill();
      await new Promise<void>((r) => proc.on("exit", r));
      rmSync(workDir, { recursive: true, force: true });
    },
    { scope: "worker" },
  ],

  // Override baseURL per worker so page.goto("/") uses the right backend
  baseURL: async ({ backend }, use) => {
    await use(backend.baseURL);
  },

  agentType: async ({}, use, testInfo) => {
    const at = (testInfo.project.use as any).agentType ?? "claude";
    await use(at);
  },

  page: async ({ page }, use) => {
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
        `Protocol errors in DOM:\n${texts.join("\n---\n")}`
      ).toBe(0);
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
