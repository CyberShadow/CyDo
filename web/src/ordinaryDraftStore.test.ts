import { describe, expect, it, vi } from "vitest";
import { createOrdinaryDraftStore } from "./ordinaryDraftStore";

describe("OrdinaryDraftStore", () => {
  it("initializes missing entries from their first hydration value", () => {
    const store = createOrdinaryDraftStore();

    expect(store.ensure("task", "server draft")).toBe("server draft");
    expect(store.ensure("task", "later snapshot")).toBe("server draft");
    expect(store.read("task")).toBe("server draft");
  });

  it("requires an entry before writing or registering", () => {
    const store = createOrdinaryDraftStore();

    expect(() => {
      store.write("missing", "text");
    }).toThrow("Missing ordinary draft: missing");
    expect(() => store.register("missing", () => {})).toThrow(
      "Missing ordinary draft: missing",
    );
  });

  it("accepts blank and exact-old remote updates", () => {
    const store = createOrdinaryDraftStore();
    store.ensure("blank", "");
    store.ensure("equal", "A");

    expect(store.applyRemote("blank", { old_draft: "A", new_draft: "B" })).toBe(
      true,
    );
    expect(store.applyRemote("equal", { old_draft: "A", new_draft: "B" })).toBe(
      true,
    );
    expect(store.read("blank")).toBe("B");
    expect(store.read("equal")).toBe("B");
  });

  it("rejects a remote update when local text has diverged", () => {
    const store = createOrdinaryDraftStore();
    const listener = vi.fn();
    store.ensure("task", "local");
    store.register("task", listener);
    listener.mockClear();

    expect(
      store.applyRemote("task", { old_draft: "server", new_draft: "next" }),
    ).toBe(false);
    expect(store.read("task")).toBe("local");
    expect(listener).not.toHaveBeenCalled();
  });

  it("creates a missing remote baseline and applies ordered chains", () => {
    const store = createOrdinaryDraftStore();

    expect(store.applyRemote("task", { old_draft: "A", new_draft: "B" })).toBe(
      true,
    );
    expect(store.applyRemote("task", { old_draft: "B", new_draft: "C" })).toBe(
      true,
    );
    expect(store.applyRemote("task", { old_draft: "C", new_draft: "" })).toBe(
      true,
    );
    expect(store.read("task")).toBe("");
  });

  it("reflects current state immediately and synchronously notifies accepted updates", () => {
    const store = createOrdinaryDraftStore();
    const listener = vi.fn();
    store.ensure("task", "A");

    const unregister = store.register("task", listener);
    expect(listener).toHaveBeenCalledExactlyOnceWith("A");
    listener.mockClear();

    expect(store.applyRemote("task", { old_draft: "A", new_draft: "B" })).toBe(
      true,
    );
    expect(store.read("task")).toBe("B");
    expect(listener).toHaveBeenCalledExactlyOnceWith("B");

    unregister();
  });

  it("rejects duplicate listeners", () => {
    const store = createOrdinaryDraftStore();
    store.ensure("task", "");
    store.register("task", () => {});

    expect(() => store.register("task", () => {})).toThrow(
      "Ordinary draft already has a listener: task",
    );
  });

  it("does not let stale cleanup affect a retired and recreated entry", () => {
    const store = createOrdinaryDraftStore();
    const first = vi.fn();
    const second = vi.fn();
    store.ensure("task", "A");
    const unregisterFirst = store.register("task", first);
    store.retire("task");
    store.ensure("task", "B");
    store.register("task", second);
    second.mockClear();

    unregisterFirst();
    store.write("task", "C");
    store.applyRemote("task", { old_draft: "C", new_draft: "D" });

    expect(second.mock.calls).toEqual([["C"], ["D"]]);
  });

  it("clears all entries", () => {
    const store = createOrdinaryDraftStore();
    store.ensure("first", "A");
    store.ensure("second", "B");

    store.clear();

    expect(store.read("first")).toBeUndefined();
    expect(store.read("second")).toBeUndefined();
  });
});
