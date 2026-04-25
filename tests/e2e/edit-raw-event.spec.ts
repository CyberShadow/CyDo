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

test("edit raw JSON event persists to disk across reload", async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  await sendMessage(page, "run command echo edit-raw-marker");

  const timeout = responseTimeout(agentType);

  // Wait for the tool result so we know the full turn has completed
  await expect(
    page.locator(".tool-result", { hasText: "edit-raw-marker" }),
  ).toBeVisible({ timeout });

  // Wait for the final "Done." response
  await expect(lastAssistantText(page, "Done.")).toBeVisible({ timeout });

  // Stop the session so we can edit
  await killSession(page, agentType);

  // Find the last assistant message wrapper (the "Done." message)
  const assistantMsg = page
    .locator(".message-wrapper")
    .filter({
      has: assistantText(page, "Done."),
    })
    .last();
  await assistantMsg.hover();

  const viewSourceBtn = assistantMsg.locator(".view-source-btn");
  await expect(viewSourceBtn).toBeVisible({ timeout: 5_000 });
  await viewSourceBtn.click();

  // Use global locator for source-view since clicking view-source replaces
  // the text content, which breaks the scoped filter.
  const sourceView = page.locator(".source-view");
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

  // Inject a unique marker into the raw JSON
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

  // Click Save — triggers JSONL rewrite and session reload
  await page.locator(".edit-actions .btn-primary").click();

  // Session reloads — wait for messages to reappear
  await expect(lastAssistantText(page, "Done.")).toBeVisible({
    timeout: 15_000,
  });

  // Verify the edit persisted: re-open source view and check the marker
  const assistantMsgAfter = page
    .locator(".message-wrapper")
    .filter({
      has: assistantText(page, "Done."),
    })
    .last();
  await assistantMsgAfter.hover();

  const viewSourceBtn2 = assistantMsgAfter.locator(".view-source-btn");
  await expect(viewSourceBtn2).toBeVisible({ timeout: 5_000 });
  await viewSourceBtn2.click();

  const sourceView2 = page.locator(".source-view");
  const firstEventHeader2 = sourceView2.locator(".source-event-header").first();
  await expect(firstEventHeader2).toBeVisible({ timeout: 5_000 });
  await firstEventHeader2.click();

  const rawTab2 = sourceView2.locator(".source-tab", { hasText: "Raw" });
  await expect(rawTab2).toBeVisible({ timeout: 5_000 });
  await rawTab2.click();

  await expect(sourceView2.locator(".code-pre-wrap").first()).toBeVisible({
    timeout: 10_000,
  });
  // The marker injected into the raw event must survive the JSONL round-trip
  await expect(
    sourceView2.locator(".code-pre-wrap", { hasText: marker }),
  ).toBeVisible({ timeout: 5_000 });
});
