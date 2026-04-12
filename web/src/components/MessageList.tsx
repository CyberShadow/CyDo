import { memo } from "preact/compat";
import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  useMemo,
  useCallback,
} from "preact/hooks";
import type { DisplayMessage, Block } from "../types";
import { hasAnsi, renderAnsi } from "../ansi";
import { AssistantMessage } from "./AssistantMessage";
import { UserMessage } from "./UserMessage";
import { useDevMode } from "../devMode";
import { Markdown } from "./Markdown";
import { SourceView } from "./SourceView";
import editIcon from "../icons/edit.svg?raw";
import viewSourceIcon from "../icons/view-source.svg?raw";
import forkIcon from "../icons/fork.svg?raw";
import undoIcon from "../icons/undo.svg?raw";
import sunIcon from "../icons/sun.svg?raw";
import checkIcon from "../icons/check.svg?raw";
import errorIcon from "../icons/error.svg?raw";

interface Props {
  sessionId: number;
  messages: DisplayMessage[];
  blocks: Map<string, Block>;
  isProcessing: boolean;
  onFork?: (sid: number, afterUuid: string) => void;
  onUndo?: (tid: number, afterUuid: string) => void;
  onEditMessage?: (tid: number, uuid: string, content: string) => void;
  forkableUuids?: Set<string>;
  onViewFile?: (filePath: string) => void;
}

function ResultMessageView({ message }: { message: DisplayMessage }) {
  const devMode = useDevMode();
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
        <span class="result-divider-icon">
          <span
            class="action-icon"
            dangerouslySetInnerHTML={{
              __html: d.isError ? errorIcon : checkIcon,
            }}
          />
        </span>
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

function SystemUserMessage({ message }: { message: DisplayMessage }) {
  const meta = message.cydoMeta!;
  // Messages without vars (nudges) start collapsed; messages with vars show them by default.
  const [showFull, setShowFull] = useState(false);

  const text = message.content
    .filter((b): b is { type: "text"; text: string } => b.type === "text")
    .map((b) => b.text)
    .join("\n");

  const hasVars = meta.vars && Object.keys(meta.vars).length > 0;

  if (!hasVars) {
    // Nudge-style: collapsed divider or expanded full text
    if (!showFull) {
      return (
        <div
          class={`result-divider system-user-message${message.pending ? " pending" : ""}`}
          onClick={() => {
            setShowFull(true);
          }}
        >
          <hr />
          <svg
            class="result-divider-icon system-user-icon cydo-tool-logo"
            width="13"
            height="13"
            viewBox="0 0 16 16"
            fill="none"
            stroke-width="2"
            stroke-linecap="round"
          >
            <path
              style={{ stroke: "var(--success)" }}
              d="M5.5 12L10.5 4L13 8l-2.5 4"
            />
            <path
              style={{ stroke: "var(--processing)" }}
              d="M5.5 4L3 8l2.5 4"
            />
          </svg>
          <span class="system-user-label">{meta.label}</span>
          <hr />
        </div>
      );
    }
    return (
      <div
        class={`message user-message system-user-expanded${message.pending ? " pending" : ""}`}
        onClick={() => {
          setShowFull(false);
        }}
      >
        <div class="system-user-header">{meta.label}</div>
        <pre class="system-user-pre">{text}</pre>
      </div>
    );
  }

  // Template-style: default view shows label + vars (task_description etc.)
  // Keep "user-message" class for backward compatibility with existing selectors.
  const bodyVar = meta.bodyVar;
  const bodyValue = bodyVar && meta.vars ? meta.vars[bodyVar] : undefined;
  const otherVars = meta.vars
    ? Object.entries(meta.vars).filter(([k]) => k !== bodyVar)
    : [];

  return (
    <div
      class={`message user-message system-user-message${message.pending ? " pending" : ""}`}
    >
      <div class="system-user-header">
        <svg
          class="cydo-tool-logo"
          width="13"
          height="13"
          viewBox="0 0 16 16"
          fill="none"
          stroke-width="2"
          stroke-linecap="round"
        >
          <path
            style={{ stroke: "var(--success)" }}
            d="M5.5 12L10.5 4L13 8l-2.5 4"
          />
          <path style={{ stroke: "var(--processing)" }} d="M5.5 4L3 8l2.5 4" />
        </svg>
        {meta.label}
      </div>
      {bodyValue !== undefined && (
        <div class="system-user-body">
          {meta.bodyMarkdown ? (
            <Markdown text={bodyValue} />
          ) : (
            <div class="user-text">{bodyValue}</div>
          )}
        </div>
      )}
      {otherVars.length > 0 && (
        <div class="system-user-vars">
          {otherVars.map(([k, v]) => (
            <div key={k} class="system-user-var">
              <span class="field-label">{k}:</span>{" "}
              <span class="field-value">{v}</span>
            </div>
          ))}
        </div>
      )}
      <details
        class="system-user-full-text"
        onClick={(e) => {
          e.stopPropagation();
        }}
      >
        <summary>Full message</summary>
        <pre>{text}</pre>
      </details>
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
        <span class="result-divider-icon">
          <span
            class="action-icon"
            dangerouslySetInnerHTML={{ __html: sunIcon }}
          />
        </span>
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
        {raw.cwd && (
          <span>
            cwd: <code>{raw.cwd}</code>
          </span>
        )}
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

function shallowArrayEqual<T>(a: T[], b: T[]): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

const MessageView = memo(
  function MessageView({
    msg,
    tid,
    resolvedBlocks,
    childrenByParent,
    resolvedBlocksByMsg,
    onViewFile,
    onFork,
    onUndo,
    onEdit,
    forkable,
  }: {
    msg: DisplayMessage;
    tid: number;
    resolvedBlocks: Block[];
    childrenByParent: Map<string, DisplayMessage[]>;
    resolvedBlocksByMsg: Map<string, Block[]>;
    onViewFile?: (filePath: string) => void;
    onFork?: (afterUuid: string) => void;
    onUndo?: (afterUuid: string) => void;
    onEdit?: (uuid: string, content: string) => void;
    forkable?: boolean;
  }) {
    const devMode = useDevMode();
    const [showSource, setShowSource] = useState(false);
    const [editing, setEditing] = useState(false);
    const [editText, setEditText] = useState("");
    const uuid = msg.uuid;

    const startEdit = useCallback(() => {
      let text: string;
      if (msg.type === "assistant") {
        text = resolvedBlocks
          .filter((b) => b.type === "text")
          .map((b) => b.text)
          .join("\n");
      } else {
        text = msg.content
          .filter((b): b is { type: "text"; text: string } => b.type === "text")
          .map((b) => b.text)
          .join("\n");
      }
      setEditText(text);
      setEditing(true);
    }, [msg, resolvedBlocks]);

    const saveEdit = useCallback(() => {
      if (uuid && onEdit) onEdit(uuid, editText);
      setEditing(false);
    }, [uuid, onEdit, editText]);

    let inner;
    switch (msg.type) {
      case "user":
        inner = msg.cydoMeta ? (
          <SystemUserMessage message={msg} />
        ) : (
          <UserMessage message={msg} />
        );
        break;
      case "assistant":
        inner = (
          <AssistantMessage
            message={msg}
            resolvedBlocks={resolvedBlocks}
            resolvedBlocksByMsg={resolvedBlocksByMsg}
            childrenByParent={childrenByParent}
            onViewFile={onViewFile}
            sessionId={tid}
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
        } else if (msg.subtype === "stderr") {
          const text = msg.content
            .filter(
              (b): b is { type: "text"; text: string } => b.type === "text",
            )
            .map((b) => b.text)
            .join("\n");
          inner = (
            <div class="message stderr-message">
              <span class="stderr-badge">stderr</span>
              <pre class="stderr-content">
                {hasAnsi(text) ? renderAnsi(text) : text}
              </pre>
            </div>
          );
        } else if (msg.subtype !== "parse_error" || devMode) {
          const text = msg.content
            .filter(
              (b): b is { type: "text"; text: string } => b.type === "text",
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
          {(msg.rawSource != null || msg.streaming === true) && (
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
          inner
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
    shallowArrayEqual(prev.resolvedBlocks, next.resolvedBlocks) &&
    prev.tid === next.tid &&
    prev.childrenByParent === next.childrenByParent &&
    prev.resolvedBlocksByMsg === next.resolvedBlocksByMsg &&
    prev.onViewFile === next.onViewFile &&
    prev.onFork === next.onFork &&
    prev.onUndo === next.onUndo &&
    prev.onEdit === next.onEdit &&
    prev.forkable === next.forkable,
);

export function MessageList({
  sessionId,
  messages,
  blocks,
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
  const prevResolvedBlocksRef = useRef(new Map<string, Block[]>());
  const { childrenByParent, topLevelMessages, resolvedBlocksByMsg } =
    useMemo(() => {
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

      // Stabilize arrays: reuse previous entry arrays when content hasn't changed
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
      // Stabilize the Map itself: if keys and values are unchanged, reuse the
      // previous Map object so MessageView's `===` comparator can skip re-renders.
      let stableChildrenMap: Map<string, DisplayMessage[]>;
      if (
        newMap.size === prev.size &&
        [...newMap].every(([k, v]) => prev.get(k) === v)
      ) {
        stableChildrenMap = prev;
      } else {
        stableChildrenMap = newMap;
      }
      prevChildrenRef.current = stableChildrenMap;

      // Pre-resolve blocks for nested assistant messages so AssistantMessage
      // doesn't need the full blocks Map (which changes on every streaming delta).
      const newResolvedMap = new Map<string, Block[]>();
      for (const [, children] of stableChildrenMap) {
        for (const child of children) {
          if (child.type === "assistant" && child.blockIds) {
            const resolved = child.blockIds
              .map((id) => blocks.get(id))
              .filter(Boolean) as Block[];
            newResolvedMap.set(child.id, resolved);
          }
        }
      }
      // Stabilize arrays
      const prevResolved = prevResolvedBlocksRef.current;
      for (const [key, arr] of newResolvedMap) {
        const prevArr = prevResolved.get(key);
        if (prevArr && shallowArrayEqual(prevArr, arr)) {
          newResolvedMap.set(key, prevArr);
        }
      }
      // Stabilize the Map itself
      let stableResolvedMap: Map<string, Block[]>;
      if (
        newResolvedMap.size === prevResolved.size &&
        [...newResolvedMap].every(([k, v]) => prevResolved.get(k) === v)
      ) {
        stableResolvedMap = prevResolved;
      } else {
        stableResolvedMap = newResolvedMap;
      }
      prevResolvedBlocksRef.current = stableResolvedMap;

      return {
        childrenByParent: stableChildrenMap,
        topLevelMessages,
        resolvedBlocksByMsg: stableResolvedMap,
      };
    }, [messages, blocks]);

  return (
    <div class="message-list" ref={containerRef}>
      <div class="message-list-inner">
        {topLevelMessages.map((msg) => {
          const resolvedBlocks =
            msg.type === "assistant"
              ? ((msg.blockIds ?? [])
                  .map((id) => blocks.get(id))
                  .filter(Boolean) as Block[])
              : [];
          const msgUuid = msg.uuid;
          const isForkable =
            !!msgUuid && !!forkableUuids && forkableUuids.has(msgUuid);
          return (
            <MessageView
              key={msg.id}
              msg={msg}
              tid={sessionId}
              resolvedBlocks={resolvedBlocks}
              childrenByParent={childrenByParent}
              resolvedBlocksByMsg={resolvedBlocksByMsg}
              onViewFile={onViewFile}
              onFork={handleFork}
              onUndo={msg.type === "user" ? handleUndo : undefined}
              onEdit={msg.type === "user" ? handleEditMessage : undefined}
              forkable={isForkable}
            />
          );
        })}
      </div>
    </div>
  );
}
