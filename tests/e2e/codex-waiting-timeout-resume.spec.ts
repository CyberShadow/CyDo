import { test, expect, enterSession, sendMessage } from "./fixtures";

type Event =
  | { kind: "status"; status: string; isProcessing: boolean }
  | { kind: "output"; type: string; deltaType?: string; itemType?: string };

function isAssistantTurnWork(event: Event): boolean {
  return (
    event.kind === "output" &&
    ((event.type === "item/started" &&
      ["text", "thinking", "tool_use"].includes(event.itemType ?? "")) ||
      (event.type === "item/delta" &&
        ["text_delta", "thinking_delta", "input_json_delta"].includes(
          event.deltaType ?? "",
        )))
  );
}

test.use({
  backendEnv: { CYDO_TEST_CODEX_MCP_TOOL_TIMEOUT_SEC: "2" },
});

test(
  "direct Task timeout reactivates its waiting parent on assistant work",
  { tag: "@codex-only" },
  async ({ page }) => {
    const events: Event[] = [];
    // a history replay of the parent (on returning to it below) repeats its
    // past events; only live ones say what happened in which order
    let replaying = false;
    page.on("websocket", (ws) => {
      ws.on("framereceived", (frame) => {
        const data = JSON.parse(frame.payload.toString()) as {
          type?: string;
          task?: { tid?: number; status?: string; isProcessing?: boolean };
          tid?: number;
          event?: { type?: string; delta_type?: string; item_type?: string };
        };
        if (data.tid === 1 && data.type === "task_history_start")
          replaying = true;
        if (data.tid === 1 && data.type === "task_history_end")
          replaying = false;
        if (
          data.type === "task_updated" &&
          data.task?.tid === 1 &&
          data.task.status &&
          typeof data.task.isProcessing === "boolean"
        ) {
          events.push({
            kind: "status",
            status: data.task.status,
            isProcessing: data.task.isProcessing,
          });
        } else if (data.tid === 1 && data.event?.type && !replaying) {
          events.push({
            kind: "output",
            type: data.event.type,
            deltaType: data.event.delta_type,
            itemType: data.event.item_type,
          });
        }
      });
    });

    await enterSession(page);
    const start = events.length;
    await sendMessage(
      page,
      "call task research run command sleep 20 && echo waiting-child-done",
    );

    await expect
      .poll(
        () =>
          events
            .slice(start)
            .some(
              (event) => event.kind === "status" && event.status === "waiting",
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
        .getByText("call task research run command sleep 20")
        .first(),
    ).toBeVisible();

    await expect
      .poll(
        () => {
          const observed = events.slice(start);
          const waitingIndex = observed.findIndex(
            (event) => event.kind === "status" && event.status === "waiting",
          );
          return observed
            .slice(waitingIndex + 1)
            .filter(
              (event) =>
                event.kind === "status" &&
                event.status === "active" &&
                event.isProcessing,
            ).length;
        },
      )
      .toBe(1);

    const observed = events.slice(start);
    const waitingIndex = observed.findIndex(
      (event) => event.kind === "status" && event.status === "waiting",
    );
    const assistantWorkIndex = observed.findIndex(
      (event, index) => index > waitingIndex && isAssistantTurnWork(event),
    );
    const activeIndex = observed.findIndex(
      (event, index) =>
        index > waitingIndex &&
        event.kind === "status" &&
        event.status === "active" &&
        event.isProcessing,
    );

    expect(waitingIndex).toBeGreaterThanOrEqual(0);
    expect(assistantWorkIndex).toBeGreaterThan(waitingIndex);
    expect(activeIndex).toBe(assistantWorkIndex + 1);
    expect(
      observed
        .slice(waitingIndex + 1)
        .filter(
          (event) =>
            event.kind === "status" &&
            event.status === "active" &&
            event.isProcessing,
        ),
    ).toHaveLength(1);
  },
);
