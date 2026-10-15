import {
  test,
  expect,
  enterSession,
  sendMessage,
  assistantText,
  responseTimeout,
} from "./fixtures";
import { writeTestConfig } from "./test-config";

// a windowed replay windows each sub-agent's transcript like the task's own
// messages: only its newest messages load, and a "Load N more" row inside
// its Agent block brings the rest

test(
  "a sub-agent's transcript loads in windows inside its Agent block",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    const timeout = responseTimeout(agentType);
    writeTestConfig(
      "/tmp/playwright-home/.config/cydo/config.yaml",
      `history_window:
  desktop: 3
  mobile: 3
workspaces:
  local:
    root: /tmp/cydo-test-workspace
`,
    );
    await page.waitForTimeout(500);

    await enterSession(page);
    await page.locator("button.task-type-row", { hasText: "blank" }).click();
    // the sub-agent runs four commands after its prompt: five messages, its
    // text never reaching the live stream; the task's own holds two
    await sendMessage(page, "spawn task chatty steps 4");
    const nested = page.locator(
      '[style*="display: contents"] .sub-agent-messages',
    );
    await expect(assistantText(page, "Done.")).toBeVisible({ timeout });

    // the reload replays the task, which is what the window applies to
    await page.reload();
    // the newest three of the sub-agent's five
    await expect(nested.getByText("echo chatty 4")).toBeVisible({ timeout });
    await expect(nested.getByText("echo chatty 3")).toBeVisible();
    await expect(nested.getByText("echo chatty 2")).toBeVisible();
    await expect(nested.getByText("echo chatty 1")).toHaveCount(0);
    await expect(nested.getByText("chatty steps 4")).toHaveCount(0);

    const loadMore = nested.locator(".nested-load-more-row");
    await expect(loadMore).toBeVisible();
    await loadMore.getByRole("button", { name: "Load 3 more" }).click();

    await expect(nested.getByText("echo chatty 1")).toBeVisible({ timeout });
    await expect(nested.getByText("chatty steps 4")).toBeVisible();
    await expect(loadMore).toHaveCount(0);
    // in their original order
    const text = (await nested.innerText()).replace(/\s+/g, " ");
    const order = [
      "chatty steps 4",
      "echo chatty 1",
      "echo chatty 2",
      "echo chatty 4",
    ].map((needle) => text.indexOf(needle));
    expect(order[0]).toBeGreaterThanOrEqual(0);
    expect([...order].sort((a, b) => a - b)).toEqual(order);
  },
);
