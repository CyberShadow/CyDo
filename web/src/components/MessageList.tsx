import { h } from "preact";
import { useEffect, useRef } from "preact/hooks";
import type { DisplayMessage, StreamingBlock } from "../types";
import { AssistantMessage } from "./AssistantMessage";
import { UserMessage } from "./UserMessage";
import { Markdown } from "./Markdown";
import { ExtraFields } from "./ExtraFields";

interface Props {
  messages: DisplayMessage[];
  streamingBlocks: StreamingBlock[];
  isProcessing: boolean;
}

function ResultMessageView({ message }: { message: DisplayMessage }) {
  const d = message.resultData!;
  const durationSec = d.durationMs ? Math.floor(d.durationMs / 1000) : 0;
  const apiSec = d.durationApiMs ? Math.floor(d.durationApiMs / 1000) : 0;

  return (
    <div class={`message result-message ${d.isError ? "result-error" : "result-success"}`}>
      <div class="result-header">
        {d.isError ? "Session Failed" : "Session Complete"}
        <span class="result-subtype">[{d.subtype}]</span>
      </div>
      <div class="result-meta">
        {d.numTurns > 0 && <span>Turns: {d.numTurns}</span>}
        {durationSec > 0 && <span>Duration: {durationSec}s{apiSec > 0 && ` (${apiSec}s API)`}</span>}
        {d.totalCostUsd > 0 && <span>Cost: ${d.totalCostUsd.toFixed(4)}</span>}
        {d.usage && (
          <span>{d.usage.input_tokens.toLocaleString()} in / {d.usage.output_tokens.toLocaleString()} out</span>
        )}
        {d.stopReason && d.stopReason !== null && <span>Stop: {d.stopReason}</span>}
      </div>
      {d.modelUsage && Object.keys(d.modelUsage).length > 0 && (
        <details class="result-details">
          <summary>Per-model usage</summary>
          <pre>{JSON.stringify(d.modelUsage, null, 2)}</pre>
        </details>
      )}
      {d.permissionDenials && d.permissionDenials.length > 0 && (
        <details class="result-details">
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

function SystemStatusMessageView({ message }: { message: DisplayMessage }) {
  return (
    <div class="message system-status-message">
      status: {message.statusText}
      <ExtraFields fields={message.extraFields} />
    </div>
  );
}

export function MessageList({ messages, streamingBlocks, isProcessing }: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  const shouldAutoScroll = useRef(true);

  // Track if user has scrolled up
  const handleScroll = () => {
    const el = containerRef.current;
    if (!el) return;
    const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 50;
    shouldAutoScroll.current = atBottom;
  };

  // Auto-scroll on new content
  useEffect(() => {
    if (shouldAutoScroll.current && containerRef.current) {
      containerRef.current.scrollTop = containerRef.current.scrollHeight;
    }
  }, [messages, streamingBlocks]);

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
    <div class="message-list" ref={containerRef} onScroll={handleScroll}>
      {topLevelMessages.map((msg) => {
        switch (msg.type) {
          case "user":
            return <UserMessage key={msg.id} message={msg} />;
          case "assistant":
            return <AssistantMessage key={msg.id} message={msg} childrenByParent={childrenByParent} />;
          case "result":
            return <ResultMessageView key={msg.id} message={msg} />;
          case "summary":
            return <SummaryMessageView key={msg.id} message={msg} />;
          case "rate_limit":
            return <RateLimitMessageView key={msg.id} message={msg} />;
          case "compact_boundary":
            return <CompactBoundaryMessageView key={msg.id} message={msg} />;
          case "system": {
            // System status vs stderr
            if (msg.statusText !== undefined) {
              return <SystemStatusMessageView key={msg.id} message={msg} />;
            }
            const text = msg.content
              .filter((b): b is { type: "text"; text: string } => b.type === "text")
              .map((b) => b.text)
              .join("\n");
            return (
              <div key={msg.id} class="message system-message">
                <pre>{text}</pre>
                <ExtraFields fields={msg.extraFields} />
              </div>
            );
          }
          default:
            return (
              <div key={msg.id} class="message system-message">
                <pre>Unknown display type: {(msg as any).type}{"\n"}{JSON.stringify(msg, null, 2)}</pre>
              </div>
            );
        }
      })}
      {streamingBlocks.length > 0 && (
        <div class="message assistant-message streaming">
          {streamingBlocks.map((block) => (
            <div key={block.index} class={`content-block ${block.type}`}>
              {block.type === "thinking" && (
                <details open>
                  <summary>Thinking...</summary>
                  <Markdown text={block.text} class="thinking-text" />
                </details>
              )}
              {block.type === "text" && (
                <div class="text-content streaming-text">
                  <Markdown text={block.text} />
                  <span class="cursor" />
                </div>
              )}
              {block.type === "tool_use" && (
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
