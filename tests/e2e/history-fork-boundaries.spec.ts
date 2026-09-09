import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
  responseTimeout,
  assistantText,
} from "./fixtures";
import type { Page } from "@playwright/test";

async function snapshotTids(page: Page): Promise<Set<string>> {
  return new Set(
    await page
      .locator(".sidebar-item[data-tid]")
      .evaluateAll((items) =>
        items.map((item) => item.getAttribute("data-tid")!),
      ),
  );
}

async function waitForNewTid(page: Page, before: Set<string>): Promise<string> {
  let tid: string | undefined;
  await expect(async () => {
    const tids = await page
      .locator(".sidebar-item[data-tid]")
      .evaluateAll((items) =>
        items.map((item) => item.getAttribute("data-tid")!),
      );
    tid = tids.find((candidate) => !before.has(candidate));
    expect(tid).toBeTruthy();
  }).toPass();
  return tid!;
}

async function resume(page: Page, agentType: string) {
  const button = page.locator(
    "[style*='display: contents'] .btn-banner-resume",
  );
  await expect(button).toBeVisible({ timeout: responseTimeout(agentType) });
  await button.click();
}

async function activeHistory(page: Page) {
  return page
    .locator(
      "[style*='display: contents'] .message.user-message:not(.pending):not(.meta-message), [style*='display: contents'] .assistant-message",
    )
    .evaluateAll((messages) =>
      messages.map((message) => ({
        role: message.classList.contains("user-message") ? "user" : "assistant",
        text: (message.textContent ?? "").trimEnd(),
      })),
    );
}

function message(page: Page, selector: string, marker: string) {
  return page
    .locator("[style*='display: contents'] .message-wrapper", {
      has: page.locator(selector, { hasText: marker }),
    })
    .last();
}

async function fork(page: Page, selector: string, marker: string) {
  const wrapper = message(page, selector, marker);
  await wrapper.hover();
  await expect(wrapper.locator(".fork-btn")).toBeVisible();
  await wrapper.locator(".fork-btn").click();
}

async function createParent(page: Page, prefix: string, agentType: string) {
  const before = await snapshotTids(page);
  const prior = `${prefix}-prior`;
  const selected = `${prefix}-selected`;
  const response = `${prefix}-response`;
  const tail = `${prefix}-tail`;
  await enterSession(page);
  await sendMessage(page, `Reply exactly with ${prior}`);
  const parentTid = await waitForNewTid(page, before);
  await expect(assistantText(page, prior)).toBeVisible({
    timeout: responseTimeout(agentType),
  });
  await sendMessage(page, `Reply exactly with ${response}. Marker ${selected}`);
  await expect(assistantText(page, response)).toBeVisible({
    timeout: responseTimeout(agentType),
  });
  await sendMessage(page, `Reply exactly with ${tail}`);
  await expect(assistantText(page, tail)).toBeVisible({
    timeout: responseTimeout(agentType),
  });
  return { parentTid, prior, selected, response, tail };
}

async function assertChild(
  page: Page,
  prior: string,
  selected: string,
  response: string,
  tail: string,
  includesResponse: boolean,
) {
  await expect(
    page.locator("[style*='display: contents'] .user-message", {
      hasText: prior,
    }),
  ).toBeVisible();
  await expect(
    page.locator("[style*='display: contents'] .user-message", {
      hasText: selected,
    }),
  ).toBeVisible();
  if (includesResponse) {
    await expect(assistantText(page, response)).toBeVisible();
  } else {
    await expect(assistantText(page, response)).toHaveCount(0);
  }
  await expect(
    page.locator("[style*='display: contents'] .user-message", {
      hasText: tail,
    }),
  ).toHaveCount(0);
  await expect(assistantText(page, tail)).toHaveCount(0);
}

test(
  "non-Codex fork boundaries retain the inclusive prefix and isolate parents",
  { tag: "@no-codex" },
  async ({ page, agentType }) => {
    const user = await createParent(page, "LIVE_USER_FORK", agentType);
    const userParentHistory = await activeHistory(page);
    const beforeUserFork = await snapshotTids(page);
    await fork(
      page,
      ".user-message:not(.pending):not(.meta-message)",
      user.selected,
    );
    const userChildTid = await waitForNewTid(page, beforeUserFork);
    await expect(page).toHaveURL(new RegExp(`/task/${userChildTid}$`));
    await assertChild(
      page,
      user.prior,
      user.selected,
      user.response,
      user.tail,
      false,
    );
    if (agentType === "claude") {
      await resume(page, agentType);
      await sendMessage(
        page,
        `check context contains ${Buffer.from(user.selected).toString("base64")}`,
      );
      await expect(assistantText(page, "context-check-passed")).toBeVisible({
        timeout: responseTimeout(agentType),
      });
    }
    await page.locator(`.sidebar-item[data-tid="${user.parentTid}"]`).click();
    await expect(assistantText(page, user.tail)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    expect(await activeHistory(page)).toEqual(userParentHistory);

    const assistant = await createParent(
      page,
      "LIVE_ASSISTANT_FORK",
      agentType,
    );
    const assistantParentHistory = await activeHistory(page);
    const beforeAssistantFork = await snapshotTids(page);
    await fork(page, ".assistant-message", assistant.response);
    const assistantChildTid = await waitForNewTid(page, beforeAssistantFork);
    await expect(page).toHaveURL(new RegExp(`/task/${assistantChildTid}$`));
    await assertChild(
      page,
      assistant.prior,
      assistant.selected,
      assistant.response,
      assistant.tail,
      true,
    );
    if (agentType === "claude") {
      await resume(page, agentType);
      await sendMessage(
        page,
        'Reply exactly with "live-assistant-fork-resumed"',
      );
      await expect(
        assistantText(page, "live-assistant-fork-resumed"),
      ).toBeVisible({
        timeout: responseTimeout(agentType),
      });
    }
    await page
      .locator(`.sidebar-item[data-tid="${assistant.parentTid}"]`)
      .click();
    await expect(assistantText(page, assistant.tail)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    expect(await activeHistory(page)).toEqual(assistantParentHistory);

    const offline = await createParent(
      page,
      "OFFLINE_ASSISTANT_FORK",
      agentType,
    );
    await killSession(page, agentType);
    await page.reload();
    await expect(assistantText(page, offline.tail)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    const offlineParentHistory = await activeHistory(page);
    const beforeOfflineFork = await snapshotTids(page);
    await fork(page, ".assistant-message", offline.response);
    const offlineChildTid = await waitForNewTid(page, beforeOfflineFork);
    await expect(page).toHaveURL(new RegExp(`/task/${offlineChildTid}$`));
    await assertChild(
      page,
      offline.prior,
      offline.selected,
      offline.response,
      offline.tail,
      true,
    );
    if (agentType === "claude") {
      await resume(page, agentType);
      await sendMessage(
        page,
        'Reply exactly with "offline-assistant-fork-resumed"',
      );
      await expect(
        assistantText(page, "offline-assistant-fork-resumed"),
      ).toBeVisible({ timeout: responseTimeout(agentType) });
    }
    await page
      .locator(`.sidebar-item[data-tid="${offline.parentTid}"]`)
      .click();
    await expect(assistantText(page, offline.tail)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    expect(await activeHistory(page)).toEqual(offlineParentHistory);
  },
);
