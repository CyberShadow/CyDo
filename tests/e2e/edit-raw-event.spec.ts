import { execFileSync } from "child_process";
import { existsSync, readFileSync, readdirSync, statSync } from "fs";
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

async function openRawEditor(page: Page, messageText: string): Promise<string> {
  const assistantMsg = page
    .locator(".message-wrapper")
    .filter({
      has: assistantText(page, messageText),
    })
    .last();
  await assistantMsg.hover();

  const viewSourceBtn = assistantMsg.locator(".view-source-btn");
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
