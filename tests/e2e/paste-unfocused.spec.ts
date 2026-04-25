import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
} from "./fixtures";

test("paste when input is unfocused populates session input", async ({
  page,
  agentType,
}) => {
  await enterSession(page);
  await sendMessage(page, 'Please reply with "paste-unfocused-test"');
  await expect(assistantText(page, "paste-unfocused-test")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // Click on the message list to move focus away from the input
  await page.locator(".message-list").click();
  await page.evaluate(() =>
    (document.activeElement as HTMLElement | null)?.blur(),
  );

  // Dispatch a paste event to the document (not targeting the textarea)
  await page.evaluate(() => {
    const dt = new DataTransfer();
    dt.setData("text/plain", "hello-pasted");
    document.dispatchEvent(
      new ClipboardEvent("paste", { clipboardData: dt, bubbles: true }),
    );
  });

  // The pasted text should appear in the input
  await expect(page.locator(".input-textarea:visible").first()).toHaveValue(
    "hello-pasted",
  );
});

test("paste when input is unfocused on new-task page populates input", async ({
  page,
  agentType,
}) => {
  test.skip(agentType !== "claude", "agent-agnostic, runs once");
  await enterSession(page);

  // Blur whichever element currently has focus
  await page.evaluate(() =>
    (document.activeElement as HTMLElement | null)?.blur(),
  );

  // Dispatch a paste event to the document
  await page.evaluate(() => {
    const dt = new DataTransfer();
    dt.setData("text/plain", "newtask-pasted");
    document.dispatchEvent(
      new ClipboardEvent("paste", { clipboardData: dt, bubbles: true }),
    );
  });

  // The pasted text should appear in the new-task input
  await expect(page.locator(".input-textarea:visible").first()).toHaveValue(
    "newtask-pasted",
  );
});
