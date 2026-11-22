import { test, expect, enterSession, sendMessage } from "./fixtures";
import type { Page } from "./fixtures";
import type { AgnosticEvent } from "../../web/src/protocol";

// Follow-up bodies must be rendered as Markdown (agent-authored content).
// This test drives the same parent→completed-child Ask flow as ask-answer.spec.ts
// but sends a message that contains Markdown bold syntax so we can assert that
// the rendered body contains a <strong> element rather than raw **…** text.
test("Follow-up from parent renders body as Markdown (live and after reload)", async ({
  page,
  agentType,
}) => {
  const events = observeTaskEvents(page);
  await enterSession(page);

  // Create a sub-task that completes normally.
  await sendMessage(page, 'call task research reply with "initial-result"');
  const taskStarted = await waitForEvent(
    events,
    0,
    ({ tid, event }) => tid === 1 && isCydoToolStart(event, "Task"),
  );
  const taskResult = await waitForEvent(
    events,
    taskStarted.index + 1,
    ({ tid, event }) =>
      tid === 1 &&
      event.type === "item/result" &&
      event.item_id === taskStarted.event.item_id,
  );
  expect(eventJson(taskResult.event)).toContain("initial-result");

  // Select the parent and wait for its turn to complete before asking.
  await selectTask(page, 1);
  await expect(
    page
      .locator('[data-tid="1"] .message-list')
      .getByText("Done.", { exact: true })
      .last(),
  ).toBeVisible();

  // Parent asks the completed child (tid=2) with a Markdown-formatted message.
  const askStart = events.length;
  await sendMessage(page, "call ask 2 **important question**");
  const askStarted = await waitForEvent(
    events,
    askStart,
    ({ tid, event }) => tid === 1 && isCydoToolStart(event, "Ask"),
  );
  await waitForEvent(
    events,
    askStarted.index + 1,
    ({ tid, event }) =>
      tid === 2 &&
      event.type === "item/started" &&
      event.item_type === "user_message" &&
      // Claude labels its live resumed user echo replay; the askStart
      // boundary still excludes historical events for that driver.
      (agentType === "claude" || !event.is_replay) &&
      !event.is_synthetic &&
      !event.is_meta &&
      eventJson(event).includes("**important question**"),
  );
  const askResult = await waitForEvent(
    events,
    askStarted.index + 1,
    ({ tid, event }) =>
      tid === 1 &&
      event.type === "item/result" &&
      event.item_id === askStarted.event.item_id,
  );
  expect(eventJson(askResult.event)).toContain("follow-up-answered");

  // Navigate to the child task and verify Markdown rendering.
  await selectTask(page, 2);
  const followUpMessage = page
    .locator(
      '[data-tid="2"] .message-list .message.user-message.system-user-message',
      { hasText: "Follow-up from parent" },
    )
    .last();
  await expect(followUpMessage).toBeVisible();

  // The body must contain a <strong> element — proof that **…** was rendered as Markdown.
  await expect(
    followUpMessage.locator(".system-user-body strong").first(),
  ).toBeVisible();

  // After page reload the offline replay path must also render Markdown.
  await page.reload();
  await selectTask(page, 2);

  const followUpMessageAfterReload = page
    .locator(
      '[data-tid="2"] .message-list .message.user-message.system-user-message',
      { hasText: "Follow-up from parent" },
    )
    .last();
  await expect(followUpMessageAfterReload).toBeVisible();
  await expect(
    followUpMessageAfterReload.locator(".system-user-body strong").first(),
  ).toBeVisible();
});

type ObservedEvent = { index: number; tid: number; event: AgnosticEvent };

function observeTaskEvents(page: Page): ObservedEvent[] {
  const events: ObservedEvent[] = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", (frame) => {
      const data = JSON.parse(frame.payload.toString()) as {
        tid?: number;
        event?: AgnosticEvent;
      };
      if (typeof data.tid === "number" && data.event?.type) {
        events.push({ index: events.length, tid: data.tid, event: data.event });
      }
    });
  });
  return events;
}

async function waitForEvent(
  events: ObservedEvent[],
  sinceIndex: number,
  predicate: (event: ObservedEvent) => boolean,
): Promise<ObservedEvent> {
  let match: ObservedEvent | undefined;
  await expect
    .poll(() => {
      match = events.slice(sinceIndex).find(predicate);
      return match !== undefined;
    })
    .toBe(true);
  return match!;
}

function isCydoToolStart(event: AgnosticEvent, name: string): boolean {
  return (
    event.type === "item/started" &&
    event.item_type === "tool_use" &&
    event.tool_server === "cydo" &&
    event.name === name
  );
}

function eventJson(event: AgnosticEvent): string {
  return JSON.stringify(event);
}

async function selectTask(page: Page, tid: number) {
  await page.locator(`.sidebar-item[data-tid="${tid}"]`).click();
  await expect(
    page.locator(`.sidebar-item[data-tid="${tid}"].active`),
  ).toBeVisible();
}
