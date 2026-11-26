// Agent-agnostic protocol types.
//
// Agnostic event types are generated from D structs in source/cydo/agent/protocol.d.
// Run `npm run generate` in web/ to regenerate web/src/generated/protocol.ts.

// ---------------------------------------------------------------------------
// Generated event types (re-exported from ./generated/protocol)
// ---------------------------------------------------------------------------

export type {
  BrowserSubmissionRejectionKind,
  BrowserSubmissionRejectedEvent,
  ContentBlock,
  HistoryBoundary,
  UsageInfo,
  ModelUsageInfo,
  CompactMetadata,
  RateLimitInfo,
  ControlResponse,
  SessionInitEvent,
  SessionMetadataEvent,
  SessionStatusEvent,
  SessionCompactedEvent,
  TurnResultEvent,
  TurnEndReason,
  ItemDenier,
  ItemPermissionStage,
  SessionSummaryEvent,
  SessionCostEvent,
  SessionRateLimitEvent,
  TaskStartedEvent,
  TaskNotificationEvent,
  TaskUpdatedEvent,
  TurnRetractedEvent,
  ControlResponseEvent,
  ProcessStderrEvent,
  ProcessExitEvent,
  TaskDiagnosticEvent,
  AgentNoticeEvent,
  CommandOutputEvent,
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
  AgentUnrecognizedEvent,
  CydoItemEnrichedEvent,
} from "./generated/protocol";

import type {
  BrowserSubmissionRejectedEvent,
  UsageInfo,
  SessionInitEvent,
  SessionMetadataEvent,
  SessionStatusEvent,
  SessionCompactedEvent,
  TurnResultEvent,
  SessionSummaryEvent,
  SessionCostEvent,
  SessionRateLimitEvent,
  TaskStartedEvent,
  TaskNotificationEvent,
  TaskUpdatedEvent,
  TurnRetractedEvent,
  ControlResponseEvent,
  ProcessStderrEvent,
  ProcessExitEvent,
  TaskDiagnosticEvent,
  AgentNoticeEvent,
  CommandOutputEvent,
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
  AgentUnrecognizedEvent,
  CydoItemEnrichedEvent,
} from "./generated/protocol";
import type { TaskStatus } from "./types";

// ---------------------------------------------------------------------------
// Backwards-compatible type aliases (old names → generated types)
// ---------------------------------------------------------------------------

export type Usage = UsageInfo;
export type SystemInitMessage = SessionInitEvent;
export type SystemMetadataMessage = SessionMetadataEvent;
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
  | SessionMetadataEvent
  | SessionStatusEvent
  | SessionCompactedEvent
  | SystemStopHookSummaryMessage
  | TaskStartedEvent
  | TaskNotificationEvent
  | TaskUpdatedEvent
  | TurnRetractedEvent
  | TurnResultEvent
  | SessionSummaryEvent
  | SessionCostEvent
  | SessionRateLimitEvent
  | ItemStartedEvent
  | ItemDeltaEvent
  | ItemAbandonedEvent
  | ItemCompletedEvent
  | ItemResultEvent
  | ItemDeniedEvent
  | ItemPermissionEvent
  | TurnDeltaEvent
  | TurnStopEvent
  | UserMessageConsumedEvent
  | ControlResponseEvent
  | ProcessExitEvent
  | TaskDiagnosticEvent
  | AgentNoticeEvent
  | CommandOutputEvent
  | ProcessStderrEvent
  | AgentUnrecognizedEvent
  | CydoItemEnrichedEvent;

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
export interface TaskListEntry {
  tid: number;
  alive: boolean;
  resumable: boolean;
  isProcessing: boolean;
  stdinClosed?: boolean;
  canStop?: boolean;
  needsAttention?: boolean;
  hasPendingQuestion?: boolean;
  notificationBody?: string;
  title?: string;
  workspace?: string;
  project_path?: string;
  parent_tid?: number;
  child_count: number;
  relation_type?: string;
  creator_tid?: number;
  status?: TaskStatus;
  task_type?: string;
  entry_point?: string;
  agent_name?: string;
  driver?: string;
  usage_profile?: string | null;
  archived?: boolean;
  archiving?: boolean;
  draft?: string;
  error?: string;
  created_at?: number;
  last_active?: number;
}
export interface TasksListMessage {
  type: "tasks_list";
  complete: boolean;
  tasks: TaskListEntry[];
}
export interface TaskUpdatedMessage {
  type: "task_updated";
  task: TaskListEntry;
}
export interface TaskReloadMessage {
  type: "task_reload";
  tid: number;
  reason?: string;
  /** Native user UUID deleted by a successful continuation-history repair. */
  excluded_user_uuid?: string | null;
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
export interface TaskHistoryStartMessage {
  type: "task_history_start";
  tid: number;
  total: number;
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
    default_agent?: string;
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
    model_classes?: Record<string, string>;
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
    model_classes?: Record<string, string>;
    read_only: boolean;
    icon?: string;
  }[];
  type_info: {
    name: string;
    icon?: string;
  }[];
}
export interface AgentsListMessage {
  type: "agents_list";
  agents: {
    name: string;
    driver: string;
    display_name?: string;
    is_available?: boolean;
  }[];
  default_agent?: string;
}
export type HistoryOperationMechanism =
  | "jsonl"
  | "codex_native"
  | "claude_native";
export interface HistoryOperationKinds {
  user?: HistoryOperationMechanism;
  /** The conversation's first user message. */
  first_user?: HistoryOperationMechanism;
  provisional_user?: HistoryOperationMechanism;
  agent_turn?: HistoryOperationMechanism;
}
export interface HistoryOperations {
  fork: HistoryOperationKinds;
  undo: HistoryOperationKinds;
  edit_message?: boolean;
  edit_raw_event?: boolean;
}
export interface HistoryOperationsMessage {
  type: "history_operations";
  tid: number;
  history_operations: HistoryOperations;
}
export interface ErrorMessage {
  type: "error";
  message: string;
  tid?: number;
  operation?: "undo_preview";
}
export type UndoCountUnit = "codex_turns" | "history_entries";
export interface UndoPreviewMessage {
  type: "undo_preview";
  tid: number;
  messages_removed: number;
  count_unit: UndoCountUnit;
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
  /** Why the agent's own safety checks flag the call, if they do. */
  reason?: string;
  /** When CyDo denies the call unanswered (Unix ms); absent: never. */
  expires_at?: number;
}
export interface DraftUpdatedMessage {
  type: "draft_updated";
  tid: number;
  old_draft: string;
  new_draft: string;
  correlation_id?: string;
}
export interface UsageUiConfig {
  coloring: "pace" | "percent";
  remaining: boolean;
}

export interface SidebarUiConfig {
  sort?: "creation" | "activity";
  order?: "oldest_first" | "newest_first";
}

export interface UiConfig {
  sidebar?: SidebarUiConfig;
  usage?: UsageUiConfig;
}

export interface HeicConversionStatus {
  available: boolean;
  reason?: string;
}

export interface ServerStatusMessage {
  type: "server_status";
  ui: UiConfig;
  heic_conversion: HeicConversionStatus;
  auth_enabled: boolean;
  dev_mode?: boolean;
  build_id?: string;
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
  action_kind?: string;
}
export interface NoticesListMessage {
  type: "notices_list";
  notices: Record<string, Notice>;
}
export interface AgentUsageLimitWindow {
  utilization?: number;
  resetsAt?: number;
  status?: string;
}
export interface AgentUsageMessage {
  type: "agent_usage";
  profile: string;
  updated_at: number;
  limits: Record<string, AgentUsageLimitWindow>;
  model_weekly?: { label: string; utilization?: number; resetsAt?: number }[];
  /** When the account login ends for good (ISO 8601). */
  credential_expires_at?: string;
}
export interface ScanStatusMessage {
  type: "scan_status";
  scanning: boolean;
}
export type ControlMessage =
  | TaskCreatedMessage
  | TasksListMessage
  | TaskUpdatedMessage
  | TaskReloadMessage
  | FocusHintMessage
  | TitleUpdateMessage
  | TaskHistoryStartMessage
  | TaskHistoryEndMessage
  | WorkspacesListMessage
  | TaskTypesListMessage
  | ProjectTaskTypesListMessage
  | AgentsListMessage
  | HistoryOperationsMessage
  | BrowserSubmissionRejectedEvent
  | ErrorMessage
  | UndoPreviewMessage
  | UndoResultMessage
  | SuggestionsUpdateMessage
  | AskUserQuestionControlMessage
  | PermissionPromptControlMessage
  | DraftUpdatedMessage
  | ServerStatusMessage
  | TaskDeletedMessage
  | NoticesListMessage
  | AgentUsageMessage
  | ScanStatusMessage;
