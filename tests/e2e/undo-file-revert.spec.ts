import {
  test,
  expect,
  enterSession,
  openUndoMenu,
  chooseUndo,
  sendMessage,
  killSession,
  assistantText,
} from "./fixtures";
import type { Locator, Page } from "@playwright/test";
import { readFileSync } from "fs";

async function undoMenuState(message: Locator) {
  return message.evaluate((wrapper) => {
    const list = wrapper.closest<HTMLElement>(".message-list")!;
    const listTop = list.getBoundingClientRect().top + list.clientTop;
    const bounds = (element: Element) => {
      const { top, bottom } = element.getBoundingClientRect();
      return { top, bottom };
    };
    const actions = wrapper.querySelector(".undo-btn")!.parentElement!;
    const menu = actions.querySelector(".undo-menu");
    const item = menu?.querySelector('[aria-label="Undo conversation"]');
    const itemRect = item?.getBoundingClientRect();
    const hit = itemRect
      ? document.elementFromPoint(
          itemRect.x + itemRect.width / 2,
          itemRect.y + itemRect.height / 2,
        )
      : null;
    return {
      top: Math.max(0, listTop),
      bottom: Math.min(innerHeight, listTop + list.clientHeight),
      row: bounds(actions),
      menu: menu ? bounds(menu) : null,
      hitTestable: !!hit && !!item?.contains(hit),
    };
  });
}

async function expectMenuInvariant(message: Locator, scenario: string) {
  await expect
    .poll(
      async () => {
        const { top, bottom, row, menu } = await undoMenuState(message);
        if (!menu) return null;
        const within = (rect: typeof row) =>
          rect.top >= top - 1 && rect.bottom <= bottom + 1;
        const attached =
          Math.abs(menu.top - row.bottom) <= 1 ||
          Math.abs(menu.bottom - row.top) <= 1;
        return within(row) && within(menu) && attached
          ? null
          : { top, bottom, row, menu };
      },
      { message: scenario, timeout: 5_000 },
    )
    .toBeNull();
}

async function wheelPastUndoRow(page: Page, message: Locator, step: 8 | -8) {
  const edge = step > 0 ? "top" : "bottom";
  const listBox = (await page.locator(".message-list:visible").boundingBox())!;
  await page.mouse.move(listBox.x + 4, listBox.y + listBox.height / 2);

  for (let i = 0; i < 100; i++) {
    const before = await undoMenuState(message);
    await page.mouse.wheel(0, step);
    await expect
      .poll(async () => (await undoMenuState(message)).row.top, {
        message: `Wheel step ${i + 1} must move the undo row toward the ${edge} edge`,
        timeout: 5_000,
      })
      .not.toBe(before.row.top);
    await expectMenuInvariant(message, `Undo menu at the ${edge} edge`);
    const { row, top, bottom } = await undoMenuState(message);
    if (step > 0 ? row.bottom <= top : row.top >= bottom) return;
  }
  throw new Error(
    `Undo row did not leave through the ${edge} edge in 100 steps`,
  );
}

test(
  "undo file revert uses the selected checkpoint",
  { tag: "@claude-only" },
  async ({ page, backend, agentType }) => {
    const testFile = `${backend.wsDir}/undo-revert-test.txt`;
    const firstContent = "first checkpoint state";
    const secondContent = "selected checkpoint state";
    const thirdContent = "third checkpoint state";
    const fourthContent = "conversation only state";
    const liveFile = `${backend.wsDir}/undo-live-revert-test.txt`;
    const livePrevious = "live predecessor state";
    const liveSelected = "live selected state";

    await enterSession(page);
    await sendMessage(
      page,
      `create file ${liveFile} with content ${livePrevious}`,
    );
    await expect(assistantText(page, "Done.")).toBeVisible();
    await sendMessage(
      page,
      `create file ${liveFile} with content ${liveSelected}`,
    );
    await expect(assistantText(page, "Done.")).toHaveCount(2);
    const liveCheckpointUser = page
      .locator(".message-wrapper", {
        has: page.locator(".user-message", { hasText: liveSelected }),
      })
      .last();
    const liveUndo = liveCheckpointUser.locator(".undo-btn");
    await expect(liveUndo).toHaveAttribute(
      "title",
      "Undo this message and later history, restoring its prompt to the composer (file checkpoint available)",
    );
    await expect(page.locator(".btn-stop:visible")).toHaveCount(0);
    const originalViewport = page.viewportSize()!;
    await page.setViewportSize({ width: 900, height: 300 });
    const earlyCheckpointUser = page
      .locator(".message-wrapper", {
        has: page.locator(".user-message", { hasText: livePrevious }),
      })
      .last();
    const earlyUndo = earlyCheckpointUser.locator(".undo-btn");
    const earlyMenu = await openUndoMenu(earlyCheckpointUser);
    await expect(earlyMenu.locator(".undo-menu-files")).toContainText(
      "Restores 1 file",
    );
    await expectMenuInvariant(earlyCheckpointUser, "Initial undo menu");
    await expect(earlyMenu).toHaveCount(1);
    await expect
      .poll(async () => (await undoMenuState(earlyCheckpointUser)).hitTestable)
      .toBe(true);

    await wheelPastUndoRow(page, earlyCheckpointUser, 8);
    await expect(earlyMenu).toHaveCount(0);
    await expect(earlyUndo).toBeFocused();

    await openUndoMenu(earlyCheckpointUser);
    await expect(earlyMenu.locator(".undo-menu-files")).toContainText(
      "Restores 1 file",
    );
    const list = page.locator(".message-list:visible");
    await expect
      .poll(() => list.evaluate((el) => el.scrollTop))
      .toBeLessThan(0);
    await page.setViewportSize({ width: 900, height: 270 });
    await expectMenuInvariant(earlyCheckpointUser, "Scrolled-up shrink");
    await page.setViewportSize({ width: 900, height: 300 });
    if (await earlyMenu.count()) {
      await page.keyboard.press("Escape");
      await expect(earlyMenu).toHaveCount(0);
    }

    const bottomMenu = await openUndoMenu(liveCheckpointUser);
    await wheelPastUndoRow(page, liveCheckpointUser, -8);
    await expect(bottomMenu).toHaveCount(0);

    await page.mouse.wheel(0, 5000);
    await expect.poll(() => list.evaluate((el) => el.scrollTop)).toBe(0);
    const liveMenu = await openUndoMenu(liveCheckpointUser);
    const preview = liveMenu.locator(".undo-menu-files");
    await expect(preview).toContainText("Restores 1 file");
    await expect(preview.locator(".tool-subtitle-path")).toHaveText(liveFile);
    await expect(preview.locator(".diffstat-added")).toHaveText("+1");
    await expect(preview.locator(".diffstat-removed")).toHaveText("−1");
    await expectMenuInvariant(liveCheckpointUser, "Pinned-bottom undo menu");
    await expect
      .poll(() =>
        liveMenu.evaluate((menu) => {
          const list = menu.closest<HTMLElement>(".message-list")!;
          const menuRect = menu.getBoundingClientRect();
          const listRect = list.getBoundingClientRect();
          const top = Math.max(0, listRect.top + list.clientTop);
          const left = Math.max(0, listRect.left + list.clientLeft);
          const bottom = Math.min(
            window.innerHeight,
            listRect.top + list.clientTop + list.clientHeight,
          );
          const right = Math.min(
            window.innerWidth,
            listRect.left + list.clientLeft + list.clientWidth,
          );
          return (
            menuRect.height > 0 &&
            menuRect.top >= top - 1 &&
            menuRect.bottom <= bottom + 1 &&
            menuRect.left >= left - 1 &&
            menuRect.right <= right + 1
          );
        }),
      )
      .toBe(true);
    await liveMenu.evaluate((menu) => {
      menu.scrollTop = menu.scrollHeight;
    });
    const { scrollTop, overflow } = await liveMenu.evaluate((menu) => ({
      scrollTop: menu.scrollTop,
      overflow: menu.scrollHeight - menu.clientHeight,
    }));
    expect(overflow).toBeGreaterThan(0);
    expect(scrollTop).toBeCloseTo(overflow, 0);
    await chooseUndo(page, "Undo files only");
    await page.setViewportSize(originalViewport);
    await expect(page.locator(".undo-result-banner")).toBeVisible();
    expect(readFileSync(liveFile, "utf8").trimEnd()).toBe(livePrevious);
    await expect(
      page.locator(".message.user-message:not(.pending)", {
        hasText: liveSelected,
      }),
    ).toBeVisible();
    await expect(assistantText(page, "Done.")).toHaveCount(2);
    await sendMessage(page, 'Please reply with "live-file-revert-follow-up"');
    await expect(
      assistantText(page, "live-file-revert-follow-up"),
    ).toBeVisible();
    const followUp = page.locator(".message-wrapper", {
      has: page.locator(".user-message:not(.pending)", {
        hasText: 'Please reply with "live-file-revert-follow-up"',
      }),
    });
    await expect(followUp.locator(".undo-btn")).toHaveAttribute(
      "title",
      /file checkpoint available/,
    );
    await expect(page.locator(".btn-stop:visible")).toHaveCount(0);
    const noChangeMenu = await openUndoMenu(followUp);
    await expect(noChangeMenu.getByRole("menuitem")).toHaveCount(1);
    await expect(noChangeMenu.locator(".undo-menu-files")).toHaveCount(0);
    await page.keyboard.press("Escape");
    await expect(noChangeMenu).toHaveCount(0);

    await enterSession(page);
    await sendMessage(
      page,
      `create file ${testFile} with content ${firstContent}`,
    );
    await expect(assistantText(page, "Done.")).toBeVisible();
    expect(readFileSync(testFile, "utf8").trimEnd()).toBe(firstContent);

    const checkpointAssistant = page
      .locator(".message-wrapper", {
        has: page.locator(".assistant-message").last(),
      })
      .last();
    await expect(checkpointAssistant.locator(".undo-btn")).toHaveAttribute(
      "title",
      "Undo this response and later history, retaining its prompt",
    );
    const assistantMenu = await openUndoMenu(checkpointAssistant);
    await expect(assistantMenu.getByRole("menuitem")).toHaveCount(1);
    await page.keyboard.press("Escape");

    await sendMessage(
      page,
      `create file ${testFile} with content ${secondContent}`,
    );
    await expect(assistantText(page, "Done.")).toHaveCount(2);
    expect(readFileSync(testFile, "utf8").trimEnd()).toBe(secondContent);

    await sendMessage(
      page,
      `create file ${testFile} with content ${thirdContent}`,
    );
    await expect(assistantText(page, "Done.")).toHaveCount(3);
    expect(readFileSync(testFile, "utf8").trimEnd()).toBe(thirdContent);

    await killSession(page, agentType);
    const thirdCheckpointUser = page.locator(".message-wrapper", {
      has: page.locator(".user-message", { hasText: thirdContent }),
    });
    await expect(thirdCheckpointUser).toHaveCount(1);
    const thirdUndoButton = thirdCheckpointUser.locator(".undo-btn");
    await expect(thirdUndoButton).toHaveAttribute(
      "title",
      "Undo this message and later history, restoring its prompt to the composer (file checkpoint available)",
    );
    const thirdForkButton = thirdCheckpointUser.locator(".fork-btn");
    await thirdCheckpointUser.hover();
    await expect(thirdUndoButton.locator("xpath=..")).toHaveClass(
      "message-actions",
    );
    await expect(thirdForkButton.locator("xpath=..")).toHaveClass(
      /message-actions-bottom/,
    );
    const thirdMessageBox = await thirdCheckpointUser
      .locator(".user-message")
      .boundingBox();
    const thirdUndoBox = await thirdUndoButton.boundingBox();
    const thirdForkBox = await thirdForkButton.boundingBox();
    expect(thirdMessageBox).not.toBeNull();
    expect(thirdUndoBox).not.toBeNull();
    expect(thirdForkBox).not.toBeNull();
    expect(
      Math.abs(thirdUndoBox!.y + thirdUndoBox!.height / 2 - thirdMessageBox!.y),
    ).toBeLessThanOrEqual(2);
    expect(
      Math.abs(
        thirdForkBox!.y +
          thirdForkBox!.height / 2 -
          (thirdMessageBox!.y + thirdMessageBox!.height),
      ),
    ).toBeLessThanOrEqual(2);
    expect(thirdUndoBox!.y + thirdUndoBox!.height).toBeLessThanOrEqual(
      thirdForkBox!.y,
    );
    await expect(thirdForkButton).toBeVisible();
    await thirdForkButton.focus();
    await page.keyboard.press("Shift+Tab");
    await expect(thirdUndoButton).toBeFocused();
    await expect(thirdUndoButton).toBeVisible();
    await thirdUndoButton.press("Enter");
    const thirdMenu = thirdCheckpointUser.locator(".undo-menu");
    await expect(
      thirdMenu.getByRole("menuitem", {
        name: "Undo conversation + files",
        exact: true,
      }),
    ).toBeVisible();
    await expect(
      thirdMenu.getByRole("menuitem", {
        name: "Undo files only",
        exact: true,
      }),
    ).toBeVisible();
    await expect(thirdMenu.locator(".undo-menu-files")).toHaveCount(0);
    await chooseUndo(page, "Undo files only");
    await expect(page.locator(".undo-result-banner")).toBeVisible();

    // The selected third checkpoint restores the second write, proving the
    // backend passed the resolved checkpoint rather than an adjacent one.
    expect(readFileSync(testFile, "utf8").trimEnd()).toBe(secondContent);

    // Files-only undo leaves the history available for another rewind.
    const secondCheckpointUser = page.locator(".message-wrapper", {
      has: page.locator(".user-message", { hasText: secondContent }),
    });
    await expect(secondCheckpointUser).toHaveCount(1);
    const secondUndoButton = secondCheckpointUser.locator(".undo-btn");
    await expect(secondUndoButton).toHaveAttribute(
      "title",
      "Undo this message and later history, restoring its prompt to the composer (file checkpoint available)",
    );
    const secondForkButton = secondCheckpointUser.locator(".fork-btn");
    await secondCheckpointUser.hover();
    await expect(secondUndoButton.locator("xpath=..")).toHaveClass(
      "message-actions",
    );
    await expect(secondForkButton.locator("xpath=..")).toHaveClass(
      /message-actions-bottom/,
    );
    const secondMessageBox = await secondCheckpointUser
      .locator(".user-message")
      .boundingBox();
    const secondUndoBox = await secondUndoButton.boundingBox();
    const secondForkBox = await secondForkButton.boundingBox();
    expect(secondMessageBox).not.toBeNull();
    expect(secondUndoBox).not.toBeNull();
    expect(secondForkBox).not.toBeNull();
    expect(
      Math.abs(
        secondUndoBox!.y + secondUndoBox!.height / 2 - secondMessageBox!.y,
      ),
    ).toBeLessThanOrEqual(2);
    expect(
      Math.abs(
        secondForkBox!.y +
          secondForkBox!.height / 2 -
          (secondMessageBox!.y + secondMessageBox!.height),
      ),
    ).toBeLessThanOrEqual(2);
    expect(secondUndoBox!.y + secondUndoBox!.height).toBeLessThanOrEqual(
      secondForkBox!.y,
    );
    await expect(secondForkButton).toBeVisible();
    await secondForkButton.focus();
    await page.keyboard.press("Shift+Tab");
    await expect(secondUndoButton).toBeFocused();
    await expect(secondUndoButton).toBeVisible();
    await secondUndoButton.press("Enter");
    const secondMenu = secondCheckpointUser.locator(".undo-menu");
    await expect(
      secondMenu.getByRole("menuitem", {
        name: "Undo conversation + files",
        exact: true,
      }),
    ).toBeVisible();
    await expect(
      secondMenu.getByRole("menuitem", {
        name: "Undo files only",
        exact: true,
      }),
    ).toBeVisible();
    await expect(secondMenu.locator(".undo-menu-files")).toHaveCount(0);
    await chooseUndo(page, "Undo conversation + files");
    await expect(page.locator(".undo-result-banner")).toBeVisible();
    await expect
      .poll(() => readFileSync(testFile, "utf8").trimEnd())
      .toBe(firstContent);
    await expect(secondCheckpointUser).toHaveCount(0);
    await expect(thirdCheckpointUser).toHaveCount(0);

    await sendMessage(
      page,
      `create file ${testFile} with content ${fourthContent}`,
    );
    await expect(assistantText(page, "Done.")).toHaveCount(2);
    expect(readFileSync(testFile, "utf8").trimEnd()).toBe(fourthContent);

    await killSession(page, agentType);
    const conversationOnly = page
      .locator(".message-wrapper", {
        has: page.locator(".user-message", { hasText: fourthContent }),
      })
      .last();
    const conversationMenu = await openUndoMenu(conversationOnly);
    await expect(conversationMenu.getByRole("menuitem")).toHaveCount(3);
    await expect(conversationMenu.locator(".undo-menu-files")).toHaveCount(0);
    await chooseUndo(page, "Undo conversation");
    await expect(
      page.locator(".message.user-message:not(.pending)", {
        hasText: fourthContent,
      }),
    ).toHaveCount(0);
    expect(readFileSync(testFile, "utf8").trimEnd()).toBe(fourthContent);
  },
);
