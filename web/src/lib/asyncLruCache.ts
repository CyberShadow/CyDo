type CacheEntry<Result> =
  | Readonly<{
      kind: "pending";
      promise: Promise<Result>;
    }>
  | Readonly<{
      kind: "settled";
      result: Result;
    }>;

export class AsyncLruCache<Result> {
  private readonly entries = new Map<string, CacheEntry<Result>>();

  constructor(private readonly capacity: number) {}

  load(source: string, compute: () => Promise<Result>): Promise<Result> {
    const cached = this.entries.get(source);
    if (cached !== undefined) {
      if (cached.kind === "settled") {
        this.entries.delete(source);
        this.entries.set(source, cached);
        return Promise.resolve(cached.result);
      }
      this.entries.delete(source);
      this.entries.set(source, cached);
      return cached.promise;
    }

    const promise = compute().then(
      (result) => {
        const entry = this.entries.get(source);
        if (entry?.kind === "pending" && entry.promise === promise) {
          this.entries.set(source, {
            kind: "settled",
            result,
          });
          this.evictSettledEntries();
        }
        return result;
      },
      (error: unknown) => {
        const entry = this.entries.get(source);
        if (entry?.kind === "pending" && entry.promise === promise)
          this.entries.delete(source);
        throw error;
      },
    );
    this.entries.set(source, { kind: "pending", promise });
    return promise;
  }

  peek(source: string): Result | undefined {
    const cached = this.entries.get(source);
    if (cached === undefined) return undefined;
    if (cached.kind === "pending") return undefined;
    this.entries.delete(source);
    this.entries.set(source, cached);
    return cached.result;
  }

  private evictSettledEntries(): void {
    let settledCount = 0;
    for (const entry of this.entries.values())
      if (entry.kind === "settled") settledCount++;
    while (settledCount > this.capacity) {
      let removed = false;
      for (const [source, entry] of this.entries) {
        if (entry.kind !== "settled") continue;
        this.entries.delete(source);
        settledCount--;
        removed = true;
        break;
      }
      if (!removed) throw new Error("settled parser cache eviction invariant");
    }
  }
}
