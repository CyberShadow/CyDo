// Claude Code stream-json protocol schemas (Zod)
//
// Single source of truth for both TypeScript types and runtime known-keys.
// Only fields that are (a) consumed by the UI or (b) explicitly ignored with
// rationale are included.  Everything else surfaces as "extra fields" in the UI.

import { z } from "zod";

// ---------------------------------------------------------------------------
// Leaf / nested schemas
// ---------------------------------------------------------------------------

export const UsageSchema = z.object({
  input_tokens: z.number(),
  output_tokens: z.number(),
  // TODO: review — observed from Anthropic API but not yet consumed by UI
  // cache_creation_input_tokens, cache_read_input_tokens, cache_creation,
  // service_tier, inference_geo
}).passthrough();

// -- Assistant content blocks (discriminated on "type") --

const TextContentBlock = z.object({
  type: z.literal("text"),
  text: z.string(),
}).passthrough();

const ToolUseContentBlock = z.object({
  type: z.literal("tool_use"),
  id: z.string(),
  name: z.string(),
  input: z.record(z.string(), z.unknown()), // opaque — tool inputs are arbitrary JSON
}).passthrough();

const ThinkingContentBlock = z.object({
  type: z.literal("thinking"),
  thinking: z.string(),
  signature: z.string(),
}).passthrough();

export const AssistantContentBlockSchema = z.discriminatedUnion("type", [
  TextContentBlock,
  ToolUseContentBlock,
  ThinkingContentBlock,
]);

// -- User content blocks --

const UserTextBlock = z.object({
  type: z.literal("text"),
  text: z.string(),
}).passthrough();

const UserToolResultBlock = z.object({
  type: z.literal("tool_result"),
  tool_use_id: z.string(),
  content: z.string(),
  is_error: z.boolean().optional(),
}).passthrough();

export const UserContentBlockSchema = z.discriminatedUnion("type", [
  UserTextBlock,
  UserToolResultBlock,
]);

// -- Stream event deltas --

const ThinkingDelta = z.object({
  type: z.literal("thinking_delta"),
  thinking: z.string(),
}).passthrough();

const TextDelta = z.object({
  type: z.literal("text_delta"),
  text: z.string(),
}).passthrough();

const InputJsonDelta = z.object({
  type: z.literal("input_json_delta"),
  partial_json: z.string(),
}).passthrough();

export const ContentDeltaSchema = z.discriminatedUnion("type", [
  ThinkingDelta,
  TextDelta,
  InputJsonDelta,
]);

// -- Stream events --

const MessageStartEvent = z.object({
  type: z.literal("message_start"),
  message: z.object({ model: z.string(), id: z.string() }).passthrough(),
}).passthrough();

const ContentBlockStartEvent = z.object({
  type: z.literal("content_block_start"),
  index: z.number(),
  content_block: z.object({ type: z.string() }).passthrough(),
}).passthrough();

const ContentBlockDeltaEvent = z.object({
  type: z.literal("content_block_delta"),
  index: z.number(),
  delta: ContentDeltaSchema,
}).passthrough();

const ContentBlockStopEvent = z.object({
  type: z.literal("content_block_stop"),
  index: z.number(),
}).passthrough();

const MessageDeltaEvent = z.object({
  type: z.literal("message_delta"),
  delta: z.object({ stop_reason: z.string() }).passthrough(),
}).passthrough();

const MessageStopEvent = z.object({
  type: z.literal("message_stop"),
}).passthrough();

export const StreamEventSchema = z.discriminatedUnion("type", [
  MessageStartEvent,
  ContentBlockStartEvent,
  ContentBlockDeltaEvent,
  ContentBlockStopEvent,
  MessageDeltaEvent,
  MessageStopEvent,
]);

// ---------------------------------------------------------------------------
// Top-level message schemas
// ---------------------------------------------------------------------------

export const SystemInitSchema = z.object({
  type: z.literal("system"),
  subtype: z.literal("init"),
  session_id: z.string(),
  uuid: z.string(),
  model: z.string(),
  cwd: z.string(),
  tools: z.array(z.string()),
  claude_code_version: z.string(),
  permissionMode: z.string(),
  mcp_servers: z.array(z.unknown()).optional(),
  agents: z.array(z.unknown()).optional(),
  apiKeySource: z.string().optional(),
  skills: z.array(z.string()).optional(),
  plugins: z.array(z.unknown()).optional(),
  fast_mode_state: z.string().optional(),
  // TODO: review — these were in the old KNOWN list but are not consumed by the UI
  // version, gitBranch, slash_commands, output_style
}).passthrough();

export const SystemStatusSchema = z.object({
  type: z.literal("system"),
  subtype: z.literal("status"),
  status: z.string().optional(),
  // ignored: routing fields not displayed
  uuid: z.string().optional(),
  session_id: z.string().optional(),
}).passthrough();

export const SystemCompactBoundarySchema = z.object({
  type: z.literal("system"),
  subtype: z.literal("compact_boundary"),
  compact_metadata: z.object({
    trigger: z.string().optional(),
    pre_tokens: z.number().optional(),
  }).passthrough().optional(),
  // ignored: routing fields not displayed
  uuid: z.string().optional(),
  session_id: z.string().optional(),
}).passthrough();

const AssistantInnerMessage = z.object({
  id: z.string(),
  role: z.literal("assistant"),
  content: z.array(AssistantContentBlockSchema),
  model: z.string(),
  stop_reason: z.string().nullable(),
  usage: UsageSchema,
  // TODO: review
  // type, stop_sequence, context_management
}).passthrough();

export const AssistantMessageSchema = z.object({
  type: z.literal("assistant"),
  uuid: z.string(),
  session_id: z.string(),
  parent_tool_use_id: z.string().nullable(),
  isSidechain: z.boolean().optional(),
  message: AssistantInnerMessage,
  // TODO: review — these were in the old KNOWN list but are not consumed by the UI
  // parentUuid, cwd, sessionId, version, gitBranch, requestId, timestamp, userType
}).passthrough();

export const UserEchoSchema = z.object({
  type: z.literal("user"),
  session_id: z.string(),
  message: z.object({
    role: z.literal("user"),
    content: z.array(UserContentBlockSchema),
  }).passthrough(),
  parent_tool_use_id: z.string().nullable(),
  isSidechain: z.boolean().optional(),
  // ignored: legacy duplicate of tool results in content blocks
  tool_use_result: z.unknown().optional(),
  toolUseResult: z.unknown().optional(),
  // consumed: checked in handleSessionMessage to skip echo for replayed messages
  isReplay: z.boolean().optional(),
  uuid: z.string().optional(),
  // TODO: review — these were in the old KNOWN list but are not consumed by the UI
  // parentUuid, cwd, sessionId, version, gitBranch, timestamp, userType
}).passthrough();

export const ResultSchema = z.object({
  type: z.literal("result"),
  subtype: z.string(),
  uuid: z.string(),
  session_id: z.string(),
  is_error: z.boolean(),
  result: z.string(),
  num_turns: z.number(),
  duration_ms: z.number(),
  duration_api_ms: z.number().optional(),
  total_cost_usd: z.number(),
  usage: UsageSchema,
  modelUsage: z.record(z.string(), UsageSchema).optional(),
  permission_denials: z.array(z.string()).optional(),
  stop_reason: z.string().nullable().optional(),
}).passthrough();

export const SummarySchema = z.object({
  type: z.literal("summary"),
  summary: z.string(),
  // TODO: review — in old KNOWN list but not consumed by the UI
  // leafUuid
}).passthrough();

export const RateLimitEventSchema = z.object({
  type: z.literal("rate_limit_event"),
  rate_limit_info: z.object({
    status: z.string().optional(),
    rateLimitType: z.string().optional(),
    resetsAt: z.number().optional(),
    overageStatus: z.string().optional(),
    overageDisabledReason: z.string().optional(),
  }).passthrough(),
  // ignored: routing fields not displayed
  uuid: z.string().optional(),
  session_id: z.string().optional(),
}).passthrough();

// -- JSONL-only system subtypes (not present in stream-json stdout) --

export const SystemApiErrorSchema = z.object({
  type: z.literal("system"),
  subtype: z.literal("api_error"),
  level: z.string().optional(),
  error: z.unknown(),
  retryInMs: z.number().optional(),
  retryAttempt: z.number().optional(),
  maxRetries: z.number().optional(),
}).passthrough();

export const SystemTurnDurationSchema = z.object({
  type: z.literal("system"),
  subtype: z.literal("turn_duration"),
  durationMs: z.number(),
}).passthrough();

// -- JSONL-only top-level types (not present in stream-json stdout) --

export const ProgressSchema = z.object({
  type: z.literal("progress"),
  data: z.object({ type: z.string() }).passthrough(),
}).passthrough();

export const QueueOperationSchema = z.object({
  type: z.literal("queue-operation"),
  operation: z.string(),
}).passthrough();

export const FileHistorySnapshotSchema = z.object({
  type: z.literal("file-history-snapshot"),
  messageId: z.string().optional(),
  snapshot: z.unknown(),
}).passthrough();

export const StreamEventMessageSchema = z.object({
  type: z.literal("stream_event"),
  uuid: z.string(),
  session_id: z.string(),
  parent_tool_use_id: z.string().nullable(),
  event: StreamEventSchema,
}).passthrough();

export const ExitMessageSchema = z.object({
  type: z.literal("exit"),
  code: z.number(),
}).passthrough();

export const StderrMessageSchema = z.object({
  type: z.literal("stderr"),
  text: z.string(),
}).passthrough();

// ---------------------------------------------------------------------------
// Derived TypeScript types
// ---------------------------------------------------------------------------

export type SystemInitMessage = z.infer<typeof SystemInitSchema>;
export type SystemStatusMessage = z.infer<typeof SystemStatusSchema>;
export type SystemCompactBoundaryMessage = z.infer<typeof SystemCompactBoundarySchema>;
export type AssistantMessage = z.infer<typeof AssistantMessageSchema>;
export type AssistantContentBlock = z.infer<typeof AssistantContentBlockSchema>;
export type UserEchoMessage = z.infer<typeof UserEchoSchema>;
export type UserContentBlock = z.infer<typeof UserContentBlockSchema>;
export type ResultMessage = z.infer<typeof ResultSchema>;
export type SummaryMessage = z.infer<typeof SummarySchema>;
export type RateLimitEventMessage = z.infer<typeof RateLimitEventSchema>;
export type StreamEventMessage = z.infer<typeof StreamEventMessageSchema>;
export type StreamEvent = z.infer<typeof StreamEventSchema>;
export type ContentDelta = z.infer<typeof ContentDeltaSchema>;
export type Usage = z.infer<typeof UsageSchema>;
export type ExitMessage = z.infer<typeof ExitMessageSchema>;
export type StderrMessage = z.infer<typeof StderrMessageSchema>;
export type SystemApiErrorMessage = z.infer<typeof SystemApiErrorSchema>;
export type SystemTurnDurationMessage = z.infer<typeof SystemTurnDurationSchema>;
export type ProgressMessage = z.infer<typeof ProgressSchema>;
export type QueueOperationMessage = z.infer<typeof QueueOperationSchema>;
export type FileHistorySnapshotMessage = z.infer<typeof FileHistorySnapshotSchema>;

export type ClaudeMessage =
  | SystemInitMessage
  | SystemStatusMessage
  | SystemCompactBoundaryMessage
  | SystemApiErrorMessage
  | SystemTurnDurationMessage
  | AssistantMessage
  | UserEchoMessage
  | ResultMessage
  | SummaryMessage
  | RateLimitEventMessage
  | StreamEventMessage
  | ProgressMessage
  | QueueOperationMessage
  | FileHistorySnapshotMessage
  | ExitMessage
  | StderrMessage;

export type SessionMessage = { sid: number; event: ClaudeMessage };

// Control messages from our backend (not Claude Code) — plain interfaces, no Zod needed
export interface SessionCreatedMessage {
  type: "session_created";
  sid: number;
}
export interface SessionsListMessage {
  type: "sessions_list";
  sessions: { sid: number; alive: boolean; resumable: boolean }[];
}
export type ControlMessage = SessionCreatedMessage | SessionsListMessage;
