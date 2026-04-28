import { describe, expect, it } from "vitest";
import type { ToolResult } from "../types";
import { formatCydoTaskResultItem, getCydoTaskResultItems } from "./ToolCall";

function makeResult(
  overrides: Partial<ToolResult>,
  content: ToolResult["content"] = "",
): ToolResult {
  return {
    toolUseId: "tool-1",
    content,
    ...overrides,
  };
}

describe("CyDo task result helpers", () => {
  it("prefers structured tool results over content text", () => {
    const items = getCydoTaskResultItems(
      makeResult(
        {
          toolResult: {
            tasks: [{ status: "success", tid: 2, summary: "from-tool-result" }],
          },
        },
        "not json",
      ),
    );

    expect(items).toEqual([
      { status: "success", tid: 2, summary: "from-tool-result" },
    ]);
  });

  it("accepts question results directly from toolResult", () => {
    const items = getCydoTaskResultItems(
      makeResult(
        {
          toolResult: {
            status: "question",
            tid: 2,
            qid: 1,
            message: "what approach should I use?",
          },
        },
        "",
      ),
    );

    expect(items).toEqual([
      {
        status: "question",
        tid: 2,
        qid: 1,
        message: "what approach should I use?",
      },
    ]);
  });

  it("unwraps structuredContent wrappers in toolResult", () => {
    const items = getCydoTaskResultItems(
      makeResult(
        {
          toolResult: {
            content:
              '{"status":"question","tid":2,"qid":1,"message":"what approach should I use?"}',
            structuredContent: {
              status: "question",
              tid: 2,
              qid: 1,
              message: "what approach should I use?",
            },
          },
        },
        "",
      ),
    );

    expect(items).toEqual([
      {
        status: "question",
        tid: 2,
        qid: 1,
        message: "what approach should I use?",
      },
    ]);
  });

  it("falls back to outer JSON text when structured data is absent", () => {
    const items = getCydoTaskResultItems(
      makeResult({}, [
        {
          type: "text",
          text: '{"tasks":[{"status":"success","tid":2,"summary":"from-text"}]}',
        },
      ]),
    );

    expect(items).toEqual([
      { status: "success", tid: 2, summary: "from-text" },
    ]);
  });

  it("falls back to text when toolResult is only a content wrapper", () => {
    const items = getCydoTaskResultItems(
      makeResult(
        {
          toolResult: {
            content:
              '{"tasks":[{"status":"success","tid":2,"summary":"from-wrapper-content"}]}',
          },
        },
        [
          {
            type: "text",
            text: '{"tasks":[{"status":"success","tid":2,"summary":"from-result-content"}]}',
          },
        ],
      ),
    );

    expect(items).toEqual([
      { status: "success", tid: 2, summary: "from-result-content" },
    ]);
  });

  it("keeps nested JSON-looking summary text literal", () => {
    const item = formatCydoTaskResultItem({
      status: "success",
      tid: 2,
      summary: '{"qid":3,"message":"**Summary**\\n\\nHello"}',
    });

    expect(item.text).toBe('{"qid":3,"message":"**Summary**\\n\\nHello"}');
  });

  it("renders structured errors through the typed path", () => {
    const item = formatCydoTaskResultItem({
      status: "error",
      tid: 2,
      error: "task failed",
      summary: "task failed",
    });

    expect(item.text).toBe("task failed");
    expect(item.fields).toMatchObject({ status: "error", tid: 2 });
  });
});
