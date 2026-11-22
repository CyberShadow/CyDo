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
  const diagnostic = "OutputTextDelta without active item";
  const stderrMessage = page.locator(".stderr-message", { hasText: diagnostic });
  await expect(stderrMessage).toBeVisible({ timeout });
  await expect(stderrMessage).toContainText("ERROR", { timeout });

  const stderrWrapper = page
    .locator(".message-wrapper")
    .filter({ has: stderrMessage });
  await stderrWrapper.hover();
  const viewSourceBtn = stderrWrapper.locator(".view-source-btn");
  await expect(viewSourceBtn).toBeVisible();
  await viewSourceBtn.click();

  const sourceView = page.locator(".source-view");
  await expect(sourceView).toBeVisible();

  for (const header of await sourceView.locator(".source-event-header").all()) {
    await header.click();
  }
  const stderrEvent = sourceView.locator(".source-event", {
    hasText: diagnostic,
  });
  await expect(stderrEvent.getByRole("button", { name: "Raw", exact: true }))
    .toBeVisible();
  const abstractTab = stderrEvent.getByRole("button", {
    name: "Abstract",
    exact: true,
  });
  await expect(abstractTab).toBeVisible();
  await abstractTab.click();

  await expect(stderrEvent).toContainText('"type": "process/stderr"');
  await expect(stderrEvent).toContainText('"text":');
});
