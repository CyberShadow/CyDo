import { test as base, expect } from "@playwright/test";
import type { Page, WorkerInfo } from "@playwright/test";
import { spawn } from "child_process";
import type { ChildProcess } from "child_process";
import { mkdirSync, cpSync, symlinkSync } from "fs";
import * as path from "path";
import { enterSession, sendMessage, responseTimeout } from "./fixtures";

type WorkerFixtures = {
  backend: { port: number; baseURL: string };
};

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
      const port = 4100 + workerInfo.workerIndex;
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

      const proc = spawn(process.env.CYDO_BIN!, [], {
        cwd: workDir,
        env: {
          ...process.env,
          HOME: workerHome,
          CYDO_LISTEN_PORT: String(port),
          CYDO_CLAUDE_BIN: wrapperPath,
          CYDO_REAL_CLAUDE_BIN: "claude",
        },
        stdio: ["ignore", "ignore", "inherit"],
      });

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
        throw new Error(
          `CyDo extra-fields backend on port ${port} did not start in time`,
        );
      }

      await use({ port, baseURL });

      proc.kill();
      await new Promise<void>((r) => proc.on("exit", r));
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
  test.skip(agentType === "codex", "claude-only test");

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
  test.skip(agentType === "codex", "claude-only test");

  await enterSession(page);
  await sendMessage(page, 'reply with "hello"');

  await expect(
    page.locator(".message.assistant-message .unknown-extra-fields", {
      hasText: "_test_extra",
    }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
});

test("extra fields on content blocks are surfaced", async ({
  page,
  agentType,
}) => {
  test.skip(agentType === "codex", "claude-only test");

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
  test.skip(agentType === "codex", "claude-only test");

  await enterSession(page);
  await sendMessage(page, 'reply with "hello"');

  await expect(
    page.locator(".message.result-message .unknown-extra-fields", {
      hasText: "_test_extra",
    }),
  ).toBeVisible({ timeout: responseTimeout(agentType) });
});
