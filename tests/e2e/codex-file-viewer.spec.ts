import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
  responseTimeout,
} from "./fixtures";

/**
 * Test the partial-data path: an "update" apply_patch with only a unified diff
 * and no prior create (so no originalFile / currentContent is available).
 * Before the fix, this showed an empty file viewer. After the fix, it shows
 * the diff hunks via PatchView.
 *
 * The mock LLM returns an apply_patch custom tool call. The Codex CLI processes
 * it internally; after the session is killed and history reloads from JSONL,
 * the apply_patch item appears in the frontend as a tool call block.
 */
test("file viewer shows diff content for codex update without prior create", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "codex", "codex-only: partial diff rendering");

  await enterSession(page);
  const timeout = responseTimeout(agentType);

  // Send only the update fixture — no create first.
  // The mock returns apply_patch; Codex processes it internally.
  // The apply_patch is written to the JSONL rollout file but not emitted
  // as a live item event — it only appears after history reload.
  await sendMessage(page, "codex filechange update fixture");
  await expect(
    page.locator('[data-testid="assistant-text"]', { hasText: "Done." }).last(),
  ).toBeVisible({ timeout });

  // Kill the session to trigger task_reload → history reload from JSONL.
  // The JSONL contains the apply_patch entry which translateHistoryLine
  // converts to an item/started event — making it visible as a tool call.
  await killSession(page, agentType);
  await page.reload();

  // After reload, the apply_patch tool call should appear in the history.
  const tool = page
    .locator(".tool-call")
    .filter({ has: page.locator(".tool-name", { hasText: /apply_patch/i }) })
    .last();
  await expect(tool).toBeVisible({ timeout });
  await tool.locator(".tool-view-file").dispatchEvent("click");

  await expect(page.locator(".file-viewer")).toBeVisible({ timeout: 5_000 });
  await expect(page.locator(".file-viewer")).toContainText(
    "codex-fileviewer-create.txt",
  );

  const contentViewer = page.locator(".file-viewer .content-viewer");

  // Source view: PartialSourceView should show new-side lines from the hunk.
  await expect(contentViewer).not.toContainText("Select a file to view");

  // Switch to diff view: PatchView renders the hunks with +/- lines.
  await contentViewer.getByRole("button", { name: "Diff" }).click();
  await expect(contentViewer.locator(".diff-view")).toContainText(
    "hello from update fixture",
  );
});

/**
 * Test the full-content chain: create (full_content) + update (patch_text)
 * produces a resolved edit chain. The cumulative view should show the net
 * change from the original empty file to the final content.
 */
test("cumulative diff shows net change after codex create and update", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "codex", "codex-only: cumulative file viewer");

  await enterSession(page);
  const timeout = responseTimeout(agentType);

  // Create the file first (full_content mode — gives base content).
  await sendMessage(page, "codex filechange create fixture");
  await expect(
    page.locator('[data-testid="assistant-text"]', { hasText: "Done." }).last(),
  ).toBeVisible({ timeout });

  // Update the file (patch_text mode — chains off the create's contentAfter).
  await sendMessage(page, "codex filechange update fixture");
  await expect(
    page.locator('[data-testid="assistant-text"]', { hasText: "Done." }),
  ).toHaveCount(2, { timeout });

  // Kill the session to trigger task_reload → history reload from JSONL.
  await killSession(page, agentType);
  await page.reload();

  // Open file viewer from the last apply_patch tool call (the update).
  // Wait for both create and update tool calls to load before clicking,
  // to avoid clicking the create (first) tool call due to a timing race.
  const tools = page
    .locator(".tool-call")
    .filter({ has: page.locator(".tool-name", { hasText: /apply_patch/i }) });
  await expect(tools).toHaveCount(2, { timeout });
  await tools.last().locator(".tool-view-file").dispatchEvent("click");

  await expect(page.locator(".file-viewer")).toBeVisible({ timeout: 5_000 });

  const contentViewer = page.locator(".file-viewer .content-viewer");

  // Switch to cumulative view.
  await contentViewer.getByRole("button", { name: "Cumulative" }).click();

  // The cumulative diff shows the net change: empty → final content.
  await expect(contentViewer.locator(".diff-view")).toContainText(
    "hello from update fixture",
  );
});

test("rendered markdown view includes all collected partial hunks", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "codex", "codex-only: partial markdown rendering");

  await enterSession(page);
  const timeout = responseTimeout(agentType);

  // Send two update-only patch fixtures for the same Markdown file. There is no
  // full file content available, so the viewer must compose the fragments it has
  // collected from both edits.
  await sendMessage(page, "codex markdown partial first hunk fixture");
  await expect(
    page.locator('[data-testid="assistant-text"]', { hasText: "Done." }).last(),
  ).toBeVisible({ timeout });
  await sendMessage(page, "codex markdown partial second hunk fixture");
  await expect(
    page.locator('[data-testid="assistant-text"]', { hasText: "Done." }),
  ).toHaveCount(2, { timeout });

  // Reload history so the apply_patch tool calls are reconstructed from Codex's
  // rollout file, matching the update-only partial-data path.
  await killSession(page, agentType);
  await page.reload();

  const tools = page
    .locator(".tool-call")
    .filter({ has: page.locator(".tool-name", { hasText: /apply_patch/i }) });
  await expect(tools).toHaveCount(2, { timeout });
  await tools.last().locator(".tool-view-file").dispatchEvent("click");

  const contentViewer = page.locator(".file-viewer .content-viewer");
  await expect(page.locator(".file-viewer")).toBeVisible({ timeout: 5_000 });
  await expect(
    contentViewer.getByRole("button", { name: "Rendered" }),
  ).toHaveClass(/active/);

  const renderedBody = contentViewer.locator(".content-viewer-body");
  await expect(renderedBody).toContainText("second collected fragment");
  await expect(renderedBody).toContainText("first collected fragment");

  await page.locator(".file-viewer .edit-history-item").first().click();
  await expect(renderedBody).toContainText("first collected fragment");
  await expect(renderedBody).not.toContainText("second collected fragment");
});
