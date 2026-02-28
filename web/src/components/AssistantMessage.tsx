import { h } from "preact";
import type { DisplayMessage } from "../app";
import { Markdown } from "./Markdown";
import { ToolCall } from "./ToolCall";

interface Props {
  message: DisplayMessage;
}

export function AssistantMessage({ message }: Props) {
  return (
    <div class="message assistant-message">
      {message.content.map((block, i) => {
        if (block.type === "thinking") {
          return (
            <details key={i} class="thinking-block">
              <summary>Thinking</summary>
              <Markdown text={block.thinking} class="thinking-text" />
            </details>
          );
        }
        if (block.type === "tool_use") {
          const result = message.toolResults?.get(block.id);
          return (
            <ToolCall
              key={i}
              name={block.name}
              input={block.input}
              result={result}
            />
          );
        }
        if (block.type === "text") {
          return <Markdown key={i} text={block.text} class="text-content" />;
        }
        return null;
      })}
    </div>
  );
}
