import { test, expect, enterSession, sendMessage } from "./fixtures";

test("keep_context continuation injects prompt template", async ({ page, agentType }) => {
  await enterSession(page);

  await sendMessage(page, "call switchmode plan");

  await expect(
    page.locator(".message.user-message", { hasText: "Planning Mode" }),
  ).toBeVisible({ timeout: 30_000 });
});

test("unsent message recovered into input box after kill", async ({ page, agentType }) => {
  // Codex writes turn/steer messages to its JSONL immediately upon receipt (before the
  // LLM responds), so the preReloadDrafts confirmation logic incorrectly marks the steer
  // as "confirmed" even though the LLM never processed it.  The first message also fails
  // to match because codex stores the full rendered prompt template, not the raw text.
  test.skip(agentType === "codex", "codex writes steers to JSONL eagerly; preReloadDrafts mechanism cannot distinguish unprocessed steers");

  await enterSession(page);

  await sendMessage(page, "run command sleep 60");

  await expect(
    page.locator(".tool-call", { hasText: "sleep 60" }),
  ).toBeVisible({ timeout: 30_000 });

  await sendMessage(page, "this should be recovered");

  await page.locator(".btn-banner-stop").click();
  await expect(page.locator(".btn-resume")).toBeVisible({ timeout: 10_000 });

  await page.locator(".btn-resume").click();
  await expect(page.locator(".btn-banner-stop")).toBeVisible({ timeout: 15_000 });

  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toHaveValue("this should be recovered", { timeout: 10_000 });
});

test("handoff continuation exit navigates to grandparent, not completed parent", async ({ page, agentType }) => {

  // Create root task G and enter its session.
  await enterSession(page);

  // G calls Task to create subtask A (type test_handoff).
  // A's prompt is "call handoff done test-prompt" which triggers Handoff immediately.
  // G's fiber blocks waiting for A's result, keeping G alive throughout.
  // The task is created atomically with this first message (activeTaskId === null).
  await sendMessage(page, "call task test_handoff call handoff done test-prompt");

  // Wait for the task URL to settle so we can capture G's tid.
  await expect(page).toHaveURL(/\/[^/]+\/[^/]+\/task\/\d+/, { timeout: 15_000 });
  const tidG = parseInt(page.url().match(/\/[^/]+\/[^/]+\/task\/(\d+)/)?.[1] ?? "0");
  expect(tidG).toBeGreaterThan(0);

  // Wait for subtask A to be created and auto-focused (URL changes away from G).
  await expect(page).not.toHaveURL(new RegExp(`/task/${tidG}$`), { timeout: 15_000 });

  // Flow: A calls Handoff → A completes → continuation C created → C auto-focused
  //        → C responds → C exits → frontend should navigate to G (first alive ancestor)
  //
  // With the bug, it would navigate to A (completed direct parent).
  // With the fix, it walks up through completed A to find alive G.
  await expect(page).toHaveURL(new RegExp(`/task/${tidG}$`), { timeout: 30_000 });
});

test("input box stays empty after mode switch", async ({ page, agentType }) => {
  await enterSession(page);

  await sendMessage(page, "call switchmode plan");

  await expect(
    page.locator(".message.user-message", { hasText: "Planning Mode" }),
  ).toBeVisible({ timeout: 30_000 });

  const input = page.locator(".input-textarea:visible").first();
  await expect(input).toBeEnabled({ timeout: 10_000 });
  await expect(input).toHaveValue("");
});
