import { Fragment, h } from "preact";
import { memo } from "preact/compat";
import { useState } from "preact/hooks";
import type { DisplayMessage, Block } from "../types";
import { Markdown } from "./Markdown";
import { ToolCall } from "./ToolCall";
import { UserMessage } from "./UserMessage";
import { hasAnsi, renderAnsi } from "../ansi";
import { StickyScrollPre } from "./StickyScrollPre";
import { SourceView } from "./SourceView";
import { useDevMode } from "../devMode";
import viewSourceIcon from "../icons/view-source.svg?raw";

function shallowArrayEqual<T>(a: T[], b: T[]): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

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

/** Wrapper for nested subagent messages — adds a "view source" toggle
 *  with full Raw/Abstract tabs (same as top-level messages). */
function NestedMessageWrapper({
  msg,
  tid,
  children,
}: {
  msg: DisplayMessage;
  tid: number;
  children: h.JSX.Element;
}) {
  const [showSource, setShowSource] = useState(false);
  const hasSource = msg.rawSource != null;
  if (!hasSource) return children;
  return (
    <div class={`message-wrapper${showSource ? " show-source" : ""}`}>
      <div class="message-actions">
        <button
          class="msg-action-btn view-source-btn"
          onClick={() => {
            setShowSource(!showSource);
          }}
          title="View source"
        >
          <span
            class="action-icon"
            dangerouslySetInnerHTML={{ __html: viewSourceIcon }}
          />
        </button>
      </div>
      {showSource ? <SourceView msg={msg} tid={tid} /> : children}
    </div>
  );
}

interface Props {
  message: DisplayMessage;
  resolvedBlocks: Block[];
  resolvedBlocksByMsg?: Map<string, Block[]>;
  childrenByParent?: Map<string, DisplayMessage[]>;
  onViewFile?: (filePath: string) => void;
  sessionId?: number;
  semanticSelectors?: boolean;
}

export const AssistantMessage = memo(
  function AssistantMessage({
    message,
    resolvedBlocks,
    resolvedBlocksByMsg,
    childrenByParent,
    onViewFile,
    sessionId,
    semanticSelectors = true,
  }: Props) {
    const devMode = useDevMode();
    const isStreaming = message.streaming === true;
    const isSynthetic = message.model === "<synthetic>";
    const blocksToRender = resolvedBlocks;
    const assistantTextAttrs: {
      "data-testid"?: string;
      "data-block-type"?: string;
    } = semanticSelectors
      ? {
          "data-testid": "assistant-text",
          "data-block-type": "assistant-text",
        }
      : {};
    return (
      <div
        class={`message assistant-message${isStreaming ? " streaming" : ""}${
          isSynthetic ? " synthetic-message" : ""
        }`}
      >
        {(message.isSidechain || isSynthetic) && (
          <div class="message-meta">
            {message.isSidechain && (
              <span class="meta-badge sidechain">sub-agent</span>
            )}
            {isSynthetic && <span class="meta-badge synthetic">synthetic</span>}
          </div>
        )}
        {blocksToRender.map((block, i) => {
          const itemId = block.itemId;

          const blockExtras = { ...(block.extras ?? {}) };
          const caller = blockExtras.caller;
          if (
            caller &&
            typeof caller === "object" &&
            (caller as Record<string, unknown>).type === "direct"
          ) {
            delete blockExtras.caller;
          }
          const blockExtraEl =
            devMode && Object.keys(blockExtras).length > 0 ? (
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
              <Fragment key={itemId}>
                {block.text.trim() === "" ? (
                  <div
                    class="thinking-text thinking-dots"
                    aria-label="thinking"
                    data-testid="thinking-dots"
                  />
                ) : (
                  <Markdown text={block.text} class="thinking-text" />
                )}
                {blockExtraEl}
              </Fragment>
            );
          }

          if (block.type === "text") {
            return (
              <Fragment key={itemId}>
                {block.completed ? (
                  <Markdown
                    text={block.text}
                    class="text-content"
                    {...assistantTextAttrs}
                  />
                ) : (
                  <div
                    class="text-content streaming-text"
                    {...assistantTextAttrs}
                  >
                    {block.text ? (
                      <Markdown text={block.text} />
                    ) : (
                      <span class="cursor" />
                    )}
                  </div>
                )}
                {blockExtraEl}
              </Fragment>
            );
          }

          if (block.type === "tool_use") {
            if (!block.name && !block.completed) {
              // Tool name not yet arrived
              return (
                <div key={itemId} class="tool-streaming">
                  <span class="tool-label">Tool call building...</span>
                  <pre>{block.text}</pre>
                </div>
              );
            }
            if (block.name) {
              const nested = childrenByParent?.get(block.itemId);
              return (
                <Fragment key={itemId}>
                  <ToolCall
                    name={block.name}
                    toolServer={block.toolServer}
                    toolSource={block.toolSource}
                    agentType={block.agentType}
                    toolUseId={block.itemId}
                    streaming={!block.completed}
                    input={
                      block.completed
                        ? ((block.input as
                            | Record<string, unknown>
                            | undefined) ?? {})
                        : ((block.input as
                            | Record<string, unknown>
                            | undefined) ?? tryParsePartialJson(block.text))
                    }
                    result={block.completed ? block.result : undefined}
                    onViewFile={onViewFile}
                  >
                    {block.stdin && (
                      <StickyScrollPre class="tool-result streaming-stdin">
                        {block.stdin}
                      </StickyScrollPre>
                    )}
                    {typeof block.output === "string" &&
                      block.output &&
                      !block.result && (
                        <StickyScrollPre class="tool-result streaming-output">
                          {hasAnsi(block.output)
                            ? renderAnsi(block.output)
                            : block.output}
                        </StickyScrollPre>
                      )}
                    {nested && nested.length > 0 && block.completed && (
                      <div class="sub-agent-messages">
                        {nested.map((child) => {
                          if (child.type === "assistant") {
                            return (
                              <NestedMessageWrapper
                                key={child.id}
                                msg={child}
                                tid={sessionId ?? 0}
                              >
                                <AssistantMessage
                                  message={child}
                                  resolvedBlocks={
                                    resolvedBlocksByMsg?.get(child.id) ?? []
                                  }
                                  resolvedBlocksByMsg={resolvedBlocksByMsg}
                                  childrenByParent={childrenByParent}
                                  onViewFile={onViewFile}
                                  sessionId={sessionId}
                                  semanticSelectors={false}
                                />
                              </NestedMessageWrapper>
                            );
                          }
                          if (child.type === "user") {
                            return (
                              <NestedMessageWrapper
                                key={child.id}
                                msg={child}
                                tid={sessionId ?? 0}
                              >
                                <UserMessage message={child} />
                              </NestedMessageWrapper>
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
            return null;
          }

          if (block.type === "error") {
            return (
              <div key={itemId} class={`content-block ${block.type}`}>
                <div class="error-block">
                  <div class="error-block-label">Agent error</div>
                  <pre>{block.text}</pre>
                </div>
              </div>
            );
          }

          if (block.type === "unrecognized") {
            if (!devMode) return null;
            return (
              <div key={itemId} class={`content-block ${block.type}`}>
                <div class="unknown-block">
                  <div class="unknown-block-label">Unrecognized agent data</div>
                  <pre>{block.text}</pre>
                </div>
              </div>
            );
          }

          // Unknown block type
          if (!devMode) return null;
          return (
            <div key={i} class="unknown-block">
              <div class="unknown-block-label">
                Unknown block type: {block.type}
              </div>
              <pre>{JSON.stringify(block, null, 2)}</pre>
              {blockExtraEl}
            </div>
          );
        })}
        {devMode &&
          message.extraFields &&
          Object.keys(message.extraFields).length > 0 && (
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
  },
  (prev, next) =>
    prev.message === next.message &&
    shallowArrayEqual(prev.resolvedBlocks, next.resolvedBlocks) &&
    prev.childrenByParent === next.childrenByParent &&
    prev.resolvedBlocksByMsg === next.resolvedBlocksByMsg &&
    prev.onViewFile === next.onViewFile &&
    prev.sessionId === next.sessionId &&
    prev.semanticSelectors === next.semanticSelectors,
);
