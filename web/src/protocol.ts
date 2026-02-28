// Claude Code stream-json protocol types

export interface SystemInitMessage {
  type: "system";
  subtype: "init";
  session_id: string;
  uuid: string;
  model: string;
  cwd: string;
  tools: string[];
  claude_code_version: string;
  permissionMode: string;
}

export interface AssistantMessage {
  type: "assistant";
  uuid: string;
  session_id: string;
  parent_tool_use_id: string | null;
  message: {
    id: string;
    role: "assistant";
    content: AssistantContentBlock[];
    model: string;
    stop_reason: string | null;
    usage: Usage;
  };
}

export type AssistantContentBlock =
  | { type: "text"; text: string }
  | { type: "tool_use"; id: string; name: string; input: Record<string, unknown> }
  | { type: "thinking"; thinking: string; signature: string };

export interface UserEchoMessage {
  type: "user";
  uuid?: string;
  session_id: string;
  message: {
    role: "user";
    content: UserContentBlock[];
  };
  parent_tool_use_id: string | null;
  tool_use_result?: unknown;
}

export type UserContentBlock =
  | { type: "text"; text: string }
  | { type: "tool_result"; tool_use_id: string; content: string; is_error?: boolean };

export interface ResultMessage {
  type: "result";
  subtype: string;
  uuid: string;
  session_id: string;
  is_error: boolean;
  result: string;
  num_turns: number;
  duration_ms: number;
  total_cost_usd: number;
  usage: Usage;
}

export interface StreamEventMessage {
  type: "stream_event";
  uuid: string;
  session_id: string;
  parent_tool_use_id: string | null;
  event: StreamEvent;
}

export type StreamEvent =
  | { type: "message_start"; message: { model: string; id: string } }
  | { type: "content_block_start"; index: number; content_block: { type: string } }
  | { type: "content_block_delta"; index: number; delta: ContentDelta }
  | { type: "content_block_stop"; index: number }
  | { type: "message_delta"; delta: { stop_reason: string } }
  | { type: "message_stop" };

export type ContentDelta =
  | { type: "thinking_delta"; thinking: string }
  | { type: "text_delta"; text: string }
  | { type: "input_json_delta"; partial_json: string };

export interface Usage {
  input_tokens: number;
  output_tokens: number;
}

// Internal exit message from backend
export interface ExitMessage {
  type: "exit";
  code: number;
}

// Internal stderr message from backend
export interface StderrMessage {
  type: "stderr";
  text: string;
}

// Control messages from backend
export interface SessionCreatedMessage {
  type: "session_created";
  sid: number;
}

export interface SessionsListMessage {
  type: "sessions_list";
  sessions: { sid: number; alive: boolean }[];
}

// Session messages have sid injected by backend
export type SessionMessage = ClaudeMessage & { sid: number };

export type ControlMessage = SessionCreatedMessage | SessionsListMessage;

export type ClaudeMessage =
  | SystemInitMessage
  | AssistantMessage
  | UserEchoMessage
  | ResultMessage
  | StreamEventMessage
  | ExitMessage
  | StderrMessage;
