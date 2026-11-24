import { describe, expect, it } from "vitest";
import { parseCreatedTaskResult } from "./cydoToolResults";

describe("parseCreatedTaskResult", () => {
  const result = {
    tid: 7,
    workspace: "local",
    project_path: "/project",
    entry_point: "agentic",
    status: "draft",
  };

  it("parses structured and serialized results", () => {
    expect(parseCreatedTaskResult({ structuredContent: result })).toEqual(
      result,
    );
    expect(parseCreatedTaskResult(JSON.stringify(result))).toEqual(result);
  });

  it("rejects errors and malformed payloads", () => {
    expect(
      parseCreatedTaskResult({ isError: true, structuredContent: result }),
    ).toBeUndefined();
    expect(parseCreatedTaskResult({ ...result, tid: "7" })).toBeUndefined();
    expect(parseCreatedTaskResult("malformed JSON")).toBeUndefined();
  });
});
