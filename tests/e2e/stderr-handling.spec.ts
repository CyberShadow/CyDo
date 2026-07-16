import { existsSync, writeFileSync } from "fs";
import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
} from "./fixtures";

test("codex stderr view source keeps tabs and shows abstract stderr payload", { tag: "@codex-only" }, async ({
  page,
  agentType,
  backend,
}) => {

  await enterSession(page);
  await sendMessage(page, "codex filechange create fixture");
  await expect(
    page
      .locator('[data-testid="assistant-text"]', {
        hasText: "Done.",
      })
      .last(),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  const fixturePath = `${backend.wsDir}/tmp/codex-fileviewer-create.txt`;
  expect(
    existsSync(fixturePath),
    "Codex completed without executing the fixture's apply_patch tool call; check model compatibility and request framing",
  ).toBe(true);
  writeFileSync(fixturePath, "external edit from playwright\n", "utf8");

  await sendMessage(page, "codex filechange update fixture");

  const timeout = responseTimeout(agentType);
  const stderrMessage = page.locator(".stderr-message").last();
  await expect(stderrMessage).toBeVisible({ timeout });
  await expect(page.locator(".stderr-message")).toHaveCount(1, { timeout });
  await expect(stderrMessage).toContainText("ERROR", { timeout });

  const stderrWrapper = page
    .locator(".message-wrapper")
    .filter({ has: stderrMessage })
    .last();
  await stderrWrapper.hover();
  const viewSourceBtn = stderrWrapper.locator(".view-source-btn");
  await expect(viewSourceBtn).toBeVisible();
  await viewSourceBtn.click();

  const sourceView = page.locator(".source-view").last();
  await expect(sourceView).toBeVisible();

  // Expand the first (and likely only) event in the list
  const firstEvent = sourceView.locator(".source-event-header").first();
  await expect(firstEvent).toBeVisible();
  await firstEvent.click();

  // Both tabs should be visible inside the expanded event
  await expect(
    sourceView.locator(".source-tab", { hasText: "Raw" }),
  ).toBeVisible();
  const abstractTab = sourceView.locator(".source-tab", {
    hasText: "Abstract",
  });
  await expect(abstractTab).toBeVisible();
  await abstractTab.click();

  await expect(sourceView).toContainText('"type": "process/stderr"');
  await expect(sourceView).toContainText('"text":');
});
