import { h, type ComponentChildren } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import type { DisplayMessage, StreamingBlock } from "../types";
import { AssistantMessage } from "./AssistantMessage";
import { UserMessage } from "./UserMessage";
import { Markdown } from "./Markdown";
import { ExtraFields } from "./ExtraFields";
import { ToolCall } from "./ToolCall";

interface Props {
  sessionId: number;
  messages: DisplayMessage[];
  streamingBlocks: StreamingBlock[];
  isProcessing: boolean;
}

/** Best-effort parse of an incomplete JSON string by closing open delimiters. */
function tryParsePartialJson(partial: string): Record<string, unknown> | null {
  if (!partial) return {};
  // Try as-is first (might already be complete)
  try { return JSON.parse(partial); } catch {}
  // Close open strings, arrays, objects
  let attempt = partial;
  // Count unescaped open quotes
  let inString = false;
  for (let i = 0; i < attempt.length; i++) {
    if (attempt[i] === "\\" && inString) { i++; continue; }
    if (attempt[i] === '"') inString = !inString;
  }
  if (inString) attempt += '"';
  // Close open brackets/braces
  const stack: string[] = [];
  inString = false;
  for (let i = 0; i < attempt.length; i++) {
    if (attempt[i] === "\\" && inString) { i++; continue; }
    if (attempt[i] === '"') { inString = !inString; continue; }
    if (inString) continue;
    if (attempt[i] === "{") stack.push("}");
    else if (attempt[i] === "[") stack.push("]");
    else if (attempt[i] === "}" || attempt[i] === "]") stack.pop();
  }
  attempt += stack.reverse().join("");
  try { return JSON.parse(attempt); } catch { return null; }
}

function ResultMessageView({ message }: { message: DisplayMessage }) {
  const d = message.resultData!;
  const durationSec = d.durationMs ? Math.floor(d.durationMs / 1000) : 0;
  const apiSec = d.durationApiMs ? Math.floor(d.durationApiMs / 1000) : 0;
  const [expanded, setExpanded] = useState(d.isError);

  if (!expanded) {
    return (
      <div class={`result-divider ${d.isError ? "result-error" : "result-success"}`} onClick={() => setExpanded(true)}>
        <hr />
        <span class="result-divider-icon">{d.isError ? "!" : "\u2713"}</span>
        <hr />
      </div>
    );
  }

  return (
    <div
      class={`message result-message ${d.isError ? "result-error" : "result-success"}`}
      onClick={() => setExpanded(false)}
    >
      <div class="result-header">
        {d.isError ? "Session Failed" : "Session Complete"}
        <span class="result-subtype">[{d.subtype}]</span>
      </div>
      <div class="result-meta">
        {d.numTurns > 0 && <span>Turns: {d.numTurns}</span>}
        {durationSec > 0 && <span>Duration: {durationSec}s{apiSec > 0 && ` (${apiSec}s API)`}</span>}
        {d.totalCostUsd > 0 && <span>Cost: ${d.totalCostUsd.toFixed(4)}</span>}

        {d.stopReason && d.stopReason !== null && <span>Stop: {d.stopReason}</span>}
      </div>
      {d.modelUsage && Object.keys(d.modelUsage).length > 0 && (
        <details class="result-details" onClick={(e) => e.stopPropagation()}>
          <summary>Per-model usage</summary>
          <pre>{JSON.stringify(d.modelUsage, null, 2)}</pre>
        </details>
      )}
      {d.permissionDenials && d.permissionDenials.length > 0 && (
        <details class="result-details" onClick={(e) => e.stopPropagation()}>
          <summary>Permission denials ({d.permissionDenials.length})</summary>
          <pre>{JSON.stringify(d.permissionDenials, null, 2)}</pre>
        </details>
      )}
      {d.result && <div class="result-text">{d.result}</div>}
      <ExtraFields fields={message.extraFields} />
    </div>
  );
}

function SummaryMessageView({ message }: { message: DisplayMessage }) {
  const text = message.content
    .filter((b): b is { type: "text"; text: string } => b.type === "text")
    .map((b) => b.text)
    .join("\n");

  return (
    <div class="message summary-message">
      <div class="summary-header">Session Summary</div>
      <Markdown text={text} class="summary-text" />
      <ExtraFields fields={message.extraFields} />
    </div>
  );
}

function RateLimitMessageView({ message }: { message: DisplayMessage }) {
  const info = message.rateLimitInfo!;
  const resetsAt = info.resetsAt ? new Date(info.resetsAt * 1000).toLocaleString() : null;

  return (
    <div class="message rate-limit-message">
      <div class="rate-limit-header">
        Rate Limit
        {info.status && <span class="rate-limit-badge">[{info.status}]</span>}
        {info.rateLimitType && <span class="rate-limit-badge">[{info.rateLimitType}]</span>}
      </div>
      <div class="rate-limit-meta">
        {resetsAt && <span>Resets at: {resetsAt}</span>}
        {info.overageStatus && (
          <span>
            Overage: {info.overageStatus}
            {info.overageDisabledReason && ` (${info.overageDisabledReason})`}
          </span>
        )}
      </div>
      <ExtraFields fields={message.extraFields} />
    </div>
  );
}

function CompactBoundaryMessageView({ message }: { message: DisplayMessage }) {
  const cm = message.compactMetadata;
  return (
    <div class="message compact-boundary-message">
      <span class="compact-label">Context Compacted</span>
      {cm?.trigger && <span class="compact-detail">[{cm.trigger}]</span>}
      {cm?.preTokens && <span class="compact-detail">{cm.preTokens.toLocaleString()} tokens before</span>}
      <ExtraFields fields={message.extraFields} />
    </div>
  );
}

function SystemInitView({ message }: { message: DisplayMessage }) {
  const [expanded, setExpanded] = useState(false);

  if (!expanded) {
    return (
      <div class="result-divider" onClick={() => setExpanded(true)}>
        <hr />
        <span class="result-divider-icon">{"☀"}</span>
        <hr />
      </div>
    );
  }

  return (
    <div class="message system-message init-message" onClick={() => setExpanded(false)}>
      <div class="init-header">Session Init</div>
      <ExtraFields fields={message.extraFields} />
    </div>
  );
}

function SystemStatusMessageView({ message }: { message: DisplayMessage }) {
  return (
    <div class="message system-status-message">
      status: {message.statusText}
      <ExtraFields fields={message.extraFields} />
    </div>
  );
}

function jsonReplacer(_key: string, value: unknown) {
  return value instanceof Map ? Object.fromEntries(value) : value;
}

function MessageView({ msg, children }: { msg: DisplayMessage; children: ComponentChildren }) {
  const [showSource, setShowSource] = useState(false);
  return (
    <div class={`message-wrapper${showSource ? " show-source" : ""}`}>
      {msg.rawSource != null && (
        <button
          class="view-source-btn"
          onClick={() => setShowSource(!showSource)}
          title="View source"
        >
          {"{}"}
        </button>
      )}
      {showSource
        ? (
          <div class="message source-view">
            <pre>{JSON.stringify(msg.rawSource, jsonReplacer, 2)}</pre>
          </div>
        )
        : children
      }
    </div>
  );
}

export function MessageList({ sessionId, messages, streamingBlocks, isProcessing }: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  const wantScroll = useRef(true);

  // On session switch, always scroll to bottom
  const prevSessionId = useRef(sessionId);
  if (prevSessionId.current !== sessionId) {
    prevSessionId.current = sessionId;
    wantScroll.current = true;
  }

  // Track user scroll intent via input events (wheel/touch) instead of
  // the generic 'scroll' event. 'scroll' fires for both user and
  // programmatic scrolls, causing races with content-visibility layout
  // recalculations that incorrectly clear wantScroll.
  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;

    let userActive = false;
    let activeTimer: ReturnType<typeof setTimeout> | null = null;

    const markActive = () => {
      userActive = true;
      if (activeTimer !== null) clearTimeout(activeTimer);
      activeTimer = setTimeout(() => { userActive = false; activeTimer = null; }, 200);
    };

    const onScroll = () => {
      if (!userActive) return;
      wantScroll.current = el.scrollHeight - el.scrollTop - el.clientHeight < 50;
    };

    el.addEventListener("wheel", markActive, { passive: true });
    el.addEventListener("touchmove", markActive, { passive: true });
    el.addEventListener("scroll", onScroll, { passive: true });
    return () => {
      el.removeEventListener("wheel", markActive);
      el.removeEventListener("touchmove", markActive);
      el.removeEventListener("scroll", onScroll);
      if (activeTimer !== null) clearTimeout(activeTimer);
    };
  }, []);

  // Auto-scroll to bottom after every render when wantScroll is set.
  // content-visibility: auto defers rendering of off-screen elements.
  // After scrolling, newly-visible elements get their actual sizes,
  // which changes scrollHeight. Keep re-scrolling until stable.
  useEffect(() => {
    const el = containerRef.current;
    if (!el || !wantScroll.current) return;

    let rafId: number;
    let lastHeight = -1;
    let settled = 0;

    const tick = () => {
      el.scrollTop = el.scrollHeight;
      if (el.scrollHeight === lastHeight) {
        if (++settled >= 3) return;
      } else {
        settled = 0;
        lastHeight = el.scrollHeight;
      }
      rafId = requestAnimationFrame(tick);
    };

    tick();
    return () => cancelAnimationFrame(rafId);
  });

  // Partition messages: top-level vs nested under a parent tool_use_id
  const childrenByParent = new Map<string, DisplayMessage[]>();
  const topLevelMessages: DisplayMessage[] = [];
  for (const msg of messages) {
    if (msg.parentToolUseId) {
      let list = childrenByParent.get(msg.parentToolUseId);
      if (!list) {
        list = [];
        childrenByParent.set(msg.parentToolUseId, list);
      }
      list.push(msg);
    } else {
      topLevelMessages.push(msg);
    }
  }

  return (
    <div class="message-list" ref={containerRef}>
      {topLevelMessages.map((msg) => {
        let inner;
        switch (msg.type) {
          case "user":
            inner = <UserMessage message={msg} />;
            break;
          case "assistant":
            inner = <AssistantMessage message={msg} childrenByParent={childrenByParent} />;
            break;
          case "result":
            inner = <ResultMessageView message={msg} />;
            break;
          case "summary":
            inner = <SummaryMessageView message={msg} />;
            break;
          case "rate_limit":
            inner = <RateLimitMessageView message={msg} />;
            break;
          case "compact_boundary":
            inner = <CompactBoundaryMessageView message={msg} />;
            break;
          case "system": {
            if ((msg.rawSource as any)?.subtype === "init") {
              inner = <SystemInitView message={msg} />;
            } else if (msg.statusText !== undefined) {
              inner = <SystemStatusMessageView message={msg} />;
            } else {
              const text = msg.content
                .filter((b): b is { type: "text"; text: string } => b.type === "text")
                .map((b) => b.text)
                .join("\n");
              inner = (
                <div class="message system-message">
                  <pre>{text}</pre>
                  <ExtraFields fields={msg.extraFields} />
                </div>
              );
            }
            break;
          }
          default:
            inner = (
              <div class="message system-message">
                <pre>Unknown display type: {(msg as any).type}{"\n"}{JSON.stringify(msg, null, 2)}</pre>
              </div>
            );
        }
        return <MessageView key={msg.id} msg={msg}>{inner}</MessageView>;
      })}
      {streamingBlocks.length > 0 && (
        <div class="message assistant-message streaming">
          {streamingBlocks.map((block) => (
            <div key={block.index} class={`content-block ${block.type}`}>
              {block.type === "thinking" && (
                <Markdown text={block.text} class="thinking-text" />
              )}
              {block.type === "text" && (
                <div class="text-content streaming-text">
                  <Markdown text={block.text} />
                  <span class="cursor" />
                </div>
              )}
              {block.type === "tool_use" && block.name && (() => {
                const parsed = tryParsePartialJson(block.text);
                return parsed
                  ? <ToolCall name={block.name} input={parsed} />
                  : (
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
        </div>
      )}
    </div>
  );
}
