import { readFileSync } from "node:fs";
import {
  assistantText,
  enterSession,
  expect,
  responseTimeout,
  sendMessage,
  test,
} from "./fixtures";
import { withTestAgentEnvironment, writeTestConfig } from "./test-config";

test("reloading sidebar activity sort moves the selected task into view", { tag: "@claude-only" }, async ({
  page,
  agentType,
}) => {
  const configPath = "/tmp/playwright-home/.config/cydo/config.yaml";
  const original = readFileSync(configPath, "utf8");
  const sharedPrefix = withTestAgentEnvironment("").trimEnd() + "\n";
  expect(original.startsWith(sharedPrefix)).toBe(true);
  const config = original.slice(sharedPrefix.length);
  const setSort = (sort: "creation" | "activity") =>
    writeTestConfig(
      configPath,
      `${config.trimEnd()}
ui:
  sidebar:
    order: newest_first
    sort: ${sort}
`,
    );
  const timeout = responseTimeout(agentType);

  try {
    setSort("creation");
    await enterSession(page);
    await sendMessage(page, 'Please reply with "alpha"');
    await expect(assistantText(page, "alpha")).toBeVisible({ timeout });

    await enterSession(page);
    await sendMessage(page, 'Please reply with "beta"');
    await expect(assistantText(page, "beta")).toBeVisible({ timeout });

    // Force the two task rows to occupy separate scroll positions.
    // Disable browser scroll anchoring so visibility depends on the sidebar.
    await page.addStyleTag({
      content: ".sidebar-list { max-height: 32px; overflow-anchor: none; }",
    });
    const rows = page.locator(".sidebar-list .sidebar-item.top-level[data-tid]");
    const alpha = rows.filter({ hasText: "alpha" });
    await expect(rows).toHaveText([/beta/i, /alpha/i]);
    await alpha.click();
    await sendMessage(page, 'Please reply with "gamma"');
    await expect(assistantText(page, "gamma")).toBeVisible({ timeout });

    await expect(alpha).toHaveClass(/\bactive\b/);
    await expect(alpha).toBeInViewport({ ratio: 0.9 });

    setSort("activity");
    await expect(rows).toHaveText([/alpha/i, /beta/i]);
    await expect(alpha).toHaveClass(/\bactive\b/);
    await expect(alpha).toBeInViewport({ ratio: 0.9 });
  } finally {
    writeTestConfig(configPath, config);
  }
});
