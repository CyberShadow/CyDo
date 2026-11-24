export type TurnEndReason = "unspecified" | "completed" | "interrupted" | "hook_stopped" | "context_limit" | "max_turns" | "auto_mode_stopped";

export type TaskDiagnosticSeverity = "info" | "warning" | "error";

export type BrowserSubmissionRejectionKind = "validation" | "task_unavailable" | "task_archiving" | "native_undo_refused" | "history_cancelled" | "delivery_failed";

export type ItemDenier = "classifier" | "settingsRule" | "backgroundAgent";

export type ItemPermissionStage = "asked" | "answered" | "accepted" | "withdrawn";

export interface ContentBlock {
  type: string;
  text?: string;
  id?: string;
  name?: string;
  input?: unknown;
  data?: string;
  media_type?: string;
  extras?: Record<string, unknown>;
}

export interface UsageInfo {
  input_tokens: number;
  output_tokens: number;
}

export interface ModelUsageInfo {
  input_tokens?: number;
  output_tokens?: number;
  [key: string]: unknown;
}

export interface CompactMetadata {
  trigger?: string;
  pre_tokens?: number;
}

export interface RateLimitInfo {
  status?: string;
  rateLimitType?: string;
  resetsAt?: number;
  utilization?: number;
  overageStatus?: string;
  overageResetsAt?: number;
  overageDisabledReason?: string;
  isUsingOverage?: boolean;
  surpassedThreshold?: number;
  [key: string]: unknown;
}

export interface ControlResponse {
  subtype?: string;
  request_id?: string;
  [key: string]: unknown;
}

export interface HistoryBoundary {
  anchor: string;
  kind: "user" | "provisional_user" | "agent_turn";
  checkpoint_uuid?: string;
}

export interface RequestHistory {
  type: "request_history";
  tid: number;
  workspace?: string;
}

export interface SessionInitEvent {
  type: "session/init";
  session_id: string;
  model: string;
  cwd: string;
  tools: string[];
  agent_version: string;
  permission_mode: string;
  agent?: string;
  agent_name?: string;
  api_key_source?: string;
  fast_mode_state?: string;
  skills?: string[];
  mcp_servers?: unknown[];
  agents?: unknown[];
  plugins?: unknown[];
  supports_file_revert: boolean;
  extras?: Record<string, unknown>;
}

export interface SessionMetadataEvent {
  type: "session/metadata";
  model: string;
}

export interface SessionStatusEvent {
  type: "session/status";
  status?: string;
  permission_mode?: string;
  extras?: Record<string, unknown>;
}

export interface SessionCompactedEvent {
  type: "session/compacted";
  compact_metadata?: CompactMetadata;
}

export interface TurnResultEvent {
  type: "turn/result";
  subtype: string;
  is_error: boolean;
  result?: string;
  num_turns: number;
  duration_ms: number;
  duration_api_ms?: number;
  total_cost_usd: number;
  usage: UsageInfo;
  model_usage?: Record<string, ModelUsageInfo>;
  permission_denials?: unknown[];
  stop_reason?: string;
  errors?: string[];
  end_reason?: TurnEndReason;
  credential_expires_at?: string;
  extras?: Record<string, unknown>;
}

export interface SessionSummaryEvent {
  type: "session/summary";
  summary: string;
}

export interface SessionCostEvent {
  type: "session/cost";
  total_cost_usd: number;
}

export interface SessionRateLimitEvent {
  type: "session/rate_limit";
  rate_limit_info: RateLimitInfo;
}

export interface TaskStartedEvent {
  type: "task/started";
  task_id: string;
  tool_use_id?: string;
  description?: string;
  task_type?: string;
  extras?: Record<string, unknown>;
}

export interface TaskUpdatedEvent {
  type: "task/updated";
  task_id: string;
  status?: string;
  error?: string;
  extras?: Record<string, unknown>;
}

export interface TaskNotificationEvent {
  type: "task/notification";
  task_id: string;
  status: string;
  output_file?: string;
  summary?: string;
  extras?: Record<string, unknown>;
}

export interface ControlResponseEvent {
  type: "control/response";
  response: ControlResponse;
}

export interface ProcessStderrEvent {
  type: "process/stderr";
  text: string;
}

export interface ProcessExitEvent {
  type: "process/exit";
  code: number;
  is_continuation?: boolean;
}

export interface TaskDiagnosticEvent {
  type: "cydo/task_diagnostic";
  severity: TaskDiagnosticSeverity;
  subject: string;
  body: string;
}

export interface AgentNoticeEvent {
  type: "agent/notice";
  severity: TaskDiagnosticSeverity;
  subject: string;
  body: string;
  stdout?: string;
  stderr?: string;
  output?: string;
  collapsible?: boolean;
}

export interface CommandOutputEvent {
  type: "agent/command_output";
  text: string;
}

export interface TurnRetractedEvent {
  type: "turn/retracted";
  uuids: string[];
  notice: TaskDiagnosticEvent;
}

export interface BrowserSubmissionRejectedEvent {
  type: "cydo/submission_rejected";
  correlation_id: string;
  tid?: number;
  kind: BrowserSubmissionRejectionKind;
  reason: string;
}

export interface ItemStartedEvent {
  type: "item/started";
  item_id: string;
  item_type: string;
  name?: string;
  tool_server?: string;
  tool_source?: string;
  input?: unknown;
  text?: string;
  content?: ContentBlock[];
  is_replay?: boolean;
  is_synthetic?: boolean;
  is_meta?: boolean;
  is_steering?: boolean;
  pending?: boolean;
  uuid?: string;
  history_boundary?: HistoryBoundary;
  isCompactSummary?: boolean;
  parent_tool_use_id?: string;
  is_sidechain?: boolean;
  correlation_id?: string;
  extras?: Record<string, unknown>;
}

export interface ItemDeltaEvent {
  type: "item/delta";
  item_id: string;
  delta_type: string;
  content: string;
}

export interface ItemCompletedEvent {
  type: "item/completed";
  item_id: string;
  text?: string;
  input?: unknown;
  output?: string;
  is_error?: boolean;
  is_narration?: boolean;
  extras?: Record<string, unknown>;
}

export interface ItemResultEvent {
  type: "item/result";
  item_id: string;
  content: unknown;
  is_error?: boolean;
  tool_result?: unknown;
  extras?: Record<string, unknown>;
}

export interface ItemDeniedEvent {
  type: "item/denied";
  item_id: string;
  by: ItemDenier;
  reason?: string;
}

export interface ItemPermissionEvent {
  type: "item/permission";
  item_id: string;
  stage: ItemPermissionStage;
}

export interface UserMessageConsumedEvent {
  type: "user_message/consumed";
  uuid: string;
  consumed_as: string;
  correlation_id?: string;
  native_uuid?: string;
}

export interface TurnStopEvent {
  type: "turn/stop";
  model?: string;
  usage?: UsageInfo;
  parent_tool_use_id?: string;
  is_sidechain?: boolean;
  uuid?: string;
  api_block_count?: number;
  history_boundary?: HistoryBoundary;
  extras?: Record<string, unknown>;
}

export interface TurnDeltaEvent {
  type: "turn/delta";
  model?: string;
  usage?: UsageInfo;
  parent_tool_use_id?: string;
  is_sidechain?: boolean;
  uuid?: string;
  extras?: Record<string, unknown>;
}

export interface AgentUnrecognizedEvent {
  type: "agent/unrecognized";
  reason: string;
}

export interface CydoTaskSpawnedEvent {
  type: "cydo/task_spawned";
  child_tid: number;
  spec_index: number;
}

