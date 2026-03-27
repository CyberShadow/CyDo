// Shared display types for the UI.
//
// These are the frontend's internal representations — distinct from the
// wire-protocol types in protocol.ts.

import type { AssistantContentBlock, AskUserQuestionItem } from "./protocol";

export interface DisplayMessage {
  id: string;
  type:
    | "user"
    | "assistant"
    | "tool_result"
    | "system"
    | "result"
    | "summary"
    | "rate_limit"
    | "compact_boundary";
  /** System message subtype — routes to the correct view component. */
  subtype?:
    | "init"
    | "status"
    | "compact_boundary"
    | "task_lifecycle"
    | "control_response"
    | "stop_hook_summary"
    | "stderr"
    | "parse_error";
  content: AssistantContentBlock[];
  toolResults?: Map<string, ToolResult>;
  model?: string;
  pending?: boolean;
  // In-progress streaming content blocks (text/tool_use/thinking being received)
  streamingBlocks?: StreamingBlock[];
  // Additional metadata for richer display
  isSidechain?: boolean;
  isSynthetic?: boolean;
  isMeta?: boolean;
  isSteering?: boolean;
  isCompactSummary?: boolean;
  parentToolUseId?: string | null;
  /** Bumped when a nested child message under this message's tool_use blocks changes. */
  nestedVersion?: number;
  usage?: { input_tokens: number; output_tokens: number };
  // Result message fields
  resultData?: {
    subtype: string;
    isError: boolean;
    result?: string;
    numTurns: number;
    durationMs: number;
    durationApiMs?: number;
    totalCostUsd: number;
    usage: { input_tokens: number; output_tokens: number };
    modelUsage?: Record<string, Record<string, unknown>>;
    permissionDenials?: unknown[];
    stopReason?: string | null;
    errors?: string[];
  };
  // Rate limit fields
  rateLimitInfo?: {
    status?: string;
    rateLimitType?: string;
    resetsAt?: number;
    overageStatus?: string;
    overageDisabledReason?: string;
  };
  // Compact boundary fields
  compactMetadata?: {
    trigger?: string;
    preTokens?: number;
  };
  // System status
  statusText?: string;
  // Monotonic counter for assigning creation order to streaming blocks
  nextCreationOrder?: number;
  // Original wire-protocol message(s) for "view source"
  rawSource?: unknown;
  /** Backend history sequence number(s) for on-demand raw source fetching. */
  seq?: number | number[];
  /** Extra/unknown fields from the wire protocol, surfaced in the UI. */
  extraFields?: Record<string, unknown>;
  /** Claude Code message UUID — drives fork/undo/edit buttons. */
  uuid?: string;
}

export type ToolResultContent =
  | string
  | Array<{ type: string; text?: string; [key: string]: unknown }>;

export interface ToolResult {
  toolUseId: string;
  content: ToolResultContent;
  isError?: boolean;
  // opaque tool result payload — varies by tool, rendered via ToolCall dispatch
  toolResult?: unknown;
}

export type FileEditOp = "add" | "update" | "delete" | "edit" | "write";

export type FileEditStatus = "pending" | "applied" | "cancelled";

export type FileEditSource =
  | "claude-tool"
  | "codex-fileChange"
  | "codex-apply_patch-history";

export type FileChangePayload =
  | { mode: "full_content"; content: string }
  | { mode: "patch_text"; patchText: string }
  | { mode: "none" };

/** A single edit operation on a file, linked to a tool call.
 *  Stores only lightweight metadata; file content is resolved on-demand
 *  via resolveEditContent() to avoid memory overhead when the viewer is closed. */
export interface FileEdit {
  toolUseId: string; // links to the tool_use block ID
  messageId: string; // DisplayMessage.id for scroll-to
  filePath: string;
  type: "edit" | "write";
  op?: FileEditOp;
  status?: FileEditStatus;
  payload?: FileChangePayload;
  source?: FileEditSource;
  changeIndex?: number;
  turnId?: string;
}

/** Accumulated state for a single tracked file. */
export interface TrackedFile {
  path: string;
  edits: FileEdit[];
}

export interface StreamingBlock {
  itemId: string; // ID-based lookup for item/* protocol
  type: string; // "text" | "tool_use" | "thinking"
  text: string; // accumulated text/input_json so far
  name?: string; // tool name for tool_use blocks
  input?: unknown; // initial input (from item/started, for tool_use)
  output?: string; // accumulated output (for output_delta)
  creationOrder: number; // monotonic counter for preserving creation order
}

export interface SessionInfo {
  model: string;
  version: string;
  sessionId: string;
  cwd: string;
  tools: string[];
  permission_mode: string;
  mcp_servers?: unknown[];
  agents?: unknown[];
  api_key_source?: string;
  skills?: string[];
  plugins?: unknown[];
  fast_mode_state?: string;
  agent?: string; // "claude" | "codex" | undefined
  supports_file_revert?: boolean;
}

export interface TaskState {
  tid: number;
  status: string; // pending, active, completed, failed
  messages: DisplayMessage[];
  sessionInfo: SessionInfo | null;
  isProcessing: boolean;
  needsAttention: boolean;
  hasPendingQuestion: boolean;
  totalCost: number;
  alive: boolean;
  resumable: boolean;
  msgIdCounter: number;
  title?: string;
  /** Whether the task's JSONL history has been loaded from the backend. */
  historyLoaded: boolean;
  /** User message texts from before a reload, not yet matched by file replay. */
  preReloadDrafts?: string[];
  /** Confirmed user texts accumulated during history replay (cleared at history_end). */
  confirmedDuringReplay?: string[];
  /** Recovered draft text to inject into the input box once after a reload. */
  inputDraft?: string;
  workspace?: string;
  projectPath?: string;
  /** Parent task ID (0 or undefined = no parent). */
  parentTid?: number;
  /** Relation type to parent (e.g. "fork"). */
  relationType?: string;
  /** UUIDs confirmed in the on-disk JSONL file — only these are forkable. */
  forkableUuids: Set<string>;
  /** Current task type (e.g. "conversation", "plan", "implement"). */
  taskType?: string;
  archived?: boolean;
  /** Stable Preact key for draft tasks (UUID). */
  renderKey?: string;
  /** Last stderr text from non-zero exit; cleared on restart. */
  error?: string;
  /** Task creation timestamp (unix millis), undefined if not set. */
  createdAt?: number;
  /** Last activity timestamp (unix millis), undefined if not set. */
  lastActive?: number;
  /** Pending undo confirmation (set by dry_run preview, cleared on confirm/dismiss). */
  undoPending?: {
    afterUuid: string;
    messagesRemoved: number;
  } | null;
  /** Auto-generated reply suggestions, shown when it's the user's turn. */
  suggestions?: string[];
  /** Server-provided draft for initial hydration on page load. */
  serverDraft?: string;
  /** Pending AskUserQuestion from the agent, waiting for user response. */
  pendingAskUser?: {
    toolUseId: string;
    questions: AskUserQuestionItem[];
  } | null;
  /** Files modified by the agent, keyed by absolute file path. */
  trackedFiles: Map<string, TrackedFile>;
}

export function makeTaskState(
  tid: number,
  alive: boolean = false,
  resumable: boolean = false,
  title?: string,
  historyLoaded: boolean = false,
  workspace?: string,
  projectPath?: string,
  parentTid?: number,
  relationType?: string,
  status: string = "pending",
  isProcessing: boolean = false,
  needsAttention: boolean = false,
  hasPendingQuestion: boolean = false,
  taskType?: string,
  archived: boolean = false,
  createdAt?: number,
  lastActive?: number,
): TaskState {
  return {
    tid,
    status,
    messages: [],
    sessionInfo: null,
    isProcessing,
    needsAttention,
    hasPendingQuestion,
    totalCost: 0,
    alive,
    resumable,
    msgIdCounter: 0,
    title,
    historyLoaded,
    workspace,
    projectPath,
    parentTid,
    relationType,
    forkableUuids: new Set(),
    taskType,
    archived,
    createdAt: createdAt || undefined,
    lastActive: lastActive || undefined,
    trackedFiles: new Map(),
  };
}
