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
      {(message.isSidechain || message.parentToolUseId || message.usage) && (
        <div class="message-meta">
          {message.isSidechain && <span class="meta-badge sidechain">sub-agent</span>}
          {message.parentToolUseId && (
            <span class="meta-detail" title={message.parentToolUseId}>
              parent: {message.parentToolUseId.slice(0, 12)}...
            </span>
          )}
          {message.usage && (
            <span class="meta-detail">
              {message.usage.input_tokens.toLocaleString()} in / {message.usage.output_tokens.toLocaleString()} out
            </span>
          )}
        </div>
      )}
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
        // Unknown content block type - display it rather than silently dropping
        return (
          <div key={i} class="unknown-block">
            <div class="unknown-block-label">Unknown block type: {(block as any).type}</div>
            <pre>{JSON.stringify(block, null, 2)}</pre>
          </div>
        );
      })}
    </div>
  );
}
