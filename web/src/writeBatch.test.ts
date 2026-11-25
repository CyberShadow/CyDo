import { describe, expect, it } from "vitest";

import { deepFreeze } from "./testing/deepFreeze";
import { WriteBatch } from "./writeBatch";

describe("WriteBatch", () => {
  it("copies a foreign map and reuses the copy for subsequent writes", () => {
    const batch = new WriteBatch();
    const original = new Map([["existing", 1]]);
    const copy = batch.map(original);

    expect(copy).not.toBe(original);
    expect(copy).toEqual(original);
    batch.map(copy).set("added", 2);
    expect(batch.map(copy)).toBe(copy);
    expect(copy.get("added")).toBe(2);
    expect(original.has("added")).toBe(false);
    expect(new WriteBatch().map(copy)).not.toBe(copy);
  });

  it("copies a foreign array and reuses the copy for subsequent writes", () => {
    const batch = new WriteBatch();
    const original = [1];
    const copy = batch.array(original);

    expect(copy).not.toBe(original);
    expect(copy).toEqual(original);
    batch.array(copy).push(2);
    expect(batch.array(copy)).toBe(copy);
    expect(copy).toEqual([1, 2]);
    expect(original).toEqual([1]);
    expect(new WriteBatch().array(copy)).not.toBe(copy);
  });

  it("copies a foreign object and reuses the copy for subsequent writes", () => {
    const batch = new WriteBatch();
    const original = { value: 1 };
    const copy = batch.object(original);

    expect(copy).not.toBe(original);
    expect(copy).toEqual(original);
    batch.object(copy).value = 2;
    expect(batch.object(copy)).toBe(copy);
    expect(copy.value).toBe(2);
    expect(original.value).toBe(1);
    expect(new WriteBatch().object(copy)).not.toBe(copy);
  });

  it("adopts fresh containers without copying them", () => {
    const batch = new WriteBatch();
    const map = new Map([["value", 1]]);
    const array = [1];
    const object = { value: 1 };

    expect(batch.adopt(map)).toBe(map);
    expect(batch.adopt(array)).toBe(array);
    expect(batch.adopt(object)).toBe(object);
    expect(batch.map(map)).toBe(map);
    expect(batch.array(array)).toBe(array);
    expect(batch.object(object)).toBe(object);
    expect(batch.copiedEntries).toBe(0);
  });

  it("sums map size, array length, and own enumerable object keys", () => {
    const batch = new WriteBatch();
    const symbol = Symbol("visible");
    const original = { visible: 1, [symbol]: 2 };
    Object.setPrototypeOf(original, { inherited: 3 });
    Object.defineProperty(original, "hidden", { value: 4 });
    const sparse = [1];
    sparse.length = 4;

    expect(batch.copiedEntries).toBe(0);
    const map = batch.map(
      new Map([
        ["a", 1],
        ["b", 2],
        ["c", 3],
      ]),
    );
    expect(batch.copiedEntries).toBe(3);
    const array = batch.array(sparse);
    expect(batch.copiedEntries).toBe(7);
    const object = batch.object(original);
    expect(batch.copiedEntries).toBe(9);

    batch.map(map);
    batch.array(array);
    batch.object(object);
    expect(batch.copiedEntries).toBe(9);
  });

  it.each([
    ["map", (batch: WriteBatch) => batch.map(new Map())],
    ["array", (batch: WriteBatch) => batch.array([])],
    ["object", (batch: WriteBatch) => batch.object({})],
    ["adopt", (batch: WriteBatch) => batch.adopt({})],
    ["copiedEntries", (batch: WriteBatch) => batch.copiedEntries],
    [
      "close",
      (batch: WriteBatch) => {
        batch.close();
      },
    ],
  ] as const)("throws when accessing %s after close", (_, access) => {
    const batch = new WriteBatch();
    batch.close();
    expect(() => access(batch)).toThrow();
  });

  it("rejects writes to already owned values after close", () => {
    const batch = new WriteBatch();
    const map = batch.adopt(new Map());
    const array = batch.adopt([]);
    const object = batch.adopt({});
    batch.close();

    expect(() => batch.map(map)).toThrow();
    expect(() => batch.array(array)).toThrow();
    expect(() => batch.object(object)).toThrow();
  });
});

describe("deepFreeze", () => {
  it("rejects every Map mutator and freezes both keys and values", () => {
    const key = { id: 1 };
    const value = { count: 1 };
    const map = deepFreeze(new Map([[key, value]]));

    expect(() => map.set(key, { count: 2 })).toThrow(TypeError);
    expect(() => map.delete(key)).toThrow(TypeError);
    expect(() => {
      map.clear();
    }).toThrow(TypeError);
    expect(() => {
      key.id = 2;
    }).toThrow(TypeError);
    expect(() => {
      value.count = 2;
    }).toThrow(TypeError);
  });

  it("rejects every Set mutator and freezes its entries", () => {
    const entry = { id: 1 };
    const set = deepFreeze(new Set([entry]));

    expect(() => set.add({ id: 2 })).toThrow(TypeError);
    expect(() => set.delete(entry)).toThrow(TypeError);
    expect(() => {
      set.clear();
    }).toThrow(TypeError);
    expect(() => {
      entry.id = 2;
    }).toThrow(TypeError);
  });

  it("rejects array mutation and assignment to nested objects", () => {
    const item = { id: 1 };
    const items = [item];
    const state = { items };

    expect(deepFreeze(state)).toBe(state);
    expect(() => items.push({ id: 2 })).toThrow(TypeError);
    expect(() => items.splice(0, 1)).toThrow(TypeError);
    expect(() => {
      items[0] = { id: 2 };
    }).toThrow(TypeError);
    expect(() => {
      item.id = 2;
    }).toThrow(TypeError);
    expect(() => {
      state.items = [];
    }).toThrow(TypeError);
  });

  it("freezes a cycle through a collection", () => {
    const cycle = { links: new Set<object>() };
    cycle.links.add(cycle);

    expect(deepFreeze(cycle)).toBe(cycle);
    expect(Object.isFrozen(cycle)).toBe(true);
    expect(() => {
      cycle.links.clear();
    }).toThrow(TypeError);
  });

  it("skips traversing already frozen values", () => {
    const child = { count: 1 };
    const frozen = Object.freeze({ child });
    const parent = deepFreeze({ frozen });

    expect(Object.isFrozen(parent)).toBe(true);
    child.count = 2;
    expect(parent.frozen.child.count).toBe(2);
  });
});
