import { writeFileSync } from "fs";
import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
} from "./fixtures";

test("codex stderr view source keeps tabs and shows agnostic stderr payload", async ({
  page,
  agentType,
  backend,
}) => {
  test.skip(agentType !== "codex", "codex-only stderr regression");

  await enterSession(page);
  await sendMessage(page, "codex filechange create fixture");
  await expect(
    page
      .locator(".message.assistant-message .text-content", {
        hasText: "Done.",
      })
      .last(),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  const fixturePath = `${backend.wsDir}/tmp/codex-fileviewer-create.txt`;
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
  await expect(viewSourceBtn).toBeVisible({ timeout: 5_000 });
  await viewSourceBtn.click();

  const sourceView = page.locator(".source-view").last();
  await expect(sourceView).toBeVisible({ timeout: 5_000 });
  await expect(
    sourceView.locator(".source-tab", { hasText: "Raw" }),
  ).toBeVisible({
    timeout: 5_000,
  });
  const agnosticTab = sourceView.locator(".source-tab", {
    hasText: "Agnostic",
  });
  await expect(agnosticTab).toBeVisible({ timeout: 5_000 });
  await agnosticTab.click();

  await expect(sourceView).toContainText('"type": "process/stderr"', {
    timeout: 5_000,
  });
  await expect(sourceView).toContainText('"text":', { timeout: 5_000 });
});
