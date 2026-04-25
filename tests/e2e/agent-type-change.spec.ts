import {
  test,
  expect,
  enterSession,
  responseTimeout,
  assistantText,
} from "./fixtures";
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
  }).toPass({ timeout: 5_000 });
  return newTid!;
}

test("changing agent type after draft creation updates backend", async ({
  page,
  agentType,
}) => {
  // Pick a different agent than the default to verify the change propagates.
  // Both claude and codex use HTTP mock endpoints and work in all test projects.
  // Avoid switching to claude in the copilot project (HTTPS_PROXY can interfere).
  const targetAgent = agentType === "codex" ? "claude" : "codex";

  // Capture task_updated broadcasts to verify backend agent type
  const taskUpdatedEvents: Array<{
    tid: number;
    agent_type: string;
  }> = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", (event) => {
      try {
        const data = JSON.parse(event.payload.toString());
        if (data.type === "task_updated" && data.task) {
          taskUpdatedEvents.push({
            tid: data.task.tid,
            agent_type: data.task.agent_type,
          });
        }
      } catch {}
    });
  });

  await enterSession(page);

  // Agent picker should be visible in draft mode
  await expect(page.locator(".agent-picker")).toBeVisible({
    timeout: 5_000,
  });

  const before = await snapshotTids(page);

  // Type something to create a draft task
  const input = page.locator(".input-textarea:visible").first();
  await input.click();
  await input.fill('reply with "agent-type-change-test"');

  // Wait for draft to appear in sidebar
  const draftTid = await waitForNewTid(page, before);
  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"] .draft-label`),
  ).toBeVisible({ timeout: 2_000 });

  // Change the agent picker to a different agent
  await page.locator(".agent-picker").selectOption(targetAgent);
  await expect(page.locator(".agent-picker")).toHaveValue(targetAgent);

  // Send the message
  await page.locator(".btn-send:visible").first().click();

  // Wait for the agent response
  await expect(assistantText(page, "agent-type-change-test")).toBeVisible({
    timeout: responseTimeout(agentType),
  });

  // Verify the backend task has the changed agent_type
  const tid = parseInt(draftTid);
  const finalUpdate = taskUpdatedEvents.filter((e) => e.tid === tid).pop();
  expect(finalUpdate).toBeTruthy();
  expect(finalUpdate!.agent_type).toBe(targetAgent);
});
