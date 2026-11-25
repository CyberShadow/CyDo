// Pure task state reducers — no React dependency.
//
// Mutate only values owned by the current write batch, acquiring the parent
// before replacing a child. Acquire ownership at the point of writing.

import type {
  TaskState as SessionState,
  DisplayMessage,
  ToolResultContent,
  FileEdit,
  FileChangePayload,
  FileEditOp,
  FileEditSource,
  FileEditStatus,
  Block,
  CydoMeta,
  ItemEnrichment,
} from "./types";
import type { HistoryBoundary } from "./types";
import { itemBlockKey } from "./types";
import { WriteBatch } from "./writeBatch";
import { toolIs } from "./toolIdentity";
import { normalizeFilePath } from "./lib/localFileLinks";
import type {
  AgnosticEvent,
  AssistantContentBlock,
  ResultMessage,
  SystemInitMessage,
  SystemMetadataMessage,
  SystemStatusMessage,
  SystemCompactBoundaryMessage,
  SystemTaskStartedMessage,
  TaskUpdatedEvent,
  SystemTaskNotificationMessage,
  SummaryMessage,
  RateLimitEventMessage,
  ItemStartedEvent,
  ItemDeltaEvent,
  ItemAbandonedEvent,
  ItemCompletedEvent,
  ItemResultEvent,
  ItemDeniedEvent,
  ItemPermissionEvent,
  TurnStopEvent,
  TurnDeltaEvent,
  UserMessageConsumedEvent,
  StderrMessage,
  CydoItemEnrichedEvent,
} from "./protocol";
import {
  fileEditPayloadFromNormalizedChange,
  getApplyPatchFileChanges,
  getBashEditDiff,
  getBashEditDiffFileChanges,
  parseCodexFileChanges,
  toFileEditOperation,
} from "./lib/fileChanges";
import {
  canonicalUserTextFromContentAndMeta,
  canonicalUserTextFromDisplayMessage,
} from "./userText";

function getExtras(msg: {
  extras?: Record<string, unknown>;
}): Record<string, unknown> | undefined {
  const extras = msg.extras;
  if (
    extras &&
    typeof extras === "object" &&
    !Array.isArray(extras) &&
    Object.keys(extras).length > 0
  ) {
    return extras;
  }
  return undefined;
}

/** Append `event` to `msg.rawSource` and accumulate its seq into `msg.seq`.
 *  Mutates `msg` in place — callers must already own the message. */
function appendRawSource(
  b: WriteBatch,
  msg: DisplayMessage,
  event: unknown,
  seq?: number,
): void {
  const prevRaw = msg.rawSource;
  if (Array.isArray(prevRaw)) {
    const raw = b.array(prevRaw);
    msg.rawSource = raw;
    raw.push(event);
  } else {
    msg.rawSource = prevRaw ? b.adopt([prevRaw, event]) : event;
  }

  if (seq != null) {
    const prevSeq = msg.seq;
    if (Array.isArray(prevSeq)) {
      msg.seq = b.array(prevSeq);
      msg.seq.push(seq);
    } else {
      msg.seq = prevSeq != null ? b.adopt([prevSeq, seq]) : seq;
    }
  }
}

interface BuildEditsParams {
  toolUseId: string;
  messageId: string;
  status: FileEditStatus;
  source: FileEditSource;
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
    filePath: path,
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
): FileEdit[] {
  const changes = getApplyPatchFileChanges(input);
  const edits: FileEdit[] = [];
  for (let i = 0; i < changes.length; i++) {
    const change = changes[i]!;
    const path = change.path;
    if (!path) continue;
    const op = toFileEditOperation(change.op) ?? "update";
    edits.push(
      buildFileEdit(
        {
          toolUseId,
          messageId,
          status,
          source: "codex-apply_patch-history",
        },
        path,
        op,
        fileEditPayloadFromNormalizedChange(change),
        i,
      ),
    );
  }
  return edits;
}

function buildEditsFromCodexFileChangeEvent(
  rawEvent: unknown,
  toolUseId: string,
  messageId: string,
  status: FileEditStatus,
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

  const { changes } = parseCodexFileChanges({ changes: item.changes });
  const edits: FileEdit[] = [];
  for (let i = 0; i < changes.length; i++) {
    const change = changes[i]!;
    const path = change.path;
    if (!path) continue;
    const op = toFileEditOperation(change.op) ?? "update";
    edits.push(
      buildFileEdit(
        {
          toolUseId,
          messageId,
          status,
          source: "codex-fileChange",
          turnId,
        },
        path,
        op,
        fileEditPayloadFromNormalizedChange(change),
        i,
      ),
    );
  }
  return edits;
}

// ---------------------------------------------------------------------------
// Individual reducers
// ---------------------------------------------------------------------------

function reduceParseError(
  b: WriteBatch,
  s: SessionState,
  label: string,
  detail: string,
  rawSource: unknown,
  dumpSource: boolean = true,
  seq?: number,
): SessionState {
  const t = b.object(s);
  const id = `parse-error-${++t.msgIdCounter}`;
  t.messages = b.array(t.messages);
  t.messages.push(
    b.adopt<DisplayMessage>({
      id,
      type: "system" as const,
      subtype: "parse_error" as const,
      content: [
        {
          type: "text" as const,
          text: dumpSource
            ? `${label}: ${detail}\n${JSON.stringify(rawSource, null, 2)}`
            : `${label}: ${detail}`,
        },
      ],
      rawSource,
      seq,
    }),
  );
  return t;
}

function reduceSessionInitBootstrap(
  b: WriteBatch,
  s: SessionState,
  msg: SystemInitMessage,
): SessionState {
  const t = b.object(s);
  // Preserve the configured agent key separately from the runtime driver so
  // pre-task_updated blocks still get the correct driver identity.
  t.driver = msg.agent ?? t.driver;
  t.agentName = msg.agent_name ?? t.agentName;
  t.sessionInfo = b.adopt({
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
    agent_name: msg.agent_name,
    supports_file_revert: msg.supports_file_revert,
  });
  t.sessionStatus = null;
  return t;
}

function reduceSessionMetadata(
  b: WriteBatch,
  s: SessionState,
  msg: SystemMetadataMessage,
  seq?: number,
): SessionState {
  if (!s.sessionInfo) {
    throw new Error("session/metadata received before session/init");
  }
  const t = b.object(s);
  const metadataMsg = b.adopt<DisplayMessage>({
    id: `metadata-${++t.msgIdCounter}`,
    type: "system" as const,
    subtype: "metadata" as const,
    content: [],
    rawSource: msg,
    seq,
  });
  t.sessionInfo = b.object(s.sessionInfo);
  t.sessionInfo.model = msg.model;
  t.messages = b.array(t.messages);
  t.messages.push(metadataMsg);
  return t;
}

function reduceSystemInit(
  b: WriteBatch,
  s: SessionState,
  msg: SystemInitMessage,
  seq?: number,
): SessionState {
  const t = reduceSessionInitBootstrap(b, s, msg);
  const initMsg = b.adopt<DisplayMessage>({
    id: `init-${++t.msgIdCounter}`,
    type: "system" as const,
    subtype: "init" as const,
    content: [],
    rawSource: msg,
    seq,
  });
  t.messages = b.array(t.messages);
  t.messages.push(initMsg);
  return t;
}

function reduceSystemStatus(
  b: WriteBatch,
  s: SessionState,
  msg: SystemStatusMessage,
  seq?: number,
): SessionState {
  void seq;
  const status =
    typeof msg.status === "string" && msg.status.trim().length > 0
      ? msg.status
      : null;
  const permission = msg.permission_mode;
  if (
    permission &&
    s.sessionInfo &&
    permission !== s.sessionInfo.permission_mode
  ) {
    const t = b.object(s);
    t.sessionInfo = b.object(s.sessionInfo);
    t.sessionInfo.permission_mode = permission;
    t.sessionStatus = status;
    return t;
  }
  if (s.sessionStatus === status) return s;
  const t = b.object(s);
  t.sessionStatus = status;
  return t;
}

function reduceStopHookSummary(
  b: WriteBatch,
  s: SessionState,
  msg: {
    hookCount: number;
    hookInfos: Array<{ command: string; durationMs: number }>;
    hookErrors: Array<unknown>;
    preventedContinuation: boolean;
    hasOutput: boolean;
    [key: string]: unknown;
  },
  seq?: number,
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

  const t = b.object(s);
  const id = `stop-hook-${++t.msgIdCounter}`;
  t.messages = b.array(t.messages);
  t.messages.push(
    b.adopt<DisplayMessage>({
      id,
      type: "system" as const,
      subtype: "stop_hook_summary" as const,
      content: [{ type: "text" as const, text }],
      rawSource: msg,
      seq,
    }),
  );
  return t;
}

function reduceCompactBoundary(
  b: WriteBatch,
  s: SessionState,
  msg: SystemCompactBoundaryMessage,
  seq?: number,
): SessionState {
  const t = b.object(s);
  const id = `compact-${++t.msgIdCounter}`;
  const cm = msg.compact_metadata;
  t.messages = b.array(t.messages);
  t.messages.push(
    b.adopt<DisplayMessage>({
      id,
      type: "compact_boundary" as const,
      content: [],
      compactMetadata: cm
        ? { trigger: cm.trigger, preTokens: cm.pre_tokens }
        : undefined,
      rawSource: msg,
      seq,
    }),
  );
  return t;
}

function reduceTaskLifecycle(
  b: WriteBatch,
  s: SessionState,
  msg: SystemTaskStartedMessage | SystemTaskNotificationMessage,
  seq?: number,
): SessionState {
  const t = b.object(s);
  const id = `task-${++t.msgIdCounter}`;
  let text: string;
  if (msg.type === "task/started") {
    const desc = msg.description || msg.task_id;
    const typeLabel = msg.task_type ? ` [${msg.task_type}]` : "";
    text = `Task started: ${desc}${typeLabel}`;
  } else {
    text = `Task ${msg.status}: ${msg.summary || msg.task_id}`;
  }
  if (msg.type === "task/notification") {
    withTaskState(b, t, msg.task_id, { status: msg.status });
  }
  t.messages = b.array(t.messages);
  t.messages.push(
    b.adopt<DisplayMessage>({
      id,
      type: "system" as const,
      subtype: "task_lifecycle" as const,
      content: [{ type: "text" as const, text }],
      rawSource: msg,
      seq,
      ...(msg.type === "task/started" && {
        taskState: { status: "running" },
      }),
    }),
  );
  return t;
}

/** Show a task's changed state on the row that announced its start. */
function reduceTaskUpdated(
  b: WriteBatch,
  s: SessionState,
  msg: TaskUpdatedEvent,
): SessionState {
  if (msg.status === undefined && msg.error === undefined) return s;
  return withTaskState(b, s, msg.task_id, {
    ...(msg.status !== undefined && { status: msg.status }),
    ...(msg.error !== undefined && { error: msg.error }),
  });
}

function withTaskState(
  b: WriteBatch,
  s: SessionState,
  taskId: string,
  change: { status?: string; error?: string },
): SessionState {
  const index = s.messages.findIndex(
    (m) =>
      m.taskState !== undefined &&
      (m.rawSource as SystemTaskStartedMessage).task_id === taskId,
  );
  // The start may predate the loaded history.
  if (index < 0) return s;
  const started = s.messages[index]!;
  const t = b.object(s);
  t.messages = b.array(t.messages);
  const updated = b.object(started);
  t.messages[index] = updated;
  updated.taskState = b.object(updated.taskState!);
  Object.assign(updated.taskState, change);
  return t;
}

function reduceSummary(
  b: WriteBatch,
  s: SessionState,
  msg: SummaryMessage,
  seq?: number,
): SessionState {
  const t = b.object(s);
  const id = `summary-${++t.msgIdCounter}`;
  t.messages = b.array(t.messages);
  t.messages.push(
    b.adopt<DisplayMessage>({
      id,
      type: "summary" as const,
      content: [{ type: "text" as const, text: msg.summary || "" }],
      rawSource: msg,
      seq,
    }),
  );
  return t;
}

export function reduceRateLimit(
  s: SessionState,
  msg: RateLimitEventMessage,
  seq?: number,
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
        seq,
      },
    ],
  };
}

/** Lightweight file-edit tracker: records only metadata (toolUseId, messageId,
 *  filePath, type).  Actual file content is resolved on-demand by
 *  resolveEditContent() in FileViewer, avoiding string ops and memory
 *  overhead when the viewer is never opened. */
function appendTrackedEdits(
  b: WriteBatch,
  state: SessionState,
  edits: FileEdit[],
): SessionState {
  if (edits.length === 0) return state;
  const t = b.object(state);
  t.trackedFiles = b.map(t.trackedFiles);
  for (const edit of edits) {
    const path = normalizeFilePath(edit.filePath, t.sessionInfo?.cwd);
    const tracked = b.adopt({ ...edit, filePath: path });
    const existing = t.trackedFiles.get(path);
    if (existing) {
      const file = b.object(existing);
      t.trackedFiles.set(path, file);
      file.edits = b.array(file.edits);
      file.edits.push(tracked);
    } else {
      t.trackedFiles.set(path, b.adopt({ path, edits: b.adopt([tracked]) }));
    }
  }
  return t;
}

function updateEditStatusByToolUseId(
  b: WriteBatch,
  state: SessionState,
  toolUseId: string,
  status: FileEditStatus,
): SessionState {
  let t = state;
  for (const [path, file] of state.trackedFiles) {
    for (let i = 0; i < file.edits.length; i++) {
      const edit = file.edits[i]!;
      if (edit.toolUseId !== toolUseId || edit.status === status) continue;
      t = b.object(t);
      t.trackedFiles = b.map(t.trackedFiles);
      const updated = b.object(t.trackedFiles.get(path)!);
      t.trackedFiles.set(path, updated);
      updated.edits = b.array(updated.edits);
      const ownedEdit = b.object(edit);
      updated.edits[i] = ownedEdit;
      ownedEdit.status = status;
    }
  }
  return t;
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

function cancelPendingFileEdits(
  b: WriteBatch,
  state: SessionState,
): SessionState {
  let t = state;
  for (const [path, file] of state.trackedFiles) {
    for (let i = 0; i < file.edits.length; i++) {
      const edit = file.edits[i]!;
      if (edit.status !== "pending") continue;
      t = b.object(t);
      t.trackedFiles = b.map(t.trackedFiles);
      const updated = b.object(t.trackedFiles.get(path)!);
      t.trackedFiles.set(path, updated);
      updated.edits = b.array(updated.edits);
      const ownedEdit = b.object(edit);
      updated.edits[i] = ownedEdit;
      ownedEdit.status = "cancelled";
    }
  }
  return t;
}

function trackResultFileEdits(
  b: WriteBatch,
  state: SessionState,
  toolResults: Array<{
    tool_use_id: string;
    content: ToolResultContent;
    is_error?: boolean;
  }>,
): SessionState {
  for (const block of toolResults) {
    if (block.is_error) continue;

    const blockKey =
      state.itemIdMap.get(block.tool_use_id) ?? block.tool_use_id;
    const toolBlock = state.blocks.get(blockKey);
    if (!toolBlock || toolBlock.type !== "tool_use") continue;

    const toolName = toolBlock.name;
    if (
      !toolName ||
      (!toolIs(
        toolName,
        toolBlock.driver,
        toolBlock.toolServer,
        "claude/Edit",
      ) &&
        !toolIs(
          toolName,
          toolBlock.driver,
          toolBlock.toolServer,
          "claude/Write",
        ) &&
        !toolIs(
          toolName,
          toolBlock.driver,
          toolBlock.toolServer,
          "codex/apply_patch",
        ) &&
        !toolIs(
          toolName,
          toolBlock.driver,
          toolBlock.toolServer,
          "claude/Bash",
        ))
    )
      continue;

    // Find the message containing this block for messageId (used for scroll-to)
    let messageId = "";
    for (let i = state.messages.length - 1; i >= 0; i--) {
      const m = state.messages[i]!;
      if (m.blockIds?.includes(blockKey)) {
        messageId = m.id;
        break;
      }
    }

    const input = (toolBlock.input ?? {}) as Record<string, unknown>;

    if (
      toolIs(toolName, toolBlock.driver, toolBlock.toolServer, "claude/Bash")
    ) {
      if (!toolBlock.result) continue;
      const toolResult = toolBlock.result.toolResult;
      const bashEditDiff = getBashEditDiff(toolResult);
      if (!bashEditDiff) continue;
      if (bashEditDiff.skipped) continue;
      if (hasTrackedEditsForToolUseId(state, block.tool_use_id)) continue;
      const edits = getBashEditDiffFileChanges(bashEditDiff).map(
        (change, changeIndex) =>
          buildFileEdit(
            {
              toolUseId: block.tool_use_id,
              messageId,
              status: "applied",
              source: "claude-bashEditDiff",
            },
            change.path!,
            toFileEditOperation(change.op)!,
            { mode: "hunks", hunks: change.patchHunks! },
            changeIndex,
          ),
      );
      state = appendTrackedEdits(b, state, edits);
      continue;
    }

    if (
      toolIs(
        toolName,
        toolBlock.driver,
        toolBlock.toolServer,
        "codex/apply_patch",
      )
    ) {
      if (hasTrackedEditsForToolUseId(state, block.tool_use_id)) continue;
      const edits = buildEditsFromApplyPatchInput(
        input,
        block.tool_use_id,
        messageId,
        "applied",
      );
      state = appendTrackedEdits(b, state, edits);
      continue;
    }

    const filePath =
      typeof input.file_path === "string" ? input.file_path : null;
    if (!filePath) continue;

    state = appendTrackedEdits(b, state, [
      {
        toolUseId: block.tool_use_id,
        messageId,
        filePath,
        type: toolIs(
          toolName,
          toolBlock.driver,
          toolBlock.toolServer,
          "claude/Edit",
        )
          ? "edit"
          : "write",
        op: toolIs(
          toolName,
          toolBlock.driver,
          toolBlock.toolServer,
          "claude/Edit",
        )
          ? "edit"
          : "write",
        status: "applied",
        source: "claude-tool",
        payload:
          toolIs(
            toolName,
            toolBlock.driver,
            toolBlock.toolServer,
            "claude/Write",
          ) && typeof input.content === "string"
            ? { mode: "full_content", content: input.content }
            : { mode: "none" },
      },
    ]);
  }
  return state;
}

function reduceResultMessage(
  b: WriteBatch,
  s: SessionState,
  msg: ResultMessage,
  seq?: number,
): SessionState {
  // A result (especially error_during_execution from an interrupt) means the
  // current turn is over. Clear any lingering streaming state so the next
  // response creates a fresh assistant message instead of appending to the
  // interrupted one.
  const t = b.object(s);
  t.messages = b.array(t.messages);
  const messages = t.messages;

  const i = findStreamingMessage(t);
  if (i >= 0) {
    const updated = b.object(messages[i]!);
    updated.streaming = false;
    messages[i] = updated;

    // Mark all incomplete blocks as completed so partial text remains visible.
    let blocksChanged = false;
    for (const itemId of updated.blockIds ?? []) {
      const block = t.blocks.get(itemId);
      if (block && !block.completed) {
        if (!blocksChanged) {
          t.blocks = b.map(t.blocks);
          blocksChanged = true;
        }
        const complete = b.object(block);
        t.blocks.set(itemId, complete);
        complete.completed = true;
      }
    }
    t.streamingMessageCount--;
  }

  const id = `result-${++t.msgIdCounter}`;
  const resultExtraFields = getExtras(msg);
  t.sessionStatus = null;
  t.totalCost = msg.total_cost_usd || t.totalCost;
  messages.push(
    b.adopt<DisplayMessage>({
      id,
      type: "result" as const,
      content: [],
      rawSource: msg,
      seq,
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
        endReason: msg.end_reason,
      },
    }),
  );
  return msg.is_error ? cancelPendingFileEdits(b, t) : t;
}

function findStreamingMessage(
  s: SessionState,
  parentToolUseId?: string,
): number {
  if (s.streamingMessageCount === 0) return -1;
  let sawStreaming = false;
  for (let i = s.messages.length - 1; i >= 0; i--) {
    const message = s.messages[i]!;
    if (message.type !== "assistant" || !message.streaming) continue;
    if (!parentToolUseId || message.parentToolUseId === parentToolUseId)
      return i;
    sawStreaming = true;
  }
  if (!sawStreaming) throw new Error("Streaming message count is inconsistent");
  return -1;
}

/** Insert a message before any in-progress streaming assistant message.
 *  User messages should always precede the assistant's response, but the
 *  protocol may deliver the user echo after streaming has already started. */
function insertBeforeStreaming(
  b: WriteBatch,
  s: SessionState,
  msg: DisplayMessage,
): DisplayMessage[] {
  const i = findStreamingMessage(s);
  const result = b.array(s.messages);
  if (i >= 0) result.splice(i, 0, msg);
  else result.push(msg);
  return result;
}

/** Find or create the in-progress assistant message for streaming blocks.
 *
 * When parentToolUseId is provided (sub-agent context), we look for an
 * existing streaming message with that same parentToolUseId, or create a
 * new isolated placeholder.  This prevents sub-agent events from corrupting
 * the main turn's streaming message (M_main). */
function getOrCreateStreamingMessage(
  b: WriteBatch,
  s: SessionState,
  parentToolUseId?: string,
  ts?: number,
): number {
  const i = findStreamingMessage(s, parentToolUseId);
  if (i >= 0) return i;
  const placeholder = b.adopt<DisplayMessage>({
    id: `streaming-${++s.msgIdCounter}`,
    type: "assistant",
    content: [],
    blockIds: b.adopt([]),
    streaming: true,
    nextCreationOrder: 0,
    ts,
  });
  if (parentToolUseId) placeholder.parentToolUseId = parentToolUseId;
  s.messages = b.array(s.messages);
  s.messages.push(placeholder);
  s.streamingMessageCount++;
  return s.messages.length - 1;
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

export function replaceHistoryBoundaryIn(
  b: WriteBatch,
  s: SessionState,
  event: AgnosticEvent & { history_boundary?: HistoryBoundary },
  seq: number,
): SessionState {
  const boundary = event.history_boundary;
  if (!boundary) throw new Error("Replacement event has no history boundary");
  const isUserBoundary =
    boundary.kind === "user" || boundary.kind === "provisional_user";
  const expectedType = isUserBoundary ? "user" : "assistant";
  const eventMatchesBoundary = isUserBoundary
    ? event.type === "item/started" && event.item_type === "user_message"
    : event.type === "turn/stop";
  if (!eventMatchesBoundary)
    throw new Error(
      "Replacement event identity does not match history boundary",
    );
  let message: DisplayMessage | undefined;
  for (let i = s.messages.length - 1; i >= 0; i--) {
    const candidate = s.messages[i]!;
    if (
      candidate.type === expectedType &&
      (candidate.seq === seq ||
        (Array.isArray(candidate.seq) && candidate.seq.includes(seq)))
    ) {
      message = candidate;
      break;
    }
  }
  if (!message)
    throw new Error(`History replacement matched 0 messages at seq ${seq}`);
  const raw = Array.isArray(message.rawSource)
    ? message.rawSource
    : [message.rawSource];
  const seqs = Array.isArray(message.seq) ? message.seq : [message.seq];
  let rawIndex = -1;
  let rawMatches = 0;
  for (let i = 0; i < seqs.length; i++) {
    if (seqs[i] === seq) {
      rawIndex = i;
      rawMatches++;
    }
  }
  if (rawMatches !== 1)
    throw new Error(
      `History replacement matched ${rawMatches} raw contributions at seq ${seq}`,
    );
  const existing = raw[rawIndex] as {
    type?: string;
    item_type?: string;
    item_id?: string;
    uuid?: string;
  };
  const existingMatchesBoundary = isUserBoundary
    ? existing.type === "item/started" && existing.item_type === "user_message"
    : existing.type === "turn/stop";
  if (!existingMatchesBoundary)
    throw new Error(
      "Replacement target identity does not match history boundary",
    );
  if (
    isUserBoundary &&
    existing.item_id !== (event as { item_id?: string }).item_id
  )
    throw new Error("Replacement target item identity does not match");
  if (
    boundary.kind === "agent_turn" &&
    existing.uuid !== (event as { uuid?: string }).uuid
  )
    throw new Error("Replacement target turn identity does not match");
  const t = b.object(s);
  t.replacementEvents = b.map(t.replacementEvents);
  t.replacementEvents.set(seq, event);
  return t;
}

function reduceItemStartedUserMessage(
  b: WriteBatch,
  s: SessionState,
  event: ItemStartedEvent,
  seq?: number,
  ts?: number,
): SessionState {
  const content = event.content ?? [];
  const blocks: AssistantContentBlock[] =
    content.length > 0
      ? (content as AssistantContentBlock[])
      : [{ type: "text" as const, text: "" }];

  const isPendingUserMsg = (m: DisplayMessage) =>
    m.type === "user" && m.ackState !== undefined && m.ackState > 1;
  const isProvisionalUserMsg = (m: DisplayMessage) =>
    m.type === "user" && m.isProvisional === true;
  const eventNonce = (event as unknown as { correlation_id?: string })
    .correlation_id;
  const eventCydoMeta = (event as unknown as { meta?: CydoMeta }).meta;
  const eventUserText = canonicalUserTextFromContentAndMeta(
    blocks,
    eventCydoMeta,
  );
  const hasSameContent = (m: DisplayMessage) =>
    canonicalUserTextFromDisplayMessage(m) === eventUserText;
  // Only local optimistic/unconfirmed bubbles are displaced by a replay.
  // Queue-emitted history bubbles retain their enqueue-N identity until their
  // own user_message/consumed confirmation removes them.
  const isReplayDisposableProvisionalUserMsg = (m: DisplayMessage) =>
    isProvisionalUserMsg(m) &&
    m.expectedNativeUuid === undefined &&
    (eventNonce ? m.nonce === eventNonce : !m.nonce || hasSameContent(m));
  const isExpectedReplayProvisionalUserMsg = (m: DisplayMessage) =>
    isProvisionalUserMsg(m) &&
    m.expectedNativeUuid !== undefined &&
    m.expectedNativeUuid === event.uuid;

  // Extract cydoMeta from a pending placeholder before replay removes it.
  const pendingMsg = eventNonce
    ? s.messages.find((m) => isPendingUserMsg(m) && m.nonce === eventNonce)
    : s.messages.find(
        (m) => isPendingUserMsg(m) && (!m.nonce || hasSameContent(m)),
      );

  let state = s;
  let displacedPlaceholder: DisplayMessage | undefined;

  if (event.is_replay) {
    // One replay echo accounts for exactly one sent message: displace at
    // most one placeholder. A prior queue confirmation gives an exact native
    // UUID match; otherwise retain the nonce/content matching for replays
    // that arrive first.
    const expectedDropIdx = state.messages.findIndex(
      isExpectedReplayProvisionalUserMsg,
    );
    const dropIdx =
      expectedDropIdx >= 0
        ? expectedDropIdx
        : state.messages.findIndex(isReplayDisposableProvisionalUserMsg);
    if (dropIdx >= 0) {
      displacedPlaceholder = state.messages[dropIdx];
      state = b.object(state);
      state.messages = b.array(state.messages);
      state.messages.splice(dropIdx, 1);
    }
  }

  let reconciled = displacedPlaceholder;
  // Match by nonce when provided, leaving unrelated placeholders alone.
  // A replay already displaced its placeholder above and must not consume
  // a second one.
  if (!event.pending && !event.is_replay) {
    const matchIdx = state.messages.findIndex(
      (m) =>
        isPendingUserMsg(m) &&
        !m.uuid &&
        (eventNonce ? m.nonce === eventNonce : hasSameContent(m)),
    );
    if (matchIdx >= 0) {
      reconciled = state.messages[matchIdx];
      state = b.object(state);
      state.messages = b.array(state.messages);
      state.messages.splice(matchIdx, 1);
    } else if (!eventNonce) {
      const removed = state.messages.filter(
        isReplayDisposableProvisionalUserMsg,
      );
      if (removed.length === 1) reconciled = removed[0];
      if (removed.length > 0) {
        state = b.object(state);
        state.messages = b.array(state.messages);
        let kept = 0;
        for (const message of state.messages) {
          if (!isReplayDisposableProvisionalUserMsg(message)) {
            state.messages[kept++] = message;
          }
        }
        state.messages.length = kept;
      }
    }
  }

  // The echo inherits the render identity of the single row it reconciles.
  state = b.object(state);
  const id = reconciled?.id ?? `user-echo-${++state.msgIdCounter}`;
  if (event.pending) {
    const echoMsg = b.adopt<DisplayMessage>({
      id,
      type: "user" as const,
      content: blocks,
      ackState: 3,
      pending: true,
      isSidechain: event.is_sidechain,
      isSynthetic: event.is_synthetic || undefined,
      isMeta: event.is_meta || undefined,
      metaKinds: event.meta_kinds,
      isSteering: event.is_steering || undefined,
      isCompactSummary: event.isCompactSummary || undefined,
      parentToolUseId: event.parent_tool_use_id,
      extraFields: getExtras(event),
      rawSource: event,
      seq,
      uuid: event.uuid,
      cydoMeta: eventCydoMeta,
      ts,
    });
    if (event.is_meta) {
      state.messages = b.array(state.messages);
      state.messages.push(echoMsg);
    } else {
      state.messages = insertBeforeStreaming(b, state, echoMsg);
    }
    return state;
  }

  const echoMsg = b.adopt<DisplayMessage>({
    id,
    type: "user" as const,
    content: blocks,
    isSidechain: event.is_sidechain,
    isSynthetic: event.is_synthetic || undefined,
    isMeta: event.is_meta || undefined,
    metaKinds: event.meta_kinds,
    isSteering:
      event.is_steering || displacedPlaceholder?.isSteering || undefined,
    isCompactSummary: event.isCompactSummary || undefined,
    parentToolUseId: event.parent_tool_use_id,
    extraFields: getExtras(event),
    rawSource: event,
    seq,
    uuid: event.uuid,
    nonce: event.is_replay ? undefined : pendingMsg?.nonce,
    cydoMeta:
      displacedPlaceholder?.cydoMeta ?? pendingMsg?.cydoMeta ?? eventCydoMeta,
    removed: displacedPlaceholder?.removed,
    ts,
  });
  if (displacedPlaceholder?.pending) {
    // The agent echoes a replayed user message as soon as it consumes it —
    // that only proves submission to the harness, not that the LLM has seen
    // it. Keep the "submitted" presentation; assistant output promotes it
    // (reduceItemStarted) once the request demonstrably reached the model.
    echoMsg.ackState = 3;
    echoMsg.pending = true;
    echoMsg.echoPending = true;
    state.mayHaveEchoPending = true;
  }

  if (event.is_meta) {
    state.messages = b.array(state.messages);
    state.messages.push(echoMsg);
  } else {
    state.messages = insertBeforeStreaming(b, state, echoMsg);
  }

  return state;
}

/// A queue confirmation reported what became of a previously displayed user
/// message: consumed as a steering injection, consumed as a turn opener,
/// removed without being consumed, or cancelled (withdrawn by CyDo).
///
/// A cancelled message never reached the conversation: drop its bubble. The
/// un-send that cancels it reloads the task, so the pre-reload draft snapshot
/// returns its text to the composer.
///
/// When the confirmation targets a provisional enqueue-emitted bubble
/// (identity "enqueue-N") and names a distinct native identity, the canonical
/// echo message follows in the same stream — drop the provisional bubble.
/// Otherwise upgrade the bubble in place: clear the pending presentation and
/// apply the consumption classification.
function reduceUserMessageConsumed(
  b: WriteBatch,
  s: SessionState,
  event: UserMessageConsumedEvent,
): SessionState {
  const idx = s.messages.findIndex(
    (m) =>
      m.type === "user" &&
      ((event.uuid && m.uuid === event.uuid) ||
        (event.correlation_id && m.nonce === event.correlation_id)),
  );
  if (idx < 0) return s;

  const target = s.messages[idx]!;
  const canonicalFollows =
    event.native_uuid &&
    event.native_uuid !== event.uuid &&
    target.uuid?.startsWith("enqueue-");
  const t = b.object(s);
  t.messages = b.array(t.messages);
  if (
    event.consumed_as === "cancelled" ||
    (canonicalFollows && event.consumed_as !== "removed")
  ) {
    t.messages.splice(idx, 1);
    return t;
  }
  const upgraded = b.object(target);
  t.messages[idx] = upgraded;
  upgraded.pending = undefined;
  upgraded.ackState = undefined;
  upgraded.echoPending = undefined;
  if (upgraded.isProvisional) {
    if (event.native_uuid) upgraded.expectedNativeUuid = event.native_uuid;
    else {
      upgraded.isProvisional = undefined;
      upgraded.expectedNativeUuid = undefined;
    }
  }
  if (event.consumed_as === "steering") upgraded.isSteering = true;
  else if (event.consumed_as === "removed") upgraded.removed = true;
  return t;
}

export function rejectOrdinarySubmissionIn(
  b: WriteBatch,
  task: SessionState,
  nonce: string,
): SessionState {
  let t = task;
  for (let i = task.messages.length - 1; i >= 0; i--) {
    const message = task.messages[i]!;
    if (
      message.type !== "user" ||
      !message.isProvisional ||
      message.nonce !== nonce
    )
      continue;
    t = b.object(t);
    t.messages = b.array(t.messages);
    t.messages.splice(i, 1);
  }
  return t;
}

export function reduceAgentAckIn(
  b: WriteBatch,
  s: SessionState,
  nonce: string,
): SessionState {
  const idx = s.messages.findIndex(
    (m) =>
      m.type === "user" &&
      m.nonce === nonce &&
      m.ackState !== undefined &&
      m.ackState > 1,
  );
  if (idx < 0) return s;
  const t = b.object(s);
  t.messages = b.array(t.messages);
  const message = b.object(t.messages[idx]!);
  t.messages[idx] = message;
  message.ackState = 2;
  return t;
}

function reduceItemStarted(
  b: WriteBatch,
  s: SessionState,
  event: ItemStartedEvent,
  seq?: number,
  ts?: number,
): SessionState {
  if (event.item_type === "user_message") {
    return reduceItemStartedUserMessage(b, s, event, seq, ts);
  }

  // Top-level assistant output proves the request containing the previously
  // echoed user messages reached the model — promote them from "submitted to
  // the harness" to the confirmed in-context presentation.
  if (
    !event.parent_tool_use_id &&
    !event.is_sidechain &&
    (event.item_type === "text" ||
      event.item_type === "thinking" ||
      event.item_type === "tool_use") &&
    s.mayHaveEchoPending
  ) {
    s = b.object(s);
    s.messages = b.array(s.messages);
    for (let i = 0; i < s.messages.length; i++) {
      const message = s.messages[i]!;
      if (!message.echoPending) continue;
      const promoted = b.object(message);
      s.messages[i] = promoted;
      promoted.echoPending = undefined;
      promoted.pending = undefined;
      promoted.ackState = undefined;
    }
    s.mayHaveEchoPending = false;
  }

  const state = b.object(s);
  const msgIdx = getOrCreateStreamingMessage(
    b,
    state,
    event.parent_tool_use_id,
    ts,
  );
  state.messages = b.array(state.messages);
  const msg = b.object(state.messages[msgIdx]!);
  state.messages[msgIdx] = msg;

  // Block keys must be globally unique. Item IDs (e.g. "cc-block-0") are only
  // unique within a turn, so scope them with the message ID.
  const blockKey = itemBlockKey(msg.id, event.item_id);
  const isDuplicateBlockKey = msg.blockIds?.includes(blockKey) ?? false;

  if (event.parent_tool_use_id) {
    msg.parentToolUseId = event.parent_tool_use_id;
  }

  appendRawSource(b, msg, event, seq);

  if (state.itemIdMap.get(event.item_id) !== blockKey) {
    state.itemIdMap = b.map(state.itemIdMap);
    state.itemIdMap.set(event.item_id, blockKey);
  }
  if (isDuplicateBlockKey) return state;

  const creationOrder = msg.nextCreationOrder ?? 0;
  msg.nextCreationOrder = creationOrder + 1;
  const blockType =
    event.item_type === "text" ||
    event.item_type === "thinking" ||
    event.item_type === "tool_use" ||
    event.item_type === "unrecognized" ||
    event.item_type === "user_message"
      ? event.item_type
      : "other";
  const driver = s.driver ?? s.sessionInfo?.agent;
  const block = b.adopt<Block>({
    itemId: event.item_id,
    type: blockType,
    text: event.text ?? "",
    name: event.name,
    toolServer: event.tool_server,
    toolSource: event.tool_source,
    driver,
    input: event.input,
    completed: false,
    creationOrder,
  });

  msg.blockIds = msg.blockIds ? b.array(msg.blockIds) : b.adopt([]);
  msg.blockIds.push(blockKey);
  state.blocks = b.map(state.blocks);
  state.blocks.set(blockKey, block);

  if (event.item_type === "tool_use") {
    if (
      toolIs(event.name ?? "", driver, event.tool_server, "codex/fileChange")
    ) {
      const rawForEdits =
        event.input != null ? { params: { item: event.input } } : undefined;
      const edits = buildEditsFromCodexFileChangeEvent(
        rawForEdits,
        event.item_id,
        msg.id,
        "pending",
      );
      appendTrackedEdits(b, state, edits);
    } else if (
      toolIs(event.name ?? "", driver, event.tool_server, "codex/apply_patch")
    ) {
      const edits = buildEditsFromApplyPatchInput(
        (block.input ?? {}) as Record<string, unknown>,
        event.item_id,
        msg.id,
        "pending",
      );
      appendTrackedEdits(b, state, edits);
    }
  }

  return state;
}

function reduceItemDelta(
  b: WriteBatch,
  s: SessionState,
  event: ItemDeltaEvent,
): SessionState {
  const blockKey = s.itemIdMap.get(event.item_id) ?? event.item_id;
  const block = s.blocks.get(blockKey);
  if (!block) return s;

  const t = b.object(s);
  t.blocks = b.map(t.blocks);
  const updated = b.object(block);
  t.blocks.set(blockKey, updated);
  if (event.delta_type === "output_delta") {
    updated.output = (updated.output ?? "") + event.content;
  } else if (event.delta_type === "stdin_delta") {
    updated.stdin = (updated.stdin ?? "") + event.content;
  } else {
    updated.text += event.content;
  }

  return t;
}

function reduceItemCompleted(
  b: WriteBatch,
  s: SessionState,
  event: ItemCompletedEvent,
  seq?: number,
): SessionState {
  const blockKey = s.itemIdMap.get(event.item_id) ?? event.item_id;
  const block = s.blocks.get(blockKey);

  if (!block) {
    // Item not found anywhere — just update edit status
    return updateEditStatusByToolUseId(
      b,
      s,
      event.item_id,
      event.is_error ? "cancelled" : "applied",
    );
  }

  const isToolUse = block.type === "tool_use";
  const input = isToolUse
    ? (event.input ?? block.input ?? tryParseJson(block.text))
    : undefined;
  const t = b.object(s);
  t.blocks = b.map(t.blocks);
  const updated = b.object(block);
  t.blocks.set(blockKey, updated);
  updated.completed = true;
  if (event.text !== undefined) updated.text = event.text;
  if (event.is_narration) updated.narration = true;
  const completedExtras = getExtras(event);
  if (completedExtras) updated.extras = completedExtras;
  if (isToolUse) updated.input = input;

  // Append to rawSource of the parent message
  const messages = t.messages;
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i]!;
    if (m.blockIds?.includes(blockKey)) {
      t.messages = b.array(messages);
      const updatedMsg = b.object(m);
      t.messages[i] = updatedMsg;
      appendRawSource(b, updatedMsg, event, seq);
      break;
    }
  }

  if (isToolUse) {
    updateEditStatusByToolUseId(
      b,
      t,
      event.item_id,
      event.is_error ? "cancelled" : "applied",
    );
  }
  return t;
}

function reduceItemAbandoned(
  b: WriteBatch,
  s: SessionState,
  event: ItemAbandonedEvent,
): SessionState {
  const blockKey = s.itemIdMap.get(event.item_id);
  if (blockKey === undefined) {
    throw new Error(`Cannot abandon unknown item ${event.item_id}`);
  }
  const t = b.object(s);
  t.blocks = b.map(t.blocks);
  t.blocks.delete(blockKey);
  t.itemIdMap = b.map(t.itemIdMap);
  t.itemIdMap.delete(event.item_id);
  for (let i = t.messages.length - 1; i >= 0; i--) {
    const message = t.messages[i]!;
    if (!message.blockIds?.includes(blockKey)) continue;
    t.messages = b.array(t.messages);
    const blockIds = message.blockIds.filter((id) => id !== blockKey);
    if (blockIds.length > 0) {
      const updated = b.object(message);
      t.messages[i] = updated;
      updated.blockIds = b.adopt(blockIds);
    } else {
      t.messages.splice(i, 1);
      if (message.type === "assistant" && message.streaming)
        t.streamingMessageCount--;
    }
  }
  return t;
}

function reduceItemDenied(
  b: WriteBatch,
  s: SessionState,
  event: ItemDeniedEvent,
): SessionState {
  const blockKey = s.itemIdMap.get(event.item_id) ?? event.item_id;
  const block = s.blocks.get(blockKey);
  if (!block) return s;
  const t = b.object(s);
  t.blocks = b.map(t.blocks);
  const updated = b.object(block);
  t.blocks.set(blockKey, updated);
  updated.denial = { by: event.by, reason: event.reason };
  return t;
}

function reduceItemPermission(
  b: WriteBatch,
  s: SessionState,
  event: ItemPermissionEvent,
): SessionState {
  const blockKey = s.itemIdMap.get(event.item_id) ?? event.item_id;
  const block = s.blocks.get(blockKey);
  if (!block) return s;
  const t = b.object(s);
  t.blocks = b.map(t.blocks);
  const updated = b.object(block);
  t.blocks.set(blockKey, updated);
  updated.permission = event.stage;
  return t;
}

function reduceItemResult(
  b: WriteBatch,
  s: SessionState,
  event: ItemResultEvent,
  seq?: number,
): SessionState {
  const blockKey = s.itemIdMap.get(event.item_id) ?? event.item_id;
  const block = s.blocks.get(blockKey);
  if (!block) return s;

  const t = b.object(s);
  t.blocks = b.map(t.blocks);
  const updated = b.object(block);
  t.blocks.set(blockKey, updated);
  updated.result = {
    toolUseId: event.item_id,
    content: event.content as import("./types").ToolResultContent,
    isError: event.is_error,
    toolResult: event.tool_result,
  };

  // Append to rawSource of the parent message
  const messages = t.messages;
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i]!;
    if (m.blockIds?.includes(blockKey)) {
      t.messages = b.array(messages);
      const updatedMsg = b.object(m);
      t.messages[i] = updatedMsg;
      appendRawSource(b, updatedMsg, event, seq);
      break;
    }
  }

  trackResultFileEdits(b, t, [
    {
      tool_use_id: event.item_id,
      content: event.content as import("./types").ToolResultContent,
      is_error: event.is_error,
    },
  ]);
  return t;
}

function reduceTurnDelta(
  b: WriteBatch,
  s: SessionState,
  event: TurnDeltaEvent,
  seq?: number,
): SessionState {
  const i = findStreamingMessage(s, event.parent_tool_use_id);
  if (i < 0) return s;
  const t = b.object(s);
  t.messages = b.array(t.messages);
  const messages = t.messages;
  const updated = b.object(messages[i]!);
  messages[i] = updated;

  // Apply turn-level metadata eagerly.
  if (event.model) updated.model ??= event.model;
  if (event.usage) updated.usage = event.usage;
  if (event.parent_tool_use_id)
    updated.parentToolUseId ??= event.parent_tool_use_id;
  if (event.is_sidechain) updated.isSidechain = event.is_sidechain;
  const deltaExtras = getExtras(event);
  if (deltaExtras) updated.extraFields = deltaExtras;
  if (event.uuid) updated.uuid = event.uuid;

  // Attach to rawSource for "View source" → "Raw".
  appendRawSource(b, updated, event, seq);

  return t;
}

function reduceTurnStop(
  b: WriteBatch,
  s: SessionState,
  event: TurnStopEvent,
  seq?: number,
): SessionState {
  const i = findStreamingMessage(s, event.parent_tool_use_id);
  if (i < 0) return s;
  const t = b.object(s);
  t.messages = b.array(t.messages);
  const messages = t.messages;
  const updated = b.object(messages[i]!);
  messages[i] = updated;

  // Apply metadata if present (history path where no turn/delta preceded).
  // ??= guards prevent overwriting values already set by turn/delta.
  if (event.model) updated.model ??= event.model;
  if (event.usage) updated.usage ??= event.usage;
  if (event.parent_tool_use_id)
    updated.parentToolUseId ??= event.parent_tool_use_id;
  if (event.is_sidechain) updated.isSidechain ??= event.is_sidechain;
  const stopExtras = getExtras(event);
  if (stopExtras) updated.extraFields ??= stopExtras;
  if (event.uuid) updated.uuid ??= event.uuid;

  // Always append to rawSource — every raw Claude Code event that
  // contributes to the message should be visible via "View source" → "Raw".
  appendRawSource(b, updated, event, seq);

  updated.streaming = false;
  t.streamingMessageCount--;

  // Mark all incomplete blocks as completed (safety net — prevents
  // orphaned incomplete blocks from persisting past the turn boundary).
  let blocksChanged = false;
  for (const itemId of updated.blockIds ?? []) {
    const block = t.blocks.get(itemId);
    if (block && !block.completed) {
      if (!blocksChanged) {
        t.blocks = b.map(t.blocks);
        blocksChanged = true;
      }
      const complete = b.object(block);
      t.blocks.set(itemId, complete);
      complete.completed = true;
    }
  }

  return t;
}

function reduceStderr(
  b: WriteBatch,
  s: SessionState,
  event: StderrMessage,
  seq?: number,
): SessionState {
  const lastMessage = s.messages[s.messages.length - 1];
  if (lastMessage?.type === "system" && lastMessage.subtype === "stderr") {
    const t = b.object(s);
    t.messages = b.array(t.messages);
    const messages = t.messages;
    const updated = b.object(lastMessage);
    const priorText = updated.content
      .filter(
        (block): block is { type: "text"; text: string } =>
          block.type === "text",
      )
      .map((block) => block.text)
      .join("\n");
    updated.content = [
      {
        type: "text" as const,
        text: priorText.length > 0 ? `${priorText}\n${event.text}` : event.text,
      },
    ];
    appendRawSource(b, updated, event, seq);
    messages[messages.length - 1] = updated;
    return t;
  }

  const t = b.object(s);
  const id = `stderr-${++t.msgIdCounter}`;
  t.messages = b.array(t.messages);
  t.messages.push(
    b.adopt<DisplayMessage>({
      id,
      type: "system" as const,
      subtype: "stderr" as const,
      content: [{ type: "text" as const, text: event.text }],
      rawSource: event,
      seq,
    }),
  );
  return t;
}

function reduceExit(b: WriteBatch, s: SessionState): SessionState {
  // Backend owns alive/resumable via tasks_list; nothing to update here.
  if (s.sessionStatus !== null) {
    s = b.object(s);
    s.sessionStatus = null;
  }
  return cancelPendingFileEdits(b, s);
}

/** The agent withdrew responses it had delivered: keep them, marked as
 *  retracted, and show its notice. A response is one assistant message; the
 *  agent names it by the uuid of each of its parts, the last of which the
 *  message carries. */
function reduceTurnRetracted(
  b: WriteBatch,
  s: SessionState,
  msg: Extract<AgnosticEvent, { type: "turn/retracted" }>,
  seq?: number,
  ts?: number,
): SessionState {
  const uuids = new Set(msg.uuids);
  let t = s;
  for (let i = 0; i < s.messages.length; i++) {
    const message = s.messages[i]!;
    if (
      message.type !== "assistant" ||
      message.uuid === undefined ||
      !uuids.has(message.uuid) ||
      message.retracted
    )
      continue;
    t = b.object(t);
    t.messages = b.array(t.messages);
    const updated = b.object(message);
    t.messages[i] = updated;
    updated.retracted = true;
  }
  return reduceTaskDiagnostic(b, t, msg.notice, seq, ts);
}

function reduceTaskDiagnostic(
  b: WriteBatch,
  s: SessionState,
  msg: Extract<
    AgnosticEvent,
    { type: "cydo/task_diagnostic" | "agent/notice" }
  >,
  seq?: number,
  ts?: number,
): SessionState {
  const hookOutput =
    msg.type === "agent/notice" && msg.collapsible
      ? { stdout: msg.stdout, stderr: msg.stderr, output: msg.output }
      : undefined;
  const i = findStreamingMessage(s);
  if (i >= 0) {
    const t = b.object(s);
    t.messages = b.array(t.messages);
    const messages = t.messages;
    const updated = b.object(messages[i]!);
    messages[i] = updated;
    appendRawSource(b, updated, msg, seq);
    const creationOrder = updated.nextCreationOrder ?? 0;
    updated.nextCreationOrder = creationOrder + 1;
    const itemId = `diagnostic-${++t.msgIdCounter}`;
    t.blocks = b.map(t.blocks);
    t.blocks.set(
      itemId,
      b.adopt({
        itemId,
        type: "diagnostic",
        text: msg.body,
        severity: msg.severity,
        subject: msg.subject,
        hookOutput,
        completed: false,
        creationOrder,
      }),
    );
    updated.blockIds = updated.blockIds
      ? b.array(updated.blockIds)
      : b.adopt([]);
    updated.blockIds.push(itemId);
    return t;
  }
  const t = b.object(s);
  t.messages = b.array(t.messages);
  t.messages.push(
    b.adopt<DisplayMessage>({
      id: `task-diagnostic-${++t.msgIdCounter}`,
      type: "diagnostic",
      content: [{ type: "text", text: msg.body }],
      diagnostic: {
        severity: msg.severity,
        subject: msg.subject,
        hookOutput,
      },
      rawSource: msg,
      seq,
      ts,
    }),
  );
  return t;
}

// ---------------------------------------------------------------------------
// Top-level dispatcher: routes to individual reducers
// ---------------------------------------------------------------------------

export function reduceMessageIn(
  b: WriteBatch,
  s: SessionState,
  msg: AgnosticEvent,
  seq?: number,
  ts?: number,
): SessionState {
  switch (msg.type) {
    case "agent/notice":
    case "cydo/task_diagnostic":
      return reduceTaskDiagnostic(b, s, msg, seq, ts);
    case "agent/command_output": {
      const t = b.object(s);
      const id = `command-output-${++t.msgIdCounter}`;
      t.blocks = b.map(t.blocks);
      t.blocks.set(
        id,
        b.adopt({
          itemId: id,
          type: "command_output",
          text: msg.text,
          completed: true,
          creationOrder: 0,
        }),
      );
      t.messages = b.array(t.messages);
      t.messages.push(
        b.adopt<DisplayMessage>({
          id,
          type: "assistant",
          content: [],
          blockIds: [id],
          rawSource: msg,
          seq,
          ts,
        }),
      );
      return t;
    }
    case "turn/retracted":
      return reduceTurnRetracted(b, s, msg, seq, ts);
    case "session/init":
      return reduceSystemInit(b, s, msg, seq);

    case "session/metadata":
      return reduceSessionMetadata(b, s, msg, seq);

    case "session/status":
      return reduceSystemStatus(b, s, msg, seq);

    case "session/compacted":
      return reduceCompactBoundary(b, s, msg, seq);

    case "task/started":
    case "task/notification":
      return reduceTaskLifecycle(b, s, msg, seq);

    case "task/updated":
      return reduceTaskUpdated(b, s, msg);

    case "system":
      return reduceStopHookSummary(b, s, msg, seq);

    case "item/started":
      return reduceItemStarted(b, s, msg, seq, ts);

    case "user_message/consumed":
      return reduceUserMessageConsumed(b, s, msg);

    case "item/delta":
      return reduceItemDelta(b, s, msg);

    case "item/abandoned":
      return reduceItemAbandoned(b, s, msg);

    case "item/completed":
      return reduceItemCompleted(b, s, msg, seq);

    case "item/result":
      return reduceItemResult(b, s, msg, seq);

    case "item/denied":
      return reduceItemDenied(b, s, msg);

    case "item/permission":
      return reduceItemPermission(b, s, msg);

    case "turn/delta":
      return reduceTurnDelta(b, s, msg, seq);

    case "turn/stop":
      return reduceTurnStop(b, s, msg, seq);

    case "turn/result":
      return reduceResultMessage(b, s, msg, seq);

    case "session/summary":
      return reduceSummary(b, s, msg, seq);

    case "session/cost": {
      if (s.totalCost === msg.total_cost_usd) return s;
      const t = b.object(s);
      t.totalCost = msg.total_cost_usd;
      return t;
    }

    case "session/rate_limit":
      return s;

    case "control/response": {
      const t = b.object(s);
      const id = `control-response-${++t.msgIdCounter}`;
      t.messages = b.array(t.messages);
      t.messages.push(
        b.adopt<DisplayMessage>({
          id,
          type: "system" as const,
          subtype: "control_response" as const,
          content: [
            {
              type: "text" as const,
              text: `Control response: ${msg.response.subtype ?? "unknown"}`,
            },
          ],
          rawSource: msg,
          seq,
        }),
      );
      return t;
    }

    case "process/exit":
      return reduceExit(b, s);

    case "process/stderr":
      return reduceStderr(b, s, msg, seq);

    case "agent/unrecognized": {
      // If mid-turn, embed in the streaming message to preserve temporal order.
      const streamingMsgIdx = findStreamingMessage(s);
      if (streamingMsgIdx >= 0) {
        const t = b.object(s);
        t.messages = b.array(t.messages);
        const messages = t.messages;
        const updated = b.object(messages[streamingMsgIdx]!);
        messages[streamingMsgIdx] = updated;
        const creationOrder = updated.nextCreationOrder ?? 0;
        updated.nextCreationOrder = creationOrder + 1;

        const itemId = `unrecognized-${++t.msgIdCounter}`;
        const block: Block = {
          itemId,
          type: "unrecognized",
          text: msg.reason,
          completed: false,
          creationOrder,
        };
        updated.blockIds = updated.blockIds
          ? b.array(updated.blockIds)
          : b.adopt([]);
        updated.blockIds.push(itemId);
        appendRawSource(b, updated, msg, seq);

        t.blocks = b.map(t.blocks);
        t.blocks.set(itemId, b.adopt(block));
        return t;
      }
      // No streaming message — top-level system message.
      return reduceParseError(
        b,
        s,
        "Unrecognized agent data",
        msg.reason,
        msg,
        false,
        seq,
      );
    }

    case "cydo/item_enriched":
      return reduceItemEnriched(b, s, msg);

    default:
      return reduceParseError(
        b,
        s,
        "Unknown message type",
        (msg as unknown as Record<string, unknown>).type as string,
        msg,
        true,
        seq,
      );
  }
}

function reduceItemEnriched(
  b: WriteBatch,
  s: SessionState,
  event: CydoItemEnrichedEvent,
): SessionState {
  const { item_id, target_tid, spawned_child } = event;
  const blockKey = s.itemIdMap.get(item_id);
  if (blockKey === undefined || s.blocks.get(blockKey)?.type !== "tool_use") {
    throw new Error(`Cannot enrich unknown or non-tool item ${item_id}`);
  }
  if (target_tid === undefined && spawned_child === undefined) {
    throw new Error(`Empty enrichment for item ${item_id}`);
  }
  const existing = s.itemEnrichments.get(blockKey);
  if (target_tid !== undefined && existing?.targetTid !== undefined) {
    throw new Error(`Duplicate target task enrichment for item ${item_id}`);
  }
  if (
    spawned_child !== undefined &&
    existing?.spawnedTids?.has(spawned_child.spec_index)
  ) {
    throw new Error(
      `Duplicate spawned child enrichment for item ${item_id} at spec index ${spawned_child.spec_index}`,
    );
  }
  const t = b.object(s);
  t.itemEnrichments = b.map(t.itemEnrichments);
  const enrichment = existing
    ? b.object(existing)
    : b.adopt<ItemEnrichment>({});
  t.itemEnrichments.set(blockKey, enrichment);
  if (target_tid !== undefined) enrichment.targetTid = target_tid;
  if (spawned_child !== undefined) {
    const spawnedTids = enrichment.spawnedTids
      ? b.map(enrichment.spawnedTids)
      : b.adopt(new Map<number, number>());
    spawnedTids.set(spawned_child.spec_index, spawned_child.child_tid);
    enrichment.spawnedTids = spawnedTids;
  }
  return t;
}

export function replaceHistoryBoundary(
  s: SessionState,
  event: AgnosticEvent & { history_boundary?: HistoryBoundary },
  seq: number,
): SessionState {
  const batch = new WriteBatch();
  const next = replaceHistoryBoundaryIn(batch, s, event, seq);
  batch.close();
  return next;
}

export function rejectOrdinarySubmission(
  task: SessionState,
  nonce: string,
): SessionState {
  const batch = new WriteBatch();
  const next = rejectOrdinarySubmissionIn(batch, task, nonce);
  batch.close();
  return next;
}

export function reduceAgentAck(s: SessionState, nonce: string): SessionState {
  const batch = new WriteBatch();
  const next = reduceAgentAckIn(batch, s, nonce);
  batch.close();
  return next;
}

export function reduceMessage(
  s: SessionState,
  msg: AgnosticEvent,
  seq?: number,
  ts?: number,
): SessionState {
  const batch = new WriteBatch();
  const next = reduceMessageIn(batch, s, msg, seq, ts);
  batch.close();
  return next;
}
