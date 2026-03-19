// Agent-agnostic protocol types.
//
// Plain TypeScript interfaces — no runtime validation.  The backend is
// trusted to emit well-formed events.

// ---------------------------------------------------------------------------
// Nested types
// ---------------------------------------------------------------------------

export interface Usage {
  input_tokens: number;
  output_tokens: number;
  [key: string]: unknown;
}

export interface AssistantContentBlock {
  type: string;
  text?: string;
  id?: string;
  name?: string;
  input?: Record<string, unknown>;
  caller?: { type: string; tool_id?: string };
  [key: string]: unknown;
}

export interface UserContentBlock {
  type: string;
  text?: string;
  tool_use_id?: string;
  content?: unknown;
  is_error?: boolean;
  [key: string]: unknown;
}

export interface ContentDelta {
  type: string;
  text?: string;
  partial_json?: string;
  [key: string]: unknown;
}

// ---------------------------------------------------------------------------
// Live stream (stdout) event types
// ---------------------------------------------------------------------------

export interface SystemInitMessage {
  type: "session/init";
  session_id: string;
  model: string;
  cwd: string;
  tools: string[];
  agent_version: string;
  permission_mode: string;
  mcp_servers?: unknown[];
  agents?: unknown[];
  api_key_source?: string;
  skills?: string[];
  plugins?: unknown[];
  fast_mode_state?: string;
  agent?: string;
  supports_file_revert?: boolean;
  [key: string]: unknown;
}

export interface SystemStatusMessage {
  type: "session/status";
  status?: string | null;
  [key: string]: unknown;
}

export interface SystemCompactBoundaryMessage {
  type: "session/compacted";
  compact_metadata?: {
    trigger?: string;
    pre_tokens?: number;
    [key: string]: unknown;
  };
  [key: string]: unknown;
}

export interface SystemTaskStartedMessage {
  type: "task/started";
  task_id: string;
  tool_use_id?: string;
  description?: string;
  task_type?: string;
  [key: string]: unknown;
}

export interface SystemTaskNotificationMessage {
  type: "task/notification";
  task_id: string;
  status: string;
  output_file?: string;
  summary?: string;
  [key: string]: unknown;
}

export interface AssistantMessage {
  type: "message/assistant";
  id: string;
  content: AssistantContentBlock[];
  model: string;
  stop_reason: string | null;
  usage?: Usage;
  parent_tool_use_id?: string | null;
  is_sidechain?: boolean;
  is_api_error?: boolean;
  uuid?: string;
  [key: string]: unknown;
}


export interface UserEchoMessage {
  type: "message/user";
  content: string | UserContentBlock[];
  parent_tool_use_id?: string | null;
  is_sidechain?: boolean;
  tool_result?: unknown;
  is_replay?: boolean;
  is_synthetic?: boolean;
  is_meta?: boolean;
  is_steering?: boolean;
  pending?: boolean;
  uuid?: string;
  isCompactSummary?: boolean;
  isVisibleInTranscriptOnly?: boolean;
  [key: string]: unknown;
}


export interface ResultMessage {
  type: "turn/result";
  subtype: string;
  is_error: boolean;
  result?: string;
  num_turns: number;
  duration_ms: number;
  duration_api_ms?: number;
  total_cost_usd: number;
  usage: Usage;
  model_usage?: Record<string, Record<string, unknown>>;
  permission_denials?: unknown[];
  stop_reason?: string | null;
  errors?: string[];
  [key: string]: unknown;
}

export interface SummaryMessage {
  type: "session/summary";
  summary: string;
  [key: string]: unknown;
}

export interface RateLimitEventMessage {
  type: "session/rate_limit";
  rate_limit_info: {
    status?: string;
    rateLimitType?: string;
    resetsAt?: number;
    overageStatus?: string;
    overageDisabledReason?: string;
    [key: string]: unknown;
  };
  [key: string]: unknown;
}

export interface StreamBlockStart {
  type: "stream/block_start";
  index: number;
  content_block: {
    type: string;
    id?: string;
    name?: string;
    [key: string]: unknown;
  };
  [key: string]: unknown;
}

export interface StreamBlockDelta {
  type: "stream/block_delta";
  index: number;
  delta: ContentDelta;
  [key: string]: unknown;
}

export interface StreamBlockStop {
  type: "stream/block_stop";
  index: number;
  [key: string]: unknown;
}

export interface StreamTurnStop {
  type: "stream/turn_stop";
  [key: string]: unknown;
}

export interface ControlResponseMessage {
  type: "control/response";
  response: {
    subtype: string;
    request_id?: string;
    [key: string]: unknown;
  };
  [key: string]: unknown;
}

export interface ExitMessage {
  type: "process/exit";
  code: number;
  [key: string]: unknown;
}

export interface StderrMessage {
  type: "process/stderr";
  text: string;
  [key: string]: unknown;
}

// ---------------------------------------------------------------------------
// JSONL-only types (pass through unchanged)
// ---------------------------------------------------------------------------

export interface SystemApiErrorMessage {
  type: "system";
  subtype: "api_error";
  level?: string;
  retryInMs?: number;
  retryAttempt?: number;
  maxRetries?: number;
  [key: string]: unknown;
}

export interface SystemTurnDurationMessage {
  type: "system";
  subtype: "turn_duration";
  durationMs: number;
  [key: string]: unknown;
}

// ---------------------------------------------------------------------------
// Union event types
// ---------------------------------------------------------------------------

// Agent-agnostic event union (live stream)
export type AgnosticEvent =
  | SystemInitMessage
  | SystemStatusMessage
  | SystemCompactBoundaryMessage
  | SystemTaskStartedMessage
  | SystemTaskNotificationMessage
  | AssistantMessage
  | UserEchoMessage
  | ResultMessage
  | SummaryMessage
  | RateLimitEventMessage
  | StreamBlockStart
  | StreamBlockDelta
  | StreamBlockStop
  | StreamTurnStop
  | ControlResponseMessage
  | ExitMessage
  | StderrMessage;

// File message union (translated + pass-through JSONL-only types)
export type AgnosticFileEvent =
  | SystemInitMessage
  | SystemStatusMessage
  | SystemCompactBoundaryMessage
  | SystemApiErrorMessage
  | SystemTurnDurationMessage
  | SystemTaskStartedMessage
  | SystemTaskNotificationMessage
  | AssistantMessage
  | UserEchoMessage
  | ResultMessage
  | SummaryMessage
  | RateLimitEventMessage
  | { type: "progress"; [key: string]: unknown }
  | { type: "queue-operation"; [key: string]: unknown }
  | { type: "file-history-snapshot"; [key: string]: unknown };

export type TaskMessage = { tid: number; event: AgnosticEvent };
export type FileMessage = { tid: number; fileEvent: AgnosticFileEvent };

// Control messages from our backend (not Claude Code) — plain interfaces
export interface TaskCreatedMessage {
  type: "task_created";
  tid: number;
  workspace?: string;
  project_path?: string;
  parent_tid?: number;
  relation_type?: string;
  correlation_id?: string;
}
export interface TasksListMessage {
  type: "tasks_list";
  tasks: {
    tid: number;
    alive: boolean;
    resumable: boolean;
    isProcessing: boolean;
    needsAttention?: boolean;
    notificationBody?: string;
    title?: string;
    workspace?: string;
    project_path?: string;
    parent_tid?: number;
    relation_type?: string;
    status?: string;
    task_type?: string;
    archived?: boolean;
    draft?: string;
  }[];
}
export interface TaskUpdatedMessage {
  type: "task_updated";
  task: {
    tid: number;
    alive: boolean;
    resumable: boolean;
    isProcessing: boolean;
    needsAttention?: boolean;
    notificationBody?: string;
    title?: string;
    workspace?: string;
    project_path?: string;
    parent_tid?: number;
    relation_type?: string;
    status?: string;
    task_type?: string;
    archived?: boolean;
    draft?: string;
  };
}
export interface TaskReloadMessage {
  type: "task_reload";
  tid: number;
  reason?: string;
}
export interface TitleUpdateMessage {
  type: "title_update";
  tid: number;
  title: string;
}
export interface TaskHistoryEndMessage {
  type: "task_history_end";
  tid: number;
}
export interface WorkspacesListMessage {
  type: "workspaces_list";
  workspaces: {
    name: string;
    projects: { name: string; path: string }[];
  }[];
}
export interface TaskTypesListMessage {
  type: "task_types_list";
  task_types: {
    name: string;
    display_name?: string;
    description: string;
    model_class: string;
    read_only: boolean;
    icon?: string;
    user_visible?: boolean;
  }[];
}
export interface ForkableUuidsMessage {
  type: "forkable_uuids";
  tid: number;
  uuids: string[];
}
export interface ErrorMessage {
  type: "error";
  message: string;
  tid?: number;
}
export interface UndoPreviewMessage {
  type: "undo_preview";
  tid: number;
  messages_removed: number;
}
export interface SuggestionsUpdateMessage {
  type: "suggestions_update";
  tid: number;
  suggestions: string[];
}
export interface AskUserQuestionOption {
  label: string;
  description: string;
}

export interface AskUserQuestionItem {
  header: string;
  question: string;
  options: AskUserQuestionOption[];
  multiSelect?: boolean;
}

export interface AskUserQuestionControlMessage {
  type: "ask_user_question";
  tid: number;
  tool_use_id: string;
  questions: AskUserQuestionItem[];
}
export interface DraftUpdatedMessage {
  type: "draft_updated";
  tid: number;
  new_draft: string;
}
export type ControlMessage =
  | TaskCreatedMessage
  | TasksListMessage
  | TaskUpdatedMessage
  | TaskReloadMessage
  | TitleUpdateMessage
  | TaskHistoryEndMessage
  | WorkspacesListMessage
  | TaskTypesListMessage
  | ForkableUuidsMessage
  | ErrorMessage
  | UndoPreviewMessage
  | SuggestionsUpdateMessage
  | AskUserQuestionControlMessage
  | DraftUpdatedMessage;
