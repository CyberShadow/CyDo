import { describe, expect, it } from "vitest";
import { shouldHandleSidebarAltArchive } from "./Sidebar";

describe("Sidebar archive click guard", () => {
  it("allows Alt-click archive when task is not archiving", () => {
    expect(shouldHandleSidebarAltArchive(true, true, false)).toBe(true);
  });

  it("blocks Alt-click archive while task is archiving", () => {
    expect(shouldHandleSidebarAltArchive(true, true, true)).toBe(false);
  });

  it("blocks non-Alt clicks and missing handlers", () => {
    expect(shouldHandleSidebarAltArchive(false, true, false)).toBe(false);
    expect(shouldHandleSidebarAltArchive(true, false, false)).toBe(false);
  });
});
