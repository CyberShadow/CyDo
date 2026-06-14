import { describe, expect, it } from "vitest";
import renderToString from "preact-render-to-string";
import { MessageList } from "./MessageList";
import { DevModeContext } from "../devMode";
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

  it("hides unknown system subtype parse errors outside dev mode", () => {
    const parseError: DisplayMessage = {
      id: "msg-1",
      type: "system",
      subtype: "parse_error",
      content: [
        {
          type: "text",
          text: 'Unknown system subtype: thinking_tokens\n{"type":"system","subtype":"thinking_tokens"}',
        },
      ],
    };

    const normalHtml = renderToString(
      <DevModeContext.Provider value={false}>
        <MessageList
          taskTid={1}
          messages={[parseError]}
          blocks={new Map()}
          isProcessing={false}
          bandStatus=""
        />
      </DevModeContext.Provider>,
    );
    const devHtml = renderToString(
      <DevModeContext.Provider value={true}>
        <MessageList
          taskTid={1}
          messages={[parseError]}
          blocks={new Map()}
          isProcessing={false}
          bandStatus=""
        />
      </DevModeContext.Provider>,
    );

    expect(normalHtml).not.toContain("Unknown system subtype: thinking_tokens");
    expect(devHtml).toContain("Unknown system subtype: thinking_tokens");
  });
});
