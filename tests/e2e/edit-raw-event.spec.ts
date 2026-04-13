import { test, expect, enterSession, sendMessage, killSession, responseTimeout } from "./fixtures";

test("edit raw JSON event in source view", async ({ page, agentType }) => {
  test.skip(agentType !== "claude", "raw event editing requires Claude seq numbers");

  await enterSession(page);
  await sendMessage(page, "run command echo edit-raw-test");

  const timeout = responseTimeout(agentType);

  // Wait for the full turn to complete
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "Done." }),
  ).toBeVisible({ timeout });

  // Stop the session so we can edit
  await killSession(page, agentType);

  // Find the assistant message with "Done." and open source view
  const doneMsg = page
    .locator(".message-wrapper")
    .filter({
      has: page.locator(".message.assistant-message .text-content", { hasText: "Done." }),
    })
    .last();
  await doneMsg.hover();

  const viewSourceBtn = doneMsg.locator(".view-source-btn");
  await expect(viewSourceBtn).toBeVisible({ timeout: 5_000 });
  await viewSourceBtn.click();

  // The source view should show a collapsible event list
  const sourceView = doneMsg.locator(".source-view");
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

  // Modify the JSON: parse it, add a marker field, stringify back
  const currentValue = await textarea.inputValue();
  let modified: string;
  try {
    const parsed = JSON.parse(currentValue);
    parsed._test_edit_marker = "edit-raw-test-marker";
    modified = JSON.stringify(parsed, null, 2);
  } catch {
    modified = currentValue.replace(/\}$/, ', "_test_edit_marker": "edit-raw-test-marker"}');
  }

  await textarea.fill(modified);

  // Click Save
  await page.locator(".edit-actions .btn-primary").click();

  // Session reloads — wait for messages to reappear
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "Done." }),
  ).toBeVisible({ timeout: 15_000 });

  // Re-open source view on the same message
  const doneMsgAfter = page
    .locator(".message-wrapper")
    .filter({
      has: page.locator(".message.assistant-message .text-content", { hasText: "Done." }),
    })
    .last();
  await doneMsgAfter.hover();

  const viewSourceBtn2 = doneMsgAfter.locator(".view-source-btn");
  await expect(viewSourceBtn2).toBeVisible({ timeout: 5_000 });
  await viewSourceBtn2.click();

  // Expand the first event again
  const sourceView2 = doneMsgAfter.locator(".source-view");
  const firstEventHeader2 = sourceView2.locator(".source-event-header").first();
  await expect(firstEventHeader2).toBeVisible({ timeout: 5_000 });
  await firstEventHeader2.click();

  // Switch to Raw tab
  const rawTab2 = sourceView2.locator(".source-tab", { hasText: "Raw" });
  await expect(rawTab2).toBeVisible({ timeout: 5_000 });
  await rawTab2.click();

  // Wait for raw JSON to load
  await expect(sourceView2.locator(".code-pre-wrap").first()).toBeVisible({ timeout: 10_000 });

  // Verify the edit marker appears
  await expect(
    sourceView2.locator(".code-pre-wrap", { hasText: "edit-raw-test-marker" }),
  ).toBeVisible({ timeout: 5_000 });
});
