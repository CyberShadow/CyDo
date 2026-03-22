import { Fragment } from "preact";
import type { DisplayMessage } from "../types";
import { Markdown } from "./Markdown";
import { ToolCall } from "./ToolCall";
import { UserMessage } from "./UserMessage";
import { hasAnsi, renderAnsi } from "../ansi";

/** Best-effort parse of an incomplete JSON string by closing open delimiters.
 *
 * Returns a valid object for any non-empty input (never null). When the input
 * ends mid-value, falls back to the last structurally complete position. */
function tryParsePartialJson(partial: string): Record<string, unknown> {
  if (!partial) return {};
  try {
    return JSON.parse(partial) as Record<string, unknown>;
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
    return JSON.parse(s + closers) as Record<string, unknown>;
  } catch {}
  for (let i = snapshots.length - 1; i >= 0; i--) {
    const snap = snapshots[i]!;
    const c = [...snap.stack].reverse().join("");
    try {
      return JSON.parse(s.slice(0, snap.pos) + c) as Record<string, unknown>;
    } catch {}
  }

  return {};
}

interface Props {
  message: DisplayMessage;
  childrenByParent?: Map<string, DisplayMessage[]>;
  onViewFile?: (filePath: string) => void;
}

export function AssistantMessage({
  message,
  childrenByParent,
  onViewFile,
}: Props) {
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
      {(() => {
        // Build unified render list sorted by creationOrder so completed
        // content blocks and still-streaming blocks stay in stable order.
        type RenderItem =
          | { streaming: false; block: (typeof message.content)[number]; order: number }
          | { streaming: true; block: NonNullable<typeof message.streamingBlocks>[number]; order: number };
        const items: RenderItem[] = [];
        for (const block of message.content) {
          items.push({
            streaming: false,
            block,
            order: ((block as Record<string, unknown>)._creationOrder as number | undefined) ?? 0,
          });
        }
        for (const block of message.streamingBlocks ?? []) {
          items.push({ streaming: true, block, order: block.creationOrder });
        }
        items.sort((a, b) => a.order - b.order);

        return items.map((item, i) => {
          if (!item.streaming) {
            const block = item.block;
            const blockExtras = { ...block._extras };
            const caller = blockExtras.caller;
            if (
              caller &&
              typeof caller === "object" &&
              (caller as Record<string, unknown>).type === "direct"
            ) {
              delete blockExtras.caller;
            }
            const blockExtraEl =
              Object.keys(blockExtras).length > 0 ? (
                <div class="unknown-extra-fields">
                  {Object.entries(blockExtras).map(([k, v]) => (
                    <div key={k} class="tool-input-field">
                      <span class="field-label">{k}:</span>
                      <span class="field-value">
                        {" "}
                        {typeof v === "string" ? v : JSON.stringify(v)}
                      </span>
                    </div>
                  ))}
                </div>
              ) : null;

            if (block.type === "thinking") {
              return (
                <Fragment key={i}>
                  <Markdown text={block.text ?? ""} class="thinking-text" />
                  {blockExtraEl}
                </Fragment>
              );
            }
            if (block.type === "tool_use") {
              const result = message.toolResults?.get(block.id!);
              const nested = childrenByParent?.get(block.id!);
              return (
                <Fragment key={i}>
                  <ToolCall
                    name={block.name!}
                    toolUseId={block.id}
                    input={block.input!}
                    result={result}
                    onViewFile={onViewFile}
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
                                onViewFile={onViewFile}
                              />
                            );
                          }
                          if (child.type === "user") {
                            return (
                              <UserMessage key={child.id} message={child} />
                            );
                          }
                          return null;
                        })}
                      </div>
                    )}
                  </ToolCall>
                  {blockExtraEl}
                </Fragment>
              );
            }
            if (block.type === "text") {
              return (
                <Fragment key={i}>
                  <Markdown text={block.text ?? ""} class="text-content" />
                  {blockExtraEl}
                </Fragment>
              );
            }
            return (
              <div key={i} class="unknown-block">
                <div class="unknown-block-label">
                  Unknown block type: {block.type}
                </div>
                <pre>{JSON.stringify(block, null, 2)}</pre>
                {blockExtraEl}
              </div>
            );
          }

          // Streaming block
          const block = item.block;
          return (
            <div key={block.itemId} class={`content-block ${block.type}`}>
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
                <Fragment>
                  <ToolCall
                    name={block.name}
                    input={
                      (block.input as Record<string, unknown> | undefined) ??
                      tryParsePartialJson(block.text)
                    }
                    onViewFile={onViewFile}
                  />
                  {block.output && (
                    <pre class="tool-result streaming-output">
                      {hasAnsi(block.output)
                        ? renderAnsi(block.output)
                        : block.output}
                    </pre>
                  )}
                </Fragment>
              )}
              {block.type === "tool_use" && !block.name && (
                <div class="tool-streaming">
                  <span class="tool-label">Tool call building...</span>
                  <pre>{block.text}</pre>
                </div>
              )}
            </div>
          );
        });
      })()}
      {message.extraFields && Object.keys(message.extraFields).length > 0 && (
        <div class="unknown-extra-fields">
          {Object.entries(message.extraFields).map(([k, v]) => (
            <div key={k} class="tool-input-field">
              <span class="field-label">{k}:</span>
              <span class="field-value">
                {" "}
                {typeof v === "string" ? v : JSON.stringify(v)}
              </span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
