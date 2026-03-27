import { type ComponentChildren } from "preact";
import { memo } from "preact/compat";
import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  useMemo,
  useCallback,
} from "preact/hooks";
import type { DisplayMessage } from "../types";
import { useHighlight, renderTokens } from "../highlight";
import { AssistantMessage } from "./AssistantMessage";
import { UserMessage } from "./UserMessage";
import { Markdown } from "./Markdown";
import editIcon from "../icons/edit.svg?raw";
import viewSourceIcon from "../icons/view-source.svg?raw";
import forkIcon from "../icons/fork.svg?raw";
import undoIcon from "../icons/undo.svg?raw";

interface Props {
  sessionId: number;
  messages: DisplayMessage[];
  isProcessing: boolean;
  onFork?: (sid: number, afterUuid: string) => void;
  onUndo?: (tid: number, afterUuid: string) => void;
  onEditMessage?: (tid: number, uuid: string, content: string) => void;
  forkableUuids?: Set<string>;
  onViewFile?: (filePath: string) => void;
}

function ResultMessageView({ message }: { message: DisplayMessage }) {
  const d = message.resultData!;
  const durationSec = d.durationMs ? Math.floor(d.durationMs / 1000) : 0;
  const apiSec = d.durationApiMs ? Math.floor(d.durationApiMs / 1000) : 0;
  const [expanded, setExpanded] = useState(d.isError);

  if (!expanded) {
    return (
      <div
        class={`result-divider ${
          d.isError ? "result-error" : "result-success"
        }`}
        onClick={() => {
          setExpanded(true);
        }}
      >
        <hr />
        <span class="result-divider-icon">{d.isError ? "!" : "\u2713"}</span>
        <hr />
      </div>
    );
  }

  return (
    <div
      class={`message result-message ${
        d.isError ? "result-error" : "result-success"
      }`}
      onClick={() => {
        setExpanded(false);
      }}
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

        {d.stopReason && <span>Stop: {d.stopReason}</span>}
      </div>
      {d.modelUsage && Object.keys(d.modelUsage).length > 0 && (
        <details
          class="result-details"
          onClick={(e) => {
            e.stopPropagation();
          }}
        >
          <summary>Per-model usage</summary>
          <pre>{JSON.stringify(d.modelUsage, null, 2)}</pre>
        </details>
      )}
      {d.permissionDenials && d.permissionDenials.length > 0 && (
        <details
          class="result-details"
          onClick={(e) => {
            e.stopPropagation();
          }}
        >
          <summary>Permission denials ({d.permissionDenials.length})</summary>
          <pre>{JSON.stringify(d.permissionDenials, null, 2)}</pre>
        </details>
      )}
      {d.errors && d.errors.length > 0 && (
        <details
          class="result-details"
          onClick={(e) => {
            e.stopPropagation();
          }}
        >
          <summary>Errors ({d.errors.length})</summary>
          <pre>{d.errors.join("\n\n")}</pre>
        </details>
      )}
      {d.result && <div class="result-text">{d.result}</div>}
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

function SummaryMessageView({ message }: { message: DisplayMessage }) {
  const text = message.content
    .filter((b): b is { type: "text"; text: string } => b.type === "text")
    .map((b) => b.text)
    .join("\n");

  return (
    <div class="message summary-message">
      <div class="summary-header">Session Summary</div>
      <Markdown text={text} class="summary-text" />
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
                ? `${(item as Record<string, unknown>).name}${
                    (item as Record<string, unknown>).status
                      ? ` [${(item as Record<string, unknown>).status}]`
                      : ""
                  }`
                : JSON.stringify(item)}
          </li>
        ))}
      </ul>
    </details>
  );
}

function SystemInitView({ message }: { message: DisplayMessage }) {
  const [expanded, setExpanded] = useState(false);
  const raw = message.rawSource as Record<string, unknown>;

  if (!expanded) {
    return (
      <div
        class="result-divider init-message"
        onClick={() => {
          setExpanded(true);
        }}
      >
        <hr />
        <span class="result-divider-icon">{"☀"}</span>
        <hr />
      </div>
    );
  }

  return (
    <div class="message system-message init-message">
      <div
        class="init-header"
        onClick={() => {
          setExpanded(false);
        }}
      >
        Session Init
      </div>
      <div class="init-meta">
        {raw.model && <span>Model: {raw.model}</span>}
        {raw.agent_version && <span>v{raw.agent_version}</span>}
        {raw.permission_mode && <span>{raw.permission_mode}</span>}
      </div>
      {Array.isArray(raw.tools) && raw.tools.length > 0 && (
        <InitDetailList label="Tools" items={raw.tools} />
      )}
      {Array.isArray(raw.mcp_servers) && raw.mcp_servers.length > 0 && (
        <InitDetailList label="MCP servers" items={raw.mcp_servers} />
      )}
      {Array.isArray(raw.agents) && raw.agents.length > 0 && (
        <InitDetailList label="Agents" items={raw.agents} />
      )}
      {Array.isArray(raw.skills) && raw.skills.length > 0 && (
        <InitDetailList label="Skills" items={raw.skills} />
      )}
      {Array.isArray(raw.plugins) && raw.plugins.length > 0 && (
        <InitDetailList label="Plugins" items={raw.plugins} />
      )}
    </div>
  );
}

function TaskLifecycleView({ message }: { message: DisplayMessage }) {
  const raw = message.rawSource as Record<string, unknown>;
  const isStarted = raw.subtype === "task_started";
  const taskType = raw.task_type;
  const taskId = raw.task_id;

  let label: string;
  let description: string;
  if (isStarted) {
    label = "Task started";
    description =
      (raw.description as string | undefined) ||
      (taskId as string | undefined) ||
      "";
  } else {
    label = `Task ${typeof raw.status === "string" ? raw.status : "updated"}`;
    description =
      (raw.summary as string | undefined) ||
      (taskId as string | undefined) ||
      "";
  }

  return (
    <div
      class={`message task-lifecycle-message${
        isStarted ? " task-started" : " task-notification"
      }`}
    >
      <span class="task-lifecycle-label">{label}</span>
      {taskType && <span class="task-lifecycle-type">{taskType}</span>}
      {description && <span class="task-lifecycle-desc">{description}</span>}
    </div>
  );
}

function ControlResponseView({ message }: { message: DisplayMessage }) {
  const raw = message.rawSource as
    | { response?: { subtype?: string } }
    | undefined;
  const subtype = raw?.response?.subtype ?? "unknown";
  return (
    <div class="message control-response-message">
      <span class="control-response-label">Control response</span>
      <span class="control-response-subtype">{subtype}</span>
    </div>
  );
}

function SystemStatusMessageView({ message }: { message: DisplayMessage }) {
  return (
    <div class="message system-status-message">
      status: {message.statusText}
    </div>
  );
}

function jsonReplacer(_key: string, value: unknown) {
  return value instanceof Map
    ? (Object.fromEntries(value) as Record<string, unknown>)
    : value;
}

function HighlightedJson({ text }: { text: string }) {
  const tokens = useHighlight(text, "json");
  return (
    <pre>
      {tokens
        ? tokens.map((line, i) => (
            <span key={i}>
              {i > 0 && "\n"}
              {renderTokens(line)}
            </span>
          ))
        : text}
    </pre>
  );
}

function SourceView({ msg, tid }: { msg: DisplayMessage; tid: number }) {
  const hasRaw = msg.seq != null;
  const [tab, setTab] = useState<"raw" | "agnostic">(
    hasRaw ? "raw" : "agnostic",
  );
  const [rawSources, setRawSources] = useState<unknown[] | null>(null);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (msg.seq == null) return;
    const seqs = Array.isArray(msg.seq) ? msg.seq : [msg.seq];
    setLoading(true);
    Promise.all(
      seqs.map((s) =>
        fetch(`/api/raw-source?tid=${tid}&seq=${s}`).then((r) => r.json()),
      ),
    )
      .then((results) => {
        setRawSources(results);
        setLoading(false);
      })
      .catch(() => {
        setLoading(false);
      });
  }, [tid, msg.seq]);

  const agnosticText = useMemo(
    () => JSON.stringify(msg.rawSource ?? msg, jsonReplacer, 2),
    [msg.rawSource ?? msg],
  );
  const rawText = useMemo(() => {
    if (!rawSources) return null;
    return rawSources.map((s) => JSON.stringify(s, jsonReplacer, 2)).join("\n");
  }, [rawSources]);

  return (
    <div class="message source-view">
      {hasRaw && (
        <div class="source-tabs">
          <button
            class={`source-tab${tab === "raw" ? " active" : ""}`}
            onClick={() => {
              setTab("raw");
            }}
          >
            Raw
          </button>
          <button
            class={`source-tab${tab === "agnostic" ? " active" : ""}`}
            onClick={() => {
              setTab("agnostic");
            }}
          >
            Agnostic
          </button>
        </div>
      )}
      {tab === "raw" && loading && <div class="source-loading">Loading...</div>}
      {tab === "raw" && rawText && <HighlightedJson text={rawText} />}
      {tab === "agnostic" && <HighlightedJson text={agnosticText} />}
    </div>
  );
}

const MessageView = memo(
  function MessageView({
    msg,
    tid,
    onFork,
    onUndo,
    onEdit,
    forkable,
    children,
  }: {
    msg: DisplayMessage;
    tid: number;
    onFork?: (afterUuid: string) => void;
    onUndo?: (afterUuid: string) => void;
    onEdit?: (uuid: string, content: string) => void;
    forkable?: boolean;
    children: ComponentChildren;
  }) {
    const [showSource, setShowSource] = useState(false);
    const [editing, setEditing] = useState(false);
    const [editText, setEditText] = useState("");
    const uuid = msg.uuid;

    const startEdit = useCallback(() => {
      const text = msg.content
        .filter((b): b is { type: "text"; text: string } => b.type === "text")
        .map((b) => b.text)
        .join("\n");
      setEditText(text);
      setEditing(true);
    }, [msg.content]);

    const saveEdit = useCallback(() => {
      if (uuid && onEdit) onEdit(uuid, editText);
      setEditing(false);
    }, [uuid, onEdit, editText]);

    return (
      <div
        id={`msg-${msg.id}`}
        class={`message-wrapper${showSource ? " show-source" : ""}`}
      >
        <div class="message-actions">
          {uuid && onEdit && (
            <button
              class="msg-action-btn edit-btn"
              onClick={startEdit}
              title="Edit message"
            >
              <span
                class="action-icon"
                dangerouslySetInnerHTML={{ __html: editIcon }}
              />
            </button>
          )}
          {(msg.rawSource != null || msg.streamingBlocks !== undefined) && (
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
          )}
        </div>
        {editing ? (
          <div class="message user-message editing">
            <textarea
              class="edit-textarea"
              value={editText}
              onInput={(e) => {
                setEditText((e.target as HTMLTextAreaElement).value);
              }}
              onKeyDown={(e) => {
                if (e.key === "Escape") {
                  setEditing(false);
                } else if (e.key === "Enter" && !e.shiftKey) {
                  e.preventDefault();
                  saveEdit();
                }
              }}
              ref={(el) => el?.focus()}
            />
            <div class="edit-actions">
              <button
                class="btn btn-sm"
                onClick={() => {
                  setEditing(false);
                }}
              >
                Cancel
              </button>
              <button class="btn btn-sm btn-primary" onClick={saveEdit}>
                Save
              </button>
            </div>
          </div>
        ) : showSource ? (
          <SourceView msg={msg} tid={tid} />
        ) : (
          children
        )}
        {uuid && forkable && (onFork || onUndo) && (
          <div class="message-actions message-actions-bottom">
            {onFork && (
              <button
                class="msg-action-btn fork-btn"
                onClick={() => {
                  onFork(uuid);
                }}
                title="Fork session after this point"
              >
                <span
                  class="action-icon"
                  dangerouslySetInnerHTML={{ __html: forkIcon }}
                />
              </button>
            )}
            {onUndo && (
              <button
                class="msg-action-btn undo-btn"
                onClick={() => {
                  onUndo(uuid);
                }}
                title="Undo: rewind to this point"
              >
                <span
                  class="action-icon"
                  dangerouslySetInnerHTML={{ __html: undoIcon }}
                />
              </button>
            )}
          </div>
        )}
      </div>
    );
  },
  (prev, next) =>
    prev.msg === next.msg &&
    prev.tid === next.tid &&
    prev.onFork === next.onFork &&
    prev.onUndo === next.onUndo &&
    prev.onEdit === next.onEdit &&
    prev.forkable === next.forkable,
);

export function MessageList({
  sessionId,
  messages,
  onFork,
  onUndo,
  onEditMessage,
  forkableUuids,
  onViewFile,
}: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  const handleFork = useMemo(
    () =>
      onFork
        ? (afterUuid: string) => {
            onFork(sessionId, afterUuid);
          }
        : undefined,
    [onFork, sessionId],
  );
  const handleUndo = useMemo(
    () =>
      onUndo
        ? (afterUuid: string) => {
            onUndo(sessionId, afterUuid);
          }
        : undefined,
    [onUndo, sessionId],
  );
  const handleEditMessage = useMemo(
    () =>
      onEditMessage
        ? (uuid: string, content: string) => {
            onEditMessage(sessionId, uuid, content);
          }
        : undefined,
    [onEditMessage, sessionId],
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
    return () => {
      el.removeEventListener("scroll", onScroll);
    };
  }, []);

  // Partition messages: top-level vs nested under a parent tool_use_id
  const prevChildrenRef = useRef(new Map<string, DisplayMessage[]>());
  const { childrenByParent, topLevelMessages } = useMemo(() => {
    const newMap = new Map<string, DisplayMessage[]>();
    const topLevelMessages: DisplayMessage[] = [];
    for (const msg of messages) {
      if (msg.parentToolUseId) {
        let list = newMap.get(msg.parentToolUseId);
        if (!list) {
          list = [];
          newMap.set(msg.parentToolUseId, list);
        }
        list.push(msg);
      } else {
        topLevelMessages.push(msg);
      }
    }

    // Stabilize: reuse previous entry arrays when content hasn't changed
    // (same length and same item references). This prevents AssistantMessage
    // from doing unnecessary VDOM work when its parent re-renders.
    const prev = prevChildrenRef.current;
    for (const [key, arr] of newMap) {
      const prevArr = prev.get(key);
      if (
        prevArr &&
        prevArr.length === arr.length &&
        prevArr.every((m, i) => m === arr[i])
      ) {
        newMap.set(key, prevArr);
      }
    }
    prevChildrenRef.current = newMap;

    return { childrenByParent: newMap, topLevelMessages };
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
                  onViewFile={onViewFile}
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
              if (msg.subtype === "init") {
                inner = <SystemInitView message={msg} />;
              } else if (msg.subtype === "status") {
                inner = <SystemStatusMessageView message={msg} />;
              } else if (msg.subtype === "task_lifecycle") {
                inner = <TaskLifecycleView message={msg} />;
              } else if (msg.subtype === "control_response") {
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
                  </div>
                );
              }
              break;
            }
            default:
              inner = (
                <div class="message system-message">
                  <pre>
                    Unknown display type: {msg.type}
                    {"\n"}
                    {JSON.stringify(msg, null, 2)}
                  </pre>
                </div>
              );
          }
          const msgUuid = msg.uuid;
          const isForkable =
            !!msgUuid && !!forkableUuids && forkableUuids.has(msgUuid);
          return (
            <MessageView
              key={msg.id}
              msg={msg}
              tid={sessionId}
              onFork={handleFork}
              onUndo={msg.type === "user" ? handleUndo : undefined}
              onEdit={msg.type === "user" ? handleEditMessage : undefined}
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
