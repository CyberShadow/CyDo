import { test, expect, enterSession, sendMessage } from "./fixtures";
import type { Locator, Page } from "@playwright/test";

function messageList(page: Page): Locator {
  return page.locator('[style*="display: contents"] .message-list');
}

const integratorLabel = { hasText: /^Integrator$/ };

function integratorItems(page: Page): Locator {
  return page.locator(".sidebar-item[data-tid]", {
    has: page.locator(".sidebar-label", integratorLabel),
  });
}

function authorItem(page: Page): Locator {
  return page.locator(".sidebar-item[data-tid]", {
    hasNot: page.locator(".sidebar-label", integratorLabel),
  });
}

async function open(item: Locator): Promise<void> {
  await item.click();
  await expect(item).toHaveClass(/active/);
}

test("Land starts the project's integrator and returns its answer", async ({
  page,
}) => {
  await enterSession(page);
  await sendMessage(page, "call land land-test-first");

  // The project had no integrator: Land started one, which is not something
  // the new-task page offers.
  await expect(integratorItems(page)).toHaveCount(1);
  await expect(authorItem(page)).toHaveCount(1);
  const authorTid = await authorItem(page).getAttribute("data-tid");

  // Its answer is the author's result. (The view follows the question to the
  // integrator and the answer back, so look once the author's turn is over.)
  await expect(authorItem(page).locator(".task-type-icon.alive")).toBeVisible();
  await open(authorItem(page));
  await expect(
    messageList(page).getByText("landed-first", { exact: true }).last(),
  ).toBeVisible();

  // The request had reached the integrator as a question from the author,
  // and having answered, the integrator is idle rather than working.
  await open(integratorItems(page));
  await expect(
    messageList(page)
      .locator(".system-user-message")
      .filter({ hasText: new RegExp(`Question from task ${authorTid}`) }),
  ).toBeVisible();
  await expect(
    integratorItems(page).locator(".task-type-icon.alive"),
  ).toBeVisible();

  // A later Land goes to the same integrator.
  await open(authorItem(page));
  await sendMessage(page, "call land land-test-second");
  await expect(
    messageList(page).getByText("landed-second", { exact: true }).last(),
  ).toBeVisible();
  await expect(integratorItems(page)).toHaveCount(1);
});
