import { describe, expect, it } from "vitest";
import { isCompactingStatus, normalizeSessionStatus } from "./SystemBanner";

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
});
