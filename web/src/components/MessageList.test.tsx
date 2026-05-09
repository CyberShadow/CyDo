import { describe, expect, it } from "vitest";
import renderToString from "preact-render-to-string";
import { MessageList } from "./MessageList";
import type { DisplayMessage } from "../types";

describe("MessageList parse-error rendering", () => {
  it("shows parse_error system messages in normal mode", () => {
    const parseError: DisplayMessage = {
      id: "msg-1",
      type: "system",
      subtype: "parse_error",
      content: [
        {
          type: "text",
          text: 'Unknown message type: future_protocol\n{"type":"future_protocol"}',
        },
      ],
    };

    const html = renderToString(
      <MessageList
        taskTid={1}
        messages={[parseError]}
        blocks={new Map()}
        isProcessing={false}
        bandStatus=""
      />,
    );

    expect(html).toContain("Unknown message type: future_protocol");
    expect(html).toContain("<summary>Details</summary>");
  });
});
