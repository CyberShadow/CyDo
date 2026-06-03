import { describe, expect, it } from "vitest";
import renderToString from "preact-render-to-string";
import { DevModeContext } from "../devMode";
import type { Block, DisplayMessage } from "../types";
import { AssistantMessage } from "./AssistantMessage";

function renderAssistantMessage(message: DisplayMessage, block: Block): string {
  return renderToString(
    <DevModeContext.Provider value={false}>
      <AssistantMessage
        message={message}
        resolvedBlocks={[block]}
        onViewFile={() => {}}
        semanticSelectors={false}
      />
    </DevModeContext.Provider>,
  );
}

describe("AssistantMessage warning blocks", () => {
  it("renders agent warnings with warning styling and label", () => {
    const html = renderAssistantMessage(
      {
        id: "warning-msg-1",
        type: "assistant",
        content: [],
        blockIds: ["warning-1"],
        streaming: false,
        nextCreationOrder: 1,
      },
      {
        itemId: "warning-1",
        type: "warning",
        text: "Heads up: Long threads and multiple compactions can cause the model to be less accurate.",
        completed: true,
        creationOrder: 0,
      },
    );

    expect(html).toContain("warning-block");
    expect(html).toContain("Agent warning");
    expect(html).toContain(
      "Heads up: Long threads and multiple compactions can cause the model to be less accurate.",
    );
  });
});
