import {
  assistantText,
  enterSession,
  expect,
  responseTimeout,
  sendMessage,
  test,
} from "./fixtures";

test("CreateTask leaves a draft linked to its creator", async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  await sendMessage(page, "call create task Fix the widget|reply with widget-fixed");

  const topLevelTasks = page.locator(".sidebar-item.top-level[data-tid]");
  const draftLabel = page.locator(".sidebar-label", { hasText: /^Fix the widget$/ });
  const draft = topLevelTasks.filter({ has: draftLabel });
  const openTask = page.getByTestId("cydo-create-task-open");
  await expect(openTask).toHaveText("Open task →", {
    timeout: responseTimeout(agentType),
  });
  await expect(draft.locator(".task-type-icon")).toHaveClass(/\bdraft\b/);
  await expect(topLevelTasks).toHaveCount(2);
  await expect(openTask).toHaveAttribute("href", (await draft.getAttribute("href"))!);
  await expect(assistantText(page, "Done.")).toBeVisible({
    timeout: responseTimeout(agentType),
  });
  await expect(page.locator(".input-box .btn-stop:visible")).toHaveCount(0);
  await expect(draft).not.toHaveClass(/\bactive\b/);

  const creator = topLevelTasks.filter({ hasNot: draftLabel });
  await expect(creator).toHaveClass(/\bactive\b/);
  const creatorHref = (await creator.getAttribute("href"))!;
  const creatorTid = (await creator.getAttribute("data-tid"))!;

  await openTask.click();
  await expect(draft).toHaveClass(/\bactive\b/);
  await expect(page.locator(".input-textarea:visible")).toHaveValue(
    "reply with widget-fixed\n\n---\n" +
      "This task description was written by another task " +
      `(\`tid\` ${creatorTid}) using mcp__cydo__CreateTask, not by the user.\n`,
  );
  const provenance = page.locator(".task-origin:visible a");
  await expect(provenance).toHaveAttribute("href", creatorHref);
  await provenance.click();
  await expect(creator).toHaveClass(/\bactive\b/);
});
