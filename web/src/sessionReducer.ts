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
  FileChangePayload,
  FileEditOp,
  FileEditSource,
  FileEditStatus,
} from "./types";
import type {
  AgnosticEvent,
  ResultMessage,
  SystemInitMessage,
  SystemStatusMessage,
  SystemCompactBoundaryMessage,
  SystemTaskStartedMessage,
  SystemTaskNotificationMessage,
  SummaryMessage,
  RateLimitEventMessage,
  ItemStartedEvent,
  ItemDeltaEvent,
  ItemCompletedEvent,
  ItemResultEvent,
  TurnStopEvent,
  TurnDeltaEvent,
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

/** Append `event` to `msg.rawSource` and accumulate its seq into `msg.seq`.
 *  Mutates `msg` in place — callers must already hold a shallow copy. */
function appendRawSource(msg: DisplayMessage, event: unknown): void {
  const prevRaw = msg.rawSource;
  msg.rawSource = prevRaw
    ? Array.isArray(prevRaw)
      ? [...(prevRaw as unknown[]), event]
      : [prevRaw, event]
    : event;

  const newSeq = getSeq(event);
  if (newSeq != null) {
    const prevSeq = msg.seq;
    msg.seq =
      prevSeq != null
        ? Array.isArray(prevSeq)
          ? [...prevSeq, newSeq]
          : [prevSeq, newSeq]
        : newSeq;
  }
}

interface ParsedPatchPath {
  path: string;
  op: "add" | "update" | "delete";
  addedContent?: string;
  patchText?: string;
}

function normalizePath(path: string): string {
  if (path.startsWith("a/") || path.startsWith("b/")) return path.slice(2);
  return path;
}

function toAbsolutePath(path: string, cwd?: string): string {
  if (path.startsWith("/")) return path;
  if (!cwd || cwd.length === 0) return path;
  const base = cwd.endsWith("/") ? cwd.slice(0, -1) : cwd;
  return `${base}/${path}`;
}

function parseDiffHeaderPath(line: string, prefix: string): string | null {
  if (!line.startsWith(prefix)) return null;
  const value = line.slice(prefix.length).trim();
  if (!value || value === "/dev/null") return value;
  return normalizePath(value);
}

function parseApplyPatchPaths(patchText: string): ParsedPatchPath[] {
  const lines = patchText.split("\n");
  const out: ParsedPatchPath[] = [];
  const seen = new Set<string>();
  const pushPath = (
    path: string,
    op: "add" | "update" | "delete",
    addedContent?: string,
    patchText?: string,
  ) => {
    if (!path || path === "/dev/null") return;
    const key = `${op}:${path}`;
    if (seen.has(key)) return;
    seen.add(key);
    out.push({ path, op, addedContent, patchText });
  };

  let lastOld: string | null = null;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;
    if (line.startsWith("*** Add File: ")) {
      const path = line.slice("*** Add File: ".length).trim();
      const contentLines: string[] = [];
      const sectionLines = [line];
      for (let j = i + 1; j < lines.length; j++) {
        const next = lines[j]!;
        if (next.startsWith("*** ")) {
          i = j - 1;
          break;
        }
        sectionLines.push(next);
        if (next.startsWith("+")) contentLines.push(next.slice(1));
        else if (next.startsWith(" ")) contentLines.push(next.slice(1));
        if (j === lines.length - 1) i = j;
      }
      pushPath(path, "add", contentLines.join("\n"), sectionLines.join("\n"));
      continue;
    }
    if (line.startsWith("*** Update File: ")) {
      const path = line.slice("*** Update File: ".length).trim();
      const sectionLines = [line];
      for (let j = i + 1; j < lines.length; j++) {
        const next = lines[j]!;
        if (next.startsWith("*** ")) {
          i = j - 1;
          break;
        }
        sectionLines.push(next);
        if (j === lines.length - 1) i = j;
      }
      pushPath(path, "update", undefined, sectionLines.join("\n"));
      continue;
    }
    if (line.startsWith("*** Delete File: ")) {
      const path = line.slice("*** Delete File: ".length).trim();
      pushPath(path, "delete", undefined, line);
      continue;
    }
    const oldPath = parseDiffHeaderPath(line, "--- ");
    if (oldPath != null) {
      lastOld = oldPath;
      continue;
    }
    const newPath = parseDiffHeaderPath(line, "+++ ");
    if (newPath != null) {
      if (newPath === "/dev/null") {
        if (lastOld && lastOld !== "/dev/null") pushPath(lastOld, "delete");
      } else if (lastOld === "/dev/null") {
        pushPath(newPath, "add");
      } else {
        pushPath(newPath, "update");
      }
    }
  }
  return out;
}

function parsePatchTextFromInput(
  input: Record<string, unknown>,
): string | null {
  const direct = [input.input, input.patchText, input.patch, input.diff];
  for (const candidate of direct) {
    if (typeof candidate === "string" && candidate.trim().length > 0) {
      return candidate;
    }
  }
  return null;
}

interface BuildEditsParams {
  toolUseId: string;
  messageId: string;
  status: FileEditStatus;
  source: FileEditSource;
  cwd?: string;
  turnId?: string;
}

function buildFileEdit(
  params: BuildEditsParams,
  path: string,
  op: FileEditOp,
  payload: FileChangePayload,
  changeIndex: number,
): FileEdit {
  return {
    toolUseId: params.toolUseId,
    messageId: params.messageId,
    filePath: toAbsolutePath(path, params.cwd),
    type: op === "update" || op === "edit" ? "edit" : "write",
    op,
    status: params.status,
    payload,
    source: params.source,
    changeIndex,
    turnId: params.turnId,
  };
}

function buildEditsFromApplyPatchInput(
  input: Record<string, unknown>,
  toolUseId: string,
  messageId: string,
  status: FileEditStatus,
  cwd?: string,
): FileEdit[] {
  const patchText = parsePatchTextFromInput(input);
  if (!patchText) return [];
  const parsedPaths = parseApplyPatchPaths(patchText);
  return parsedPaths.map((p, idx) =>
    buildFileEdit(
      {
        toolUseId,
        messageId,
        status,
        source: "codex-apply_patch-history",
        cwd,
      },
      p.path,
      p.op,
      p.op === "add" && typeof p.addedContent === "string"
        ? { mode: "full_content", content: p.addedContent }
        : p.op === "delete"
          ? { mode: "full_content", content: "" }
          : {
              mode: "patch_text",
              patchText: p.patchText ?? patchText,
            },
      idx,
    ),
  );
}

function buildFileChangeInputFromRawEvent(
  rawEvent: unknown,
  cwd?: string,
): Record<string, unknown> | undefined {
  const parsedRaw =
    typeof rawEvent === "string" ? tryParseJson(rawEvent) : rawEvent;
  if (!parsedRaw || typeof parsedRaw !== "object" || Array.isArray(parsedRaw))
    return undefined;
  const raw = parsedRaw as Record<string, unknown>;
  const params =
    raw.params && typeof raw.params === "object" && !Array.isArray(raw.params)
      ? (raw.params as Record<string, unknown>)
      : null;
  const item =
    params?.item &&
    typeof params.item === "object" &&
    !Array.isArray(params.item)
      ? (params.item as Record<string, unknown>)
      : null;
  if (!item || !Array.isArray(item.changes) || item.changes.length === 0)
    return undefined;

  const changes: Array<Record<string, unknown>> = [];
  for (const ch of item.changes as unknown[]) {
    if (!ch || typeof ch !== "object" || Array.isArray(ch)) continue;
    const change = ch as Record<string, unknown>;
    const path = typeof change.path === "string" ? change.path : null;
    if (!path) continue;
    const kind =
      change.kind &&
      typeof change.kind === "object" &&
      !Array.isArray(change.kind)
        ? (change.kind as Record<string, unknown>)
        : null;
    const op =
      kind?.type === "add" || kind?.type === "update" || kind?.type === "delete"
        ? (kind.type as string)
        : "update";
    changes.push({ file_path: toAbsolutePath(path, cwd), op });
  }
  if (changes.length === 0) return undefined;
  return { file_path: changes[0]!.file_path, changes };
}

function buildEditsFromCodexFileChangeEvent(
  rawEvent: unknown,
  toolUseId: string,
  messageId: string,
  status: FileEditStatus,
  cwd?: string,
): FileEdit[] {
  const parsedRaw =
    typeof rawEvent === "string" ? tryParseJson(rawEvent) : rawEvent;
  if (!parsedRaw || typeof parsedRaw !== "object" || Array.isArray(parsedRaw))
    return [];
  const raw = parsedRaw as Record<string, unknown>;
  const params =
    raw.params && typeof raw.params === "object" && !Array.isArray(raw.params)
      ? (raw.params as Record<string, unknown>)
      : null;
  const item =
    params?.item &&
    typeof params.item === "object" &&
    !Array.isArray(params.item)
      ? (params.item as Record<string, unknown>)
      : null;
  const turnId = typeof params?.turnId === "string" ? params.turnId : undefined;
  if (!item || !Array.isArray(item.changes)) return [];

  const rawChanges = item.changes as unknown[];
  const edits: FileEdit[] = [];
  for (let i = 0; i < rawChanges.length; i++) {
    const ch = rawChanges[i];
    if (!ch || typeof ch !== "object" || Array.isArray(ch)) continue;
    const change = ch as Record<string, unknown>;
    const path = typeof change.path === "string" ? change.path : null;
    if (!path) continue;
    const kind =
      change.kind &&
      typeof change.kind === "object" &&
      !Array.isArray(change.kind)
        ? (change.kind as Record<string, unknown>)
        : null;
    const kindType = kind?.type;
    const op: "add" | "update" | "delete" =
      kindType === "add" || kindType === "update" || kindType === "delete"
        ? kindType
        : "update";
    const payload: FileChangePayload =
      typeof change.diff === "string"
        ? op === "update"
          ? { mode: "patch_text", patchText: change.diff }
          : { mode: "full_content", content: change.diff }
        : { mode: "none" };
    edits.push(
      buildFileEdit(
        {
          toolUseId,
          messageId,
          status,
          source: "codex-fileChange",
          cwd,
          turnId,
        },
        path,
        op,
        payload,
        i,
      ),
    );
  }
  return edits;
}

// ---------------------------------------------------------------------------
// Individual reducers
// ---------------------------------------------------------------------------

export function reduceParseError(
  s: SessionState,
  label: string,
  detail: string,
  raw: unknown,
  rawSource?: unknown,
): SessionState {
  const id = `parse-error-${++s.msgIdCounter}`;
  return {
    ...s,
    messages: [
      ...s.messages,
      {
        id,
        type: "system" as const,
        subtype: "parse_error" as const,
        content: [
          {
            type: "text" as const,
            text: `${label}: ${detail}\n${JSON.stringify(raw, null, 2)}`,
          },
        ],
        rawSource: rawSource ?? raw,
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
    subtype: "init" as const,
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
        subtype: "status" as const,
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
        subtype: "stop_hook_summary" as const,
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
        subtype: "task_lifecycle" as const,
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

/** Lightweight file-edit tracker: records only metadata (toolUseId, messageId,
 *  filePath, type).  Actual file content is resolved on-demand by
 *  resolveEditContent() in FileViewer, avoiding string ops and memory
 *  overhead when the viewer is never opened. */
function appendTrackedEdits(
  state: SessionState,
  edits: FileEdit[],
): SessionState {
  if (edits.length === 0) return state;
  const trackedFiles = new Map(state.trackedFiles);
  for (const edit of edits) {
    const existing = trackedFiles.get(edit.filePath);
    if (existing) {
      trackedFiles.set(edit.filePath, {
        ...existing,
        edits: [...existing.edits, edit],
      });
    } else {
      trackedFiles.set(edit.filePath, {
        path: edit.filePath,
        edits: [edit],
      });
    }
  }
  return { ...state, trackedFiles };
}

function updateEditStatusByToolUseId(
  state: SessionState,
  toolUseId: string,
  status: FileEditStatus,
): SessionState {
  let changed = false;
  const trackedFiles = new Map(state.trackedFiles);
  for (const [path, file] of trackedFiles) {
    const hasChanges = file.edits.some(
      (edit) => edit.toolUseId === toolUseId && edit.status !== status,
    );
    if (!hasChanges) continue;
    changed = true;
    trackedFiles.set(path, {
      ...file,
      edits: file.edits.map((edit) =>
        edit.toolUseId === toolUseId ? { ...edit, status } : edit,
      ),
    });
  }
  return changed ? { ...state, trackedFiles } : state;
}

function hasTrackedEditsForToolUseId(
  state: SessionState,
  toolUseId: string,
): boolean {
  for (const file of state.trackedFiles.values()) {
    if (file.edits.some((edit) => edit.toolUseId === toolUseId)) return true;
  }
  return false;
}

function cancelPendingFileEdits(state: SessionState): SessionState {
  let changed = false;
  const trackedFiles = new Map(state.trackedFiles);
  for (const [path, file] of trackedFiles) {
    const hasPending = file.edits.some((edit) => edit.status === "pending");
    if (!hasPending) continue;
    changed = true;
    trackedFiles.set(path, {
      ...file,
      edits: file.edits.map((edit) =>
        edit.status === "pending"
          ? { ...edit, status: "cancelled" as const }
          : edit,
      ),
    });
  }
  return changed ? { ...state, trackedFiles } : state;
}

function trackResultFileEdits(
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
      if (
        !toolName ||
        (toolName !== "Edit" &&
          toolName !== "Write" &&
          toolName !== "apply_patch")
      )
        break;

      const input = toolUse.input ?? {};
      if (toolName === "apply_patch") {
        if (hasTrackedEditsForToolUseId(state, block.tool_use_id)) break;
        const edits = buildEditsFromApplyPatchInput(
          input,
          block.tool_use_id,
          m.id,
          "applied",
          state.sessionInfo?.cwd,
        );
        state = appendTrackedEdits(state, edits);
        break;
      }

      const filePath =
        typeof input.file_path === "string" ? input.file_path : null;
      if (!filePath) break;

      state = appendTrackedEdits(state, [
        {
          toolUseId: block.tool_use_id,
          messageId: m.id,
          filePath,
          type: toolName === "Edit" ? "edit" : "write",
          op: toolName === "Edit" ? "edit" : "write",
          status: "applied",
          source: "claude-tool",
          payload:
            toolName === "Write" && typeof input.content === "string"
              ? { mode: "full_content", content: input.content }
              : { mode: "none" },
        },
      ]);
      break;
    }
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
  const nextState = {
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
  return msg.is_error ? cancelPendingFileEdits(nextState) : nextState;
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
  const content = event.content ?? [{ type: "text" as const, text }];

  let state = s;

  if (event.is_replay) {
    state = {
      ...state,
      messages: state.messages.filter((m) => !(m.pending && m.type === "user")),
    };
  }

  if (event.pending) {
    const id = `user-echo-${++state.msgIdCounter}`;
    const echoMsg: DisplayMessage = {
      id,
      type: "user" as const,
      content,
      pending: true,
      isSidechain: event.is_sidechain,
      isSynthetic: event.is_synthetic || undefined,
      isMeta: event.is_meta || undefined,
      isSteering: event.is_steering || undefined,
      isCompactSummary: event.isCompactSummary || undefined,
      parentToolUseId: event.parent_tool_use_id,
      extraFields: getExtras(event as Record<string, unknown>),
      rawSource: event,
      seq: getSeq(event),
      uuid: event.uuid,
    };
    const messages = event.is_meta
      ? [...state.messages, echoMsg]
      : insertBeforeStreaming(state.messages, echoMsg);
    bumpNestedVersion(messages, event.parent_tool_use_id);
    return { ...state, messages };
  }

  const hasContent = content.some(
    (b) => (b.type === "text" && b.text.trim().length > 0) || b.type !== "text",
  );
  if (hasContent) {
    const id = `user-echo-${++state.msgIdCounter}`;
    const echoMsg: DisplayMessage = {
      id,
      type: "user" as const,
      content,
      isSidechain: event.is_sidechain,
      isSynthetic: event.is_synthetic || undefined,
      isMeta: event.is_meta || undefined,
      isSteering: event.is_steering || undefined,
      isCompactSummary: event.isCompactSummary || undefined,
      parentToolUseId: event.parent_tool_use_id,
      extraFields: getExtras(event as Record<string, unknown>),
      rawSource: event,
      seq: getSeq(event),
      uuid: event.uuid,
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

  // Draft recovery
  if (state.preReloadDrafts && state.preReloadDrafts.length > 0 && text) {
    if (state.preReloadDrafts.includes(text)) {
      state = {
        ...state,
        confirmedDuringReplay: [...(state.confirmedDuringReplay ?? []), text],
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
      itemId: event.item_id,
      type: event.item_type,
      text: event.text ?? "",
      name: event.name,
      input:
        event.item_type === "tool_use" && event.name === "fileChange"
          ? (event.input ??
            buildFileChangeInputFromRawEvent(
              (event as Record<string, unknown>)._raw,
              s.sessionInfo?.cwd,
            ))
          : event.input,
      creationOrder,
    },
  ];

  if (event.parent_tool_use_id) {
    msg.parentToolUseId = event.parent_tool_use_id;
    bumpNestedVersion(messages, event.parent_tool_use_id);
  }

  appendRawSource(msg, event);

  let state = { ...s, messages };

  if (event.item_type === "tool_use") {
    if (event.name === "fileChange") {
      // _raw is stripped before broadcast; fall back to event.input (set by backend
      // for live events) wrapped in the shape buildEditsFromCodexFileChangeEvent expects.
      const rawForEdits =
        (event as Record<string, unknown>)._raw ??
        (event.input != null ? { params: { item: event.input } } : undefined);
      const edits = buildEditsFromCodexFileChangeEvent(
        rawForEdits,
        event.item_id,
        msg.id,
        "pending",
        state.sessionInfo?.cwd,
      );
      state = appendTrackedEdits(state, edits);
    } else if (event.name === "apply_patch") {
      const edits = buildEditsFromApplyPatchInput(
        (msg.streamingBlocks[msg.streamingBlocks.length - 1]!.input ??
          {}) as Record<string, unknown>,
        event.item_id,
        msg.id,
        "pending",
        state.sessionInfo?.cwd,
      );
      state = appendTrackedEdits(state, edits);
    }
  }

  return state;
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
    if (event.delta_type === "stdin_delta") {
      return { ...b, stdin: (b.stdin ?? "") + event.content };
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
  if (targetIdx < 0) {
    return updateEditStatusByToolUseId(
      s,
      event.item_id,
      event.is_error ? "cancelled" : "applied",
    );
  }

  const messages = s.messages.slice();
  const msg = { ...messages[targetIdx]! };
  messages[targetIdx] = msg;

  const blockIdx = msg.streamingBlocks!.findIndex(
    (b) => b.itemId === event.item_id,
  );
  if (blockIdx < 0) {
    return updateEditStatusByToolUseId(
      s,
      event.item_id,
      event.is_error ? "cancelled" : "applied",
    );
  }

  const block = msg.streamingBlocks![blockIdx]!;
  const { creationOrder } = block;

  let contentBlock: import("./protocol").AssistantContentBlock;
  if (block.type === "tool_use") {
    contentBlock = {
      type: "tool_use",
      id: event.item_id,
      name: block.name,
      // event.input is only set via rollout path; live path carries the
      // initial input in block.input (from item/started).
      input:
        event.input ??
        (block.input as Record<string, unknown> | undefined) ??
        tryParseJson(block.text),
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

  appendRawSource(msg, event);

  bumpNestedVersion(messages, msg.parentToolUseId);
  let state = { ...s, messages };
  if (block.type === "tool_use") {
    state = updateEditStatusByToolUseId(
      state,
      event.item_id,
      event.is_error ? "cancelled" : "applied",
    );
  }
  return state;
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
    if (
      m.content.some((c) => c.type === "tool_use" && c.id === event.item_id)
    ) {
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
    toolResult: event.tool_result,
  });
  appendRawSource(parentMsg, event);
  messages[parentMsgIdx] = parentMsg;

  bumpNestedVersion(messages, parentMsg.parentToolUseId);

  let state = { ...s, messages };
  state = trackResultFileEdits(state, [
    {
      tool_use_id: event.item_id,
      content: event.content as import("./types").ToolResultContent,
      is_error: event.is_error,
    },
  ]);
  return state;
}

export function reduceTurnDelta(
  s: SessionState,
  event: TurnDeltaEvent,
): SessionState {
  for (let i = s.messages.length - 1; i >= 0; i--) {
    const m = s.messages[i]!;
    if (m.type === "assistant" && m.streamingBlocks !== undefined) {
      const messages = s.messages.slice();
      const updated = { ...m };
      messages[i] = updated;

      // Apply turn-level metadata eagerly.
      if (event.model) updated.model ??= event.model;
      if (event.usage) updated.usage = event.usage;
      if (event.parent_tool_use_id)
        updated.parentToolUseId ??= event.parent_tool_use_id;
      if (event.is_sidechain) updated.isSidechain = event.is_sidechain;
      if (event._extras) updated.extraFields = event._extras;
      if (event.uuid) updated.uuid = event.uuid;

      // Attach to rawSource for "View source" → "Raw".
      appendRawSource(updated, event);

      if (updated.parentToolUseId) {
        bumpNestedVersion(messages, updated.parentToolUseId);
      }

      return { ...s, messages };
    }
  }
  return s;
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

      // Apply metadata if present (history path where no turn/delta preceded).
      // ??= guards prevent overwriting values already set by turn/delta.
      if (event.model) updated.model ??= event.model;
      if (event.usage) updated.usage ??= event.usage;
      if (event.parent_tool_use_id)
        updated.parentToolUseId ??= event.parent_tool_use_id;
      if (event.is_sidechain) updated.isSidechain ??= event.is_sidechain;
      if (event._extras) updated.extraFields ??= event._extras;
      if (event.uuid) updated.uuid ??= event.uuid;

      // Always append to rawSource — every raw Claude Code event that
      // contributes to the message should be visible via "View source" → "Raw".
      appendRawSource(updated, event);

      // Promote any remaining streaming blocks to content (safety net —
      // prevents orphaned blocks from persisting past the turn boundary).
      if (updated.streamingBlocks!.length > 0) {
        for (const block of updated.streamingBlocks!) {
          let contentBlock: import("./protocol").AssistantContentBlock;
          if (block.type === "tool_use") {
            contentBlock = {
              type: "tool_use",
              id: block.itemId,
              name: block.name,
              input:
                (block.input as Record<string, unknown> | undefined) ??
                tryParseJson(block.text),
            };
          } else {
            contentBlock = { type: block.type, text: block.text };
          }
          (contentBlock as Record<string, unknown>)._creationOrder =
            block.creationOrder;
          let insertIdx = updated.content.length;
          for (let j = 0; j < updated.content.length; j++) {
            const o = (updated.content[j] as Record<string, unknown>)
              ._creationOrder as number | undefined;
            if (o != null && o > block.creationOrder) {
              insertIdx = j;
              break;
            }
          }
          updated.content = [
            ...updated.content.slice(0, insertIdx),
            contentBlock,
            ...updated.content.slice(insertIdx),
          ];
        }
      }
      updated.streamingBlocks = undefined;

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
        subtype: "stderr" as const,
        content: [{ type: "text" as const, text }],
        rawSource: text,
      },
    ],
  };
}

export function reduceExit(s: SessionState): SessionState {
  // Backend owns alive/resumable via tasks_list; nothing to update here.
  return cancelPendingFileEdits(s);
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

    case "turn/delta":
      return reduceTurnDelta(s, msg);

    case "turn/stop":
      return reduceTurnStop(s, msg);

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
            subtype: "control_response" as const,
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

    case "agent/unrecognized": {
      // If mid-turn, embed in the streaming message to preserve temporal order.
      const streamIdx = findStreamingMsg(s.messages);
      if (streamIdx >= 0) {
        const messages = s.messages.slice();
        const updated = { ...messages[streamIdx]! };
        messages[streamIdx] = updated;
        const creationOrder = updated.nextCreationOrder ?? 0;
        updated.nextCreationOrder = creationOrder + 1;
        updated.streamingBlocks = [
          ...(updated.streamingBlocks || []),
          {
            itemId: `unrecognized-${++s.msgIdCounter}`,
            type: "unrecognized",
            text: `${msg.reason}\n${JSON.stringify(msg.raw_content, null, 2)}`,
            creationOrder,
          },
        ];
        appendRawSource(updated, msg);
        return { ...s, messages };
      }
      // No streaming message — top-level system message.
      return reduceParseError(
        s,
        "Unrecognized agent data",
        msg.reason,
        msg.raw_content,
        msg,
      );
    }

    default:
      return reduceParseError(
        s,
        "Unknown message type",
        (msg as Record<string, unknown>).type as string,
        msg,
        msg,
      );
  }
}
