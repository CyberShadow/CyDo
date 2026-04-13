import { test, expect, enterSession, sendMessage, killSession, responseTimeout } from "./fixtures";

test("edit raw JSON event persists to disk and is visible to resumed agent", async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  await sendMessage(page, 'reply with "pre-edit-marker"');

  const timeout = responseTimeout(agentType);

  // Wait for the response so we have a complete turn in history
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "pre-edit-marker" }),
  ).toBeVisible({ timeout });

  // Stop the session so we can edit
  await killSession(page, agentType);

  // Find the assistant message and open source view
  const assistantMsg = page
    .locator(".message-wrapper")
    .filter({
      has: page.locator(".message.assistant-message .text-content", { hasText: "pre-edit-marker" }),
    })
    .last();
  await assistantMsg.hover();

  const viewSourceBtn = assistantMsg.locator(".view-source-btn");
  await expect(viewSourceBtn).toBeVisible({ timeout: 5_000 });
  await viewSourceBtn.click();

  // The source view should show a collapsible event list
  const sourceView = assistantMsg.locator(".source-view");
  await expect(sourceView).toBeVisible({ timeout: 5_000 });

  // Expand the first event
  const firstEventHeader = sourceView.locator(".source-event-header").first();
  await expect(firstEventHeader).toBeVisible({ timeout: 5_000 });
  await firstEventHeader.click();

  // Switch to Raw tab inside the expanded event
  const rawTab = sourceView.locator(".source-tab", { hasText: "Raw" });
  await expect(rawTab).toBeVisible({ timeout: 5_000 });
  await rawTab.click();

  // Wait for raw JSON to load
  const rawBlock = sourceView.locator(".code-pre-wrap").first();
  await expect(rawBlock).toBeVisible({ timeout: 10_000 });

  // Hover over the block and click edit
  await rawBlock.hover();
  const editBtn = rawBlock.locator(".edit-btn");
  await expect(editBtn).toBeVisible({ timeout: 5_000 });
  await editBtn.click();

  // Textarea should appear with the original JSON
  const textarea = page.locator(".raw-edit-textarea");
  await expect(textarea).toBeVisible({ timeout: 5_000 });

  // Inject a unique marker into the raw JSON that we can later check via
  // the mock API's "check context contains" pattern.
  const marker = `EDIT_RAW_TEST_${Date.now()}`;
  const currentValue = await textarea.inputValue();
  let modified: string;
  try {
    const parsed = JSON.parse(currentValue);
    parsed._test_edit_marker = marker;
    modified = JSON.stringify(parsed, null, 2);
  } catch {
    modified = currentValue.replace(
      /\}$/,
      `, "_test_edit_marker": "${marker}"}`,
    );
  }

  await textarea.fill(modified);

  // Click Save
  await page.locator(".edit-actions .btn-primary").click();

  // Session reloads — wait for messages to reappear
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "pre-edit-marker" }),
  ).toBeVisible({ timeout: 15_000 });

  // Verify the edit persisted: re-open source view and check the marker
  const assistantMsgAfter = page
    .locator(".message-wrapper")
    .filter({
      has: page.locator(".message.assistant-message .text-content", { hasText: "pre-edit-marker" }),
    })
    .last();
  await assistantMsgAfter.hover();

  const viewSourceBtn2 = assistantMsgAfter.locator(".view-source-btn");
  await expect(viewSourceBtn2).toBeVisible({ timeout: 5_000 });
  await viewSourceBtn2.click();

  const sourceView2 = assistantMsgAfter.locator(".source-view");
  const firstEventHeader2 = sourceView2.locator(".source-event-header").first();
  await expect(firstEventHeader2).toBeVisible({ timeout: 5_000 });
  await firstEventHeader2.click();

  const rawTab2 = sourceView2.locator(".source-tab", { hasText: "Raw" });
  await expect(rawTab2).toBeVisible({ timeout: 5_000 });
  await rawTab2.click();

  await expect(sourceView2.locator(".code-pre-wrap").first()).toBeVisible({ timeout: 10_000 });
  await expect(
    sourceView2.locator(".code-pre-wrap", { hasText: marker }),
  ).toBeVisible({ timeout: 5_000 });

  // Close source view by clicking view-source again
  await assistantMsgAfter.hover();
  await assistantMsgAfter.locator(".view-source-btn").click();

  // Resume the session and verify the agent sees the edited history.
  // The mock API's "check context contains <base64>" pattern searches the
  // full serialized API request for the decoded string.
  await page.locator(".btn-banner-resume").click();
  const bannerTimeout = agentType === "codex" ? 30_000 : 15_000;
  await expect(page.locator(".btn-banner-stop")).toBeVisible({ timeout: bannerTimeout });

  const markerB64 = Buffer.from(marker).toString("base64");
  await sendMessage(page, `check context contains ${markerB64}`);

  await expect(
    page.locator(".message.assistant-message .text-content", {
      hasText: "context-check-passed",
    }).first(),
  ).toBeVisible({ timeout });
});
