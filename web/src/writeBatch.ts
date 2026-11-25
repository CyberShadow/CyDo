export class WriteBatch {
  private readonly owned = new WeakSet();
  private closed = false;
  private entries = 0;

  get copiedEntries(): number {
    this.assertOpen();
    return this.entries;
  }

  map<K, V>(m: ReadonlyMap<K, V>): Map<K, V> {
    this.assertOpen();
    if (this.owned.has(m)) return m as Map<K, V>;
    this.entries += m.size;
    return this.adopt(new Map(m));
  }

  array<T>(a: readonly T[]): T[] {
    this.assertOpen();
    if (this.owned.has(a)) return a as T[];
    this.entries += a.length;
    return this.adopt(a.slice());
  }

  object<T extends object>(o: T): T {
    this.assertOpen();
    if (this.owned.has(o)) return o;
    const copy = { ...o };
    this.entries += Reflect.ownKeys(copy).length;
    return this.adopt(copy);
  }

  adopt<T extends object>(fresh: T): T {
    this.assertOpen();
    this.owned.add(fresh);
    return fresh;
  }

  close(): void {
    this.assertOpen();
    this.closed = true;
  }

  private assertOpen(): void {
    if (this.closed) throw new Error("WriteBatch is closed");
  }
}
