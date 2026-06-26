import { test as isolatedTest } from "@playwright/test";
import type { Locator } from "@playwright/test";
import type { ChildProcess } from "child_process";
import { execFileSync, spawn } from "child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync } from "fs";
import { join } from "path";

import type { Page } from "./fixtures";
import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
  responseTimeout,
  assistantText,
  lastAssistantText,
} from "./fixtures";

type AgentType = "claude" | "codex" | "copilot";

const BACKEND_URL = "http://localhost:3940";

function currentTaskTid(page: Page): number {
  const match = page.url().match(/\/task\/(\d+)(?:$|[/?#])/);
  if (!match) throw new Error(`Could not extract tid from URL: ${page.url()}`);
  return Number(match[1]);
}

function lookupTaskSession(
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

function findFileRecursive(root: string, predicate: (path: string) => boolean): string | null {
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

function historyPathForTask(tid: number): string {
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

function readHistoryFile(historyPath: string): string {
  if (!existsSync(historyPath))
    throw new Error(`History file does not exist: ${historyPath}`);
  return readFileSync(historyPath, "utf8");
}

function compactRawJson(rawJson: string): string {
  return JSON.stringify(JSON.parse(rawJson) as unknown);
}

async function openRawEditor(page: Page, messageText: string): Promise<string> {
  const assistantMsg = page
    .locator(".message-wrapper")
    .filter({
      has: assistantText(page, messageText),
    })
    .last();
  return openRawEditorForMessageWrapper(page, assistantMsg);
}

async function openRawEditorForUserMessage(page: Page, messageText: string): Promise<string> {
  const userMsg = page
    .locator(".message-wrapper")
    .filter({
      has: page.locator(".message.user-message", { hasText: messageText }),
    })
    .last();
  return openRawEditorForMessageWrapper(page, userMsg);
}

async function openRawEditorForMessageWrapper(page: Page, messageWrapper: Locator): Promise<string> {
  await messageWrapper.hover();

  const viewSourceBtn = messageWrapper.locator(".view-source-btn");
  await expect(viewSourceBtn).toBeVisible({ timeout: 5_000 });
  await viewSourceBtn.click();

  const sourceView = page.locator(".source-view");
  await expect(sourceView).toBeVisible({ timeout: 5_000 });

  const firstEventHeader = sourceView.locator(".source-event-header").first();
  await expect(firstEventHeader).toBeVisible({ timeout: 5_000 });
  await firstEventHeader.click();

  const rawTab = sourceView.locator(".source-tab", { hasText: "Raw" });
  await expect(rawTab).toBeVisible({ timeout: 5_000 });
  await rawTab.click();

  const rawBlock = sourceView.locator(".code-pre-wrap").first();
  await expect(rawBlock).toBeVisible({ timeout: 10_000 });
  await rawBlock.hover();

  const editBtn = rawBlock.locator(".edit-btn");
  await expect(editBtn).toBeVisible({ timeout: 5_000 });
  await editBtn.click();

  const textarea = page.locator(".raw-edit-textarea");
  await expect(textarea).toBeVisible({ timeout: 5_000 });
  return textarea.inputValue();
}

function rewriteFirstMatchingString(
  value: unknown,
  needle: string,
  replacement: string,
): boolean {
  if (typeof value === "string") return false;
  if (Array.isArray(value)) {
    for (let i = 0; i < value.length; i++) {
      const child = value[i];
      if (typeof child === "string" && child.includes(needle)) {
        value[i] = child.replace(needle, replacement);
        return true;
      }
      if (child && typeof child === "object" && rewriteFirstMatchingString(child, needle, replacement))
        return true;
    }
    return false;
  }
  if (!value || typeof value !== "object") return false;
  for (const [key, child] of Object.entries(value)) {
    if (typeof child === "string" && child.includes(needle)) {
      (value as Record<string, unknown>)[key] = child.replace(needle, replacement);
      return true;
    }
    if (child && typeof child === "object" && rewriteFirstMatchingString(child, needle, replacement))
      return true;
  }
  return false;
}

function rewriteVisibleText(rawJson: string, originalText: string, replacement: string): string {
  const parsed = JSON.parse(rawJson) as unknown;
  if (!rewriteFirstMatchingString(parsed, originalText, replacement))
    throw new Error(`Could not find visible text ${originalText} in raw JSON`);
  return JSON.stringify(parsed, null, 2);
}

async function createEditableStoppedSession(page: Page, agentType: AgentType) {
  await enterSession(page);
  await sendMessage(page, "run command echo edit-raw-marker");

  const timeout = responseTimeout(agentType);
  await expect(
    page.locator(".tool-result", { hasText: "edit-raw-marker" }),
  ).toBeVisible({ timeout });
  await expect(lastAssistantText(page, "Done.")).toBeVisible({ timeout });
  await expect
    .poll(() => page.url(), { timeout: 15_000 })
    .toMatch(/\/task\/\d+(?:$|[/?#])/);

  const historyPath = historyPathForTask(currentTaskTid(page));

  await killSession(page, agentType);
  return { historyPath };
}

async function waitForBackend(proc: ChildProcess, timeoutMs = 30_000): Promise<void> {
  const processExited = new Promise<never>((_, reject) => {
    if (proc.exitCode !== null) {
      reject(new Error(`Backend already exited with code ${proc.exitCode}`));
      return;
    }
    proc.on("exit", (code, signal) =>
      reject(
        new Error(
          `Backend exited with ${code}${signal ? ` (signal ${signal})` : ""} before becoming ready`,
        ),
      ),
    );
  });

  const polling = (async () => {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      try {
        const res = await fetch(BACKEND_URL);
        if (res.ok || res.status < 500) return;
      } catch {
        // not ready yet
      }
      await new Promise((r) => setTimeout(r, 300));
    }
    throw new Error(`Backend at ${BACKEND_URL} did not start within ${timeoutMs}ms`);
  })();

  await Promise.race([polling, processExited]);
}

function spawnBackend(workDir: string, workerHome: string): ChildProcess {
  return spawn(process.env.CYDO_BIN!, [], {
    detached: true,
    cwd: workDir,
    env: {
      ...process.env,
      HOME: workerHome,
      CLAUDE_CONFIG_DIR: `${workerHome}/.claude`,
      XDG_DATA_HOME: `${workDir}/data`,
    },
    stdio: ["ignore", "inherit", "inherit"],
  });
}

async function killBackend(proc: ChildProcess): Promise<void> {
  try {
    process.kill(-proc.pid!, "SIGTERM");
  } catch {}
  await new Promise<void>((r) => proc.on("exit", () => r()));
}

function createImportWorkDir(suffix: string): { workDir: string; workerHome: string } {
  const workDir = `/tmp/cydo-edit-raw-import-${suffix}`;
  const workerHome = `${workDir}/home`;
  rmSync(workDir, { recursive: true, force: true });
  mkdirSync(`${workDir}/data`, { recursive: true });
  symlinkSync("/tmp/cydo-test-workspace/defs", `${workDir}/defs`);
  mkdirSync(`${workerHome}/.config/cydo`, { recursive: true });
  return { workDir, workerHome };
}

test("edit raw JSON event persists to disk across reload", async ({
  page,
  agentType,
}) => {
  const { historyPath } = await createEditableStoppedSession(page, agentType);

  const marker = `EDIT_RAW_TEST_${Date.now()}`;
  const currentValue = await openRawEditor(page, "Done.");
  const parsed = JSON.parse(currentValue) as Record<string, unknown>;
  parsed._test_edit_marker = marker;
  await page.locator(".raw-edit-textarea").fill(JSON.stringify(parsed, null, 2));

  await page.locator(".edit-actions .btn-primary").click();

  await expect(lastAssistantText(page, "Done.")).toBeVisible({
    timeout: 15_000,
  });

  const currentFile = readHistoryFile(historyPath);
  expect(currentFile).toContain(marker);

  const reopenedValue = await openRawEditor(page, "Done.");
  expect(reopenedValue).toContain(marker);
});

test("clearing raw JSON deletes the source line instead of writing null", async ({
  page,
  agentType,
}) => {
  const { historyPath } = await createEditableStoppedSession(page, agentType);
  const originalFile = readHistoryFile(historyPath);

  await openRawEditor(page, "Done.");
  await page.locator(".raw-edit-textarea").fill("");
  await page.locator(".edit-actions .btn-primary").click();

  await expect(lastAssistantText(page, "Done.")).not.toBeVisible({
    timeout: 15_000,
  });

  const rewrittenFile = readHistoryFile(historyPath);
  expect(rewrittenFile).not.toContain("\nnull\n");
  expect(rewrittenFile).not.toContain("\nnull");
  expect(rewrittenFile.length).toBeLessThan(originalFile.length);
});

test("editing raw JSON to two top-level objects expands into two history lines", async ({
  page,
  agentType,
}) => {
  const { historyPath } = await createEditableStoppedSession(page, agentType);

  const currentValue = await openRawEditor(page, "Done.");
  const firstText = `EDIT_RAW_MULTI_A_${Date.now()}`;
  const secondText = `EDIT_RAW_MULTI_B_${Date.now()}`;
  const firstObject = rewriteVisibleText(currentValue, "Done.", firstText);
  const secondObject = rewriteVisibleText(currentValue, "Done.", secondText);

  await page
    .locator(".raw-edit-textarea")
    .fill(`${firstObject}\n${secondObject}`);
  await page.locator(".edit-actions .btn-primary").click();

  await expect(lastAssistantText(page, firstText)).toBeVisible({
    timeout: 15_000,
  });
  await expect(lastAssistantText(page, secondText)).toBeVisible({
    timeout: 15_000,
  });

  const rawLines = readHistoryFile(historyPath)
    .split("\n")
    .filter((line) => line.trim().length > 0);
  expect(rawLines.filter((line) => line.includes(firstText))).toHaveLength(1);
  expect(rawLines.filter((line) => line.includes(secondText))).toHaveLength(1);
});

test("invalid raw JSON edit is rejected and leaves the JSONL file unchanged", async ({
  page,
  agentType,
}) => {
  const { historyPath } = await createEditableStoppedSession(page, agentType);
  const originalFile = readHistoryFile(historyPath);

  await openRawEditor(page, "Done.");
  await page.locator(".raw-edit-textarea").fill("null");
  const dialogPromise = page.waitForEvent("dialog").then(async (dialog) => {
    const message = dialog.message();
    await dialog.dismiss();
    return message;
  });
  await page.locator(".edit-actions .btn-primary").click();
  expect(await dialogPromise).toMatch(/Invalid JSON|JSON objects/);

  expect(readHistoryFile(historyPath)).toBe(originalFile);
});

isolatedTest("editing the second identical raw line rewrites that physical JSONL line", { tag: "@claude-only" }, async ({
  page,
}) => {
  const { workDir, workerHome } = createImportWorkDir(`duplicate-${Date.now()}`);
  const projectPath = "/tmp/cydo-test-workspace";
  const mangledPath = projectPath.replace(/\//g, "-");
  const sessionId = "99999999-aaaa-bbbb-cccc-dddddddddddd";
  const claudeProjectsDir = `${workerHome}/.claude/projects/${mangledPath}`;
  mkdirSync(claudeProjectsDir, { recursive: true });

  const duplicatePrompt = "duplicate imported line";
  const duplicatePromptText = (page: Page) =>
    page.locator(".message.user-message .user-text").getByText(duplicatePrompt, {
      exact: true,
    });
  const duplicateRawLine = JSON.stringify({
    type: "user",
    message: { content: duplicatePrompt },
  });
  const historyPath = `${claudeProjectsDir}/${sessionId}.jsonl`;
  writeFileSync(
    historyPath,
    [
      JSON.stringify({
        type: "system",
        subtype: "init",
        session_id: sessionId,
        model: "claude-3-5-sonnet-20241022",
        cwd: projectPath,
      }),
      duplicateRawLine,
      duplicateRawLine,
    ].join("\n") + "\n",
  );
  writeFileSync(
    `${workerHome}/.config/cydo/config.yaml`,
    ["workspaces:", "  testws:", `    root: ${projectPath}`].join("\n") + "\n",
  );

  const proc = spawnBackend(workDir, workerHome);
  try {
    await waitForBackend(proc);
    await page.goto(BACKEND_URL + "/");

    const importableLabel = page.locator(
      ".project-card-sessions .sidebar-item .sidebar-label",
      { hasText: duplicatePrompt },
    );
    await expect(importableLabel).toBeVisible({ timeout: 15_000 });
    await importableLabel.click();

    await expect(duplicatePromptText(page)).toHaveCount(2, {
      timeout: 15_000,
    });

    const duplicateValue = await openRawEditorForUserMessage(page, duplicatePrompt);
    const rawLinesBefore = readHistoryFile(historyPath)
      .split("\n")
      .filter((line) => line.trim().length > 0);
    expect(rawLinesBefore.filter((line) => line === duplicateRawLine)).toHaveLength(2);

    const replacement = `duplicate imported line fixed ${Date.now()}`;
    const rewrittenValue = rewriteVisibleText(duplicateValue, duplicatePrompt, replacement);

    await page.locator(".raw-edit-textarea").fill(rewrittenValue);
    await page.locator(".edit-actions .btn-primary").click();

    await expect(duplicatePromptText(page)).toHaveCount(1, {
      timeout: 15_000,
    });
    await expect(
      page.locator(".message.user-message .user-text").getByText(replacement, {
        exact: true,
      }),
    ).toBeVisible({
      timeout: 15_000,
    });

    const rewrittenLines = readHistoryFile(historyPath)
      .split("\n")
      .filter((line) => line.trim().length > 0);
    const originalIndex = rewrittenLines.indexOf(duplicateRawLine);
    const replacementIndex = rewrittenLines.findIndex((line) => line.includes(replacement));
    expect(rewrittenLines.filter((line) => line === duplicateRawLine)).toHaveLength(1);
    expect(originalIndex).toBeGreaterThanOrEqual(0);
    expect(replacementIndex).toBeGreaterThanOrEqual(0);
    expect(originalIndex).toBeLessThan(replacementIndex);
  } finally {
    await killBackend(proc);
    rmSync(workDir, { recursive: true, force: true });
  }
});

isolatedTest("editing replayed steering raw JSON rewrites the earlier enqueue line", { tag: "@claude-only" }, async ({
  page,
}) => {
  const { workDir, workerHome } = createImportWorkDir(`steering-${Date.now()}`);
  const projectPath = "/tmp/cydo-test-workspace";
  const mangledPath = projectPath.replace(/\//g, "-");
  const sessionId = "88888888-aaaa-bbbb-cccc-eeeeeeeeeeee";
  const claudeProjectsDir = `${workerHome}/.claude/projects/${mangledPath}`;
  mkdirSync(claudeProjectsDir, { recursive: true });

  const steeringPrompt = "queued imported steering";
  const assistantReply = "assistant after steering";
  const enqueueRawLine = JSON.stringify({
    type: "queue-operation",
    operation: "enqueue",
    timestamp: "2026-06-23T00:00:00Z",
    sessionId,
    content: steeringPrompt,
  });
  const dequeueRawLine = JSON.stringify({
    type: "queue-operation",
    operation: "dequeue",
    timestamp: "2026-06-23T00:00:01Z",
    sessionId,
  });
  const assistantRawLine = JSON.stringify({
    type: "assistant",
    message: {
      id: "msg-1",
      content: [{ type: "text", text: assistantReply }],
      model: "claude-3-5-sonnet-20241022",
      usage: { input_tokens: 1, output_tokens: 1 },
    },
  });
  const discoverabilityRawLine = JSON.stringify({
    type: "user",
    message: { content: "import discovery anchor" },
  });
  const historyPath = `${claudeProjectsDir}/${sessionId}.jsonl`;
  writeFileSync(
    historyPath,
    [
      JSON.stringify({
        type: "system",
        subtype: "init",
        session_id: sessionId,
        model: "claude-3-5-sonnet-20241022",
        cwd: projectPath,
      }),
      enqueueRawLine,
      dequeueRawLine,
      assistantRawLine,
      discoverabilityRawLine,
    ].join("\n") + "\n",
  );
  writeFileSync(
    `${workerHome}/.config/cydo/config.yaml`,
    ["workspaces:", "  testws:", `    root: ${projectPath}`].join("\n") + "\n",
  );

  const proc = spawnBackend(workDir, workerHome);
  try {
    await waitForBackend(proc);
    await page.goto(BACKEND_URL + "/");

    const importableLabel = page.locator(".project-card-sessions .sidebar-item .sidebar-label").first();
    await expect(importableLabel).toBeVisible({ timeout: 15_000 });
    await importableLabel.click();

    await expect(page.locator(".message.user-message", { hasText: steeringPrompt })).toBeVisible({
      timeout: 15_000,
    });
    await expect(page.locator(".message.assistant-message", { hasText: assistantReply })).toBeVisible({
      timeout: 15_000,
    });

    const currentValue = await openRawEditorForUserMessage(page, steeringPrompt);
    expect(currentValue).toContain('"operation": "enqueue"');

    const replacement = `queued steering fixed ${Date.now()}`;
    const rewrittenValue = rewriteVisibleText(currentValue, steeringPrompt, replacement);

    await page.locator(".raw-edit-textarea").fill(rewrittenValue);
    await page.locator(".edit-actions .btn-primary").click();

    await expect(page.locator(".message.user-message", { hasText: steeringPrompt })).not.toBeVisible({
      timeout: 15_000,
    });
    await expect(page.locator(".message.user-message", { hasText: replacement })).toBeVisible({
      timeout: 15_000,
    });
    await expect(page.locator(".message.assistant-message", { hasText: assistantReply })).toBeVisible({
      timeout: 15_000,
    });

    const rewrittenLines = readHistoryFile(historyPath)
      .split("\n")
      .filter((line) => line.trim().length > 0);
    expect(rewrittenLines).toHaveLength(5);
    expect(rewrittenLines[1]).toContain(replacement);
    expect(rewrittenLines[1]).toContain('"operation":"enqueue"');
    expect(rewrittenLines[2]).toBe(dequeueRawLine);
    expect(rewrittenLines[3]).toBe(assistantRawLine);
    expect(rewrittenLines[4]).toBe(discoverabilityRawLine);
  } finally {
    await killBackend(proc);
    rmSync(workDir, { recursive: true, force: true });
  }
});
