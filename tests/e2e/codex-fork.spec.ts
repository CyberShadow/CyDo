import { test as base } from "@playwright/test";
import { spawn } from "child_process";
import type { ChildProcess } from "child_process";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "fs";
import { basename, dirname, join, relative } from "path";
import { writeTestConfig } from "./test-config";
import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
  endSession,
  killBackend,
  responseTimeout,
  visibleHistory,
  installCydoE2eBridge,
  forkThroughBridge,
  codexRolloutRecords,
} from "./fixtures";
import type { Page } from "@playwright/test";

async function snapshotTids(
  page: Parameters<typeof sendMessage>[0],
): Promise<Set<string>> {
  const tids = await page
    .locator(".sidebar-item[data-tid]")
    .evaluateAll((els: Element[]) =>
      els.map((el) => el.getAttribute("data-tid")!),
    );
  return new Set(tids);
}

async function waitForNewTid(
  page: Parameters<typeof sendMessage>[0],
  before: Set<string>,
): Promise<string> {
  let newTid: string | undefined;
  await expect(async () => {
    const tids = await page
      .locator(".sidebar-item[data-tid]")
      .evaluateAll((els: Element[]) =>
        els.map((el) => el.getAttribute("data-tid")!),
      );
    newTid = tids.find((tid: string) => !before.has(tid));
    expect(newTid).toBeTruthy();
  }).toPass();
  return newTid!;
}

async function resumeIfNeeded(page: Parameters<typeof sendMessage>[0]) {
  const resumeBtn = page.locator(".btn-banner-resume:visible").first();
  const visible = await resumeBtn.isVisible().catch(() => false);
  if (visible) {
    await resumeBtn.click();
  }
}

/**
 * End the currently active task's session, scoped to the active pane.
 * Unlike the shared `endSession` fixture, this disambiguates from other
 * still-live tasks whose panes remain mounted (display: none) in the
 * background — see app.tsx's `everLoaded` pane-retention behavior.
 */
async function endActiveSession(page: Page) {
  await page.locator("[style*='display: contents'] .btn-banner-end").click();
  await expect(
    page.locator("[style*='display: contents'] .btn-banner-archive"),
  ).toBeVisible();
}

function activeAssistantText(
  page: Parameters<typeof sendMessage>[0],
  text: string,
) {
  return page
    .locator("[style*='display: contents'] [data-testid='assistant-text']", {
      hasText: text,
    })
    .last();
}

async function activePersistedMessages(page: Page) {
  return page
    .locator(
      "[style*='display: contents'] .message.user-message:not(.pending):not(.meta-message), [style*='display: contents'] .assistant-message",
    )
    .evaluateAll((messages) =>
      messages.map((message) => ({
        role: message.classList.contains("user-message") ? "user" : "assistant",
        text: (message.textContent ?? "").trimEnd(),
      })),
    );
}

function messageWrapper(page: Page, selector: string, text: string) {
  return page
    .locator("[style*='display: contents'] .message-wrapper", {
      has: page.locator(selector, { hasText: text }),
    })
    .last();
}

async function forkFromMessage(page: Page, selector: string, text: string) {
  const message = messageWrapper(page, selector, text);
  await message.hover();
  const fork = message.locator(".fork-btn");
  await expect(fork).toBeVisible();
  await fork.click();
}

async function undoUserMessage(page: Page, text: string) {
  const message = messageWrapper(
    page,
    ".message.user-message:not(.pending):not(.meta-message)",
    text,
  );
  await message.hover();
  await expect(message.locator(".undo-btn")).toBeVisible();
  await message.locator(".undo-btn").click();
  await expect(page.locator(".undo-dialog:visible")).toBeVisible();
  await page.locator(".btn-undo:visible").click();
}

test(
  "codex fork from older turn truncates later history and isolates branches",
  { tag: "@codex-only" },
  async ({ page, agentType }) => {
    await installCydoE2eBridge(page);
    const taskCreatedEvents: Array<{
      tid: number;
      parent_tid?: number;
      relation_type?: string;
    }> = [];
    const frames: any[] = [];
    const frameWaiters: Array<{
      predicate: (frame: any) => boolean;
      resolve: (frame: any) => void;
    }> = [];
    const nextFrame = (predicate: (frame: any) => boolean) =>
      new Promise<any>((resolve) => frameWaiters.push({ predicate, resolve }));

    page.on("websocket", (ws) => {
      ws.on("framereceived", (event) => {
        try {
          const data = JSON.parse(event.payload.toString());
          frames.push(data);
          for (let index = frameWaiters.length - 1; index >= 0; index--) {
            const waiter = frameWaiters[index];
            if (waiter.predicate(data)) {
              frameWaiters.splice(index, 1);
              waiter.resolve(data);
            }
          }
          if (data.type === "task_created") {
            taskCreatedEvents.push({
              tid: data.tid,
              parent_tid: data.parent_tid,
              relation_type: data.relation_type,
            });
          }
        } catch {
          /* ignore non-JSON frames */
        }
      });
    });

    const isCanonicalUserBoundary = (frame: any, tid: number, prompt: string) =>
      frame?.type === "task_history_boundary_replaced" &&
      frame?.tid === tid &&
      frame?.event?.type === "item/started" &&
      frame?.event?.item_type === "user_message" &&
      !frame?.event?.pending &&
      !frame?.event?.is_meta &&
      !frame?.event?.is_synthetic &&
      !frame?.event?.is_sidechain &&
      Array.isArray(frame?.event?.content) &&
      frame.event.content.length === 1 &&
      frame.event.content[0]?.type === "text" &&
      frame.event.content[0]?.text === prompt &&
      frame?.event?.history_boundary?.kind === "user";
    const isSuccessfulTurn = (frame: any, tid: number) =>
      frame?.tid === tid &&
      frame?.event?.type === "turn/result" &&
      frame?.event?.subtype === "success";
    const isHistoryEnd = (frame: any, tid: number) =>
      frame?.type === "task_history_end" && frame?.tid === tid;

    const turnOne = "FORK_OLD_TURN_ONE";
    const turnTwo = "FORK_OLD_TURN_TWO";
    const forkOnly = "FORK_CHILD_ONLY";
    const parentOnly = "FORK_PARENT_ONLY";

    await enterSession(page);
    const before = await snapshotTids(page);

    await sendMessage(page, `Reply exactly with ${turnOne}`);
    const parentTid = Number(await waitForNewTid(page, before));
    expect(parentTid).toBeGreaterThan(0);
    await expect(activeAssistantText(page, turnOne)).toBeVisible({
      timeout: responseTimeout(agentType),
    });

    await sendMessage(page, `Reply exactly with ${turnTwo}`);
    await expect(activeAssistantText(page, turnTwo)).toBeVisible({
      timeout: responseTimeout(agentType),
    });

    await killSession(page, agentType);
    await page.reload();
    await expect(activeAssistantText(page, turnTwo)).toBeVisible({
      timeout: responseTimeout(agentType),
    });

    await expect(async () => {
      const turnOneAssistant = messageWrapper(
        page,
        ".assistant-message",
        turnOne,
      );
      await turnOneAssistant.hover();
      await expect(turnOneAssistant.locator(".fork-btn")).toBeVisible();
    }).toPass();

    await forkFromMessage(page, ".assistant-message", turnOne);

    await expect(async () => {
      const fork = taskCreatedEvents.find(
        (event) =>
          event.relation_type === "fork" && event.parent_tid === parentTid,
      );
      expect(fork).toBeTruthy();
    }).toPass();

    const forkTid = taskCreatedEvents.find(
      (event) =>
        event.relation_type === "fork" && event.parent_tid === parentTid,
    )!.tid;

    await expect(async () => {
      if (!page.url().endsWith(`/task/${forkTid}`)) {
        await page.locator(`.sidebar-item[data-tid="${forkTid}"]`).click();
      }
      await expect(page).toHaveURL(new RegExp(`/task/${forkTid}$`));
    }).toPass();

    await expect(activeAssistantText(page, turnOne)).toBeVisible();
    await expect(
      page.locator(
        "[style*='display: contents'] [data-testid='assistant-text']",
        {
          hasText: turnTwo,
        },
      ),
    ).toHaveCount(0);

    await resumeIfNeeded(page);
    await sendMessage(page, `Reply exactly with ${forkOnly}`);
    await expect(activeAssistantText(page, forkOnly)).toBeVisible({
      timeout: responseTimeout(agentType),
    });

    await page.locator(`.sidebar-item[data-tid="${parentTid}"]`).click();
    await expect(page).toHaveURL(new RegExp(`/task/${parentTid}$`));

    await resumeIfNeeded(page);
    await sendMessage(page, `Reply exactly with ${parentOnly}`);
    await expect(activeAssistantText(page, parentOnly)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    await expect(
      page.locator(
        "[style*='display: contents'] [data-testid='assistant-text']",
        {
          hasText: forkOnly,
        },
      ),
    ).toHaveCount(0);

    await page.locator(`.sidebar-item[data-tid="${forkTid}"]`).click();
    await expect(page).toHaveURL(new RegExp(`/task/${forkTid}$`));
    await expect(activeAssistantText(page, forkOnly)).toBeVisible();
    await expect(
      page.locator(
        "[style*='display: contents'] [data-testid='assistant-text']",
        {
          hasText: parentOnly,
        },
      ),
    ).toHaveCount(0);
    await expect(
      page.locator(
        "[style*='display: contents'] [data-testid='assistant-text']",
        {
          hasText: turnTwo,
        },
      ),
    ).toHaveCount(0);

    await enterSession(page);
    const userBefore = await snapshotTids(page);
    const offlineUser = "FORK_OFFLINE_USER";
    const offlineResponse = "FORK_OFFLINE_USER_RESPONSE";
    const offlineTail = "FORK_OFFLINE_USER_TAIL";
    await sendMessage(page, `Reply exactly with ${turnOne}`);
    const offlineParentTid = await waitForNewTid(page, userBefore);
    await expect(activeAssistantText(page, turnOne)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    const offlinePrompt = `Reply exactly with ${offlineResponse}. Marker ${offlineUser}`;
    const offlineFrameStart = frames.length;
    const offlineCanonical = nextFrame((frame) =>
      isCanonicalUserBoundary(frame, Number(offlineParentTid), offlinePrompt),
    );
    const offlineTurnComplete = nextFrame((frame) =>
      isSuccessfulTurn(frame, Number(offlineParentTid)),
    );
    await sendMessage(page, offlinePrompt);
    await expect(activeAssistantText(page, offlineResponse)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    await Promise.all([offlineCanonical, offlineTurnComplete]);
    await sendMessage(page, `Reply exactly with ${offlineTail}`);
    await expect(activeAssistantText(page, offlineTail)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    await killSession(page, agentType);
    const offlineSetupHistoryEnd = nextFrame((frame) =>
      isHistoryEnd(frame, Number(offlineParentTid)),
    );
    await page.reload();
    await offlineSetupHistoryEnd;
    const offlineParentHistory = await activePersistedMessages(page);
    const offlineTids = await snapshotTids(page);
    const taskCreatedBeforeUnsupported = taskCreatedEvents.length;
    const offlineUserMessage = messageWrapper(
      page,
      ".user-message",
      offlineUser,
    );
    await offlineUserMessage.hover();
    await expect(offlineUserMessage.locator(".fork-btn")).toHaveCount(0);
    const userBoundaries = frames
      .slice(offlineFrameStart)
      .filter((frame) =>
        isCanonicalUserBoundary(frame, Number(offlineParentTid), offlinePrompt),
      );
    expect(userBoundaries).toHaveLength(1);
    const offlineUserAnchor = userBoundaries[0].event.history_boundary.anchor;
    expect(offlineUserAnchor).toMatch(/^line:\d+$/);
    const offlineRollout = codexRolloutRecords(Number(offlineParentTid));
    await forkThroughBridge(page, Number(offlineParentTid), offlineUserAnchor!);
    const forkError = page.locator(".command-error-dialog");
    await expect(forkError).toContainText(
      "Fork failed: message UUID not found in task history",
    );
    await forkError.getByRole("button", { name: "Dismiss" }).click();
    await expect(page).toHaveURL(new RegExp(`/task/${offlineParentTid}$`));
    await expect(activeAssistantText(page, offlineTail)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    expect(
      taskCreatedEvents
        .slice(taskCreatedBeforeUnsupported)
        .filter(
          (event) =>
            event.parent_tid === Number(offlineParentTid) &&
            event.relation_type === "fork",
        ),
    ).toHaveLength(0);
    expect(await snapshotTids(page)).toEqual(offlineTids);
    expect(await activePersistedMessages(page)).toEqual(offlineParentHistory);
    expect(codexRolloutRecords(Number(offlineParentTid))).toEqual(
      offlineRollout,
    );
    const offlineFinalHistoryEnd = nextFrame((frame) =>
      isHistoryEnd(frame, Number(offlineParentTid)),
    );
    await page.reload();
    await offlineFinalHistoryEnd;
    await expect(page).toHaveURL(new RegExp(`/task/${offlineParentTid}$`));
    await expect(activeAssistantText(page, offlineTail)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    expect(await snapshotTids(page)).toEqual(offlineTids);
    expect(await activePersistedMessages(page)).toEqual(offlineParentHistory);
    expect(codexRolloutRecords(Number(offlineParentTid))).toEqual(
      offlineRollout,
    );
  },
);

test(
  "codex does not offer user-boundary forks",
  { tag: "@codex-only" },
  async ({ page, agentType }) => {
    const currentUser = "FORK_CURRENT_USER";
    const currentResponse = "FORK_CURRENT_RESPONSE";
    const earlierUser = "FORK_EARLIER_USER";
    const currentPrompt = `Reply exactly with ${currentResponse}. Marker ${currentUser}`;
    await installCydoE2eBridge(page);
    const taskCreatedEvents: Array<{
      parent_tid?: number;
      relation_type?: string;
    }> = [];
    const frames: any[] = [];
    page.on("websocket", (ws) => {
      ws.on("framereceived", (event) => {
        try {
          const frame = JSON.parse(event.payload.toString());
          frames.push(frame);
          if (frame.type === "task_created") taskCreatedEvents.push(frame);
        } catch {}
      });
    });
    await enterSession(page);
    const before = await snapshotTids(page);

    await sendMessage(page, `Reply exactly with ${earlierUser}`);
    const parentTid = await waitForNewTid(page, before);
    await expect(activeAssistantText(page, earlierUser)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    await expect
      .poll(() =>
        frames.some(
          (frame) =>
            frame?.tid === Number(parentTid) &&
            frame?.event?.type === "turn/result" &&
            frame?.event?.subtype === "success",
        ),
      )
      .toBe(true);
    const currentFrameStart = frames.length;
    await sendMessage(page, currentPrompt);
    await expect(activeAssistantText(page, currentResponse)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    await expect
      .poll(() =>
        frames
          .slice(currentFrameStart)
          .some(
            (frame) =>
              frame?.tid === Number(parentTid) &&
              frame?.event?.type === "turn/result" &&
              frame?.event?.subtype === "success",
          ),
      )
      .toBe(true);
    let userAnchor: string | undefined;
    await expect
      .poll(() => {
        const matches = frames.filter(
          (frame) =>
            frame?.type === "task_history_boundary_replaced" &&
            frame?.tid === Number(parentTid) &&
            frame?.event?.type === "item/started" &&
            frame?.event?.item_type === "user_message" &&
            !frame.event?.pending &&
            !frame.event?.is_meta &&
            !frame.event?.is_synthetic &&
            !frame.event?.is_sidechain &&
            Array.isArray(frame.event?.content) &&
            frame.event.content.length === 1 &&
            frame.event.content[0]?.type === "text" &&
            frame.event.content[0]?.text === currentPrompt &&
            frame?.event?.history_boundary?.kind === "user",
        );
        userAnchor = matches[0]?.event?.history_boundary?.anchor;
        return matches.length;
      })
      .toBe(1);
    expect(userAnchor).toMatch(/^line:\d+$/);

    const userMessage = messageWrapper(page, ".user-message", currentUser);
    await userMessage.hover();
    await expect(userMessage.locator(".fork-btn")).toHaveCount(0);
    const tidsBeforeFork = await snapshotTids(page);

    await forkThroughBridge(page, Number(parentTid), userAnchor!);
    const forkError = page.locator(".command-error-dialog");
    await expect(forkError).toContainText(
      "Fork failed: message UUID not found in task history",
    );
    await forkError.getByRole("button", { name: "Dismiss" }).click();
    expect(await snapshotTids(page)).toEqual(tidsBeforeFork);
    expect(
      taskCreatedEvents.filter(
        (event) =>
          event.parent_tid === Number(parentTid) &&
          event.relation_type === "fork",
      ),
    ).toHaveLength(0);
  },
);

test(
  "codex rejects a forged line anchor without changing parent history",
  { tag: "@codex-only" },
  async ({ page, agentType }) => {
    await installCydoE2eBridge(page);
    const marker = "FORK_FORGED_PARENT";
    const taskCreatedEvents: Array<{
      parent_tid?: number;
      relation_type?: string;
    }> = [];
    page.on("websocket", (ws) => {
      ws.on("framereceived", (event) => {
        try {
          const data = JSON.parse(event.payload.toString());
          if (data.type === "task_created") taskCreatedEvents.push(data);
        } catch {}
      });
    });

    await enterSession(page);
    const before = await snapshotTids(page);
    await sendMessage(page, `Reply exactly with ${marker}`);
    const parentTid = Number(await waitForNewTid(page, before));
    await expect(activeAssistantText(page, marker)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    const parentHistory = await visibleHistory(page);
    const tidsBeforeFork = await snapshotTids(page);

    await forkThroughBridge(page, parentTid, "line:999999");
    const forkError = page.locator(".command-error-dialog");
    await expect(forkError).toContainText(
      "Fork failed: message UUID not found in task history",
    );
    await forkError.getByRole("button", { name: "Dismiss" }).click();
    await expect(forkError).not.toBeVisible();
    expect(await snapshotTids(page)).toEqual(tidsBeforeFork);
    expect(
      taskCreatedEvents.filter(
        (event) =>
          event.parent_tid === parentTid && event.relation_type === "fork",
      ),
    ).toHaveLength(0);
    expect(await visibleHistory(page)).toEqual(parentHistory);
    await page.reload();
    await expect(activeAssistantText(page, marker)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    expect(await visibleHistory(page)).toEqual(parentHistory);
  },
);

test(
  "codex rejects a stale line anchor after dead-session rollback without creating a child",
  { tag: "@codex-only" },
  async ({ page, agentType }) => {
    await installCydoE2eBridge(page);
    const retained = "FORK_STALE_RETAINED";
    const rolledBack = "FORK_STALE_ROLLED_BACK";
    const taskCreatedEvents: Array<{
      parent_tid?: number;
      relation_type?: string;
    }> = [];

    page.on("websocket", (ws) => {
      ws.on("framereceived", (event) => {
        try {
          const data = JSON.parse(event.payload.toString());
          if (data.type === "task_created") taskCreatedEvents.push(data);
        } catch {
          // Ignore non-JSON frames.
        }
      });
    });

    await enterSession(page);
    const before = await snapshotTids(page);
    await sendMessage(page, `Reply exactly with ${retained}`);
    const parentTid = Number(await waitForNewTid(page, before));
    await expect(activeAssistantText(page, retained)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    await sendMessage(page, `Reply exactly with ${rolledBack}`);
    await expect(activeAssistantText(page, rolledBack)).toBeVisible({
      timeout: responseTimeout(agentType),
    });

    const staleMessage = messageWrapper(page, ".assistant-message", rolledBack);
    await staleMessage.hover();
    const staleFork = staleMessage.locator(".fork-btn");
    await expect(staleFork).toBeVisible();
    const staleTid = Number(await staleFork.getAttribute("data-fork-tid"));
    const staleAnchor = await staleFork.getAttribute("data-fork-anchor");
    expect(staleTid).toBe(parentTid);
    expect(staleAnchor).toMatch(/^line:\d+$/);

    await killSession(page, agentType);
    await undoUserMessage(page, rolledBack);
    await expect(
      page.locator(".message.user-message:visible", { hasText: rolledBack }),
    ).toHaveCount(0);
    await page.reload();
    await expect(activeAssistantText(page, retained)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    const tidsBeforeFork = await snapshotTids(page);
    const parentHistory = await visibleHistory(page);

    await forkThroughBridge(page, staleTid, staleAnchor!);
    const forkError = page.locator(".command-error-dialog");
    await expect(forkError).toContainText(
      "Fork failed: message UUID not found in task history",
    );
    await forkError.getByRole("button", { name: "Dismiss" }).click();
    await expect(forkError).not.toBeVisible();
    expect(await snapshotTids(page)).toEqual(tidsBeforeFork);
    expect(
      taskCreatedEvents.filter(
        (event) =>
          event.parent_tid === parentTid && event.relation_type === "fork",
      ),
    ).toHaveLength(0);
    expect(await visibleHistory(page)).toEqual(parentHistory);
    await page.reload();
    await expect(activeAssistantText(page, retained)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    expect(await visibleHistory(page)).toEqual(parentHistory);
  },
);

// ---------------------------------------------------------------------------
// AC23 real-Codex fork profile-lifecycle regression test.
//
// Codex's native fork issues `thread/fork` on the PARENT's own live
// app-server process (CodexAgent.forkSession in
// source/cydo/agent/drivers/codex/package.d) — the child's own rollout is
// written by that same live process into whatever CODEX_HOME (profile B) the
// parent was launched under, not whatever CODEX_HOME is configured later.
// This mirrors custom-claude-agent-lifecycle.spec.ts's AC21 profile-lifecycle
// tests (backend-parent profile A vs. configured agent profile B/C), but
// covers the fork-specific parent/child split that only exists for Codex.
// ---------------------------------------------------------------------------

type ProfiledCodexBackend = {
  baseURL: string;
  workDir: string;
  workerHome: string;
  configPath: string;
  backendProfileA: string;
  profileB: string;
  profileC: string;
};

const CODEX_PROFILE_WORK_DIR = "/tmp/cydo-codex-fork-profile-lifecycle";
const CODEX_PROFILE_BASE_URL = "http://localhost:3940";

/** Minimal CODEX_HOME: config.toml pointed at the mock API, no session state. */
function initCodexProfileDir(dir: string): void {
  mkdirSync(dir, { recursive: true });
  mkdirSync(join(dir, "shell_snapshots"), { recursive: true });
  writeFileSync(
    join(dir, "config.toml"),
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
}

/** Write a complete work-codex config pointed at the given CODEX_HOME. */
function writeCodexProfileConfig(
  configPath: string,
  profileRoot: string,
  displayName: string,
): void {
  writeTestConfig(
    configPath,
    `default_agent: work-codex
agents:
  work-codex:
    driver: codex
    display_name: ${displayName}
    sandbox:
      env:
        CODEX_HOME: ${profileRoot}
workspaces:
  local:
    root: /tmp/cydo-test-workspace
`,
  );
}

function spawnCodexProfiledBackend(
  workDir: string,
  workerHome: string,
  backendProfileA: string,
): ChildProcess {
  return spawn(process.env.CYDO_BIN!, [], {
    detached: true,
    cwd: workDir,
    env: {
      ...process.env,
      HOME: workerHome,
      CODEX_HOME: backendProfileA,
      XDG_DATA_HOME: `${workDir}/data`,
    },
    stdio: ["ignore", "inherit", "inherit"],
  });
}

async function waitForCodexProfiledBackend(
  baseURL: string,
  proc: ChildProcess,
  timeoutMs = 540_000,
): Promise<void> {
  const processExited = new Promise<never>((_, reject) => {
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
  });

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

/**
 * Local restartable backend fixture with a separate backend-parent profile
 * (A) and configured agent profile (B/C), overriding baseURL so
 * page.goto("/") targets this backend instead of fixtures.ts's fixed
 * /tmp/cydo-backend.
 */
const codexProfileTest = base.extend<{ profileBackend: ProfiledCodexBackend }>({
  profileBackend: async ({}, use, testInfo) => {
    test.skip(testInfo.project.name !== "codex", "codex-only regression");

    const workDir = CODEX_PROFILE_WORK_DIR;
    const workerHome = `${workDir}/home`;
    const backendProfileA = `${workDir}/profile-a`;
    const profileB = `${workDir}/profile-b`;
    const profileC = `${workDir}/profile-c`;
    const configPath = `${workerHome}/.config/cydo/config.yaml`;

    rmSync(workDir, { recursive: true, force: true });
    mkdirSync(`${workDir}/data`, { recursive: true });
    symlinkSync("/tmp/cydo-test-workspace/defs", `${workDir}/defs`);
    mkdirSync(`${workerHome}/.config/cydo`, { recursive: true });

    initCodexProfileDir(backendProfileA);
    initCodexProfileDir(profileB);
    writeCodexProfileConfig(configPath, profileB, "Profile B");

    const proc = spawnCodexProfiledBackend(
      workDir,
      workerHome,
      backendProfileA,
    );
    try {
      await waitForCodexProfiledBackend(CODEX_PROFILE_BASE_URL, proc);
    } catch (e) {
      try {
        process.kill(-proc.pid!, "SIGTERM");
      } catch {
        // already gone
      }
      throw e;
    }

    await use({
      baseURL: CODEX_PROFILE_BASE_URL,
      workDir,
      workerHome,
      configPath,
      backendProfileA,
      profileB,
      profileC,
    });

    await killBackend(proc);
  },
  baseURL: async ({ profileBackend }, use) => {
    await use(profileBackend.baseURL);
  },
});

function listRolloutFiles(sessionsDir: string): string[] {
  if (!existsSync(sessionsDir)) return [];
  const matches: string[] = [];
  for (const entry of readdirSync(sessionsDir, {
    recursive: true,
  }) as string[]) {
    if (!entry.endsWith(".jsonl")) continue;
    if (!basename(entry).startsWith("rollout-")) continue;
    matches.push(join(sessionsDir, entry));
  }
  return matches;
}

/** Poll root/sessions for exactly one real Codex rollout JSONL containing marker. */
async function findRolloutJsonlContaining(
  root: string,
  marker: string,
): Promise<string> {
  const sessionsDir = join(root, "sessions");
  let found: string | undefined;
  await expect
    .poll(() => {
      const matches: string[] = [];
      for (const full of listRolloutFiles(sessionsDir)) {
        try {
          if (readFileSync(full, "utf8").includes(marker)) matches.push(full);
        } catch {
          // file may be mid-write; retry on next poll
        }
      }
      found = matches.length === 1 ? matches[0] : undefined;
      return matches.length;
    })
    .toBe(1);
  return found!;
}

function relativeRolloutPath(root: string, realFile: string): string {
  const rel = relative(root, realFile);
  expect(rel.startsWith("sessions/")).toBe(true);
  return rel;
}

function sessionIdFromRollout(path: string): string {
  const firstLine = readFileSync(path, "utf8").split("\n")[0];
  const parsed = JSON.parse(firstLine);
  expect(parsed.type).toBe("session_meta");
  expect(typeof parsed.payload?.id).toBe("string");
  return parsed.payload.id as string;
}

/** Create a valid two-line rollout at the given relative location, same session ID. */
function writeSameIdRolloutPoison(
  root: string,
  relativePath: string,
  sessionId: string,
  cwd: string,
  marker: string,
): void {
  const fullPath = join(root, relativePath);
  mkdirSync(dirname(fullPath), { recursive: true });
  const content =
    [
      JSON.stringify({
        type: "session_meta",
        payload: { id: sessionId, cwd, cli_version: "0.0.0-poison" },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "message",
          role: "user",
          content: [{ type: "input_text", text: marker }],
        },
      }),
    ].join("\n") + "\n";
  writeFileSync(fullPath, content);
}

function rolloutTreeContains(root: string, marker: string): boolean {
  for (const full of listRolloutFiles(join(root, "sessions"))) {
    try {
      if (readFileSync(full, "utf8").includes(marker)) return true;
    } catch {
      // ignore transient read races
    }
  }
  return false;
}

function readFileOrEmpty(path: string): string {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return "";
  }
}

async function openTaskByTid(
  page: Page,
  tid: string,
  timeoutMs = 540_000,
): Promise<void> {
  const row = page.locator(`.sidebar-item[data-tid="${tid}"]`);
  await expect(row).toBeVisible({ timeout: timeoutMs });
  await row.click();
  await expect(row).toHaveClass(/active/, { timeout: timeoutMs });
}

codexProfileTest(
  "codex forked child inherits the parent's live profile, not a later-reconfigured one",
  { tag: "@codex-only" },
  async ({ page, profileBackend }) => {
    const parentMarker = "ac23-fork-parent-marker";
    const laterMarker = "ac23-fork-later-marker";
    const childMarker = "ac23-fork-child-marker";
    const parentPoisonMarker = "ac23-fork-a-parent-poison-marker";
    const childPoisonMarker = "ac23-fork-a-child-poison-marker";
    const cwd = "/tmp/cydo-test-workspace";
    const timeout = responseTimeout("codex");

    await enterSession(page);
    const before = await snapshotTids(page);
    await sendMessage(page, `Reply exactly with ${parentMarker}`);
    const parentTid = await waitForNewTid(page, before);
    await expect(activeAssistantText(page, parentMarker)).toBeVisible({
      timeout,
    });
    await sendMessage(page, `Reply exactly with ${laterMarker}`);
    await expect(activeAssistantText(page, laterMarker)).toBeVisible({
      timeout,
    });

    // The parent's own rollout lands under B, never A or C.
    const parentRollout = await findRolloutJsonlContaining(
      profileBackend.profileB,
      parentMarker,
    );
    const parentRelPath = relativeRolloutPath(
      profileBackend.profileB,
      parentRollout,
    );
    const parentSessionId = sessionIdFromRollout(parentRollout);
    expect(
      rolloutTreeContains(profileBackend.backendProfileA, parentMarker),
    ).toBe(false);
    expect(rolloutTreeContains(profileBackend.profileC, parentMarker)).toBe(
      false,
    );

    // Adversarial same-session-ID poison under the backend's parent profile
    // (A): a fallback to A would surface this instead of B's real content.
    writeSameIdRolloutPoison(
      profileBackend.backendProfileA,
      parentRelPath,
      parentSessionId,
      cwd,
      parentPoisonMarker,
    );

    // Fork from the parent's turn while the parent session is still alive.
    // Exclude parentTid too — reusing the original `before` set alone would
    // let this match parentTid again, since it also satisfies "not in the
    // pre-session baseline".
    await forkFromMessage(page, ".assistant-message", parentMarker);
    const forkTid = await waitForNewTid(page, new Set([...before, parentTid]));
    await expect(page).toHaveURL(new RegExp(`/task/${forkTid}$`));

    // Let the child's copied history (and its dead-state resume banner)
    // fully render before probing for the banner below — mirrors the
    // existing fork test's settle-then-resume ordering.
    await expect(activeAssistantText(page, parentMarker)).toBeVisible();
    await expect(activeAssistantText(page, laterMarker)).toHaveCount(0);

    // Fork materializes the child dead (thread/fork mints the thread on the
    // parent's own live process, but the child task itself still needs a
    // Resume to launch its own live process for further messages). Unlike
    // the existing fork tests above, this fork is taken from a still-LIVE
    // parent process, whose own child launch measurably takes longer to
    // become sendable than a fork of an already-dead/reloaded parent —
    // sendMessage()'s own short built-in grace window isn't enough here, so
    // retry the whole resume-and-send sequence (each step individually
    // bounded, so a stuck step fails fast into the next retry instead of
    // hanging for the full test timeout) until it succeeds.
    await expect(async () => {
      await resumeIfNeeded(page);
      const input = page.locator(".input-textarea:visible").first();
      const inputBox = input.locator(
        "xpath=ancestor::div[contains(concat(' ', normalize-space(@class), ' '), ' input-box ')]",
      );
      await expect(input).toBeEnabled();
      await input.click();
      await input.fill(`Reply exactly with ${childMarker}`);
      const sendBtn = inputBox.locator(".btn-send");
      await expect(sendBtn).toBeVisible();
      await expect(sendBtn).toBeEnabled();
      await sendBtn.click();
    }).toPass();
    await expect(activeAssistantText(page, childMarker)).toBeVisible({
      timeout,
    });

    // The forked child's own (distinct) rollout also lands under B — proof
    // that a live fork binds to the parent's captured launch profile, not
    // whatever CODEX_HOME happens to be configured when the child is used.
    const childRollout = await findRolloutJsonlContaining(
      profileBackend.profileB,
      childMarker,
    );
    expect(childRollout).not.toBe(parentRollout);
    const childRelPath = relativeRolloutPath(
      profileBackend.profileB,
      childRollout,
    );
    const childSessionId = sessionIdFromRollout(childRollout);
    expect(childSessionId).not.toBe(parentSessionId);
    expect(
      rolloutTreeContains(profileBackend.backendProfileA, childMarker),
    ).toBe(false);
    expect(rolloutTreeContains(profileBackend.profileC, childMarker)).toBe(
      false,
    );

    writeSameIdRolloutPoison(
      profileBackend.backendProfileA,
      childRelPath,
      childSessionId,
      cwd,
      childPoisonMarker,
    );

    // Reconfigure work-codex live, from B to C, with no backend restart —
    // done here, while still on the child's own view (no navigation), only
    // after the child's live process has already launched and replied
    // under B. A resume/launch reads whatever profile is CURRENTLY
    // configured at that moment, so reconfiguring any earlier would make
    // the child's own Resume click fail outright (its rollout genuinely
    // lives under B, not C) — this ordering is what makes the end-under-C
    // diagnostic below a meaningful, not self-defeating, check.
    initCodexProfileDir(profileBackend.profileC);
    writeCodexProfileConfig(
      profileBackend.configPath,
      profileBackend.profileC,
      "Profile C",
    );
    await page.waitForTimeout(500);

    // The parent's own pane stays mounted (display: none) in the background
    // alongside the child's — app.tsx keeps every "everLoaded" task's
    // SessionView mounted, toggling `display: contents`/`none` rather than
    // unmounting. Both panes are still live at this point (the parent was
    // never ended), so an unscoped `.btn-banner-end` matches both. Scope to
    // the active pane, mirroring the `[style*='display: contents']` pattern
    // already used elsewhere in this file to disambiguate panes.
    await endActiveSession(page);
    const childDiagnostics = page.locator(
      "[style*='display: contents'] .diagnostic-message.diagnostic-error",
    );
    await expect(childDiagnostics).toHaveCount(1);
    const childDiagText = await childDiagnostics.first().innerText();
    expect(childDiagText).toContain("Failed to load session history");
    // Deterministic, not a race: the fork-materialization callback writes
    // the child's agentSessionId to the fork-time thread ID before the child
    // is ever spawned, and the child's own resume is keyed off that same ID
    // — Codex's thread/resume response handler enforces the returned thread
    // id equals the one it was asked to resume, or throws. So the child can
    // never end up bound to the parent's session id.
    expect(childDiagText).toContain(childSessionId);
    expect(childDiagText).not.toContain(parentSessionId);
    expect(childDiagText).toContain(profileBackend.profileC);
    expect(childDiagText).toContain("work-codex");
    expect(childDiagText).toContain("CODEX_HOME");
    expect(childDiagText).not.toContain(profileBackend.backendProfileA);
    expect(childDiagText).not.toContain(profileBackend.profileB);
    await expect(
      page.locator('[data-testid="assistant-text"]', {
        hasText: childMarker,
      }),
    ).toHaveCount(0);
    expect(readFileOrEmpty(childRollout)).toContain(childMarker);
    expect(rolloutTreeContains(profileBackend.profileC, childMarker)).toBe(
      false,
    );

    // Observe the config-reload acknowledgement via a fresh draft's picker,
    // confirming work-codex is now actually resolved to C.
    await enterSession(page);
    await expect(
      page.locator('.agent-picker option[value="work-codex"]'),
    ).toHaveText("Profile C");

    // Parent remains bound to B and unaffected by the fork, the child's
    // end, the reconfiguration, or the A poison.
    await openTaskByTid(page, parentTid);
    await expect(activeAssistantText(page, parentMarker)).toBeVisible();
    await expect(
      page.locator(".message.user-message", { hasText: parentPoisonMarker }),
    ).toHaveCount(0);

    // End the parent too, then reload once and confirm both diagnostics
    // survive a full page reload (the parent's own requirement per AC23;
    // the child's survival is a bonus check reusing the same code path —
    // both tasks are already dead by the time of this single reload, so
    // reloading the page cannot disturb a live background task).
    await endSession(page);
    await page.reload();

    const parentDiagnostics = page.locator(
      "[style*='display: contents'] .diagnostic-message.diagnostic-error",
    );
    await expect(parentDiagnostics).toHaveCount(1);
    const parentDiagText = await parentDiagnostics.first().innerText();
    expect(parentDiagText).toContain("Failed to load session history");
    expect(parentDiagText).toContain(parentSessionId);
    expect(parentDiagText).toContain(profileBackend.profileC);
    expect(parentDiagText).toContain("work-codex");
    expect(parentDiagText).toContain("CODEX_HOME");
    expect(parentDiagText).not.toContain(profileBackend.backendProfileA);
    expect(parentDiagText).not.toContain(profileBackend.profileB);
    await expect(
      page.locator('[data-testid="assistant-text"]', {
        hasText: parentMarker,
      }),
    ).toHaveCount(0);
    expect(readFileOrEmpty(parentRollout)).toContain(parentMarker);
    expect(rolloutTreeContains(profileBackend.profileC, parentMarker)).toBe(
      false,
    );

    await openTaskByTid(page, forkTid);
    // Scoped to the active pane: by this point both the parent's and the
    // child's SessionView are mounted (app.tsx's `everLoaded` pane-retention
    // behavior keeps ended tasks' panes around, toggling display: none rather
    // than unmounting), so an unscoped selector can transiently match the
    // parent's still-mounted (but hidden) diagnostic before the child's own
    // diagnostic has rendered post-reload.
    const childDiagnosticsAfterReload = page.locator(
      "[style*='display: contents'] .diagnostic-message.diagnostic-error",
    );
    await expect(childDiagnosticsAfterReload).toHaveCount(1);
    const childDiagTextAfterReload = await childDiagnosticsAfterReload
      .first()
      .innerText();
    expect(childDiagTextAfterReload).toContain(
      "Failed to load session history",
    );
    // Same deterministic identity as the live check above — see comment
    // there — surviving a full page reload.
    expect(childDiagTextAfterReload).toContain(childSessionId);
    expect(childDiagTextAfterReload).not.toContain(parentSessionId);
    expect(childDiagTextAfterReload).toContain(profileBackend.profileC);
  },
);
