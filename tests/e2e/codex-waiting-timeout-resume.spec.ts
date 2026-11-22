import { test, expect, enterSession, sendMessage } from "./fixtures";
import type { AgnosticEvent } from "../../web/src/protocol";

type Event =
  | { kind: "status"; status: string; isProcessing: boolean }
  | { kind: "output"; event: AgnosticEvent };

function isAssistantTurnWork(event: Event): boolean {
  if (event.kind !== "output") return false;
  const output = event.event;
  if (output.type === "item/delta") {
    return ["text_delta", "thinking_delta", "input_json_delta"].includes(
      output.delta_type,
    );
  }
  if (output.type !== "item/started") return false;
  if (output.is_replay || output.is_synthetic || output.is_meta) return false;
  return (
    output.item_type === "text" ||
    output.item_type === "thinking" ||
    (output.item_type === "tool_use" && output.tool_server !== "cydo")
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
    page.on("websocket", (ws) => {
      ws.on("framereceived", (frame) => {
        const data = JSON.parse(frame.payload.toString()) as {
          type?: string;
          task?: { tid?: number; status?: string; isProcessing?: boolean };
          tid?: number;
          event?: AgnosticEvent;
        };
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
        } else if (data.tid === 1 && data.event?.type) {
          events.push({ kind: "output", event: data.event });
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
