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
  StreamEventMessageSchema,
  ProgressSchema,
  QueueOperationSchema,
  FileHistorySnapshotSchema,
  ExitMessageSchema,
  StderrMessageSchema,
} from "./schemas";

type SchemaLookup = (raw: Record<string, unknown>) => ZodTypeAny | null;

// Schema lookup for live stdout (stream-json) messages.
export const schemaForStdout: SchemaLookup = (raw) => {
  switch (raw.type) {
    case "system":
      switch (raw.subtype) {
        case "init":
          return SystemInitSchema;
        case "status":
          return SystemStatusSchema;
        case "compact_boundary":
          return SystemCompactBoundarySchema;
        case "task_started":
          return SystemTaskStartedSchema;
        case "task_notification":
          return SystemTaskNotificationSchema;
        default:
          return null;
      }
    case "assistant":
      return AssistantMessageSchema;
    case "user":
      return UserEchoSchema;
    case "result":
      return ResultSchema;
    case "summary":
      return SummarySchema;
    case "rate_limit_event":
      return RateLimitEventSchema;
    case "stream_event":
      return StreamEventMessageSchema;
    case "exit":
      return ExitMessageSchema;
    case "stderr":
      return StderrMessageSchema;
    default:
      return null;
  }
};

// Schema lookup for on-disk JSONL file messages.
export const schemaForFile: SchemaLookup = (raw) => {
  switch (raw.type) {
    case "system":
      switch (raw.subtype) {
        case "init":
          return SystemInitSchema;
        case "status":
          return SystemStatusSchema;
        case "compact_boundary":
          return SystemCompactBoundarySchema;
        case "api_error":
          return SystemApiErrorSchema;
        case "turn_duration":
          return SystemTurnDurationSchema;
        case "task_started":
          return SystemTaskStartedSchema;
        case "task_notification":
          return SystemTaskNotificationSchema;
        default:
          return null;
      }
    case "assistant":
      return AssistantFileSchema;
    case "user":
      return UserFileSchema;
    case "result":
      return ResultSchema;
    case "summary":
      return SummarySchema;
    case "rate_limit_event":
      return RateLimitEventSchema;
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
