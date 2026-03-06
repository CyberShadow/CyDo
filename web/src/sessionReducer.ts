// Pure session state reducers — no React dependency.
//
// Each function takes a SessionState and returns a new SessionState.
// Convention: functions pre-increment s.msgIdCounter in place before spreading
// into the return value. This is safe because the caller always replaces the
// old state with the returned state (the old reference is never reused).

import type { SessionState, DisplayMessage, ToolResultContent } from "./types";
import type {
  ClaudeMessage,
  ClaudeFileMessage,
  AssistantMessage,
  AssistantFileMessage,
  StreamEvent,
  ResultMessage,
} from "./schemas";
import type { ExtraField } from "./extractExtras";
import { schemaForStdout, schemaForFile, validateWith } from "./validate";

// ---------------------------------------------------------------------------
// Individual reducers
// ---------------------------------------------------------------------------

export function reduceParseError(
  s: SessionState,
  source: "stdout" | "file",
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
            text: `${label} (${source}): ${detail}\n${JSON.stringify(raw, null, 2)}`,
          },
        ],
        rawSource: raw,
      },
    ],
  };
}

export function reduceSystemInit(
  s: SessionState,
  msg: any,
  extras: ExtraField[] | undefined,
): SessionState {
  const initMsg: DisplayMessage | undefined = extras
    ? {
        id: `init-${++s.msgIdCounter}`,
        type: "system" as const,
        content: [],
        extraFields: extras,
        rawSource: msg,
      }
    : undefined;
  return {
    ...s,
    sessionInfo: {
      model: msg.model,
      version: msg.claude_code_version,
      sessionId: msg.session_id,
      cwd: msg.cwd,
      tools: msg.tools,
      permissionMode: msg.permissionMode,
      mcp_servers: msg.mcp_servers,
      agents: msg.agents,
      apiKeySource: msg.apiKeySource,
      skills: msg.skills,
      plugins: msg.plugins,
      fast_mode_state: msg.fast_mode_state,
    },
    isProcessing: true,
    messages: initMsg ? [...s.messages, initMsg] : s.messages,
  };
}

export function reduceSystemStatus(
  s: SessionState,
  msg: any,
  extras: ExtraField[] | undefined,
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
        extraFields: extras,
        rawSource: msg,
      },
    ],
  };
}

export function reduceCompactBoundary(
  s: SessionState,
  msg: any,
  extras: ExtraField[] | undefined,
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
        extraFields: extras,
        rawSource: msg,
      },
    ],
  };
}

export function reduceTaskLifecycle(
  s: SessionState,
  msg: any,
  extras: ExtraField[] | undefined,
): SessionState {
  const id = `task-${++s.msgIdCounter}`;
  let text: string;
  if (msg.subtype === "task_started") {
    text = `Task started: ${msg.description || msg.task_id}`;
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
        extraFields: extras,
        rawSource: msg,
      },
    ],
  };
}

export function reduceSummary(
  s: SessionState,
  msg: any,
  extras: ExtraField[] | undefined,
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
        extraFields: extras,
        rawSource: msg,
      },
    ],
  };
}

export function reduceRateLimit(
  s: SessionState,
  msg: any,
  extras: ExtraField[] | undefined,
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
        extraFields: extras,
        rawSource: msg,
      },
    ],
  };
}

export function reduceAssistantMessage(
  s: SessionState,
  msg: AssistantMessage | AssistantFileMessage,
  extras: ExtraField[] | undefined,
): SessionState {
  const msgId = msg.message.id;
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
      const m = s.messages[i];
      if (m.type === "assistant" && m.id.startsWith("streaming-")) {
        idx = i;
        break;
      }
    }
  }

  if (idx >= 0) {
    const updated = [...s.messages];
    const existingMsg = { ...updated[idx] };
    // Replace temp ID with real one when adopting a streaming placeholder
    if (existingMsg.id !== msgId) existingMsg.id = msgId;
    existingMsg.content = [...existingMsg.content, ...msg.message.content];
    // Only keep streamingBlocks active if it was a streaming placeholder;
    // during JSONL replay there's no streaming so leave it undefined.
    if (existingMsg.streamingBlocks !== undefined) {
      existingMsg.streamingBlocks = [];
    }
    // Update usage if present (later messages may have updated counts)
    if (msg.message.usage) {
      existingMsg.usage = msg.message.usage;
    }
    // Set fields that may not have been on the placeholder
    existingMsg.model ??= msg.message.model;
    existingMsg.isSidechain ??= msg.isSidechain;
    existingMsg.parentToolUseId ??= msg.parent_tool_use_id;
    // Accumulate raw sources
    const prev = existingMsg.rawSource;
    existingMsg.rawSource = prev
      ? Array.isArray(prev)
        ? [...prev, msg]
        : [prev, msg]
      : msg;
    // Merge extra fields (deduplicate by path+key)
    if (extras) {
      const prev = existingMsg.extraFields || [];
      const seen = new Set(prev.map((e) => `${e.path}\0${e.key}`));
      const novel = extras.filter((e) => !seen.has(`${e.path}\0${e.key}`));
      existingMsg.extraFields = novel.length > 0 ? [...prev, ...novel] : prev;
    }
    updated[idx] = existingMsg;
    return { ...s, messages: updated };
  }
  return {
    ...s,
    messages: [
      ...s.messages,
      {
        id: msgId,
        type: "assistant" as const,
        content: [...msg.message.content],
        toolResults: new Map(),
        model: msg.message.model,
        isSidechain: msg.isSidechain,
        parentToolUseId: msg.parent_tool_use_id,
        usage: msg.message.usage,
        extraFields: extras,
        rawSource: msg,
      },
    ],
  };
}

// Applies both tool-result linking and user-text echo in a single pass.
export function reduceUserEcho(
  s: SessionState,
  content: any[],
  isSidechain: boolean | undefined,
  parentToolUseId: string | null | undefined,
  extras: ExtraField[] | undefined,
  rawMsg: unknown,
  isSynthetic?: boolean,
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
      toolResults.push(block);
    } else if (block.type === "text") {
      textBlocks.push(block.text);
    }
  }

  let state = s;

  // Link tool results to their parent assistant messages
  if (toolResults.length > 0) {
    const updated = [...state.messages];
    const touchedIndices = new Set<number>();
    for (const block of toolResults) {
      for (let i = updated.length - 1; i >= 0; i--) {
        const m = updated[i];
        if (m.type === "assistant") {
          const hasToolUse = m.content.some(
            (c) => c.type === "tool_use" && (c as any).id === block.tool_use_id,
          );
          if (hasToolUse) {
            const newMsg = { ...m, toolResults: new Map(m.toolResults) };
            newMsg.toolResults!.set(block.tool_use_id, {
              toolUseId: block.tool_use_id,
              content: block.content,
              isError: block.is_error,
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
    // the complete round-trip.
    for (const i of touchedIndices) {
      const msg = updated[i];
      const prev = msg.rawSource;
      msg.rawSource = prev
        ? Array.isArray(prev)
          ? [...prev, rawMsg]
          : [prev, rawMsg]
        : rawMsg;
    }
    state = { ...state, messages: updated };
  }

  // If there are text blocks (actual user text, not just tool results), show as user message
  const meaningfulText = textBlocks.filter((t) => t.trim().length > 0);
  if (meaningfulText.length > 0 && toolResults.length === 0) {
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
      parentToolUseId,
      extraFields: extras,
      rawSource: rawMsg,
    };
    // Remove the pending placeholder, then insert the echo before any
    // in-progress streaming message so user text always precedes the
    // assistant's response.
    const filtered = state.messages.filter(
      (m) => !(m.pending && m.type === "user"),
    );
    state = {
      ...state,
      messages: insertBeforeStreaming(filtered, echoMsg),
    };
  }

  return state;
}

export function reduceUserReplay(
  s: SessionState,
  contentBlocks: any[],
  rawMsg: unknown,
): SessionState {
  const text = contentBlocks
    .filter((b: any) => b.type === "text")
    .map((b: any) => b.text)
    .join("");
  const id = `user-${++s.msgIdCounter}`;
  const echoMsg: DisplayMessage = {
    id,
    type: "user" as const,
    content: [{ type: "text" as const, text }],
    rawSource: rawMsg,
  };
  // Remove the pending placeholder, then insert the echo before any
  // in-progress streaming message so user text always precedes the
  // assistant's response.
  const filtered = s.messages.filter((m) => !(m.pending && m.type === "user"));
  return {
    ...s,
    messages: insertBeforeStreaming(filtered, echoMsg),
  };
}

export function reduceResultMessage(
  s: SessionState,
  msg: ResultMessage,
  extras: ExtraField[] | undefined,
): SessionState {
  const id = `result-${++s.msgIdCounter}`;
  return {
    ...s,
    totalCost: msg.total_cost_usd || s.totalCost,
    isProcessing: false,
    messages: [
      ...s.messages,
      {
        id,
        type: "result" as const,
        content: [],
        extraFields: extras,
        rawSource: msg,
        resultData: {
          subtype: msg.subtype,
          isError: msg.is_error,
          result: msg.result,
          numTurns: msg.num_turns,
          durationMs: msg.duration_ms,
          durationApiMs: msg.duration_api_ms,
          totalCostUsd: msg.total_cost_usd,
          usage: msg.usage,
          modelUsage: msg.modelUsage,
          permissionDenials: msg.permission_denials,
          stopReason: msg.stop_reason,
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
      messages[i].type === "assistant" &&
      messages[i].streamingBlocks !== undefined
    ) {
      const result = [...messages];
      result.splice(i, 0, msg);
      return result;
    }
  }
  return [...messages, msg];
}

/** Find the last assistant message with active streaming blocks. */
function findStreamingMsg(messages: DisplayMessage[]): number {
  for (let i = messages.length - 1; i >= 0; i--) {
    if (messages[i].streamingBlocks?.length) return i;
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
    if (messages[i].type === "assistant" && messages[i].streamingBlocks) {
      messages[i] = { ...messages[i] };
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
  };
  messages.push(placeholder);
  return { messages, msgIdx: messages.length - 1 };
}

export function reduceStreamEvent(
  s: SessionState,
  event: StreamEvent,
): SessionState {
  switch (event.type) {
    case "content_block_start": {
      const { messages, msgIdx } = getStreamingMessage(s);
      const msg = messages[msgIdx];
      msg.streamingBlocks = [
        ...(msg.streamingBlocks || []),
        {
          index: event.index,
          type: event.content_block.type,
          text: "",
          name: (event.content_block as Record<string, unknown>).name as
            | string
            | undefined,
        },
      ];
      return { ...s, messages };
    }
    case "content_block_delta": {
      const targetIdx = findStreamingMsg(s.messages);
      if (targetIdx < 0) return s;
      const messages = s.messages.slice();
      const msg = { ...messages[targetIdx] };
      messages[targetIdx] = msg;
      msg.streamingBlocks = msg.streamingBlocks!.map((b) => {
        if (b.index !== event.index) return b;
        const delta = event.delta;
        let append = "";
        if (delta.type === "text_delta") append = delta.text;
        else if (delta.type === "thinking_delta") append = delta.thinking;
        else if (delta.type === "input_json_delta") append = delta.partial_json;
        return { ...b, text: b.text + append };
      });
      return { ...s, messages };
    }
    case "content_block_stop": {
      const targetIdx = findStreamingMsg(s.messages);
      if (targetIdx < 0) return s;
      const messages = s.messages.slice();
      const msg = { ...messages[targetIdx] };
      messages[targetIdx] = msg;
      msg.streamingBlocks = msg.streamingBlocks!.filter(
        (b) => b.index !== event.index,
      );
      return { ...s, messages };
    }
    case "message_stop": {
      // Mark the assistant message as no longer streaming so the next
      // response creates a fresh message instead of reusing this one.
      // Must match getStreamingMessage's check (truthy streamingBlocks),
      // not findStreamingMsg (which requires length > 0), because
      // reduceAssistantMessage may have already set streamingBlocks = [].
      for (let i = s.messages.length - 1; i >= 0; i--) {
        if (
          s.messages[i].type === "assistant" &&
          s.messages[i].streamingBlocks
        ) {
          const messages = s.messages.slice();
          messages[i] = { ...messages[i], streamingBlocks: undefined };
          return { ...s, messages };
        }
      }
      return s;
    }
    default:
      return s;
  }
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
  return {
    ...s,
    isProcessing: false,
    alive: false,
    resumable: s.sessionInfo !== null,
  };
}

export function reducePendingUserMessage(
  s: SessionState,
  text: string,
): SessionState {
  const id = `pending-${++s.msgIdCounter}`;
  return {
    ...s,
    messages: [
      ...s.messages,
      {
        id,
        type: "user" as const,
        content: [{ type: "text" as const, text }],
        pending: true,
      },
    ],
  };
}

// ---------------------------------------------------------------------------
// Top-level dispatchers: validate + route to individual reducers
// ---------------------------------------------------------------------------

export function reduceStdoutMessage(
  s: SessionState,
  msg: ClaudeMessage,
): SessionState {
  const { extras, schemaError } = validateWith(schemaForStdout, msg);
  if (schemaError) {
    s = reduceParseError(
      s,
      "stdout",
      "Schema validation failed",
      schemaError,
      msg,
    );
  }

  switch (msg.type) {
    case "system":
      if ("subtype" in msg && msg.subtype === "init") {
        return reduceSystemInit(s, msg, extras);
      } else if ("subtype" in msg && msg.subtype === "status") {
        return reduceSystemStatus(s, msg, extras);
      } else if ("subtype" in msg && msg.subtype === "compact_boundary") {
        return reduceCompactBoundary(s, msg, extras);
      } else if (
        "subtype" in msg &&
        (msg.subtype === "task_started" || msg.subtype === "task_notification")
      ) {
        return reduceTaskLifecycle(s, msg as any, extras);
      } else {
        return reduceParseError(
          s,
          "stdout",
          "Unknown system subtype",
          String((msg as any).subtype),
          msg,
        );
      }

    case "assistant":
      return reduceAssistantMessage(s, msg as AssistantMessage, extras);

    case "user": {
      const rawContent = msg.message.content;
      const contentBlocks: any[] =
        typeof rawContent === "string"
          ? [{ type: "text", text: rawContent }]
          : rawContent;

      if ("isReplay" in msg && (msg as any).isReplay) {
        return reduceUserReplay(s, contentBlocks, msg);
      } else {
        return reduceUserEcho(
          s,
          contentBlocks,
          msg.isSidechain,
          msg.parent_tool_use_id,
          extras,
          msg,
          (msg as any).isSynthetic,
        );
      }
    }

    case "stream_event":
      return reduceStreamEvent(s, (msg as any).event);

    case "result":
      return reduceResultMessage(s, msg as ResultMessage, extras);

    case "summary":
      return reduceSummary(s, msg, extras);

    case "rate_limit_event":
      // Global event, not session-scoped; will be handled by the backend in the future.
      return s;

    case "exit":
      return reduceExit(s);

    case "stderr":
      return reduceStderr(s, msg.text);

    default:
      return reduceParseError(
        s,
        "stdout",
        "Unknown message type",
        (msg as any).type,
        msg,
      );
  }
}

export function reduceFileMessage(
  s: SessionState,
  msg: ClaudeFileMessage,
): SessionState {
  const { extras, schemaError } = validateWith(schemaForFile, msg);
  if (schemaError) {
    s = reduceParseError(
      s,
      "file",
      "Schema validation failed",
      schemaError,
      msg,
    );
  }

  switch (msg.type) {
    case "system":
      if ("subtype" in msg && msg.subtype === "init") {
        return reduceSystemInit(s, msg, extras);
      } else if ("subtype" in msg && msg.subtype === "status") {
        return reduceSystemStatus(s, msg, extras);
      } else if ("subtype" in msg && msg.subtype === "compact_boundary") {
        return reduceCompactBoundary(s, msg, extras);
      } else if (
        "subtype" in msg &&
        (msg.subtype === "task_started" || msg.subtype === "task_notification")
      ) {
        return reduceTaskLifecycle(s, msg as any, extras);
      } else if (
        "subtype" in msg &&
        (msg.subtype === "api_error" || msg.subtype === "turn_duration")
      ) {
        // JSONL-only bookkeeping subtypes — intentionally not rendered.
        // api_error: transient retry attempts already resolved by the time we see them.
        // turn_duration: internal timing metadata with no user-facing value.
        return s;
      } else {
        return reduceParseError(
          s,
          "file",
          "Unknown system subtype",
          String((msg as any).subtype),
          msg,
        );
      }

    case "assistant":
      return reduceAssistantMessage(s, msg as AssistantFileMessage, extras);

    case "user": {
      // JSONL user messages store content as a plain string; normalize to block array
      const rawContent = (msg as any).message?.content;
      const content: any[] =
        typeof rawContent === "string"
          ? [{ type: "text", text: rawContent }]
          : (rawContent ?? []);
      s = reduceUserEcho(
        s,
        content,
        msg.isSidechain,
        msg.parent_tool_use_id,
        extras,
        msg,
        (msg as any).isSynthetic,
      );
      // Remove matched user text from preReloadDrafts
      if (s.preReloadDrafts && s.preReloadDrafts.length > 0) {
        const text = content
          .filter((b: any) => b.type === "text")
          .map((b: any) => b.text ?? "")
          .join("");
        if (text) {
          const idx = s.preReloadDrafts.indexOf(text);
          if (idx !== -1) {
            const drafts = [...s.preReloadDrafts];
            drafts.splice(idx, 1);
            s = {
              ...s,
              preReloadDrafts: drafts.length > 0 ? drafts : undefined,
            };
          }
        }
      }
      return s;
    }

    case "result":
      return reduceResultMessage(s, msg as ResultMessage, extras);

    case "summary":
      return reduceSummary(s, msg, extras);

    case "rate_limit_event":
      // Global event, not session-scoped; will be handled by the backend in the future.
      return s;

    // JSONL-only types — intentionally not rendered:
    // progress: transient hook/bash/agent execution trace, already resolved.
    // queue-operation: internal enqueue/dequeue bookkeeping.
    // file-history-snapshot: file state snapshots for undo, no user-facing value.
    case "progress":
    case "queue-operation":
    case "file-history-snapshot":
      return s;

    default:
      return reduceParseError(
        s,
        "file",
        "Unknown message type",
        (msg as any).type,
        msg,
      );
  }
}
