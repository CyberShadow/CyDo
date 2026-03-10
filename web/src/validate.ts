// Schema lookup and validation — pure logic, no React dependency.

import type { ZodTypeAny } from "zod";
import { extractExtras, type ExtraField } from "./extractExtras";
import {
  SystemInitSchema,
  SystemStatusSchema,
  SystemCompactBoundarySchema,
  SystemTaskStartedSchema,
  SystemTaskNotificationSchema,
  SystemApiErrorSchema,
  SystemTurnDurationSchema,
  AssistantMessageSchema,
  AssistantFileSchema,
  UserEchoSchema,
  UserFileSchema,
  ResultSchema,
  SummarySchema,
  RateLimitEventSchema,
  ControlResponseSchema,
  StreamBlockStartSchema,
  StreamBlockDeltaSchema,
  StreamBlockStopSchema,
  StreamTurnStopSchema,
  ProgressSchema,
  QueueOperationSchema,
  FileHistorySnapshotSchema,
  ExitMessageSchema,
  StderrMessageSchema,
} from "./schemas";

type SchemaLookup = (raw: Record<string, unknown>) => ZodTypeAny | null;

// Schema lookup for live stream messages (agent-agnostic protocol).
export const schemaForStdout: SchemaLookup = (raw) => {
  switch (raw.type) {
    case "session/init":
      return SystemInitSchema;
    case "session/status":
      return SystemStatusSchema;
    case "session/compacted":
      return SystemCompactBoundarySchema;
    case "task/started":
      return SystemTaskStartedSchema;
    case "task/notification":
      return SystemTaskNotificationSchema;
    case "message/assistant":
      return AssistantMessageSchema;
    case "message/user":
      return UserEchoSchema;
    case "turn/result":
      return ResultSchema;
    case "session/summary":
      return SummarySchema;
    case "session/rate_limit":
      return RateLimitEventSchema;
    case "stream/block_start":
      return StreamBlockStartSchema;
    case "stream/block_delta":
      return StreamBlockDeltaSchema;
    case "stream/block_stop":
      return StreamBlockStopSchema;
    case "stream/turn_stop":
      return StreamTurnStopSchema;
    case "control/response":
      return ControlResponseSchema;
    case "process/exit":
      return ExitMessageSchema;
    case "process/stderr":
      return StderrMessageSchema;
    default:
      return null;
  }
};

// Schema lookup for translated JSONL file messages.
// Most types are agnostic (translated by backend), but some pass through unchanged.
export const schemaForFile: SchemaLookup = (raw) => {
  switch (raw.type) {
    // Agnostic types (translated by backend)
    case "session/init":
      return SystemInitSchema;
    case "session/status":
      return SystemStatusSchema;
    case "session/compacted":
      return SystemCompactBoundarySchema;
    case "task/started":
      return SystemTaskStartedSchema;
    case "task/notification":
      return SystemTaskNotificationSchema;
    case "message/assistant":
      return AssistantFileSchema;
    case "message/user":
      return UserFileSchema;
    case "turn/result":
      return ResultSchema;
    case "session/summary":
      return SummarySchema;
    case "session/rate_limit":
      return RateLimitEventSchema;
    // Pass-through system subtypes (not translated by backend)
    case "system":
      switch (raw.subtype) {
        case "api_error":
          return SystemApiErrorSchema;
        case "turn_duration":
          return SystemTurnDurationSchema;
        default:
          return null;
      }
    // JSONL-only types (pass through unchanged)
    case "progress":
      return ProgressSchema;
    case "queue-operation":
      return QueueOperationSchema;
    case "file-history-snapshot":
      return FileHistorySnapshotSchema;
    default:
      return null;
  }
};

export interface MessageValidation {
  extras: ExtraField[] | undefined;
  /** Non-null when the message fails schema validation or has no schema. */
  schemaError: string | null;
}

// Validate a raw message against a schema set and extract extra fields.
export function validateWith(
  lookup: SchemaLookup,
  msg: unknown,
): MessageValidation {
  const raw = msg as Record<string, unknown>;
  const schema = lookup(raw);
  if (!schema) {
    return {
      extras: undefined,
      schemaError:
        `No schema for message type: ${raw.type}` +
        (raw.subtype ? ` subtype: ${raw.subtype}` : ""),
    };
  }
  const result = schema.safeParse(raw);
  const extras = extractExtras(raw, schema);
  return {
    extras: extras.length > 0 ? extras : undefined,
    schemaError: result.success
      ? null
      : result.error.issues
          .map((i) => `${i.path.join(".")}: ${i.message}`)
          .join("; "),
  };
}
