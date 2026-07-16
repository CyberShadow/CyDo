import { test, expect, enterSession } from "./fixtures";
import type { Page } from "./fixtures";

async function snapshotTids(page: Page): Promise<Set<string>> {
  const tids = await page
    .locator(".sidebar-item[data-tid]")
    .evaluateAll((els: Element[]) =>
      els.map((el) => el.getAttribute("data-tid")!),
    );
  return new Set(tids);
}

async function waitForNewTid(page: Page, before: Set<string>): Promise<string> {
  let newTid: string | undefined;
  await expect(async () => {
    const tids = await page
      .locator(".sidebar-item[data-tid]")
      .evaluateAll((els: Element[]) =>
        els.map((el) => el.getAttribute("data-tid")!),
      );
    newTid = tids.find((tid: string) => !before.has(tid));
    expect(newTid).toBeTruthy();
  }).toPass();
  return newTid!;
}

test("draft creation syncs title and body to another tab", async ({
  page,
  browser,
}) => {
  await enterSession(page);

  const context2 = await browser.newContext();
  const page2 = await context2.newPage();
  await page2.goto(page.url());
  await expect(page2.locator(".input-textarea:visible").first()).toBeEnabled({
      });

  const before = await snapshotTids(page);
  const draftText = "cross tab draft sync body";

  const input1 = page.locator(".input-textarea:visible").first();
  await input1.click();
  await input1.fill(draftText);

  const draftTid = await waitForNewTid(page, before);

  const tab2Draft = page2.locator(`.sidebar-item[data-tid="${draftTid}"]`);
  await expect(tab2Draft).toBeAttached();

  const tab2Label = tab2Draft.locator(".sidebar-label");
  await page2.waitForTimeout(1_000);
  const sidebarTitleBeforeClick = (await tab2Label.textContent())?.trim();

  await tab2Draft.click();
  const input2 = page2.locator(".input-textarea:visible").first();
  await expect(input2).toBeVisible();

  expect({
    sidebarTitleBeforeClick,
    body: await input2.inputValue(),
  }).toEqual({
    sidebarTitleBeforeClick: draftText,
    body: draftText,
  });

  await context2.close();
});
