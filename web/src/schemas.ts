// Claude Code protocol schemas (Zod)
//
// Two schema sets — stdout (live stream-json) and file (on-disk JSONL) — each
// strict for its own format, sharing inner types.  Only fields that are
// (a) consumed by the UI or (b) explicitly ignored with rationale are included.
// Everything else surfaces as "extra fields" in the UI.

import { z } from "zod";

// ---------------------------------------------------------------------------
// Leaf / nested schemas
// ---------------------------------------------------------------------------

export const UsageSchema = z
  .object({
    input_tokens: z.number(),
    output_tokens: z.number(),
    cache_creation_input_tokens: z.number().optional(),
    cache_read_input_tokens: z.number().optional(),
    cache_creation: z
      .object({
        ephemeral_5m_input_tokens: z.number().optional(),
        ephemeral_1h_input_tokens: z.number().optional(),
      })
      .passthrough()
      .optional(),
    service_tier: z.literal("standard").optional(),
    inference_geo: z
      .union([z.literal("not_available"), z.literal("")])
      .optional(),
    server_tool_use: z
      .object({
        web_search_requests: z.number(),
        web_fetch_requests: z.number(),
      })
      .passthrough()
      .optional(),
    iterations: z.array(z.unknown()).optional(),
    speed: z.literal("standard").optional(),
  })
  .passthrough();

// Per-model usage in result messages — camelCase, different fields from top-level usage
export const ModelUsageSchema = z
  .object({
    inputTokens: z.number(),
    outputTokens: z.number(),
    cacheReadInputTokens: z.number().optional(),
    cacheCreationInputTokens: z.number().optional(),
    costUSD: z.number().optional(),
    webSearchRequests: z.number().optional(),
    contextWindow: z.number().optional(),
    maxOutputTokens: z.number().optional(),
  })
  .passthrough();

// -- Assistant content blocks (discriminated on "type") --

const TextContentBlock = z
  .object({
    type: z.literal("text"),
    text: z.string(),
  })
  .passthrough();

const ToolUseContentBlock = z
  .object({
    type: z.literal("tool_use"),
    id: z.string(),
    name: z.string(),
    input: z.record(z.string(), z.unknown()), // opaque — tool inputs are arbitrary JSON
    caller: z
      .object({ type: z.literal("direct") })
      .passthrough()
      .optional(),
  })
  .passthrough();

const ThinkingContentBlock = z
  .object({
    type: z.literal("thinking"),
    thinking: z.string(),
    signature: z.string(),
  })
  .passthrough();

export const AssistantContentBlockSchema = z.discriminatedUnion("type", [
  TextContentBlock,
  ToolUseContentBlock,
  ThinkingContentBlock,
]);

// -- User content blocks --

const UserTextBlock = z
  .object({
    type: z.literal("text"),
    text: z.string(),
  })
  .passthrough();

const UserToolResultBlock = z
  .object({
    type: z.literal("tool_result"),
    tool_use_id: z.string(),
    content: z.union([
      z.string(),
      z.array(z.object({ type: z.string(), text: z.string() }).passthrough()),
    ]),
    is_error: z.boolean().optional(),
  })
  .passthrough();

export const UserContentBlockSchema = z.discriminatedUnion("type", [
  UserTextBlock,
  UserToolResultBlock,
]);

// Alias — stdout and file formats use the same content shape
export const UserFileContentBlockSchema = z.discriminatedUnion("type", [
  UserTextBlock,
  UserToolResultBlock,
]);

// -- Stream event deltas --

const ThinkingDelta = z
  .object({
    type: z.literal("thinking_delta"),
    thinking: z.string(),
  })
  .passthrough();

const TextDelta = z
  .object({
    type: z.literal("text_delta"),
    text: z.string(),
  })
  .passthrough();

const InputJsonDelta = z
  .object({
    type: z.literal("input_json_delta"),
    partial_json: z.string(),
  })
  .passthrough();

const SignatureDelta = z
  .object({
    type: z.literal("signature_delta"),
    signature: z.string(),
  })
  .passthrough();

export const ContentDeltaSchema = z.discriminatedUnion("type", [
  ThinkingDelta,
  TextDelta,
  InputJsonDelta,
  SignatureDelta,
]);

// -- Stream events --

const MessageStartEvent = z
  .object({
    type: z.literal("message_start"),
    message: z.object({ model: z.string(), id: z.string() }).passthrough(),
  })
  .passthrough();

const ContentBlockStartEvent = z
  .object({
    type: z.literal("content_block_start"),
    index: z.number(),
    content_block: z.object({ type: z.string() }).passthrough(),
  })
  .passthrough();

const ContentBlockDeltaEvent = z
  .object({
    type: z.literal("content_block_delta"),
    index: z.number(),
    delta: ContentDeltaSchema,
  })
  .passthrough();

const ContentBlockStopEvent = z
  .object({
    type: z.literal("content_block_stop"),
    index: z.number(),
  })
  .passthrough();

const MessageDeltaEvent = z
  .object({
    type: z.literal("message_delta"),
    delta: z.object({ stop_reason: z.string() }).passthrough(),
  })
  .passthrough();

const MessageStopEvent = z
  .object({
    type: z.literal("message_stop"),
  })
  .passthrough();

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

export const SystemInitSchema = z
  .object({
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
  })
  .passthrough();

export const SystemStatusSchema = z
  .object({
    type: z.literal("system"),
    subtype: z.literal("status"),
    status: z.string().optional(),
    // ignored: routing fields not displayed
    uuid: z.string().optional(),
    session_id: z.string().optional(),
  })
  .passthrough();

export const SystemCompactBoundarySchema = z
  .object({
    type: z.literal("system"),
    subtype: z.literal("compact_boundary"),
    compact_metadata: z
      .object({
        trigger: z.string().optional(),
        pre_tokens: z.number().optional(),
      })
      .passthrough()
      .optional(),
    // ignored: routing fields not displayed
    uuid: z.string().optional(),
    session_id: z.string().optional(),
  })
  .passthrough();

const AssistantInnerMessage = z
  .object({
    id: z.string(),
    type: z.literal("message").optional(),
    role: z.literal("assistant"),
    content: z.array(AssistantContentBlockSchema),
    model: z.string(),
    stop_reason: z.string().nullable(),
    stop_sequence: z.null().optional(),
    usage: UsageSchema,
    context_management: z.null().optional(),
  })
  .passthrough();

export const AssistantMessageSchema = z
  .object({
    type: z.literal("assistant"),
    uuid: z.string(),
    session_id: z.string(),
    parent_tool_use_id: z.string().nullable(),
    isSidechain: z.boolean().optional(),
    message: AssistantInnerMessage,
  })
  .passthrough();

export const UserEchoSchema = z
  .object({
    type: z.literal("user"),
    session_id: z.string(),
    message: z
      .object({
        role: z.literal("user"),
        content: z.union([z.string(), z.array(UserContentBlockSchema)]), // string when isReplay
      })
      .passthrough(),
    parent_tool_use_id: z.string().nullable(),
    isSidechain: z.boolean().optional(),
    // ignored: legacy duplicate of tool results in content blocks
    tool_use_result: z.unknown().optional(),
    toolUseResult: z.unknown().optional(),
    // consumed: checked in handleSessionMessage to skip echo for replayed messages
    isReplay: z.boolean().optional(),
    isSynthetic: z.boolean().optional(),
    uuid: z.string().optional(),
  })
  .passthrough();

export const ResultSchema = z
  .object({
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
    modelUsage: z.record(z.string(), ModelUsageSchema).optional(),
    permission_denials: z
      .array(
        z.union([
          z.string(),
          z
            .object({
              tool_name: z.string(),
              tool_use_id: z.string(),
              tool_input: z.record(z.string(), z.unknown()),
            })
            .passthrough(),
        ]),
      )
      .optional(),
    stop_reason: z.string().nullable().optional(),
  })
  .passthrough();

export const SummarySchema = z
  .object({
    type: z.literal("summary"),
    summary: z.string(),
    // TODO: review — in old KNOWN list but not consumed by the UI
    // leafUuid
  })
  .passthrough();

export const RateLimitEventSchema = z
  .object({
    type: z.literal("rate_limit_event"),
    rate_limit_info: z
      .object({
        status: z.string().optional(),
        rateLimitType: z.string().optional(),
        resetsAt: z.number().optional(),
        overageStatus: z.string().optional(),
        overageDisabledReason: z.string().optional(),
      })
      .passthrough(),
    // ignored: routing fields not displayed
    uuid: z.string().optional(),
    session_id: z.string().optional(),
  })
  .passthrough();

// -- Task/subagent lifecycle system subtypes --

export const SystemTaskStartedSchema = z
  .object({
    type: z.literal("system"),
    subtype: z.literal("task_started"),
    task_id: z.string(),
    tool_use_id: z.string().optional(),
    uuid: z.string(),
    session_id: z.string(),
  })
  .passthrough();

export const SystemTaskNotificationSchema = z
  .object({
    type: z.literal("system"),
    subtype: z.literal("task_notification"),
    task_id: z.string(),
    status: z.string(),
    output_file: z.string().optional(),
    summary: z.string().optional(),
    uuid: z.string(),
    session_id: z.string(),
  })
  .passthrough();

// -- JSONL-only system subtypes (not present in stream-json stdout) --

export const SystemApiErrorSchema = z
  .object({
    type: z.literal("system"),
    subtype: z.literal("api_error"),
    level: z.string().optional(),
    error: z.unknown(),
    retryInMs: z.number().optional(),
    retryAttempt: z.number().optional(),
    maxRetries: z.number().optional(),
  })
  .passthrough();

export const SystemTurnDurationSchema = z
  .object({
    type: z.literal("system"),
    subtype: z.literal("turn_duration"),
    durationMs: z.number(),
  })
  .passthrough();

// -- JSONL file schemas (strict for the on-disk format) --

export const AssistantFileSchema = z
  .object({
    type: z.literal("assistant"),
    uuid: z.string(),
    parent_tool_use_id: z.string().nullable().optional(),
    isSidechain: z.boolean().optional(),
    message: AssistantInnerMessage,
  })
  .passthrough();

export const UserFileSchema = z
  .object({
    type: z.literal("user"),
    message: z
      .object({
        role: z.literal("user"),
        content: z.union([z.string(), z.array(UserFileContentBlockSchema)]),
      })
      .passthrough(),
    parent_tool_use_id: z.string().nullable().optional(),
    isSidechain: z.boolean().optional(),
    // ignored: legacy duplicate of tool results in content blocks
    tool_use_result: z.unknown().optional(),
    toolUseResult: z.unknown().optional(),
    isSynthetic: z.literal(true).optional(),
    uuid: z.string().optional(),
  })
  .passthrough();

// -- JSONL-only top-level types (not present in stream-json stdout) --

export const ProgressSchema = z
  .object({
    type: z.literal("progress"),
    data: z.object({ type: z.string() }).passthrough(),
  })
  .passthrough();

export const QueueOperationSchema = z
  .object({
    type: z.literal("queue-operation"),
    operation: z.string(),
  })
  .passthrough();

export const FileHistorySnapshotSchema = z
  .object({
    type: z.literal("file-history-snapshot"),
    messageId: z.string().optional(),
    snapshot: z.unknown(),
  })
  .passthrough();

export const StreamEventMessageSchema = z
  .object({
    type: z.literal("stream_event"),
    uuid: z.string(),
    session_id: z.string(),
    parent_tool_use_id: z.string().nullable(),
    event: StreamEventSchema,
  })
  .passthrough();

export const ExitMessageSchema = z
  .object({
    type: z.literal("exit"),
    code: z.number(),
  })
  .passthrough();

export const StderrMessageSchema = z
  .object({
    type: z.literal("stderr"),
    text: z.string(),
  })
  .passthrough();

// ---------------------------------------------------------------------------
// Derived TypeScript types
// ---------------------------------------------------------------------------

export type SystemInitMessage = z.infer<typeof SystemInitSchema>;
export type SystemStatusMessage = z.infer<typeof SystemStatusSchema>;
export type SystemCompactBoundaryMessage = z.infer<
  typeof SystemCompactBoundarySchema
>;
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
export type AssistantFileMessage = z.infer<typeof AssistantFileSchema>;
export type UserFileMessage = z.infer<typeof UserFileSchema>;
export type SystemTaskStartedMessage = z.infer<typeof SystemTaskStartedSchema>;
export type SystemTaskNotificationMessage = z.infer<
  typeof SystemTaskNotificationSchema
>;
export type SystemApiErrorMessage = z.infer<typeof SystemApiErrorSchema>;
export type SystemTurnDurationMessage = z.infer<
  typeof SystemTurnDurationSchema
>;
export type ProgressMessage = z.infer<typeof ProgressSchema>;
export type QueueOperationMessage = z.infer<typeof QueueOperationSchema>;
export type FileHistorySnapshotMessage = z.infer<
  typeof FileHistorySnapshotSchema
>;

// Stdout (live stream-json) message union
export type ClaudeMessage =
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
  | StreamEventMessage
  | ExitMessage
  | StderrMessage;

// JSONL file message union (excludes exit/stderr — those are synthetic from our backend)
export type ClaudeFileMessage =
  | SystemInitMessage
  | SystemStatusMessage
  | SystemCompactBoundaryMessage
  | SystemApiErrorMessage
  | SystemTurnDurationMessage
  | SystemTaskStartedMessage
  | SystemTaskNotificationMessage
  | AssistantFileMessage
  | UserFileMessage
  | ResultMessage
  | SummaryMessage
  | RateLimitEventMessage
  | ProgressMessage
  | QueueOperationMessage
  | FileHistorySnapshotMessage;

export type SessionMessage = { sid: number; event: ClaudeMessage };
export type FileMessage = { sid: number; fileEvent: ClaudeFileMessage };

// Control messages from our backend (not Claude Code) — plain interfaces, no Zod needed
export interface SessionCreatedMessage {
  type: "session_created";
  sid: number;
}
export interface SessionsListMessage {
  type: "sessions_list";
  sessions: {
    sid: number;
    alive: boolean;
    resumable: boolean;
    lastActivity: string;
    title?: string;
  }[];
}
export interface SessionReloadMessage {
  type: "session_reload";
  sid: number;
}
export interface TitleUpdateMessage {
  type: "title_update";
  sid: number;
  title: string;
}
export interface SessionHistoryEndMessage {
  type: "session_history_end";
  sid: number;
}
export type ControlMessage =
  | SessionCreatedMessage
  | SessionsListMessage
  | SessionReloadMessage
  | TitleUpdateMessage
  | SessionHistoryEndMessage;
