import { h } from "preact";
import type { DisplayMessage } from "../types";
import { Markdown } from "./Markdown";
import { ToolCall } from "./ToolCall";
import { ExtraFields } from "./ExtraFields";
import { UserMessage } from "./UserMessage";

interface Props {
  message: DisplayMessage;
  childrenByParent?: Map<string, DisplayMessage[]>;
}

export function AssistantMessage({ message, childrenByParent }: Props) {
  return (
    <div class="message assistant-message">
      {(message.isSidechain || message.usage) && (
        <div class="message-meta">
          {message.isSidechain && <span class="meta-badge sidechain">sub-agent</span>}
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
          const nested = childrenByParent?.get(block.id);
          return (
            <ToolCall
              key={i}
              name={block.name}
              input={block.input}
              result={result}
            >
              {nested && nested.length > 0 && (
                <div class="sub-agent-messages">
                  {nested.map((child) => {
                    if (child.type === "assistant") {
                      return <AssistantMessage key={child.id} message={child} childrenByParent={childrenByParent} />;
                    }
                    if (child.type === "user") {
                      return <UserMessage key={child.id} message={child} />;
                    }
                    return null;
                  })}
                </div>
              )}
            </ToolCall>
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
      <ExtraFields fields={message.extraFields} />
    </div>
  );
}
