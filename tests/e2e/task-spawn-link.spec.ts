import { test, expect, enterSession, sendMessage } from "./fixtures";

test("parent tool-call card shows Open task link to spawned subtask", async ({
  page,
}) => {

  await enterSession(page);
  await sendMessage(page, 'call task research reply with "ping"');

  // Wait for the Open task link to appear in the parent's tool-call card.
  const link = page
    .locator('[style*="display: contents"] .message-list')
    .locator('[data-testid="cydo-task-spec-open"]')
    .first();
  await expect(link).toBeVisible();

  // Verify href targets a numeric task id.
  const href = await link.getAttribute("href");
  expect(href).toMatch(/\/task\/\d+$/);

  // Click navigates to the child task's view.
  await link.click();
  await expect(page).toHaveURL(/\/task\/\d+$/);
});
