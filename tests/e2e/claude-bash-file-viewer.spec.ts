import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
  responseTimeout,
  assistantText,
} from "./fixtures";

const request = "run command printf bash-edit-diff-e2e > bash-edit-diff-e2e.txt";
const marker = "bash-edit-diff-e2e";
const basename = "bash-edit-diff-e2e.txt";

test(
  "Bash file diffs open in the viewer and survive history reload",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    const timeout = responseTimeout(agentType);

    await enterSession(page);
    await sendMessage(page, request);
    await expect(assistantText(page, "Done.")).toBeVisible({ timeout });

    await expectBashDiffInViewer(page, timeout);

    await killSession(page, agentType);
    await page.reload();
    await expectBashDiffInViewer(page, timeout);
  },
);

async function expectBashDiffInViewer(
  page: Parameters<typeof enterSession>[0],
  timeout: number,
) {
  const tool = page
    .locator(".tool-call")
    .filter({ has: page.locator(".tool-name", { hasText: "Bash" }) })
    .last();
  const row = tool.locator(".filechange-change", { hasText: basename });

  await expect(row).toHaveCount(1, { timeout });
  await expect(row.locator(".diff-added")).toContainText(marker);

  const viewFile = row.locator(".tool-view-file");
  await expect(viewFile).toHaveCount(1);
  await viewFile.dispatchEvent("click");

  const viewer = page.locator(".file-viewer");
  await expect(viewer).toBeVisible();
  const diffTab = viewer.getByRole("button", { name: "Diff" });
  await diffTab.click();
  await expect(diffTab).toHaveClass(/active/);
  await expect(viewer).toContainText(basename);
  await expect(viewer.locator(".diff-view")).toContainText(marker);
}
