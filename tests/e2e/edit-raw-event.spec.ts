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

  // Switch to Raw tab
  const rawTab = page.locator(".source-tab", { hasText: "Raw" });
  await expect(rawTab).toBeVisible({ timeout: 5_000 });
  await rawTab.click();

  // Wait for raw events to load — there should be at least one code-pre-wrap block
  const rawBlocks = page.locator(".source-view .code-pre-wrap");
  await expect(rawBlocks.first()).toBeVisible({ timeout: 10_000 });

  // Hover over the first block and click edit
  const firstBlock = rawBlocks.first();
  await firstBlock.hover();
  const editBtn = firstBlock.locator(".edit-btn");
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
    // If parsing fails, just append the marker field
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

  // Switch to Raw tab again
  const rawTab2 = page.locator(".source-tab", { hasText: "Raw" });
  await expect(rawTab2).toBeVisible({ timeout: 5_000 });
  await rawTab2.click();

  // Wait for raw events to load
  await expect(page.locator(".source-view .code-pre-wrap").first()).toBeVisible({ timeout: 10_000 });

  // Verify the edit marker appears in one of the raw event blocks
  await expect(
    page.locator(".source-view .code-pre-wrap", { hasText: "edit-raw-test-marker" }),
  ).toBeVisible({ timeout: 5_000 });
});
