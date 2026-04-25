import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
} from "./fixtures";

test("View Source shows item-level events in collapsible list", async ({
  page,
  agentType,
}) => {
  test.skip(
    agentType !== "claude",
    "item/started and item/completed are claude-only events",
  );

  await enterSession(page);
  await sendMessage(page, "run command echo view-source-events-test");

  const timeout = responseTimeout(agentType);

  // Wait for the tool result to appear so we know the full turn has completed
  await expect(
    page.locator(".tool-result", { hasText: "view-source-events-test" }),
  ).toBeVisible({ timeout });

  // Wait for the final "Done." response from the assistant
  await expect(assistantText(page, "Done.")).toBeVisible({ timeout });

  // Hover over the last assistant message to reveal action buttons
  const lastAssistantMsg = page.locator(".message-wrapper").filter({
    has: assistantText(page, "Done."),
  });
  await lastAssistantMsg.hover();

  // Click the View Source button
  const viewSourceBtn = lastAssistantMsg.locator(".view-source-btn");
  await expect(viewSourceBtn).toBeVisible({ timeout: 5_000 });
  await viewSourceBtn.click();

  // The source view should show collapsible event items with type labels
  const sourceView = page.locator(".source-view");
  await expect(sourceView).toBeVisible({ timeout: 5_000 });

  // Event types should be visible in collapsed headers
  const eventTypes = sourceView.locator(".source-event-type");
  await expect(eventTypes.first()).toBeVisible({ timeout: 5_000 });

  const allTypes = await eventTypes.allInnerTexts();
  expect(allTypes).toContain("item/started");
  expect(allTypes).toContain("item/completed");
  expect(allTypes).toContain("turn/stop");

  // item/delta events must NOT be in rawSource (they are excluded to avoid bloat)
  expect(allTypes).not.toContain("item/delta");
});
