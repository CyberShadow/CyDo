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
  // Original wire-protocol message(s) for "view source"
  rawSource?: unknown;
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

/** A single edit operation on a file, linked to a tool call.
 *  Stores only lightweight metadata; file content is resolved on-demand
 *  via resolveEditContent() to avoid memory overhead when the viewer is closed. */
export interface FileEdit {
  toolUseId: string; // links to the tool_use block ID
  messageId: string; // DisplayMessage.id for scroll-to
  filePath: string;
  type: "edit" | "write";
}

/** Accumulated state for a single tracked file. */
export interface TrackedFile {
  path: string;
  edits: FileEdit[];
}

export interface StreamingBlock {
  index: number;
  type: string;
  text: string;
  name?: string;
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
}

export interface TaskState {
  tid: number;
  status: string; // pending, active, completed, failed
  messages: DisplayMessage[];
  sessionInfo: SessionInfo | null;
  isProcessing: boolean;
  needsAttention: boolean;
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
  taskType?: string,
  archived: boolean = false,
): TaskState {
  return {
    tid,
    status,
    messages: [],
    sessionInfo: null,
    isProcessing,
    needsAttention,
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
    trackedFiles: new Map(),
  };
}
