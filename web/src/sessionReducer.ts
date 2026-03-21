// Pure task state reducers — no React dependency.
//
// Each function takes a TaskState and returns a new TaskState.
// Convention: functions pre-increment s.msgIdCounter in place before spreading
// into the return value. This is safe because the caller always replaces the
// old state with the returned state (the old reference is never reused).

import type {
  TaskState as SessionState,
  DisplayMessage,
  ToolResultContent,
  FileEdit,
} from "./types";
import type {
  AgnosticEvent,
  AssistantMessage,
  ResultMessage,
  SystemInitMessage,
  SystemStatusMessage,
  SystemCompactBoundaryMessage,
  SystemTaskStartedMessage,
  SystemTaskNotificationMessage,
  SummaryMessage,
  RateLimitEventMessage,
  StreamBlockStart,
  StreamBlockDelta,
  StreamBlockStop,
  UserEchoMessage,
  UserContentBlock,
  ItemStartedEvent,
  ItemDeltaEvent,
  ItemCompletedEvent,
  ItemResultEvent,
  TurnStopEvent,
} from "./protocol";

function getExtras(
  msg: Record<string, unknown>,
): Record<string, unknown> | undefined {
  const extras = msg._extras;
  if (
    extras &&
    typeof extras === "object" &&
    !Array.isArray(extras) &&
    Object.keys(extras).length > 0
  ) {
    return extras as Record<string, unknown>;
  }
  return undefined;
}

function getSeq(msg: unknown): number | undefined {
  const seq = (msg as Record<string, unknown>)._seq;
  return typeof seq === "number" ? seq : undefined;
}

// ---------------------------------------------------------------------------
// Individual reducers
// ---------------------------------------------------------------------------

export function reduceParseError(
  s: SessionState,
  label: string,
  detail: string,
  raw: unknown,
): SessionState {
  const id = `parse-error-${++s.msgIdCounter}`;
  return {
    ...s,
    messages: [
      ...s.messages,
      {
        id,
        type: "system" as const,
        content: [
          {
            type: "text" as const,
            text: `${label}: ${detail}\n${JSON.stringify(raw, null, 2)}`,
          },
        ],
      },
    ],
  };
}

export function reduceSystemInit(
  s: SessionState,
  msg: SystemInitMessage,
): SessionState {
  const initMsg: DisplayMessage = {
    id: `init-${++s.msgIdCounter}`,
    type: "system" as const,
    content: [],
    rawSource: msg,
    seq: getSeq(msg),
  };
  return {
    ...s,
    sessionInfo: {
      model: msg.model,
      version: msg.agent_version,
      sessionId: msg.session_id,
      cwd: msg.cwd,
      tools: msg.tools,
      permission_mode: msg.permission_mode,
      mcp_servers: msg.mcp_servers,
      agents: msg.agents,
      api_key_source: msg.api_key_source,
      skills: msg.skills,
      plugins: msg.plugins,
      fast_mode_state: msg.fast_mode_state,
      agent: msg.agent,
      supports_file_revert: msg.supports_file_revert,
    },
    messages: [...s.messages, initMsg],
  };
}

export function reduceSystemStatus(
  s: SessionState,
  msg: SystemStatusMessage,
): SessionState {
  const id = `status-${++s.msgIdCounter}`;
  return {
    ...s,
    messages: [
      ...s.messages,
      {
        id,
        type: "system" as const,
        content: [],
        statusText: msg.status || "clear",
        rawSource: msg,
        seq: getSeq(msg),
      },
    ],
  };
}

export function reduceStopHookSummary(
  s: SessionState,
  msg: {
    hookCount: number;
    hookInfos: Array<{ command: string; durationMs: number }>;
    hookErrors: Array<unknown>;
    preventedContinuation: boolean;
    hasOutput: boolean;
    [key: string]: unknown;
  },
): SessionState {
  const parts: string[] = [];
  for (const hook of msg.hookInfos) {
    parts.push(`${hook.command} (${hook.durationMs}ms)`);
  }
  const summary = parts.join(", ");
  const prefix = msg.preventedContinuation
    ? "Stop hook prevented continuation"
    : `Stop hook${msg.hookCount > 1 ? "s" : ""}`;
  const text = `${prefix}: ${summary}`;

  const id = `stop-hook-${++s.msgIdCounter}`;
  return {
    ...s,
    messages: [
      ...s.messages,
      {
        id,
        type: "system" as const,
        content: [{ type: "text" as const, text }],
        rawSource: msg,
        seq: getSeq(msg),
      },
    ],
  };
}

export function reduceCompactBoundary(
  s: SessionState,
  msg: SystemCompactBoundaryMessage,
): SessionState {
  const id = `compact-${++s.msgIdCounter}`;
  const cm = msg.compact_metadata;
  return {
    ...s,
    messages: [
      ...s.messages,
      {
        id,
        type: "compact_boundary" as const,
        content: [],
        compactMetadata: cm
          ? { trigger: cm.trigger, preTokens: cm.pre_tokens }
          : undefined,
        rawSource: msg,
        seq: getSeq(msg),
      },
    ],
  };
}

export function reduceTaskLifecycle(
  s: SessionState,
  msg: SystemTaskStartedMessage | SystemTaskNotificationMessage,
): SessionState {
  const id = `task-${++s.msgIdCounter}`;
  let text: string;
  if (msg.type === "task/started") {
    const desc = msg.description || msg.task_id;
    const typeLabel = msg.task_type ? ` [${msg.task_type}]` : "";
    text = `Task started: ${desc}${typeLabel}`;
  } else {
    text = `Task ${msg.status}: ${msg.summary || msg.task_id}`;
  }
  return {
    ...s,
    messages: [
      ...s.messages,
      {
        id,
        type: "system" as const,
        content: [{ type: "text" as const, text }],
        rawSource: msg,
        seq: getSeq(msg),
      },
    ],
  };
}

export function reduceSummary(
  s: SessionState,
  msg: SummaryMessage,
): SessionState {
  const id = `summary-${++s.msgIdCounter}`;
  return {
    ...s,
    messages: [
      ...s.messages,
      {
        id,
        type: "summary" as const,
        content: [{ type: "text" as const, text: msg.summary || "" }],
        rawSource: msg,
        seq: getSeq(msg),
      },
    ],
  };
}

export function reduceRateLimit(
  s: SessionState,
  msg: RateLimitEventMessage,
): SessionState {
  const id = `ratelimit-${++s.msgIdCounter}`;
  return {
    ...s,
    messages: [
      ...s.messages,
      {
        id,
        type: "rate_limit" as const,
        content: [],
        rateLimitInfo: msg.rate_limit_info,
        rawSource: msg,
        seq: getSeq(msg),
      },
    ],
  };
}

export function reduceAssistantMessage(
  s: SessionState,
  msg: AssistantMessage,
): SessionState {
  const msgId = msg.id;
  let idx = s.messages.findIndex((m) => m.id === msgId);

  // If not found by real ID, search backwards for a streaming placeholder
  // to adopt (it was created by content_block_start before the full
  // assistant message arrived, and may no longer be the last message if
  // a user echo was inserted after it).  Once adopted, the placeholder's
  // ID is replaced with the real one, so previously-adopted placeholders
  // won't re-match.  We intentionally don't require active streamingBlocks
  // here because during batched replay message_stop may have already
  // cleared them before the full assistant message is processed.
  if (idx < 0) {
    for (let i = s.messages.length - 1; i >= 0; i--) {
      const m = s.messages[i]!;
      if (m.type === "assistant" && m.id.startsWith("streaming-")) {
        idx = i;
        break;
      }
    }
  }

  if (idx >= 0) {
    const updated = [...s.messages];
    const existingMsg = { ...updated[idx]! };
    // Replace temp ID with real one when adopting a streaming placeholder
    if (existingMsg.id !== msgId) existingMsg.id = msgId;
    existingMsg.content = [...existingMsg.content, ...msg.content];
    // Only keep streamingBlocks active if it was a streaming placeholder;
    // during JSONL replay there's no streaming so leave it undefined.
    if (existingMsg.streamingBlocks !== undefined) {
      existingMsg.streamingBlocks = [];
    }
    // Update usage if present (later messages may have updated counts)
    if (msg.usage) {
      existingMsg.usage = msg.usage;
    }
    // Set fields that may not have been on the placeholder
    existingMsg.model ??= msg.model;
    existingMsg.isSidechain ??= msg.is_sidechain;
    existingMsg.parentToolUseId ??= msg.parent_tool_use_id;
    existingMsg.extraFields ??= getExtras(msg);
    // Accumulate raw sources and seq numbers
    const prev = existingMsg.rawSource;
    existingMsg.rawSource = prev
      ? Array.isArray(prev)
        ? [...(prev as unknown[]), msg]
        : [prev, msg]
      : msg;
    const newSeq = getSeq(msg);
    if (newSeq != null) {
      const prevSeq = existingMsg.seq;
      existingMsg.seq = prevSeq != null
        ? Array.isArray(prevSeq)
          ? [...prevSeq, newSeq]
          : [prevSeq, newSeq]
        : newSeq;
    }
    updated[idx] = existingMsg;
    bumpNestedVersion(updated, existingMsg.parentToolUseId);
    return { ...s, messages: updated };
  }
  const extraFields = getExtras(msg);
  const messages = [
    ...s.messages,
    {
      id: msgId,
      type: "assistant" as const,
      content: [...msg.content],
      toolResults: new Map(),
      model: msg.model,
      isSidechain: msg.is_sidechain,
      parentToolUseId: msg.parent_tool_use_id,
      usage: msg.usage,
      extraFields,
      rawSource: msg,
      seq: getSeq(msg),
    },
  ];
  bumpNestedVersion(messages, msg.parent_tool_use_id);
  return { ...s, messages };
}

/** Lightweight file-edit tracker: records only metadata (toolUseId, messageId,
 *  filePath, type).  Actual file content is resolved on-demand by
 *  resolveEditContent() in FileViewer, avoiding string ops and memory
 *  overhead when the viewer is never opened. */
function trackFileEdits(
  state: SessionState,
  toolResults: Array<{
    tool_use_id: string;
    content: ToolResultContent;
    is_error?: boolean;
  }>,
): SessionState {
  for (const block of toolResults) {
    if (block.is_error) continue;
    for (let i = state.messages.length - 1; i >= 0; i--) {
      const m = state.messages[i]!;
      if (m.type !== "assistant") continue;
      const toolUse = m.content.find(
        (c) => c.type === "tool_use" && c.id === block.tool_use_id,
      );
      if (!toolUse) continue;

      const toolName = toolUse.name;
      if (!toolName || (toolName !== "Edit" && toolName !== "Write" && toolName !== "fileChange")) break;

      const input = toolUse.input ?? {};
      const filePath =
        typeof input.file_path === "string" ? input.file_path : null;
      if (!filePath) break;

      const edit: FileEdit = {
        toolUseId: block.tool_use_id,
        messageId: m.id,
        filePath,
        type: toolName === "Edit" ? "edit" : "write",
      };

      const trackedFiles = new Map(state.trackedFiles);
      const existing = trackedFiles.get(filePath);
      if (existing) {
        trackedFiles.set(filePath, {
          ...existing,
          edits: [...existing.edits, edit],
        });
      } else {
        trackedFiles.set(filePath, {
          path: filePath,
          edits: [edit],
        });
      }

      state = { ...state, trackedFiles };
      break;
    }
  }
  return state;
}

// Applies both tool-result linking and user-text echo in a single pass.

export function reduceUserEcho(
  s: SessionState,
  content: UserContentBlock[],
  isSidechain: boolean | undefined,
  parentToolUseId: string | null | undefined,
  rawMsg: UserEchoMessage,
  isSynthetic?: boolean,
  isMeta?: boolean,
  isSteering?: boolean,
): SessionState {
  // Collect text blocks and tool_result blocks separately
  const textBlocks: string[] = [];
  const toolResults: Array<{
    tool_use_id: string;
    content: ToolResultContent;
    is_error?: boolean;
  }> = [];

  for (const block of content) {
    if (block.type === "tool_result") {
      toolResults.push(
        block as {
          tool_use_id: string;
          content: ToolResultContent;
          is_error?: boolean;
        },
      );
    } else if (block.type === "text") {
      textBlocks.push(block.text ?? "");
    }
  }

  let state = s;

  // Extract the opaque tool result payload (varies by tool)
  const toolUseResult = rawMsg.tool_result ?? undefined;

  // Link tool results to their parent assistant messages
  if (toolResults.length > 0) {
    const updated = [...state.messages];
    const touchedIndices = new Set<number>();
    for (const block of toolResults) {
      for (let i = updated.length - 1; i >= 0; i--) {
        const m = updated[i]!;
        if (m.type === "assistant") {
          const hasToolUse = m.content.some(
            (c) => c.type === "tool_use" && c.id === block.tool_use_id,
          );
          if (hasToolUse) {
            const newMsg = { ...m, toolResults: new Map(m.toolResults) };
            newMsg.toolResults.set(block.tool_use_id, {
              toolUseId: block.tool_use_id,
              content: block.content,
              isError: block.is_error,
              toolResult: toolUseResult,
            });
            updated[i] = newMsg;
            touchedIndices.add(i);
            break;
          }
        }
      }
    }
    // Append the raw user message (carrying tool results) to each
    // touched assistant message's rawSource so "view source" shows
    // the complete round-trip.  Also merge any extra fields from the
    // tool-result user message onto the parent assistant message so
    // they are visible in the UI.
    for (const i of touchedIndices) {
      const msg = updated[i]!;
      const prev = msg.rawSource;
      msg.rawSource = prev
        ? Array.isArray(prev)
          ? [...(prev as unknown[]), rawMsg]
          : [prev, rawMsg]
        : rawMsg;
      const newSeq = getSeq(rawMsg);
      if (newSeq != null) {
        const prevSeq = msg.seq;
        msg.seq = prevSeq != null
          ? Array.isArray(prevSeq)
            ? [...prevSeq, newSeq]
            : [prevSeq, newSeq]
          : newSeq;
      }
    }
    state = { ...state, messages: updated };
    state = trackFileEdits(state, toolResults);
  }

  // If there are text blocks (actual user text, not just tool results), show as user message
  const meaningfulText = textBlocks.filter((t) => t.trim().length > 0);
  if (meaningfulText.length > 0 && toolResults.length === 0) {
    const isCompactSummary = !!rawMsg.isCompactSummary;
    const id = `user-echo-${++state.msgIdCounter}`;
    const echoMsg: DisplayMessage = {
      id,
      type: "user" as const,
      content: meaningfulText.map((t) => ({
        type: "text" as const,
        text: t,
      })),
      isSidechain,
      isSynthetic: isSynthetic || undefined,
      isMeta: isMeta || undefined,
      isSteering: isSteering || undefined,
      isCompactSummary: isCompactSummary || undefined,
      parentToolUseId,
      extraFields: getExtras(rawMsg as Record<string, unknown>),
      rawSource: rawMsg,
      seq: getSeq(rawMsg),
    };
    // Remove the pending placeholder (the user already sees their message
    // via the placeholder in the correct chronological position).  Use
    // insertBeforeStreaming to position the confirmed echo before any
    // streaming assistant message.  Exception: interrupt markers (isMeta)
    // should appear after the assistant's partial response.
    const filtered = state.messages.filter(
      (m) => !(m.pending && m.type === "user"),
    );
    const messages = isMeta
      ? [...filtered, echoMsg]
      : insertBeforeStreaming(filtered, echoMsg);
    bumpNestedVersion(messages, parentToolUseId);
    state = { ...state, messages };
  }

  return state;
}

export function reduceResultMessage(
  s: SessionState,
  msg: ResultMessage,
): SessionState {
  // A result (especially error_during_execution from an interrupt) means the
  // current turn is over.  Clear any lingering streaming state so the next
  // response creates a fresh assistant message instead of appending to the
  // interrupted one.
  let messages = s.messages;
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i]!;
    if (m.type === "assistant" && m.streamingBlocks) {
      messages = messages.slice();
      // Promote any in-progress streaming blocks into content so the
      // partial text remains visible after the stream is interrupted.
      const promoted = m.streamingBlocks
        .filter((b) => b.text)
        .map((b) => {
          if (b.type === "thinking")
            return { type: "thinking" as const, text: b.text };
          return { type: "text" as const, text: b.text };
        });
      messages[i] = {
        ...m,
        content: promoted.length > 0 ? [...m.content, ...promoted] : m.content,
        streamingBlocks: undefined,
      };
      bumpNestedVersion(messages, m.parentToolUseId);
      break;
    }
  }

  const id = `result-${++s.msgIdCounter}`;
  const resultExtraFields = getExtras(msg);
  return {
    ...s,
    totalCost: msg.total_cost_usd || s.totalCost,
    messages: [
      ...messages,
      {
        id,
        type: "result" as const,
        content: [],
        rawSource: msg,
        seq: getSeq(msg),
        extraFields: resultExtraFields,
        resultData: {
          subtype: msg.subtype,
          isError: msg.is_error,
          result: msg.result,
          numTurns: msg.num_turns,
          durationMs: msg.duration_ms,
          durationApiMs: msg.duration_api_ms,
          totalCostUsd: msg.total_cost_usd,
          usage: msg.usage,
          modelUsage: msg.model_usage,
          permissionDenials: msg.permission_denials,
          stopReason: msg.stop_reason,
          errors: msg.errors,
        },
      },
    ],
  };
}

/** Insert a message before any in-progress streaming assistant message.
 *  User messages should always precede the assistant's response, but the
 *  protocol may deliver the user echo after streaming has already started. */
function insertBeforeStreaming(
  messages: DisplayMessage[],
  msg: DisplayMessage,
): DisplayMessage[] {
  for (let i = messages.length - 1; i >= 0; i--) {
    if (
      messages[i]!.type === "assistant" &&
      messages[i]!.streamingBlocks !== undefined
    ) {
      const result = [...messages];
      result.splice(i, 0, msg);
      return result;
    }
  }
  return [...messages, msg];
}

/**
 * When a message with parentToolUseId is created or modified, bump the
 * nestedVersion counter on the parent assistant message so its object
 * reference changes.  Recurses upward: if the parent is itself nested,
 * its grandparent is bumped too.
 *
 * Mutates the `messages` array in place (callers always pass a fresh copy).
 */
function bumpNestedVersion(
  messages: DisplayMessage[],
  parentToolUseId: string | null | undefined,
): void {
  if (!parentToolUseId) return;
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i]!;
    if (
      m.type === "assistant" &&
      m.content.some((c) => c.type === "tool_use" && c.id === parentToolUseId)
    ) {
      messages[i] = { ...m, nestedVersion: (m.nestedVersion ?? 0) + 1 };
      // Recurse: if the parent is itself nested, bump its parent too.
      bumpNestedVersion(messages, m.parentToolUseId);
      return;
    }
  }
}

/** Find the last assistant message with active streaming blocks. */
function findStreamingMsg(messages: DisplayMessage[]): number {
  for (let i = messages.length - 1; i >= 0; i--) {
    if (messages[i]!.streamingBlocks?.length) return i;
  }
  return -1;
}

/** Find or create the in-progress assistant message for streaming blocks. */
function getStreamingMessage(s: SessionState): {
  messages: DisplayMessage[];
  msgIdx: number;
} {
  const messages = s.messages.slice();
  // Search backwards for an assistant message with active streaming
  for (let i = messages.length - 1; i >= 0; i--) {
    if (messages[i]!.type === "assistant" && messages[i]!.streamingBlocks) {
      messages[i] = { ...messages[i]! };
      return { messages, msgIdx: i };
    }
  }
  // Create a streaming placeholder
  const placeholder: DisplayMessage = {
    id: `streaming-${++s.msgIdCounter}`,
    type: "assistant" as const,
    content: [],
    toolResults: new Map(),
    streamingBlocks: [],
    nextCreationOrder: 0,
  };
  messages.push(placeholder);
  return { messages, msgIdx: messages.length - 1 };
}

export function reduceStreamBlockStart(
  s: SessionState,
  event: StreamBlockStart,
): SessionState {
  const { messages, msgIdx } = getStreamingMessage(s);
  const msg = messages[msgIdx]!;
  const creationOrder = msg.nextCreationOrder ?? msg.streamingBlocks?.length ?? 0;
  msg.nextCreationOrder = creationOrder + 1;
  msg.streamingBlocks = [
    ...(msg.streamingBlocks || []),
    {
      index: event.index,
      itemId: String(event.index),
      type: event.content_block.type,
      text: "",
      name: event.content_block.name,
      creationOrder,
    },
  ];
  bumpNestedVersion(messages, msg.parentToolUseId);
  return { ...s, messages };
}

export function reduceStreamBlockDelta(
  s: SessionState,
  event: StreamBlockDelta,
): SessionState {
  const targetIdx = findStreamingMsg(s.messages);
  if (targetIdx < 0) return s;
  const messages = s.messages.slice();
  const msg = { ...messages[targetIdx]! };
  messages[targetIdx] = msg;
  msg.streamingBlocks = msg.streamingBlocks!.map((b) => {
    if (b.index !== event.index) return b;
    const delta = event.delta;
    let append = "";
    if (delta.type === "text_delta") append = delta.text ?? "";
    else if (delta.type === "thinking_delta") append = delta.text ?? "";
    else if (delta.type === "input_json_delta")
      append = delta.partial_json ?? "";
    return { ...b, text: b.text + append };
  });
  bumpNestedVersion(messages, msg.parentToolUseId);
  return { ...s, messages };
}

export function reduceStreamBlockStop(
  s: SessionState,
  event: StreamBlockStop,
): SessionState {
  const targetIdx = findStreamingMsg(s.messages);
  if (targetIdx < 0) return s;
  const messages = s.messages.slice();
  const msg = { ...messages[targetIdx]! };
  messages[targetIdx] = msg;
  msg.streamingBlocks = msg.streamingBlocks!.filter(
    (b) => b.index !== event.index,
  );
  bumpNestedVersion(messages, msg.parentToolUseId);
  return { ...s, messages };
}

export function reduceStreamTurnStop(s: SessionState): SessionState {
  // Mark the assistant message as no longer streaming so the next
  // response creates a fresh message instead of reusing this one.
  for (let i = s.messages.length - 1; i >= 0; i--) {
    if (s.messages[i]!.type === "assistant" && s.messages[i]!.streamingBlocks) {
      const messages = s.messages.slice();
      messages[i] = { ...messages[i]!, streamingBlocks: undefined };
      bumpNestedVersion(messages, messages[i]!.parentToolUseId);
      return { ...s, messages };
    }
  }
  return s;
}

// ---------------------------------------------------------------------------
// Item-based protocol handlers (item/started, item/delta, item/completed,
// item/result, turn/stop) — new event types that carry IDs instead of indices.
// ---------------------------------------------------------------------------

function tryParseJson(text: string): Record<string, unknown> {
  if (!text) return {};
  try {
    return JSON.parse(text) as Record<string, unknown>;
  } catch {
    return {};
  }
}

function reduceItemStartedUserMessage(
  s: SessionState,
  event: ItemStartedEvent,
): SessionState {
  const text = event.text ?? "";

  let state = s;

  if (event.is_replay) {
    state = {
      ...state,
      messages: state.messages.filter(
        (m) => !(m.pending && m.type === "user"),
      ),
    };
  }

  if (event.pending) {
    const id = `user-echo-${++state.msgIdCounter}`;
    const echoMsg: DisplayMessage = {
      id,
      type: "user" as const,
      content: [{ type: "text" as const, text }],
      pending: true,
      isSidechain: event.is_sidechain,
      isSynthetic: event.is_synthetic || undefined,
      isMeta: event.is_meta || undefined,
      isSteering: event.is_steering || undefined,
      isCompactSummary: event.isCompactSummary || undefined,
      parentToolUseId: event.parent_tool_use_id,
      extraFields: getExtras(event as Record<string, unknown>),
    };
    const messages = event.is_meta
      ? [...state.messages, echoMsg]
      : insertBeforeStreaming(state.messages, echoMsg);
    bumpNestedVersion(messages, event.parent_tool_use_id);
    return { ...state, messages };
  }

  if (text.trim().length > 0) {
    const id = `user-echo-${++state.msgIdCounter}`;
    const echoMsg: DisplayMessage = {
      id,
      type: "user" as const,
      content: [{ type: "text" as const, text }],
      isSidechain: event.is_sidechain,
      isSynthetic: event.is_synthetic || undefined,
      isMeta: event.is_meta || undefined,
      isSteering: event.is_steering || undefined,
      isCompactSummary: event.isCompactSummary || undefined,
      parentToolUseId: event.parent_tool_use_id,
      extraFields: getExtras(event as Record<string, unknown>),
    };
    const filtered = state.messages.filter(
      (m) => !(m.pending && m.type === "user"),
    );
    const messages = event.is_meta
      ? [...filtered, echoMsg]
      : insertBeforeStreaming(filtered, echoMsg);
    bumpNestedVersion(messages, event.parent_tool_use_id);
    state = { ...state, messages };
  }

  // Draft recovery (same as message/user handler)
  if (state.preReloadDrafts && state.preReloadDrafts.length > 0 && text) {
    if (state.preReloadDrafts.includes(text)) {
      state = {
        ...state,
        confirmedDuringReplay: [
          ...(state.confirmedDuringReplay ?? []),
          text,
        ],
      };
    }
  }

  return state;
}

export function reduceItemStarted(
  s: SessionState,
  event: ItemStartedEvent,
): SessionState {
  if (event.item_type === "user_message") {
    return reduceItemStartedUserMessage(s, event);
  }

  const { messages, msgIdx } = getStreamingMessage(s);
  const msg = messages[msgIdx]!;

  const creationOrder = msg.nextCreationOrder ?? 0;
  msg.nextCreationOrder = creationOrder + 1;
  msg.streamingBlocks = [
    ...(msg.streamingBlocks || []),
    {
      index: -1,
      itemId: event.item_id,
      type: event.item_type,
      text: event.text ?? "",
      name: event.name,
      input: event.input,
      creationOrder,
    },
  ];

  if (event.parent_tool_use_id) {
    msg.parentToolUseId = event.parent_tool_use_id;
    bumpNestedVersion(messages, event.parent_tool_use_id);
  }

  return { ...s, messages };
}

export function reduceItemDelta(
  s: SessionState,
  event: ItemDeltaEvent,
): SessionState {
  const targetIdx = findStreamingMsg(s.messages);
  if (targetIdx < 0) return s;
  const messages = s.messages.slice();
  const msg = { ...messages[targetIdx]! };
  messages[targetIdx] = msg;
  msg.streamingBlocks = msg.streamingBlocks!.map((b) => {
    if (b.itemId !== event.item_id) return b;
    if (event.delta_type === "output_delta") {
      return { ...b, output: (b.output ?? "") + event.content };
    }
    return { ...b, text: b.text + event.content };
  });
  bumpNestedVersion(messages, msg.parentToolUseId);
  return { ...s, messages };
}

export function reduceItemCompleted(
  s: SessionState,
  event: ItemCompletedEvent,
): SessionState {
  const targetIdx = findStreamingMsg(s.messages);
  if (targetIdx < 0) return s;

  const messages = s.messages.slice();
  const msg = { ...messages[targetIdx]! };
  messages[targetIdx] = msg;

  const blockIdx = msg.streamingBlocks!.findIndex(
    (b) => b.itemId === event.item_id,
  );
  if (blockIdx < 0) return s;

  const block = msg.streamingBlocks![blockIdx]!;
  const { creationOrder } = block;

  let contentBlock: import("./protocol").AssistantContentBlock;
  if (block.type === "tool_use") {
    contentBlock = {
      type: "tool_use",
      id: event.item_id,
      name: block.name,
      input: event.input ?? tryParseJson(block.text),
      ...(event._extras ? { _extras: event._extras } : {}),
    };
  } else {
    contentBlock = {
      type: block.type,
      text: event.text ?? block.text,
      ...(event._extras ? { _extras: event._extras } : {}),
    };
  }

  // Tag with creation order so future insertions maintain order
  (contentBlock as Record<string, unknown>)._creationOrder = creationOrder;

  // Find insertion position based on creationOrder
  let insertIdx = msg.content.length;
  for (let i = 0; i < msg.content.length; i++) {
    const existingOrder = (msg.content[i] as Record<string, unknown>)
      ._creationOrder as number | undefined;
    if (existingOrder != null && existingOrder > creationOrder) {
      insertIdx = i;
      break;
    }
  }

  msg.content = [
    ...msg.content.slice(0, insertIdx),
    contentBlock,
    ...msg.content.slice(insertIdx),
  ];

  // Remove from streamingBlocks
  msg.streamingBlocks = msg.streamingBlocks!.filter(
    (b) => b.itemId !== event.item_id,
  );

  bumpNestedVersion(messages, msg.parentToolUseId);
  return { ...s, messages };
}

export function reduceItemResult(
  s: SessionState,
  event: ItemResultEvent,
): SessionState {
  const messages = s.messages.slice();
  let parentMsgIdx = -1;

  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i]!;
    if (m.type !== "assistant") continue;
    if (m.content.some((c) => c.type === "tool_use" && c.id === event.item_id)) {
      parentMsgIdx = i;
      break;
    }
  }

  if (parentMsgIdx < 0) return s;

  const parentMsg = {
    ...messages[parentMsgIdx]!,
    toolResults: new Map(messages[parentMsgIdx]!.toolResults),
  };
  parentMsg.toolResults.set(event.item_id, {
    toolUseId: event.item_id,
    content: event.content as import("./types").ToolResultContent,
    isError: event.is_error,
  });
  messages[parentMsgIdx] = parentMsg;

  bumpNestedVersion(messages, parentMsg.parentToolUseId);

  let state = { ...s, messages };
  state = trackFileEdits(state, [
    {
      tool_use_id: event.item_id,
      content: event.content as import("./types").ToolResultContent,
      is_error: event.is_error,
    },
  ]);
  return state;
}

export function reduceTurnStop(
  s: SessionState,
  event: TurnStopEvent,
): SessionState {
  for (let i = s.messages.length - 1; i >= 0; i--) {
    const m = s.messages[i]!;
    if (m.type === "assistant" && m.streamingBlocks !== undefined) {
      const messages = s.messages.slice();
      const updated = { ...m };
      messages[i] = updated;

      if (event.model) updated.model ??= event.model;
      if (event.usage) updated.usage = event.usage;
      if (event.parent_tool_use_id)
        updated.parentToolUseId ??= event.parent_tool_use_id;
      if (event.is_sidechain) updated.isSidechain = event.is_sidechain;

      // Only clear streamingBlocks if empty — preserves uncompleted items
      if (updated.streamingBlocks!.length === 0) {
        updated.streamingBlocks = undefined;
      }

      if (updated.parentToolUseId) {
        bumpNestedVersion(messages, updated.parentToolUseId);
      }

      return { ...s, messages };
    }
  }
  return s;
}

export function reduceStderr(s: SessionState, text: string): SessionState {
  const id = `stderr-${++s.msgIdCounter}`;
  return {
    ...s,
    messages: [
      ...s.messages,
      {
        id,
        type: "system" as const,
        content: [{ type: "text" as const, text }],
        rawSource: text,
      },
    ],
  };
}

export function reduceExit(s: SessionState): SessionState {
  // Backend owns alive/resumable via tasks_list; nothing to update here.
  return s;
}

// ---------------------------------------------------------------------------
// Top-level dispatcher: routes to individual reducers
// ---------------------------------------------------------------------------

export function reduceMessage(
  s: SessionState,
  msg: AgnosticEvent,
): SessionState {
  switch (msg.type) {
    case "session/init":
      return reduceSystemInit(s, msg);

    case "session/status":
      return reduceSystemStatus(s, msg);

    case "session/compacted":
      return reduceCompactBoundary(s, msg);

    case "task/started":
    case "task/notification":
      return reduceTaskLifecycle(s, msg);

    case "message/assistant":
      return reduceAssistantMessage(s, msg);

    case "message/user": {
      const rawContent = msg.content;
      const contentBlocks: UserContentBlock[] =
        typeof rawContent === "string"
          ? [{ type: "text", text: rawContent }]
          : rawContent;

      // is_replay: dismiss any pending placeholder, then echo normally
      let state = s;
      if (msg.is_replay) {
        state = {
          ...state,
          messages: state.messages.filter(
            (m) => !(m.pending && m.type === "user"),
          ),
        };
      }

      state = reduceUserEcho(
        state,
        contentBlocks,
        msg.is_sidechain,
        msg.parent_tool_use_id,
        msg,
        msg.is_synthetic,
        msg.is_meta,
        msg.is_steering,
      );

      // Draft recovery (safe for live — preReloadDrafts is undefined outside
      // history loading, making this a no-op)
      if (state.preReloadDrafts && state.preReloadDrafts.length > 0) {
        const text = contentBlocks
          .filter((b) => b.type === "text")
          .map((b) => b.text ?? "")
          .join("");
        if (text && state.preReloadDrafts.includes(text)) {
          state = {
            ...state,
            confirmedDuringReplay: [
              ...(state.confirmedDuringReplay ?? []),
              text,
            ],
          };
        }
      }
      return state;
    }

    case "system": {
      const sysMsg = msg as Record<string, unknown>;
      if (sysMsg.subtype === "stop_hook_summary") {
        return reduceStopHookSummary(
          s,
          sysMsg as unknown as Parameters<typeof reduceStopHookSummary>[1],
        );
      }
      if (sysMsg.subtype === "api_error" || sysMsg.subtype === "turn_duration")
        return s;
      return reduceParseError(
        s,
        "Unknown system subtype",
        String(sysMsg.subtype),
        msg,
      );
    }

    case "item/started":
      return reduceItemStarted(s, msg);

    case "item/delta":
      return reduceItemDelta(s, msg);

    case "item/completed":
      return reduceItemCompleted(s, msg);

    case "item/result":
      return reduceItemResult(s, msg);

    case "turn/stop":
      return reduceTurnStop(s, msg);

    case "stream/block_start":
      return reduceStreamBlockStart(s, msg);

    case "stream/block_delta":
      return reduceStreamBlockDelta(s, msg);

    case "stream/block_stop":
      return reduceStreamBlockStop(s, msg);

    case "stream/turn_stop":
      return reduceStreamTurnStop(s);

    case "turn/result":
      return reduceResultMessage(s, msg);

    case "session/summary":
      return reduceSummary(s, msg);

    case "session/rate_limit":
      return s;

    case "control/response": {
      const resp = msg.response;
      const id = `control-response-${++s.msgIdCounter}`;
      return {
        ...s,
        messages: [
          ...s.messages,
          {
            id,
            type: "system" as const,
            content: [
              {
                type: "text" as const,
                text: `Control response: ${resp.subtype}`,
              },
            ],
            rawSource: msg,
            seq: getSeq(msg),
          },
        ],
      };
    }

    case "process/exit":
      return reduceExit(s);

    case "process/stderr":
      return reduceStderr(s, msg.text);

    default:
      return reduceParseError(
        s,
        "Unknown message type",
        (msg as Record<string, unknown>).type as string,
        msg,
      );
  }
}
