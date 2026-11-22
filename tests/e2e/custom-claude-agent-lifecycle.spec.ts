import { test as base } from "@playwright/test";
import { spawn, execFileSync, spawnSync } from "child_process";
import type { ChildProcess } from "child_process";
import {
  mkdirSync,
  symlinkSync,
  writeFileSync,
  readFileSync,
  readdirSync,
  existsSync,
  rmSync,
  renameSync,
  unlinkSync,
} from "fs";
import { join, dirname, relative, basename } from "path";

import { writeTestConfig } from "./test-config";

import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
  endSession,
  responseTimeout,
  assistantText,
  lastAssistantText,
  killBackend,
} from "./fixtures";
import type { Page } from "./fixtures";

async function snapshotTids(page: Page): Promise<Set<string>> {
  const tids = await page
    .locator(".sidebar-item[data-tid]")
    .evaluateAll((els: Element[]) =>
      els.map((el) => el.getAttribute("data-tid")!),
    );
  return new Set(tids);
}

async function waitForNewTid(page: Page, before: Set<string>): Promise<string> {
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

test(
  "custom Claude agent keeps configured name across draft, init, and reload",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    writeTestConfig(
      "/tmp/playwright-home/.config/cydo/config.yaml",
      `default_agent: claude
agents:
  claude:
    driver: claude
  work-claude:
    driver: claude
workspaces:
  local:
    root: /tmp/cydo-test-workspace
`,
    );
    await page.waitForTimeout(500);

    const taskUpdatedEvents: Array<{ tid: number; agent_name: string }> = [];
    const initEvents: Array<{ tid: number; agent_name?: string; agent?: string }> =
      [];
    const setAgentNameFrames: Array<{ tid: number; agent_name: string }> = [];
    page.on("websocket", (ws) => {
      ws.on("framesent", (event) => {
        try {
          const data = JSON.parse(event.payload.toString());
          if (
            data.type === "set_agent_name" &&
            typeof data.tid === "number" &&
            typeof data.agent_name === "string"
          ) {
            setAgentNameFrames.push({
              tid: data.tid,
              agent_name: data.agent_name,
            });
          }
        } catch {}
      });
      ws.on("framereceived", (event) => {
        try {
          const data = JSON.parse(event.payload.toString());
          if (data.type === "task_updated" && data.task) {
            taskUpdatedEvents.push({
              tid: data.task.tid,
              agent_name: data.task.agent_name,
            });
          }
          if (
            data.event?.type === "session/init" &&
            typeof data.tid === "number"
          ) {
            initEvents.push({
              tid: data.tid,
              agent_name: data.event.agent_name,
              agent: data.event.agent,
            });
          }
        } catch {}
      });
    });

    await enterSession(page);
    await expect(page.locator(".agent-picker")).toHaveValue("claude");

    const before = await snapshotTids(page);
    const input = page.locator(".input-textarea:visible").first();
    await input.click();
    await input.fill('reply with "custom agent reload transcript test"');

    const draftTid = await waitForNewTid(page, before);
    await expect(
      page.locator(`.sidebar-item[data-tid="${draftTid}"] .draft-label`),
    ).toBeVisible();

    await page.locator(".agent-picker").selectOption("work-claude");
    await expect(page.locator(".agent-picker")).toHaveValue("work-claude");
    const tid = parseInt(draftTid, 10);
    await expect
      .poll(() => setAgentNameFrames.filter((e) => e.tid === tid).at(-1))
      .toMatchObject({
        tid,
        agent_name: "work-claude",
      });
    await page.locator(".btn-send:visible").first().click();

    await expect(
      assistantText(page, "custom agent reload transcript test"),
    ).toBeVisible({ timeout: responseTimeout(agentType) });

    await expect
      .poll(() => taskUpdatedEvents.filter((e) => e.tid === tid).at(-1))
      .toMatchObject({
        tid,
        agent_name: "work-claude",
      });
    await expect
      .poll(() => initEvents.find((e) => e.tid === tid))
      .toMatchObject({
        tid,
        agent_name: "work-claude",
        agent: "claude",
      });

    await killSession(page, agentType);
    await page.reload();

    const sidebarItem = page.locator(`.sidebar-item[data-tid="${draftTid}"]`);
    await expect(sidebarItem).toBeVisible();
    await sidebarItem.click();

    await expect(
      assistantText(page, "custom agent reload transcript test"),
    ).toBeVisible();
    await expect(page.locator(".message.assistant-message")).toHaveCount(1);
    await expect(page.locator(".sidebar-item[data-tid]")).toHaveCount(1);
    await expect(
      page.locator(".sidebar-item.sidebar-archive-node", {
        hasText: /Import/,
      }),
    ).not.toBeVisible();
  },
);

test(
  "cold-loaded Claude Edit renders driver-qualified file viewer after history reload",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    const timeout = responseTimeout(agentType);

    await enterSession(page);

    // Prime Claude's file cache, then edit — Edit tool call with structuredPatch.
    await sendMessage(page, "read file README.md");
    await expect(lastAssistantText(page, "Done.")).toBeVisible({ timeout });
    await sendMessage(page, "edit file README.md replace test with updated");
    await expect(
      page.locator(".tool-call").filter({
        has: page.locator(".tool-name", { hasText: "Edit" }),
      }),
    ).toBeVisible({ timeout });
    await expect(lastAssistantText(page, "Done.")).toBeVisible({ timeout });

    // Force a cold load: on process exit, resetHistoryWatermarkAfterExit
    // (task_runner.d) resets the HistoryStore, dropping the in-memory buffer
    // that held the live session/init. The next request_history — triggered
    // here by reloading the page — re-reads Claude's own JSONL from disk,
    // which has no session/init record, so Block.driver can only come from
    // the task snapshot's resolved driver, not a live session/init.
    await killSession(page, agentType);
    await page.reload();

    const sidebarItem = page.locator(".sidebar-item[data-tid]").first();
    await expect(sidebarItem).toBeVisible();
    await sidebarItem.click();

    const editTool = page.locator(".tool-call").filter({
      has: page.locator(".tool-name", { hasText: "Edit" }),
    });
    await expect(editTool).toBeVisible();

    // The view-file button only renders when the Edit tool call resolves to
    // "claude/Edit" — i.e. only when Block.driver was correctly seeded from
    // the cold-loaded task snapshot.
    await editTool.locator(".tool-header").hover();
    await expect(editTool.locator(".tool-view-file")).toBeVisible();
  },
);

// ---------------------------------------------------------------------------
// AC21/AC22 real-Claude profile-lifecycle regression tests.
//
// These tests separate the backend's parent CLAUDE_CONFIG_DIR (profile A,
// which agent sandbox env normally inherits) from the configured work-claude
// agent's CLAUDE_CONFIG_DIR (profile B, later reconfigured or renamed to C).
// A same-session-ID poison file planted under A (and, for AC22, a stale B)
// makes any accidental fallback to the backend's parent environment or a
// stale root visible, without CyDo ever persisting or exposing the native
// locator itself — every assertion below reads the real Claude CLI's own
// JSONL files or a stopped-backend SQLite snapshot directly.
// ---------------------------------------------------------------------------

type ProfiledClaudeBackend = {
  baseURL: string;
  workDir: string;
  workerHome: string;
  configPath: string;
  backendProfileA: string;
  profileB: string;
  profileC: string;
  stop: () => Promise<void>;
  start: () => Promise<void>;
  restart: () => Promise<void>;
};

const PROFILE_WORK_DIR = "/tmp/cydo-real-claude-profile-lifecycle";
const PROFILE_BASE_URL = "http://localhost:3940";

function initClaudeProfileDir(dir: string): void {
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    join(dir, "settings.json"),
    JSON.stringify({
      hasCompletedOnboarding: true,
      theme: "dark",
      skipDangerousModePermissionPrompt: true,
      autoUpdates: false,
    }),
  );
}

/** Write a complete work-claude config pointed at the given profile root. */
function writeProfileConfig(
  configPath: string,
  profileRoot: string,
  displayName: string,
): void {
  writeTestConfig(
    configPath,
    `default_agent: work-claude
agents:
  work-claude:
    driver: claude
    display_name: ${displayName}
    sandbox:
      env:
        CLAUDE_CONFIG_DIR: ${profileRoot}
workspaces:
  local:
    root: /tmp/cydo-test-workspace
`,
  );
}

function spawnProfiledBackend(
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
      CLAUDE_CONFIG_DIR: backendProfileA,
      XDG_DATA_HOME: `${workDir}/data`,
    },
    stdio: ["ignore", "inherit", "inherit"],
  });
}

async function waitForProfiledBackend(
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
 * (A) and configured agent profile (B/C). Overrides baseURL so page.goto("/")
 * targets this backend instead of fixtures.ts's fixed /tmp/cydo-backend.
 */
const profiledTest = base.extend<{ profileBackend: ProfiledClaudeBackend }>({
  profileBackend: async ({}, use) => {
    const workDir = PROFILE_WORK_DIR;
    const workerHome = `${workDir}/home`;
    const backendProfileA = `${workDir}/profile-a`;
    const profileB = `${workDir}/profile-b`;
    const profileC = `${workDir}/profile-c`;
    const configPath = `${workerHome}/.config/cydo/config.yaml`;

    rmSync(workDir, { recursive: true, force: true });
    mkdirSync(`${workDir}/data`, { recursive: true });
    symlinkSync("/tmp/cydo-test-workspace/defs", `${workDir}/defs`);
    mkdirSync(`${workerHome}/.config/cydo`, { recursive: true });

    initClaudeProfileDir(backendProfileA);
    initClaudeProfileDir(profileB);
    writeProfileConfig(configPath, profileB, "Profile B");

    let proc = spawnProfiledBackend(workDir, workerHome, backendProfileA);
    try {
      await waitForProfiledBackend(PROFILE_BASE_URL, proc);
    } catch (e) {
      try {
        process.kill(-proc.pid!, "SIGTERM");
      } catch {
        // already gone
      }
      throw e;
    }

    let running = true;
    const stop = async () => {
      if (!running) return;
      await killBackend(proc);
      running = false;
    };
    const start = async () => {
      proc = spawnProfiledBackend(workDir, workerHome, backendProfileA);
      await waitForProfiledBackend(PROFILE_BASE_URL, proc);
      running = true;
    };
    const restart = async () => {
      await stop();
      await start();
    };

    await use({
      baseURL: PROFILE_BASE_URL,
      workDir,
      workerHome,
      configPath,
      backendProfileA,
      profileB,
      profileC,
      stop,
      start,
      restart,
    });

    if (running) await killBackend(proc);
  },
  baseURL: async ({ profileBackend }, use) => {
    await use(profileBackend.baseURL);
  },
});

/** Poll root/projects for exactly one real CLI JSONL containing marker. */
async function findNativeJsonlContaining(
  root: string,
  marker: string,
): Promise<string> {
  const projectsDir = join(root, "projects");
  let found: string | undefined;
  await expect
    .poll(
      () => {
        if (!existsSync(projectsDir)) return 0;
        const matches: string[] = [];
        for (const entry of readdirSync(projectsDir, {
          recursive: true,
        }) as string[]) {
          if (!entry.endsWith(".jsonl")) continue;
          const full = join(projectsDir, entry);
          try {
            if (readFileSync(full, "utf8").includes(marker)) matches.push(full);
          } catch {
            // file may be mid-write; retry on next poll
          }
        }
        found = matches.length === 1 ? matches[0] : undefined;
        return matches.length;
      },
    )
    .toBe(1);
  return found!;
}

function relativeNativePath(root: string, realFile: string): string {
  const rel = relative(root, realFile);
  expect(rel.startsWith("projects/")).toBe(true);
  return rel;
}

/** Create a valid two-line native Claude session at the given relative location. */
function writeSameIdPoison(
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
        type: "user",
        cwd,
        sessionId,
        message: { role: "user", content: marker },
      }),
    ].join("\n") + "\n";
  writeFileSync(fullPath, content);
}

function treeContains(root: string, marker: string): boolean {
  const projectsDir = join(root, "projects");
  if (!existsSync(projectsDir)) return false;
  for (const entry of readdirSync(projectsDir, {
    recursive: true,
  }) as string[]) {
    if (!entry.endsWith(".jsonl")) continue;
    try {
      if (readFileSync(join(projectsDir, entry), "utf8").includes(marker))
        return true;
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

async function activeTaskTid(page: Page): Promise<string> {
  const row = page.locator(".sidebar-item.active");
  await expect(row).toBeVisible();
  const tid = await row.getAttribute("data-tid");
  expect(tid).toBeTruthy();
  return tid!;
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

profiledTest(
  "real Claude configured profile B survives End, navigation, reload, restart, and resume",
  { tag: "@claude-only" },
  async ({ page, profileBackend }) => {
    const marker1 = "ac21-b-original-marker";
    const marker2 = "ac21-b-second-marker";
    const poisonMarker = "ac21-a-poison-marker";
    const cwd = "/tmp/cydo-test-workspace";

    await enterSession(page);
    await sendMessage(page, `reply with "${marker1}"`);
    await expect(assistantText(page, marker1)).toBeVisible();

    const tid = await activeTaskTid(page);
    const taskUrl = page.url();

    const realFile = await findNativeJsonlContaining(
      profileBackend.profileB,
      marker1,
    );
    const relPath = relativeNativePath(profileBackend.profileB, realFile);
    const sessionId = basename(realFile, ".jsonl");
    expect(treeContains(profileBackend.backendProfileA, marker1)).toBe(false);

    // Adversarial same-ID poison under the backend's parent profile (A):
    // a fallback to A would surface this rather than B's real content.
    writeSameIdPoison(
      profileBackend.backendProfileA,
      relPath,
      sessionId,
      cwd,
      poisonMarker,
    );

    await endSession(page);
    await expect(assistantText(page, marker1)).toBeVisible();
    await expect(
      page.locator(".message.user-message", { hasText: poisonMarker }),
    ).toHaveCount(0);
    expect(readFileOrEmpty(realFile)).toContain(marker1);

    // Navigate away and back through normal browser navigation.
    await page.goto("/");
    await page.goto(taskUrl);
    await openTaskByTid(page, tid);
    await expect(assistantText(page, marker1)).toBeVisible();
    await expect(
      page.locator(".message.user-message", { hasText: poisonMarker }),
    ).toHaveCount(0);

    // Reload the browser — cold load from B's real JSONL.
    await page.reload();
    await openTaskByTid(page, tid);
    await expect(assistantText(page, marker1)).toBeVisible();
    await expect(
      page.locator(".message.user-message", { hasText: poisonMarker }),
    ).toHaveCount(0);

    // Restart the backend: DB/config/B persist; the unrelated parent A remains.
    await profileBackend.restart();
    await page.goto(taskUrl);
    await openTaskByTid(page, tid);
    await expect(assistantText(page, marker1)).toBeVisible();
    await expect(
      page.locator(".message.user-message", { hasText: poisonMarker }),
    ).toHaveCount(0);

    // Resume, append a second marker, End again.
    await page.locator(".btn-banner-resume").click();
    await expect(page.locator(".btn-banner-stop")).toBeVisible();
    await sendMessage(page, `reply with "${marker2}"`);
    await expect(assistantText(page, marker2)).toBeVisible();
    await endSession(page);

    await expect
      .poll(() => readFileOrEmpty(realFile))
      .toContain(marker2);
    const finalContent = readFileOrEmpty(realFile);
    expect(finalContent).toContain(marker1);
    expect(finalContent).not.toContain(poisonMarker);
    expect(
      readFileOrEmpty(join(profileBackend.backendProfileA, relPath)),
    ).not.toContain(marker2);
  },
);

profiledTest(
  "real Claude retains live profile B but uses current profile C after End",
  { tag: "@claude-only" },
  async ({ page, profileBackend }) => {
    const liveMarker = "ac21-live-b-marker";
    const poisonMarker = "ac21-a-poison-marker-live";
    const cwd = "/tmp/cydo-test-workspace";

    await enterSession(page);
    await sendMessage(page, `reply with "${liveMarker}"`);
    await expect(assistantText(page, liveMarker)).toBeVisible();

    const tid = await activeTaskTid(page);

    const realFile = await findNativeJsonlContaining(
      profileBackend.profileB,
      liveMarker,
    );
    const relPath = relativeNativePath(profileBackend.profileB, realFile);
    const sessionId = basename(realFile, ".jsonl");

    writeSameIdPoison(
      profileBackend.backendProfileA,
      relPath,
      sessionId,
      cwd,
      poisonMarker,
    );
    initClaudeProfileDir(profileBackend.profileC);

    // Reconfigure the (still-live) work-claude agent from B to C.
    writeProfileConfig(
      profileBackend.configPath,
      profileBackend.profileC,
      "Profile C",
    );

    // Observe the config-reload acknowledgement via a fresh draft's picker.
    await enterSession(page);
    await expect(
      page.locator('.agent-picker option[value="work-claude"]'),
    ).toHaveText("Profile C");

    // Return to the still-live original task.
    await openTaskByTid(page, tid);
    await expect(assistantText(page, liveMarker)).toBeVisible();

    await endSession(page);

    // Scoped to :visible: app.tsx keeps every "everLoaded" task's SessionView
    // mounted (display: none when inactive) rather than unmounting, so an
    // unscoped selector could match a hidden pane's diagnostic if another
    // task's diagnostic is ever present in the DOM.
    const diagnostics = page.locator(
      ".diagnostic-message.diagnostic-error:visible",
    );
    await expect(diagnostics).toHaveCount(1);
    const diagText = await diagnostics.first().innerText();
    expect(diagText).toContain("Failed to load session history");
    expect(diagText).toContain(sessionId);
    expect(diagText).toContain(profileBackend.profileC);
    expect(diagText).toContain("work-claude");
    expect(diagText).toContain("CLAUDE_CONFIG_DIR");
    expect(diagText).not.toContain(profileBackend.backendProfileA);
    expect(diagText).not.toContain(profileBackend.profileB);

    await expect(
      page.locator('[data-testid="assistant-text"]', { hasText: liveMarker }),
    ).toHaveCount(0);
    await expect(
      page.locator(".message.user-message", { hasText: poisonMarker }),
    ).toHaveCount(0);

    // Independent filesystem proof: B still has the live marker, C has nothing.
    expect(readFileOrEmpty(realFile)).toContain(liveMarker);
    expect(treeContains(profileBackend.profileC, liveMarker)).toBe(false);
  },
);

profiledTest(
  "real Claude profile rename from B to C preserves task history and discovery ownership",
  { tag: "@claude-only" },
  async ({ page, profileBackend }) => {
    const beforeMarker = "ac22-before-rename";
    const afterMarker = "ac22-after-rename";
    const aPoisonMarker = "ac22-a-poison-marker";
    const bPoisonMarker = "ac22-b-poison-marker";
    const sentinelMarker = "ac22-c-discovery-sentinel";
    const cwd = "/tmp/cydo-test-workspace";

    await enterSession(page);
    await sendMessage(page, `reply with "${beforeMarker}"`);
    await expect(assistantText(page, beforeMarker)).toBeVisible();

    const tid = await activeTaskTid(page);
    const taskUrl = page.url();

    const realFile = await findNativeJsonlContaining(
      profileBackend.profileB,
      beforeMarker,
    );
    const relPath = relativeNativePath(profileBackend.profileB, realFile);
    const sessionId = basename(realFile, ".jsonl");

    await endSession(page);
    await profileBackend.stop();

    const dbPath = `${profileBackend.workDir}/data/cydo/cydo.db`;
    const beforeRow = execFileSync(
      "sqlite3",
      [
        dbPath,
        `SELECT tid, agent_session_id, agent_type, workspace, project_path FROM tasks WHERE tid = ${tid};`,
      ],
      { encoding: "utf8" },
    ).trim();
    const [rowTid, rowSessionId, rowAgentType, rowWorkspace, rowProjectPath] =
      beforeRow.split("|");
    expect(rowTid).toBe(tid);
    expect(rowSessionId).toBe(sessionId);
    expect(rowAgentType).toBe("work-claude");
    expect(rowWorkspace).toBe("local");
    expect(rowProjectPath).toBe(cwd);

    const schemaOut = execFileSync(
      "sqlite3",
      [dbPath, "PRAGMA table_info(tasks);"],
      { encoding: "utf8" },
    );
    const columnNames = schemaOut
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((line) => line.split("|")[1]);
    expect(columnNames).not.toContain("profile_root");
    expect(columnNames).not.toContain("native_history_root");
    expect(columnNames).not.toContain("native_history_path");
    expect(columnNames).toContain("project_path");

    // Rename B → C while the backend is stopped, then recreate poisoned B/A
    // siblings at the same relative location with the same session ID.
    renameSync(profileBackend.profileB, profileBackend.profileC);
    initClaudeProfileDir(profileBackend.profileB);
    writeSameIdPoison(
      profileBackend.profileB,
      relPath,
      sessionId,
      cwd,
      bPoisonMarker,
    );
    writeSameIdPoison(
      profileBackend.backendProfileA,
      relPath,
      sessionId,
      cwd,
      aPoisonMarker,
    );

    // A separate, differently-ID'd, C-only session: the discovery
    // scan-completion sentinel.
    const sentinelId = "22222222-3333-4444-5555-666666666666";
    const sentinelRelPath = join(dirname(relPath), `${sentinelId}.jsonl`);
    writeSameIdPoison(
      profileBackend.profileC,
      sentinelRelPath,
      sentinelId,
      cwd,
      sentinelMarker,
    );

    // Only the configured agent's CLAUDE_CONFIG_DIR changes, B → C.
    writeProfileConfig(
      profileBackend.configPath,
      profileBackend.profileC,
      "Profile B",
    );

    await profileBackend.start();

    await page.goto(taskUrl);
    await openTaskByTid(page, tid);
    await expect(assistantText(page, beforeMarker)).toBeVisible();
    await expect(
      page.locator(".message.user-message", { hasText: aPoisonMarker }),
    ).toHaveCount(0);
    await expect(
      page.locator(".message.user-message", { hasText: bPoisonMarker }),
    ).toHaveCount(0);

    await page.locator(".btn-banner-resume").click();
    await expect(page.locator(".btn-banner-stop")).toBeVisible();
    await sendMessage(page, `reply with "${afterMarker}"`);
    await expect(assistantText(page, afterMarker)).toBeVisible();
    await endSession(page);

    const cFile = join(profileBackend.profileC, relPath);
    await expect
      .poll(() => readFileOrEmpty(cFile))
      .toContain(afterMarker);
    const finalCContent = readFileOrEmpty(cFile);
    expect(finalCContent).toContain(beforeMarker);
    expect(finalCContent).not.toContain(aPoisonMarker);
    expect(finalCContent).not.toContain(bPoisonMarker);

    const aPoisonFile = join(profileBackend.backendProfileA, relPath);
    const bPoisonFile = join(profileBackend.profileB, relPath);
    expect(readFileOrEmpty(aPoisonFile)).not.toContain(afterMarker);
    expect(readFileOrEmpty(bPoisonFile)).not.toContain(afterMarker);

    // Export: the parent CLAUDE_CONFIG_DIR is A, but the current config
    // overrides work-claude to C — export must re-derive C, not A/B.
    const outputPath = "/tmp/cydo-ac22-rename-export.html";
    try {
      const result = spawnSync(
        process.env.CYDO_BIN!,
        ["export-html", tid, "--output", outputPath],
        {
          env: {
            ...process.env,
            HOME: profileBackend.workerHome,
            CLAUDE_CONFIG_DIR: profileBackend.backendProfileA,
            XDG_DATA_HOME: `${profileBackend.workDir}/data`,
          },
          encoding: "utf8",
        },
      );
      if (result.status !== 0) {
        throw new Error(
          `cydo export-html failed (status ${result.status}):\nstdout: ${result.stdout}\nstderr: ${result.stderr}`,
        );
      }
      const html = readFileSync(outputPath, "utf8");
      const match = html.match(
        /<script id="cydo-export-data" type="application\/json">([\s\S]*?)<\/script>/,
      );
      expect(match).toBeTruthy();
      const exportedText = match![1];
      expect(exportedText).toContain(beforeMarker);
      expect(exportedText).toContain(afterMarker);
      expect(exportedText).not.toContain(aPoisonMarker);
      expect(exportedText).not.toContain(bPoisonMarker);
    } finally {
      try {
        unlinkSync(outputPath);
      } catch {
        // file may not exist if export failed
      }
    }

    // Discovery ownership: refresh, then confirm only the C-only sentinel
    // is offered — the unchanged task must own (claude, C, sessionId).
    await page.goto("/");
    const refreshBtn = page.locator('button[title="Refresh project list"]');
    await refreshBtn.click();
    await expect(refreshBtn).toBeDisabled();
    await expect(refreshBtn).toBeEnabled();

    await page.goto(taskUrl);
    const importNode = page.locator(".sidebar-item.sidebar-archive-node", {
      hasText: /Import \(1\)/,
    });
    await expect(importNode).toBeVisible();
    await importNode.click();

    const sentinelEntry = page.locator(".sidebar-item .sidebar-label", {
      hasText: sentinelMarker,
    });
    await expect(sentinelEntry).toBeVisible();
    await expect(
      page.locator(".sidebar-item .sidebar-label", { hasText: aPoisonMarker }),
    ).not.toBeVisible();
    await expect(
      page.locator(".sidebar-item .sidebar-label", { hasText: bPoisonMarker }),
    ).not.toBeVisible();

    // The original task remains a normal resumable task, not importable.
    await openTaskByTid(page, tid);
    await expect(page.locator(".btn-banner-resume")).toBeVisible();
    await expect(
      page.locator(".btn-resume", { hasText: "Import Session" }),
    ).not.toBeVisible();
    await expect(assistantText(page, beforeMarker)).toBeVisible();
    await expect(assistantText(page, afterMarker)).toBeVisible();

    // Stop again and compare the logical row exactly against the pre-rename
    // snapshot — no task-row native locator was ever written.
    await profileBackend.stop();
    const afterRow = execFileSync(
      "sqlite3",
      [
        dbPath,
        `SELECT tid, agent_session_id, agent_type, workspace, project_path FROM tasks WHERE tid = ${tid};`,
      ],
      { encoding: "utf8" },
    ).trim();
    expect(afterRow).toBe(beforeRow);
  },
);
