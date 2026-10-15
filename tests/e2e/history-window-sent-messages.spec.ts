import {
  test,
  expect,
  enterSession,
  sendMessage,
  assistantText,
  responseTimeout,
} from "./fixtures";
import { writeTestConfig } from "./test-config";

// a live task's history holds each sent message twice: the unconfirmed copy
// from the moment it was sent, which has no seq, and the agent's own record
// of it; loading older messages has to place the unconfirmed copies too

test("loading older messages of a live task reaches past its sent messages", async ({
  page,
  agentType,
}) => {
  const timeout = responseTimeout(agentType);
  writeTestConfig(
    "/tmp/playwright-home/.config/cydo/config.yaml",
    `default_agent: ${agentType}
history_window:
  desktop: 2
  mobile: 2
workspaces:
  local:
    root: /tmp/cydo-test-workspace
`,
  );
  await page.waitForTimeout(500);

  await enterSession(page);
  for (const n of [1, 2, 3]) {
    await sendMessage(page, `Please reply with "window-sent-${n}"`);
    await expect(assistantText(page, `window-sent-${n}`)).toBeVisible({
      timeout,
    });
  }

  // the task stays live, so the replay comes from the server's own history,
  // unconfirmed copies included
  await page.reload();
  await expect(assistantText(page, "window-sent-3")).toBeVisible({ timeout });
  await expect(assistantText(page, "window-sent-1")).toHaveCount(0);

  const loadMore = page.getByRole("button", { name: "Load 2 more" }).first();
  for (let i = 0; i < 3 && (await loadMore.count()) > 0; i++) {
    await loadMore.click();
    await page.waitForTimeout(500);
  }

  await expect(assistantText(page, "window-sent-1")).toBeVisible({ timeout });
  await expect(assistantText(page, "window-sent-2")).toBeVisible();
});
