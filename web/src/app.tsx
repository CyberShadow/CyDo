import { h } from "preact";
import { useState, useEffect, useRef, useCallback } from "preact/hooks";
import { Connection } from "./connection";
import type {
  ClaudeMessage,
  AssistantMessage,
  AssistantContentBlock,
  StreamEvent,
  ControlMessage,
  ResultMessage,
} from "./schemas";
import {
  SystemInitSchema,
  SystemStatusSchema,
  SystemCompactBoundarySchema,
  AssistantMessageSchema,
  UserEchoSchema,
  ResultSchema,
  SummarySchema,
  RateLimitEventSchema,
  ExitMessageSchema,
  StderrMessageSchema,
} from "./schemas";
import { extractExtras, type ExtraField } from "./extractExtras";
import type { ZodTypeAny } from "zod";
import { SystemBanner } from "./components/SystemBanner";
import { MessageList } from "./components/MessageList";
import { InputBox } from "./components/InputBox";
import { Sidebar } from "./components/Sidebar";

// Display types for the UI
export interface DisplayMessage {
  id: string;
  type: "user" | "assistant" | "tool_result" | "system" | "result" | "summary" | "rate_limit" | "compact_boundary";
  content: AssistantContentBlock[];
  toolResults?: Map<string, ToolResult>;
  model?: string;
  pending?: boolean;
  // Additional metadata for richer display
  isSidechain?: boolean;
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
    modelUsage?: Record<string, { input_tokens: number; output_tokens: number }>;
    permissionDenials?: string[];
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

interface SessionState {
  sid: number;
  messages: DisplayMessage[];
  streamingBlocks: StreamingBlock[];
  sessionInfo: SessionInfo | null;
  isProcessing: boolean;
  totalCost: number;
  alive: boolean;
  resumable: boolean;
  msgIdCounter: number;
}

// Select the Zod schema for a raw Claude message (after stripping `sid`).
// Returns null for unknown types and stream_event (transient, not stored).
function schemaForMessage(raw: Record<string, unknown>): ZodTypeAny | null {
  switch (raw.type) {
    case "system":
      switch (raw.subtype) {
        case "init": return SystemInitSchema;
        case "status": return SystemStatusSchema;
        case "compact_boundary": return SystemCompactBoundarySchema;
        default: return null;
      }
    case "assistant": return AssistantMessageSchema;
    case "user": return UserEchoSchema;
    case "result": return ResultSchema;
    case "summary": return SummarySchema;
    case "rate_limit_event": return RateLimitEventSchema;
    case "stream_event": return null; // transient — never stored as DisplayMessage
    case "exit": return ExitMessageSchema;
    case "stderr": return StderrMessageSchema;
    default: return null;
  }
}

// Extract extra fields from a raw message using its Zod schema.
function messageExtras(msg: unknown): ExtraField[] | undefined {
  const raw = msg as Record<string, unknown>;
  // Strip `sid` — injected by our backend, not part of Claude's protocol
  const { sid: _sid, ...withoutSid } = raw;
  const schema = schemaForMessage(withoutSid);
  if (!schema) return undefined;
  const extras = extractExtras(withoutSid, schema);
  return extras.length > 0 ? extras : undefined;
}

function makeSessionState(sid: number, alive: boolean = false, resumable: boolean = false): SessionState {
  return {
    sid,
    messages: [],
    streamingBlocks: [],
    sessionInfo: null,
    isProcessing: false,
    totalCost: 0,
    alive,
    resumable,
    msgIdCounter: 0,
  };
}

export function App() {
  const [connected, setConnected] = useState(false);
  const [sessions, setSessions] = useState<Map<number, SessionState>>(new Map());
  const [activeSessionId, setActiveSessionId] = useState<number | null>(null);
  const connRef = useRef<Connection | null>(null);
  // When we create a session and want to send a message once it's confirmed
  const pendingFirstMessage = useRef<string | null>(null);

  const updateSession = useCallback((sid: number, updater: (s: SessionState) => SessionState) => {
    setSessions((prev) => {
      const s = prev.get(sid);
      if (!s) return prev;
      const next = new Map(prev);
      next.set(sid, updater(s));
      return next;
    });
  }, []);

  const handleSessionMessage = useCallback((sid: number, msg: ClaudeMessage) => {
    // Ensure session exists in our map (might arrive before sessions_list on replay)
    setSessions((prev) => {
      if (!prev.has(sid)) {
        const next = new Map(prev);
        next.set(sid, makeSessionState(sid, true));
        return next;
      }
      return prev;
    });

    const extras = messageExtras(msg);

    switch (msg.type) {
      case "system":
        if ("subtype" in msg) {
          if (msg.subtype === "init") {
            updateSession(sid, (s) => {
              const initMsg: DisplayMessage | undefined = extras ? {
                id: `init-${++s.msgIdCounter}`,
                type: "system" as const,
                content: [],
                extraFields: extras,
              } : undefined;
              return {
                ...s,
                sessionInfo: {
                  model: msg.model,
                  version: msg.claude_code_version,
                  sessionId: msg.session_id,
                  cwd: msg.cwd,
                  tools: msg.tools,
                  permissionMode: msg.permissionMode,
                  mcp_servers: msg.mcp_servers,
                  agents: msg.agents,
                  apiKeySource: msg.apiKeySource,
                  skills: msg.skills,
                  plugins: msg.plugins,
                  fast_mode_state: msg.fast_mode_state,
                },
                isProcessing: true,
                streamingBlocks: [],
                messages: initMsg ? [...s.messages, initMsg] : s.messages,
              };
            });
          } else if (msg.subtype === "status") {
            updateSession(sid, (s) => {
              const id = `status-${++s.msgIdCounter}`;
              return {
                ...s,
                messages: [
                  ...s.messages,
                  {
                    id,
                    type: "system" as const,
                    content: [],
                    statusText: (msg as any).status || "clear",
                    extraFields: extras,
                  },
                ],
              };
            });
          } else if (msg.subtype === "compact_boundary") {
            updateSession(sid, (s) => {
              const id = `compact-${++s.msgIdCounter}`;
              const cm = (msg as any).compact_metadata;
              return {
                ...s,
                messages: [
                  ...s.messages,
                  {
                    id,
                    type: "compact_boundary" as const,
                    content: [],
                    compactMetadata: cm ? { trigger: cm.trigger, preTokens: cm.pre_tokens } : undefined,
                    extraFields: extras,
                  },
                ],
              };
            });
          }
        }
        break;

      case "assistant":
        handleAssistantMessage(sid, msg as AssistantMessage);
        break;

      case "user":
        if ("isReplay" in msg && (msg as any).isReplay) {
          const content = (msg as any).message?.content;
          const text = typeof content === "string" ? content : "";
          updateSession(sid, (s) => {
            const filtered = s.messages.filter((m) => !(m.pending && m.type === "user"));
            const id = `user-${++s.msgIdCounter}`;
            return {
              ...s,
              messages: [...filtered, { id, type: "user" as const, content: [{ type: "text" as const, text }] }],
            };
          });
        } else if ("message" in msg && msg.message) {
          handleUserEcho(sid, msg);
        }
        break;

      case "stream_event":
        if ("event" in msg) {
          handleStreamEvent(sid, msg.event);
        }
        break;

      case "result":
        handleResultMessage(sid, msg as ResultMessage);
        break;

      case "summary": {
        updateSession(sid, (s) => {
          const id = `summary-${++s.msgIdCounter}`;
          return {
            ...s,
            messages: [
              ...s.messages,
              {
                id,
                type: "summary" as const,
                content: [{ type: "text" as const, text: (msg as any).summary || "" }],
                extraFields: extras,
              },
            ],
          };
        });
        break;
      }

      case "rate_limit_event": {
        updateSession(sid, (s) => {
          const id = `ratelimit-${++s.msgIdCounter}`;
          return {
            ...s,
            messages: [
              ...s.messages,
              {
                id,
                type: "rate_limit" as const,
                content: [],
                rateLimitInfo: (msg as any).rate_limit_info,
                extraFields: extras,
              },
            ],
          };
        });
        break;
      }

      case "exit":
        updateSession(sid, (s) => ({ ...s, isProcessing: false, streamingBlocks: [], alive: false }));
        break;

      case "stderr": {
        updateSession(sid, (s) => {
          const id = `stderr-${++s.msgIdCounter}`;
          return {
            ...s,
            messages: [
              ...s.messages,
              { id, type: "system" as const, content: [{ type: "text" as const, text: msg.text }] },
            ],
          };
        });
        break;
      }

      default: {
        // Unknown message type - display it so nothing is silently lost
        updateSession(sid, (s) => {
          const id = `unknown-${++s.msgIdCounter}`;
          return {
            ...s,
            messages: [
              ...s.messages,
              {
                id,
                type: "system" as const,
                content: [{ type: "text" as const, text: `Unknown message type: ${(msg as any).type}\n${JSON.stringify(msg, null, 2)}` }],
              },
            ],
          };
        });
        break;
      }
    }
  }, [updateSession]);

  const handleAssistantMessage = useCallback((sid: number, msg: AssistantMessage) => {
    const msgId = msg.message.id;
    const extras = messageExtras(msg);
    updateSession(sid, (s) => {
      const existing = s.messages.findIndex((m) => m.id === msgId);
      if (existing >= 0) {
        const updated = [...s.messages];
        const existingMsg = { ...updated[existing] };
        existingMsg.content = [...existingMsg.content, ...msg.message.content];
        // Update usage if present (later messages may have updated counts)
        if (msg.message.usage) {
          existingMsg.usage = msg.message.usage;
        }
        // Merge extra fields (deduplicate by path+key)
        if (extras) {
          const prev = existingMsg.extraFields || [];
          const seen = new Set(prev.map((e) => `${e.path}\0${e.key}`));
          const novel = extras.filter((e) => !seen.has(`${e.path}\0${e.key}`));
          existingMsg.extraFields = novel.length > 0 ? [...prev, ...novel] : prev;
        }
        updated[existing] = existingMsg;
        return { ...s, messages: updated, streamingBlocks: [] };
      }
      return {
        ...s,
        messages: [
          ...s.messages,
          {
            id: msgId,
            type: "assistant" as const,
            content: [...msg.message.content],
            toolResults: new Map(),
            model: msg.message.model,
            isSidechain: msg.isSidechain,
            parentToolUseId: msg.parent_tool_use_id,
            usage: msg.message.usage,
            extraFields: extras,
          },
        ],
        streamingBlocks: [],
      };
    });
  }, [updateSession]);

  const handleUserEcho = useCallback((sid: number, msg: any) => {
    const content = msg.message?.content;
    if (!content) return;

    const extras = messageExtras(msg);

    // Collect text blocks and tool_result blocks separately
    const textBlocks: string[] = [];
    const toolResults: Array<{ tool_use_id: string; content: string; is_error?: boolean }> = [];

    for (const block of content) {
      if (block.type === "tool_result") {
        toolResults.push(block);
      } else if (block.type === "text") {
        textBlocks.push(block.text);
      }
    }

    // Link tool results to their parent assistant messages
    if (toolResults.length > 0) {
      updateSession(sid, (s) => {
        const updated = [...s.messages];
        for (const block of toolResults) {
          for (let i = updated.length - 1; i >= 0; i--) {
            const m = updated[i];
            if (m.type === "assistant") {
              const hasToolUse = m.content.some(
                (c) => c.type === "tool_use" && (c as any).id === block.tool_use_id
              );
              if (hasToolUse) {
                const newMsg = { ...m, toolResults: new Map(m.toolResults) };
                newMsg.toolResults!.set(block.tool_use_id, {
                  toolUseId: block.tool_use_id,
                  content: block.content,
                  isError: block.is_error,
                });
                updated[i] = newMsg;
                break;
              }
            }
          }
        }
        return { ...s, messages: updated };
      });
    }

    // If there are text blocks (actual user text, not just tool results), show as user message
    // Skip if all text blocks are empty system-reminder type content
    const meaningfulText = textBlocks.filter((t) => t.trim().length > 0);
    if (meaningfulText.length > 0 && toolResults.length === 0) {
      // Only show user echo text when it's not a tool-result-only message
      // (tool result messages are user echos that just carry results back)
      updateSession(sid, (s) => {
        // Remove any pending user message that matches
        const filtered = s.messages.filter((m) => !(m.pending && m.type === "user"));
        const id = `user-echo-${++s.msgIdCounter}`;
        return {
          ...s,
          messages: [
            ...filtered,
            {
              id,
              type: "user" as const,
              content: meaningfulText.map((t) => ({ type: "text" as const, text: t })),
              isSidechain: msg.isSidechain,
              parentToolUseId: msg.parent_tool_use_id,
              extraFields: extras,
            },
          ],
        };
      });
    }
  }, [updateSession]);

  const handleResultMessage = useCallback((sid: number, msg: ResultMessage) => {
    const extras = messageExtras(msg);
    updateSession(sid, (s) => {
      const id = `result-${++s.msgIdCounter}`;
      return {
        ...s,
        totalCost: msg.total_cost_usd || s.totalCost,
        isProcessing: false,
        streamingBlocks: [],
        messages: [
          ...s.messages,
          {
            id,
            type: "result" as const,
            content: [],
            extraFields: extras,
            resultData: {
              subtype: msg.subtype,
              isError: msg.is_error,
              result: msg.result,
              numTurns: msg.num_turns,
              durationMs: msg.duration_ms,
              durationApiMs: msg.duration_api_ms,
              totalCostUsd: msg.total_cost_usd,
              usage: msg.usage,
              modelUsage: msg.modelUsage,
              permissionDenials: msg.permission_denials,
              stopReason: msg.stop_reason,
            },
          },
        ],
      };
    });
  }, [updateSession]);

  const handleStreamEvent = useCallback((sid: number, event: StreamEvent) => {
    switch (event.type) {
      case "content_block_start":
        updateSession(sid, (s) => ({
          ...s,
          streamingBlocks: [
            ...s.streamingBlocks,
            { index: event.index, type: event.content_block.type, text: "" },
          ],
        }));
        break;
      case "content_block_delta":
        updateSession(sid, (s) => ({
          ...s,
          streamingBlocks: s.streamingBlocks.map((b) => {
            if (b.index !== event.index) return b;
            const delta = event.delta;
            let append = "";
            if (delta.type === "text_delta") append = delta.text;
            else if (delta.type === "thinking_delta") append = delta.thinking;
            else if (delta.type === "input_json_delta") append = delta.partial_json;
            return { ...b, text: b.text + append };
          }),
        }));
        break;
      case "content_block_stop":
        updateSession(sid, (s) => ({
          ...s,
          streamingBlocks: s.streamingBlocks.filter((b) => b.index !== event.index),
        }));
        break;
    }
  }, [updateSession]);

  const handleControlMessage = useCallback((msg: ControlMessage) => {
    switch (msg.type) {
      case "session_created": {
        const sid = msg.sid;
        setSessions((prev) => {
          const next = new Map(prev);
          next.set(sid, makeSessionState(sid, false));
          return next;
        });
        setActiveSessionId(sid);

        // If we have a pending first message, send it now
        const text = pendingFirstMessage.current;
        if (text !== null) {
          pendingFirstMessage.current = null;
          // Add pending user message to session state
          setSessions((prev) => {
            const next = new Map(prev);
            const s = next.get(sid);
            if (s) {
              const id = `pending-${++s.msgIdCounter}`;
              next.set(sid, {
                ...s,
                messages: [...s.messages, { id, type: "user" as const, content: [{ type: "text" as const, text }], pending: true }],
              });
            }
            return next;
          });
          connRef.current?.sendMessage(sid, text);
        }
        break;
      }
      case "sessions_list": {
        setSessions((prev) => {
          const next = new Map(prev);
          for (const entry of msg.sessions) {
            if (!next.has(entry.sid)) {
              next.set(entry.sid, makeSessionState(entry.sid, entry.alive, entry.resumable));
            } else {
              const s = next.get(entry.sid)!;
              next.set(entry.sid, { ...s, alive: entry.alive, resumable: entry.resumable });
            }
          }
          return next;
        });
        // Set active to first session if we don't have one
        if (msg.sessions.length > 0) {
          setActiveSessionId((prev) => prev ?? msg.sessions[0].sid);
        }
        break;
      }
    }
  }, []);

  useEffect(() => {
    const conn = new Connection();
    connRef.current = conn;

    // Buffer incoming messages and flush on rAF so that hundreds of replay
    // messages are processed in a single render pass instead of one-per-message.
    type BufferedMsg =
      | { kind: "session"; sid: number; msg: ClaudeMessage }
      | { kind: "control"; msg: ControlMessage };
    let buffer: BufferedMsg[] = [];
    let rafId: number | null = null;

    const flush = () => {
      rafId = null;
      const batch = buffer;
      buffer = [];
      for (const item of batch) {
        if (item.kind === "control") handleControlMessage(item.msg);
        else handleSessionMessage(item.sid, item.msg);
      }
    };

    conn.onStatusChange = (connected) => {
      setConnected(connected);
      if (!connected) {
        setSessions(new Map());
        setActiveSessionId(null);
      }
    };
    conn.onSessionMessage = (sid, msg) => {
      buffer.push({ kind: "session", sid, msg });
      if (rafId === null) rafId = requestAnimationFrame(flush);
    };
    conn.onControlMessage = (msg) => {
      buffer.push({ kind: "control", msg });
      if (rafId === null) rafId = requestAnimationFrame(flush);
    };
    conn.connect();
    return () => {
      if (rafId !== null) cancelAnimationFrame(rafId);
      conn.disconnect();
    };
  }, [handleSessionMessage, handleControlMessage]);

  const handleSend = useCallback(
    (text: string) => {
      if (activeSessionId === null) {
        // No sessions — create one and queue the message
        pendingFirstMessage.current = text;
        connRef.current?.createSession();
        return;
      }
      updateSession(activeSessionId, (s) => {
        const id = `pending-${++s.msgIdCounter}`;
        return {
          ...s,
          messages: [...s.messages, { id, type: "user" as const, content: [{ type: "text" as const, text }], pending: true }],
        };
      });
      connRef.current?.sendMessage(activeSessionId, text);
    },
    [activeSessionId, updateSession]
  );

  const handleInterrupt = useCallback(() => {
    if (activeSessionId !== null) {
      connRef.current?.sendInterrupt(activeSessionId);
    }
  }, [activeSessionId]);

  const handleNewSession = useCallback(() => {
    connRef.current?.createSession();
  }, []);

  const handleResume = useCallback(() => {
    if (activeSessionId !== null) {
      connRef.current?.resumeSession(activeSessionId);
      updateSession(activeSessionId, (s) => ({ ...s, alive: true, resumable: false }));
    }
  }, [activeSessionId, updateSession]);

  const active = activeSessionId !== null ? sessions.get(activeSessionId) ?? null : null;
  const hasSessions = sessions.size > 0;

  // Build sidebar session list sorted by sid
  const sidebarSessions = Array.from(sessions.values())
    .sort((a, b) => a.sid - b.sid)
    .map((s) => ({ sid: s.sid, alive: s.alive, resumable: s.resumable, totalCost: s.totalCost }));

  if (!hasSessions) {
    // Welcome screen — no sessions yet
    return (
      <div class="app welcome">
        <div class="welcome-box">
          <h1 class="welcome-title">CyDo</h1>
          <p class="welcome-subtitle">Multi-agent orchestration system</p>
          <InputBox
            onSend={handleSend}
            onInterrupt={handleInterrupt}
            isProcessing={false}
            disabled={!connected}
          />
        </div>
      </div>
    );
  }

  return (
    <div class="app has-sidebar">
      <Sidebar
        sessions={sidebarSessions}
        activeSessionId={activeSessionId}
        onSelectSession={setActiveSessionId}
        onNewSession={handleNewSession}
      />
      <SystemBanner
        sessionInfo={active?.sessionInfo ?? null}
        connected={connected}
        totalCost={active?.totalCost ?? 0}
        isProcessing={active?.isProcessing ?? false}
      />
      <MessageList
        messages={active?.messages ?? []}
        streamingBlocks={active?.streamingBlocks ?? []}
        isProcessing={active?.isProcessing ?? false}
      />
      {active?.resumable ? (
        <div class="resume-bar">
          <button class="btn btn-resume" onClick={handleResume}>
            Resume Session
          </button>
        </div>
      ) : (
        <InputBox
          onSend={handleSend}
          onInterrupt={handleInterrupt}
          isProcessing={active?.isProcessing ?? false}
          disabled={!connected}
        />
      )}
    </div>
  );
}
