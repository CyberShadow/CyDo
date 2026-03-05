// Shared display types for the UI.
//
// These are the frontend's internal representations — distinct from the Claude
// Code wire-protocol types in schemas.ts.

import type { AssistantContentBlock } from "./schemas";
import type { ExtraField } from "./extractExtras";

export interface DisplayMessage {
  id: string;
  type:
    | "user"
    | "assistant"
    | "tool_result"
    | "system"
    | "result"
    | "summary"
    | "rate_limit"
    | "compact_boundary";
  content: AssistantContentBlock[];
  toolResults?: Map<string, ToolResult>;
  model?: string;
  pending?: boolean;
  // In-progress streaming content blocks (text/tool_use/thinking being received)
  streamingBlocks?: StreamingBlock[];
  // Additional metadata for richer display
  isSidechain?: boolean;
  isSynthetic?: boolean;
  parentToolUseId?: string | null;
  usage?: { input_tokens: number; output_tokens: number };
  // Result message fields
  resultData?: {
    subtype: string;
    isError: boolean;
    result: string;
    numTurns: number;
    durationMs: number;
    durationApiMs?: number;
    totalCostUsd: number;
    usage: { input_tokens: number; output_tokens: number };
    modelUsage?: Record<string, Record<string, unknown>>;
    permissionDenials?: unknown[];
    stopReason?: string | null;
  };
  // Rate limit fields
  rateLimitInfo?: {
    status?: string;
    rateLimitType?: string;
    resetsAt?: number;
    overageStatus?: string;
    overageDisabledReason?: string;
  };
  // Compact boundary fields
  compactMetadata?: {
    trigger?: string;
    preTokens?: number;
  };
  // System status
  statusText?: string;
  // Extra fields not explicitly handled — displayed so nothing is silently lost
  extraFields?: ExtraField[];
  // Original wire-protocol message(s) for "view source"
  rawSource?: unknown;
}

export type ToolResultContent =
  | string
  | Array<{ type: string; text?: string; [key: string]: unknown }>;

export interface ToolResult {
  toolUseId: string;
  content: ToolResultContent;
  isError?: boolean;
}

export interface StreamingBlock {
  index: number;
  type: string;
  text: string;
  name?: string;
}

export interface SessionInfo {
  model: string;
  version: string;
  sessionId: string;
  cwd: string;
  tools: string[];
  permissionMode: string;
  mcp_servers?: unknown[];
  agents?: unknown[];
  apiKeySource?: string;
  skills?: string[];
  plugins?: unknown[];
  fast_mode_state?: string;
}

export interface SessionState {
  sid: number;
  messages: DisplayMessage[];
  sessionInfo: SessionInfo | null;
  isProcessing: boolean;
  totalCost: number;
  alive: boolean;
  resumable: boolean;
  msgIdCounter: number;
  title?: string;
  /** User message texts from before a reload, not yet matched by file replay. */
  preReloadDrafts?: string[];
}

export function makeSessionState(
  sid: number,
  alive: boolean = false,
  resumable: boolean = false,
  title?: string,
): SessionState {
  return {
    sid,
    messages: [],
    sessionInfo: null,
    isProcessing: false,
    totalCost: 0,
    alive,
    resumable,
    msgIdCounter: 0,
    title,
  };
}
