import { test as base } from "@playwright/test";
import { spawn, spawnSync } from "child_process";
import type { ChildProcess } from "child_process";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from "fs";
import { basename, dirname, join, relative } from "path";

import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
  endSession,
  killBackend,
  assistantText,
  responseTimeout,
  lastAssistantText,
  installCydoE2eBridge,
  parseShellThroughBridge,
} from "./fixtures";
import type { Page } from "@playwright/test";
import { writeTestConfig } from "./test-config";
import {
  installExportCdnRoutes,
  readExportCdnFixtures,
} from "./export-cdn-fixtures";

test("export-html creates viewable HTML file", { tag: "@claude-only" }, async ({ page, backend, agentType }, testInfo) => {

  const outputPath = "/tmp/cydo-export-test.html";

  try {
    await enterSession(page);
    await sendMessage(page, 'reply with "export-marker-ok"');
    await expect(lastAssistantText(page, "export-marker-ok")).toBeVisible({
      timeout: responseTimeout(agentType),
    });

    await killSession(page, agentType);

    const tid = await page.locator(".sidebar-item.active").getAttribute("data-tid");
    expect(tid).toBeTruthy();

    const result = spawnSync(
      process.env.CYDO_BIN!,
      ["export-html", tid!, "--output", outputPath],
      {
        env: {
          ...process.env,
          XDG_DATA_HOME: "/tmp/cydo-backend/data",
        },
        encoding: "utf8",
      },
    );
    if (result.status !== 0) {
      throw new Error(`cydo export-html failed (status ${result.status}):\nstdout: ${result.stdout}\nstderr: ${result.stderr}`);
    }

    await installCydoE2eBridge(page);
    const fixtures = readExportCdnFixtures();
    const routeState = await installExportCdnRoutes(page, fixtures);
    const requests: string[] = [];
    page.on("request", (request) => requests.push(request.url()));

    await page.goto(`file://${outputPath}`);

    expect(await parseShellThroughBridge(page, "echo export")).toEqual({
      ok: true,
      source: "echo export",
      commands: [{
        name: "echo",
        argv: ["echo", "export"],
        span: { start: 0, end: 11 },
      }],
    });

    await expect(
      page.locator('[data-testid="assistant-text"]', { hasText: "export-marker-ok" }),
    ).toBeVisible();

    await expect(page.locator(".sidebar-item")).toHaveCount(
      await page.locator(".sidebar-item").count(),
    );
    const sidebarItems = page.locator(".sidebar-item");
    expect(await sidebarItems.count()).toBeGreaterThan(0);

    await expect(page.locator(".input-textarea")).toHaveCount(0);

    const html = readFileSync(outputPath, "utf8");
    const match = html.match(
      /<script id="cydo-export-data" type="application\/json">([\s\S]*?)<\/script>/,
    );
    expect(match).toBeTruthy();
    const data = JSON.parse(match![1]);
    expect(data.tasks.find((t: { tid: number }) => t.tid === Number(tid))?.driver).toBe("claude");

    expect(routeState.unexpectedHttps).toEqual([]);
    expect(routeState.attempts.every((url) => fixtures.byUrl.has(url))).toBe(true);
    expect(routeState.attempts.filter((url) => new URL(url).hostname === "esm.sh")).toEqual([]);
    expect(requests.filter((url) => url.startsWith("file:") && /\.wasm(?:$|[?#])/.test(url))).toEqual([]);

    const parserFixtureFiles = [
      "files/web-tree-sitter/web-tree-sitter.wasm",
      "files/tree-sitter-bash/tree-sitter-bash.wasm",
    ];
    for (const file of parserFixtureFiles) {
      const candidates = fixtures.records.filter((record) => record.file === file);
      const jsDelivr = candidates.filter((record) => new URL(record.url).hostname === "cdn.jsdelivr.net");
      const unpkg = candidates.filter((record) => new URL(record.url).hostname === "unpkg.com");
      const esm = candidates.filter((record) => new URL(record.url).hostname === "esm.sh");
      expect(jsDelivr).toHaveLength(1);
      expect(unpkg).toHaveLength(1);
      expect(esm).toHaveLength(1);

      const jsDelivrIndex = routeState.attempts.indexOf(jsDelivr[0]!.url);
      const unpkgIndex = routeState.attempts.indexOf(unpkg[0]!.url);
      expect(jsDelivrIndex).toBeGreaterThanOrEqual(0);
      expect(unpkgIndex).toBeGreaterThan(jsDelivrIndex);
      expect(routeState.actions.filter((action) => action.url === jsDelivr[0]!.url && action.action === "abort-jsdelivr")).toHaveLength(1);
      expect(routeState.actions.filter((action) => action.url === unpkg[0]!.url && action.action === "fulfill-unpkg")).toHaveLength(1);
      expect(routeState.attempts).not.toContain(esm[0]!.url);
    }

    expect(html).not.toMatch(/\/assets\/(?:web-tree-sitter|tree-sitter-bash)-[^"']+\.wasm/);
    expect(html).not.toContain("data:application/wasm");
    expect(html).not.toMatch(/new URL\(["']web-tree-sitter\.wasm["'],\s*import\.meta\.url\)/);
    for (const record of fixtures.records) {
      expect(html).not.toContain(record.bytes.toString("base64"));
    }
  } finally {
    try {
      unlinkSync(outputPath);
    } catch {
      // file may not exist if export failed
    }
  }
});

test("export-html includes transcript for custom Claude-backed agent", { tag: "@claude-only" }, async ({ page, agentType }) => {
  const outputPath = "/tmp/cydo-export-custom-agent.html";

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

  try {
    await enterSession(page);
    await page.selectOption(".agent-picker", "work-claude");
    await sendMessage(page, 'reply with "custom-export-marker-ok"');
    await expect(lastAssistantText(page, "custom-export-marker-ok")).toBeVisible(
      { timeout: responseTimeout(agentType) },
    );

    await killSession(page, agentType);

    const tid = await page
      .locator(".sidebar-item.active")
      .getAttribute("data-tid");
    expect(tid).toBeTruthy();

    const result = spawnSync(
      process.env.CYDO_BIN!,
      ["export-html", tid!, "--output", outputPath],
      {
        env: {
          ...process.env,
          XDG_DATA_HOME: "/tmp/cydo-backend/data",
        },
        encoding: "utf8",
      },
    );
    if (result.status !== 0) {
      throw new Error(
        `cydo export-html failed (status ${result.status}):\nstdout: ${result.stdout}\nstderr: ${result.stderr}`,
      );
    }

    await page.goto(`file://${outputPath}`);

    await expect(
      page.locator('[data-testid="assistant-text"]', {
        hasText: "custom-export-marker-ok",
      }),
    ).toBeVisible();
  } finally {
    try {
      unlinkSync(outputPath);
    } catch {
      // file may not exist if export failed
    }
  }
});

// ---------------------------------------------------------------------------
// AC23 real-Claude export-html split-profile / missing-profile regression
// tests.
//
// Mirrors custom-claude-agent-lifecycle.spec.ts's AC21 profile-lifecycle
// tests: a separate backend-parent profile (A) from the configured
// work-claude agent's profile (B, later reconfigurable to C). `export-html`
// is a standalone CLI invocation with no live in-memory binding of its
// own — like AC21's own cold-read path, it always resolves the task's
// history against whatever profile is CURRENTLY configured at the moment it
// runs (there is no persisted native path/root to fall back on), so a task
// whose real content lives at B can only be exported successfully while B
// is still current; once reconfigured away, export-html must fail cleanly
// rather than silently substituting the new (or backend-parent) root's
// content.
// ---------------------------------------------------------------------------

type ProfiledClaudeBackend = {
  baseURL: string;
  workDir: string;
  workerHome: string;
  configPath: string;
  backendProfileA: string;
  profileB: string;
  profileC: string;
};

const EXPORT_PROFILE_WORK_DIR = "/tmp/cydo-export-html-profile-lifecycle";
const EXPORT_PROFILE_BASE_URL = "http://localhost:3940";

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
  timeoutMs = 30_000,
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
 * Local backend fixture with a separate backend-parent profile (A) and
 * configured agent profile (B/C). Overrides baseURL so page.goto("/")
 * targets this backend instead of fixtures.ts's fixed /tmp/cydo-backend.
 * Uses its own work dir, distinct from custom-claude-agent-lifecycle.spec.ts's
 * PROFILE_WORK_DIR, so the two specs' fixtures never collide.
 */
const profiledTest = base.extend<{ profileBackend: ProfiledClaudeBackend }>({
  profileBackend: async ({}, use) => {
    const workDir = EXPORT_PROFILE_WORK_DIR;
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

    const proc = spawnProfiledBackend(workDir, workerHome, backendProfileA);
    try {
      await waitForProfiledBackend(EXPORT_PROFILE_BASE_URL, proc);
    } catch (e) {
      try {
        process.kill(-proc.pid!, "SIGTERM");
      } catch {
        // already gone
      }
      throw e;
    }

    await use({
      baseURL: EXPORT_PROFILE_BASE_URL,
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
        type: "system",
        subtype: "init",
        session_id: sessionId,
        model: "claude-3-5-sonnet-20241022",
        cwd,
      }),
      JSON.stringify({
        type: "user",
        message: { content: marker },
      }),
    ].join("\n") + "\n";
  writeFileSync(fullPath, content);
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

function exportHtmlCli(
  profileBackend: ProfiledClaudeBackend,
  tid: string,
  outputPath: string,
): ReturnType<typeof spawnSync> {
  return spawnSync(
    process.env.CYDO_BIN!,
    ["export-html", tid, "--output", outputPath],
    {
      env: {
        ...process.env,
        HOME: profileBackend.workerHome,
        XDG_DATA_HOME: `${profileBackend.workDir}/data`,
      },
      encoding: "utf8",
    },
  );
}

profiledTest(
  "cydo export-html resolves the configured profile B, never backend-parent A, and stops working once reconfigured to C",
  { tag: "@claude-only" },
  async ({ page, profileBackend }) => {
    const liveMarker = "export-split-b-live-marker";
    const poisonMarker = "export-split-a-poison-marker";
    const cwd = "/tmp/cydo-test-workspace";
    const outputPath = `${profileBackend.workDir}/export-b.html`;
    const outputPathAfterReconfigure = `${profileBackend.workDir}/export-b-after-c.html`;

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

    // Adversarial same-session-ID poison under the backend's own parent
    // profile (A): a fallback to A would surface this instead of B's own
    // content.
    writeSameIdPoison(
      profileBackend.backendProfileA,
      relPath,
      sessionId,
      cwd,
      poisonMarker,
    );
    const poisonAContent = readFileSync(
      join(profileBackend.backendProfileA, relPath),
      "utf8",
    );

    await endSession(page);

    try {
      // While work-claude is still configured at B, export succeeds and
      // contains exactly B's content.
      const result = exportHtmlCli(profileBackend, tid, outputPath);
      expect(result.status).toBe(0);

      const html = readFileSync(outputPath, "utf8");
      const match = html.match(
        /<script id="cydo-export-data" type="application\/json">([\s\S]*?)<\/script>/,
      );
      expect(match).toBeTruthy();
      const data = JSON.parse(match![1]);
      expect(
        data.tasks.find((t: { tid: number }) => t.tid === Number(tid))
          ?.driver,
      ).toBe("claude");
      const eventsText = JSON.stringify(data.events[tid]);
      expect(eventsText).toContain(liveMarker);
      expect(eventsText).not.toContain(poisonMarker);

      // Reconfigure work-claude live, from B to C, after the task is
      // already ended (cold). Cold resolution always re-derives the
      // CURRENTLY configured profile (see custom-claude-agent-lifecycle
      // .spec.ts's "real Claude retains live profile B but uses current
      // profile C after End" test for the equivalent live-server proof) —
      // there is no persisted native root to fall back on — so a *second*
      // export attempt for the same task must now fail instead of silently
      // substituting C's (or A's) content for B's.
      initClaudeProfileDir(profileBackend.profileC);
      writeProfileConfig(
        profileBackend.configPath,
        profileBackend.profileC,
        "Profile C",
      );
      await enterSession(page);
      await expect(
        page.locator('.agent-picker option[value="work-claude"]'),
      ).toHaveText("Profile C");

      const resultAfterReconfigure = exportHtmlCli(
        profileBackend,
        tid,
        outputPathAfterReconfigure,
      );
      expect(resultAfterReconfigure.status).toBe(1);
      expect(resultAfterReconfigure.stderr).toContain(
        `Cannot export task ${tid}: session history is unavailable`,
      );
      expect(existsSync(outputPathAfterReconfigure)).toBe(false);

      // Neither the real B file nor the A poison were ever touched.
      expect(readFileOrEmpty(realFile)).toContain(liveMarker);
      expect(
        readFileOrEmpty(join(profileBackend.backendProfileA, relPath)),
      ).toBe(poisonAContent);
    } finally {
      try {
        unlinkSync(outputPath);
      } catch {
        // file may not exist if export failed
      }
      try {
        unlinkSync(outputPathAfterReconfigure);
      } catch {
        // file is not expected to exist — the failed export must never
        // create it
      }
    }
  },
);

profiledTest(
  "cydo export-html fails gracefully instead of producing empty output when the configured profile root is missing",
  { tag: "@claude-only" },
  async ({ page, profileBackend }) => {
    const liveMarker = "export-missing-root-marker";
    const outputPath = `${profileBackend.workDir}/export-missing.html`;

    await enterSession(page);
    await sendMessage(page, `reply with "${liveMarker}"`);
    await expect(assistantText(page, liveMarker)).toBeVisible();

    const tid = await activeTaskTid(page);
    await findNativeJsonlContaining(profileBackend.profileB, liveMarker);

    await endSession(page);

    // Remove the entire configured profile root — work-claude's config
    // still points at it (no reconfigure), but the directory itself is gone.
    rmSync(profileBackend.profileB, { recursive: true, force: true });

    try {
      const result = exportHtmlCli(profileBackend, tid, outputPath);
      expect(result.status).toBe(1);
      expect(result.stderr).toContain(
        `Cannot export task ${tid}: session history is unavailable`,
      );
      expect(existsSync(outputPath)).toBe(false);
    } finally {
      try {
        unlinkSync(outputPath);
      } catch {
        // file is not expected to exist — the failed export must never
        // create it
      }
    }
  },
);
