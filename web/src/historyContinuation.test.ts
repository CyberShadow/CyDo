// "Load [N] more" must be a continuation of the initial load: its end state
// has to be exactly what an initial load with the larger window would have
// produced. The regression pinned here: a queued send leaves a seq-less
// pending placeholder in the stored history, healed only by its later
// delivery; reducing an older slice in isolation resurrected the placeholder
// as a phantom pending bubble at the bottom of the task.
import { describe, expect, it, vi } from "vitest";

vi.hoisted(() => {
  vi.stubGlobal("CSS", { supports: () => false });
  vi.stubGlobal("document", { querySelector: () => null });
});

import { rebuildFromFrames, type HistoryFrame } from "./historyContinuation";
import { makeTaskState, type TaskState } from "./types";

const NONCE = "queued-nonce-1";

function userFrame(
  text: string,
  seq: number,
  correlationId?: string,
): HistoryFrame {
  return {
    kind: "event",
    msg: {
      type: "item/started",
      item_type: "user_message",
      item_id: `user-${seq}`,
      text,
      content: [{ type: "text", text }],
      ...(correlationId ? { correlation_id: correlationId } : {}),
    } as HistoryFrame["msg"],
    seq,
  };
}

function assistantFrame(text: string, seq: number): HistoryFrame {
  return {
    kind: "event",
    msg: {
      type: "item/started",
      item_type: "text",
      item_id: `assistant-${seq}`,
      text,
    } as HistoryFrame["msg"],
    seq,
  };
}

/** The seq-less placeholder the server broadcasts (and re-sends on replay)
 *  for a message queued while the agent is mid-turn. */
function placeholderFrame(text: string, correlationId: string): HistoryFrame {
  return {
    kind: "unconfirmed",
    msg: {
      type: "item/started",
      item_type: "user_message",
      item_id: "cc-user-msg",
      text,
      content: [{ type: "text", text }],
      pending: true,
    } as HistoryFrame["msg"],
    correlationId,
  };
}

function initFrame(seq: number): HistoryFrame {
  return {
    kind: "event",
    msg: {
      type: "session/init",
      session_id: "session-1",
    } as HistoryFrame["msg"],
    seq,
  };
}

function metadataFrame(model: string, seq: number): HistoryFrame {
  return {
    kind: "event",
    msg: { type: "session/metadata", model } as HistoryFrame["msg"],
    seq,
  };
}

function baseTask(): TaskState {
  return { ...makeTaskState(5, true), uuid: "task-5" };
}

/** Identity-free view of the rendered transcript. */
function transcript(state: TaskState) {
  return state.messages.map((m) => ({
    type: m.type,
    pending: m.pending === true,
    text: m.content.map((b) => ("text" in b ? (b.text ?? "") : "")).join(""),
  }));
}

// arrival order of a task where "queued mid-turn" was sent while the agent
// worked: its placeholder appears mid-stream, its delivery two events later
const FRAMES: HistoryFrame[] = [
  userFrame("first question", 0),
  assistantFrame("first answer", 1),
  placeholderFrame("queued mid-turn", NONCE),
  assistantFrame("long turn continues", 2),
  userFrame("queued mid-turn", 3, NONCE),
  assistantFrame("answer to queued", 4),
];
// the window boundary a windowed initial load would pick: the delivered
// non-pending user message at seq 3
const SUFFIX = FRAMES.slice(4);
const OLDER_SLICE = FRAMES.slice(0, 4);

describe("history continuation", () => {
  it("load-more ends in exactly the state a larger initial load produces", () => {
    const reference = rebuildFromFrames(baseTask(), FRAMES, 0);

    const windowed = rebuildFromFrames(baseTask(), SUFFIX, 3);
    const afterLoadMore = rebuildFromFrames(
      windowed,
      OLDER_SLICE.concat(SUFFIX),
      0,
    );

    expect(transcript(afterLoadMore)).toEqual(transcript(reference));
    expect(afterLoadMore.historyWindowStart).toBe(0);
    expect(afterLoadMore.historyLoaded).toBe(true);
  });

  it("does not resurrect a delivered message as a pending phantom", () => {
    const windowed = rebuildFromFrames(baseTask(), SUFFIX, 3);
    const afterLoadMore = rebuildFromFrames(
      windowed,
      OLDER_SLICE.concat(SUFFIX),
      0,
    );

    const copies = transcript(afterLoadMore).filter(
      (m) => m.text === "queued mid-turn",
    );
    expect(copies).toHaveLength(1);
    expect(copies[0]?.pending).toBe(false);
  });

  it("keeps replayed session context ahead of a load-more slice", () => {
    // a windowed load of a codex-style transcript: the server replays the
    // pre-window session/init and newest session/metadata ahead of the range
    const all: HistoryFrame[] = [
      initFrame(0),
      userFrame("early question", 1),
      metadataFrame("model-b", 2),
      assistantFrame("early answer", 3),
      userFrame("late question", 4),
      assistantFrame("late answer", 5),
    ];
    const reference = rebuildFromFrames(baseTask(), all, 0);

    const initialArrival = [
      initFrame(0),
      metadataFrame("model-b", 2),
      ...all.slice(4),
    ];
    const windowed = rebuildFromFrames(baseTask(), initialArrival, 4);
    expect(windowed.sessionInfo?.model).toBe("model-b");

    // the prepend merge: context the slice covers is dropped, the slice goes
    // first, everything already held follows (mirrors task_history_prepend_end)
    const slice = all.slice(0, 4);
    const sliceEnd = 4;
    const newWindowStart = 0;
    const context: HistoryFrame[] = [];
    const rest: HistoryFrame[] = [];
    for (const f of initialArrival) {
      if (f.kind === "event" && f.seq !== undefined && f.seq < sliceEnd) {
        if (f.seq < newWindowStart) context.push(f);
      } else {
        rest.push(f);
      }
    }
    const afterLoadMore = rebuildFromFrames(
      windowed,
      context.concat(slice, rest),
      newWindowStart,
    );

    expect(transcript(afterLoadMore)).toEqual(transcript(reference));
    expect(afterLoadMore.sessionInfo?.model).toBe("model-b");
  });

  it("keeps a genuinely still-queued placeholder pending", () => {
    // no delivery anywhere: the message is still waiting in the queue
    const stillQueued = [
      userFrame("first question", 0),
      assistantFrame("first answer", 1),
      placeholderFrame("never delivered", "queued-nonce-2"),
    ];
    const rebuilt = rebuildFromFrames(baseTask(), stillQueued, 0);

    const copies = transcript(rebuilt).filter(
      (m) => m.text === "never delivered",
    );
    expect(copies).toHaveLength(1);
    expect(copies[0]?.pending).toBe(true);
  });
});
