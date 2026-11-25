function frozenMutation(): never {
  throw new TypeError("Cannot mutate a frozen collection");
}

export function deepFreeze<T>(value: T): T {
  const visited = new WeakSet();

  function freeze(object: unknown): void {
    if (
      object === null ||
      typeof object !== "object" ||
      Object.isFrozen(object) ||
      visited.has(object)
    ) {
      return;
    }
    visited.add(object);

    if (object instanceof Map) {
      for (const [key, entry] of object) {
        freeze(key);
        freeze(entry);
      }
      Object.defineProperty(object, "set", { value: frozenMutation });
    } else if (object instanceof Set) {
      for (const entry of object) freeze(entry);
      Object.defineProperty(object, "add", { value: frozenMutation });
    }
    if (object instanceof Map || object instanceof Set) {
      Object.defineProperties(object, {
        delete: { value: frozenMutation },
        clear: { value: frozenMutation },
      });
    }

    for (const key of Reflect.ownKeys(object)) {
      freeze(Object.getOwnPropertyDescriptor(object, key)!.value);
    }
    Object.freeze(object);
  }

  freeze(value);
  return value;
}
