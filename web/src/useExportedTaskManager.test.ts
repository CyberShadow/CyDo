import { describe, expect, it } from "vitest";
import { parseExportDataText } from "./useExportedTaskManager";

describe("parseExportDataText", () => {
  it("returns a visible error when export payload is missing", () => {
    const parsed = parseExportDataText(null);
    expect(parsed.data).toBeNull();
    expect(parsed.error).toBe("Missing embedded export data.");
  });

  it("returns a visible error when export payload is invalid JSON", () => {
    const parsed = parseExportDataText("{bad json");
    expect(parsed.data).toBeNull();
    expect(parsed.error).toBe("Failed to parse embedded export data.");
  });

  it("accepts export payloads with tasks array", () => {
    const parsed = parseExportDataText('{"tasks":[{"tid":1}]}');
    expect(parsed.error).toBeNull();
    expect(parsed.data?.tasks).toHaveLength(1);
  });
});
