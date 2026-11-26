import { statSync } from "fs";
import {
  assistantText,
  enterSession,
  expect,
  responseTimeout,
  sendMessage,
  test,
} from "./fixtures";

test("CreateWorktree creates a worktree without changing the session cwd", async ({
  page,
  backend,
  agentType,
}) => {
  const timeout = responseTimeout(agentType);
  await enterSession(page);
  await page
    .locator(".task-type-row")
    .filter({ has: page.getByText("test_create_worktree", { exact: true }) })
    .click();
  await sendMessage(page, "call create worktree");

  const toolCalls = page.locator(".tool-call");
  const createWorktree = toolCalls.filter({
    has: page.locator(".tool-name", { hasText: /^CreateWorktree$/ }),
  });
  const resultHeader = createWorktree.locator(".tool-result-header");
  await expect(resultHeader).toBeVisible({ timeout });
  await expect(createWorktree).not.toHaveClass(/\btool-error\b/);
  await resultHeader.click();

  const activeTask = page.locator(".sidebar-item.top-level.active[data-tid]");
  await expect(activeTask).toHaveAttribute("data-tid", /^\d+$/);
  const tid = await activeTask.getAttribute("data-tid");
  const worktreeSuffix = `/.cydo/tasks/${tid}/worktree`;
  const result = createWorktree.locator(".tool-result");
  await expect(result).toContainText(worktreeSuffix);
  await expect(result).toContainText(new RegExp(`\\bcydo/${tid}\\b`));
  expect(statSync(`${backend.wsDir}${worktreeSuffix}`).isDirectory()).toBe(true);

  await expect(assistantText(page, "Done.")).toBeVisible({ timeout });
  await sendMessage(page, "run command pwd");

  const shellName = agentType === "codex" ? "commandExecution" : "Bash";
  const shell = toolCalls.filter({
    has: page.locator(".tool-name", { hasText: shellName }),
  });
  const shellResultHeader = shell.locator(".tool-result-header");
  const shellOutput = shell.locator(".tool-result");
  await expect(shellResultHeader).toBeVisible({ timeout });
  await expect(async () => {
    if (!(await shell.locator(".tool-result-container").isVisible()))
      await shellResultHeader.click();
    const output = (await shellOutput.allTextContents()).map((text) => text.trim());
    expect(output).toContain(backend.wsDir);
  }).toPass({ timeout });
  await expect(shell).not.toHaveClass(/\btool-error\b/);
});
