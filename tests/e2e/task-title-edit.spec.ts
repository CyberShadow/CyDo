import type { Page } from "@playwright/test";
import {
  enterSession,
  expect,
  responseTimeout,
  sendMessage,
  test,
} from "./fixtures";

async function expectTaskTitle(page: Page, title: string) {
  await expect(page.locator(".task-bar-title:visible")).toHaveText(title);
  await expect(page.locator(".sidebar-item.active .sidebar-label")).toHaveText(
    title,
  );
}

test(
  "edited task title syncs across tabs and survives a backend restart",
  { tag: "@claude-only" },
  async ({ page, context, backend, agentType }) => {
    const generated = "Generated planning title";
    const edited = "Reviewed planning title";
    await enterSession(page);
    await sendMessage(page, `Please reply with "${generated}"`);
    await expect(page.locator(".task-bar-title:visible")).toHaveText(
      generated,
      {
        timeout: responseTimeout(agentType),
      },
    );

    const taskUrl = page.url();
    const secondTab = await context.newPage();
    await secondTab.goto(taskUrl);
    await expectTaskTitle(secondTab, generated);

    const input = page.getByRole("textbox", { name: "Title", exact: true });
    const editButton = page.getByRole("button", {
      name: "Edit title",
      exact: true,
    });
    await page
      .getByRole("button", { name: "Task details", exact: true })
      .click();
    await expect(input).toBeHidden();
    await editButton.click();
    await expect(input).toBeFocused();
    await input.press("Escape");
    await expect(input).toBeHidden();

    await page
      .getByRole("button", { name: `Edit title: ${generated}` })
      .click();
    await expect(input).toBeFocused();
    await input.fill("");
    await input.press("Enter");
    const error = page.locator(".command-error-dialog");
    await expect(error).toContainText(
      "Title cannot be empty after a task has started",
    );
    await error.getByRole("button", { name: "Dismiss" }).click();
    await expect(input).toHaveValue("");

    await input.fill(edited);
    await page.getByRole("button", { name: "Save", exact: true }).click();

    await expect(input).toBeHidden();
    await expect(editButton).toBeVisible();
    await expectTaskTitle(page, edited);
    await expectTaskTitle(secondTab, edited);

    await backend.restart();
    await page.reload();
    await expectTaskTitle(page, edited);
  },
);
