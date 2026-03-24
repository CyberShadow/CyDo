import { test, expect, enterSession, sendMessage, responseTimeout } from "./fixtures";

test("View Source Agnostic tab includes item-level events", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "claude", "item/started and item/completed are claude-only events");

  await enterSession(page);
  await sendMessage(page, "run command echo view-source-events-test");

  const timeout = responseTimeout(agentType);

  // Wait for the tool result to appear so we know the full turn has completed
  await expect(
    page.locator(".tool-result", { hasText: "view-source-events-test" }),
  ).toBeVisible({ timeout });

  // Wait for the final "Done." response from the assistant
  await expect(
    page.locator(".message.assistant-message .text-content", { hasText: "Done." }),
  ).toBeVisible({ timeout });

  // Hover over the last assistant message to reveal action buttons
  const lastAssistantMsg = page.locator(".message-wrapper").filter({
    has: page.locator(".message.assistant-message .text-content", { hasText: "Done." }),
  });
  await lastAssistantMsg.hover();

  // Click the View Source button
  const viewSourceBtn = lastAssistantMsg.locator(".view-source-btn");
  await expect(viewSourceBtn).toBeVisible({ timeout: 5_000 });
  await viewSourceBtn.click();

  // Switch to the Agnostic tab (may already be active if no seq)
  const agnosticTab = page.locator(".source-tab", { hasText: "Agnostic" });
  if (await agnosticTab.isVisible()) {
    await agnosticTab.click();
  }

  // The source view should show JSON containing item-level event types
  const sourceView = page.locator(".source-view");
  await expect(sourceView).toBeVisible({ timeout: 5_000 });

  const sourceText = await sourceView.innerText();
  expect(sourceText).toContain("item/started");
  expect(sourceText).toContain("item/completed");
  expect(sourceText).toContain("turn/stop");

  // item/delta events must NOT be in rawSource (they are excluded to avoid bloat)
  expect(sourceText).not.toContain("item/delta");
});
