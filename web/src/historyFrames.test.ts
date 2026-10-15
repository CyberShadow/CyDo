import { describe, expect, it } from "vitest";
import {
  appendFrame,
  mergeFramesBySeq,
  type HistoryFrame,
} from "./historyContinuation";
import type { AgnosticEvent } from "./protocol";

function event(seq: number, msg: object): HistoryFrame {
  return { kind: "event", msg: msg as AgnosticEvent, seq };
}

function delta(seq: number, itemId: string, content: string): HistoryFrame {
  return event(seq, {
    type: "item/delta",
    item_id: itemId,
    delta_type: "text_delta",
    content,
  });
}

describe("frame cache", () => {
  it("merges consecutive deltas of one item into one frame", () => {
    const frames: HistoryFrame[] = [];
    appendFrame(frames, delta(4, "a", "he"));
    appendFrame(frames, delta(4, "a", "ll"));
    appendFrame(frames, delta(4, "a", "o"));
    expect(frames).toHaveLength(1);
    expect((frames[0] as { msg: { content: string } }).msg.content).toBe(
      "hello",
    );
  });

  it("keeps deltas of different items, kinds, or seqs apart", () => {
    const frames: HistoryFrame[] = [];
    appendFrame(frames, delta(4, "a", "x"));
    appendFrame(frames, delta(4, "b", "y"));
    appendFrame(frames, delta(5, "b", "z"));
    appendFrame(frames, event(6, { type: "item/completed", item_id: "b" }));
    appendFrame(frames, delta(6, "b", "w"));
    expect(frames).toHaveLength(5);
  });

  it("places a fetched batch by seq, the batch winning a shared seq", () => {
    const unconfirmed: HistoryFrame = {
      kind: "unconfirmed",
      msg: { type: "item/started" } as AgnosticEvent,
    };
    const cached = [
      event(0, { type: "session/init", cached: true }),
      event(5, { type: "item/started" }),
      unconfirmed,
      event(9, { type: "item/started" }),
    ];
    const batch = [
      event(7, {}),
      event(0, { type: "session/init" }),
      event(3, {}),
    ];
    const merged = mergeFramesBySeq(cached, batch);
    expect(merged.map((f) => (f.kind === "event" ? f.seq : "u"))).toEqual([
      0,
      3,
      5,
      "u",
      7,
      9,
    ]);
    expect(merged[0]).toBe(batch[1]);
  });

  it("keeps a batch's unconfirmed sends with the events around them", () => {
    const queued = (text: string): HistoryFrame => ({
      kind: "unconfirmed",
      msg: { type: "item/started", text } as unknown as AgnosticEvent,
    });
    const cached = [event(0, { type: "session/init" }), event(20, {})];
    const batch = [
      queued("ahead"),
      event(10, {}),
      queued("after 10"),
      queued("also after 10"),
      event(12, {}),
    ];
    const merged = mergeFramesBySeq(cached, batch);
    expect(
      merged.map((f) =>
        f.kind === "event"
          ? f.seq
          : (f.msg as unknown as { text: string }).text,
      ),
    ).toEqual([0, "ahead", 10, "after 10", "also after 10", 12, 20]);
  });

  it("still refuses a fetched event without a seq", () => {
    expect(() =>
      mergeFramesBySeq([], [{ kind: "event", msg: {} as AgnosticEvent }]),
    ).toThrow("a fetched history event without a seq");
  });
});
