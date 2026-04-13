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

export interface CompactMetadata {
  trigger?: string;
  pre_tokens?: number;
}

export interface RateLimitInfo {
  status?: string;
  rateLimitType?: string;
  resetsAt?: number;
  overageStatus?: string;
  overageDisabledReason?: string;
  [key: string]: unknown;
}

export interface ControlResponse {
  subtype?: string;
  request_id?: string;
  [key: string]: unknown;
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
  api_key_source?: string;
  fast_mode_state?: string;
  skills?: string[];
  mcp_servers?: unknown[];
  agents?: unknown[];
  plugins?: unknown[];
  supports_file_revert: boolean;
  extras?: Record<string, unknown>;
}

export interface SessionStatusEvent {
  type: "session/status";
  status?: string;
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
  model_usage?: unknown;
  permission_denials?: unknown[];
  stop_reason?: string;
  errors?: string[];
  extras?: Record<string, unknown>;
}

export interface SessionSummaryEvent {
  type: "session/summary";
  summary: string;
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
  isCompactSummary?: boolean;
  parent_tool_use_id?: string;
  is_sidechain?: boolean;
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

export interface TurnStopEvent {
  type: "turn/stop";
  model?: string;
  usage?: UsageInfo;
  parent_tool_use_id?: string;
  is_sidechain?: boolean;
  uuid?: string;
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

export interface AgentErrorEvent {
  type: "agent/error";
  message: string;
  willRetry?: boolean;
}

export interface AgentUnrecognizedEvent {
  type: "agent/unrecognized";
  reason: string;
}

