// Agent-agnostic protocol types.
//
// Agnostic event types are generated from D structs in source/cydo/agent/protocol.d.
// Run `npm run generate` in web/ to regenerate web/src/generated/protocol.ts.

// ---------------------------------------------------------------------------
// Generated event types (re-exported from ./generated/protocol)
// ---------------------------------------------------------------------------

export type {
  ContentBlock,
  UsageInfo,
  ModelUsageInfo,
  CompactMetadata,
  RateLimitInfo,
  ControlResponse,
  SessionInitEvent,
  SessionStatusEvent,
  SessionCompactedEvent,
  TurnResultEvent,
  SessionSummaryEvent,
  SessionRateLimitEvent,
  TaskStartedEvent,
  TaskNotificationEvent,
  ControlResponseEvent,
  ProcessStderrEvent,
  ProcessExitEvent,
  ItemStartedEvent,
  ItemDeltaEvent,
  ItemCompletedEvent,
  ItemResultEvent,
  TurnStopEvent,
  TurnDeltaEvent,
  AgentErrorEvent,
  AgentUnrecognizedEvent,
} from "./generated/protocol";

import type {
  UsageInfo,
  SessionInitEvent,
  SessionStatusEvent,
  SessionCompactedEvent,
  TurnResultEvent,
  SessionSummaryEvent,
  SessionRateLimitEvent,
  TaskStartedEvent,
  TaskNotificationEvent,
  ControlResponseEvent,
  ProcessStderrEvent,
  ProcessExitEvent,
  ItemStartedEvent,
  ItemDeltaEvent,
  ItemCompletedEvent,
  ItemResultEvent,
  TurnStopEvent,
  TurnDeltaEvent,
  AgentErrorEvent,
  AgentUnrecognizedEvent,
} from "./generated/protocol";

// ---------------------------------------------------------------------------
// Backwards-compatible type aliases (old names → generated types)
// ---------------------------------------------------------------------------

export type Usage = UsageInfo;
export type SystemInitMessage = SessionInitEvent;
export type SystemStatusMessage = SessionStatusEvent;
export type SystemCompactBoundaryMessage = SessionCompactedEvent;
export type ResultMessage = TurnResultEvent;
export type SummaryMessage = SessionSummaryEvent;
export type RateLimitEventMessage = SessionRateLimitEvent;
export type SystemTaskStartedMessage = TaskStartedEvent;
export type SystemTaskNotificationMessage = TaskNotificationEvent;
export type ControlResponseMessage = ControlResponseEvent;
export type ExitMessage = ProcessExitEvent;
export type StderrMessage = ProcessStderrEvent;

// ---------------------------------------------------------------------------
// Hand-written types: not generated (no corresponding D struct)
// ---------------------------------------------------------------------------

export interface AssistantContentBlock {
  type: string;
  text?: string;
  id?: string;
  name?: string;
  tool_server?: string;
  tool_source?: string;
  input?: unknown;
  caller?: { type: string; tool_id?: string };
  extras?: Record<string, unknown>;
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

// JSONL-only system events (no corresponding D struct)
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

// ---------------------------------------------------------------------------
// Union event types
// ---------------------------------------------------------------------------

// Agent-agnostic event union (live stream + JSONL history)
export type AgnosticEvent =
  | SessionInitEvent
  | SessionStatusEvent
  | SessionCompactedEvent
  | SystemApiErrorMessage
  | SystemTurnDurationMessage
  | SystemStopHookSummaryMessage
  | TaskStartedEvent
  | TaskNotificationEvent
  | TurnResultEvent
  | SessionSummaryEvent
  | SessionRateLimitEvent
  | ItemStartedEvent
  | ItemDeltaEvent
  | ItemCompletedEvent
  | ItemResultEvent
  | TurnDeltaEvent
  | TurnStopEvent
  | ControlResponseEvent
  | ProcessExitEvent
  | ProcessStderrEvent
  | AgentErrorEvent
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
    stdinClosed?: boolean;
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
    entry_point?: string;
    agent_type?: string;
    archived?: boolean;
    archiving?: boolean;
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
    stdinClosed?: boolean;
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
    entry_point?: string;
    agent_type?: string;
    archived?: boolean;
    archiving?: boolean;
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
export interface FocusHintMessage {
  type: "focus_hint";
  from_tid: number;
  to_tid: number;
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
    projects: {
      name: string;
      path: string;
      virtual?: boolean;
      exists?: boolean;
    }[];
    default_agent_type?: string;
    default_task_type?: string;
  }[];
}
export interface TaskTypesListMessage {
  type: "task_types_list";
  entry_points: {
    name: string;
    task_type: string;
    description: string;
    model_class: string;
    read_only: boolean;
    icon?: string;
  }[];
  type_info: {
    name: string;
    icon?: string;
  }[];
  default_task_type?: string;
}
export interface ProjectTaskTypesListMessage {
  type: "project_task_types_list";
  project_path: string;
  entry_points: {
    name: string;
    task_type: string;
    description: string;
    model_class: string;
    read_only: boolean;
    icon?: string;
  }[];
  type_info: {
    name: string;
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
export interface AssignUuidsMessage {
  type: "assign_uuids";
  tid: number;
  assignments: Array<{ uuid: string; seq: number }>;
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
export interface UndoResultMessage {
  type: "undo_result";
  tid: number;
  output: string;
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
export interface PermissionPromptControlMessage {
  type: "permission_prompt";
  tid: number;
  tool_use_id: string;
  tool_name: string;
  input: Record<string, unknown>;
}
export interface DraftUpdatedMessage {
  type: "draft_updated";
  tid: number;
  new_draft: string;
}
export interface ServerStatusMessage {
  type: "server_status";
  auth_enabled: boolean;
  dev_mode?: boolean;
}
export interface TaskDeletedMessage {
  type: "task_deleted";
  tid: number;
}
export interface Notice {
  level: "info" | "warning" | "alert";
  description: string;
  impact: string;
  action: string;
}
export interface NoticesListMessage {
  type: "notices_list";
  notices: Record<string, Notice>;
}
export type ControlMessage =
  | TaskCreatedMessage
  | TasksListMessage
  | TaskUpdatedMessage
  | TaskReloadMessage
  | FocusHintMessage
  | TitleUpdateMessage
  | TaskHistoryEndMessage
  | WorkspacesListMessage
  | TaskTypesListMessage
  | ProjectTaskTypesListMessage
  | AgentTypesListMessage
  | ForkableUuidsMessage
  | AssignUuidsMessage
  | ErrorMessage
  | UndoPreviewMessage
  | UndoResultMessage
  | SuggestionsUpdateMessage
  | AskUserQuestionControlMessage
  | PermissionPromptControlMessage
  | DraftUpdatedMessage
  | ServerStatusMessage
  | TaskDeletedMessage
  | NoticesListMessage;
