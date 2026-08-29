/**
 * Continuation of a task's history replay.
 *
 * "Load [N] more" must behave as a continuation of the initial load: its end
 * state has to be exactly what an initial load with the larger window would
 * have produced. The only structure that guarantees that is re-running the
 * same reduction over the same input, so every frame that built the current
 * timeline is kept in arrival order, a load-more fetches only the older
 * slice, and the whole sequence is reduced again from the same reset an
 * initial replay starts from. Reducing the older slice in isolation and
 * merging message lists loses cross-references: a queued send's placeholder
 * healed by its later delivery, a consumption event upgrading an earlier
 * bubble. That split is what resurrected already-delivered messages as
 * phantom pending bubbles.
 */
import type { AgnosticEvent, AssistantContentBlock } from "./protocol";
import { resetTaskForHistoryReplay } from "./historyReplayReset";
import { reduceMessage, replaceHistoryBoundary } from "./sessionReducer";
import type { CydoMeta, HistoryBoundary, TaskState } from "./types";

/** One frame as it arrived over the socket, in the two shapes the timeline
 *  is built from: seq'd task events, and seq-less unconfirmed placeholders. */
export type HistoryFrame =
  | { kind: "event"; msg: AgnosticEvent; seq?: number; ts?: number }
  | { kind: "unconfirmed"; msg: AgnosticEvent; correlationId?: string };

export type HistoryBoundaryEvent =
  | (Extract<AgnosticEvent, { type: "item/started" }> & {
      history_boundary: HistoryBoundary;
    })
  | (Extract<AgnosticEvent, { type: "turn/stop" }> & {
      history_boundary: HistoryBoundary;
    });

export function hasHistoryBoundary(
  event: AgnosticEvent,
): event is HistoryBoundaryEvent {
  return (
    (event.type === "item/started" || event.type === "turn/stop") &&
    event.history_boundary !== undefined
  );
}

/// Extract text content from a user message event (for unconfirmed display).
export function extractTextContent(msg: AgnosticEvent): string {
  if (msg.type !== "item/started" || msg.item_type !== "user_message")
    return "";
  return msg.text ?? "";
}

/** The state transform for an unconfirmed (queued, not yet delivered) user
 *  message: upgrade a local placeholder with the same nonce if one exists,
 *  otherwise append a fresh pending bubble. Pure; side effects (outbox,
 *  notifications) stay with the live caller. */
export function reduceUnconfirmedUserMessage(
  prev: TaskState,
  msg: AgnosticEvent,
  correlationId?: string,
): TaskState {
  const meta = (msg as Record<string, unknown>).meta as CydoMeta | undefined;
  const content = ((msg as Record<string, unknown>).content as
    | AssistantContentBlock[]
    | undefined) ?? [{ type: "text" as const, text: extractTextContent(msg) }];

  if (correlationId) {
    const idx = prev.messages.findIndex(
      (m) => m.type === "user" && m.nonce === correlationId,
    );
    if (idx >= 0) {
      return {
        ...prev,
        messages: prev.messages.map((m, i) =>
          i === idx
            ? {
                ...m,
                ackState: 3 as const,
                pending: true,
                isProvisional: true,
              }
            : m,
        ),
      };
    }
  }

  const msgIdCounter = prev.msgIdCounter + 1;
  return {
    ...prev,
    msgIdCounter,
    messages: [
      ...prev.messages,
      {
        id: `pending-${msgIdCounter}`,
        type: "user" as const,
        content,
        ackState: 3 as const,
        pending: true,
        nonce: correlationId,
        cydoMeta: meta,
        isProvisional: true,
      },
    ],
  };
}

/** Reduce one frame into the timeline exactly the way the live path does. */
export function reduceHistoryFrame(
  state: TaskState,
  frame: HistoryFrame,
): TaskState {
  if (frame.kind === "unconfirmed")
    return reduceUnconfirmedUserMessage(state, frame.msg, frame.correlationId);
  let updated = reduceMessage(state, frame.msg, frame.seq, frame.ts);
  if (hasHistoryBoundary(frame.msg) && frame.seq !== undefined)
    updated = replaceHistoryBoundary(updated, frame.msg, frame.seq);
  return updated;
}

/** Rebuild a task's timeline from the complete frame sequence: the same
 *  reset an initial replay starts from, then every frame in order. Fields
 *  that do not derive from the timeline ride through the reset untouched. */
export function rebuildFromFrames(
  task: TaskState,
  frames: readonly HistoryFrame[],
  windowStart: number,
): TaskState {
  let state: TaskState = resetTaskForHistoryReplay(task, frames.length);
  for (const frame of frames) state = reduceHistoryFrame(state, frame);
  return {
    ...state,
    historyLoaded: true,
    everLoaded: true,
    historyTotal: undefined,
    historyReceived: undefined,
    historyWindowStart: windowStart,
  };
}
