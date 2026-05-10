import { describe, expect, it } from "vitest";
import {
  computeUsagePaceRatio,
  isCompactingStatus,
  normalizeSessionStatus,
  usagePercent,
  usageFillColor,
} from "./SystemBanner";

describe("SystemBanner status helpers", () => {
  it("recognizes codex compacting status strings", () => {
    expect(isCompactingStatus("compacting")).toBe(true);
    expect(isCompactingStatus("Compacting context...")).toBe(true);
  });

  it("does not treat non-compacting statuses as compacting", () => {
    expect(isCompactingStatus("requesting")).toBe(false);
    expect(isCompactingStatus("compacted")).toBe(false);
  });

  it("normalizes empty status strings to null", () => {
    expect(normalizeSessionStatus("")).toBeNull();
    expect(normalizeSessionStatus("   ")).toBeNull();
    expect(normalizeSessionStatus("requesting")).toBe("requesting");
  });

  it("colors usage by pace ratio thresholds", () => {
    const now = 1_700_000_000;
    const fiveHour = 5 * 60 * 60;

    const green = usageFillColor(0.5, now + fiveHour, fiveHour, now);
    const yellow = usageFillColor(
      20,
      now + fiveHour - fiveHour * 0.2,
      fiveHour,
      now,
    );
    const red = usageFillColor(
      95,
      now + fiveHour - fiveHour * 0.2,
      fiveHour,
      now,
    );

    expect(green).toBe("rgb(76, 175, 80)");
    expect(yellow).toBe("rgb(242, 153, 74)");
    expect(red).toBe("rgb(220, 67, 67)");
  });

  it("computes pace ratio using elapsed window progress", () => {
    const now = 1_700_000_000;
    const week = 7 * 24 * 60 * 60;
    const ratio = computeUsagePaceRatio(70, now + week * 0.5, week, now);
    expect(ratio).toBeCloseTo(1.4, 3);
  });

  it("treats missing utilization as unknown", () => {
    expect(usagePercent(undefined)).toBeNull();
    expect(usagePercent(Number.NaN)).toBeNull();
    expect(usagePercent(0.42)).toBe(42);
  });
});
