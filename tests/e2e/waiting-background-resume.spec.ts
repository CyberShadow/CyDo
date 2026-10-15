import { existsSync, rmSync, writeFileSync } from "node:fs";
import { test, expect, enterSession, sendMessage } from "./fixtures";

const fifoPath = "/tmp/cydo-test-workspace/waiting-background-resume.fifo";

type ParentEvent =
  | { kind: "status"; status: string; isProcessing: boolean }
  | { kind: "output"; type: string; itemType?: string; deltaType?: string };

function isAssistantTurnWork(event: ParentEvent): boolean {
  return (
    event.kind === "output" &&
    ((event.type === "item/started" &&
      (event.itemType === "text" ||
        event.itemType === "thinking" ||
        event.itemType === "tool_use")) ||
      (event.type === "item/delta" &&
        (event.deltaType === "text_delta" ||
          event.deltaType === "thinking_delta" ||
          event.deltaType === "input_json_delta")))
  );
}

test(
  "background output leaves a waiting parent waiting before child-result resume",
  { tag: "@codex-only" },
  async ({ page }) => {
    rmSync(fifoPath, { force: true });
    try {
      const events: ParentEvent[] = [];
      page.on("websocket", (ws) => {
        ws.on("framereceived", (frame) => {
          try {
            const data = JSON.parse(frame.payload.toString()) as {
              type?: string;
              task?: { tid?: number; status?: string; isProcessing?: boolean };
              tid?: number;
              event?: {
                type?: string;
                item_type?: string;
                delta_type?: string;
              };
            };
            if (
              data.type === "task_updated" &&
              data.task?.tid === 1 &&
              typeof data.task.status === "string" &&
              typeof data.task.isProcessing === "boolean"
            ) {
              events.push({
                kind: "status",
                status: data.task.status,
                isProcessing: data.task.isProcessing,
              });
            } else if (data.tid === 1 && typeof data.event?.type === "string") {
              events.push({
                kind: "output",
                type: data.event.type,
                itemType: data.event.item_type,
                deltaType: data.event.delta_type,
              });
            }
          } catch {
            // Ignore non-JSON frames and unrelated events.
          }
        });
      });

      await enterSession(page);
      const eventStart = events.length;
      await sendMessage(page, "call waiting background resume fixture");

      await expect
        .poll(() => existsSync(fifoPath))
        .toBe(true);
      await expect
        .poll(
          () =>
            events
              .slice(eventStart)
              .some(
                (event) =>
                  event.kind === "status" && event.status === "waiting",
              ),
        )
        .toBe(true);

      // the Task call moved the page to the child, and a page receives only
      // the task it shows; back on the parent, its live output reaches the
      // page again
      await page.locator('.sidebar-item[data-tid="1"]').click();
      await expect(page.locator('.sidebar-item[data-tid="1"].active')).toBeVisible();
      await expect(
        page
          .locator('[style*="display: contents"] .message-list')
          .getByText("call waiting background resume fixture")
          .first(),
      ).toBeVisible();

      writeFileSync(fifoPath, "release\n");

      await expect
        .poll(
          () => {
            const resumedEvents = events.slice(eventStart);
            const waitingIndex = resumedEvents.findIndex(
              (event) => event.kind === "status" && event.status === "waiting",
            );
            const outputIndex = resumedEvents.findIndex(
              (event, index) =>
                index > waitingIndex &&
                event.kind === "output" &&
                event.type === "item/delta" &&
                event.deltaType === "output_delta",
            );
            return outputIndex;
          },
        )
        .toBeGreaterThanOrEqual(0);

      const resumedEvents = events.slice(eventStart);
      const waitingIndex = resumedEvents.findIndex(
        (event) => event.kind === "status" && event.status === "waiting",
      );
      const outputIndex = resumedEvents.findIndex(
        (event, index) =>
          index > waitingIndex &&
          event.kind === "output" &&
          event.type === "item/delta" &&
          event.deltaType === "output_delta",
      );
      expect(outputIndex).toBeGreaterThan(waitingIndex);
      expect(
        resumedEvents
          .slice(waitingIndex + 1, outputIndex)
          .some(
            (event) => event.kind === "status" && event.status !== "waiting",
          ),
      ).toBe(false);
      await expect(
        page.locator('.sidebar-item[data-tid="1"] .task-type-icon.waiting'),
      ).toBeVisible();

      await expect
        .poll(
          () =>
            events
              .slice(eventStart)
              .some(
                (event, index) =>
                  index > outputIndex &&
                  event.kind === "status" &&
                  event.status === "active" &&
                  event.isProcessing,
              ),
        )
        .toBe(true);

      const activeIndex = events
        .slice(eventStart)
        .findIndex(
          (event, index) =>
            index > outputIndex &&
            event.kind === "status" &&
            event.status === "active" &&
            event.isProcessing,
        );
      expect(activeIndex).toBeGreaterThan(outputIndex);
      expect(
        events
          .slice(eventStart + outputIndex + 1, eventStart + activeIndex)
          .some(isAssistantTurnWork),
      ).toBe(false);
      await expect
        .poll(
          () =>
            events
              .slice(eventStart + activeIndex + 1)
              .some(
                (event) =>
                  event.kind === "output" &&
                  event.type === "item/delta" &&
                  event.deltaType === "text_delta",
              ),
        )
        .toBe(true);

      const afterWait = events.slice(eventStart);
      expect(
        afterWait.filter(
          (event, index) =>
            index > outputIndex &&
            event.kind === "status" &&
            event.status === "active" &&
            event.isProcessing,
        ),
      ).toHaveLength(1);

      await expect
        .poll(
          () =>
            events
              .slice(eventStart)
              .some(
                (event) => event.kind === "status" && event.status === "alive",
              ),
        )
        .toBe(true);
      await page.reload();
      await expect(
        page.locator('.sidebar-item[data-tid="1"] .task-type-icon.alive'),
      ).toBeVisible();
    } finally {
      rmSync(fifoPath, { force: true });
    }
  },
);
