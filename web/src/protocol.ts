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

export type ContentBlock =
  | { type: "text"; text: string }
  | { type: "image"; data: string; media_type: string };

export interface AssistantContentBlock {
  type: string;
  text?: string;
  id?: string;
  name?: string;
  tool_server?: string;
  tool_source?: string;
  input?: Record<string, unknown>;
  caller?: { type: string; tool_id?: string };
  _extras?: Record<string, unknown>;
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
  _extras?: Record<string, unknown>;
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

export interface ItemStartedEvent {
  type: "item/started";
  item_id: string;
  item_type: "text" | "thinking" | "tool_use" | "user_message";
  name?: string;
  tool_server?: string;
  tool_source?: string;
  input?: Record<string, unknown>;
  text?: string;
  content?: ContentBlock[];
  is_replay?: boolean;
  is_synthetic?: boolean;
  is_meta?: boolean;
  is_steering?: boolean;
  pending?: boolean;
  uuid?: string;
  isCompactSummary?: boolean;
  parent_tool_use_id?: string;
  is_sidechain?: boolean;
  _extras?: Record<string, unknown>;
  [key: string]: unknown;
}

export interface ItemDeltaEvent {
  type: "item/delta";
  item_id: string;
  delta_type:
    | "text_delta"
    | "thinking_delta"
    | "input_json_delta"
    | "output_delta"
    | "stdin_delta";
  content: string;
  [key: string]: unknown;
}

export interface ItemCompletedEvent {
  type: "item/completed";
  item_id: string;
  text?: string;
  input?: Record<string, unknown>;
  output?: string;
  is_error?: boolean;
  _extras?: Record<string, unknown>;
  [key: string]: unknown;
}

export interface ItemResultEvent {
  type: "item/result";
  item_id: string;
  content: string | UserContentBlock[];
  is_error?: boolean;
  tool_result?: unknown;
  _extras?: Record<string, unknown>;
  [key: string]: unknown;
}

export interface TurnStopEvent {
  type: "turn/stop";
  model?: string;
  usage?: Usage;
  parent_tool_use_id?: string;
  is_sidechain?: boolean;
  is_api_error?: boolean;
  uuid?: string;
  _extras?: Record<string, unknown>;
  [key: string]: unknown;
}

export interface TurnDeltaEvent {
  type: "turn/delta";
  model?: string;
  usage?: Usage;
  parent_tool_use_id?: string;
  is_sidechain?: boolean;
  is_api_error?: boolean;
  uuid?: string;
  _extras?: Record<string, unknown>;
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
  is_continuation?: boolean;
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

export interface SystemStopHookSummaryMessage {
  type: "system";
  subtype: "stop_hook_summary";
  hookCount: number;
  hookInfos: Array<{
    command: string;
    durationMs: number;
    [key: string]: unknown;
  }>;
  hookErrors: Array<unknown>;
  preventedContinuation: boolean;
  hasOutput: boolean;
  [key: string]: unknown;
}

export interface AgentUnrecognizedEvent {
  type: "agent/unrecognized";
  reason: string;
  raw_content: unknown;
}

// ---------------------------------------------------------------------------
// Union event types
// ---------------------------------------------------------------------------

// Agent-agnostic event union (live stream + JSONL history)
export type AgnosticEvent =
  | SystemInitMessage
  | SystemStatusMessage
  | SystemCompactBoundaryMessage
  | SystemApiErrorMessage
  | SystemTurnDurationMessage
  | SystemStopHookSummaryMessage
  | SystemTaskStartedMessage
  | SystemTaskNotificationMessage
  | ResultMessage
  | SummaryMessage
  | RateLimitEventMessage
  | ItemStartedEvent
  | ItemDeltaEvent
  | ItemCompletedEvent
  | ItemResultEvent
  | TurnDeltaEvent
  | TurnStopEvent
  | ControlResponseMessage
  | ExitMessage
  | StderrMessage
  | AgentUnrecognizedEvent;

export type TaskMessage = { tid: number; event: AgnosticEvent };

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
    hasPendingQuestion?: boolean;
    notificationBody?: string;
    title?: string;
    workspace?: string;
    project_path?: string;
    parent_tid?: number;
    relation_type?: string;
    status?: string;
    task_type?: string;
    agent_type?: string;
    archived?: boolean;
    draft?: string;
    error?: string;
    created_at?: number;
    last_active?: number;
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
    hasPendingQuestion?: boolean;
    notificationBody?: string;
    title?: string;
    workspace?: string;
    project_path?: string;
    parent_tid?: number;
    relation_type?: string;
    status?: string;
    task_type?: string;
    agent_type?: string;
    archived?: boolean;
    draft?: string;
    error?: string;
    created_at?: number;
    last_active?: number;
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
    default_agent_type?: string;
  }[];
}
export interface TaskTypesListMessage {
  type: "task_types_list";
  entry_points: {
    name: string;
    task_type: string;
    display_name?: string;
    description: string;
    model_class: string;
    read_only: boolean;
    icon?: string;
  }[];
  type_info: {
    name: string;
    display_name?: string;
    icon?: string;
  }[];
}
export interface AgentTypesListMessage {
  type: "agent_types_list";
  agent_types: {
    name: string;
    display_name?: string;
    is_available?: boolean;
  }[];
  default_agent_type?: string;
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
export interface ServerStatusMessage {
  type: "server_status";
  auth_enabled: boolean;
}
export interface TaskDeletedMessage {
  type: "task_deleted";
  tid: number;
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
  | AgentTypesListMessage
  | ForkableUuidsMessage
  | ErrorMessage
  | UndoPreviewMessage
  | SuggestionsUpdateMessage
  | AskUserQuestionControlMessage
  | DraftUpdatedMessage
  | ServerStatusMessage
  | TaskDeletedMessage;
