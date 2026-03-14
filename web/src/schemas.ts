// Claude Code protocol schemas (Zod)
//
// Two schema sets — stdout (live stream-json) and file (on-disk JSONL) — each
// strict for its own format, sharing inner types.  Only fields that are
// (a) consumed by the UI or (b) explicitly ignored with rationale are included.
// Everything else surfaces as "extra fields" in the UI.
//
// Schema completeness policy:
//
//   1. Schemas SHOULD describe the full structure of every field. Opaque types
//      (z.unknown(), z.record(k, z.unknown())) prevent extractExtras from
//      recursing into nested objects, silently swallowing new fields that would
//      otherwise surface as "extra fields" in the UI and fail tests. Unknown
//      fields causing test failures is expected and desired — each new field
//      requires a deliberate decision about how to handle it.
//
//   2. Any field typed as z.unknown() MUST still be surfaced in the UI in some
//      way (e.g. rendered via JSON.stringify, or reported as ExtraFields).
//      A field that is both opaque AND invisible is a compliance violation.
//
//   3. Fields may be added to a schema (removing them from ExtraFields) ONLY
//      if they are also rendered in the UI, or added by explicit unambiguous
//      instructions from the user. Do not suppress extra-field warnings by
//      adding z.unknown() declarations that hide structure.

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
    service_tier: z.literal("standard").nullable().optional(),
    inference_geo: z
      .union([z.literal("not_available"), z.literal("")])
      .nullable()
      .optional(),
    server_tool_use: z
      .object({
        web_search_requests: z.number(),
        web_fetch_requests: z.number(),
      })
      .passthrough()
      .optional(),
    // only ever observed as empty []; z.never() ensures non-empty arrays fail validation
    iterations: z.array(z.never()).nullable().optional(),
    speed: z.literal("standard").nullable().optional(),
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

// Stream events (promoted to top-level by backend translation)
export const StreamBlockStartSchema = z
  .object({
    type: z.literal("stream/block_start"),
    index: z.number(),
    content_block: z.object({ type: z.string() }).passthrough(),
  })
  .passthrough();

export const StreamBlockDeltaSchema = z
  .object({
    type: z.literal("stream/block_delta"),
    index: z.number(),
    delta: ContentDeltaSchema,
  })
  .passthrough();

export const StreamBlockStopSchema = z
  .object({
    type: z.literal("stream/block_stop"),
    index: z.number(),
  })
  .passthrough();

export const StreamTurnStopSchema = z
  .object({
    type: z.literal("stream/turn_stop"),
  })
  .passthrough();

// ---------------------------------------------------------------------------
// Top-level message schemas
// ---------------------------------------------------------------------------

export const SystemInitSchema = z
  .object({
    type: z.literal("session/init"),
    session_id: z.string(),
    uuid: z.string(),
    model: z.string(),
    cwd: z.string(),
    tools: z.array(z.string()),
    claude_code_version: z.string(),
    permissionMode: z.string(),
    mcp_servers: z
      .array(z.object({ name: z.string(), status: z.string() }).passthrough())
      .optional(),
    agents: z.array(z.string()).optional(),
    apiKeySource: z.string().optional(),
    skills: z.array(z.string()).optional(),
    plugins: z
      .array(z.object({ name: z.string(), path: z.string() }).passthrough())
      .optional(),
    fast_mode_state: z.string().optional(),
    slash_commands: z.array(z.string()).optional(),
    output_style: z.string().optional(),
    agent: z.string().optional(),
  })
  .passthrough();

export const SystemStatusSchema = z
  .object({
    type: z.literal("session/status"),
    status: z.string().nullable().optional(),
    // ignored: routing fields not displayed
    uuid: z.string().optional(),
    session_id: z.string().optional(),
  })
  .passthrough();

export const SystemCompactBoundarySchema = z
  .object({
    type: z.literal("session/compacted"),
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
    stop_sequence: z.union([z.null(), z.string()]).optional(),
    usage: UsageSchema,
    context_management: z.null().optional(),
    container: z.null().optional(),
  })
  .passthrough();

export const AssistantMessageSchema = z
  .object({
    type: z.literal("message/assistant"),
    uuid: z.string(),
    session_id: z.string(),
    parent_tool_use_id: z.string().nullable(),
    isSidechain: z.boolean().optional(),
    isApiErrorMessage: z.boolean().optional(),
    message: AssistantInnerMessage,
  })
  .passthrough();

export const UserEchoSchema = z
  .object({
    type: z.literal("message/user"),
    session_id: z.string().optional(),
    message: z
      .object({
        role: z.enum(["user", "developer"]),
        content: z.union([z.string(), z.array(UserContentBlockSchema)]), // string when isReplay
      })
      .passthrough(),
    parent_tool_use_id: z.string().nullable().optional(),
    isSidechain: z.boolean().optional(),
    // opaque — tool result payloads vary by tool, rendered via ToolCall dispatch
    // may be an object (Bash, Edit) or an array (SwitchMode, ControlResponse)
    tool_use_result: z
      .union([z.record(z.string(), z.unknown()), z.array(z.unknown())])
      .optional(),
    toolUseResult: z
      .union([z.record(z.string(), z.unknown()), z.array(z.unknown())])
      .optional(),
    // ignored: routing — links tool result back to the assistant that made the call
    sourceToolAssistantUUID: z.string().optional(),
    // consumed: checked in handleSessionMessage to skip echo for replayed messages
    isReplay: z.boolean().optional(),
    isSynthetic: z.boolean().optional(),
    isMeta: z.boolean().optional(),
    isSteering: z.boolean().optional(),
    pending: z.boolean().optional(),
    slug: z.string().optional(),
    uuid: z.string().optional(),
  })
  .passthrough();

export const ResultSchema = z
  .object({
    type: z.literal("turn/result"),
    subtype: z.string(),
    uuid: z.string(),
    session_id: z.string(),
    is_error: z.boolean(),
    result: z.string().optional(),
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
    errors: z.array(z.string()).optional(),
  })
  .passthrough();

export const SummarySchema = z
  .object({
    type: z.literal("session/summary"),
    summary: z.string(),
    // TODO: review — in old KNOWN list but not consumed by the UI
    // leafUuid
  })
  .passthrough();

export const RateLimitEventSchema = z
  .object({
    type: z.literal("session/rate_limit"),
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
    type: z.literal("task/started"),
    task_id: z.string(),
    tool_use_id: z.string().optional(),
    description: z.string().optional(),
    task_type: z.string().optional(),
    uuid: z.string(),
    session_id: z.string(),
  })
  .passthrough();

export const SystemTaskNotificationSchema = z
  .object({
    type: z.literal("task/notification"),
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

// Envelope fields present on all JSONL entries
const FileEnvelopeFields = {
  parentUuid: z.string().nullable().optional(),
  userType: z.string().optional(),
  cwd: z.string().optional(),
  sessionId: z.string().optional(),
  version: z.string().optional(),
  gitBranch: z.string().optional(),
  timestamp: z.string().optional(),
  permissionMode: z.string().optional(),
} as const;

export const AssistantFileSchema = z
  .object({
    type: z.literal("message/assistant"),
    uuid: z.string(),
    // ignored: routing — present in live stream schema too, Codex adapter injects it
    session_id: z.string().optional(),
    parent_tool_use_id: z.string().nullable().optional(),
    isSidechain: z.boolean().optional(),
    isApiErrorMessage: z.boolean().optional(),
    message: AssistantInnerMessage,
    slug: z.string().optional(),
    requestId: z.string().optional(),
    ...FileEnvelopeFields,
  })
  .passthrough();

export const UserFileSchema = z
  .object({
    type: z.literal("message/user"),
    message: z
      .object({
        role: z.enum(["user", "developer"]),
        content: z.union([z.string(), z.array(UserFileContentBlockSchema)]),
      })
      .passthrough(),
    parent_tool_use_id: z.string().nullable().optional(),
    isSidechain: z.boolean().optional(),
    // opaque — tool result payloads vary by tool, rendered via ToolCall dispatch
    tool_use_result: z
      .union([z.record(z.string(), z.unknown()), z.array(z.unknown())])
      .optional(),
    toolUseResult: z
      .union([z.record(z.string(), z.unknown()), z.array(z.unknown())])
      .optional(),
    // ignored: routing — links tool result back to the assistant that made the call
    sourceToolAssistantUUID: z.string().optional(),
    isSynthetic: z.literal(true).optional(),
    isMeta: z.boolean().optional(),
    isSteering: z.boolean().optional(),
    pending: z.boolean().optional(),
    slug: z.string().optional(),
    uuid: z.string().optional(),
    ...FileEnvelopeFields,
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
    // POLICY: opaque — entire event is intentionally discarded by reducer
    snapshot: z.unknown(),
  })
  .passthrough();

export const ControlResponseSchema = z
  .object({
    type: z.literal("control/response"),
    response: z
      .object({
        subtype: z.string(),
        request_id: z.string(),
      })
      .passthrough(),
  })
  .passthrough();

export const ExitMessageSchema = z
  .object({
    type: z.literal("process/exit"),
    code: z.number(),
  })
  .passthrough();

export const StderrMessageSchema = z
  .object({
    type: z.literal("process/stderr"),
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
export type StreamBlockStart = z.infer<typeof StreamBlockStartSchema>;
export type StreamBlockDelta = z.infer<typeof StreamBlockDeltaSchema>;
export type StreamBlockStop = z.infer<typeof StreamBlockStopSchema>;
export type StreamTurnStop = z.infer<typeof StreamTurnStopSchema>;
export type ContentDelta = z.infer<typeof ContentDeltaSchema>;
export type Usage = z.infer<typeof UsageSchema>;
export type ControlResponseMessage = z.infer<typeof ControlResponseSchema>;
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

// Backwards compat alias
export type ClaudeMessage = AgnosticEvent;

// File message union (translated + pass-through JSONL-only types)
export type AgnosticFileEvent =
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

// Backwards compat alias
export type ClaudeFileMessage = AgnosticFileEvent;

export type TaskMessage = { tid: number; event: AgnosticEvent };
export type FileMessage = { tid: number; fileEvent: AgnosticFileEvent };

// Control messages from our backend (not Claude Code) — plain interfaces, no Zod needed
export interface TaskCreatedMessage {
  type: "task_created";
  tid: number;
  workspace?: string;
  project_path?: string;
  parent_tid?: number;
  relation_type?: string;
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
    lastActivity: string;
    title?: string;
    workspace?: string;
    project_path?: string;
    parent_tid?: number;
    relation_type?: string;
    status?: string;
    task_type?: string;
    agent_type?: string;
  }[];
}
export interface TaskReloadMessage {
  type: "task_reload";
  tid: number;
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
    description: string;
    model_class: string;
    read_only: boolean;
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
export type ControlMessage =
  | TaskCreatedMessage
  | TasksListMessage
  | TaskReloadMessage
  | TitleUpdateMessage
  | TaskHistoryEndMessage
  | WorkspacesListMessage
  | TaskTypesListMessage
  | ForkableUuidsMessage
  | ErrorMessage
  | UndoPreviewMessage;
