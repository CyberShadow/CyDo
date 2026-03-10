import { h, type ComponentChildren } from "preact";
import { memo } from "preact/compat";
import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  useMemo,
} from "preact/hooks";
import type { DisplayMessage } from "../types";
import { useHighlight, renderTokens } from "../highlight";
import { AssistantMessage } from "./AssistantMessage";
import { UserMessage } from "./UserMessage";
import { Markdown } from "./Markdown";
import { ExtraFields } from "./ExtraFields";

interface Props {
  sessionId: number;
  messages: DisplayMessage[];
  isProcessing: boolean;
  onFork?: (sid: number, afterUuid: string) => void;
  forkableUuids?: Set<string>;
}

function ResultMessageView({ message }: { message: DisplayMessage }) {
  const d = message.resultData!;
  const durationSec = d.durationMs ? Math.floor(d.durationMs / 1000) : 0;
  const apiSec = d.durationApiMs ? Math.floor(d.durationApiMs / 1000) : 0;
  const [expanded, setExpanded] = useState(d.isError);

  if (!expanded) {
    return (
      <div
        class={`result-divider ${d.isError ? "result-error" : "result-success"}`}
        onClick={() => setExpanded(true)}
      >
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
        {durationSec > 0 && (
          <span>
            Duration: {durationSec}s{apiSec > 0 && ` (${apiSec}s API)`}
          </span>
        )}
        {d.totalCostUsd > 0 && <span>Cost: ${d.totalCostUsd.toFixed(4)}</span>}

        {d.stopReason && d.stopReason !== null && (
          <span>Stop: {d.stopReason}</span>
        )}
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
      {d.errors && d.errors.length > 0 && (
        <details class="result-details" onClick={(e) => e.stopPropagation()}>
          <summary>Errors ({d.errors.length})</summary>
          <pre>{d.errors.join("\n\n")}</pre>
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
  const resetsAt = info.resetsAt
    ? new Date(info.resetsAt * 1000).toLocaleString()
    : null;

  return (
    <div class="message rate-limit-message">
      <div class="rate-limit-header">
        Rate Limit
        {info.status && <span class="rate-limit-badge">[{info.status}]</span>}
        {info.rateLimitType && (
          <span class="rate-limit-badge">[{info.rateLimitType}]</span>
        )}
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
      {cm?.preTokens && (
        <span class="compact-detail">
          {cm.preTokens.toLocaleString()} tokens before
        </span>
      )}
      <ExtraFields fields={message.extraFields} />
    </div>
  );
}

function InitDetailList({ label, items }: { label: string; items: unknown[] }) {
  return (
    <details class="init-details">
      <summary>
        {label} ({items.length})
      </summary>
      <ul class="init-detail-list">
        {items.map((item, i) => (
          <li key={i}>
            {typeof item === "string"
              ? item
              : typeof item === "object" && item !== null && "name" in item
                ? `${(item as any).name}${(item as any).status ? ` [${(item as any).status}]` : ""}`
                : JSON.stringify(item)}
          </li>
        ))}
      </ul>
    </details>
  );
}

function SystemInitView({ message }: { message: DisplayMessage }) {
  const [expanded, setExpanded] = useState(false);
  const raw = message.rawSource as any;

  if (!expanded) {
    return (
      <div
        class="result-divider init-message"
        onClick={() => setExpanded(true)}
      >
        <hr />
        <span class="result-divider-icon">{"☀"}</span>
        <hr />
      </div>
    );
  }

  return (
    <div class="message system-message init-message">
      <div class="init-header" onClick={() => setExpanded(false)}>
        Session Init
      </div>
      <div class="init-meta">
        {raw?.model && <span>Model: {raw.model}</span>}
        {raw?.claude_code_version && <span>v{raw.claude_code_version}</span>}
        {raw?.permissionMode && <span>{raw.permissionMode}</span>}
        {raw?.output_style && raw.output_style !== "default" && (
          <span>Style: {raw.output_style}</span>
        )}
      </div>
      {raw?.tools?.length > 0 && (
        <InitDetailList label="Tools" items={raw.tools} />
      )}
      {raw?.mcp_servers?.length > 0 && (
        <InitDetailList label="MCP servers" items={raw.mcp_servers} />
      )}
      {raw?.agents?.length > 0 && (
        <InitDetailList label="Agents" items={raw.agents} />
      )}
      {raw?.skills?.length > 0 && (
        <InitDetailList label="Skills" items={raw.skills} />
      )}
      {raw?.slash_commands?.length > 0 && (
        <InitDetailList label="Slash commands" items={raw.slash_commands} />
      )}
      {raw?.plugins?.length > 0 && (
        <InitDetailList label="Plugins" items={raw.plugins} />
      )}
      <ExtraFields fields={message.extraFields} />
    </div>
  );
}

function TaskLifecycleView({ message }: { message: DisplayMessage }) {
  const raw = message.rawSource as any;
  const isStarted = raw?.subtype === "task_started";
  const taskType = raw?.task_type;
  const taskId = raw?.task_id;

  let label: string;
  let description: string;
  if (isStarted) {
    label = "Task started";
    description = raw?.description || taskId || "";
  } else {
    label = `Task ${raw?.status || "updated"}`;
    description = raw?.summary || taskId || "";
  }

  return (
    <div
      class={`message task-lifecycle-message${isStarted ? " task-started" : " task-notification"}`}
    >
      <span class="task-lifecycle-label">{label}</span>
      {taskType && <span class="task-lifecycle-type">{taskType}</span>}
      {description && <span class="task-lifecycle-desc">{description}</span>}
      <ExtraFields fields={message.extraFields} />
    </div>
  );
}

function ControlResponseView({ message }: { message: DisplayMessage }) {
  const raw = message.rawSource as any;
  const subtype = raw?.response?.subtype ?? "unknown";
  return (
    <div class="message control-response-message">
      <span class="control-response-label">Control response</span>
      <span class="control-response-subtype">{subtype}</span>
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

function SourceView({ msg }: { msg: DisplayMessage }) {
  const jsonText = useMemo(
    () => JSON.stringify(msg.rawSource ?? msg, jsonReplacer, 2),
    [msg.rawSource ?? msg],
  );
  const tokens = useHighlight(jsonText, "json");
  return (
    <div class="message source-view">
      <pre>
        {tokens
          ? tokens.map((line, i) => (
              <span key={i}>
                {i > 0 && "\n"}
                {renderTokens(line)}
              </span>
            ))
          : jsonText}
      </pre>
    </div>
  );
}

const MessageView = memo(
  function MessageView({
    msg,
    onFork,
    forkable,
    children,
  }: {
    msg: DisplayMessage;
    hasNested?: boolean;
    onFork?: (afterUuid: string) => void;
    forkable?: boolean;
    children: ComponentChildren;
  }) {
    const [showSource, setShowSource] = useState(false);
    const raw = Array.isArray(msg.rawSource)
      ? msg.rawSource[msg.rawSource.length - 1]
      : msg.rawSource;
    const uuid = (raw as any)?.uuid as string | undefined;
    return (
      <div class={`message-wrapper${showSource ? " show-source" : ""}`}>
        <div class="message-actions">
          {(msg.rawSource != null || msg.streamingBlocks !== undefined) && (
            <button
              class="msg-action-btn view-source-btn"
              onClick={() => setShowSource(!showSource)}
              title="View source"
            >
              {"{}"}
            </button>
          )}
        </div>
        {showSource ? <SourceView msg={msg} /> : children}
        {uuid && forkable && onFork && (
          <div class="message-actions message-actions-bottom">
            <button
              class="msg-action-btn fork-btn"
              onClick={() => onFork(uuid)}
              title="Fork session after this point"
            >
              {"\u2442"}
            </button>
          </div>
        )}
      </div>
    );
  },
  (prev, next) => {
    if (prev.hasNested || next.hasNested) return false;
    return (
      prev.msg === next.msg &&
      prev.onFork === next.onFork &&
      prev.forkable === next.forkable
    );
  },
);

export function MessageList({
  sessionId,
  messages,
  isProcessing,
  onFork,
  forkableUuids,
}: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  const handleFork = useMemo(
    () =>
      onFork ? (afterUuid: string) => onFork(sessionId, afterUuid) : undefined,
    [onFork, sessionId],
  );

  // On session switch, scroll to bottom (scrollTop 0 = bottom in column-reverse).
  const prevSessionId = useRef(sessionId);
  useLayoutEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    if (prevSessionId.current !== sessionId) {
      prevSessionId.current = sessionId;
      el.scrollTop = 0;
    }
    // Toggle overflow-anchor based on scroll position:
    // - At bottom: disable so column-reverse naturally sticks to bottom
    // - Scrolled up: enable so browser anchors viewport when content grows
    el.style.overflowAnchor = el.scrollTop >= -1 ? "none" : "auto";
  });

  // Also toggle on user scroll (which happens between renders).
  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const onScroll = () => {
      el.style.overflowAnchor = el.scrollTop >= -1 ? "none" : "auto";
    };
    el.addEventListener("scroll", onScroll, { passive: true });
    return () => el.removeEventListener("scroll", onScroll);
  }, []);

  // Partition messages: top-level vs nested under a parent tool_use_id
  const { childrenByParent, topLevelMessages } = useMemo(() => {
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
    return { childrenByParent, topLevelMessages };
  }, [messages]);

  return (
    <div class="message-list" ref={containerRef}>
      <div class="message-list-inner">
        {topLevelMessages.map((msg) => {
          let inner;
          switch (msg.type) {
            case "user":
              inner = <UserMessage message={msg} />;
              break;
            case "assistant":
              inner = (
                <AssistantMessage
                  message={msg}
                  childrenByParent={childrenByParent}
                />
              );
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
              const rawSubtype = (msg.rawSource as any)?.subtype;
              const rawType = (msg.rawSource as any)?.type;
              if (rawSubtype === "init") {
                inner = <SystemInitView message={msg} />;
              } else if (msg.statusText !== undefined) {
                inner = <SystemStatusMessageView message={msg} />;
              } else if (
                rawSubtype === "task_started" ||
                rawSubtype === "task_notification"
              ) {
                inner = <TaskLifecycleView message={msg} />;
              } else if (rawType === "control_response") {
                inner = <ControlResponseView message={msg} />;
              } else {
                const text = msg.content
                  .filter(
                    (b): b is { type: "text"; text: string } =>
                      b.type === "text",
                  )
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
                  <pre>
                    Unknown display type: {(msg as any).type}
                    {"\n"}
                    {JSON.stringify(msg, null, 2)}
                  </pre>
                </div>
              );
          }
          const rawSrc = Array.isArray(msg.rawSource)
            ? msg.rawSource[msg.rawSource.length - 1]
            : msg.rawSource;
          const msgUuid = (rawSrc as any)?.uuid as string | undefined;
          const isForkable =
            !!msgUuid && !!forkableUuids && forkableUuids.has(msgUuid);
          return (
            <MessageView
              key={msg.id}
              msg={msg}
              hasNested={
                msg.type === "assistant" &&
                msg.content.some(
                  (b) => b.type === "tool_use" && childrenByParent.has(b.id),
                )
              }
              onFork={handleFork}
              forkable={isForkable}
            >
              {inner}
            </MessageView>
          );
        })}
      </div>
    </div>
  );
}
