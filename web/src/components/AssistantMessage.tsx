import { h } from "preact";
import type { DisplayMessage } from "../types";
import { Markdown } from "./Markdown";
import { ToolCall } from "./ToolCall";
import { ExtraFields } from "./ExtraFields";
import { UserMessage } from "./UserMessage";

/** Best-effort parse of an incomplete JSON string by closing open delimiters.
 *
 * Returns a valid object for any non-empty input (never null). When the input
 * ends mid-value, falls back to the last structurally complete position. */
function tryParsePartialJson(partial: string): Record<string, unknown> {
  if (!partial) return {};
  try {
    return JSON.parse(partial);
  } catch {}

  let s = partial;

  // Phase 1: Close any open string.
  // If the string ends with an odd number of backslashes, complete the
  // dangling escape sequence so the closing quote isn't consumed by it.
  let inString = false;
  for (let i = 0; i < s.length; i++) {
    if (s[i] === "\\" && inString) {
      i++;
      continue;
    }
    if (s[i] === '"') inString = !inString;
  }
  if (inString) {
    let trailingBs = 0;
    for (let j = s.length - 1; j >= 0; j--) {
      if (s[j] === "\\") trailingBs++;
      else break;
    }
    if (trailingBs % 2 === 1) s += "\\";
    s += '"';
  }

  // Phase 2: Walk through tracking brackets and recording "clean boundary"
  // snapshots — positions where truncating + closing brackets yields valid JSON.
  const snapshots: Array<{ pos: number; stack: string[] }> = [];
  const stack: string[] = [];
  inString = false;
  for (let i = 0; i < s.length; i++) {
    if (s[i] === "\\" && inString) {
      i++;
      continue;
    }
    if (s[i] === '"') {
      inString = !inString;
      continue;
    }
    if (inString) continue;
    if (s[i] === "{" || s[i] === "[") {
      stack.push(s[i] === "{" ? "}" : "]");
      snapshots.push({ pos: i + 1, stack: [...stack] });
    } else if (s[i] === "}" || s[i] === "]") {
      stack.pop();
      snapshots.push({ pos: i + 1, stack: [...stack] });
    } else if (s[i] === ",") {
      snapshots.push({ pos: i, stack: [...stack] });
    }
  }

  // Phase 3: Try parsing with computed closers, then fall back to snapshots
  const closers = [...stack].reverse().join("");
  try {
    return JSON.parse(s + closers);
  } catch {}
  for (let i = snapshots.length - 1; i >= 0; i--) {
    const snap = snapshots[i];
    const c = [...snap.stack].reverse().join("");
    try {
      return JSON.parse(s.slice(0, snap.pos) + c);
    } catch {}
  }

  return {};
}

interface Props {
  message: DisplayMessage;
  childrenByParent?: Map<string, DisplayMessage[]>;
}

export function AssistantMessage({ message, childrenByParent }: Props) {
  const hasStreamingBlocks = (message.streamingBlocks?.length ?? 0) > 0;
  const isSynthetic = message.model === "<synthetic>";
  return (
    <div
      class={`message assistant-message${hasStreamingBlocks ? " streaming" : ""}${isSynthetic ? " synthetic-message" : ""}`}
    >
      {(message.isSidechain || isSynthetic) && (
        <div class="message-meta">
          {message.isSidechain && (
            <span class="meta-badge sidechain">sub-agent</span>
          )}
          {isSynthetic && <span class="meta-badge synthetic">synthetic</span>}
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
          {block.type === "tool_use" && block.name && (
            <ToolCall
              name={block.name}
              input={tryParsePartialJson(block.text)}
            />
          )}
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
