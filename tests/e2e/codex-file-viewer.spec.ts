import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
  responseTimeout,
} from "./fixtures";

/**
 * Test the full-content chain: create (full_content) + update (patch_text)
 * produces a resolved edit chain. The cumulative view should show the net
 * change from the original empty file to the final content.
 */
test("cumulative diff shows net change after codex create and update", { tag: "@codex-only" }, async ({
  page,
  agentType,
}) => {

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

  // Kill the session and reload: the history is then the one Codex serves.
  await killSession(page, agentType);
  await page.reload();

  // Open file viewer from the last file change (the update).
  // Wait for both create and update tool calls to load before clicking,
  // to avoid clicking the create (first) tool call due to a timing race.
  const tools = page
    .locator(".tool-call")
    .filter({ has: page.locator(".tool-name", { hasText: /fileChange/i }) });
  await expect(tools).toHaveCount(2, { timeout });
  await tools.last().locator(".tool-view-file").dispatchEvent("click");

  await expect(page.locator(".file-viewer")).toBeVisible();

  const contentViewer = page.locator(".file-viewer .content-viewer");

  // Switch to cumulative view.
  await contentViewer.getByRole("button", { name: "Cumulative" }).click();

  // The cumulative diff shows the net change: empty → final content.
  await expect(contentViewer.locator(".diff-view")).toContainText(
    "hello from update fixture",
  );
});

test("live codex fileChange markdown add renders inline preview and rendered viewer tab", { tag: "@codex-only" }, async ({
  page,
  agentType,
}) => {

  await enterSession(page);
  const timeout = responseTimeout(agentType);

  await sendMessage(page, "codex markdown add fixture");
  await expect(
    page.locator('[data-testid="assistant-text"]', { hasText: "Done." }).last(),
  ).toBeVisible({ timeout });

  const tool = page
    .locator(".tool-call")
    .filter({ has: page.locator(".tool-name", { hasText: /fileChange/i }) })
    .last();
  await expect(tool).toBeVisible({ timeout });
  await expect(tool.locator(".write-content-markdown")).toContainText(
    "Inline Preview",
  );

  await tool.locator(".tool-view-file").dispatchEvent("click");
  await expect(page.locator(".file-viewer")).toBeVisible();

  const contentViewer = page.locator(".file-viewer .content-viewer");
  await expect(
    contentViewer.getByRole("button", { name: "Rendered" }),
  ).toHaveClass(/active/);
  await expect(contentViewer.locator(".content-viewer-body")).toContainText(
    "Inline Preview",
  );
});
