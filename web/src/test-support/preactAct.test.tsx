// @vitest-environment jsdom
import { describe, expect, it, vi } from "vitest";
import { joinedRows } from "./preactAct";

describe.sequential("joinedRows", { shuffle: false }, () => {
  const run = joinedRows();
  let xSettledAt: number | undefined;
  let xSignal: AbortSignal | undefined;

  it.fails(
    "times out while the row is still running",
    { timeout: 50 },
    (context) =>
      run(context, async (row) => {
        xSignal = row.signal;
        try {
          await new Promise<void>((resolve) => setTimeout(resolve, 200));
        } finally {
          xSettledAt = performance.now();
        }
      }),
  );

  it("waits for the timed-out row to settle before starting the next row", (context) =>
    run(context, async () => {
      await Promise.resolve();
      const yStartedAt = performance.now();
      expect(xSettledAt).toBeDefined();
      expect(xSettledAt).toBeLessThanOrEqual(yStartedAt);
      expect(xSignal?.aborted).toBe(true);
    }));

  it("rejects a poll aborted during readiness with the exact abort reason", (context) => {
    const controller = new AbortController();
    const reason = new Error("row cancelled");

    return run({ ...context, signal: controller.signal }, async (row) => {
      const ready = vi.fn(() => {
        controller.abort(reason);
        return false;
      });

      await expect(
        row.poll({ description: "pending stage", ready, steps: 0 }),
      ).rejects.toBe(reason);
      expect(ready).toHaveBeenCalledTimes(1);
    });
  });
});
