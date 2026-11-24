import { beforeEach, describe, expect, it, vi } from "vitest";
import { outbox } from "./outbox";

const entries = new Map<string, string>();
const setItem = vi.fn((key: string, value: string) => entries.set(key, value));

Object.defineProperty(globalThis, "localStorage", {
  value: {
    getItem: (key: string) => entries.get(key) ?? null,
    setItem,
  },
});

describe("outbox task reload", () => {
  beforeEach(() => {
    entries.clear();
    setItem.mockClear();
  });

  it("only settles a matching task and entry kind without writing on misses", () => {
    const send = { tid: 1, nonce: "send", content: [], createdAt: 1 };
    const draft = { ...send, nonce: "draft", recoveredDraft: "" };
    outbox.add(send);
    outbox.add(draft);
    setItem.mockClear();

    const listener = vi.fn();
    const unsubscribe = outbox.subscribe(listener);
    try {
      outbox.acceptSend(2, "send");
      outbox.acceptSend(1, "draft");
      outbox.acceptSend(1, "historical-echo");
      outbox.acknowledgeDraft(2, "draft");
      outbox.acknowledgeDraft(1, "send");
      expect(outbox.all()).toEqual([send, draft]);
      expect(setItem).not.toHaveBeenCalled();
      expect(listener).not.toHaveBeenCalled();

      outbox.acceptSend(1, "send");
      expect(outbox.all()).toEqual([draft]);
      outbox.acknowledgeDraft(1, "draft");
      expect(outbox.all()).toEqual([]);
      expect(setItem).toHaveBeenCalledTimes(2);
      expect(listener).toHaveBeenCalledTimes(2);
    } finally {
      unsubscribe();
    }
  });

  it("clears submitted entries for the reloaded task without affecting another task", () => {
    outbox.add({
      tid: 1,
      nonce: "submitted",
      content: "removed",
      createdAt: 1,
    });
    outbox.add({ tid: 2, nonce: "other", content: "draft", createdAt: 2 });

    outbox.removeForTask(1);

    expect(outbox.byTid(1)).toEqual([]);
    expect(outbox.byTid(2)).toEqual([
      { tid: 2, nonce: "other", content: "draft", createdAt: 2 },
    ]);
  });

  it("replaces the rejected entry and keeps only the latest recovery through history reload", () => {
    const rejected = {
      tid: 1,
      nonce: "rejected",
      content: [{ type: "text", text: "follow-up" }],
      createdAt: 1,
    };
    outbox.add(rejected);
    outbox.add({
      ...rejected,
      content: [],
      recoveredDraft: "draft with follow-up",
    });
    expect(outbox.all()).toMatchObject([
      {
        nonce: "rejected",
        content: [],
        recoveredDraft: "draft with follow-up",
      },
    ]);

    const recovered = {
      ...rejected,
      nonce: "edit",
      content: [],
      recoveredDraft: "",
    };
    outbox.add(recovered);
    outbox.add({ ...rejected, nonce: "unknown" });
    outbox.removeForTask(1, true);

    expect(outbox.all()).toEqual([recovered]);
    outbox.removeForTask(1);
    expect(outbox.all()).toEqual([]);
  });
});
