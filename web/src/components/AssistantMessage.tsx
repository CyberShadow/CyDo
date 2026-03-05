import { h } from "preact";
import type { DisplayMessage } from "../types";
import { Markdown } from "./Markdown";
import { ToolCall } from "./ToolCall";
import { ExtraFields } from "./ExtraFields";
import { UserMessage } from "./UserMessage";

/** Best-effort parse of an incomplete JSON string by closing open delimiters. */
function tryParsePartialJson(partial: string): Record<string, unknown> | null {
  if (!partial) return {};
  // Try as-is first (might already be complete)
  try {
    return JSON.parse(partial);
  } catch {}
  // Close open strings, arrays, objects
  let attempt = partial;
  // Count unescaped open quotes
  let inString = false;
  for (let i = 0; i < attempt.length; i++) {
    if (attempt[i] === "\\" && inString) {
      i++;
      continue;
    }
    if (attempt[i] === '"') inString = !inString;
  }
  if (inString) attempt += '"';
  // Close open brackets/braces
  const stack: string[] = [];
  inString = false;
  for (let i = 0; i < attempt.length; i++) {
    if (attempt[i] === "\\" && inString) {
      i++;
      continue;
    }
    if (attempt[i] === '"') {
      inString = !inString;
      continue;
    }
    if (inString) continue;
    if (attempt[i] === "{") stack.push("}");
    else if (attempt[i] === "[") stack.push("]");
    else if (attempt[i] === "}" || attempt[i] === "]") stack.pop();
  }
  attempt += stack.reverse().join("");
  try {
    return JSON.parse(attempt);
  } catch {
    return null;
  }
}

interface Props {
  message: DisplayMessage;
  childrenByParent?: Map<string, DisplayMessage[]>;
}

export function AssistantMessage({ message, childrenByParent }: Props) {
  const hasStreamingBlocks = (message.streamingBlocks?.length ?? 0) > 0;
  return (
    <div
      class={`message assistant-message${hasStreamingBlocks ? " streaming" : ""}`}
    >
      {message.isSidechain && (
        <div class="message-meta">
          <span class="meta-badge sidechain">sub-agent</span>
        </div>
      )}
      {message.content.map((block, i) => {
        if (block.type === "thinking") {
          return (
            <Markdown key={i} text={block.thinking} class="thinking-text" />
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
                      return (
                        <AssistantMessage
                          key={child.id}
                          message={child}
                          childrenByParent={childrenByParent}
                        />
                      );
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
            <div class="unknown-block-label">
              Unknown block type: {(block as any).type}
            </div>
            <pre>{JSON.stringify(block, null, 2)}</pre>
          </div>
        );
      })}
      {message.streamingBlocks?.map((block) => (
        <div key={`s${block.index}`} class={`content-block ${block.type}`}>
          {block.type === "thinking" && (
            <Markdown text={block.text} class="thinking-text" />
          )}
          {block.type === "text" && (
            <div class="text-content streaming-text">
              <Markdown text={block.text} />
              <span class="cursor" />
            </div>
          )}
          {block.type === "tool_use" &&
            block.name &&
            (() => {
              const parsed = tryParsePartialJson(block.text);
              return parsed ? (
                <ToolCall name={block.name} input={parsed} />
              ) : (
                <div class="tool-streaming">
                  <span class="tool-label">{block.name}</span>
                  <pre>{block.text}</pre>
                </div>
              );
            })()}
          {block.type === "tool_use" && !block.name && (
            <div class="tool-streaming">
              <span class="tool-label">Tool call building...</span>
              <pre>{block.text}</pre>
            </div>
          )}
        </div>
      ))}
      <ExtraFields fields={message.extraFields} />
    </div>
  );
}
